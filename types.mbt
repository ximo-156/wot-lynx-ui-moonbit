///|
/// moonlint — a config-driven convention linter for source trees.
///
/// This is a MoonBit port of `wot-lynx-ui`'s `scripts/review-lint.mjs`.
/// It scans a directory tree, applies a set of declarative rules to each
/// source file, and reports violations. Rules are loaded from a JSON config
/// so the same engine can enforce any project's conventions.
///
/// Design notes:
/// - Regex-free core matchers (`Contains` / `HasPrefix` / `HasSuffix`) cover
///   the common cases cheaply; a `Regex` variant is available for the rest.
/// - Comments are blanked out (preserving line numbers and column offsets)
///   before matching, so rule authors never match inside comments.
/// - A hash-based baseline lets an existing codebase adopt the linter
///   incrementally: known findings are exempted until they are fixed.

///|
/// Severity of a rule violation.
pub enum Severity {
  Error
  Warning
} derive(Debug, Eq)

///|
/// Convenience constructors (pub so external packages can build values).
pub fn Severity::error() -> Severity {
  Error
}

///|
pub fn Severity::warning() -> Severity {
  Warning
}

///|
/// Render a severity as a lowercase tag used in reports.
pub fn Severity::tag(self : Severity) -> String {
  match self {
    Error => "error"
    Warning => "warning"
  }
}

///|
/// Parse a severity from its lowercase tag. Unknown values default to
/// `Warning` so a typo in config never silently drops an error-level rule.
pub fn Severity::parse(self : String) -> Severity {
  match self {
    "error" => Error
    _ => Warning
  }
}

///|
/// A single line-matching primitive. Rules combine one `match` kind with an
/// optional `unless` kind (a negative guard) to express "match X but not Y".
pub enum MatchKind {
  /// Line contains the substring.
  Contains(String)
  /// Line starts with the substring.
  HasPrefix(String)
  /// Line ends with the substring.
  HasSuffix(String)
  /// Line matches the regular expression.
  Regex(String)
  /// Trimmed line equals the string exactly.
  Equals(String)
  /// Line contains the string as a whole word (bounded by non-word chars).
  Word(String)
} derive(Debug, Eq)

///|
/// A declarative lint rule.
pub struct Rule {
  /// Stable identifier, e.g. `vue/import-from-vue`.
  id : String
  severity : Severity
  /// Human-readable explanation shown when the rule fires.
  message : String
  /// File extensions this rule applies to, e.g. `[".vue", ".ts"]`.
  /// An empty list means "all scanned files".
  extensions : Array[String]
  /// The primary matcher.
  match_ : MatchKind
  /// Optional negative guard: if this also matches, the finding is skipped.
  unless : MatchKind?
  /// Paths this rule applies to. An empty scope means "every file".
  scope : Scope
} derive(Debug)

///|
/// A single rule violation located in a file.
pub struct Finding {
  rule_id : String
  severity : Severity
  message : String
  /// Path relative to the scan root.
  file : String
  /// 1-based line number.
  line : Int32
  /// The offending source line (trimmed).
  snippet : String
} derive(Debug)

///|
/// A scan failure. These are operational errors, not lint findings.
pub struct Diagnostic {
  file : String
  message : String
} derive(Debug)

///|
/// A file that entered the scan but was not read.
pub struct SkippedFile {
  /// Path relative to the scan root.
  file : String
  /// Why the file was not read, e.g. `no-applicable-rule`.
  reason : String
} derive(Debug)

///|
/// Scan metadata attached to machine-readable reports.
pub struct ScanInfo {
  /// Scan mode tag, e.g. `tree`, `staged`, `glob`.
  mode : String
  /// Absolute scan root.
  root : String
  /// Effective extension filter; an empty list means "all files".
  extensions : Array[String]
} derive(Debug)

///|
/// Build the scan metadata carried by machine-readable reports.
pub fn ScanInfo::new(
  mode : String,
  root : String,
  extensions : Array[String],
) -> ScanInfo {
  { mode, root, extensions, }
}

///|
/// A parsed configuration: the rule set plus the global file scope.
pub struct LintConfig {
  /// The configured rules, in declaration order.
  rules : Array[Rule]
  /// File-level rules evaluated once per file.
  file_rules : Array[FileRule]
  /// The global scope applied to every scan.
  scope : Scope
} derive(Debug)

///|
/// Naming convention for file-level naming checks.
pub enum NamingStyle {
  CamelCase
  PascalCase
  SnakeCase
  KebabCase
} derive(Debug, Eq)

///|
/// Parse a naming style from its string tag.
pub fn NamingStyle::parse(s : String) -> NamingStyle? {
  match s {
    "camelCase" => Some(CamelCase)
    "PascalCase" => Some(PascalCase)
    "snake_case" => Some(SnakeCase)
    "kebab-case" => Some(KebabCase)
    _ => None
  }
}

///|
/// Line ending style for file-level checks.
pub enum LineEndingStyle {
  /// Unix line endings (LF only).
  Lf
  /// Windows line endings (CRLF only).
  Crlf
} derive(Debug, Eq)

///|
/// Parse a line ending style from its string tag.
pub fn LineEndingStyle::parse(s : String) -> LineEndingStyle? {
  match s {
    "lf" => Some(Lf)
    "crlf" => Some(Crlf)
    _ => None
  }
}

