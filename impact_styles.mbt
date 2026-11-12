///|
/// Pure CSS/SCSS dependency extraction. This scanner does not resolve paths,
/// access the filesystem, evaluate Sass or decode escapes. Schemes, aliases,
/// queries and fragments are retained for the planner to classify/resolve.
priv struct ImpactStyleScan {
  file : String
  chars : Array[Char]
  positions : Array[(Int32, Int32)]
  scss : Bool
  references : Array[ImpactReference]
  issues : Array[ImpactIssue]
  conditions : Array[Bool]
}

///|
fn impact_style_space(c : Char) -> Bool {
  c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\u{0C}'
}

///|
fn impact_style_break(c : Char) -> Bool {
  c == '\n' || c == '\r' || c == '\u{0C}'
}

///|
fn impact_style_ident(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '_' ||
  c == '-' ||
  c.to_int() >= 128
}

///|
fn impact_style_pair(
  scan : ImpactStyleScan,
  offset : Int32,
  a : Char,
  b : Char,
) -> Bool {
  offset + 1 < scan.chars.length() &&
  scan.chars[offset] == a &&
  scan.chars[offset + 1] == b
}

///|
fn impact_style_position(
  scan : ImpactStyleScan,
  offset : Int32,
) -> (Int32, Int32) {
  let index = if offset < 0 {
    0
  } else if offset >= scan.positions.length() {
    scan.positions.length() - 1
  } else {
    offset
  }
  scan.positions[index]
}

///|
fn impact_style_issue(
  scan : ImpactStyleScan,
  offset : Int32,
  message : String,
) -> Unit {
  let (line, _) = impact_style_position(scan, offset)
  let reason = "style: " + message
  if !scan.issues.any(issue => issue.line == line && issue.reason == reason) {
    scan.issues.push({ file: scan.file, line, reason, })
  }
}

///|
fn impact_style_reference(
  scan : ImpactStyleScan,
  offset : Int32,
  value : String,
  kind : String,
) -> Unit {
  let (line, column) = impact_style_position(scan, offset)
  if scan.conditions.any(dynamic => dynamic) {
    impact_style_issue(
      scan, offset, "dependency inside a dynamic or unsupported conditional rule",
    )
  }
  if !scan.references.any(reference => {
      reference.specifier == value &&
      reference.kind == kind &&
      reference.line == line &&
      reference.column == column
    }) {
    scan.references.push({
      file: scan.file,
      specifier: value,
      kind,
      line,
      column,
    })
  }
}

///|
/// Skip a real block comment, never interpreting its quoted text or URLs.
fn impact_style_comment(scan : ImpactStyleScan, start : Int32) -> Int32 {
  let mut i = start + 2
  while i < scan.chars.length() {
    if impact_style_pair(scan, i, '*', '/') {
      return i + 2
    }
    i += 1
  }
  impact_style_issue(scan, start, "unterminated block comment")
  scan.chars.length()
}

///|
fn impact_style_trivia(
  scan : ImpactStyleScan,
  start : Int32,
  line_comments : Bool,
) -> Int32 {
  let mut i = start
  while i < scan.chars.length() {
    if impact_style_space(scan.chars[i]) {
      i += 1
    } else if impact_style_pair(scan, i, '/', '*') {
      i = impact_style_comment(scan, i)
    } else if line_comments && scan.scss && impact_style_pair(scan, i, '/', '/') {
      i += 2
      while i < scan.chars.length() && !impact_style_break(scan.chars[i]) {
        i += 1
      }
    } else {
      break
    }
  }
  i
}

///|
fn impact_style_dynamic_value(value : String) -> Bool {
  value.contains("$") ||
  value.contains("#{") ||
  value.contains("@{") ||
  value.contains("\\") ||
  value.contains("\u{0}")
}

///|
/// Consume a quoted token. Ordinary content strings may contain escapes, but
/// dependency strings with escapes/interpolation are deliberately inconclusive.
fn impact_style_quoted(
  scan : ImpactStyleScan,
  start : Int32,
  dependency : Bool,
) -> (String?, Int32) {
  let quote = scan.chars[start]
  let mut i = start + 1
  let mut escaped = false
  while i < scan.chars.length() {
    let c = scan.chars[i]
    if c == '\\' {
      escaped = true
      i += 1
      if i < scan.chars.length() {
        // Escaped CRLF is one continuation, not a new unterminated token.
        if scan.chars[i] == '\r' &&
          i + 1 < scan.chars.length() &&
          scan.chars[i + 1] == '\n' {
          i += 1
        }
        i += 1
      }
      continue
    }
    if c == quote {
      let value = String::from_array(scan.chars[start + 1:i])
      if dependency &&
        (value == "" || escaped || impact_style_dynamic_value(value)) {
        impact_style_issue(
          scan, start, "empty, escaped or dynamic dependency string",
        )
        return (None, i + 1)
      }
      return (Some(value), i + 1)
    }
    if impact_style_break(c) {
      impact_style_issue(
        scan, start, "unterminated quoted string before a line break",
      )
      return (None, i)
    }
    i += 1
  }
  impact_style_issue(scan, start, "unterminated quoted string")
  (None, i)
}

