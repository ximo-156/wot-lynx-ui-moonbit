///|
fn impact_source_extension(path : String) -> Bool {
  [".ts", ".tsx", ".js", ".jsx", ".mts", ".cts", ".mjs", ".cjs", ".vue"].any(ext => {
    path.has_suffix(ext)
  })
}

///|
fn impact_matches(patterns : Array[String], path : String) -> Bool {
  patterns.any(pattern => GlobPattern::new(pattern).matches_path(path))
}

///|
fn impact_in_scope(config : ImpactConfig, path : String) -> Bool {
  (config.includes.is_empty() || impact_matches(config.includes, path)) &&
  !impact_matches(config.excludes, path)
}

///|
/// Collapse relative module paths without clamping an escape above the root.
fn impact_join_relative(parent : String, child : String) -> String? {
  if child.has_prefix("/") || child.contains("\\") || child.contains("\u{0}") {
    return None
  }
  let parts : Array[String] = []
  for item in (parent + "/" + child).split("/") {
    let part = item.to_owned()
    if part == "" || part == "." {
      continue
    }
    if part == ".." {
      if parts.is_empty() {
        return None
      }
      ignore(parts.pop())
    } else {
      parts.push(part)
    }
  }
  Some(parts.join("/"))
}

///|
fn impact_parent(path : String) -> String {
  match path.rev_split_once("/") {
    Some((parent, _)) => parent.to_owned()
    None => ""
  }
}

///|
/// Use a path-segment boundary and the longest configured alias prefix.
fn impact_alias(spec : String, aliases : Array[(String, String)]) -> String? {
  let mut longest = -1
  let mut expanded : String? = None
  for (raw, target) in aliases {
    let prefix = if raw.has_suffix("/") {
      raw[:raw.length() - 1].to_owned()
    } else {
      raw
    }
    if spec == prefix || spec.has_prefix(prefix + "/") {
      if prefix.length() > longest {
        longest = prefix.length()
        let rest = if spec == prefix {
          ""
        } else {
          spec[prefix.length() + 1:].to_owned()
        }
        expanded = impact_join_relative(target, rest)
      }
    }
  }
  expanded
}

///|
/// All viable source paths, not a guess when multiple extension probes exist.
fn impact_module_candidates(
  base : String,
  paths : Set[String],
) -> Array[String] {
  if paths.contains(base) {
    return [base]
  }
  let candidates : Array[String] = []
  for
    (suffix, source_ext) in [(".js", ".ts"), (".mjs", ".mts"), (".cjs", ".cts")] {
    if base.has_suffix(suffix) {
      let path = base[:base.length() - suffix.length()].to_owned() + source_ext
      if paths.contains(path) {
        candidates.push(path)
      }
    }
  }
  for
    ext in [
      ".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs", ".vue", ".json",
    ] {
    for
      path in [
        base + ext,
        (if base == "" { "index" } else { base + "/index" }) + ext,
      ] {
      if paths.contains(path) && !candidates.contains(path) {
        candidates.push(path)
      }
    }
  }
  candidates
}

///|
fn impact_add_issue(
  issues : Array[ImpactIssue],
  reference : ImpactReference,
  reason : String,
) -> Unit {
  issues.push({ file: reference.file, line: reference.line, reason, })
}

