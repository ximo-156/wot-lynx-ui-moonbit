///|
/// Rule configuration loading.
///
/// Rules are declared in a JSON file so the engine stays data-driven:
///
/// ```json
/// {
///   "include": ["src/**"],
///   "exclude": ["**/*.generated.ts"],
///   "rules": [
///     {
///       "id": "vue/import-from-vue",
///       "severity": "error",
///       "message": "must import from 'vue-lynx', not 'vue'",
///       "extensions": [".vue", ".ts"],
///       "include": ["src/components/**"],
///       "exclude": ["**/*.test.ts"],
///       "match": { "regex": "from\\s+['\"]vue['\"]" },
///       "unless": { "regex": "from\\s+['\"]vue-lynx['\"]" }
///     }
///   ]
/// }
/// ```
///
/// A `match` / `unless` object has exactly one of: `contains`, `prefix`,
/// `suffix`, `regex`.
///
/// `include` / `exclude` at the top level scope the whole run; the same keys
/// inside a rule scope that rule alone. Both accept root-relative glob
/// patterns.

///|
/// A configuration error with a human-readable message.
pub(all) suberror ConfigError {
  ConfigError(String)
}

///|
/// Parse a rules config from a JSON string.
pub fn parse_config(src : String) -> Result[LintConfig, ConfigError] {
  let json = @json.parse(src) catch {
    _ => return Err(ConfigError("config is not valid JSON"))
  }
  let obj = match json.as_object() {
    Some(o) => o
    None => return Err(ConfigError("config root must be a JSON object"))
  }
  let scope = match parse_scope(obj, "config") {
    Ok(scope) => scope
    Err(message) => return Err(ConfigError(message))
  }
  let rules : Array[Rule] = []
  match obj.get("rules") {
    Some(rules_json) => {
      let arr = match rules_json.as_array() {
        Some(a) => a
        None => return Err(ConfigError("\"rules\" must be an array"))
      }
      for (idx, rj) in arr.iter2() {
        let rule = match parse_rule(rj) {
          Ok(r) => r
          Err(ConfigError(msg)) =>
            return Err(ConfigError("rule #\{idx}: \{msg}"))
        }
        rules.push(rule)
      }
    }
    None =>
      // rules is optional when file_rules is present
      if !obj.contains("file_rules") {
        return Err(ConfigError("config missing \"rules\" array"))
      }
  }
  let file_rules = match parse_file_rules(obj) {
    Ok(fr) => fr
    Err(ConfigError(msg)) => return Err(ConfigError(msg))
  }
  // A duplicate id inside one file is a mistake: the later rule would be
  // silently shadowed. Reuse across `extends` is legitimate overriding, so
  // this check lives here rather than in the merge step.
  match check_duplicate_ids(rules, file_rules) {
    Some(message) => return Err(ConfigError(message))
    None => ()
  }
  Ok({ rules, file_rules, scope, })
}

///|
/// Report the first duplicated rule or file-rule id, if any.
fn check_duplicate_ids(
  rules : Array[Rule],
  file_rules : Array[FileRule],
) -> String? {
  let seen_rule : Set[String] = Set([])
  for rule in rules {
    if seen_rule.contains(rule.id) {
      return Some("duplicate rule id: \{rule.id}")
    }
    seen_rule.add(rule.id)
  }
  let seen_file : Set[String] = Set([])
  for fr in file_rules {
    if seen_file.contains(fr.id) {
      return Some("duplicate file_rule id: \{fr.id}")
    }
    seen_file.add(fr.id)
  }
  None
}

///|
/// Parse a config with `extends` support. The `extends` field can be a string
/// or array of strings pointing to other config files (relative to the config
/// file that declares them). Extended configs are loaded and merged: their
/// rules and file_rules are appended after the current config's, so the
/// current config takes precedence on id conflicts.
///
/// `config_dir` is the directory of the config file whose text is `src`; it is
/// used to resolve that file's relative `extends` paths.
pub fn parse_config_with_extends(
  src : String,
  config_dir : String,
) -> Result[LintConfig, ConfigError] {
  let visited : Set[String] = Set([])
  parse_config_with_extends_impl(src, config_dir, visited)
}

///|
/// Directory containing `path`, or "." when it has no separator.
fn parent_dir_of(path : String) -> String {
  match path.rev_split_once("/") {
    Some((dir, _)) => if dir == "" { "/" } else { dir.to_owned() }
    None => "."
  }
}

