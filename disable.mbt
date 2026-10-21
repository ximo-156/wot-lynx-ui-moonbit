///|
/// Inline disable comment parsing.
///
/// Supports the following directives in `//` line comments:
///
/// - `// moonlint-disable` — disable all rules from this line onward
/// - `// moonlint-disable rule-id ...` — disable specific rules from this line onward
/// - `// moonlint-disable-next-line` — disable all rules on the next line
/// - `// moonlint-disable-next-line rule-id ...` — disable specific rules on the next line
/// - `// moonlint-enable` — re-enable all rules from this line onward
/// - `// moonlint-enable rule-id ...` — re-enable specific rules from this line onward
///
/// Directives are parsed from the raw source before comments are stripped.

///|
/// A parsed set of inline disable directives for one file.
pub struct DisableMap {
  /// For each line, the set of disabled rule ids ("*" means all rules).
  /// Built by processing directives in order.
  line_state : Map[Int32, Set[String]]
  /// Rules disabled on a specific line only (disable-next-line).
  disabled_on : Map[Int32, Set[String]]
}

///|
/// Parse inline disable directives from raw source text.
/// Returns a `DisableMap` that can be queried per line and rule.
pub fn parse_disable_comments(source : String) -> DisableMap {
  let line_state : Map[Int32, Set[String]] = Map::new()
  let disabled_on : Map[Int32, Set[String]] = Map::new()
  // Running state: which rules are currently disabled
  let mut all_disabled = false
  let mut disabled_rules : Set[String] = Set([])
  let lines = source.split("\n")
  let mut lineno = 1
  for line_view in lines {
    let line = line_view.to_owned()
    let trimmed = line.trim().to_owned()
    // Record current state for this line
    let state : Set[String] = Set([])
    if all_disabled {
      state.add("*")
    }
    for id in disabled_rules {
      state.add(id)
    }
    line_state.set(lineno, state)
    // Parse directive
    if trimmed.has_prefix("//") {
      let comment = trimmed[2:].trim().to_owned()
      if comment.has_prefix("moonlint-disable-next-line") {
        let rest = comment["moonlint-disable-next-line".length():]
          .trim()
          .to_owned()
        let ids = parse_rule_ids(rest)
        add_to_map(disabled_on, lineno + 1, ids)
      } else if comment.has_prefix("moonlint-disable") {
        let rest = comment["moonlint-disable".length():].trim().to_owned()
        let ids = parse_rule_ids(rest)
        if ids.contains("*") {
          all_disabled = true
          disabled_rules = Set([])
        } else {
          for id in ids {
            disabled_rules.add(id)
          }
        }
      } else if comment.has_prefix("moonlint-enable") {
        let rest = comment["moonlint-enable".length():].trim().to_owned()
        let ids = parse_rule_ids(rest)
        if ids.contains("*") {
          all_disabled = false
          disabled_rules = Set([])
        } else {
          for id in ids {
            disabled_rules.remove(id)
          }
        }
      }
    }
    lineno += 1
  }
  { line_state, disabled_on, }
}

///|
/// Parse space-separated rule ids from a directive's remainder.
/// An empty string means "all rules" (represented as "*").
fn parse_rule_ids(rest : String) -> Set[String] {
  let ids : Set[String] = Set([])
  let trimmed = rest.trim().to_owned()
  if trimmed == "" {
    ids.add("*")
  } else {
    for id in trimmed.split(" ") {
      let id = id.trim().to_owned()
      if id != "" {
        ids.add(id)
      }
    }
  }
  ids
}

///|
/// Add rule ids to a map at a given line.
fn add_to_map(
  map : Map[Int32, Set[String]],
  line : Int32,
  ids : Set[String],
) -> Unit {
  match map.get(line) {
    Some(existing) =>
      for id in ids {
        existing.add(id)
      }
    None => map.set(line, ids)
  }
}

///|
/// Whether a rule is disabled at a given line.
pub fn DisableMap::is_disabled(
  self : DisableMap,
  rule_id : String,
  line : Int32,
) -> Bool {
  // Check line-specific disables (disable-next-line)
  match self.disabled_on.get(line) {
    Some(ids) => if ids.contains("*") || ids.contains(rule_id) { return true }
    None => ()
  }
  // Check range disables from the precomputed line state
  match self.line_state.get(line) {
    Some(ids) => ids.contains("*") || ids.contains(rule_id)
    None => false
  }
}
