///|
/// MoonBit project front end. A MoonBit module is a tree of packages, each
/// declared by a `moon.pkg` (or `moon.pkg.json`) manifest whose import block
/// names its dependencies. The package graph is read from those manifests:
/// no toolchain invocation, no project code executed. A changed file selects
/// the packages that own it plus every package that transitively imports
/// them; execution is `moon test` per selected package.
priv struct ImpactMbtEdge {
  dependency : String
  kind : String
}

///|
priv struct ImpactMbtPackage {
  path : String
  imports : Array[String]
  test_imports : Array[String]
  has_tests : Bool
}

///|
/// Whether the root is a MoonBit module: the new JSON descriptor or the
/// legacy text one. Detection never reads project code.
pub fn impact_has_moonbit_module(root : String) -> Bool {
  try {
    ignore(@fs.read_file_to_string(join_path(root, "moon.mod.json")))
    true
  } catch {
    _ =>
      try {
        ignore(@fs.read_file_to_string(join_path(root, "moon.mod")))
        true
      } catch {
        _ => false
      }
  }
}

///|
fn impact_mbt_starts_with(
  chars : Array[Char],
  start : Int32,
  keyword : String,
) -> Bool {
  let key = keyword.to_array()
  if start + key.length() > chars.length() {
    return false
  }
  for k in 0..<key.length() {
    if chars[start + k] != key[k] {
      return false
    }
  }
  true
}

///|
/// The module name from a `moon.mod.json` descriptor.
fn impact_mbt_json_name(source : String) -> String? {
  let json = @json.parse(source, max_nesting_depth=8) catch { _ => return None }
  match json {
    Json::Object(obj) =>
      match obj.get("name") {
        Some(Json::String(name)) if name != "" => Some(name)
        _ => None
      }
    _ => None
  }
}

///|
/// Every module descriptor under the root, as (module directory, module name)
/// pairs sorted by directory length descending, so the longest ancestor
/// module wins. A workspace can nest many modules; each package resolves its
/// imports against its own module, never the root module.
fn impact_mbt_modules(
  sources : Array[(String, String)],
) -> Array[(String, String)] {
  let modules : Array[(String, String)] = []
  for (path, source) in sources {
    let name = match path.rev_split_once("/") {
      Some((_, name)) => name
      None => path
    }
    if name != "moon.mod" && name != "moon.mod.json" {
      continue
    }
    let dir = match path.rev_split_once("/") {
      Some((parent, _)) => parent.to_owned()
      None => ""
    }
    let name = if path.has_suffix(".json") {
      impact_mbt_json_name(source)
    } else {
      impact_mbt_text_name(source)
    }
    match name {
      Some(module) => modules.push((dir, module))
      None => ()
    }
  }
  modules.sort_by((a, b) => impact_path_order(b.0, a.0))
  modules
}

///|
/// The module that owns a manifest directory: the longest ancestor module.
fn impact_mbt_module_of(
  dir : String,
  modules : Array[(String, String)],
) -> (String, String)? {
  for (module_dir, module_name) in modules {
    if module_dir == "" || dir == module_dir || dir.has_prefix(module_dir + "/") {
      return Some((module_dir, module_name))
    }
  }
  None
}

///|
/// The module name from `moon.mod.json` or the legacy `moon.mod`.
fn impact_mbt_text_name(source : String) -> String? {
  // Legacy text manifest: name = "module/name"
  for line in source.split("\n") {
    let trimmed = line.trim()
    if !impact_mbt_starts_with(trimmed.to_array(), 0, "name") {
      continue
    }
    let rest = trimmed.to_array()
    let mut i = 4
    while i < rest.length() && impact_mbt_space(rest[i]) {
      i += 1
    }
    if i >= rest.length() || rest[i] != '=' {
      continue
    }
    i += 1
    while i < rest.length() && impact_mbt_space(rest[i]) {
      i += 1
    }
    if i >= rest.length() || rest[i] != '"' {
      continue
    }
    let mut end = i + 1
    while end < rest.length() && rest[end] != '"' {
      end += 1
    }
    if end < rest.length() && end > i + 1 {
      return Some(String::from_array(rest[i + 1:end]))
    }
  }
  None
}