///|
/// Recover a complete parenthesized function, including nested calculations.
/// This is recovery only: computed URL arguments are not emitted as paths.
fn impact_style_function_end(scan : ImpactStyleScan, opening : Int32) -> Int32 {
  let mut i = opening + 1
  let mut depth = 1
  while i < scan.chars.length() {
    let c = scan.chars[i]
    if c == '\'' || c == '"' {
      let (_, next) = impact_style_quoted(scan, i, false)
      i = next
      continue
    }
    if impact_style_pair(scan, i, '/', '*') {
      i = impact_style_comment(scan, i)
      continue
    }
    if c == '\\' {
      i += if i + 1 < scan.chars.length() { 2 } else { 1 }
      continue
    }
    if c == '(' {
      depth += 1
    } else if c == ')' {
      depth -= 1
      if depth == 0 {
        return i + 1
      }
    }
    i += 1
  }
  impact_style_issue(scan, opening, "unterminated url/function")
  i
}

///|
/// URL tokens own their unquoted body: // in https:// or //host is URI text,
/// never a SCSS line comment. The returned string is not URI-decoded or trimmed
/// inside quotes; local queries/fragments and external schemes survive intact.
fn impact_style_url(
  scan : ImpactStyleScan,
  opening : Int32,
) -> (String?, Int32) {
  let start = impact_style_trivia(scan, opening + 1, false)
  if start >= scan.chars.length() {
    impact_style_issue(scan, opening, "unterminated url/function")
    return (None, scan.chars.length())
  }
  if scan.chars[start] == '\'' || scan.chars[start] == '"' {
    let (value, after_quote) = impact_style_quoted(scan, start, true)
    let close = impact_style_trivia(scan, after_quote, false)
    if close < scan.chars.length() && scan.chars[close] == ')' {
      return (value, close + 1)
    }
    impact_style_issue(
      scan, opening, "url argument is concatenated, computed or unclosed",
    )
    return (None, impact_style_function_end(scan, opening))
  }
  let mut i = start
  while i < scan.chars.length() {
    let c = scan.chars[i]
    if c == ')' || impact_style_space(c) {
      break
    }
    if c == '(' ||
      c == '\'' ||
      c == '"' ||
      c == '\\' ||
      c == '$' ||
      c == '{' ||
      c == '}' ||
      c == '\u{0}' ||
      impact_style_pair(scan, i, '/', '*') {
      impact_style_issue(
        scan, opening, "url argument is dynamic, escaped or contains nested syntax",
      )
      return (None, impact_style_function_end(scan, opening))
    }
    i += 1
  }
  let value = String::from_array(scan.chars[start:i])
  let close = impact_style_trivia(scan, i, false)
  if value == "" {
    impact_style_issue(scan, opening, "empty url argument")
  }
  if close >= scan.chars.length() || scan.chars[close] != ')' {
    impact_style_issue(
      scan, opening, "url argument contains whitespace, concatenation or is unclosed",
    )
    return (None, impact_style_function_end(scan, opening))
  }
  (if value == "" { None } else { Some(value) }, close + 1)
}

///|
fn impact_style_word_end(scan : ImpactStyleScan, start : Int32) -> Int32 {
  let mut end = start
  while end < scan.chars.length() && impact_style_ident(scan.chars[end]) {
    end += 1
  }
  end
}

///|
/// Skip an interpolation without reporting it. Only positions that can name a
/// dependency (at-rule preludes) report; declaration values and selectors
/// cannot construct a stylesheet reference. An interpolation that never closes
/// swallows the rest of the file, so it must stay inconclusive.
fn impact_style_interpolation_skip(
  scan : ImpactStyleScan,
  start : Int32,
) -> Int32 {
  let mut depth = 1
  let mut i = start + 2
  while i < scan.chars.length() {
    let c = scan.chars[i]
    if c == '\'' || c == '"' {
      let (_, next) = impact_style_quoted(scan, i, false)
      i = next
      continue
    }
    if impact_style_pair(scan, i, '/', '*') {
      i = impact_style_comment(scan, i)
      continue
    }
    if c == '{' {
      depth += 1
    } else if c == '}' {
      depth -= 1
      if depth == 0 {
        return i + 1
      }
    }
    i += 1
  }
  impact_style_issue(scan, start, "unterminated style interpolation")
  i
}

