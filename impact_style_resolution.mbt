///|
/// Stylesheets supported by the static dependency frontend. Other stylesheet
/// languages must not be silently treated as dependency-free data when loaded
/// as modules.
fn impact_style_extension(path : String) -> Bool {
  path.has_suffix(".css") || path.has_suffix(".scss")
}

///|
fn impact_any_style_extension(path : String) -> Bool {
  impact_style_extension(path) ||
  path.has_suffix(".sass") ||
  path.has_suffix(".less") ||
  path.has_suffix(".styl")
}

///|
fn impact_has_alias(spec : String, aliases : Array[(String, String)]) -> Bool {
  aliases.any(pair => {
    let raw = pair.0
    let prefix = if raw.has_suffix("/") {
      raw[:raw.length() - 1].to_owned()
    } else {
      raw
    }
    spec == prefix || spec.has_prefix(prefix + "/")
  })
}

///|
/// Query/fragment removal applies to CSS URLs only, never to file-read paths.
fn impact_style_url_path(spec : String) -> String {
  let chars = spec.to_array()
  for i in 0..<chars.length() {
    if chars[i] == '?' || chars[i] == '#' {
      return String::from_array(chars[:i])
    }
  }
  spec
}

///|
/// Candidate Sass filesystem modules. Multiple candidates remain ambiguous;
/// custom importers/load paths and legacy .import.scss precedence are not
/// guessed. Literal CSS paths are handled separately without extension probes.
fn impact_scss_candidates(base : String, paths : Set[String]) -> Array[String] {
  let candidates : Array[String] = []
  let parent = impact_parent(base)
  let name = match base.rev_split_once("/") {
    Some((_, name)) => name.to_owned()
    None => base
  }
  let in_parent = value => {
    if parent == "" {
      value
    } else {
      parent + "/" + value
    }
  }
  let mut proposed : Array[String] = [base]
  if base.has_suffix(".css") {
    // Explicit .css imports preserve CSS URL semantics and do not select a
    // Sass partial of another filename.
    proposed = [base]
  } else if base.has_suffix(".scss") || base.has_suffix(".sass") {
    if !name.has_prefix("_") {
      proposed.push(in_parent("_" + name))
    }
    let suffix = if base.has_suffix(".scss") { ".scss" } else { ".sass" }
    let stem = name[:name.length() - suffix.length()].to_owned()
    proposed.push(in_parent(stem + ".import" + suffix))
    proposed.push(in_parent("_" + stem + ".import" + suffix))
  } else {
    for ext in [".scss", ".sass", ".css"] {
      proposed.push(base + ext)
      if !name.has_prefix("_") {
        proposed.push(in_parent("_" + name + ext))
      }
      proposed.push(base + "/index" + ext)
      proposed.push(base + "/_index" + ext)
      proposed.push(base + ".import" + ext)
      proposed.push(in_parent("_" + name + ".import" + ext))
    }
  }
  for path in proposed {
    if paths.contains(path) && !candidates.contains(path) {
      candidates.push(path)
    }
  }
  candidates.sort()
  candidates
}

///|
/// Resolve static CSS/SCSS module and asset references without filesystem or
/// network access. Scoped Sass packages and sass: builtins are external inputs;
/// their versions are covered by the existing manifest/lockfile full triggers.
fn impact_resolve_style_reference(
  reference : ImpactReference,
  paths : Set[String],
  config : ImpactConfig,
  edges : Array[ImpactEdge],
  issues : Array[ImpactIssue],
) -> Unit {
  let spec = reference.specifier
  let lower = spec.to_lower()
  if spec.contains("#{") ||
    spec.contains("${") ||
    spec.contains("@{") ||
    spec.has_prefix("$") {
    impact_add_issue(issues, reference, "dynamic-style-path: " + spec)
    return
  }
  if reference.kind == "style-import-scss" &&
    (
      lower.has_prefix("http:") ||
      lower.has_prefix("https:") ||
      lower.has_prefix("data:") ||
      spec.has_prefix("#")
    ) {
    impact_add_issue(
      issues,
      reference,
      "unsupported-sass-url-reference: " + spec,
    )
    return
  }
  if lower.has_prefix("https://") ||
    lower.has_prefix("http://") ||
    spec.has_prefix("//") ||
    lower.has_prefix("data:") ||
    spec.has_prefix("#") {
    return
  }
  if lower.has_prefix("sass:") && reference.kind == "style-import-scss" {
    return
  }
  if spec == "" ||
    spec.contains("\\") ||
    spec.contains("%") ||
    spec.contains("\u{0}") ||
    spec.contains("#{") ||
    spec.contains("${") ||
    spec.contains("@{") ||
    spec.has_prefix("$") {
    impact_add_issue(issues, reference, "unsupported-style-path: " + spec)
    return
  }
  if spec.contains(":") {
    impact_add_issue(issues, reference, "unsupported-style-protocol: " + spec)
    return
  }
  if reference.kind == "style-import-scss" &&
    (spec.contains("?") || spec.contains("#")) {
    impact_add_issue(
      issues,
      reference,
      "unsupported-sass-import-query: " + spec,
    )
    return
  }
  let pathname = impact_style_url_path(spec)
  if pathname.has_prefix("/") {
    impact_add_issue(
      issues,
      reference,
      "root-relative-style-url-needs-mapping: " + spec,
    )
    return
  }
  let aliased = impact_has_alias(pathname, config.aliases)
  let base = if aliased {
    impact_alias(pathname, config.aliases)
  } else {
    impact_join_relative(impact_parent(reference.file), pathname)
  }
  let base = match base {
    Some(value) => value
    None => {
      impact_add_issue(
        issues,
        reference,
        "outside-root-style-reference: " + spec,
      )
      return
    }
  }
  let candidates = if reference.kind == "style-import-scss" {
    impact_scss_candidates(base, paths)
  } else if paths.contains(base) {
    [base]
  } else {
    []
  }
  if candidates.is_empty() &&
    !aliased &&
    reference.kind == "style-import-scss" &&
    pathname.has_prefix("@") &&
    !pathname.has_prefix("@/") &&
    pathname.split("/").to_array().length() >= 2 &&
    !pathname.split("/").any(segment => segment == "..") {
    // Do not reinterpret a configured alias that escaped the root as npm.
    return
  }
  if candidates.any(path => {
      path.contains(".import.scss") || path.contains(".import.sass")
    }) {
    impact_add_issue(
      issues,
      reference,
      "legacy-sass-importer-precedence: " + spec,
    )
    return
  }
  if candidates.length() != 1 {
    impact_add_issue(
      issues,
      reference,
      (if candidates.is_empty() {
        "unresolved-style-input: "
      } else {
        "ambiguous-style-input: "
      }) +
      spec,
    )
    return
  }
  let dependency = candidates[0]
  if reference.kind != "style-url" {
    if !impact_style_extension(dependency) {
      impact_add_issue(
        issues,
        reference,
        "unsupported-stylesheet-language: " + dependency,
      )
    }
    if !impact_in_scope(config, dependency) {
      impact_add_issue(
        issues,
        reference,
        "excluded-stylesheet-input: " + dependency,
      )
    }
  }
  edges.push({
    dependency,
    dependent: reference.file,
    kind: reference.kind,
    line: reference.line,
    column: reference.column,
  })
}
