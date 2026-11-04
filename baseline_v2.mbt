///|
/// A version-2, count-limited baseline of location-independent content keys.
/// Keys use rule id, file, severity, message, and the snippet with only its ends
/// trimmed. Line and column are excluded; internal and literal whitespace are
/// preserved. This is not semantic or ancestor identity: renamed declarations
/// invalidate keys when their names are present in the finding message.
/// Fingerprints use non-cryptographic FNV-1a and are not a security boundary.
pub struct BaselineV2 {
  priv entries : Array[BaselineV2Entry]
}

///|
priv struct BaselineV2Entry {
  key : String
  rule_id : String
  file : String
  mut count : Int32
  reason : String
  owner : String
  expires : String?
}

///|
/// Capture only the supplied findings as a version-2 baseline.
/// Equal content keys share an entry whose count limits future suppressions.
/// Requires nonblank reason/owner and a nullable, valid Gregorian YYYY-MM-DD
/// expiry (years 0001..9999). Expiry is not inferred from the current clock.
/// Reads no files, so findings from immutable Git blobs remain authoritative.
pub fn BaselineV2::capture(
  findings : Array[Finding],
  reason : String,
  owner : String,
  expires : String?,
) -> Result[BaselineV2, ConfigError] {
  Ok(baseline_v2_capture_impl(findings, reason, owner, expires)) catch {
    ConfigError(message) => Err(ConfigError(message))
  }
}

///|
/// Parse the strict version-2 `moonlint-content-v2` baseline JSON format.
/// Unknown or duplicate fields, duplicate keys, invalid positive integer
/// counts, blank reason/owner, malformed dates, and legacy arrays are errors.
/// An explicitly empty entries array is valid and suppresses nothing.
pub fn BaselineV2::parse(src : String) -> Result[BaselineV2, ConfigError] {
  Ok(baseline_v2_parse_impl(src)) catch {
    ConfigError(message) => Err(ConfigError(message))
  }
}

///|
/// Render a stable version-2 JSON document with entries sorted by key.
/// JSON escaping preserves metadata; nullable expiry is always emitted.
pub fn BaselineV2::render(self : BaselineV2) -> String {
  let entries = self.entries.copy()
  entries.sort_by((a, b) => a.key.lexical_compare(b.key))
  let values : Array[Json] = []
  for entry in entries {
    values.push({
      "key": Json::string(entry.key),
      "rule_id": Json::string(entry.rule_id),
      "file": Json::string(entry.file),
      "count": Json::number(entry.count.to_double()),
      "reason": Json::string(entry.reason),
      "owner": Json::string(entry.owner),
      "expires": match entry.expires {
        None => Json::null()
        Some(date) => Json::string(date)
      },
    })
  }
  let json : Json = {
    "version": 2,
    "fingerprint": "moonlint-content-v2",
    "entries": Json::array(values),
  }
  json.stringify(indent=2) + "\n"
}

///|
/// Partition findings into (remaining, suppressed, baseline-audit report).
/// Each unexpired key suppresses at most its stored count, preserving input
/// order in both arrays; copied findings cannot expand the old count budget.
/// `today` is an explicit valid Gregorian YYYY-MM-DD date. Expiry before today
/// does not suppress, while expiry equal to today remains valid.
/// Audit counts are suppressed, unused_entries, expired_entries, and
/// unused_occurrences (sum of positive count minus current match count).
/// Completely unmatched entries produce one unused issue; partially unused
/// budgets produce an unused-budget issue. Expiry and unused are independent
/// and may both be reported for one entry.
/// Audit issues have Error severity for an explicit audit gate. Ordinary lint
/// callers use remaining/suppressed and must not implicitly gate on audit.
pub fn BaselineV2::partition(
  self : BaselineV2,
  findings : Array[Finding],
  today : String,
) -> Result[(Array[Finding], Array[Finding], PolicyReport), ConfigError] {
  Ok(baseline_v2_partition_impl(self, findings, today)) catch {
    ConfigError(message) => Err(ConfigError(message))
  }
}

///|
fn baseline_v2_nonblank(
  value : String,
  label : String,
) -> Unit raise ConfigError {
  if value.trim() == "" || value.contains("\u{0}") {
    raise ConfigError("\{label} must be a nonblank string without NUL")
  }
}

