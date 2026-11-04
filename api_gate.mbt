///|
/// Make a strict version-1 JSON snapshot of a compiler-generated MoonBit
/// interface. The package comes from its `package` line; toolchain is recorded
/// exactly and backend is native, js, wasm, wasm-gc, or llvm. Toolchain and module
/// version must not be blank. Unsupported/malformed public syntax is inconclusive.
///
/// Only exports present in the supplied interface are covered: omitted
/// `#doc(hidden)` extensions, private implementation, behavior, and ABI are not.
pub fn make_api_snapshot(
  interface_text : String,
  toolchain : String,
  backend : String,
  module_version : String,
) -> Result[String, ConfigError] {
  match api_gate_validate_metadata(toolchain, backend, module_version) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let surface = match api_gate_parse_interface(interface_text) {
    Ok(surface) => surface
    Err(error) => return Err(error)
  }
  let fields : Map[String, Json] = Map([])
  fields.set("version", Json::number(1.0))
  fields.set("package", Json::string(surface.package_name))
  fields.set("toolchain", Json::string(toolchain))
  fields.set("backend", Json::string(backend))
  fields.set("module_version", Json::string(module_version))
  fields.set("interface", Json::string(interface_text))
  Ok(Json::object(fields).stringify(indent=2))
}

///|
/// Compare strict v1 snapshots with identical package/toolchain/backend metadata.
/// Removals and signature/type-shape changes require review; standalone additions
/// are counted without errors. Ignore comments, whitespace, declaration/member
/// order, implementation bodies, and equivalent old/new derive display styles.
///
/// Policy `none` reports review findings as errors without interpreting versions.
/// Explicit `semver` permits warnings after a major increase for stable releases,
/// or minor/major increase for 0.x; insufficient bumps add a blocking policy issue.
/// Versions must be three non-leading-zero Int32 components. Prerelease/build
/// metadata is deliberately inconclusive. Unsupported syntax, unknown policy,
/// malformed snapshots, or mismatched identity metadata return ConfigError.
pub fn check_api_snapshots(
  before_src : String,
  after_src : String,
  version_policy : String,
) -> Result[PolicyReport, ConfigError] {
  if version_policy != "none" && version_policy != "semver" {
    return Err(ConfigError("unknown API version policy: \{version_policy}"))
  }
  let before = match api_gate_parse_snapshot(before_src) {
    Ok(snapshot) => snapshot
    Err(ConfigError(message)) =>
      return Err(ConfigError("before snapshot: \{message}"))
  }
  let after = match api_gate_parse_snapshot(after_src) {
    Ok(snapshot) => snapshot
    Err(ConfigError(message)) =>
      return Err(ConfigError("after snapshot: \{message}"))
  }
  for
    (key, old_value, new_value) in [
      ("package", before.package_name, after.package_name),
      ("toolchain", before.toolchain, after.toolchain),
      ("backend", before.backend, after.backend),
    ] {
    if old_value != new_value {
      return Err(
        ConfigError(
          "API snapshot \{key} mismatch: \{old_value} != \{new_value}",
        ),
      )
    }
  }
  let mut sufficient_bump = false
  if version_policy == "semver" {
    let old_version = match api_gate_parse_semver(before.module_version) {
      Ok(version) => version
      Err(error) => return Err(error)
    }
    let new_version = match api_gate_parse_semver(after.module_version) {
      Ok(version) => version
      Err(error) => return Err(error)
    }
    sufficient_bump = if old_version.major == 0 {
      new_version.major > 0 ||
      (new_version.major == 0 && new_version.minor > old_version.minor)
    } else {
      new_version.major > old_version.major
    }
  }
  let severity = if sufficient_bump {
    Severity::Warning
  } else {
    Severity::Error
  }
  let issues : Array[PolicyIssue] = []
  let old_keys = before.surface.exports.keys().to_array()
  let new_keys = after.surface.exports.keys().to_array()
  old_keys.sort_by((left, right) => left.lexical_compare(right))
  new_keys.sort_by((left, right) => left.lexical_compare(right))
  let mut removed = 0
  let mut changed = 0
  let mut added = 0
  for symbol in old_keys {
    let old_decl = before.surface.exports.get(symbol).unwrap()
    match after.surface.exports.get(symbol) {
      None => {
        removed += 1
        issues.push(
          api_gate_review_issue(
            before.package_name,
            symbol,
            "removed",
            old_decl,
            None,
            severity,
          ),
        )
      }
      Some(new_decl) =>
        if old_decl.canonical != new_decl.canonical {
          changed += 1
          issues.push(
            api_gate_review_issue(
              before.package_name,
              symbol,
              "changed",
              old_decl,
              Some(new_decl),
              severity,
            ),
          )
        }
    }
  }
  for symbol in new_keys {
    if !before.surface.exports.contains(symbol) {
      added += 1
    }
  }
  if version_policy == "semver" && removed + changed > 0 && !sufficient_bump {
    let details : Map[String, String] = Map([])
    details.set("package", before.package_name)
    details.set("change", "insufficient-version-bump")
    details.set("before", before.module_version)
    details.set("after", after.module_version)
    details.set(
      "required",
      if before.module_version.has_prefix("0.") {
        "minor or major increase for a 0.x release"
      } else {
        "major increase for a stable release"
      },
    )
    issues.push({
      rule_id: "api/version-policy",
      severity: Severity::Error,
      message: "API review findings require a sufficient explicit semver release bump",
      details,
    })
  }
  issues.sort_by((left, right) => {
    (left.rule_id + ":" + left.details.get("symbol").unwrap_or("")).lexical_compare(
      right.rule_id + ":" + right.details.get("symbol").unwrap_or(""),
    )
  })
  let metadata : Map[String, String] = Map([])
  metadata.set("package", before.package_name)
  metadata.set("toolchain", before.toolchain)
  metadata.set("backend", before.backend)
  metadata.set("before_version", before.module_version)
  metadata.set("after_version", after.module_version)
  metadata.set("version_policy", version_policy)
  metadata.set(
    "coverage", "supported .mbti exports only; excludes private/internal descriptors, omitted #doc(hidden) extensions, behavior and ABI; unsupported syntax is inconclusive",
  )
  let counts : Map[String, Int32] = Map([])
  counts.set("exports_before", old_keys.length())
  counts.set("exports_after", new_keys.length())
  counts.set("added", added)
  counts.set("removed", removed)
  counts.set("changed", changed)
  Ok({ mode: "api-check", metadata, counts, issues, })
}

///|
priv struct ApiGateDeclaration {
  canonical : String
  line : Int32
}

///|
priv struct ApiGateSurface {
  package_name : String
  exports : Map[String, ApiGateDeclaration]
}

