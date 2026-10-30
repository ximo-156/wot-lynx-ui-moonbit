///|
/// Cross-file structural analysis over a parsed project index.
///
/// The line matcher answers "does this line look wrong", the file checks
/// answer "does this file look wrong", and this module answers the questions
/// that need the whole project in view at once: is this import used, does
/// this specifier resolve, do these files form a cycle, is this export dead.
/// None of those can be expressed as a per-line pattern — which is exactly
/// why the scanner builds a real token stream and structural model first.
///
/// Everything here is best-effort by design: the parser never fails on
/// syntax it does not understand, so a file with exotic constructs simply
/// contributes fewer edges to the graph rather than aborting the scan.

///|
/// Extensions probed, in order, when a relative specifier omits the file
/// extension (the TypeScript convention). The literal path is always tried
/// first, so an exact match always wins.
fn resolution_extensions() -> Array[String] {
  [
    ".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs", ".vue", ".svelte",
    ".json",
  ]
}

///|
/// One parsed file in the project index.
pub struct ProjectFile {
  /// Path relative to the scan root.
  rel : String
  /// The raw source, kept so findings can quote the offending line.
  source : String
  /// The structural model parsed from the source.
  model : FileModel
} derive(Debug)

///|
/// The parsed project: every scanned file plus a membership set used for
/// extension-less module resolution.
pub struct ProjectIndex {
  files : Array[ProjectFile]
  paths : Set[String]
}

///|
/// Build the project index from (relative path, source) pairs. Sources are
/// parsed with the structural parser; every file enters the index so later
/// checks see a consistent file list even when a file parses to an empty
/// model.
pub fn build_index(sources : Array[(String, String)]) -> ProjectIndex {
  let files : Array[ProjectFile] = []
  let paths : Set[String] = Set::from_iter([].iter())
  for (rel, source) in sources {
    files.push({ rel, source, model: parse_source(source), })
    paths.add(rel)
  }
  { files, paths, }
}

///|
/// Whether a module specifier is relative to the importing file. Bare
/// specifiers (`react`, `@scope/pkg`) resolve through `node_modules`, which
/// this linter does not model, so they are never "unresolved".
pub fn is_relative(specifier : String) -> Bool {
  specifier.has_prefix("./") ||
  specifier.has_prefix("../") ||
  specifier == "." ||
  specifier == ".."
}

///|
/// The module specifier of an import, with its surrounding quotes removed.
/// The tokenizer keeps quotes in string tokens, so every consumer of
/// `ImportSpec::source` goes through here first.
pub fn spec_source(spec : ImportSpec) -> String {
  let chars = spec.source.to_array()
  let n = chars.length()
  if n >= 2 && (chars[0] == '\'' || chars[0] == '"') && chars[n - 1] == chars[0] {
    String::from_array(chars[1:n - 1])
  } else {
    spec.source
  }
}

///|
/// Join the importing file's directory with a specifier and collapse `.` and
/// `..` segments. A `..` above the root is clamped, matching how bundlers
/// refuse to let a package escape its own root.
fn normalize_join(from_rel : String, specifier : String) -> String {
  let parts : Array[String] = []
  match from_rel.rev_split_once("/") {
    Some((dir, _)) =>
      for seg in dir.split("/") {
        let s = seg.to_owned()
        if s != "" && s != "." {
          parts.push(s)
        }
      }
    None => ()
  }
  for seg in specifier.split("/") {
    let s = seg.to_owned()
    if s == "" || s == "." {
      continue
    } else if s == ".." {
      if parts.length() > 0 {
        ignore(parts.pop())
      }
    } else {
      parts.push(s)
    }
  }
  parts.join("/")
}

///|
/// Resolve a relative specifier from one file to a file in the index. The
/// literal path is tried first, then `path + ext`, then `path/index + ext`
/// for every probe extension — the same order bundlers use.
pub fn ProjectIndex::resolve(
  self : ProjectIndex,
  from_rel : String,
  specifier : String,
) -> String? {
  let chars = specifier.to_array()
  let n = chars.length()
  let spec = if n >= 2 &&
    (chars[0] == '\'' || chars[0] == '"') &&
    chars[n - 1] == chars[0] {
    String::from_array(chars[1:n - 1])
  } else {
    specifier
  }
  if !is_relative(spec) {
    return None
  }
  let base = normalize_join(from_rel, spec)
  if base == "" {
    return None
  }
  if self.paths.contains(base) {
    return Some(base)
  }
  for ext in resolution_extensions() {
    let candidate = "\{base}\{ext}"
    if self.paths.contains(candidate) {
      return Some(candidate)
    }
  }
  for ext in resolution_extensions() {
    let candidate = "\{base}/index\{ext}"
    if self.paths.contains(candidate) {
      return Some(candidate)
    }
  }
  None
}