///|
/// Convert a syntactic reference to an actual input edge. Unknown local paths
/// and unsupported transformations become explicit uncertainty, not no edge.
fn impact_resolve_reference(
  reference : ImpactReference,
  paths : Set[String],
  config : ImpactConfig,
  edges : Array[ImpactEdge],
  issues : Array[ImpactIssue],
) -> Unit {
  if reference.kind.has_prefix("style-") {
    impact_resolve_style_reference(reference, paths, config, edges, issues)
    return
  }
  let spec = reference.specifier
  let base = if reference.kind == "import" {
    if is_relative(spec) {
      impact_join_relative(impact_parent(reference.file), spec)
    } else {
      match impact_alias(spec, config.aliases) {
        Some(value) => Some(value)
        None => {
          if impact_has_alias(spec, config.aliases) {
            impact_add_issue(
              issues,
              reference,
              "outside-root-alias-reference: " + spec,
            )
            return
          }
          // npm packages are external inputs, governed by package/lockfile
          // changes. Typical unresolved local aliases are never ignored.
          if spec.has_prefix("@/") ||
            spec.has_prefix("~/") ||
            spec.has_prefix("#") ||
            spec.has_prefix("/") ||
            !impact_module_candidates(spec, paths).is_empty() {
            impact_add_issue(
              issues,
              reference,
              "unresolved-alias: configure a local alias for " + spec,
            )
          }
          return
        }
      }
    }
  } else if reference.kind == "read-file" {
    impact_join_relative(impact_parent(reference.file), spec)
  } else if reference.kind == "read-root" {
    impact_join_relative("", spec)
  } else {
    impact_add_issue(
      issues,
      reference,
      "unsupported-reference-kind: " + reference.kind,
    )
    return
  }
  let base = match base {
    Some(path) => path
    None => {
      impact_add_issue(issues, reference, "outside-root-reference: " + spec)
      return
    }
  }
  if reference.kind == "import" &&
    (spec.contains("?") || (spec.contains("#") && !spec.has_prefix("#"))) {
    impact_add_issue(issues, reference, "transformed-module-reference: " + spec)
    return
  }
  let candidates = if reference.kind == "import" {
    impact_module_candidates(base, paths)
  } else if paths.contains(base) {
    [base]
  } else {
    []
  }
  if candidates.length() != 1 {
    impact_add_issue(
      issues,
      reference,
      (if candidates.is_empty() {
        "unresolved-input: "
      } else {
        "ambiguous-input: "
      }) +
      spec,
    )
    return
  }
  let dependency = candidates[0]
  if reference.kind == "import" &&
    !impact_in_scope(config, dependency) &&
    (
      impact_source_extension(dependency) ||
      impact_any_style_extension(dependency)
    ) {
    impact_add_issue(issues, reference, "excluded-source-input: " + dependency)
  }
  if reference.kind == "import" &&
    impact_any_style_extension(dependency) &&
    !impact_style_extension(dependency) {
    impact_add_issue(
      issues,
      reference,
      "unsupported-stylesheet-language: " + dependency,
    )
  }
  edges.push({
    dependency,
    dependent: reference.file,
    kind: reference.kind,
    line: reference.line,
    column: reference.column,
  })
}

///|
fn impact_edge_key(edge : ImpactEdge) -> String {
  "\{edge.dependency}\u{0}\{edge.dependent}\u{0}\{edge.kind}\u{0}\{edge.line}\u{0}\{edge.column}"
}

///|
fn impact_unique_paths(paths : Array[String]) -> Array[String] raise {
  let seen : Set[String] = Set([])
  let result : Array[String] = []
  for path in paths {
    let clean = impact_path(path, false)
    if !seen.contains(clean) {
      seen.add(clean)
      result.push(clean)
    }
  }
  result.sort()
  result
}