///|
/// Skip a dynamic interpolation as an opaque balanced expression. Its internal
/// text must not manufacture apparently static url/import references.
fn impact_style_interpolation(scan : ImpactStyleScan, start : Int32) -> Int32 {
  impact_style_issue(
    scan, start, "style interpolation may construct dependencies",
  )
  let mut depth = 1
  let mut i = start + 2
  while i < scan.chars.length() {
    let c = scan.chars[i]
    if c == '\'' || c == '"' {
      let (_, next) = impact_style_quoted(scan, i, false)
      i = next
      continue
    }
    if impact_style_pair(scan, i, '/', '*') {
      i = impact_style_comment(scan, i)
      continue
    }
    if c == '{' {
      depth += 1
    } else if c == '}' {
      depth -= 1
      if depth == 0 {
        return i + 1
      }
    }
    i += 1
  }
  impact_style_issue(scan, start, "unterminated style interpolation")
  i
}

///|
fn impact_style_interpolation_at(scan : ImpactStyleScan, i : Int32) -> Bool {
  impact_style_pair(scan, i, '#', '{') ||
  impact_style_pair(scan, i, '@', '{') ||
  impact_style_pair(scan, i, '$', '{')
}

///|
/// Consume an at-rule's tail without confusing media query commas with a list
/// of import paths. stop_comma is used only for recovery of a bad path item.
/// Delimiters are returned unconsumed so the caller can continue safely.
fn impact_style_tail(
  scan : ImpactStyleScan,
  start : Int32,
  stop_comma : Bool,
) -> Int32 {
  let groups : Array[Char] = []
  let mut i = start
  while i < scan.chars.length() {
    let c = scan.chars[i]
    if groups.is_empty() && (c == ';' || c == '}' || (stop_comma && c == ',')) {
      return i
    }
    if impact_style_pair(scan, i, '/', '*') {
      i = impact_style_comment(scan, i)
      continue
    }
    if scan.scss && impact_style_pair(scan, i, '/', '/') {
      i = impact_style_trivia(scan, i, true)
      continue
    }
    if impact_style_interpolation_at(scan, i) {
      i = impact_style_interpolation(scan, i)
      continue
    }
    if c == '\'' || c == '"' {
      if groups.is_empty() && !stop_comma {
        impact_style_issue(scan, i, "unexpected string in import/module tail")
      }
      let (_, next) = impact_style_quoted(scan, i, false)
      i = next
      continue
    }
    if c == '$' || c == '\\' || c == '+' {
      impact_style_issue(scan, i, "dynamic or escaped import/module condition")
    }
    if c == '@' && groups.is_empty() {
      impact_style_issue(
        scan, i, "missing at-rule terminator before another rule",
      )
      return i
    }
    if c == '{' {
      impact_style_issue(scan, i, "unexpected block in import/module rule")
      return i
    }
    if c == '(' || c == '[' {
      groups.push(c)
    } else if c == ')' || c == ']' {
      let expected = if c == ')' { '(' } else { '[' }
      if groups.is_empty() || groups[groups.length() - 1] != expected {
        impact_style_issue(scan, i, "unbalanced import/module condition")
      } else {
        ignore(groups.pop())
      }
    } else if impact_style_ident(c) {
      let end = impact_style_word_end(scan, i)
      let name = String::from_array(scan.chars[i:end]).to_lower()
      let opening = impact_style_trivia(scan, end, true)
      if name == "url" &&
        opening < scan.chars.length() &&
        scan.chars[opening] == '(' {
        let (value, next) = impact_style_url(scan, opening)
        match value {
          Some(specifier) =>
            impact_style_reference(scan, i, specifier, "style-url")
          None => ()
        }
        i = next
        continue
      }
      if ["var", "calc", "env", "if"].contains(name) &&
        end < scan.chars.length() &&
        scan.chars[end] == '(' {
        impact_style_issue(scan, i, "computed import/module condition")
      }
      i = end
      continue
    }
    i += 1
  }
  if !groups.is_empty() {
    impact_style_issue(scan, start, "unclosed import/module condition")
  }
  i
}