///|
/// Run every structural rule against the index and collect the findings.
/// Cross-file data (the import graph and the export-usage map) is computed
/// once and shared by every rule that needs it.
pub fn analyze(
  index : ProjectIndex,
  rules : Array[StructuralRule],
) -> Array[Finding] {
  let findings : Array[Finding] = []
  let edges = build_edges(index)
  let (export_usage, namespace_used) = build_export_usage(index)
  for rule in rules {
    for file in index.files {
      if !rule.applies_to(file.rel) {
        continue
      }
      match rule.check {
        NoUnusedImports => check_unused_imports(rule, file, findings)
        NoDuplicateImports => check_duplicate_imports(rule, file, findings)
        NoUnresolvedRelativeImports =>
          check_unresolved(rule, file, index, findings)
        NoImportCycles => check_cycles(rule, file, edges, findings)
        NoDefaultExport => check_default_export(rule, file, findings)
        NoDeepRelativeImports(limit) =>
          check_deep_relative(rule, file, limit, findings)
        NoRequireImports => check_require_imports(rule, file, findings)
        NoUnusedExports =>
          check_unused_exports(
            rule, file, export_usage, namespace_used, findings,
          )
        MoonbitRequirePublicDoc | MoonbitNaming => ()
      }
    }
  }
  findings
}

///|
/// Build a structural finding, quoting the offending source line.
fn structural_finding(
  rule : StructuralRule,
  file : ProjectFile,
  line : Int32,
  column : Int32,
  detail : String,
) -> Finding {
  {
    rule_id: rule.id,
    severity: rule.severity,
    message: "\{rule.message} (\{detail})",
    file: file.rel,
    line,
    column,
    snippet: snippet_at(file.source, line),
  }
}

///|
/// The trimmed source line at a 1-based line number, for report snippets.
fn snippet_at(source : String, lineno : Int32) -> String {
  let mut current = 1
  for view in source.split("\n") {
    if current == lineno {
      let line = view.to_owned()
      return line.trim().to_owned()
    }
    current += 1
  }
  ""
}

///|
/// An imported binding that never appears as an identifier read anywhere
/// else in the file. Side-effect imports (`import './x'`) bind nothing and
/// are never reported.
fn check_unused_imports(
  rule : StructuralRule,
  file : ProjectFile,
  findings : Array[Finding],
) -> Unit {
  let used : Set[String] = Set::from_iter(
    file.model.used.iter().map(u => u.name),
  )
  for spec in file.model.imports {
    for name in spec.names {
      // `import * as ns` binds `ns`; a bare `import *` binds nothing.
      if name.local == "*" {
        continue
      }
      if !used.contains(name.local) {
        findings.push(
          structural_finding(
            rule,
            file,
            spec.line,
            spec.column,
            "'\{name.local}' is imported but never used",
          ),
        )
      }
    }
  }
}

///|
/// The same module specifier reached by more than one import statement in a
/// file. Each statement after the first is reported once.
fn check_duplicate_imports(
  rule : StructuralRule,
  file : ProjectFile,
  findings : Array[Finding],
) -> Unit {
  let counts : Map[String, Int32] = Map::new()
  for spec in file.model.imports {
    let src = spec_source(spec)
    if src == "" {
      continue
    }
    let seen = counts.get(src).unwrap_or(0)
    if seen > 0 {
      findings.push(
        structural_finding(
          rule,
          file,
          spec.line,
          spec.column,
          "module '\{src}' is imported \{seen + 1} times",
        ),
      )
    }
    counts.set(src, seen + 1)
  }
}

///|
/// A relative specifier that resolves to no scanned file. This is the check
/// that catches a rename or a moved file breaking its importers.
fn check_unresolved(
  rule : StructuralRule,
  file : ProjectFile,
  index : ProjectIndex,
  findings : Array[Finding],
) -> Unit {
  for spec in file.model.imports {
    let src = spec_source(spec)
    if !is_relative(src) {
      continue
    }
    match index.resolve(file.rel, src) {
      None =>
        findings.push(
          structural_finding(
            rule,
            file,
            spec.line,
            spec.column,
            "cannot resolve '\{src}'",
          ),
        )
      Some(_) => ()
    }
  }
}

///|
/// The import graph: every file mapped to the resolvable relative imports
/// it makes, as (target path, line, column) triples.
fn build_edges(
  index : ProjectIndex,
) -> Map[String, Array[(String, Int32, Int32)]] {
  let edges : Map[String, Array[(String, Int32, Int32)]] = Map::new()
  for file in index.files {
    let list : Array[(String, Int32, Int32)] = []
    for spec in file.model.imports {
      let src = spec_source(spec)
      if !is_relative(src) {
        continue
      }
      match index.resolve(file.rel, src) {
        Some(target) => list.push((target, spec.line, spec.column))
        None => ()
      }
    }
    edges.set(file.rel, list)
  }
  edges
}

