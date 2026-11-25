///|
/// A supported workspace has an explicit list of root-contained module paths.
/// Unsupported membership is uncertainty, never evidence for an empty graph.
priv struct ImpactMbtWorkspace {
  dir : String
  members : Array[String]
  valid_members : Bool
}

///|
fn impact_mbt_workspace_members(source : String) -> Array[String]? {
  let tokens = match api_gate_lex(source) {
    Ok(tokens) => tokens
    Err(_) => return None
  }
  let mut members : Array[String]? = None
  let mut i = 0
  while i < tokens.length() {
    if tokens[i].kind == 0 && tokens[i].text == "members" {
      if members is Some(_) ||
        i + 2 >= tokens.length() ||
        tokens[i + 1].text != "=" ||
        tokens[i + 2].text != "[" {
        return None
      }
      let end = tokens[i + 2].mate
      if end < i + 2 {
        return None
      }
      if end + 1 < tokens.length() && tokens[end + 1].line == tokens[end].line {
        return None
      }
      let paths : Array[String] = []
      i += 3
      while i < end {
        let parsed = @json.parse(tokens[i].text) catch { _ => return None }
        let raw = match parsed {
          Json::String(path) if path != "" => path
          _ => return None
        }
        let path = if raw == "." || raw == "./" {
          ""
        } else {
          normalize_relative(raw) catch {
            _ => return None
          }
        }
        if raw.contains("\\") ||
          raw.contains(":") ||
          raw.contains("*") ||
          raw.contains("?") ||
          raw.contains("[") ||
          raw.contains("]") ||
          raw.contains("\u{0}") ||
          paths.contains(path) {
          return None
        }
        paths.push(path)
        i += 1
        if i < end {
          if tokens[i].text != "," {
            return None
          }
          i += 1
        }
      }
      members = Some(paths)
      i = end + 1
    } else if tokens[i].mate > i {
      i = tokens[i].mate + 1
    } else {
      i += 1
    }
  }
  members
}

///|
/// A symlinked member directory must not turn an incomplete inventory into an
/// executable full plan. Check every member path component without following it.
fn impact_mbt_check_workspace_dirs(
  root : String,
  sources : Array[(String, String)],
  issues : Array[ImpactIssue],
) -> Unit {
  for (path, source) in sources {
    if path != "moon.work" && !path.has_suffix("/moon.work") {
      continue
    }
    let workspace_dir = impact_parent(path)
    let paths = match impact_mbt_workspace_members(source) {
      Some(value) => value
      None => continue
    }
    for member in paths {
      let joined = if workspace_dir == "" {
        member
      } else if member == "" {
        workspace_dir
      } else {
        workspace_dir + "/" + member
      }
      if joined == "" {
        continue
      }
      try {
        let mut current = root
        for segment in joined.split("/") {
          current = join_path(current, segment.to_owned())
          let kind = source_path_kind(current)
          if kind == 0 {
            break
          }
          if kind != 2 {
            issues.push({
              file: path,
              line: 0,
              reason: "unsafe: workspace member is not a regular directory: " +
              joined,
            })
            break
          }
        }
      } catch {
        error =>
          issues.push({
            file: path,
            line: 0,
            reason: "io: workspace member " +
            joined +
            ": " +
            error_message(error),
          })
      }
    }
  }
}

///|
fn impact_mbt_workspaces(
  sources : Array[(String, String)],
  modules : Array[(String, String)],
  issues : Array[ImpactIssue],
) -> Array[ImpactMbtWorkspace] {
  let workspaces : Array[ImpactMbtWorkspace] = []
  for (path, source) in sources {
    if path != "moon.work" && !path.has_suffix("/moon.work") {
      continue
    }
    let dir = impact_parent(path)
    let members : Array[String] = []
    let valid_members = match impact_mbt_workspace_members(source) {
      Some(paths) => {
        for member in paths {
          let joined = if dir == "" {
            member
          } else if member == "" {
            dir
          } else {
            dir + "/" + member
          }
          members.push(joined)
          if !modules.any(item => item.0 == joined) {
            issues.push({
              file: path,
              line: 0,
              reason: "moonbit: workspace member has no collected module descriptor: " +
              joined,
            })
          }
        }
        true
      }
      None => {
        issues.push({
          file: path,
          line: 0,
          reason: "moonbit: unsupported workspace members; expected explicit root-contained module directories",
        })
        false
      }
    }
    let names : Set[String] = Set([])
    for (module_dir, name) in modules {
      if members.contains(module_dir) && name != "" {
        if names.contains(name) {
          issues.push({
            file: path,
            line: 0,
            reason: "moonbit: ambiguous workspace module name: " + name,
          })
        }
        names.add(name)
      }
    }
    workspaces.push({ dir, members, valid_members, })
  }
  workspaces.sort_by((a, b) => impact_path_order(b.dir, a.dir))
  workspaces
}