///|
fn impact_style_css_suffix(value : String) -> Bool {
  let chars = value.to_array()
  let mut end = 0
  while end < chars.length() && chars[end] != '?' && chars[end] != '#' {
    end += 1
  }
  String::from_array(chars[:end]).to_lower().has_suffix(".css")
}

///|
/// Consume @import, @use or @forward. Only complete static path expressions
/// become references: a quoted prefix of a concatenation is not a path.
fn impact_style_import(
  scan : ImpactStyleScan,
  rule_start : Int32,
  after_name : Int32,
  directive : String,
) -> Int32 {
  let allowed = directive == "import" || scan.scss
  if !allowed {
    impact_style_issue(
      scan,
      rule_start,
      "@" + directive + " is not supported in CSS",
    )
  }
  let mut i = after_name
  let mut need_path = true
  while i < scan.chars.length() {
    i = impact_style_trivia(scan, i, true)
    if i >= scan.chars.length() || scan.chars[i] == ';' || scan.chars[i] == '}' {
      if need_path {
        impact_style_issue(
          scan,
          rule_start,
          "missing dependency path in @" + directive,
        )
      }
      return if i < scan.chars.length() && scan.chars[i] == ';' {
        i + 1
      } else {
        i
      }
    }
    let location = i
    let quoted = scan.chars[i] == '\'' || scan.chars[i] == '"'
    let name_end = impact_style_word_end(scan, i)
    let word = String::from_array(scan.chars[i:name_end]).to_lower()
    let opening = impact_style_trivia(scan, name_end, true)
    let is_url = word == "url" &&
      opening < scan.chars.length() &&
      scan.chars[opening] == '('
    let (parsed_value, after_value) = if quoted {
      impact_style_quoted(scan, i, true)
    } else if is_url && directive == "import" {
      impact_style_url(scan, opening)
    } else {
      impact_style_issue(
        scan,
        i,
        "dependency path in @" +
        directive +
        " is not a static quoted string or url",
      )
      (None, impact_style_tail(scan, i, true))
    }
    let mut value = parsed_value
    let mut next = impact_style_trivia(scan, after_value, true)
    let concatenated = next < scan.chars.length() &&
      (
        scan.chars[next] == '+' ||
        scan.chars[next] == '$' ||
        scan.chars[next] == '\'' ||
        scan.chars[next] == '"' ||
        impact_style_interpolation_at(scan, next)
      )
    if concatenated {
      impact_style_issue(scan, next, "concatenated or dynamic dependency path")
      value = None
      next = impact_style_tail(scan, next, true)
    }
    let has_tail = next < scan.chars.length() &&
      scan.chars[next] != ',' &&
      scan.chars[next] != ';' &&
      scan.chars[next] != '}'
    match value {
      Some(specifier) if allowed => {
        let kind = if directive != "import" {
          "style-import-scss"
        } else if !scan.scss ||
          is_url ||
          has_tail ||
          impact_style_css_suffix(specifier) {
          "style-import-css"
        } else {
          "style-import-scss"
        }
        impact_style_reference(scan, location, specifier, kind)
      }
      _ => ()
    }
    need_path = false
    if next >= scan.chars.length() {
      return next
    }
    if scan.chars[next] == ',' && directive == "import" {
      if !scan.scss {
        impact_style_issue(
          scan, next, "CSS @import does not support a comma-separated path list",
        )
      }
      i = next + 1
      need_path = true
      continue
    }
    if scan.chars[next] == ';' {
      return next + 1
    }
    if scan.chars[next] == '}' {
      return next
    }
    let end = impact_style_tail(scan, next, false)
    return if end < scan.chars.length() && scan.chars[end] == ';' {
      end + 1
    } else {
      end
    }
  }
  if need_path {
    impact_style_issue(
      scan,
      rule_start,
      "missing dependency path in @" + directive,
    )
  }
  i
}