///|
/// Whether `target` is reachable from `from` by following relative imports.
fn reaches(
  edges : Map[String, Array[(String, Int32, Int32)]],
  from : String,
  target : String,
) -> Bool {
  if from == target {
    return true
  }
  let visited : Set[String] = Set::from_iter([].iter())
  visited.add(from)
  let queue : Array[String] = [from]
  let mut head = 0
  while head < queue.length() {
    let cur = queue[head]
    head += 1
    for edge in edges.get(cur).unwrap_or([]) {
      let next = edge.0
      if next == target {
        return true
      }
      if !visited.contains(next) {
        visited.add(next)
        queue.push(next)
      }
    }
  }
  false
}

///|
/// An import whose target can import its way back to this file, i.e. the
/// file takes part in a cycle. The finding points at the import that closes
/// the loop, which is the one to remove or invert.
fn check_cycles(
  rule : StructuralRule,
  file : ProjectFile,
  edges : Map[String, Array[(String, Int32, Int32)]],
  findings : Array[Finding],
) -> Unit {
  for edge in edges.get(file.rel).unwrap_or([]) {
    let target = edge.0
    if reaches(edges, target, file.rel) {
      findings.push(
        structural_finding(
          rule,
          file,
          edge.1,
          edge.2,
          "import of '\{target}' closes an import cycle",
        ),
      )
    }
  }
}

///|
/// `export default` — reported when a project's convention forbids it.
fn check_default_export(
  rule : StructuralRule,
  file : ProjectFile,
  findings : Array[Finding],
) -> Unit {
  for spec in file.model.exports {
    if spec.names.contains("default") {
      findings.push(
        structural_finding(rule, file, spec.line, spec.column, "default export"),
      )
    }
  }
}

///|
/// A relative import climbing more than `limit` directories. Deep chains
/// are a coupling smell; the check reports the actual climb count.
fn check_deep_relative(
  rule : StructuralRule,
  file : ProjectFile,
  limit : Int32,
  findings : Array[Finding],
) -> Unit {
  for spec in file.model.imports {
    let src = spec_source(spec)
    if !is_relative(src) {
      continue
    }
    let mut climbs = 0
    for seg in src.split("/") {
      if seg.to_owned() == ".." {
        climbs += 1
      }
    }
    if climbs > limit {
      findings.push(
        structural_finding(
          rule,
          file,
          spec.line,
          spec.column,
          "relative import climbs \{climbs} levels (limit: \{limit})",
        ),
      )
    }
  }
}

///|
/// A `require()` call in a codebase that has opted into ES modules.
fn check_require_imports(
  rule : StructuralRule,
  file : ProjectFile,
  findings : Array[Finding],
) -> Unit {
  for spec in file.model.imports {
    if spec.kind == ImportKind::Require {
      findings.push(
        structural_finding(
          rule,
          file,
          spec.line,
          spec.column,
          "require() in an ES module codebase",
        ),
      )
    }
  }
}

///|
/// Which (module, exported name) pairs are imported somewhere, plus the
/// modules consumed wholesale via `import * as ns` or `export * from`.
fn build_export_usage(
  index : ProjectIndex,
) -> (Map[String, Set[String]], Set[String]) {
  let usage : Map[String, Set[String]] = Map::new()
  let namespace_used : Set[String] = Set::from_iter([].iter())
  for file in index.files {
    for spec in file.model.imports {
      if spec.names.length() == 0 {
        continue
      }
      let src = spec_source(spec)
      match index.resolve(file.rel, src) {
        Some(target) =>
          for name in spec.names {
            if name.imported == "*" {
              namespace_used.add(target)
            } else {
              let cur = usage.get(target).unwrap_or(Set::from_iter([].iter()))
              cur.add(name.imported)
              usage.set(target, cur)
            }
          }
        None => ()
      }
    }
  }
  (usage, namespace_used)
}

///|
/// An exported name no other scanned file imports. `default` and `*` are
/// skipped: a default export is a module's public entry point and
/// `export *` re-exports names this linter cannot enumerate.
fn check_unused_exports(
  rule : StructuralRule,
  file : ProjectFile,
  usage : Map[String, Set[String]],
  namespace_used : Set[String],
  findings : Array[Finding],
) -> Unit {
  if namespace_used.contains(file.rel) {
    return
  }
  for spec in file.model.exports {
    for name in spec.names {
      if name == "default" || name == "*" {
        continue
      }
      let used = usage.get(file.rel).unwrap_or(Set::from_iter([].iter()))
      if used.contains(name) {
        continue
      }
      findings.push(
        structural_finding(
          rule,
          file,
          spec.line,
          spec.column,
          "exported '\{name}' is never imported by another file",
        ),
      )
    }
  }
}

///|
/// Expose derived impls as regular methods for external callers.

///|
pub extend ProjectFile with @moonbitlang/core/debug.Debug::{to_repr}