///|
fn baseline_v2_validate_date(
  date : String,
  label : String,
) -> Unit raise ConfigError {
  let chars = date.to_array()
  if chars.length() != 10 || chars[4] != '-' || chars[7] != '-' {
    raise ConfigError("\{label} must be a valid Gregorian YYYY-MM-DD date")
  }
  for index in 0..<10 {
    if index != 4 && index != 7 && (chars[index] < '0' || chars[index] > '9') {
      raise ConfigError("\{label} must be a valid Gregorian YYYY-MM-DD date")
    }
  }
  let mut year = 0
  for index in 0..<4 {
    year = year * 10 + chars[index].to_int() - '0'.to_int()
  }
  let month = (chars[5].to_int() - '0'.to_int()) * 10 +
    chars[6].to_int() -
    '0'.to_int()
  let day = (chars[8].to_int() - '0'.to_int()) * 10 +
    chars[9].to_int() -
    '0'.to_int()
  if year == 0 || month < 1 || month > 12 || day < 1 {
    raise ConfigError("\{label} must be a valid Gregorian YYYY-MM-DD date")
  }
  let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
  let maximum = match month {
    1 | 3 | 5 | 7 | 8 | 10 | 12 => 31
    2 => if leap { 29 } else { 28 }
    _ => 30
  }
  if day > maximum {
    raise ConfigError("\{label} must be a valid Gregorian YYYY-MM-DD date")
  }
}

///|
fn baseline_v2_validate_expiry(
  expires : String?,
  label : String,
) -> Unit raise ConfigError {
  match expires {
    None => ()
    Some(date) => baseline_v2_validate_date(date, label)
  }
}

///|
fn baseline_v2_content(finding : Finding) -> String {
  let fields = [
    "moonlint-content-v2",
    finding.rule_id,
    finding.file,
    finding.severity.tag(),
    finding.message,
    finding.snippet.trim().to_owned(),
  ]
  fields.map(value => "\{value.length()}:\{value}").join("")
}

///|
fn baseline_v2_key(finding : Finding) -> String {
  fnv1a_hex(baseline_v2_content(finding))
}

///|
fn baseline_v2_capture_impl(
  findings : Array[Finding],
  reason : String,
  owner : String,
  expires : String?,
) -> BaselineV2 raise ConfigError {
  baseline_v2_nonblank(reason, "baseline reason")
  baseline_v2_nonblank(owner, "baseline owner")
  baseline_v2_validate_expiry(expires, "baseline expires")
  let by_key : Map[String, BaselineV2Entry] = Map([])
  let content_by_key : Map[String, String] = Map([])
  for finding in findings {
    baseline_v2_nonblank(finding.rule_id, "finding.rule_id")
    baseline_v2_nonblank(finding.file, "finding.file")
    let content = baseline_v2_content(finding)
    let key = fnv1a_hex(content)
    match by_key.get(key) {
      Some(entry) => {
        if content_by_key.get(key) != Some(content) {
          raise ConfigError(
            "baseline content fingerprint collision at key \{key}",
          )
        }
        if entry.count == 2147483647 {
          raise ConfigError("baseline count overflow at key \{key}")
        }
        entry.count += 1
      }
      None => {
        content_by_key[key] = content
        by_key[key] = {
          key,
          rule_id: finding.rule_id,
          file: finding.file,
          count: 1,
          reason,
          owner,
          expires,
        }
      }
    }
  }
  let entries : Array[BaselineV2Entry] = []
  for (_, entry) in by_key {
    entries.push(entry)
  }
  entries.sort_by((a, b) => a.key.lexical_compare(b.key))
  { entries, }
}

///|
fn baseline_v2_object(
  json : Json,
  label : String,
) -> Map[String, Json] raise ConfigError {
  match json {
    Object(obj) => obj
    _ => raise ConfigError("\{label} must be a JSON object")
  }
}

