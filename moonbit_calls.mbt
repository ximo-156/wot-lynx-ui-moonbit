///|
#derive(Debug)
priv struct MoonbitCallToken {
  text : String
  offset : Int32
}

///|
fn moonbit_call_tokens(code : String) -> Array[MoonbitCallToken] {
  let chars = code.to_array()
  let tokens : Array[MoonbitCallToken] = []
  let mut i = 0
  while i < chars.length() {
    let c = chars[i]
    if c == ' ' || c == '\t' || c == '\r' || c == '\n' { i += 1; continue }
    let start = i
    if moonbit_is_ident_start(c) {
      i += 1
      while i < chars.length() && moonbit_is_ident_char(chars[i]) { i += 1 }
    } else if i + 1 < chars.length() &&
      ((c == ':' && chars[i + 1] == ':') || (c == '-' && chars[i + 1] == '>')) {
      i += 2
    } else { i += 1 }
    tokens.push({ text: String::from_array(chars[start:i]), offset: start })
  }
  tokens
}

///|
fn moonbit_token_group(tokens : Array[MoonbitCallToken], start : Int32,
  open : String, close : String) -> Int32 {
  if start >= tokens.length() || tokens[start].text != open { return start }
  let mut depth = 0
  let mut i = start
  while i < tokens.length() {
    if tokens[i].text == open { depth += 1 }
    else if tokens[i].text == close {
      depth -= 1
      if depth == 0 { return i + 1 }
    }
    i += 1
  }
  tokens.length()
}

///|
fn moonbit_function_names(tokens : Array[MoonbitCallToken]) -> Set[Int32] {
  let names : Set[Int32] = Set::from_iter([].iter())
  for i in 0..<tokens.length() {
    if tokens[i].text != "fn" && tokens[i].text != "with" { continue }
    let mut j = i + 1
    if j < tokens.length() && tokens[j].text == "[" {
      j = moonbit_token_group(tokens, j, "[", "]")
    }
    let mut last = -1
    while j < tokens.length() {
      let text = tokens[j].text
      if text == "(" {
        if last >= 0 { names.add(last) }
        break
      }
      if text == "{" || text == "}" || text == "=" || text == ";" { break }
      if text != "::" && text != "." && text != "@" {
        let chars = text.to_array()
        if chars.is_empty() || !moonbit_is_ident_start(chars[0]) { break }
        last = j
      }
      j += 1
    }
  }
  names
}

///|
/// Top-level test blocks are test code even inside ordinary .mbt files.
fn moonbit_test_spans(declarations : String) -> Array[Bool] {
  let chars = declarations.to_array()
  let mask = Array::make(chars.length(), false)
  let mut depth = 0
  let mut prefix = true
  let mut pending = false
  let mut in_test = false
  for i in 0..<chars.length() {
    let c = chars[i]
    if depth == 0 && prefix && moonbit_match_word(chars, i, "test") { pending = true }
    mask[i] = in_test || pending
    if c == '{' {
      depth += 1
      if pending { in_test = true; pending = false }
    } else if c == '}' {
      if depth > 0 { depth -= 1 }
      if depth == 0 { in_test = false }
    }
    if c == '\n' { prefix = true }
    else if c != ' ' && c != '\t' && c != '\r' { prefix = false }
  }
  mask
}

///|
fn moonbit_call_position(code : String, offset : Int32) -> (Int32, Int32) {
  let chars = code.to_array()
  let mut line = 1
  let mut column = 1
  for i in 0..<offset {
    if chars[i] == '\n' { line += 1; column = 1 }
    else { column += 1 }
  }
  (line, column)
}

///|
/// Syntactic call checks deliberately do not claim binding/type resolution.
/// Qualified user methods named panic/println are not treated as builtins;
/// unwrap is an advisory policy on a method name, not proof of a panic.
fn moonbit_call_findings(rel : String, source : String, view : MoonbitLexView,
  rule : StructuralRule) -> Array[Finding] {
  let findings : Array[Finding] = []
  let tokens = moonbit_call_tokens(view.code)
  let declarations = moonbit_function_names(tokens)
  let tests = moonbit_test_spans(view.declarations)
  for i in 0..<tokens.length() {
    let token = tokens[i]
    if declarations.contains(i) || tests[token.offset] { continue }
    if i + 1 >= tokens.length() || tokens[i + 1].text != "(" { continue }
    let after = moonbit_token_group(tokens, i + 1, "(", ")")
    if after < tokens.length() &&
      (tokens[after].text == "->" || tokens[after].text == "raise") { continue }
    let qualified = i > 0 && (tokens[i - 1].text == "." || tokens[i - 1].text == "::")
    let builtin = i >= 3 && tokens[i - 3].text == "@" &&
      tokens[i - 2].text == "builtin" && tokens[i - 1].text == "."
    let matches = match rule.check {
      MoonbitNoUnwrap => token.text == "unwrap" && qualified
      MoonbitNoPanic => token.text == "panic" && (!qualified || builtin)
      MoonbitNoPrintln => token.text == "println" && (!qualified || builtin)
      _ => false
    }
    if matches {
      let (line, column) = moonbit_call_position(view.code, token.offset)
      findings.push({ rule_id: rule.id, severity: rule.severity,
        message: rule.message, file: rel, line, column,
        snippet: moonbit_snippet(source, line) })
    }
  }
  findings
}

///|
fn moonbit_todo_findings(rel : String, source : String, view : MoonbitLexView,
  rule : StructuralRule) -> Array[Finding] {
  let findings : Array[Finding] = []
  let tests = moonbit_test_spans(view.declarations)
  let mut offset = 0
  let comment_lines = view.comments.split("\n").map(line => line.to_owned()).to_array()
  for idx in 0..<comment_lines.length() {
    let comment = comment_lines[idx]
    let line = idx + 1
    let trimmed = comment.trim().to_owned()
    let text = if trimmed.has_prefix("//") {
      let chars = trimmed.to_array()
      let mut start = 0
      while start < chars.length() && chars[start] == '/' { start += 1 }
      String::from_array(chars[start:]).trim().to_owned()
    } else if trimmed.has_prefix("/*") {
      trimmed[2:].trim().to_owned()
    } else if trimmed.has_prefix("*") { trimmed[1:].trim().to_owned() }
    else { "" }
    let marker = text.has_prefix("TODO") || text.has_prefix("FIXME")
    let end = if text.has_prefix("TODO") { 4 } else { 5 }
    let chars = text.to_array()
    if marker && (chars.length() == end ||
      (chars.length() > end && (chars[end] == ':' || chars[end] == ' ' || chars[end] == '\t'))) {
      let colchars = comment.to_array()
      let mut start = 0
      while start < colchars.length() && colchars[start] == ' ' { start += 1 }
      if offset + start < tests.length() && !tests[offset + start] {
        findings.push({ rule_id: rule.id, severity: rule.severity,
          message: rule.message, file: rel, line, column: start + 1,
          snippet: moonbit_snippet(source, line) })
      }
    }
    offset += comment.to_array().length() + 1
  }
  findings
}
