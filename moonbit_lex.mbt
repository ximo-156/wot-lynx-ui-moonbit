///|
/// Shared MoonBit lexical views. Literal text is never code; interpolation
/// expressions are code for call checks but remain blank in declaration depth.
#derive(Debug)
priv struct MoonbitLexView {
  declarations : String
  code : String
  comments : String
  protected : Array[Bool]
  issues : Array[(Int32, String)]
}

///|
#derive(Debug)
priv enum MoonbitLexState {
  MLCode
  MLQuote(Char, Bool)
  MLRaw(Bool)
  MLInterpolation(Int32)
}

///|
fn moonbit_lex(src : String) -> MoonbitLexView {
  let chars = src.to_array()
  let blank = c => if c == '\n' || c == '\r' { c } else { ' ' }
  let declarations = chars.map(blank)
  let code = chars.map(blank)
  let comments = chars.map(blank)
  let protected = Array::make(chars.length(), false)
  let issues : Array[(Int32, String)] = []
  let stack : Array[MoonbitLexState] = [MLCode]
  let mut i = 0
  let mut line = 1
  let mut prefix = true
  while i < chars.length() {
    let c = chars[i]
    if i == 0 && c == '\u{FEFF}' {
      i += 1
      continue
    }
    let state = stack[stack.length() - 1]
    if c == '\n' {
      match state {
        MLRaw(_) => ignore(stack.pop())
        MLQuote(_, _) | MLInterpolation(_) => {
          issues.push(
            (line, "unterminated string or interpolation at line end"),
          )
          while stack.length() > 1 {
            ignore(stack.pop())
          }
        }
        MLCode => ()
      }
      line += 1
      prefix = true
      i += 1
      continue
    }
    match state {
      MLRaw(interpolate) => {
        protected[i] = true
        if interpolate && c == '\\' && i + 1 < chars.length() {
          protected[i + 1] = true
          if chars[i + 1] == '{' {
            stack.push(MLInterpolation(0))
            i += 2
            continue
          }
          // Escaped characters in $| remain literal, including an escaped slash.
          if chars[i + 1] != '\n' {
            i += 2
            continue
          }
        }
        i += 1
        continue
      }
      MLQuote(quote, interpolate) => {
        protected[i] = true
        if c == '\\' && i + 1 < chars.length() {
          protected[i + 1] = true
          if interpolate && chars[i + 1] == '{' {
            stack.push(MLInterpolation(0))
            i += 2
            continue
          }
          if chars[i + 1] != '\n' {
            i += 2
            continue
          }
        }
        if c == quote {
          ignore(stack.pop())
        }
        i += 1
        continue
      }
      MLCode | MLInterpolation(_) => ()
    }
    let in_literal = stack.length() > 1
    protected[i] = in_literal
    if !in_literal &&
      prefix &&
      (c == '#' || c == '$') &&
      i + 1 < chars.length() &&
      chars[i + 1] == '|' {
      protected[i] = true
      protected[i + 1] = true
      stack.push(MLRaw(c == '$'))
      prefix = false
      i += 2
      continue
    }
    if c == '/' && i + 1 < chars.length() && chars[i + 1] == '/' {
      prefix = false
      while i < chars.length() && chars[i] != '\n' {
        comments[i] = chars[i]
        protected[i] = in_literal
        i += 1
      }
      continue
    }
    if c == '/' && i + 1 < chars.length() && chars[i + 1] == '*' {
      let opened = line
      let mut depth = 1
      comments[i] = '/'
      comments[i + 1] = '*'
      protected[i] = in_literal
      protected[i + 1] = in_literal
      i += 2
      while i < chars.length() && depth > 0 {
        if i + 1 < chars.length() && chars[i] == '/' && chars[i + 1] == '*' {
          comments[i] = '/'
          comments[i + 1] = '*'
          protected[i] = in_literal
          protected[i + 1] = in_literal
          depth += 1
          i += 2
        } else if i + 1 < chars.length() &&
          chars[i] == '*' &&
          chars[i + 1] == '/' {
          comments[i] = '*'
          comments[i + 1] = '/'
          protected[i] = in_literal
          protected[i + 1] = in_literal
          depth -= 1
          i += 2
        } else {
          comments[i] = chars[i]
          protected[i] = in_literal
          if chars[i] == '\n' {
            line += 1
          }
          i += 1
        }
      }
      if depth != 0 {
        issues.push((opened, "unterminated block comment"))
      }
      prefix = false
      continue
    }
    if c == '"' || c == '\'' {
      protected[i] = true
      let bytes = i > 0 &&
        chars[i - 1] == 'b' &&
        (i < 2 || !moonbit_is_ident_char(chars[i - 2]))
      stack.push(MLQuote(c, c == '"' && !bytes))
      prefix = false
      i += 1
      continue
    }
    match state {
      MLInterpolation(depth) => {
        if c == '}' && depth == 0 {
          ignore(stack.pop())
          i += 1
          prefix = false
          continue
        }
        if c == '{' {
          stack[stack.length() - 1] = MLInterpolation(depth + 1)
        } else if c == '}' {
          stack[stack.length() - 1] = MLInterpolation(depth - 1)
        }
      }
      _ => ()
    }
    code[i] = c
    if !in_literal {
      declarations[i] = c
    }
    if c != ' ' && c != '\t' && c != '\r' {
      prefix = false
    }
    i += 1
  }
  if stack.length() > 1 {
    match stack[stack.length() - 1] {
      MLRaw(_) => ()
      _ =>
        issues.push(
          (line, "unterminated string or interpolation at end of file"),
        )
    }
  }
  {
    declarations: String::from_array(declarations),
    code: String::from_array(code),
    comments: String::from_array(comments),
    protected,
    issues,
  }
}