///|
/// Join a directory and a relative path, normalizing `./` and collapsing
/// redundant separators. Does not resolve `..` (the filesystem layer does).
fn join_path_parts(dir : String, path : String) -> String {
  if path.has_prefix("/") {
    return path
  }
  if dir == "" || dir == "." {
    return path
  }
  if dir.has_suffix("/") {
    "\{dir}\{path}"
  } else {
    "\{dir}/\{path}"
  }
}

///|
/// Recursive worker for `parse_config_with_extends`. `visited` holds the
/// canonical paths already loaded on the current chain, so a cyclic `extends`
/// reports an error instead of overflowing the stack.
fn parse_config_with_extends_impl(
  src : String,
  config_dir : String,
  visited : Set[String],
) -> Result[LintConfig, ConfigError] {
  let json = @json.parse(src) catch {
    _ => return Err(ConfigError("config is not valid JSON"))
  }
  let obj = match json.as_object() {
    Some(o) => o
    None => return Err(ConfigError("config root must be a JSON object"))
  }
  // Parse extends
  let extends_paths = match parse_extends(obj) {
    Ok(paths) => paths
    Err(message) => return Err(ConfigError(message))
  }
  // Load and merge extended configs
  let base_rules : Array[Rule] = []
  let base_file_rules : Array[FileRule] = []
  let mut base_scope = Scope::empty()
  for path in extends_paths {
    let full_path = join_path_parts(config_dir, path)
    let canonical = canonical_config_path(full_path)
    if visited.contains(canonical) {
      return Err(ConfigError("cyclic extends: \{canonical}"))
    }
    let ext_src = @fs.read_file_to_string(full_path) catch {
      _ => return Err(ConfigError("cannot read extended config: \{full_path}"))
    }
    // The extended config's own relative paths resolve against ITS directory,
    // not the top-level config's directory.
    let ext_dir = parent_dir_of(full_path)
    let ext_visited = clone_set(visited)
    ext_visited.add(canonical)
    let ext_config = match
      parse_config_with_extends_impl(ext_src, ext_dir, ext_visited) {
      Ok(c) => c
      Err(ConfigError(msg)) =>
        return Err(ConfigError("extends \{path}: \{msg}"))
    }
    for r in ext_config.rules {
      base_rules.push(r)
    }
    for fr in ext_config.file_rules {
      base_file_rules.push(fr)
    }
    if !ext_config.scope.is_empty() {
      base_scope = ext_config.scope
    }
  }
  // Parse current config
  let scope = match parse_scope(obj, "config") {
    Ok(scope) => scope
    Err(message) => return Err(ConfigError(message))
  }
  let current_rules : Array[Rule] = []
  match obj.get("rules") {
    Some(rules_json) => {
      let arr = match rules_json.as_array() {
        Some(a) => a
        None => return Err(ConfigError("\"rules\" must be an array"))
      }
      for (idx, rj) in arr.iter2() {
        let rule = match parse_rule(rj) {
          Ok(r) => r
          Err(ConfigError(msg)) =>
            return Err(ConfigError("rule #\{idx}: \{msg}"))
        }
        current_rules.push(rule)
      }
    }
    None =>
      if !obj.contains("file_rules") && extends_paths.is_empty() {
        return Err(ConfigError("config missing \"rules\" array"))
      }
  }
  let current_file_rules = match parse_file_rules(obj) {
    Ok(fr) => fr
    Err(ConfigError(msg)) => return Err(ConfigError(msg))
  }
  // Duplicates within THIS file are mistakes. Cross-file collisions are the
  // intended override mechanism, so only the local arrays are checked.
  match check_duplicate_ids(current_rules, current_file_rules) {
    Some(message) => return Err(ConfigError(message))
    None => ()
  }
  // Merge: base rules first, then current rules (dedup by id, current wins)
  let seen : Set[String] = Set([])
  let merged_rules : Array[Rule] = []
  for r in current_rules {
    if !seen.contains(r.id) {
      seen.add(r.id)
      merged_rules.push(r)
    }
  }
  for r in base_rules {
    if !seen.contains(r.id) {
      seen.add(r.id)
      merged_rules.push(r)
    }
  }
  let seen_fr : Set[String] = Set([])
  let merged_file_rules : Array[FileRule] = []
  for fr in current_file_rules {
    if !seen_fr.contains(fr.id) {
      seen_fr.add(fr.id)
      merged_file_rules.push(fr)
    }
  }
  for fr in base_file_rules {
    if !seen_fr.contains(fr.id) {
      seen_fr.add(fr.id)
      merged_file_rules.push(fr)
    }
  }
  // Use current scope if non-empty, otherwise base scope
  let final_scope = if scope.is_empty() { base_scope } else { scope }
  Ok({ rules: merged_rules, file_rules: merged_file_rules, scope: final_scope, })
}