///|
/// Extract the quoted specifiers of one `import`/`test-import` block. A
/// missing block means no dependencies (Some([])); a malformed block is None.
fn impact_mbt_manifest_imports(
  source : String,
  keyword : String,
) -> Array[String]? {
  // A manifest may hold several blocks: plain imports, `for "test"` imports
  // and `#cfg(...)`-conditional imports all name dependencies, so every block
  // is scanned, not only the first.
  let chars = source.to_array()
  let specs : Array[String] = []
  let mut found = false
  let mut i = 0
  while i < chars.length() {
    if impact_mbt_starts_with(chars, i, keyword) {
      let before_ok = i == 0 || !impact_mbt_ident_char(chars[i - 1])
      let after = if i + keyword.length() < chars.length() {
        chars[i + keyword.length()]
      } else {
        ' '
      }
      // "test-import" contains "import": the plain keyword must not be
      // followed by an identifier continuation such as '-'.
      let after_ok = if keyword == "import" { after != '-' } else { true }
      if before_ok && after_ok {
        let mut j = i + keyword.length()
        while j < chars.length() && impact_mbt_space(chars[j]) {
          j += 1
        }
        if j < chars.length() && chars[j] == '{' {
          let mut depth = 1
          let mut k = j + 1
          while k < chars.length() && depth > 0 {
            let c = chars[k]
            if c == '"' {
              let mut end = k + 1
              while end < chars.length() && chars[end] != '"' {
                if chars[end] == '\\' {
                  end += 1
                }
                end += 1
              }
              if end >= chars.length() {
                return None
              }
              let spec = String::from_array(chars[k + 1:end])
              if !specs.contains(spec) {
                specs.push(spec)
              }
              k = end + 1
              continue
            }
            if c == '{' {
              depth += 1
            } else if c == '}' {
              depth -= 1
            }
            k += 1
          }
          if depth != 0 {
            return None
          }
          found = true
          i = k
          continue
        }
      }
    }
    i += 1
  }
  Some(specs)
}

///|
fn impact_mbt_ident_char(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '_' ||
  c == '-'
}