///|
fn baseline_v2_known_fields(
  obj : Map[String, Json],
  allowed : Array[String],
  label : String,
) -> Unit raise ConfigError {
  let unknown : Array[String] = []
  for (key, _) in obj {
    if !allowed.contains(key) {
      unknown.push(key)
    }
  }
  unknown.sort_by(String::lexical_compare)
  if !unknown.is_empty() {
    raise ConfigError("\{label}: unknown field \"\{unknown[0]}\"")
  }
}

///|
fn baseline_v2_required(
  obj : Map[String, Json],
  key : String,
  label : String,
) -> Json raise ConfigError {
  match obj.get(key) {
    Some(value) => value
    None => raise ConfigError("\{label}: missing \"\{key}\"")
  }
}

///|
fn baseline_v2_string(
  obj : Map[String, Json],
  key : String,
  label : String,
) -> String raise ConfigError {
  match baseline_v2_required(obj, key, label) {
    String(value) => value
    _ => raise ConfigError("\{label}.\{key} must be a string")
  }
}

///|
fn baseline_v2_integer(json : Json, label : String) -> Int32 raise ConfigError {
  let text = match json {
    Number(_, repr=Some(text)) => text
    _ => raise ConfigError("\{label} must be a nonnegative integer literal")
  }
  for c in text.iter() {
    if c < '0' || c > '9' {
      raise ConfigError("\{label} must be a nonnegative integer literal")
    }
  }
  @string.parse_int(text) catch {
    _ => raise ConfigError("\{label} integer is outside 0..2147483647")
  }
}

///|
fn baseline_v2_parse_impl(src : String) -> BaselineV2 raise ConfigError {
  let json = @json.parse(
    src,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    @json.DuplicateKey(_, key) =>
      raise ConfigError("baseline v2 contains duplicate JSON field \"\{key}\"")
    _ => raise ConfigError("baseline v2 is not valid JSON")
  }
  let obj = baseline_v2_object(json, "baseline v2")
  baseline_v2_known_fields(
    obj,
    ["version", "fingerprint", "entries"],
    "baseline v2",
  )
  let version = baseline_v2_integer(
    baseline_v2_required(obj, "version", "baseline v2"),
    "baseline.version",
  )
  if version != 2 {
    raise ConfigError("unsupported baseline version \{version}; expected 2")
  }
  if baseline_v2_string(obj, "fingerprint", "baseline v2") !=
    "moonlint-content-v2" {
    raise ConfigError("baseline fingerprint must be moonlint-content-v2")
  }
  let values = match baseline_v2_required(obj, "entries", "baseline v2") {
    Array(values) => values
    _ => raise ConfigError("baseline.entries must be an array")
  }
  let entries : Array[BaselineV2Entry] = []
  let seen : Set[String] = Set([])
  for (index, value) in values.iter2() {
    let label = "baseline.entries[\{index}]"
    let item = baseline_v2_object(value, label)
    baseline_v2_known_fields(
      item,
      ["key", "rule_id", "file", "count", "reason", "owner", "expires"],
      label,
    )
    let key = baseline_v2_string(item, "key", label)
    if key.length() != 16 ||
      !key.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
      raise ConfigError(
        "\{label}.key must be 16 lowercase hexadecimal characters",
      )
    }
    if seen.contains(key) {
      raise ConfigError("\{label}: duplicate baseline key \{key}")
    }
    seen.add(key)
    let rule_id = baseline_v2_string(item, "rule_id", label)
    let file = baseline_v2_string(item, "file", label)
    let reason = baseline_v2_string(item, "reason", label)
    let owner = baseline_v2_string(item, "owner", label)
    baseline_v2_nonblank(rule_id, "\{label}.rule_id")
    baseline_v2_nonblank(file, "\{label}.file")
    baseline_v2_nonblank(reason, "\{label}.reason")
    baseline_v2_nonblank(owner, "\{label}.owner")
    let count = baseline_v2_integer(
      baseline_v2_required(item, "count", label),
      "\{label}.count",
    )
    if count == 0 {
      raise ConfigError("\{label}.count must be positive")
    }
    let expires = match baseline_v2_required(item, "expires", label) {
      Null => None
      String(date) => Some(date)
      _ =>
        raise ConfigError(
          "\{label}.expires must be null or a valid YYYY-MM-DD date",
        )
    }
    baseline_v2_validate_expiry(expires, "\{label}.expires")
    entries.push({ key, rule_id, file, count, reason, owner, expires, })
  }
  entries.sort_by((a, b) => a.key.lexical_compare(b.key))
  { entries, }
}

