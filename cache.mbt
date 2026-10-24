///|
/// Incremental scan cache.
///
/// A full-tree lint re-reads, re-parses and re-matches every file on every
/// run, which is wasteful when only a handful of files changed since the
/// last one. `--incremental` keeps a JSON cache keyed by a digest of each
/// file's content: an unchanged file reuses the findings it produced last
/// time, and only new or modified files go through the matcher again.
///
/// Correctness rules, in order of importance:
///
/// - The cache carries a fingerprint of the *effective* rule set. Findings
///   depend on the whole configuration, not just the file, so any rule
///   change invalidates every entry rather than reusing stale ones.
/// - The cache is per scan root and per extension filter; changing either
///   produces a different effective config and therefore a different
///   fingerprint.
/// - Only successful per-file results are cached. Structural findings are
///   deliberately not: they depend on *other* files, so they are re-derived
///   from the freshly parsed project index on every run.
/// - Entries for files that vanished from the scan are dropped, so a
///   deletion can never leave stale findings behind.
/// - A cache file that fails to parse, or whose version does not match, is
///   discarded silently: a stale cache must degrade to a full scan, never
///   to a wrong answer.

///|
/// Cache format version. Bump whenever the entry layout changes.
const CACHE_VERSION : Int32 = 1

///|
/// One cached file: the digest of its content and the findings the rules
/// produced for it on the previous run.
pub struct CacheEntry {
  hash : String
  findings : Array[Finding]
} derive(Debug)

///|
/// The on-disk cache: a format version, a fingerprint of the effective
/// configuration, and one entry per cached file.
pub struct Cache {
  version : Int32
  fingerprint : String
  files : Map[String, CacheEntry]
} derive(Debug)

///|
/// A fresh, empty cache for the given configuration fingerprint.
pub fn Cache::new(fingerprint : String) -> Cache {
  { version: CACHE_VERSION, fingerprint, files: Map([]), }
}

///|
/// Whether a loaded cache may be reused for a configuration with this
/// fingerprint. A version mismatch means the layout changed; a fingerprint
/// mismatch means the rules did. Either way the cache is discarded.
pub fn Cache::is_current(self : Cache, fingerprint : String) -> Bool {
  self.version == CACHE_VERSION && self.fingerprint == fingerprint
}

///|
/// The cached entry for a file, if any.
pub fn Cache::get(self : Cache, rel : String) -> CacheEntry? {
  self.files.get(rel)
}

///|
/// Record the result of scanning one file.
pub fn Cache::put(
  self : Cache,
  rel : String,
  hash : String,
  findings : Array[Finding],
) -> Unit {
  self.files.set(rel, { hash, findings, })
}

///|
/// Digest of a file's content, used as the cache key. FNV-1a 64-bit — the
/// same primitive the baseline uses: collision resistance against accidental
/// edits is all a cache needs, and it keeps the dependency surface at zero.
pub fn content_hash(source : String) -> String {
  fnv1a_hex(source)
}

///|
/// Fingerprint of the effective rule set. Everything that can change a
/// finding is folded in: rule ids, severities, messages, extension filters,
/// matcher/check parameters, per-rule scopes and the global scope. The
/// digest is taken over a canonical, order-sensitive rendering so that
/// reordering rules is still a cache invalidation (it changes report order).
pub fn config_fingerprint(
  rules : Array[Rule],
  file_rules : Array[FileRule],
  structural_rules : Array[StructuralRule],
  scope : Scope,
) -> String {
  let parts : Array[String] = []
  for r in rules {
    let unless = match r.unless {
      None => "-"
      Some(u) => match_signature(u)
    }
    parts.push(
      "rule|\{r.id}|\{r.severity.tag()}|\{r.message}|\{r.extensions.join(",")}|\{match_signature(r.match_)}|\{unless}|\{scope_signature(r.scope)}|\{if r.match_comments { "comments" } else { "code" }}",
    )
  }
  for fr in file_rules {
    parts.push(
      "file|\{fr.id}|\{fr.severity.tag()}|\{fr.message}|\{fr.extensions.join(",")}|\{file_check_signature(fr.check)}|\{scope_signature(fr.scope)}",
    )
  }
  for sr in structural_rules {
    parts.push(
      "struct|\{sr.id}|\{sr.severity.tag()}|\{sr.message}|\{sr.extensions.join(",")}|\{structural_check_signature(sr.check)}|\{scope_signature(sr.scope)}",
    )
  }
  parts.push("global|\{scope_signature(scope)}")
  fnv1a_hex(parts.join("\n"))
}