///|
/// Pure test-plan construction from known files. Only dependencies discovered
/// under the documented adapters are considered proven; uncertainty requests
/// all inventory tests. This is not a whole-language semantic proof.
pub fn build_impact_plan(
  root : String,
  sources : Array[(String, String)],
  paths : Array[String],
  changes : Array[String],
  config : ImpactConfig,
  input : String,
  observations : Array[ImpactIssue],
) -> ImpactPlan raise {
  impact_validate_config(config)
  let changed = impact_unique_paths(changes)
  let membership = Set::from_iter(impact_unique_paths(paths).iter())
  let inventory = membership
    .iter()
    .filter(path => {
      impact_in_scope(config, path) && impact_matches(config.tests, path)
    })
    .to_array()
  inventory.sort()
  let issues = observations.copy()
  let raw_edges = config.dependencies.copy()
  let source_paths : Set[String] = Set([])
  for (path, source) in sources {
    let rel = impact_path(path, false)
    if !membership.contains(rel) {
      raise Failure("moonimpact: source missing from input membership: " + rel)
    }
    if !impact_in_scope(config, rel) {
      continue
    }
    if source_paths.contains(rel) {
      raise Failure("moonimpact: duplicate source: " + rel)
    }
    source_paths.add(rel)
    let (references, unsupported) = if impact_style_extension(rel) {
      impact_extract_style_references(
        rel,
        source,
        if rel.has_suffix(".scss") {
          "scss"
        } else {
          "css"
        },
        1,
        1,
      )
    } else if impact_any_style_extension(rel) {
      (
        [],
        [
          {
            file: rel,
            line: 1,
            reason: "unsupported-stylesheet-language: only CSS and SCSS are analyzed",
          },
        ],
      )
    } else {
      impact_extract_references(rel, source, config.file_readers)
    }
    for issue in unsupported {
      issues.push(issue)
    }
    for reference in references {
      impact_resolve_reference(reference, membership, config, raw_edges, issues)
    }
  }
  for edge in config.dependencies {
    if !membership.contains(edge.dependent) ||
      !membership.contains(edge.dependency) {
      issues.push({
        file: edge.dependent,
        line: 0,
        reason: "unresolved-explicit-dependency: " + edge.dependency,
      })
    }
  }
  // Styles loaded as modules require their own parsed body to include
  // transitive imports/assets. A raw file read is intentionally a leaf: tests
  // inspecting a config/source file as text do not execute that file's imports.
  for edge in raw_edges {
    if (edge.kind == "import" || edge.kind.has_prefix("style-import")) &&
      impact_style_extension(edge.dependency) &&
      impact_in_scope(config, edge.dependency) &&
      !source_paths.contains(edge.dependency) {
      issues.push({
        file: edge.dependent,
        line: edge.line,
        reason: "style-source-not-analyzed: " + edge.dependency,
      })
    }
  }
  for test_file in inventory {
    if !source_paths.contains(test_file) || !impact_source_extension(test_file) {
      issues.push({
        file: test_file,
        line: 0,
        reason: "io: test file was not successfully analyzed",
      })
    }
  }
  raw_edges.sort_by((a, b) => impact_edge_key(a).compare(impact_edge_key(b)))
  let edges : Array[ImpactEdge] = []
  let edge_keys : Set[String] = Set([])
  let reverse : Map[String, Array[ImpactEdge]] = Map([])
  for edge in raw_edges {
    let key = impact_edge_key(edge)
    if !edge_keys.contains(key) {
      edge_keys.add(key)
      edges.push(edge)
      let outgoing = reverse.get(edge.dependency).unwrap_or([])
      outgoing.push(edge)
      reverse.set(edge.dependency, outgoing)
    }
  }
  // Multi-source BFS gives one deterministic shortest witness per test and
  // terminates even in cyclic dependency graphs.
  let origins : Map[String, String] = Map([])
  let parent : Map[String, ImpactEdge] = Map([])
  let queue = changed.copy()
  for path in changed {
    origins.set(path, path)
  }
  let mut head = 0
  while head < queue.length() {
    let path = queue[head]
    head += 1
    for edge in reverse.get(path).unwrap_or([]) {
      if !origins.contains(edge.dependent) {
        origins.set(edge.dependent, origins.get(path).unwrap_or(path))
        parent.set(edge.dependent, edge)
        queue.push(edge.dependent)
      }
    }
  }
  let affected = origins.keys().to_array()
  affected.sort()
  let traces : Array[ImpactTrace] = []
  let related : Array[String] = []
  for test_file in inventory {
    match origins.get(test_file) {
      Some(origin) => {
        let backwards : Array[ImpactEdge] = []
        let mut path = test_file
        while path != origin {
          match parent.get(path) {
            Some(edge) => {
              backwards.push(edge)
              path = edge.dependency
            }
            None => break
          }
        }
        let chain : Array[ImpactEdge] = []
        for i = backwards.length() - 1; i >= 0; i = i - 1 {
          chain.push(backwards[i])
        }
        related.push(test_file)
        traces.push({ test_file, changed: origin, chain, })
      }
      None => ()
    }
  }
  let reasons : Array[String] = []
  for path in changed {
    if impact_matches(config.global_inputs, path) {
      reasons.push("global-input-changed: " + path)
    }
    if !membership.contains(path) {
      reasons.push(
        "removed-or-missing-input: " +
        path +
        "; historical dependencies are not inferred",
      )
    } else if !impact_in_scope(config, path) {
      reasons.push("changed-outside-configured-scope: " + path)
    } else if (!source_paths.contains(path) || !impact_source_extension(path)) &&
      !reverse.contains(path) &&
      !inventory.contains(path) {
      reasons.push("unmodeled-changed-input: " + path)
    }
  }
  let issue_keys : Set[String] = Set([])
  let unique_issues : Array[ImpactIssue] = []
  for issue in issues {
    let key = "\{issue.file}\u{0}\{issue.line}\u{0}\{issue.reason}"
    if !issue_keys.contains(key) {
      issue_keys.add(key)
      unique_issues.push(issue)
    }
  }
  unique_issues.sort_by((a, b) => {
    let order = a.file.compare(b.file)
    if order != 0 {
      order
    } else if a.line != b.line {
      a.line.compare(b.line)
    } else {
      a.reason.compare(b.reason)
    }
  })
  if !unique_issues.is_empty() {
    reasons.push("uncertain-dependencies: full inventory required; see issues")
  }
  let blocked = unique_issues.any(issue => {
    issue.reason.has_prefix("io:") || issue.reason.has_prefix("unsafe:")
  })
  let strategy = if changed.is_empty() {
    reasons.clear()
    reasons.push("no-changes: no test execution requested")
    "none"
  } else if blocked || inventory.is_empty() {
    if inventory.is_empty() {
      reasons.push(
        "no-test-inventory: check the configured tests/include/exclude patterns",
      )
    }
    "blocked"
  } else if !reasons.is_empty() {
    "full"
  } else if related.is_empty() {
    reasons.push(
      "no-known-related-tests: no path was found under the supported dependency model",
    )
    "none"
  } else {
    "related"
  }
  {
    root,
    input,
    changed,
    strategy,
    tests: if strategy == "full" {
      inventory.copy()
    } else if strategy == "related" {
      related
    } else {
      []
    },
    inventory,
    affected,
    traces,
    issues: unique_issues,
    reasons,
    source_count: source_paths.length(),
    edge_count: edges.length(),
  }
}