///|
/// A file-level check evaluated once per file, not per line.
pub enum FileCheck {
  /// File must not exceed N lines.
  MaxLines(Int32)
  /// No line may exceed N characters.
  MaxLineLength(Int32)
  /// No trailing whitespace on any line.
  NoTrailingWhitespace
  /// No tab characters anywhere in the file.
  NoTabs
  /// File must end with a newline.
  FinalNewline
  /// No duplicate lines in the file.
  NoDuplicateLines
  /// File name (without extension) must follow a naming convention.
  FileNaming(NamingStyle)
  /// File must not exceed N bytes.
  MaxFileSize(Int32)
  /// File must not be empty.
  NoEmptyFiles
  /// File must use consistent line endings.
  LineEnding(LineEndingStyle)
  /// File must not start with a UTF-8 BOM.
  NoBom
} derive(Debug, Eq)

///|
/// A file-level lint rule.
pub struct FileRule {
  /// Stable identifier, e.g. `file/max-lines`.
  id : String
  severity : Severity
  /// Human-readable explanation shown when the rule fires.
  message : String
  /// File extensions this rule applies to. Empty means "all scanned files".
  extensions : Array[String]
  /// The file-level check to perform.
  check : FileCheck
  /// Paths this rule applies to. An empty scope means "every file".
  scope : Scope
} derive(Debug)

///|
/// Aggregate result. Selection is counted after path normalization, extension
/// filtering and de-duplication; each selected file is scanned, skipped or failed.
pub struct LintResult {
  findings : Array[Finding]
  /// Files that passed path, extension and scope filters.
  files_selected : Int32
  /// Files read successfully and linted.
  files_scanned : Int32
  /// Selected files that were not read, with a reason for each.
  files_skipped : Int32
  /// Files that could not be read, with a diagnostic for each.
  files_failed : Int32
  /// Candidate files removed by the global scope before scanning.
  files_out_of_scope : Int32
  /// Findings suppressed by the baseline.
  baseline_hits : Int32
  diagnostics : Array[Diagnostic]
  skipped_files : Array[SkippedFile]
} derive(Debug)

///|
/// Backwards-compatible constructor for callers supplying successful findings.
pub fn LintResult::new(
  findings : Array[Finding],
  files_scanned : Int32,
  baseline_hits : Int32,
) -> LintResult {
  {
    findings,
    files_selected: files_scanned,
    files_scanned,
    files_skipped: 0,
    files_failed: 0,
    files_out_of_scope: 0,
    baseline_hits,
    diagnostics: [],
    skipped_files: [],
  }
}

///|
/// Replace displayed findings without losing the run's IO counters.
pub fn LintResult::with_findings(
  self : LintResult,
  findings : Array[Finding],
  baseline_hits : Int32,
) -> LintResult {
  {
    findings,
    files_selected: self.files_selected,
    files_scanned: self.files_scanned,
    files_skipped: self.files_skipped,
    files_failed: self.files_failed,
    files_out_of_scope: self.files_out_of_scope,
    baseline_hits,
    diagnostics: self.diagnostics,
    skipped_files: self.skipped_files,
  }
}

///|
/// Whether the result contains any error-severity finding.
pub fn LintResult::has_errors(self : LintResult) -> Bool {
  self.findings.any(f => f.severity == Severity::Error)
}

///|
/// Count findings by severity.
pub fn LintResult::count_by(self : LintResult, sev : Severity) -> Int32 {
  self.findings.count_if(f => f.severity == sev)
}

///|
/// Expose the derived impls as regular methods so callers outside this
/// package can use them without relying on implicit impl promotion.
///|
pub extend Severity with @moonbitlang/core/debug.Debug::{to_repr}
///|
pub extend Severity with Eq::{equal, not_equal}
///|
pub extend MatchKind with @moonbitlang/core/debug.Debug::{to_repr}
///|
pub extend MatchKind with Eq::{equal, not_equal}
///|
pub extend Rule with @moonbitlang/core/debug.Debug::{to_repr}
///|
pub extend Finding with @moonbitlang/core/debug.Debug::{to_repr}
///|
pub extend Diagnostic with @moonbitlang/core/debug.Debug::{to_repr}
///|
pub extend SkippedFile with @moonbitlang/core/debug.Debug::{to_repr}
///|
pub extend ScanInfo with @moonbitlang/core/debug.Debug::{to_repr}
///|
pub extend LintConfig with @moonbitlang/core/debug.Debug::{to_repr}
///|
pub extend NamingStyle with @moonbitlang/core/debug.Debug::{to_repr}
///|
pub extend NamingStyle with Eq::{equal, not_equal}
///|
pub extend LineEndingStyle with @moonbitlang/core/debug.Debug::{to_repr}
///|
pub extend LineEndingStyle with Eq::{equal, not_equal}
///|
pub extend FileCheck with @moonbitlang/core/debug.Debug::{to_repr}
///|
pub extend FileCheck with Eq::{equal, not_equal}
///|
pub extend FileRule with @moonbitlang/core/debug.Debug::{to_repr}
///|
pub extend LintResult with @moonbitlang/core/debug.Debug::{to_repr}