///|
fn baseline_v2_expired(entry : BaselineV2Entry, today : String) -> Bool {
  match entry.expires {
    None => false
    Some(date) => date.lexical_compare(today) < 0
  }
}

///|
fn baseline_v2_audit_issue(
  entry : BaselineV2Entry,
  expired : Bool,
) -> PolicyIssue {
  {
    rule_id: if expired {
      "baseline/expired"
    } else {
      "baseline/unused"
    },
    severity: Severity::Error,
    message: if expired {
      "Baseline entry \{entry.key} expired before today"
    } else {
      "Baseline entry \{entry.key} matches no current finding"
    },
    details: {
      "key": entry.key,
      "rule": entry.rule_id,
      "file": entry.file,
      "reason": entry.reason,
      "owner": entry.owner,
      "expires": entry.expires.unwrap_or("null"),
      "count": entry.count.to_string(),
    },
  }
}

///|
fn baseline_v2_partition_impl(
  baseline : BaselineV2,
  findings : Array[Finding],
  today : String,
) -> (Array[Finding], Array[Finding], PolicyReport) raise ConfigError {
  baseline_v2_validate_date(today, "today")
  let by_key : Map[String, BaselineV2Entry] = Map([])
  for entry in baseline.entries {
    by_key[entry.key] = entry
  }
  let matched : Map[String, Int32] = Map([])
  let spent : Map[String, Int32] = Map([])
  let remaining : Array[Finding] = []
  let suppressed : Array[Finding] = []
  for finding in findings {
    let key = baseline_v2_key(finding)
    match by_key.get(key) {
      Some(entry) => {
        if entry.rule_id != finding.rule_id || entry.file != finding.file {
          remaining.push(finding)
          continue
        }
        matched[key] = matched.get(key).unwrap_or(0) + 1
        let used = spent.get(key).unwrap_or(0)
        if !baseline_v2_expired(entry, today) && used < entry.count {
          spent[key] = used + 1
          suppressed.push(finding)
        } else {
          remaining.push(finding)
        }
      }
      None => remaining.push(finding)
    }
  }
  let mut unused_entries = 0
  let mut expired_entries = 0
  let mut unused_occurrences = 0
  let issues : Array[PolicyIssue] = []
  let entries = baseline.entries.copy()
  entries.sort_by((a, b) => a.key.lexical_compare(b.key))
  for entry in entries {
    if baseline_v2_expired(entry, today) {
      expired_entries += 1
      issues.push(baseline_v2_audit_issue(entry, true))
    }
    let current_count = matched.get(entry.key).unwrap_or(0)
    let unused_count = if entry.count > current_count {
      entry.count - current_count
    } else {
      0
    }
    if unused_count > 2147483647 - unused_occurrences {
      raise ConfigError(
        "baseline unused_occurrences exceeds Int32 reporting range",
      )
    }
    unused_occurrences += unused_count
    if current_count == 0 {
      unused_entries += 1
      let issue = baseline_v2_audit_issue(entry, false)
      issue.details["unused_count"] = unused_count.to_string()
      issues.push(issue)
    } else if unused_count > 0 {
      let issue = baseline_v2_audit_issue(entry, false)
      issue.details["unused_count"] = unused_count.to_string()
      issues.push({
        rule_id: "baseline/unused-budget",
        severity: Severity::Error,
        message: "Baseline entry \{entry.key} has \{unused_count} unused suppression occurrences",
        details: issue.details,
      })
    }
  }
  let audit : PolicyReport = {
    mode: "baseline-audit",
    metadata: {
      "version": "2",
      "fingerprint": "moonlint-content-v2",
      "today": today,
      "coverage": "location-independent content keys; no semantic or ancestor identity; non-cryptographic FNV-1a",
    },
    counts: {
      "suppressed": suppressed.length(),
      "unused_entries": unused_entries,
      "expired_entries": expired_entries,
      "unused_occurrences": unused_occurrences,
    },
    issues,
  }
  (remaining, suppressed, audit)
}