///|
fn moonbit_code_and_comments(view : MoonbitLexView) -> String {
  let code = view.code.to_array()
  let comments = view.comments.to_array()
  for i in 0..<code.length() {
    if comments[i] != ' ' {
      code[i] = comments[i]
    }
  }
  String::from_array(code)
}

///|
/// Reject incomplete lexical input instead of counting it as a clean scan.
/// This checks lexical coverage only, not MoonBit types or the full grammar.
pub fn validate_moonbit_source(source : String) -> Unit raise {
  validate_moonbit_view(moonbit_lex(source))
}

///|
/// Validation over an already-computed view, so a caller that needs the views
/// anyway (the scan engine, the declaration scanner) lexes the file once
/// instead of once per consumer.
fn validate_moonbit_view(view : MoonbitLexView) -> Unit raise {
  if !view.issues.is_empty() {
    let (line, message) = view.issues[0]
    raise Failure(
      "incomplete MoonBit lexical input at line \{line}: \{message}",
    )
  }
  moonbit_validate_public_coverage(view)
}

///|
/// Fix only whitespace outside MoonBit literal spans. Interpolation and raw
/// string bodies remain byte-for-byte unchanged; incomplete input is rejected.
/// A final newline is not inserted into a final raw-string content line.
pub fn fix_moonbit_whitespace(
  source : String,
  trailing : Bool,
  tab_width : Int32?,
  final_newline : Bool,
) -> String raise {
  validate_moonbit_source(source)
  let view = moonbit_lex(source)
  let chars = source.to_array()
  let remove = Array::make(chars.length(), false)
  if trailing {
    let mut start = 0
    for i in 0..<=chars.length() {
      if i == chars.length() || chars[i] == '\n' {
        let mut end = i
        if end > start && chars[end - 1] == '\r' {
          end -= 1
        }
        let mut last = end
        while last > start &&
              (chars[last - 1] == ' ' || chars[last - 1] == '\t') {
          last -= 1
        }
        for j in last..<end {
          if !view.protected[j] {
            remove[j] = true
          }
        }
        start = i + 1
      }
    }
  }
  let out = StringBuilder::new()
  for i in 0..<chars.length() {
    if remove[i] {
      continue
    }
    if chars[i] == '\t' && !view.protected[i] {
      match tab_width {
        Some(width) => {
          if width < 1 {
            raise Failure("tab width must be positive")
          }
          out.write_string(" ".repeat(width))
        }
        None => out.write_char(chars[i])
      }
    } else {
      out.write_char(chars[i])
    }
  }
  let fixed = out.to_string()
  if final_newline && !fixed.is_empty() && !fixed.has_suffix("\n") {
    let raw_lines = fixed.split("\n").to_array()
    let last = raw_lines[raw_lines.length() - 1].trim().to_owned()
    if !last.has_prefix("#|") && !last.has_prefix("$|") {
      return fixed + (if source.contains("\r\n") { "\r\n" } else { "\n" })
    }
  }
  fixed
}
