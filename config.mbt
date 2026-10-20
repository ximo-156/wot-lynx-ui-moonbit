///|
/// Rule configuration loading.
///
/// Rules are declared in a JSON file so the engine stays data-driven:
///
/// ```json
/// {
///   "rules": [
///     {
///       "id": "vue/import-from-vue",
///       "severity": "error",
///       "message": "must import from 'vue-lynx', not 'vue'",
///       "extensions": [".vue", ".ts"],
///       "match": { "regex": "from\\s+['\"]vue['\"]" },
///       "unless": { "regex": "from\\s+['\"]vue-lynx['\"]" }
///     }
///   ]
/// }
/// ```
///
/// A `match` / `unless` object has exactly one of: `contains`, `prefix`,
/// `suffix`, `regex`.

///|
/// A configuration error with a human-readable message.
pub(all) suberror ConfigError {
  ConfigError(String)
}

///|
/// Parse a rules config from a JSON string.
pub fn parse_config(src : String) -> Result[Array[Rule], ConfigError] {
  let json = @json.parse(src) catch {
    _ => return Err(ConfigError("config is not valid JSON"))
  }
  let obj = match json.as_object() {
    Some(o) => o
    None => return Err(ConfigError("config root must be a JSON object"))
  }
  let rules_json = match obj.get("rules") {
    Some(r) => r
    None => return Err(ConfigError("config missing \"rules\" array"))
  }
  let arr = match rules_json.as_array() {
    Some(a) => a
    None => return Err(ConfigError("\"rules\" must be an array"))
  }
  let rules : Array[Rule] = []
  for (idx, rj) in arr.iter2() {
    let rule = match parse_rule(rj) {
      Ok(r) => r
      Err(ConfigError(msg)) => return Err(ConfigError("rule #\{idx}: \{msg}"))
    }
    rules.push(rule)
  }
  Ok(rules)
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
  Ok({ id, severity, message, extensions, match_: match_kind, unless, })
}

///|
/// Parse a matcher object: exactly one of contains / prefix / suffix / regex.
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
  Err(ConfigError("matcher needs one of: regex, contains, prefix, suffix"))
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
/// Collect the union of all rule extensions (for the default scan set).
pub fn collect_extensions(rules : Array[Rule]) -> Array[String] {
  if rules.any(rule => rule.extensions.is_empty()) {
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