///|
fn impact_mbt_space(c : Char) -> Bool {
  c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

///|
/// Resolve one manifest specifier to a package path inside this module, or
/// None when it names an external module.
fn impact_mbt_resolve(
  spec : String,
  module_name : String,
  module_dir : String,
) -> String? {
  // The graph is keyed by root-relative package paths, so a module-relative
  // specifier is re-anchored at its own module directory.
  if spec == module_name {
    Some(module_dir)
  } else if spec.has_prefix(module_name + "/") {
    let rest = spec[module_name.length() + 1:].to_owned()
    Some(if module_dir == "" { rest } else { module_dir + "/" + rest })
  } else {
    None
  }
}

///|
/// Build the package graph from the manifests found in membership.
fn impact_mbt_packages(
  membership : Set[String],
  modules : Array[(String, String)],
  sources : Array[(String, String)],
) -> (Array[ImpactMbtPackage], Array[ImpactIssue]) {
  let packages : Array[ImpactMbtPackage] = []
  let issues : Array[ImpactIssue] = []
  let manifests : Array[String] = []
  for path in membership.iter() {
    let name = match path.rev_split_once("/") {
      Some((_, name)) => name
      None => path
    }
    if name == "moon.pkg" || name == "moon.pkg.json" {
      manifests.push(path)
    }
  }
  manifests.sort_by(impact_path_order)
  for manifest in manifests {
    let dir = match manifest.rev_split_once("/") {
      Some((parent, _)) => parent.to_owned()
      None => ""
    }
    let mut collected : String? = None
    for (path, text) in sources {
      if path == manifest {
        collected = Some(text)
      }
    }
    let source = match collected {
      Some(text) => text
      None => {
        issues.push({
          file: manifest,
          line: 0,
          reason: "io: package manifest was not collected",
        })
        continue
      }
    }
    let imports = match impact_mbt_manifest_imports(source, "import") {
      Some(specs) => specs
      None => {
        issues.push({
          file: manifest,
          line: 0,
          reason: "moonbit: package manifest import block is malformed",
        })
        continue
      }
    }
    let test_imports = match
      impact_mbt_manifest_imports(source, "test-import") {
      Some(specs) => specs
      None => {
        issues.push({
          file: manifest,
          line: 0,
          reason: "moonbit: package manifest test-import block is malformed",
        })
        continue
      }
    }
    let (module_dir, module_name) = match impact_mbt_module_of(dir, modules) {
      Some(pair) => pair
      None => {
        issues.push({
          file: manifest,
          line: 0,
          reason: "moonbit: package has no enclosing module descriptor",
        })
        continue
      }
    }
    let resolved : Array[String] = []
    for spec in imports {
      match impact_mbt_resolve(spec, module_name, module_dir) {
        Some(target) => if !resolved.contains(target) { resolved.push(target) }
        None => ()
      }
    }
    let resolved_tests : Array[String] = []
    for spec in test_imports {
      match impact_mbt_resolve(spec, module_name, module_dir) {
        Some(target) =>
          if !resolved_tests.contains(target) {
            resolved_tests.push(target)
          }
        None => ()
      }
    }
    let prefix = if dir == "" { "" } else { dir + "/" }
    let mut has_tests = false
    for path in membership.iter() {
      if path.has_prefix(prefix) &&
        (path.has_suffix("_test.mbt") || path.has_suffix("_wbtest.mbt")) {
        has_tests = true
      }
    }
    packages.push({
      path: dir,
      imports: resolved,
      test_imports: resolved_tests,
      has_tests,
    })
  }
  (packages, issues)
}

///|
/// The package that owns a file: the longest package directory prefix. The
/// module root package ("") owns everything no other package claims.
fn impact_mbt_owner(
  file : String,
  packages : Array[ImpactMbtPackage],
) -> String? {
  let mut best : String? = None
  for package in packages {
    if package.path == "" {
      if best is None {
        best = Some("")
      }
    } else if file.has_prefix(package.path + "/") {
      let longer = match best {
        Some(current) => package.path.length() > current.length()
        None => true
      }
      if longer {
        best = Some(package.path)
      }
    }
  }
  best
}

///|
/// MoonBit module global inputs: manifests and the module descriptor. A change
/// to any of them can alter the graph itself, so it requests every package.
fn impact_mbt_global_input(path : String) -> Bool {
  let name = match path.rev_split_once("/") {
    Some((_, name)) => name
    None => path
  }
  name == "moon.mod" ||
  name == "moon.mod.json" ||
  name == "moon.pkg" ||
  name == "moon.pkg.json"
}

///|
/// Plan a MoonBit module: changed files select their owning packages and
/// every transitive importer. The plan is advisory, exactly like the JS/TS
/// planner: an unparseable manifest or an unmodeled change requests every
/// package rather than pretending no test is affected.
pub fn impact_moonbit_plan(
  root : String,
  changed : Array[String],
  input : String,
  observations : Array[ImpactIssue],
) -> ImpactPlan raise {
  let config = impact_default_config()
  impact_validate_config(config)
  let absolute = canonical_root(root)
  let normalized = impact_unique_paths(changed)
  if normalized.is_empty() {
    return {
      root: absolute,
      input,
      changed: [],
      strategy: "none",
      tests: [],
      inventory: [],
      affected: [],
      traces: [],
      issues: [],
      reasons: ["no-changes: no test execution requested"],
      source_count: 0,
      edge_count: 0,
      mode: "moonbit",
    }
  }
  let walk_paths : Array[String] = []
  let walk_issues : Array[ImpactIssue] = []
  impact_collect_paths(absolute, "", config, walk_paths, walk_issues)
  walk_paths.sort_by(impact_path_order)
  let observed = observations.copy()
  for issue in walk_issues {
    observed.push(issue)
  }
  let membership = impact_unique_paths(walk_paths)
  let sources : Array[(String, String)] = []
  for path in membership {
    let name = match path.rev_split_once("/") {
      Some((_, name)) => name
      None => path
    }
    if name == "moon.mod" ||
      name == "moon.mod.json" ||
      name == "moon.pkg" ||
      name == "moon.pkg.json" {
      let text = @fs.read_file_to_string(join_path(absolute, path)) catch {
        _ => raise Failure("moonbit: cannot read module manifest: " + path)
      }
      sources.push((path, text))
    }
  }
  sources.sort_by((a, b) => impact_path_order(a.0, b.0))
  impact_moonbit_plan_from(
    absolute, membership, sources, normalized, input, observed,
  )
}

///|
/// Pure MoonBit planning over an already-collected membership and the module
/// and package manifests read from it. Keeping it filesystem-free makes the
/// package graph, strategies and evidence chains unit-testable.
fn impact_moonbit_plan_from(
  absolute : String,
  membership_paths : Array[String],
  sources : Array[(String, String)],
  normalized : Array[String],
  input : String,
  observations : Array[ImpactIssue],
) -> ImpactPlan raise {
  let membership = Set::from_iter(membership_paths.iter())
  let issues = observations.copy()
  let modules = impact_mbt_modules(sources)
  if modules.is_empty() {
    issues.push({
      file: "moon.mod.json",
      line: 0,
      reason: "moonbit: no module descriptor found; the package graph is unknown",
    })
  }
  let (packages, package_issues) = impact_mbt_packages(
    membership, modules, sources,
  )
  for issue in package_issues {
    issues.push(issue)
  }
  // Inventory: packages that contain tests.
  let inventory : Array[String] = []
  for package in packages {
    if package.has_tests && !inventory.contains(package.path) {
      inventory.push(package.path)
    }
  }
  inventory.sort_by(impact_path_order)
  // Reverse edges over intra-module imports. Test-only imports matter too:
  // a whitebox test can observe a package the library never imports.
  let reverse : Map[String, Array[ImpactMbtEdge]] = Map([])
  for package in packages {
    for target in package.imports {
      let outgoing = reverse.get(target).unwrap_or([])
      outgoing.push({ dependency: package.path, kind: "imports", })
      reverse.set(target, outgoing)
    }
    for target in package.test_imports {
      let outgoing = reverse.get(target).unwrap_or([])
      outgoing.push({ dependency: package.path, kind: "test-imports", })
      reverse.set(target, outgoing)
    }
  }
  let reasons : Array[String] = []
  let origins : Map[String, String] = Map([])
  let parent : Map[String, ImpactMbtEdge] = Map([])
  let queue : Array[String] = []
  for path in normalized {
    if impact_mbt_global_input(path) {
      reasons.push("global-input-changed: " + path)
      continue
    }
    if !membership.contains(path) {
      reasons.push(
        "removed-or-missing-input: " +
        path +
        "; historical dependencies are not inferred",
      )
      continue
    }
    match impact_mbt_owner(path, packages) {
      Some(owner) =>
        if !origins.contains(owner) {
          origins.set(owner, path)
          queue.push(owner)
        }
      None => reasons.push("unmodeled-changed-input: " + path)
    }
  }
  let mut head = 0
  while head < queue.length() {
    let package = queue[head]
    head += 1
    for edge in reverse.get(package).unwrap_or([]) {
      let dependent = edge.dependency
      let kind = edge.kind
      if !origins.contains(dependent) {
        origins.set(dependent, origins.get(package).unwrap_or(package))
        parent.set(dependent, { dependency: package, kind, })
        queue.push(dependent)
      }
    }
  }
  let affected = origins.keys().to_array()
  affected.sort_by(impact_path_order)
  let traces : Array[ImpactTrace] = []
  let selected : Array[String] = []
  for package in affected {
    let has_tests = packages.any(item => item.path == package && item.has_tests)
    if !has_tests {
      continue
    }
    selected.push(package)
    // Walk parents back to the owning package, then start the chain at the
    // changed file that reached it.
    let backwards : Array[ImpactEdge] = []
    let mut current = package
    while true {
      match parent.get(current) {
        Some(edge) => {
          let dependency = edge.dependency
          let kind = edge.kind
          backwards.push({
            dependency,
            dependent: current,
            kind,
            line: 0,
            column: 0,
          })
          current = dependency
        }
        None => break
      }
    }
    let origin_file = origins.get(package).unwrap_or("")
    let chain : Array[ImpactEdge] = []
    if backwards.length() > 0 {
      chain.push({
        dependency: origin_file,
        dependent: backwards[backwards.length() - 1].dependency,
        kind: "owns",
        line: 0,
        column: 0,
      })
    } else if origin_file != "" {
      chain.push({
        dependency: origin_file,
        dependent: package,
        kind: "owns",
        line: 0,
        column: 0,
      })
    }
    for i = backwards.length() - 1; i >= 0; i = i - 1 {
      chain.push(backwards[i])
    }
    traces.push({ test_file: package, changed: origin_file, chain, })
  }
  let unique_issues : Array[ImpactIssue] = []
  let issue_keys : Set[String] = Set([])
  for issue in issues {
    let key = "\{issue.file}\u{0}\{issue.line}\u{0}\{issue.reason}"
    if !issue_keys.contains(key) {
      issue_keys.add(key)
      unique_issues.push(issue)
    }
  }
  unique_issues.sort_by((a, b) => {
    let order = impact_path_order(a.file, b.file)
    if order != 0 {
      order
    } else if a.line != b.line {
      a.line.compare(b.line)
    } else {
      impact_path_order(a.reason, b.reason)
    }
  })
  if !unique_issues.is_empty() {
    reasons.push("uncertain-dependencies: every package required; see issues")
  }
  let blocked = unique_issues.any(issue => {
    issue.reason.has_prefix("io:") || issue.reason.has_prefix("unsafe:")
  })
  let strategy = if blocked || inventory.is_empty() {
    if inventory.is_empty() {
      reasons.push(
        "no-test-inventory: no package in this module contains tests",
      )
    }
    "blocked"
  } else if !reasons.is_empty() {
    "full"
  } else if selected.is_empty() {
    reasons.push(
      "no-known-related-packages: no affected package contains tests",
    )
    "none"
  } else {
    "related"
  }
  {
    root: absolute,
    input,
    changed: normalized,
    strategy,
    tests: if strategy == "full" {
      inventory.copy()
    } else if strategy == "related" {
      selected
    } else {
      []
    },
    inventory,
    affected,
    traces,
    issues: unique_issues,
    reasons,
    source_count: membership.length(),
    edge_count: reverse.keys().length(),
    mode: "moonbit",
  }
}