///|
/// Canonical rendering of a line matcher. Combinators render their whole
/// subtree so any structural change to a nested formula invalidates caches.
fn match_signature(m : MatchKind) -> String {
  match m {
    Contains(s) => "contains:\{s}"
    HasPrefix(s) => "prefix:\{s}"
    HasSuffix(s) => "suffix:\{s}"
    Regex(s) => "regex:\{s}"
    Equals(s) => "equals:\{s}"
    Word(s) => "word:\{s}"
    All(subs) => "all:[\{subs.map(s => match_signature(s)).join(",")}]"
    Any(subs) => "any:[\{subs.map(s => match_signature(s)).join(",")}]"
    Not(sub) => "not:\{match_signature(sub)}"
  }
}

///|
/// Canonical rendering of a file-level check, parameters included.
fn file_check_signature(c : FileCheck) -> String {
  match c {
    MaxLines(n) => "max_lines:\{n}"
    MaxLineLength(n) => "max_line_length:\{n}"
    NoTrailingWhitespace => "no_trailing_whitespace"
    NoTabs => "no_tabs"
    FinalNewline => "final_newline"
    NoDuplicateLines => "no_duplicate_lines"
    FileNaming(style) => "file_naming:\{naming_style_tag(style)}"
    MaxFileSize(n) => "max_file_size:\{n}"
    NoEmptyFiles => "no_empty_files"
    LineEnding(style) => "line_ending:\{line_ending_style_tag(style)}"
    NoBom => "no_bom"
  }
}

///|
/// Canonical rendering of a project-level check, parameters included.
fn structural_check_signature(c : StructuralCheck) -> String {
  match c {
    NoUnusedImports => "no_unused_imports"
    NoDuplicateImports => "no_duplicate_imports"
    NoUnresolvedRelativeImports => "no_unresolved_relative_imports"
    NoImportCycles => "no_import_cycles"
    NoDefaultExport => "no_default_export"
    NoDeepRelativeImports(n) => "no_deep_relative_imports:\{n}"
    NoRequireImports => "no_require_imports"
    NoUnusedExports => "no_unused_exports"
  }
}

///|
/// Naming style tag, matching the config spelling.
fn naming_style_tag(s : NamingStyle) -> String {
  match s {
    CamelCase => "camelCase"
    PascalCase => "PascalCase"
    SnakeCase => "snake_case"
    KebabCase => "kebab-case"
  }
}

///|
/// Line-ending style tag, matching the config spelling.
fn line_ending_style_tag(s : LineEndingStyle) -> String {
  match s {
    Lf => "lf"
    Crlf => "crlf"
  }
}

///|
/// Canonical rendering of a path scope. Glob patterns render through their
/// segment list, so two patterns that compile to the same matcher (for
/// example `a//b` and `a/b`) share one fingerprint.
fn scope_signature(s : Scope) -> String {
  let includes = s.includes.map(p => p.segments.join("/"))
  let excludes = s.excludes.map(p => p.segments.join("/"))
  "+[\{includes.join(",")}]-[\{excludes.join(",")}]"
}

///|
/// Render the cache as JSON for atomic writing.
pub fn Cache::render(self : Cache) -> String {
  let files : Map[String, Json] = Map([])
  for (rel, entry) in self.files {
    let obj : Map[String, Json] = Map([])
    obj.set("hash", Json::string(entry.hash))
    obj.set("findings", cache_findings_json(entry.findings))
    files.set(rel, Json::object(obj))
  }
  let root : Map[String, Json] = Map([])
  root.set("version", Json::number(CACHE_VERSION.to_double()))
  root.set("fingerprint", Json::string(self.fingerprint))
  root.set("files", Json::object(files))
  Json::object(root).stringify(indent=2)
}

