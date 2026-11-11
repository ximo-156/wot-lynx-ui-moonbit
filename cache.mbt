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
const CACHE_VERSION : Int32 = 3

///|
/// Parser generation of the cached structural models. Bump whenever the
/// parser's output changes (a new statement shape, a fixed misparse), so a
/// model produced by an older front end cannot outlive the fix. A mismatch
/// drops the models but keeps the per-file findings, which do not depend on
/// the parser.
const MODEL_VERSION : Int32 = 1

///|
/// One cached file: the digest of its content and the findings the rules
/// produced for it on the previous run.
#derive(Debug)
pub struct CacheEntry {
  hash : String
  findings : Array[Finding]
}

///|
/// One cached structural model: the digest of the source it was parsed from
/// and the model itself.
#derive(Debug)
pub struct ModelEntry {
  hash : String
  model : FileModel
}

///|
/// The cached verdict of the whole structural pass. Reusable only when the
/// key — the effective rule fingerprint plus every participating file's
/// content digest — matches exactly, because any file can change a cross-file
/// answer. Snippets are deliberately not stored: a minified one-line file can
/// make one snippet larger than the entire cache, and the line is re-derived
/// from the source that was just scanned.
#derive(Debug)
pub struct StructuralCache {
  key : String
  findings : Array[Finding]
}

///|
/// Identity of a structural pass: the configuration fingerprint plus the
/// sorted `(path, content hash)` pairs of every file that took part. Equal
/// keys mean the same rules ran over byte-identical inputs.
pub fn structural_key(
  fingerprint : String,
  ids : Array[(String, String)],
) -> String {
  let sorted = ids.copy()
  sorted.sort_by((a, b) => a.0.compare(b.0))
  let parts : Array[String] = [fingerprint]
  for pair in sorted {
    let (rel, hash) = pair
    parts.push("\{rel}|\{hash}")
  }
  fnv1a_hex(parts.join("\n"))
}

///|
/// The on-disk cache: a format version, a fingerprint of the effective
/// configuration, one entry per cached file, and the parsed structural models
/// used by the cross-file pass.
#derive(Debug)
pub struct Cache {
  version : Int32
  fingerprint : String
  files : Map[String, CacheEntry]
  /// Per-file structural models, keyed by relative path and validated by
  /// content hash. Unlike findings these do not depend on the rules, so they
  /// survive a configuration change.
  models : Map[String, ModelEntry]
  /// Verdict of the last full structural pass, if it was cacheable.
  mut structural : StructuralCache?
}

///|
/// A fresh, empty cache for the given configuration fingerprint.
pub fn Cache::new(fingerprint : String) -> Cache {
  {
    version: CACHE_VERSION,
    fingerprint,
    files: Map([]),
    models: Map([]),
    structural: None,
  }
}

///|
/// The cached structural verdict, if any.
pub fn Cache::get_structural(self : Cache) -> StructuralCache? {
  self.structural
}