///|
/// The nearest enclosing workspace controls a module. A non-member cannot
/// borrow membership from a more distant workspace.
fn impact_mbt_workspace_of(
  module_dir : String,
  workspaces : Array[ImpactMbtWorkspace],
) -> ImpactMbtWorkspace? {
  for workspace in workspaces {
    if workspace.dir == "" ||
      module_dir == workspace.dir ||
      module_dir.has_prefix(workspace.dir + "/") {
      return if workspace.members.contains(module_dir) {
        Some(workspace)
      } else {
        None
      }
    }
  }
  None
}

///|
/// Report whether an enclosing, well-formed workspace declares this module.
/// None means there is no usable enclosing membership declaration.
fn impact_mbt_workspace_member_status(
  module_dir : String,
  workspaces : Array[ImpactMbtWorkspace],
) -> Bool? {
  for workspace in workspaces {
    if workspace.dir == "" ||
      module_dir == workspace.dir ||
      module_dir.has_prefix(workspace.dir + "/") {
      if !workspace.valid_members {
        return None
      }
      return Some(workspace.members.contains(module_dir))
    }
  }
  None
}

///|
/// Resolve only demonstrably local imports. Collected modules outside the
/// importing module's workspace are possible local dependencies, so report
/// uncertainty rather than silently treating them as unrelated externals.
fn impact_mbt_local_import(
  spec : String,
  module_dir : String,
  module_name : String,
  source_dir : String,
  modules : Array[(String, String)],
  workspaces : Array[ImpactMbtWorkspace],
  sources : Array[(String, String)],
  manifest : String,
  issues : Array[ImpactIssue],
) -> String? {
  let workspace = impact_mbt_workspace_of(module_dir, workspaces)
  let mut best : (String, String)? = None
  let mut longest = -1
  let mut ambiguous = false
  let mut uncertain = false
  for (dir, name) in modules {
    if name == "" || !(spec == name || spec.has_prefix(name + "/")) {
      continue
    }
    let shared = match workspace {
      Some(group) =>
        group.members.contains(dir) &&
        impact_mbt_workspace_of(dir, workspaces) is Some(other) &&
        other.dir == group.dir
      None => false
    }
    if dir != module_dir && !shared {
      uncertain = true
      continue
    }
    if name.length() > longest {
      best = Some((dir, name))
      longest = name.length()
      ambiguous = false
    } else if name.length() == longest {
      ambiguous = true
    }
  }
  if ambiguous || (best is None && uncertain) {
    issues.push({
      file: manifest,
      line: 0,
      reason: "moonbit: local module import is ambiguous or lacks a shared workspace: " +
      spec,
    })
    return None
  }
  match best {
    Some((dir, name)) => {
      let target_source = if dir == module_dir {
        Some(source_dir)
      } else {
        impact_mbt_source_dir(dir, sources)
      }
      match target_source {
        Some(target) => impact_mbt_resolve(spec, name, target)
        None => {
          issues.push({
            file: manifest,
            line: 0,
            reason: "moonbit: imported module has an unsupported source directory: " +
            name,
          })
          None
        }
      }
    }
    None => impact_mbt_resolve(spec, module_name, source_dir)
  }
}

///|
fn impact_mbt_descriptor_issues(
  sources : Array[(String, String)],
  modules : Array[(String, String)],
  issues : Array[ImpactIssue],
) -> Unit {
  let seen : Set[String] = Set([])
  for (dir, name) in modules {
    let prefix = if dir == "" { "" } else { dir + "/" }
    let descriptor = if sources.any(item => item.0 == prefix + "moon.mod") {
      prefix + "moon.mod"
    } else {
      prefix + "moon.mod.json"
    }
    if name == "" || seen.contains(dir) {
      issues.push({
        file: descriptor,
        line: 0,
        reason: "moonbit: malformed or ambiguous module descriptor; module boundary retained",
      })
    }
    seen.add(dir)
  }
}