///|
/// Serialize findings in the same shape the JSON report uses, so a cached
/// entry and a fresh finding are indistinguishable downstream.
fn cache_findings_json(findings : Array[Finding]) -> Json {
  let items : Array[Json] = []
  for f in findings {
    let obj : Map[String, Json] = Map([])
    obj.set("rule_id", Json::string(f.rule_id))
    obj.set("severity", Json::string(f.severity.tag()))
    obj.set("message", Json::string(f.message))
    obj.set("file", Json::string(f.file))
    obj.set("line", Json::number(f.line.to_double()))
    obj.set("column", Json::number(f.column.to_double()))
    obj.set("snippet", Json::string(f.snippet))
    items.push(Json::object(obj))
  }
  Json::array(items)
}

///|
/// Parse a cache file. Any malformation — bad JSON, wrong shape, unknown
/// version — yields `None`, which the caller treats as "no cache".
pub fn Cache::parse(src : String) -> Cache? {
  let json = @json.parse(src) catch { _ => return None }
  let root = match json.as_object() {
    Some(o) => o
    None => return None
  }
  let version = match root.get("version") {
    Some(v) =>
      match v.as_number() {
        Some(n) => n.to_int()
        None => return None
      }
    None => return None
  }
  if version != CACHE_VERSION {
    return None
  }
  let fingerprint = match root.get("fingerprint") {
    Some(v) =>
      match v.as_string() {
        Some(s) => s
        None => return None
      }
    None => return None
  }
  let files_json = match root.get("files") {
    Some(v) => v
    None => return None
  }
  let files_obj = match files_json.as_object() {
    Some(o) => o
    None => return None
  }
  let files : Map[String, CacheEntry] = Map([])
  for (rel, value) in files_obj {
    let obj = match value.as_object() {
      Some(o) => o
      None => return None
    }
    let hash = match obj.get("hash") {
      Some(v) =>
        match v.as_string() {
          Some(s) => s
          None => return None
        }
      None => return None
    }
    let findings = match obj.get("findings") {
      Some(v) =>
        match v.as_array() {
          Some(arr) =>
            match parse_findings(arr) {
              Some(fs) => fs
              None => return None
            }
          None => return None
        }
      None => return None
    }
    files.set(rel, { hash, findings, })
  }
  Some({ version, fingerprint, files, })
}

///|
/// Parse a findings array; a malformed entry fails the whole cache load,
/// because a half-trusted cache is worse than no cache.
fn parse_findings(arr : Array[Json]) -> Array[Finding]? {
  let findings : Array[Finding] = []
  for item in arr {
    let obj = match item.as_object() {
      Some(o) => o
      None => return None
    }
    let rule_id = match get_json_str(obj, "rule_id") {
      Some(s) => s
      None => return None
    }
    let severity = match get_json_str(obj, "severity") {
      Some(s) => Severity::parse(s)
      None => return None
    }
    let message = match get_json_str(obj, "message") {
      Some(s) => s
      None => return None
    }
    let file = match get_json_str(obj, "file") {
      Some(s) => s
      None => return None
    }
    let line = match obj.get("line") {
      Some(v) =>
        match v.as_number() {
          Some(n) => n.to_int()
          None => return None
        }
      None => return None
    }
    let column = match obj.get("column") {
      Some(v) =>
        match v.as_number() {
          Some(n) => n.to_int()
          None => return None
        }
      None => return None
    }
    let snippet = match get_json_str(obj, "snippet") {
      Some(s) => s
      None => return None
    }
    findings.push({ rule_id, severity, message, file, line, column, snippet, })
  }
  Some(findings)
}

///|
/// Read a string field from a JSON object.
fn get_json_str(obj : Map[String, Json], key : String) -> String? {
  match obj.get(key) {
    Some(v) => v.as_string()
    None => None
  }
}

///|
/// Expose derived impls as regular methods for external callers.

///|
pub extend CacheEntry with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend Cache with @moonbitlang/core/debug.Debug::{to_repr}