///|
/// Canonical form of a config path, used as the cycle-detection key. Resolves
/// to an absolute path when possible so that `a.json` and `./a.json` collide.
fn canonical_config_path(path : String) -> String {
  let dir = canonical_root(parent_dir_of(path)) catch {
    _ => parent_dir_of(path)
  }
  join_path_parts(dir, base_name(path))
}

///|
/// Final path component of `path`.
fn base_name(path : String) -> String {
  match path.rev_split_once("/") {
    Some((_, name)) => name.to_owned()
    None => path
  }
}

///|
/// Shallow copy of a string set.
fn clone_set(s : Set[String]) -> Set[String] {
  let out : Set[String] = Set([])
  for item in s {
    out.add(item)
  }
  out
}

///|
/// Parse the `extends` field: a string or array of strings.
fn parse_extends(obj : Map[String, Json]) -> Result[Array[String], String] {
  match obj.get("extends") {
    None => Ok([])
    Some(v) =>
      match v {
        String(s) => Ok([s])
        Array(arr) => {
          let paths : Array[String] = []
          for item in arr {
            match item.as_string() {
              Some(s) => paths.push(s)
              None =>
                return Err("\"extends\" must be a string or array of strings")
            }
          }
          Ok(paths)
        }
        _ => Err("\"extends\" must be a string or array of strings")
      }
  }
}

///|
/// Parse the global or rule-level `include` / `exclude` scope.
fn parse_scope(
  obj : Map[String, Json],
  label : String,
) -> Result[Scope, String] {
  let includes = match get_str_array_field(obj, "include") {
    Ok(values) => values
    Err(message) => return Err("\{label}: \{message}")
  }
  let excludes = match get_str_array_field(obj, "exclude") {
    Ok(values) => values
    Err(message) => return Err("\{label}: \{message}")
  }
  match Scope::new(includes, excludes) {
    Ok(scope) => Ok(scope)
    Err(message) => Err("\{label}: \{message}")
  }
}

///|
/// Parse a single rule object.
fn parse_rule(rj : Json) -> Result[Rule, ConfigError] {
  let obj = match rj.as_object() {
    Some(o) => o
    None => return Err(ConfigError("rule must be an object"))
  }
  let id = match get_str(obj, "id") {
    Some(s) => s
    None => return Err(ConfigError("rule missing \"id\""))
  }
  let severity = match get_str(obj, "severity") {
    Some(s) => Severity::parse(s)
    None => Severity::Warning
  }
  let message = match get_str(obj, "message") {
    Some(s) => s
    None => return Err(ConfigError("rule \"\{id}\" missing \"message\""))
  }
  let extensions = match get_str_array(obj, "extensions") {
    Some(a) => a
    None => []
  }
  let scope = match parse_scope(obj, "rule \"\{id}\"") {
    Ok(scope) => scope
    Err(message) => return Err(ConfigError(message))
  }
  let match_json = match obj.get("match") {
    Some(m) => m
    None => return Err(ConfigError("rule \"\{id}\" missing \"match\""))
  }
  let match_kind = match parse_match_kind(match_json) {
    Ok(m) => m
    Err(ConfigError(msg)) => return Err(ConfigError("rule \"\{id}\": \{msg}"))
  }
  let unless = match obj.get("unless") {
    Some(uj) =>
      match parse_match_kind(uj) {
        Ok(m) => Some(m)
        Err(ConfigError(msg)) =>
          return Err(ConfigError("rule \"\{id}\": \{msg}"))
      }
    None => None
  }
  Ok({ id, severity, message, extensions, match_: match_kind, unless, scope, })
}

///|
/// Parse the optional `file_rules` array from the config object.
fn parse_file_rules(
  obj : Map[String, Json],
) -> Result[Array[FileRule], ConfigError] {
  let fr_json = match obj.get("file_rules") {
    Some(r) => r
    None => return Ok([])
  }
  let arr = match fr_json.as_array() {
    Some(a) => a
    None => return Err(ConfigError("\"file_rules\" must be an array"))
  }
  let rules : Array[FileRule] = []
  for (idx, rj) in arr.iter2() {
    let rule = match parse_file_rule(rj) {
      Ok(r) => r
      Err(ConfigError(msg)) =>
        return Err(ConfigError("file_rule #\{idx}: \{msg}"))
    }
    rules.push(rule)
  }
  Ok(rules)
}