///|
/// Record the structural verdict for the given key.
pub fn Cache::put_structural(
  self : Cache,
  key : String,
  findings : Array[Finding],
) -> Unit {
  self.structural = Some({ key, findings, })
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
/// The cached structural model for a file, if any.
pub fn Cache::get_model(self : Cache, rel : String) -> ModelEntry? {
  self.models.get(rel)
}

///|
/// Record the structural model parsed for one file.
pub fn Cache::put_model(
  self : Cache,
  rel : String,
  hash : String,
  model : FileModel,
) -> Unit {
  self.models.set(rel, { hash, model, })
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
      "rule|\{r.id}|\{r.severity.tag()}|\{r.message}|\{r.extensions.join(",")}|\{match_signature(r.match_)}|\{unless}|\{scope_signature(r.scope)}|\{if r.match_comments { "comments" } else if r.match_literals { "literals" } else { "code" }}",
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
    NoDuplicateLines(n) => "no_duplicate_lines:\{n}"
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
    MoonbitRequirePublicDoc => "moonbit_require_public_doc"
    MoonbitNaming => "moonbit_naming"
    MoonbitNoUnwrap => "moonbit_no_unwrap"
    MoonbitNoPanic => "moonbit_no_panic"
    MoonbitNoPrintln => "moonbit_no_println"
    MoonbitNoTodo => "moonbit_no_todo"
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
  let models : Map[String, Json] = Map([])
  for (rel, entry) in self.models {
    let obj : Map[String, Json] = Map([])
    obj.set("hash", Json::string(entry.hash))
    obj.set("model", cache_model_json(entry.model))
    models.set(rel, Json::object(obj))
  }
  let root : Map[String, Json] = Map([])
  root.set("version", Json::number(CACHE_VERSION.to_double()))
  root.set("fingerprint", Json::string(self.fingerprint))
  root.set("files", Json::object(files))
  root.set("model_version", Json::number(MODEL_VERSION.to_double()))
  root.set("models", Json::object(models))
  match self.structural {
    Some(entry) => {
      let obj : Map[String, Json] = Map([])
      obj.set("key", Json::string(entry.key))
      obj.set("findings", cache_findings_json(entry.findings))
      root.set("structural", Json::object(obj))
    }
    None => ()
  }
  Json::object(root).stringify(indent=2)
}

///|
/// Serialize a structural model compactly: the cross-file pass only needs
/// imports, exports and the set of used identifier names, so declaration
/// positions and per-occurrence usage positions are not stored.
fn cache_model_json(model : FileModel) -> Json {
  let imports : Array[Json] = []
  for spec in model.imports {
    let names : Array[Json] = []
    for name in spec.names {
      names.push(
        Json::array([Json::string(name.local), Json::string(name.imported)]),
      )
    }
    imports.push(
      Json::array([
        Json::string(import_kind_tag(spec.kind)),
        Json::string(spec.source),
        Json::number(spec.line.to_double()),
        Json::number(spec.column.to_double()),
        Json::boolean(spec.type_only),
        Json::array(names),
      ]),
    )
  }
  let exports : Array[Json] = []
  for spec in model.exports {
    exports.push(
      Json::array([
        Json::array(spec.names.map(n => Json::string(n))),
        match spec.source {
          Some(s) => Json::string(s)
          None => Json::null()
        },
        Json::number(spec.line.to_double()),
        Json::number(spec.column.to_double()),
      ]),
    )
  }
  // Only the names matter downstream (`no_unused_imports` asks whether an
  // imported binding appears at all), so duplicates are dropped here: a
  // 10k-line file can read the same identifier hundreds of times.
  let seen : Set[String] = Set([])
  let used : Array[Json] = []
  for ident in model.used {
    if !seen.contains(ident.name) {
      seen.add(ident.name)
      used.push(Json::string(ident.name))
    }
  }
  Json::object({
    "imports": Json::array(imports),
    "exports": Json::array(exports),
    "used": Json::array(used),
  })
}

///|
/// Tag for an import kind; the inverse of `import_kind_from_tag`.
fn import_kind_tag(kind : ImportKind) -> String {
  match kind {
    Static => "static"
    Dynamic => "dynamic"
    Require => "require"
    ReExport => "reexport"
  }
}

///|
fn import_kind_from_tag(tag : String) -> ImportKind? {
  match tag {
    "static" => Some(Static)
    "dynamic" => Some(Dynamic)
    "require" => Some(Require)
    "reexport" => Some(ReExport)
    _ => None
  }
}

///|
/// Decode a structural model. Any malformed part returns `None`; the caller
/// drops the entry and re-parses that file.
fn cache_model_from_json(json : Json) -> FileModel? {
  let obj = match json.as_object() {
    Some(o) => o
    None => return None
  }
  let imports_json = match obj.get("imports") {
    Some(Json::Array(a)) => a
    _ => return None
  }
  let imports : Array[ImportSpec] = []
  for item in imports_json {
    let parts = match item.as_array() {
      Some(a) => if a.length() == 6 { a } else { return None }
      None => return None
    }
    let kind = match parts[0].as_string() {
      Some(tag) =>
        match import_kind_from_tag(tag) {
          Some(k) => k
          None => return None
        }
      None => return None
    }
    let source = match parts[1].as_string() {
      Some(s) => s
      None => return None
    }
    let line = match parts[2].as_number() {
      Some(n) => n.to_int()
      None => return None
    }
    let column = match parts[3].as_number() {
      Some(n) => n.to_int()
      None => return None
    }
    let type_only = match parts[4].as_bool() {
      Some(b) => b
      None => return None
    }
    let names_json = match parts[5].as_array() {
      Some(a) => a
      None => return None
    }
    let names : Array[ImportName] = []
    for name_item in names_json {
      let pair = match name_item.as_array() {
        Some(a) => if a.length() == 2 { a } else { return None }
        None => return None
      }
      let local = match pair[0].as_string() {
        Some(s) => s
        None => return None
      }
      let imported = match pair[1].as_string() {
        Some(s) => s
        None => return None
      }
      names.push({ local, imported, })
    }
    imports.push({ kind, source, names, line, column, type_only, })
  }
  let exports_json = match obj.get("exports") {
    Some(Json::Array(a)) => a
    _ => return None
  }
  let exports : Array[ExportSpec] = []
  for item in exports_json {
    let parts = match item.as_array() {
      Some(a) => if a.length() == 4 { a } else { return None }
      None => return None
    }
    let names_json = match parts[0].as_array() {
      Some(a) => a
      None => return None
    }
    let names : Array[String] = []
    for n in names_json {
      match n.as_string() {
        Some(s) => names.push(s)
        None => return None
      }
    }
    let source : String? = match parts[1] {
      Json::Null => None
      other =>
        match other.as_string() {
          Some(s) => Some(s)
          None => return None
        }
    }
    let line = match parts[2].as_number() {
      Some(n) => n.to_int()
      None => return None
    }
    let column = match parts[3].as_number() {
      Some(n) => n.to_int()
      None => return None
    }
    exports.push({ names, source, line, column, })
  }
  let used_json = match obj.get("used") {
    Some(Json::Array(a)) => a
    _ => return None
  }
  let used : Array[UsedIdent] = []
  for item in used_json {
    match item.as_string() {
      Some(name) => used.push({ name, line: 0, column: 0, })
      None => return None
    }
  }
  Some({ imports, exports, decls: ([] : Array[Decl]), used, })
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
  // Models are an optimization, not part of the verdict: a malformed or
  // outdated models section is dropped entry by entry (or wholesale on a
  // version mismatch) while the per-file findings stay usable.
  let models : Map[String, ModelEntry] = Map([])
  let model_version_ok = match root.get("model_version") {
    Some(v) =>
      match v.as_number() {
        Some(n) => n.to_int() == MODEL_VERSION
        None => false
      }
    None => false
  }
  if model_version_ok {
    match root.get("models") {
      Some(mj) =>
        match mj.as_object() {
          Some(entries) =>
            for (rel, value) in entries {
              match cache_model_entry_from_json(value) {
                Some(entry) => models.set(rel, entry)
                None => ()
              }
            }
          None => ()
        }
      None => ()
    }
  }
  // The structural verdict is likewise an optimization: a malformed entry is
  // dropped rather than failing the whole cache.
  let structural : StructuralCache? = match root.get("structural") {
    Some(sj) =>
      match sj.as_object() {
        Some(obj) =>
          match (get_json_str(obj, "key"), obj.get("findings")) {
            (Some(key), Some(Json::Array(items))) =>
              match parse_findings(items) {
                Some(findings) => Some({ key, findings, })
                None => None
              }
            _ => None
          }
        None => None
      }
    None => None
  }
  Some({ version, fingerprint, files, models, structural, })
}

///|
/// Decode one `(hash, model)` entry; `None` drops just that entry.
fn cache_model_entry_from_json(json : Json) -> ModelEntry? {
  let obj = match json.as_object() {
    Some(o) => o
    None => return None
  }
  let hash = match get_json_str(obj, "hash") {
    Some(s) => s
    None => return None
  }
  let model = match obj.get("model") {
    Some(m) =>
      match cache_model_from_json(m) {
        Some(parsed) => parsed
        None => return None
      }
    None => return None
  }
  Some({ hash, model, })
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
