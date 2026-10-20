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
} derive(Debug)

///|
/// A single rule violation located in a file.
pub struct Finding {
  pub rule_id : String
  pub severity : Severity
  pub message : String
  /// Path relative to the scan root.
  pub file : String
  /// 1-based line number.
  pub line : Int32
  /// The offending source line (trimmed).
  pub snippet : String
} derive(Debug)

///|
/// Aggregate result of a lint run.
pub struct LintResult {
  pub findings : Array[Finding]
  /// Number of files scanned.
  pub files_scanned : Int32
  /// Number of findings suppressed by the baseline.
  pub baseline_hits : Int32
} derive(Debug)

///|
/// Construct a LintResult.
pub fn LintResult::new(
  findings : Array[Finding],
  files_scanned : Int32,
  baseline_hits : Int32,
) -> LintResult {
  { findings, files_scanned, baseline_hits, }
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