///|
/// Parse a single file rule object.
fn parse_file_rule(rj : Json) -> Result[FileRule, ConfigError] {
  let obj = match rj.as_object() {
    Some(o) => o
    None => return Err(ConfigError("file_rule must be an object"))
  }
  let id = match get_str(obj, "id") {
    Some(s) => s
    None => return Err(ConfigError("file_rule missing \"id\""))
  }
  let severity = match get_str(obj, "severity") {
    Some(s) => Severity::parse(s)
    None => Severity::Warning
  }
  let message = match get_str(obj, "message") {
    Some(s) => s
    None => return Err(ConfigError("file_rule \"\{id}\" missing \"message\""))
  }
  let extensions = match get_str_array(obj, "extensions") {
    Some(a) => a
    None => []
  }
  let scope = match parse_scope(obj, "file_rule \"\{id}\"") {
    Ok(scope) => scope
    Err(message) => return Err(ConfigError(message))
  }
  let check_json = match obj.get("check") {
    Some(c) => c
    None => return Err(ConfigError("file_rule \"\{id}\" missing \"check\""))
  }
  let check = match parse_file_check(check_json) {
    Ok(c) => c
    Err(ConfigError(msg)) =>
      return Err(ConfigError("file_rule \"\{id}\": \{msg}"))
  }
  Ok({ id, severity, message, extensions, check, scope, })
}

///|
/// Parse a file check object: exactly one of max_lines / max_line_length /
/// no_trailing_whitespace / no_tabs / final_newline / no_duplicate_lines /
/// file_naming.
fn parse_file_check(cj : Json) -> Result[FileCheck, ConfigError] {
  let obj = match cj.as_object() {
    Some(o) => o
    None => return Err(ConfigError("check must be an object"))
  }
  if obj.contains("max_lines") {
    return match obj.get("max_lines") {
      Some(v) =>
        match v.as_number() {
          Some(n) => Ok(MaxLines(n.to_int()))
          None => Err(ConfigError("\"max_lines\" must be a number"))
        }
      None => Err(ConfigError("\"max_lines\" must be a number"))
    }
  }
  if obj.contains("max_line_length") {
    return match obj.get("max_line_length") {
      Some(v) =>
        match v.as_number() {
          Some(n) => Ok(MaxLineLength(n.to_int()))
          None => Err(ConfigError("\"max_line_length\" must be a number"))
        }
      None => Err(ConfigError("\"max_line_length\" must be a number"))
    }
  }
  if obj.contains("no_trailing_whitespace") {
    return Ok(NoTrailingWhitespace)
  }
  if obj.contains("no_tabs") {
    return Ok(NoTabs)
  }
  if obj.contains("final_newline") {
    return Ok(FinalNewline)
  }
  if obj.contains("no_duplicate_lines") {
    return Ok(NoDuplicateLines)
  }
  if obj.contains("file_naming") {
    return match get_str(obj, "file_naming") {
      Some(s) =>
        match NamingStyle::parse(s) {
          Some(style) => Ok(FileNaming(style))
          None =>
            Err(
              ConfigError(
                "\"file_naming\" must be one of: camelCase, PascalCase, snake_case, kebab-case",
              ),
            )
        }
      None => Err(ConfigError("\"file_naming\" must be a string"))
    }
  }
  if obj.contains("max_file_size") {
    return match obj.get("max_file_size") {
      Some(v) =>
        match v.as_number() {
          Some(n) => Ok(MaxFileSize(n.to_int()))
          None => Err(ConfigError("\"max_file_size\" must be a number"))
        }
      None => Err(ConfigError("\"max_file_size\" must be a number"))
    }
  }
  if obj.contains("no_empty_files") {
    return Ok(NoEmptyFiles)
  }
  if obj.contains("line_ending") {
    return match get_str(obj, "line_ending") {
      Some(s) =>
        match LineEndingStyle::parse(s) {
          Some(style) => Ok(LineEnding(style))
          None => Err(ConfigError("\"line_ending\" must be one of: lf, crlf"))
        }
      None => Err(ConfigError("\"line_ending\" must be a string"))
    }
  }
  if obj.contains("no_bom") {
    return Ok(NoBom)
  }
  Err(
    ConfigError(
      "check needs one of: max_lines, max_line_length, no_trailing_whitespace, no_tabs, final_newline, no_duplicate_lines, file_naming, max_file_size, no_empty_files, line_ending, no_bom",
    ),
  )
}