///|
/// Extract static stylesheet references without filesystem access. Positions
/// point to the import string's opening quote or the url function name. All
/// schemes/queries/fragments are passed through unchanged: external URLs,
/// fragment-only URLs and sass: modules are the planner's responsibility.
fn impact_extract_style_references(
  rel : String,
  source : String,
  syntax : String,
  start_line : Int32,
  start_column : Int32,
) -> (Array[ImpactReference], Array[ImpactIssue]) {
  let language = syntax.to_lower()
  if (language != "css" && language != "scss") ||
    start_line < 1 ||
    start_column < 1 {
    return (
      [],
      [
        {
          file: rel,
          line: if start_line > 0 {
            start_line
          } else {
            1
          },
          reason: "style: unsupported syntax or invalid source origin",
        },
      ],
    )
  }
  let chars = source.to_array()
  let positions : Array[(Int32, Int32)] = []
  let mut line = start_line
  let mut column = start_column
  let mut previous_cr = false
  for c in chars {
    positions.push((line, column))
    if c == '\r' || c == '\u{0C}' {
      line += 1
      column = 1
    } else if c == '\n' {
      if !previous_cr {
        line += 1
      }
      column = 1
    } else {
      column += 1
    }
    previous_cr = c == '\r'
  }
  positions.push((line, column))
  let scan : ImpactStyleScan = {
    file: rel,
    chars,
    positions,
    scss: language == "scss",
    references: [],
    issues: [],
    conditions: [],
  }
  let groups : Array[Char] = []
  let mut i = 0
  let mut in_prelude = false
  let mut dynamic_prelude = false
  while i < chars.length() {
    let c = chars[i]
    if i == 0 && c == '\u{FEFF}' {
      i += 1
      continue
    }
    if impact_style_pair(scan, i, '/', '*') ||
      (scan.scss && impact_style_pair(scan, i, '/', '/')) {
      i = impact_style_trivia(scan, i, true)
      continue
    }
    if c == '\'' || c == '"' {
      let (_, next) = impact_style_quoted(scan, i, false)
      i = next
      continue
    }
    if impact_style_interpolation_at(scan, i) {
      // An interpolation can never name a stylesheet: the at-rules that load
      // files (@use/@import/@forward) parse their own arguments and report
      // non-static paths themselves. A prelude interpolation still marks the
      // block dynamic, so references inside it stay conservative.
      if in_prelude {
        dynamic_prelude = true
      }
      i = impact_style_interpolation_skip(scan, i)
      continue
    }
    if c == '@' {
      let end = impact_style_word_end(scan, i + 1)
      let name = String::from_array(chars[i + 1:end]).to_lower()
      if ["import", "use", "forward"].contains(name) {
        i = impact_style_import(scan, i, end, name)
        in_prelude = false
        dynamic_prelude = false
        continue
      }
      in_prelude = true
      dynamic_prelude = ["if", "else", "each", "for", "while"].contains(name)
      i = if end > i + 1 { end } else { i + 1 }
      continue
    }
    if impact_style_ident(c) {
      let end = impact_style_word_end(scan, i)
      let name = String::from_array(chars[i:end]).to_lower()
      let opening = impact_style_trivia(scan, end, true)
      if name == "url" && opening < chars.length() && chars[opening] == '(' {
        let (value, next) = impact_style_url(scan, opening)
        match value {
          Some(specifier) =>
            impact_style_reference(scan, i, specifier, "style-url")
          None => ()
        }
        i = next
        continue
      }
      if scan.scss &&
        name == "load-css" &&
        opening < chars.length() &&
        chars[opening] == '(' {
        impact_style_issue(
          scan, i, "Sass load-css needs dependency evaluation not provided by this scanner",
        )
      }
      if in_prelude &&
        ["var", "calc", "env", "if"].contains(name) &&
        opening < chars.length() &&
        chars[opening] == '(' {
        dynamic_prelude = true
      }
      i = end
      continue
    }
    if c == '\\' || c == '\u{0}' {
      impact_style_issue(
        scan, i, "escaped or invalid style token may hide a dependency",
      )
      i += if c == '\\' && i + 1 < chars.length() { 2 } else { 1 }
      continue
    }
    if c == '$' && in_prelude {
      dynamic_prelude = true
    }
    if c == '{' || c == '(' || c == '[' {
      groups.push(c)
      if c == '{' {
        scan.conditions.push(
          dynamic_prelude || scan.conditions.any(value => value),
        )
        in_prelude = false
        dynamic_prelude = false
      }
    } else if c == '}' || c == ')' || c == ']' {
      let expected = if c == '}' { '{' } else if c == ')' { '(' } else { '[' }
      if groups.is_empty() || groups[groups.length() - 1] != expected {
        impact_style_issue(scan, i, "unbalanced stylesheet delimiter")
      } else {
        ignore(groups.pop())
        if c == '}' && !scan.conditions.is_empty() {
          ignore(scan.conditions.pop())
          in_prelude = false
          dynamic_prelude = false
        }
      }
    } else if c == ';' {
      in_prelude = false
      dynamic_prelude = false
    }
    i += 1
  }
  if !groups.is_empty() {
    impact_style_issue(scan, chars.length(), "unclosed stylesheet delimiter")
  }
  (scan.references, scan.issues)
}
