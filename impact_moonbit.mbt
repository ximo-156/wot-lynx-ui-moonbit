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
/// Whether the root contains a MoonBit module or workspace descriptor.
/// Detection never evaluates project code.
pub fn impact_has_moonbit_module(root : String) -> Bool {
  for name in ["moon.mod", "moon.mod.json", "moon.work"] {
    let kind = source_path_kind(join_path(root, name)) catch {
      _ => return true
    }
    if kind != 0 {
      return true
    }
  }
  false
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
    // Preserve an invalid descriptor as a module boundary. Its packages must
    // not silently borrow an ancestor module's name.
    modules.push((dir, name.unwrap_or("")))
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
/// Read one top-level string assignment using the same literal decoding as
/// import paths. Comments, nested values and duplicate assignments cannot
/// invent a module name or source directory.
fn impact_mbt_text_string(
  source : String,
  key : String,
  default_value : String?,
) -> String? {
  let tokens = match api_gate_lex(source) {
    Ok(tokens) => tokens
    Err(_) => return None
  }
  let mut value = default_value
  let mut found = false
  let mut i = 0
  while i < tokens.length() {
    if tokens[i].kind == 0 && tokens[i].text == key {
      if found || i + 2 >= tokens.length() || tokens[i + 1].text != "=" {
        return None
      }
      let parsed = @json.parse(tokens[i + 2].text) catch { _ => return None }
      // MoonBit descriptor assignments are line-oriented. Reject a value with
      // trailing tokens instead of silently accepting a malformed manifest.
      if i + 3 < tokens.length() && tokens[i + 3].line == tokens[i + 2].line {
        return None
      }
      value = match parsed {
        Json::String(text) => Some(text)
        _ => return None
      }
      found = true
      i += 3
    } else if tokens[i].mate > i {
      i = tokens[i].mate + 1
    } else {
      i += 1
    }
  }
  value
}

///|
fn impact_mbt_text_name(source : String) -> String? {
  match impact_mbt_text_string(source, "name", None) {
    Some(name) if name != "" => Some(name)
    _ => None
  }
}

///|
/// Read imports from either manifest syntax. Skip comments and metadata
/// strings; reject malformed/unknown import forms instead of losing edges.
fn impact_mbt_manifest_imports(
  source : String,
  keyword : String,
) -> Array[String]? {
  if source.trim().has_prefix("{") {
    return impact_mbt_json_imports(source, keyword)
  }
  let tokens = match api_gate_lex(source) {
    Ok(tokens) => tokens
    Err(_) => return None
  }
  let specs : Array[String] = []
  let seen : Set[String] = Set([])
  let mut i = 0
  while i < tokens.length() {
    let mut j = i
    let matched = if keyword == "import" {
      tokens[i].kind == 0 &&
      tokens[i].text == "import" &&
      (i == 0 || tokens[i - 1].text != "-")
    } else {
      let prefix = if keyword == "test-import" { "test" } else { "wbtest" }
      if i + 2 < tokens.length() &&
        tokens[i].text == prefix &&
        tokens[i + 1].text == "-" &&
        tokens[i + 2].text == "import" {
        j = i + 2
        true
      } else {
        false
      }
    }
    if matched {
      j += 1
      if j >= tokens.length() || tokens[j].text != "{" {
        return None
      }
      let end = tokens[j].mate
      j += 1
      while j < end {
        let value = @json.parse(tokens[j].text) catch { _ => return None }
        let spec = match value {
          Json::String(path) if path != "" => path
          _ => return None
        }
        if !seen.contains(spec) {
          seen.add(spec)
          specs.push(spec)
        }
        j += 1
        if j < end && tokens[j].text == "@" {
          j += 1
          if j >= end || tokens[j].kind != 0 {
            return None
          }
          j += 1
          // Qualified aliases such as @encoding/utf8 and @immut/vector
          // are valid MoonBit package aliases; they do not add imports.
          while j < end && tokens[j].text == "/" {
            j += 1
            if j >= end || tokens[j].kind != 0 {
              return None
            }
            j += 1
          }
        }
        if j < end {
          if tokens[j].text != "," {
            return None
          }
          j += 1
        }
      }
      i = end + 1
    } else if tokens[i].mate > i {
      i = tokens[i].mate + 1
    } else {
      i += 1
    }
  }
  Some(specs)
}

///|
fn impact_mbt_json_imports(source : String, keyword : String) -> Array[String]? {
  let parsed = @json.parse(source, max_nesting_depth=32) catch {
    _ => return None
  }
  let entries = match parsed {
    Json::Object(obj) =>
      match obj.get(keyword) {
        None => return Some([])
        Some(Json::Array(entries)) => entries
        _ => return None
      }
    _ => return None
  }
  let specs : Array[String] = []
  let seen : Set[String] = Set([])
  for entry in entries {
    let path = match entry {
      Json::String(path) => path
      Json::Object(obj) =>
        match obj.get("path") {
          Some(Json::String(path)) => path
          _ => return None
        }
      _ => return None
    }
    if path == "" {
      return None
    }
    if !seen.contains(path) {
      seen.add(path)
      specs.push(path)
    }
  }
  Some(specs)
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
/// Read the source directory without changing the filesystem package keys.
/// Invalid/unsupported source values must fall back, never invent import edges.
fn impact_mbt_source_dir(
  module_dir : String,
  sources : Array[(String, String)],
) -> String? {
  let prefix = if module_dir == "" { "" } else { module_dir + "/" }
  for (path, source) in sources {
    if path != prefix + "moon.mod" && path != prefix + "moon.mod.json" {
      continue
    }
    let mut value = "."
    if path.has_suffix(".json") {
      let json = @json.parse(source, max_nesting_depth=8) catch {
        _ => return None
      }
      match json {
        Json::Object(obj) =>
          match obj.get("source") {
            None => ()
            Some(Json::String(dir)) => value = dir
            _ => return None
          }
        _ => return None
      }
    } else {
      value = match impact_mbt_text_string(source, "source", Some(".")) {
        Some(dir) => dir
        None => return None
      }
    }
    if value == "." || value == "" {
      return Some(module_dir)
    }
    let dir = normalize_relative(value) catch { _ => return None }
    if dir.contains("\\") {
      return None
    }
    return Some(prefix + dir)
  }
  None
}

///|
/// Build the package graph from the manifests found in membership.
fn impact_mbt_packages(
  membership : Set[String],
  modules : Array[(String, String)],
  sources : Array[(String, String)],
  workspaces~ : Array[ImpactMbtWorkspace] = [],
) -> (Array[ImpactMbtPackage], Array[ImpactIssue]) {
  let packages : Array[ImpactMbtPackage] = []
  let issues : Array[ImpactIssue] = []
  let manifests : Array[String] = []
  let source_by_path : Map[String, String] = Map([])
  for (path, text) in sources {
    source_by_path.set(path, text)
  }
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
    let source = match source_by_path.get(manifest) {
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
    let wbtest_imports = match
      impact_mbt_manifest_imports(source, "wbtest-import") {
      Some(specs) => specs
      None => {
        issues.push({
          file: manifest,
          line: 0,
          reason: "moonbit: package manifest wbtest-import block is malformed",
        })
        continue
      }
    }
    for spec in wbtest_imports {
      test_imports.push(spec)
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
    match impact_mbt_workspace_member_status(module_dir, workspaces) {
      Some(false) => continue
      _ => ()
    }
    if module_name == "" {
      issues.push({
        file: manifest,
        line: 0,
        reason: "moonbit: package belongs to an invalid module descriptor",
      })
      continue
    }
    let source_dir = match impact_mbt_source_dir(module_dir, sources) {
      Some(dir) => dir
      None => {
        issues.push({
          file: manifest,
          line: 0,
          reason: "moonbit: unsupported module source directory",
        })
        continue
      }
    }
    if source_dir != "" &&
      dir != source_dir &&
      !dir.has_prefix(source_dir + "/") {
      continue
    }
    let resolved : Array[String] = []
    let seen_imports : Set[String] = Set([])
    for spec in imports {
      match
        impact_mbt_local_import(
          spec, module_dir, module_name, source_dir, modules, workspaces, sources,
          manifest, issues,
        ) {
        Some(target) =>
          if !seen_imports.contains(target) {
            seen_imports.add(target)
            resolved.push(target)
          }
        None => ()
      }
    }
    let resolved_tests : Array[String] = []
    let seen_test_imports : Set[String] = Set([])
    for spec in test_imports {
      match
        impact_mbt_local_import(
          spec, module_dir, module_name, source_dir, modules, workspaces, sources,
          manifest, issues,
        ) {
        Some(target) =>
          if !seen_test_imports.contains(target) {
            seen_test_imports.add(target)
            resolved_tests.push(target)
          }
        None => ()
      }
    }
    packages.push({
      path: dir,
      imports: resolved,
      test_imports: resolved_tests,
      has_tests: false,
    })
  }
  // Count a test only for the package that owns it. This matches changed-file
  // ownership and prevents nested packages' tests inflating parent inventory.
  let package_paths : Set[String] = Set([])
  for item in packages {
    package_paths.add(item.path)
  }
  let tests_by_package : Set[String] = Set([])
  for path in membership.iter() {
    let inline_tests = match source_by_path.get(path) {
      Some(text) => impact_mbt_source_contains_tests(path, text)
      None => false
    }
    if path.has_suffix("_test.mbt") ||
      path.has_suffix("_wbtest.mbt") ||
      inline_tests {
      match impact_mbt_owner_in_module(path, package_paths, modules) {
        Some(owner) => tests_by_package.add(owner)
        None => ()
      }
    }
  }
  for i in 0..<packages.length() {
    let current = packages[i]
    packages[i] = {
      path: current.path,
      imports: current.imports,
      test_imports: current.test_imports,
      has_tests: tests_by_package.contains(current.path),
    }
  }
  (packages, issues)
}

///|
/// The package that owns a file: the nearest package directory ancestor. The
/// module root package ("") owns everything no other package claims. Walking
/// parent segments is boundary-safe ("pkg" never captures "pkg2") and avoids
/// scanning all packages for every test or changed input.
fn impact_mbt_owner(file : String, package_paths : Set[String]) -> String? {
  let mut dir = match file.rev_split_once("/") {
    Some((parent, _)) => parent.to_owned()
    None => ""
  }
  while dir != "" {
    if package_paths.contains(dir) {
      return Some(dir)
    }
    dir = match dir.rev_split_once("/") {
      Some((parent, _)) => parent.to_owned()
      None => ""
    }
  }
  if package_paths.contains("") {
    Some("")
  } else {
    None
  }
}

///|
/// Attribute a file only to a package in its nearest module. A parent
/// module-root package must not absorb files across a nested module boundary.
fn impact_mbt_owner_in_module(
  file : String,
  package_paths : Set[String],
  modules : Array[(String, String)],
) -> String? {
  let module_dir = match impact_mbt_module_of(impact_parent(file), modules) {
    Some((module_dir, _)) => module_dir
    None => return None
  }
  let owner = match impact_mbt_owner(file, package_paths) {
    Some(owner) => owner
    None => return None
  }
  match impact_mbt_module_of(owner, modules) {
    Some((owner_module, _)) if owner_module == module_dir => Some(owner)
    _ => None
  }
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
  name == "moon.work" ||
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
  impact_collect_paths(
    absolute,
    "",
    config,
    walk_paths,
    walk_issues,
    moonbit=true,
  )
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
      name == "moon.work" ||
      name == "moon.pkg" ||
      name == "moon.pkg.json" ||
      path.has_suffix(".mbt") ||
      path.has_suffix(".mbt.md") {
      try {
        if rooted_source_kind(absolute, path) != 1 {
          raise Failure("not a regular file")
        }
        let text = read_source(join_path(absolute, path))
        sources.push((path, text))
      } catch {
        error =>
          observed.push({
            file: path,
            line: 0,
            reason: "io: " + error_message(error),
          })
      }
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
  let workspaces = impact_mbt_workspaces(sources, modules, issues)
  impact_mbt_descriptor_issues(sources, modules, issues)
  let (packages, package_issues) = impact_mbt_packages(
    membership,
    modules,
    sources,
    workspaces~,
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
  let package_paths : Set[String] = Set([])
  let test_packages : Set[String] = Set([])
  for item in packages {
    package_paths.add(item.path)
    if item.has_tests {
      test_packages.add(item.path)
    }
  }
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
    match impact_mbt_module_of(impact_parent(path), modules) {
      Some((module_dir, _)) =>
        if impact_mbt_workspace_member_status(module_dir, workspaces)
          is Some(false) {
          reasons.push("unmodeled-changed-input: " + path)
          continue
        }
      None => ()
    }
    match impact_mbt_owner_in_module(path, package_paths, modules) {
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
    if !test_packages.contains(package) {
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
  let strategy = if blocked || (inventory.is_empty() && reasons.is_empty()) {
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