///|
priv struct ApiGateSnapshot {
  package_name : String
  toolchain : String
  backend : String
  module_version : String
  surface : ApiGateSurface
}

///|
priv struct ApiGateVersion {
  major : Int32
  minor : Int32
}

///|
fn api_gate_validate_metadata(
  toolchain : String,
  backend : String,
  module_version : String,
) -> Result[Unit, ConfigError] {
  if toolchain.trim().is_empty() {
    return Err(ConfigError("API snapshot toolchain must be a nonempty string"))
  }
  if module_version.trim().is_empty() {
    return Err(
      ConfigError("API snapshot module_version must be a nonempty string"),
    )
  }
  if backend != "native" &&
    backend != "js" &&
    backend != "wasm" &&
    backend != "wasm-gc" &&
    backend != "llvm" {
    return Err(ConfigError("unsupported API snapshot backend: \{backend}"))
  }
  Ok(())
}

///|
fn api_gate_snapshot_string(
  fields : Map[String, Json],
  name : String,
) -> Result[String, ConfigError] {
  match fields.get(name) {
    Some(Json::String(value)) =>
      if value.trim().is_empty() {
        Err(ConfigError("API snapshot \{name} must not be blank"))
      } else {
        Ok(value)
      }
    _ => Err(ConfigError("API snapshot \{name} must be a string"))
  }
}

///|
fn api_gate_parse_snapshot(
  src : String,
) -> Result[ApiGateSnapshot, ConfigError] {
  let json = @json.parse(
    src,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    _ =>
      return Err(
        ConfigError(
          "API snapshot is not valid JSON (duplicate keys are forbidden)",
        ),
      )
  }
  let fields = match json {
    Json::Object(fields) => fields
    _ => return Err(ConfigError("API snapshot root must be an object"))
  }
  for (key, _) in fields {
    if key != "version" &&
      key != "package" &&
      key != "toolchain" &&
      key != "backend" &&
      key != "module_version" &&
      key != "interface" {
      return Err(ConfigError("unknown API snapshot field: \{key}"))
    }
  }
  match fields.get("version") {
    Some(Json::Number(1.0, repr=Some("1"))) => ()
    _ =>
      return Err(
        ConfigError("unsupported API snapshot version: expected integer 1"),
      )
  }
  let package_name = match api_gate_snapshot_string(fields, "package") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let toolchain = match api_gate_snapshot_string(fields, "toolchain") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let backend = match api_gate_snapshot_string(fields, "backend") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let module_version = match
    api_gate_snapshot_string(fields, "module_version") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let interface_text = match api_gate_snapshot_string(fields, "interface") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match api_gate_validate_metadata(toolchain, backend, module_version) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let surface = match api_gate_parse_interface(interface_text) {
    Ok(surface) => surface
    Err(error) => return Err(error)
  }
  if package_name != surface.package_name {
    return Err(
      ConfigError("API snapshot package does not match its interface package"),
    )
  }
  Ok({ package_name, toolchain, backend, module_version, surface, })
}

///|
fn api_gate_review_issue(
  package_name : String,
  symbol : String,
  change : String,
  before : ApiGateDeclaration,
  after : ApiGateDeclaration?,
  severity : Severity,
) -> PolicyIssue {
  let details : Map[String, String] = Map([])
  details.set("package", package_name)
  details.set("symbol", symbol)
  details.set("change", change)
  details.set("before", before.canonical)
  details.set("before_line", before.line.to_string())
  match after {
    Some(declaration) => {
      details.set("after", declaration.canonical)
      details.set("after_line", declaration.line.to_string())
    }
    None => details.set("after", "")
  }
  {
    rule_id: "api/" + change,
    severity,
    message: "exported declaration \{change}; compatibility review required",
    details,
  }
}

///|
fn api_gate_parse_semver(src : String) -> Result[ApiGateVersion, ConfigError] {
  if src.contains("-") || src.contains("+") {
    return Err(
      ConfigError(
        "cannot judge prerelease policy: prerelease/build metadata is unsupported (\{src})",
      ),
    )
  }
  let parts = src.split(".").to_array()
  if parts.length() != 3 {
    return Err(
      ConfigError(
        "invalid API semver version: expected major.minor.patch (\{src})",
      ),
    )
  }
  let numbers : Array[Int32] = []
  for part in parts {
    let chars = part.to_array()
    if chars.is_empty() || (chars.length() > 1 && chars[0] == '0') {
      return Err(
        ConfigError(
          "invalid API semver version: empty or leading-zero component (\{src})",
        ),
      )
    }
    let mut value = 0
    for ch in chars {
      if ch < '0' || ch > '9' {
        return Err(
          ConfigError(
            "invalid API semver version: nondecimal component (\{src})",
          ),
        )
      }
      let digit = ch.to_int() - '0'.to_int()
      if value > (2147483647 - digit) / 10 {
        return Err(
          ConfigError("invalid API semver version: component overflow (\{src})"),
        )
      }
      value = value * 10 + digit
    }
    numbers.push(value)
  }
  Ok({ major: numbers[0], minor: numbers[1], })
}

///|
// A descriptor reader, not a source AST. Lexical balance is checked even in
// implementation bodies and private items. Nesting is bounded intentionally.
priv struct ApiGateToken {
  text : String
  line : Int32
  kind : Int32 // identifier=0, quoted literal=1, number=2, punctuation=3
  mut mate : Int32
}

///|
priv struct ApiGateContext {
  tokens : Array[ApiGateToken]
  imports : Map[String, String]
}

///|
priv struct ApiGateAttributes {
  derives : Array[String]
  semantic : Array[String]
}