///|
/// Descend only into directories that could contain a configured include.
fn impact_may_descend(config : ImpactConfig, dir : String) -> Bool {
  if impact_matches(config.excludes, dir) {
    return false
  }
  if config.includes.is_empty() {
    return true
  }
  config.includes.any(pattern => {
    let prefix : Array[String] = []
    for segment in pattern.split("/") {
      if segment.contains("*") || segment.contains("?") {
        break
      }
      prefix.push(segment.to_owned())
    }
    let fixed = prefix.join("/")
    fixed == "" ||
    fixed == dir ||
    fixed.has_prefix(dir + "/") ||
    dir.has_prefix(fixed + "/")
  })
}

///|
fn impact_collect_paths(
  root : String,
  dir : String,
  config : ImpactConfig,
  paths : Array[String],
  issues : Array[ImpactIssue],
) -> Unit raise {
  let directory = if dir == "" { root } else { join_path(root, dir) }
  let entries = @fs.read_dir(directory)
  for name in entries {
    if skip_dirs().contains(name) {
      continue
    }
    let rel = if dir == "" { name } else { dir + "/" + name }
    let kind = source_path_kind(join_path(root, rel))
    if kind == 2 {
      if impact_may_descend(config, rel) {
        impact_collect_paths(root, rel, config, paths, issues)
      }
    } else if kind == 1 {
      paths.push(rel)
    } else if impact_in_scope(config, rel) {
      issues.push({
        file: rel,
        line: 0,
        reason: "unsafe: symlink or non-regular input is not followed",
      })
    }
  }
}

///|
/// Read a live working tree without following links and make an advisory plan.
/// No project command or dependency installation is performed. Source read
/// failures block execution; unsupported syntax requests a full regression.
pub fn impact_plan(
  root : String,
  changed : Array[String],
  config : ImpactConfig,
  input : String,
  observations : Array[ImpactIssue],
) -> ImpactPlan raise {
  impact_validate_config(config)
  let absolute = canonical_root(root)
  let normalized = impact_unique_paths(changed)
  if normalized.is_empty() {
    return build_impact_plan(absolute, [], [], [], config, input, [])
  }
  let paths : Array[String] = []
  let sources : Array[(String, String)] = []
  let issues = observations.copy()
  impact_collect_paths(absolute, "", config, paths, issues)
  paths.sort()
  for path in paths {
    if !impact_in_scope(config, path) ||
      (!impact_source_extension(path) && !impact_any_style_extension(path)) {
      continue
    }
    try {
      if rooted_source_kind(absolute, path) != 1 {
        raise Failure("source changed or is no longer a regular file")
      }
      let bytes = @fs.read_file_to_bytes(join_path(absolute, path))
      if bytes.length() > config.max_source_bytes {
        issues.push({
          file: path,
          line: 0,
          reason: "source-size-limit: exceeds max_source_bytes",
        })
        continue
      }
      let source = @utf8.decode(bytes[:], ignore_bom=false) catch {
        _ => raise Failure("source is not valid UTF-8")
      }
      if source.contains("\u{0}") {
        raise Failure("source contains a binary NUL")
      }
      sources.push((path, source))
    } catch {
      error =>
        issues.push({
          file: path,
          line: 0,
          reason: "io: " + error_message(error),
        })
    }
  }
  build_impact_plan(absolute, sources, paths, normalized, config, input, issues)
}
