///|
fn config_fields(
  obj : Map[String, Json],
  allowed : Array[String],
  label : String,
) -> String? {
  for (key, _) in obj {
    if !allowed.contains(key) {
      let hint = if key == "scope" {
        "; use include/exclude directly, not nested scope"
      } else {
        ""
      }
      return Some("\{label}: unknown field '\{key}'\{hint}")
    }
  }
  None
}

///|
fn config_severity(obj : Map[String, Json]) -> Result[Severity, ConfigError] {
  match obj.get("severity") {
    None => Ok(Severity::Warning)
    Some(value) =>
      match value.as_string() {
        Some("error") => Ok(Severity::Error)
        Some("warning") => Ok(Severity::Warning)
        _ => Err(ConfigError("severity must be error or warning"))
      }
  }
}

///|
fn config_extensions(
  obj : Map[String, Json],
) -> Result[Array[String], ConfigError] {
  let values = match get_str_array_field(obj, "extensions") {
    Ok(values) => values
    Err(message) => return Err(ConfigError(message))
  }
  for value in values {
    if value.is_empty() ||
      value.contains("/") ||
      value.contains("\\") ||
      value.trim().to_owned() != value {
      return Err(
        ConfigError(
          "extensions must contain nonempty extension strings without paths or whitespace",
        ),
      )
    }
  }
  Ok(values)
}

///|
fn config_check_integer(
  value : Json,
  key : String,
) -> Result[Int32, ConfigError] {
  let n = match value.as_number() {
    Some(n) => n
    None => return Err(ConfigError("\{key} must be a non-negative integer"))
  }
  if !(n >= 0.0 && n <= 2147483647.0) || n.to_int().to_double() != n {
    return Err(
      ConfigError("\{key} must be a non-negative integer in Int32 range"),
    )
  }
  Ok(n.to_int())
}

///|
fn config_one_field(obj : Map[String, Json], label : String) -> String? {
  let mut count = 0
  for (_, _) in obj {
    count += 1
  }
  if count != 1 {
    Some("\{label} must contain exactly one field")
  } else {
    None
  }
}