///|
/// Parse a matcher object: exactly one of contains / prefix / suffix / regex /
/// equals / word.
fn parse_match_kind(mj : Json) -> Result[MatchKind, ConfigError] {
  let obj = match mj.as_object() {
    Some(o) => o
    None => return Err(ConfigError("matcher must be an object"))
  }
  if obj.contains("regex") {
    return match get_str(obj, "regex") {
      Some(s) => Ok(Regex(s))
      None => Err(ConfigError("\"regex\" must be a string"))
    }
  }
  if obj.contains("contains") {
    return match get_str(obj, "contains") {
      Some(s) => Ok(Contains(s))
      None => Err(ConfigError("\"contains\" must be a string"))
    }
  }
  if obj.contains("prefix") {
    return match get_str(obj, "prefix") {
      Some(s) => Ok(HasPrefix(s))
      None => Err(ConfigError("\"prefix\" must be a string"))
    }
  }
  if obj.contains("suffix") {
    return match get_str(obj, "suffix") {
      Some(s) => Ok(HasSuffix(s))
      None => Err(ConfigError("\"suffix\" must be a string"))
    }
  }
  if obj.contains("equals") {
    return match get_str(obj, "equals") {
      Some(s) => Ok(Equals(s))
      None => Err(ConfigError("\"equals\" must be a string"))
    }
  }
  if obj.contains("word") {
    return match get_str(obj, "word") {
      Some(s) => Ok(Word(s))
      None => Err(ConfigError("\"word\" must be a string"))
    }
  }
  Err(
    ConfigError(
      "matcher needs one of: regex, contains, prefix, suffix, equals, word",
    ),
  )
}

///|
/// Validate that every rule's regex compiles. Returns the first error found.
pub fn validate_rules(rules : Array[Rule]) -> Result[Unit, ConfigError] {
  for rule in rules {
    match rule.match_.validate() {
      Some(err) => return Err(ConfigError("rule \"\{rule.id}\": \{err}"))
      None => ()
    }
    match rule.unless {
      Some(u) =>
        match u.validate() {
          Some(err) =>
            return Err(ConfigError("rule \"\{rule.id}\" (unless): \{err}"))
          None => ()
        }
      None => ()
    }
  }
  Ok(())
}

///|
/// Collect the union of all rule and file-rule extensions (for the default
/// scan set). An empty rule list keeps the scan set empty rather than scanning
/// every file.
pub fn collect_extensions(
  rules : Array[Rule],
  file_rules : Array[FileRule],
) -> Array[String] {
  if rules.any(rule => rule.extensions.is_empty()) ||
    file_rules.any(fr => fr.extensions.is_empty()) {
    return []
  }
  let exts : Array[String] = []
  for rule in rules {
    for e in rule.extensions {
      if not(exts.contains(e)) {
        exts.push(e)
      }
    }
  }
  for fr in file_rules {
    for e in fr.extensions {
      if not(exts.contains(e)) {
        exts.push(e)
      }
    }
  }
  exts
}

// ---------------------------------------------------------------------------
// JSON helpers — all return optionals, never raise.
// ---------------------------------------------------------------------------

///|
/// Read a string field from a JSON object, or `None` if absent / not a string.
fn get_str(obj : Map[String, Json], key : String) -> String? {
  match obj.get(key) {
    None => None
    Some(v) => v.as_string()
  }
}

///|
/// Read a string-array field from a JSON object, or `None` if absent / invalid.
fn get_str_array(obj : Map[String, Json], key : String) -> Array[String]? {
  let v = match obj.get(key) {
    Some(v) => v
    None => return None
  }
  let arr = match v.as_array() {
    Some(a) => a
    None => return None
  }
  let out : Array[String] = []
  for item in arr {
    match item.as_string() {
      Some(s) => out.push(s)
      None => return None
    }
  }
  Some(out)
}

///|
/// Read a string-array field that must be either absent or an array of
/// strings. Unlike `get_str_array` this distinguishes "absent" from
/// "present but malformed", so scope lists report a precise error.
fn get_str_array_field(
  obj : Map[String, Json],
  key : String,
) -> Result[Array[String], String] {
  let v = match obj.get(key) {
    Some(v) => v
    None => return Ok([])
  }
  let arr = match v.as_array() {
    Some(a) => a
    None => return Err("\"\{key}\" must be an array of strings")
  }
  let out : Array[String] = []
  for item in arr {
    match item.as_string() {
      Some(s) => out.push(s)
      None => return Err("\"\{key}\" must be an array of strings")
    }
  }
  Ok(out)
}