///|
fn api_gate_ident_start(ch : Char) -> Bool {
  (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || ch == '_'
}

///|
fn api_gate_ident_char(ch : Char) -> Bool {
  api_gate_ident_start(ch) || (ch >= '0' && ch <= '9')
}

///|
fn api_gate_hex_value(ch : Char) -> Int32 {
  if ch >= '0' && ch <= '9' {
    ch.to_int() - '0'.to_int()
  } else if ch >= 'a' && ch <= 'f' {
    ch.to_int() - 'a'.to_int() + 10
  } else if ch >= 'A' && ch <= 'F' {
    ch.to_int() - 'A'.to_int() + 10
  } else {
    -1
  }
}

///|
fn api_gate_escape_end(
  chars : Array[Char],
  start : Int32,
  line : Int32,
) -> Result[Int32, ConfigError] {
  if start + 1 >= chars.length() {
    return Err(
      ConfigError("unclosed API interface literal escape at line \{line}"),
    )
  }
  let escaped = chars[start + 1]
  if escaped == '\\' ||
    escaped == '"' ||
    escaped == '\'' ||
    escaped == '/' ||
    escaped == 'n' ||
    escaped == 'r' ||
    escaped == 't' ||
    escaped == 'b' ||
    escaped == 'f' ||
    escaped == '0' {
    return Ok(start + 2)
  }
  if escaped != 'u' && escaped != 'x' {
    return Err(
      ConfigError(
        "unsupported or malformed API interface literal escape at line \{line}",
      ),
    )
  }
  let mut index = start + 2
  let braced = escaped == 'u' && index < chars.length() && chars[index] == '{'
  if braced {
    index += 1
  }
  let mut count = 0
  let mut value = 0
  let required = if escaped == 'x' { 2 } else { 4 }
  while index < chars.length() {
    if braced && chars[index] == '}' {
      break
    }
    if !braced && count == required {
      break
    }
    let digit = api_gate_hex_value(chars[index])
    if digit < 0 || count >= 6 {
      return Err(
        ConfigError(
          "malformed API interface hexadecimal escape at line \{line}",
        ),
      )
    }
    value = value * 16 + digit
    count += 1
    index += 1
  }
  if (braced && (count == 0 || index >= chars.length() || chars[index] != '}')) ||
    (!braced && count != required) ||
    value > 0x10ffff ||
    (value >= 0xd800 && value <= 0xdfff) {
    return Err(
      ConfigError(
        "malformed or unsupported API interface Unicode escape at line \{line}",
      ),
    )
  }
  Ok(if braced { index + 1 } else { index })
}

///|
fn api_gate_digits(
  chars : Array[Char],
  start : Int32,
  end : Int32,
  base : Int32,
) -> Int32 {
  let mut index = start
  let mut had_digit = false
  let mut separator = false
  while index < end {
    let digit = api_gate_hex_value(chars[index])
    if digit >= 0 && digit < base {
      had_digit = true
      separator = false
      index += 1
    } else if chars[index] == '_' {
      if !had_digit || separator {
        return -1
      }
      separator = true
      index += 1
    } else {
      break
    }
  }
  if !had_digit || separator {
    -1
  } else {
    index
  }
}

///|
fn api_gate_numeric_literal(text : String) -> Bool {
  let chars = text.to_array()
  let mut end = chars.length()
  if end == 0 {
    return false
  }
  let is_hex = end > 2 &&
    chars[0] == '0' &&
    (chars[1] == 'x' || chars[1] == 'X')
  let is_binary = end > 2 &&
    chars[0] == '0' &&
    (chars[1] == 'b' || chars[1] == 'B')
  let is_octal = end > 2 &&
    chars[0] == '0' &&
    (chars[1] == 'o' || chars[1] == 'O')
  let mut integer_suffix = false
  if chars[end - 1] == 'L' {
    integer_suffix = true
    end -= 1
    if end > 0 && chars[end - 1] == 'U' {
      end -= 1
    }
  } else if chars[end - 1] == 'U' {
    integer_suffix = true
    end -= 1
  } else if !is_hex && !is_binary && !is_octal && chars[end - 1] == 'F' {
    end -= 1
  }
  let base = if is_hex {
    16
  } else if is_binary {
    2
  } else if is_octal {
    8
  } else {
    10
  }
  let mut index = api_gate_digits(
    chars,
    if base == 10 {
      0
    } else {
      2
    },
    end,
    base,
  )
  if index < 0 {
    return false
  }
  if index < end && chars[index] == '.' {
    if integer_suffix || is_binary || is_octal {
      return false
    }
    index = api_gate_digits(chars, index + 1, end, base)
    if index < 0 {
      return false
    }
  }
  if index < end &&
    (
      (is_hex && (chars[index] == 'p' || chars[index] == 'P')) ||
      (base == 10 && (chars[index] == 'e' || chars[index] == 'E'))
    ) {
    if integer_suffix {
      return false
    }
    index += 1
    if index < end && (chars[index] == '-' || chars[index] == '+') {
      index += 1
    }
    index = api_gate_digits(chars, index, end, 10)
    if index < 0 {
      return false
    }
  }
  index == end
}

///|
fn api_gate_lex(src : String) -> Result[Array[ApiGateToken], ConfigError] {
  let chars = src.to_array()
  let tokens : Array[ApiGateToken] = []
  let mut i = 0
  let mut line = 1
  while i < chars.length() {
    let ch = chars[i]
    if ch == '\r' || ch == '\n' {
      if ch == '\r' && i + 1 < chars.length() && chars[i + 1] == '\n' {
        i += 1
      }
      line += 1
      i += 1
      continue
    }
    if ch == ' ' || ch == '\t' || ch == '\u{B}' || ch == '\u{C}' {
      i += 1
      continue
    }
    if ch == '/' && i + 1 < chars.length() && chars[i + 1] == '/' {
      i += 2
      while i < chars.length() && chars[i] != '\n' && chars[i] != '\r' {
        i += 1
      }
      continue
    }
    if ch == '/' && i + 1 < chars.length() && chars[i + 1] == '*' {
      let start_line = line
      let mut depth = 1
      i += 2
      while i < chars.length() && depth > 0 {
        if i + 1 < chars.length() && chars[i] == '/' && chars[i + 1] == '*' {
          depth += 1
          if depth > 256 {
            return Err(
              ConfigError(
                "API interface comment nesting exceeds supported limit",
              ),
            )
          }
          i += 2
        } else if i + 1 < chars.length() &&
          chars[i] == '*' &&
          chars[i + 1] == '/' {
          depth -= 1
          i += 2
        } else if chars[i] == '\r' || chars[i] == '\n' {
          if chars[i] == '\r' && i + 1 < chars.length() && chars[i + 1] == '\n' {
            i += 1
          }
          line += 1
          i += 1
        } else {
          i += 1
        }
      }
      if depth != 0 {
        return Err(
          ConfigError("unclosed API interface comment at line \{start_line}"),
        )
      }
      continue
    }
    let start = i
    let start_line = line
    let mut kind = 3
    if ch == '"' || ch == '\'' {
      kind = 1
      let quote = ch
      let mut closed = false
      let mut units = 0
      i += 1
      while i < chars.length() {
        if chars[i] == '\r' || chars[i] == '\n' {
          return Err(
            ConfigError("unclosed API interface literal at line \{start_line}"),
          )
        }
        if chars[i] == '\\' {
          i = match api_gate_escape_end(chars, i, start_line) {
            Ok(next) => next
            Err(error) => return Err(error)
          }
          units += 1
        } else if chars[i] == quote {
          i += 1
          closed = true
          break
        } else {
          i += 1
          units += 1
        }
      }
      if !closed {
        return Err(
          ConfigError("unclosed API interface literal at line \{start_line}"),
        )
      }
      if quote == '\'' && units != 1 {
        return Err(
          ConfigError(
            "malformed API interface character literal at line \{start_line}",
          ),
        )
      }
    } else if api_gate_ident_start(ch) {
      kind = 0
      i += 1
      while i < chars.length() && api_gate_ident_char(chars[i]) {
        i += 1
      }
    } else if ch >= '0' && ch <= '9' {
      kind = 2
      i += 1
      while i < chars.length() {
        if api_gate_ident_char(chars[i]) || chars[i] == '.' {
          i += 1
        } else if (chars[i] == '+' || chars[i] == '-') &&
          (
            chars[i - 1] == 'e' ||
            chars[i - 1] == 'E' ||
            chars[i - 1] == 'p' ||
            chars[i - 1] == 'P'
          ) {
          i += 1
        } else {
          break
        }
      }
    } else {
      if !ch.is_ascii() || ch.is_ascii_control() {
        return Err(
          ConfigError("unsupported API interface character at line \{line}"),
        )
      }
      i += 1
      if i < chars.length() &&
        (
          (ch == ':' && chars[i] == ':') ||
          (ch == '-' && chars[i] == '>') ||
          (ch == '=' && chars[i] == '>')
        ) {
        i += 1
      }
    }
    tokens.push({
      text: String::from_array(chars[start:i]),
      line: start_line,
      kind,
      mate: -1,
    })
  }
  let opens : Array[Int32] = []
  for index in 0..<tokens.length() {
    let text = tokens[index].text
    if text == "(" || text == "[" || text == "{" {
      if opens.length() >= 256 {
        return Err(ConfigError("API interface nesting exceeds supported limit"))
      }
      opens.push(index)
    } else if text == ")" || text == "]" || text == "}" {
      let open_index = match opens.pop() {
        Some(index) => index
        None =>
          return Err(
            ConfigError(
              "unmatched API interface delimiter at line \{tokens[index].line}",
            ),
          )
      }
      let open = tokens[open_index].text
      if !((open == "(" && text == ")") ||
        (open == "[" && text == "]") ||
        (open == "{" && text == "}")) {
        return Err(
          ConfigError(
            "mismatched API interface delimiters at line \{tokens[index].line}",
          ),
        )
      }
      tokens[open_index].mate = index
      tokens[index].mate = open_index
    }
  }
  if !opens.is_empty() {
    let index = opens[opens.length() - 1]
    return Err(
      ConfigError(
        "unclosed API interface delimiter at line \{tokens[index].line}",
      ),
    )
  }
  Ok(tokens)
}

///|
fn api_gate_at(ctx : ApiGateContext, index : Int32) -> String {
  if index < ctx.tokens.length() {
    ctx.tokens[index].text
  } else {
    ""
  }
}

///|
fn api_gate_error(
  ctx : ApiGateContext,
  index : Int32,
  message : String,
) -> ConfigError {
  let line = if index < ctx.tokens.length() {
    ctx.tokens[index].line
  } else if ctx.tokens.is_empty() {
    1
  } else {
    ctx.tokens[ctx.tokens.length() - 1].line
  }
  ConfigError("API interface line \{line}: \{message}")
}

///|
fn api_gate_word(ctx : ApiGateContext, index : Int32) -> Bool {
  if index >= ctx.tokens.length() || ctx.tokens[index].kind != 0 {
    return false
  }
  let word = ctx.tokens[index].text
  word != "pub" &&
  word != "priv" &&
  word != "fn" &&
  word != "struct" &&
  word != "enum" &&
  word != "type" &&
  word != "trait" &&
  word != "impl" &&
  word != "suberror" &&
  word != "let" &&
  word != "const" &&
  word != "import" &&
  word != "package" &&
  word != "derive" &&
  word != "raise" &&
  word != "noraise" &&
  word != "nocancel" &&
  word != "async" &&
  word != "test" &&
  word != "using" &&
  word != "for" &&
  word != "with" &&
  word != "as"
}

///|
fn api_gate_quoted(
  ctx : ApiGateContext,
  index : Int32,
) -> Result[String, ConfigError] {
  if index >= ctx.tokens.length() || ctx.tokens[index].kind != 1 {
    return Err(api_gate_error(ctx, index, "expected a quoted package string"))
  }
  let json = @json.parse(ctx.tokens[index].text) catch {
    _ => return Err(api_gate_error(ctx, index, "invalid quoted package string"))
  }
  match json {
    Json::String(value) if !value.trim().is_empty() => Ok(value)
    _ => Err(api_gate_error(ctx, index, "package string must not be blank"))
  }
}

///|
fn api_gate_import_block(
  ctx : ApiGateContext,
  start : Int32,
) -> Result[Int32, ConfigError] {
  if api_gate_at(ctx, start + 1) != "{" {
    return Err(api_gate_error(ctx, start, "unsupported import syntax"))
  }
  let close = ctx.tokens[start + 1].mate
  let mut index = start + 2
  while index < close {
    let package_name = match api_gate_quoted(ctx, index) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let parts = package_name.split("/").to_array()
    let mut import_alias = parts[parts.length() - 1].to_owned()
    index += 1
    if api_gate_at(ctx, index) == "as" || api_gate_at(ctx, index) == "@" {
      index += 1
      if api_gate_at(ctx, index) == "@" {
        index += 1
      }
      if !api_gate_word(ctx, index) {
        return Err(api_gate_error(ctx, index, "invalid import alias"))
      }
      import_alias = ctx.tokens[index].text
      index += 1
    }
    if import_alias.is_empty() || !import_alias.iter().all(api_gate_ident_char) {
      return Err(api_gate_error(ctx, index, "unsupported import alias"))
    }
    if ctx.imports.contains(import_alias) {
      return Err(
        api_gate_error(ctx, index, "duplicate import alias: \{import_alias}"),
      )
    }
    ctx.imports.set(import_alias, package_name)
    if index < close {
      if api_gate_at(ctx, index) != "," {
        return Err(
          api_gate_error(ctx, index, "expected a comma between imports"),
        )
      }
      index += 1
    }
  }
  Ok(close + 1)
}

///|
// Resolve qualified references: changing an import binding cannot falsely pass.
fn api_gate_name(
  ctx : ApiGateContext,
  start : Int32,
) -> Result[(String, Int32), ConfigError] {
  let mut index = start
  let prefix = if api_gate_at(ctx, index) == "&" {
    index += 1
    "&"
  } else {
    ""
  }
  if api_gate_at(ctx, index) == "@" {
    if !api_gate_word(ctx, index + 1) ||
      api_gate_at(ctx, index + 2) != "." ||
      !api_gate_word(ctx, index + 3) {
      return Err(
        api_gate_error(ctx, index, "unsupported qualified type/trait name"),
      )
    }
    let import_alias = ctx.tokens[index + 1].text
    let package_name = match ctx.imports.get(import_alias) {
      Some(value) => value
      None =>
        return Err(
          api_gate_error(
            ctx,
            index,
            "unresolved interface import alias: @\{import_alias}",
          ),
        )
    }
    Ok(
      (
        prefix + "@" + package_name + "." + ctx.tokens[index + 3].text,
        index + 4,
      ),
    )
  } else {
    if !api_gate_word(ctx, index) {
      return Err(
        api_gate_error(ctx, index, "expected a supported declaration/type name"),
      )
    }
    Ok((prefix + ctx.tokens[index].text, index + 1))
  }
}

///|
fn api_gate_raw_canonical(
  ctx : ApiGateContext,
  start : Int32,
  end : Int32,
) -> Result[String, ConfigError] {
  let parts : Array[String] = []
  let mut index = start
  while index < end {
    if api_gate_at(ctx, index) == "@" {
      let (name, next) = match api_gate_name(ctx, index) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if next > end {
        return Err(api_gate_error(ctx, index, "incomplete qualified name"))
      }
      parts.push(name)
      index = next
    } else {
      parts.push(ctx.tokens[index].text)
      index += 1
    }
  }
  Ok(parts.join(" "))
}

///|
fn api_gate_derive(
  ctx : ApiGateContext,
  open : Int32,
  attrs : ApiGateAttributes,
) -> Result[Int32, ConfigError] {
  if api_gate_at(ctx, open) != "(" {
    return Err(api_gate_error(ctx, open, "derive requires a trait list"))
  }
  let close = ctx.tokens[open].mate
  let mut index = open + 1
  if index == close {
    return Err(api_gate_error(ctx, open, "empty derive list"))
  }
  while index < close {
    let (name, next) = match api_gate_name(ctx, index) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if attrs.derives.contains(name) {
      return Err(api_gate_error(ctx, index, "duplicate derive trait: \{name}"))
    }
    attrs.derives.push(name)
    index = next
    if index < close {
      if api_gate_at(ctx, index) != "," {
        return Err(api_gate_error(ctx, index, "unsupported derive syntax"))
      }
      index += 1
    }
  }
  Ok(close + 1)
}

///|
fn api_gate_attributes(
  ctx : ApiGateContext,
  start : Int32,
) -> Result[(ApiGateAttributes, Int32), ConfigError] {
  let attrs : ApiGateAttributes = { derives: [], semantic: [], }
  let mut index = start
  while api_gate_at(ctx, index) == "#" {
    let attr_start = index
    if index + 1 >= ctx.tokens.length() || ctx.tokens[index + 1].kind != 0 {
      return Err(api_gate_error(ctx, index, "malformed interface attribute"))
    }
    let name = ctx.tokens[index + 1].text
    index += 2
    if name == "derive" {
      index = match api_gate_derive(ctx, index, attrs) {
        Ok(next) => next
        Err(error) => return Err(error)
      }
      continue
    }
    if name != "doc" &&
      name != "deprecated" &&
      name != "alias" &&
      name != "as_free_fn" &&
      name != "label_migration" &&
      name != "callsite" &&
      name != "must_implement_one" {
      return Err(
        api_gate_error(
          ctx,
          attr_start,
          "unsupported interface attribute: #\{name}",
        ),
      )
    }
    if api_gate_at(ctx, index) == "(" {
      let close = ctx.tokens[index].mate
      if close == index + 1 && name != "doc" && name != "deprecated" {
        return Err(
          api_gate_error(ctx, index, "empty semantic interface attribute"),
        )
      }
      index = close + 1
    } else if name == "alias" ||
      name == "label_migration" ||
      name == "callsite" ||
      name == "must_implement_one" {
      return Err(
        api_gate_error(
          ctx, index, "semantic interface attribute requires arguments",
        ),
      )
    }
    if name != "doc" && name != "deprecated" {
      let content = match api_gate_raw_canonical(ctx, attr_start, index) {
        Ok(content) => content
        Err(error) => return Err(error)
      }
      attrs.semantic.push(content)
    }
  }
  Ok((attrs, index))
}

///|
fn api_gate_attribute_content(attrs : ApiGateAttributes) -> String {
  attrs.derives.sort_by((left, right) => left.lexical_compare(right))
  attrs.semantic.sort_by((left, right) => left.lexical_compare(right))
  let parts = attrs.semantic.copy()
  if !attrs.derives.is_empty() {
    parts.push("#derive ( " + attrs.derives.join(" , ") + " )")
  }
  parts.join(" ")
}

///|
fn api_gate_generics(
  ctx : ApiGateContext,
  start : Int32,
) -> Result[(String, Int32), ConfigError] {
  if api_gate_at(ctx, start) != "[" {
    return Ok(("", start))
  }
  let close = ctx.tokens[start].mate
  let params : Array[String] = []
  let seen : Map[String, Bool] = Map([])
  let mut index = start + 1
  if index == close {
    return Err(api_gate_error(ctx, start, "empty generic parameter list"))
  }
  while index < close {
    if !api_gate_word(ctx, index) {
      return Err(api_gate_error(ctx, index, "invalid generic parameter"))
    }
    let name = ctx.tokens[index].text
    if seen.contains(name) {
      return Err(api_gate_error(ctx, index, "duplicate generic parameter"))
    }
    seen.set(name, true)
    index += 1
    let bounds : Array[String] = []
    if api_gate_at(ctx, index) == ":" {
      index += 1
      while true {
        let (bound, next) = match api_gate_name(ctx, index) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        bounds.push(bound)
        index = next
        if api_gate_at(ctx, index) != "+" {
          break
        }
        index += 1
      }
      bounds.sort_by((left, right) => left.lexical_compare(right))
    }
    params.push(
      name + (if bounds.is_empty() { "" } else { " : " + bounds.join(" + ") }),
    )
    if index < close {
      if api_gate_at(ctx, index) != "," {
        return Err(
          api_gate_error(ctx, index, "unsupported generic constraint syntax"),
        )
      }
      index += 1
    }
  }
  Ok(("[ " + params.join(" , ") + " ]", close + 1))
}

///|
fn api_gate_type_start(ctx : ApiGateContext, index : Int32) -> Bool {
  api_gate_word(ctx, index) ||
  api_gate_at(ctx, index) == "@" ||
  api_gate_at(ctx, index) == "&" ||
  api_gate_at(ctx, index) == "(" ||
  api_gate_at(ctx, index) == "async"
}

///|
fn api_gate_type(
  ctx : ApiGateContext,
  start : Int32,
  depth : Int32,
) -> Result[(String, Int32), ConfigError] {
  if depth > 256 {
    return Err(
      api_gate_error(ctx, start, "type nesting exceeds supported limit"),
    )
  }
  let mut index = start
  let is_async = api_gate_at(ctx, index) == "async"
  if is_async {
    index += 1
  }
  let is_tuple = api_gate_at(ctx, index) == "("
  let mut content = if is_tuple {
    let close = ctx.tokens[index].mate
    let parts : Array[String] = []
    index += 1
    while index < close {
      let (part, next) = match api_gate_type(ctx, index, depth + 1) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      parts.push(part)
      index = next
      if index < close {
        if api_gate_at(ctx, index) != "," {
          return Err(
            api_gate_error(ctx, index, "unsupported tuple/function type syntax"),
          )
        }
        index += 1
      }
    }
    index = close + 1
    "( " + parts.join(" , ") + " )"
  } else {
    let (name, next) = match api_gate_name(ctx, index) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    index = next
    name
  }
  if api_gate_at(ctx, index) == "[" {
    if is_tuple {
      return Err(api_gate_error(ctx, index, "unsupported generic tuple type"))
    }
    let close = ctx.tokens[index].mate
    let args : Array[String] = []
    index += 1
    if index == close {
      return Err(api_gate_error(ctx, index, "empty type argument list"))
    }
    while index < close {
      let (arg, next) = match api_gate_type(ctx, index, depth + 1) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      args.push(arg)
      index = next
      if index < close {
        if api_gate_at(ctx, index) != "," {
          return Err(
            api_gate_error(ctx, index, "unsupported type argument syntax"),
          )
        }
        index += 1
      }
    }
    index = close + 1
    content += " [ " + args.join(" , ") + " ]"
  }
  if api_gate_at(ctx, index) == "?" {
    content += " ?"
    index += 1
  }
  if api_gate_at(ctx, index) == "->" {
    if !is_tuple {
      return Err(
        api_gate_error(
          ctx, index, "function type requires parenthesized parameters",
        ),
      )
    }
    let (ret, next) = match api_gate_type(ctx, index + 1, depth + 1) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let (effect, effect_end) = match api_gate_effect(ctx, next, depth + 1) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    content = (if is_async { "async " } else { "" }) +
      content +
      " -> " +
      ret +
      effect
    index = effect_end
  } else if is_async {
    return Err(api_gate_error(ctx, start, "async type must be a function type"))
  }
  Ok((content, index))
}

///|
fn api_gate_effect(
  ctx : ApiGateContext,
  start : Int32,
  depth : Int32,
) -> Result[(String, Int32), ConfigError] {
  let mut index = start
  let mut effect = ""
  if api_gate_at(ctx, index) == "raise" {
    index += 1
    effect = " raise"
    if api_gate_at(ctx, index) == "?" {
      effect += " ?"
      index += 1
    } else if api_gate_type_start(ctx, index) {
      let (error_type, next) = match api_gate_type(ctx, index, depth + 1) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      effect += " " + error_type
      index = next
    }
  } else if api_gate_at(ctx, index) == "noraise" {
    effect = " noraise"
    index += 1
  }
  if api_gate_at(ctx, index) == "nocancel" {
    effect += " nocancel"
    index += 1
  }
  Ok((effect, index))
}

///|
fn api_gate_parameters(
  ctx : ApiGateContext,
  open : Int32,
) -> Result[(String, Int32), ConfigError] {
  if api_gate_at(ctx, open) != "(" {
    return Err(
      api_gate_error(ctx, open, "function/constructor requires parameters"),
    )
  }
  let close = ctx.tokens[open].mate
  let parts : Array[String] = []
  let labels : Map[String, Bool] = Map([])
  let mut index = open + 1
  while index < close {
    let mut label = ""
    if api_gate_word(ctx, index) && api_gate_at(ctx, index + 1) == ":" {
      index += 2
    } else if api_gate_word(ctx, index) &&
      (api_gate_at(ctx, index + 1) == "~" || api_gate_at(ctx, index + 1) == "?") &&
      api_gate_at(ctx, index + 2) == ":" {
      let name = ctx.tokens[index].text
      if labels.contains(name) {
        return Err(api_gate_error(ctx, index, "duplicate parameter label"))
      }
      labels.set(name, true)
      label = name + " " + ctx.tokens[index + 1].text + " : "
      index += 3
    }
    let (param_type, next) = match api_gate_type(ctx, index, 0) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    parts.push(label + param_type)
    index = next
    if index < close {
      if api_gate_at(ctx, index) != "," {
        return Err(api_gate_error(ctx, index, "unsupported parameter syntax"))
      }
      index += 1
    }
  }
  Ok(("( " + parts.join(" , ") + " )", close + 1))
}

///|
fn api_gate_function(
  ctx : ApiGateContext,
  start : Int32,
  allow_default : Bool,
) -> Result[(String, String, Int32), ConfigError] {
  let mut index = start
  let prefix = if api_gate_at(ctx, index) == "async" {
    index += 1
    "async fn "
  } else {
    "fn "
  }
  if api_gate_at(ctx, index) != "fn" {
    return Err(api_gate_error(ctx, index, "expected fn"))
  }
  index += 1
  let (generics, next) = match api_gate_generics(ctx, index) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  index = next
  let (receiver_name, next) = match api_gate_name(ctx, index) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  index = next
  let mut name = receiver_name
  if api_gate_at(ctx, index) == "::" {
    if !api_gate_word(ctx, index + 1) {
      return Err(api_gate_error(ctx, index, "invalid receiver method name"))
    }
    name += "::" + ctx.tokens[index + 1].text
    index += 2
  } else if receiver_name.has_prefix("&") || receiver_name.has_prefix("@") {
    return Err(
      api_gate_error(
        ctx, index, "qualified function requires a receiver namespace",
      ),
    )
  }
  let (params, next) = match api_gate_parameters(ctx, index) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  index = next
  if api_gate_at(ctx, index) != "->" {
    return Err(api_gate_error(ctx, index, "function requires a return type"))
  }
  let (ret, next) = match api_gate_type(ctx, index + 1, 0) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (effect, next) = match api_gate_effect(ctx, next, 0) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  index = next
  let mut default_marker = ""
  if api_gate_at(ctx, index) == "=" {
    if !allow_default || api_gate_at(ctx, index + 1) != "_" {
      return Err(
        api_gate_error(ctx, index, "unsupported interface function default"),
      )
    }
    default_marker = " = _"
    index += 2
  }
  if api_gate_at(ctx, index) == "{" {
    if allow_default {
      default_marker = " = _"
    }
    index = ctx.tokens[index].mate + 1
  }
  Ok(
    (
      name,
      prefix +
      (if generics.is_empty() { "" } else { generics + " " }) +
      name +
      " " +
      params +
      " -> " +
      ret +
      effect +
      default_marker,
      index,
    ),
  )
}

///|
fn api_gate_members(
  ctx : ApiGateContext,
  open : Int32,
  kind : String,
) -> Result[(String, Int32), ConfigError] {
  let close = ctx.tokens[open].mate
  let members : Array[String] = []
  let seen : Map[String, Bool] = Map([])
  let mut index = open + 1
  while index < close {
    if api_gate_at(ctx, index) == "," || api_gate_at(ctx, index) == ";" {
      return Err(api_gate_error(ctx, index, "empty public type/trait member"))
    }
    let (attrs, next) = match api_gate_attributes(ctx, index) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    index = next
    let (name, content, next) = if kind == "trait" {
      match api_gate_function(ctx, index, true) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    } else if kind == "struct" {
      let prefix = if api_gate_at(ctx, index) == "mut" {
        index += 1
        "mut "
      } else {
        ""
      }
      if !api_gate_word(ctx, index) {
        return Err(
          api_gate_error(ctx, index, "unsupported public struct field"),
        )
      }
      let name = ctx.tokens[index].text
      if api_gate_at(ctx, index + 1) != ":" {
        return Err(api_gate_error(ctx, index, "struct field requires a type"))
      }
      let (field_type, next) = match api_gate_type(ctx, index + 2, 0) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      (name, prefix + name + " : " + field_type, next)
    } else {
      if !api_gate_word(ctx, index) {
        return Err(
          api_gate_error(ctx, index, "unsupported enum/suberror member"),
        )
      }
      let name = ctx.tokens[index].text
      index += 1
      if api_gate_at(ctx, index) == "(" {
        let (params, next) = match api_gate_parameters(ctx, index) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        (name, name + " " + params, next)
      } else {
        (name, name, index)
      }
    }
    if next > close {
      return Err(
        api_gate_error(ctx, index, "member crosses its declaration boundary"),
      )
    }
    if seen.contains(name) {
      return Err(api_gate_error(ctx, index, "duplicate public member: \{name}"))
    }
    seen.set(name, true)
    members.push(
      (api_gate_attribute_content(attrs) + " " + content).trim().to_owned(),
    )
    index = next
    if api_gate_at(ctx, index) == "," || api_gate_at(ctx, index) == ";" {
      index += 1
    }
  }
  members.sort_by((left, right) => left.lexical_compare(right))
  Ok(("{ " + members.join(" ; ") + " }", close + 1))
}

///|
fn api_gate_declaration(
  ctx : ApiGateContext,
  start : Int32,
  attrs : ApiGateAttributes,
) -> Result[(Array[(String, ApiGateDeclaration)], Int32), ConfigError] {
  let mut index = start
  let is_public = api_gate_at(ctx, index) == "pub"
  let mut visibility = "pub"
  if is_public || api_gate_at(ctx, index) == "priv" {
    index += 1
  }
  if is_public && api_gate_at(ctx, index) == "(" {
    let close = ctx.tokens[index].mate
    let modifier = api_gate_at(ctx, index + 1)
    if close != index + 2 || (modifier != "all" && modifier != "open") {
      return Err(
        api_gate_error(ctx, index, "unsupported public visibility modifier"),
      )
    }
    visibility += " ( " + modifier + " )"
    index = close + 1
  }
  let line = ctx.tokens[start].line
  let kind = api_gate_at(ctx, index)
  if visibility != "pub" {
    if visibility.contains("open") && kind != "trait" {
      return Err(
        api_gate_error(ctx, index, "pub(open) is supported only for traits"),
      )
    }
    if visibility.contains("all") &&
      kind != "struct" &&
      kind != "enum" &&
      kind != "suberror" &&
      kind != "type" {
      return Err(
        api_gate_error(
          ctx, index, "pub(all) is supported only for type declarations",
        ),
      )
    }
  }
  let mut symbol = ""
  let mut content = ""
  if kind == "fn" || kind == "async" {
    let (name, declaration, next) = match api_gate_function(ctx, index, false) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    symbol = "fn:" + name
    content = visibility + " " + declaration
    index = next
  } else if kind == "struct" ||
    kind == "enum" ||
    kind == "suberror" ||
    kind == "type" ||
    kind == "trait" {
    index += 1
    if !api_gate_word(ctx, index) {
      return Err(api_gate_error(ctx, index, "invalid declared type/trait name"))
    }
    let name = ctx.tokens[index].text
    index += 1
    let (generics, next) = match api_gate_generics(ctx, index) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    index = next
    symbol = (if kind == "trait" { "trait:" } else { "type:" }) + name
    content = visibility +
      " " +
      kind +
      " " +
      name +
      (if generics.is_empty() { "" } else { " " + generics })
    if kind == "trait" && api_gate_at(ctx, index) == ":" {
      let bounds : Array[String] = []
      index += 1
      while true {
        let (bound, next) = match api_gate_name(ctx, index) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        bounds.push(bound)
        index = next
        if api_gate_at(ctx, index) != "+" {
          break
        }
        index += 1
      }
      bounds.sort_by((left, right) => left.lexical_compare(right))
      content += " : " + bounds.join(" + ")
    }
    if api_gate_at(ctx, index) == "{" && kind != "type" {
      let (members, next) = match api_gate_members(ctx, index, kind) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      content += " " + members
      index = next
    } else if kind == "struct" || kind == "enum" {
      return Err(
        api_gate_error(ctx, index, "struct/enum requires a member block"),
      )
    } else if kind == "type" && api_gate_at(ctx, index) == "=" {
      let (target, next) = match api_gate_type(ctx, index + 1, 0) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      content += " = " + target
      index = next
    } else if kind == "type" && api_gate_type_start(ctx, index) {
      let (target, next) = match api_gate_type(ctx, index, 0) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      content += " " + target
      index = next
    }
    if api_gate_at(ctx, index) == "derive" {
      index = match api_gate_derive(ctx, index + 1, attrs) {
        Ok(next) => next
        Err(error) => return Err(error)
      }
    }
  } else if kind == "impl" {
    index += 1
    let (generics, next) = match api_gate_generics(ctx, index) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let (trait_name, next) = match api_gate_name(ctx, next) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if api_gate_at(ctx, next) != "for" {
      return Err(api_gate_error(ctx, next, "impl requires a target type"))
    }
    let (target, next) = match api_gate_type(ctx, next + 1, 0) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    symbol = "impl:" + trait_name + " for " + target
    content = visibility +
      " impl " +
      (if generics.is_empty() { "" } else { generics + " " }) +
      trait_name +
      " for " +
      target
    index = next
    if api_gate_at(ctx, index) == "{" {
      index = ctx.tokens[index].mate + 1
    }
    if api_gate_at(ctx, index) == "with" {
      return Err(
        api_gate_error(
          ctx, index, "impl with-member syntax is not a supported compiler interface descriptor",
        ),
      )
    }
  } else if kind == "let" || kind == "const" {
    index += 1
    if api_gate_at(ctx, index) == "mut" {
      index += 1
      content = "mut "
    }
    if !api_gate_word(ctx, index) {
      return Err(api_gate_error(ctx, index, "unsupported public value pattern"))
    }
    let name = ctx.tokens[index].text
    index += 1
    if api_gate_at(ctx, index) != ":" {
      return Err(
        api_gate_error(ctx, index, "interface value requires an explicit type"),
      )
    }
    let (value_type, next) = match api_gate_type(ctx, index + 1, 0) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    symbol = "value:" + name
    content = visibility +
      " " +
      kind +
      " " +
      content +
      name +
      " : " +
      value_type
    index = next
    if api_gate_at(ctx, index) == "=" {
      let literal_start = index + 1
      index += 1
      if api_gate_at(ctx, index) == "-" || api_gate_at(ctx, index) == "+" {
        index += 1
      }
      if index >= ctx.tokens.length() ||
        (
          ctx.tokens[index].kind != 1 &&
          ctx.tokens[index].kind != 2 &&
          api_gate_at(ctx, index) != "true" &&
          api_gate_at(ctx, index) != "false"
        ) {
        return Err(
          api_gate_error(
            ctx, index, "unsupported public value initializer; only literals are supported",
          ),
        )
      }
      if ctx.tokens[index].kind == 2 &&
        !api_gate_numeric_literal(ctx.tokens[index].text) {
        return Err(
          api_gate_error(
            ctx, index, "malformed or unsupported public numeric literal",
          ),
        )
      }
      if literal_start < index && ctx.tokens[index].kind != 2 {
        return Err(api_gate_error(ctx, index, "literal sign requires a number"))
      }
      index += 1
      let literal = match api_gate_raw_canonical(ctx, literal_start, index) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      content += " = " + literal
    }
  } else if kind == "using" && is_public {
    if api_gate_at(ctx, index + 1) != "@" ||
      !api_gate_word(ctx, index + 2) ||
      api_gate_at(ctx, index + 3) != "{" {
      return Err(api_gate_error(ctx, index, "unsupported public using syntax"))
    }
    let import_alias = ctx.tokens[index + 2].text
    let package_name = match ctx.imports.get(import_alias) {
      Some(value) => value
      None =>
        return Err(
          api_gate_error(ctx, index, "unresolved public using import alias"),
        )
    }
    let close = ctx.tokens[index + 3].mate
    index += 4
    let exports : Array[(String, ApiGateDeclaration)] = []
    while index < close {
      let export_kind = api_gate_at(ctx, index)
      if export_kind != "type" && export_kind != "trait" {
        return Err(
          api_gate_error(
            ctx, index, "public using supports only type and trait reexports",
          ),
        )
      }
      index += 1
      if !api_gate_word(ctx, index) {
        return Err(api_gate_error(ctx, index, "invalid public using member"))
      }
      let original = ctx.tokens[index].text
      let mut name = original
      index += 1
      if api_gate_at(ctx, index) == "as" {
        index += 1
        if !api_gate_word(ctx, index) {
          return Err(api_gate_error(ctx, index, "invalid reexport alias"))
        }
        name = ctx.tokens[index].text
        index += 1
      }
      exports.push(
        (
          export_kind + ":" + name,
          {
            canonical: (api_gate_attribute_content(attrs) +
            " " +
            visibility +
            " " +
            export_kind +
            " " +
            name +
            " = @" +
            package_name +
            "." +
            original)
            .trim()
            .to_owned(),
            line,
          },
        ),
      )
      if index < close {
        if api_gate_at(ctx, index) != "," {
          return Err(
            api_gate_error(ctx, index, "unsupported public using member syntax"),
          )
        }
        index += 1
      }
    }
    if exports.is_empty() {
      return Err(api_gate_error(ctx, index, "empty public using declaration"))
    }
    return Ok((exports, close + 1))
  } else if kind == "test" && !is_public {
    index += 1
    if index < ctx.tokens.length() && ctx.tokens[index].kind == 1 {
      index += 1
    }
    if api_gate_at(ctx, index) != "{" {
      return Err(api_gate_error(ctx, index, "private test requires a body"))
    }
    return Ok(([], ctx.tokens[index].mate + 1))
  } else {
    return Err(
      api_gate_error(ctx, index, "unsupported declaration syntax: \{kind}"),
    )
  }
  if is_public {
    content = (api_gate_attribute_content(attrs) + " " + content)
      .trim()
      .to_owned()
    Ok(([(symbol, { canonical: content, line, })], index))
  } else {
    Ok(([], index))
  }
}

///|
fn api_gate_parse_interface(
  src : String,
) -> Result[ApiGateSurface, ConfigError] {
  let tokens = match api_gate_lex(src) {
    Ok(tokens) => tokens
    Err(error) => return Err(error)
  }
  let ctx : ApiGateContext = { tokens, imports: Map([]), }
  if api_gate_at(ctx, 0) != "package" {
    return Err(
      api_gate_error(ctx, 0, "interface must start with a package declaration"),
    )
  }
  let package_name = match api_gate_quoted(ctx, 1) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  // Collect imports first so reordering cannot change reference resolution.
  let mut index = 2
  while index < tokens.length() {
    if api_gate_at(ctx, index) == "import" {
      index = match api_gate_import_block(ctx, index) {
        Ok(next) => next
        Err(error) => return Err(error)
      }
    } else if tokens[index].mate > index {
      index = tokens[index].mate + 1
    } else {
      index += 1
    }
  }
  let exports : Map[String, ApiGateDeclaration] = Map([])
  index = 2
  while index < tokens.length() {
    if api_gate_at(ctx, index) == ";" {
      index += 1
      continue
    }
    if api_gate_at(ctx, index) == "import" {
      index = tokens[index + 1].mate + 1
      continue
    }
    let (attrs, next) = match api_gate_attributes(ctx, index) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if next >= tokens.length() {
      return Err(api_gate_error(ctx, next, "attribute without a declaration"))
    }
    let (declarations, next) = match api_gate_declaration(ctx, next, attrs) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    for (symbol, declaration) in declarations {
      if exports.contains(symbol) {
        return Err(
          api_gate_error(ctx, index, "duplicate exported symbol: \{symbol}"),
        )
      }
      exports.set(symbol, declaration)
    }
    if next <= index {
      return Err(
        api_gate_error(ctx, index, "interface reader made no progress"),
      )
    }
    index = next
  }
  Ok({ package_name, exports, })
}
