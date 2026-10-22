///|
/// Comment stripping: the view of a source file that rules are matched against.
///
/// Comments are blanked in place so line and column positions are preserved.
/// JavaScript-family sources use a template- and regex-aware scanner; other
/// sources use the simpler quote-only view.

///|
/// The comment syntax in use for a file. `Js` understands template literals and
/// regex literals, so `//` inside a multi-line template string (a stringified
/// script, a URL fragment) is *not* treated as a comment; `Plain` treats quotes
/// as opaque and knows nothing about regex literals.
pub enum CommentMode {
  Js
  Plain
} derive(Debug, Eq)

///|
/// Entries of the JavaScript line-terminator set. `\n`, `\r`, U+2028 and U+2029
/// all end a `//` comment; treating any other rune as a break would hide code.
fn is_js_line_break(c : Char) -> Bool {
  c == '\n' || c == '\r' || c == '\u{2028}' || c == '\u{2029}'
}

///|
/// The backtick character. MoonBit reads a backtick inside a char literal as a
/// template-string delimiter, so a quoted backtick is not valid syntax; the
/// character is built from its code point instead.
fn backtick_ch() -> Char {
  Char::from_int(96)
}

///|
/// Blank comments without changing line or character positions.
///
/// `Js` keeps quotes, template literals and regex literals intact; `Plain` is
/// the quote-only view used for sources without regex literals.
fn strip_comments(src : String, mode : CommentMode) -> String {
  match mode {
    Js => strip_comments_js(src)
    Plain => strip_comments_plain(src)
  }
}

///|
/// The `$` that starts an interpolation.
const DOLLAR : Char = '$'

///|
/// The backslash that escapes the next character in a string or template.
///
/// Written as a code point rather than a char literal: the source text of an
/// escape is confusingly easy to get wrong, and a wrong one silently changes
/// which characters are copied.
const BS : Char = '\u{5C}'

///|
/// What the scanner is currently reading.
enum JsState {
  /// Ordinary code.
  Code
  /// A template literal body, where `//` and `/*` are text.
  Template
  /// Just after the `$` of a `${`, so the next `{` opens an interpolation body.
  InterpolationOpen
}

///|
/// Resume point for a multi-character token (a quoted string, a regex, an
/// interpolation depth).
priv struct Resume {
  index : Int32
  mode : ResumeMode
}

///|
priv enum ResumeMode {
  Each
  Skip
}

///|
/// Scan a JavaScript/TypeScript/JSX source, blanking comments and copying every
/// other character unchanged.
///
/// A small state machine drives the scan. `Template` marks a template-literal
/// body, where comment openers are text; `InterpolationOpen` marks the `{` that
/// follows a `$`, which re-enters the template body. `depths` counts the braces
/// of each open interpolation, and `regex_ok` records whether the previous
/// token may be followed by a regex literal.
fn strip_comments_js(src : String) -> String {
  let chars = src.to_array()
  let out : Array[Char] = []
  let n = chars.length()
  let mut i = 0
  let mut state = Code
  let depths : Array[Int32] = []
  let mut regex_ok = true
  let word : Array[Char] = []
  let mut escaped = false
  while i < n {
    let c = chars[i]
    match state {
      Template => {
        // A template body runs to the next unescaped backtick; until then
        // every character is copied as text, except that `${` opens code.
        if i + 1 < n && c == DOLLAR && chars[i + 1] == '{' {
          out.push(c)
          i += 1
          state = InterpolationOpen
          regex_ok = true
          word.clear()
          continue
        }
        if !escaped && c == backtick_ch() {
          out.push(c)
          i += 1
          state = Code
          regex_ok = false
          word.clear()
          escaped = false
          continue
        }
        out.push(c)
        escaped = !escaped && c == BS
        i += 1
      }
      InterpolationOpen => {
        // The `{` just opened by `${` returns to the template body. Any other
        // character is a stray `$`, so treat it as code again.
        if c == '{' {
          depths.push(0)
          out.push(c)
          i += 1
          state = Template
          escaped = false
          continue
        }
        out.push(c)
        i += 1
        state = Code
      }
      Code => {
        if c == slash() && i + 1 < n {
          let next = chars[i + 1]
          if next == slash() {
            while i < n && !is_js_line_break(chars[i]) {
              out.push(' ')
              i += 1
            }
            continue
          }
          if next == '*' {
            out.push(' ')
            out.push(' ')
            i += 2
            while i < n {
              if chars[i] == '*' && i + 1 < n && chars[i + 1] == slash() {
                out.push(' ')
                out.push(' ')
                i += 2
                break
              }
              out.push(if is_js_line_break(chars[i]) { chars[i] } else { ' ' })
              i += 1
            }
            continue
          }
          if regex_ok && regex_literal_ends_at(chars, i) is Some(end) {
            for k in i..<=end {
              out.push(chars[k])
            }
            i = end + 1
            regex_ok = false
            word.clear()
            continue
          }
          out.push(c)
          regex_ok = true
          word.clear()
          i += 1
          continue
        }
        if c == '{' {
          if depths.length() > 0 {
            depths[depths.length() - 1] += 1
          }
          out.push(c)
          regex_ok = true
          word.clear()
          i += 1
          continue
        }
        if c == '}' {
          if depths.length() > 0 {
            let top = depths.length() - 1
            if depths[top] == 0 {
              depths.pop() |> ignore
              state = Template
              escaped = false
            } else {
              depths[top] -= 1
            }
          }
          out.push(c)
          regex_ok = false
          word.clear()
          i += 1
          continue
        }
        if c == '\'' || c == '"' {
          out.push(c)
          let mut j = i + 1
          let mut quote_escape = false
          let mut closed = false
          while j < n && !closed {
            let inner = chars[j]
            out.push(inner)
            if quote_escape {
              quote_escape = false
            } else if inner == BS {
              quote_escape = true
            } else if inner == c || is_js_line_break(inner) {
              closed = true
            }
            j += 1
          }
          i = j
          regex_ok = false
          word.clear()
          continue
        }
        if c == backtick_ch() {
          out.push(c)
          i += 1
          state = Template
          escaped = false
          regex_ok = false
          word.clear()
          continue
        }
        if is_ident_char(c) {
          out.push(c)
          if is_ident_start(c) {
            word.push(c)
          } else {
            word.clear()
            regex_ok = false
          }
          i += 1
          continue
        }
        if is_js_line_break(c) || c == ' ' || c == '\u{9}' {
          out.push(c)
          i += 1
          continue
        }
        out.push(c)
        let postfix = (c == '+' || c == '-') && i + 1 < n && chars[i + 1] == c
        if c == ']' || c == ')' || postfix {
          regex_ok = false
        } else {
          regex_ok = regex_ok_after_keyword(String::from_array(word))
        }
        word.clear()
        i += 1
      }
    }
  }
  String::from_array(out)
}

///|
/// The `/` that starts a comment or regex literal, and the division operator.
fn slash() -> Char {
  Char::from_int(47)
}

///|

///|
/// Pick the comment syntax for a path: JavaScript/TypeScript-family sources get
/// the template- and regex-aware scanner; everything else keeps the plain view.
pub fn comment_mode_for(rel : String) -> CommentMode {
  let ext = match rel.rev_split_once(".") {
    Some((_, ext)) => ext.to_lower()
    None => return Plain
  }
  match ext {
    "js" | "jsx" | "ts" | "tsx" | "mjs" | "cjs" | "mts" | "cts" => Js
    _ => Plain
  }
}

///|
/// Whether `c` starts an identifier (a letter, `_` or `$`). Kept as a call
/// rather than an inline range test: the parser reads `chars[i] >= 'a'` as a
/// comparison between two generic instantiations, silently changing meaning.
fn is_ident_start(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$'
}

///|
/// Plain [A-Za-z0-9_$] test used for regex flags and identifier scanning.
fn is_ident_char(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '_' ||
  c == '$'
}

///|
/// The original quote-only stripper, kept for non-JS sources: quotes are opaque,
/// `//` and `/* */` comments are blanked, HTML comments are blanked too.
fn strip_comments_plain(src : String) -> String {
  let chars = src.to_array()
  let out : Array[Char] = []
  let mut i = 0
  let mut quote : Char? = None
  let mut escaped = false
  while i < chars.length() {
    let c = chars[i]
    if quote is Some(q) {
      out.push(c)
      if escaped {
        escaped = false
      } else if c == '\\' {
        escaped = true
      } else if c == q {
        quote = None
      }
      i += 1
      continue
    }
    if c == '\'' || c == '"' || c == backtick_ch() {
      quote = Some(c)
      out.push(c)
      i += 1
      continue
    }
    if c == '/' && i + 1 < chars.length() && chars[i + 1] == '/' {
      while i < chars.length() && chars[i] != '\n' {
        out.push(' ')
        i += 1
      }
      continue
    }
    let block_comment = c == '/' &&
      i + 1 < chars.length() &&
      chars[i + 1] == '*'
    let html_comment = c == '<' &&
      i + 3 < chars.length() &&
      chars[i + 1] == '!' &&
      chars[i + 2] == '-' &&
      chars[i + 3] == '-'
    if block_comment || html_comment {
      let opening = if html_comment { 4 } else { 2 }
      for _ in 0..<opening {
        out.push(' ')
      }
      i += opening
      while i < chars.length() {
        let closed = if html_comment {
          i + 2 < chars.length() &&
          chars[i] == '-' &&
          chars[i + 1] == '-' &&
          chars[i + 2] == '>'
        } else {
          i + 1 < chars.length() && chars[i] == '*' && chars[i + 1] == '/'
        }
        if closed {
          let closing = if html_comment { 3 } else { 2 }
          for _ in 0..<closing {
            out.push(' ')
          }
          i += closing
          break
        }
        out.push(
          if chars[i] == '\n' || chars[i] == '\r' {
            chars[i]
          } else {
            ' '
          },
        )
        i += 1
      }
      continue
    }
    out.push(c)
    i += 1
  }
  String::from_array(out)
}

///|

///|
fn regex_ok_after_keyword(word : String) -> Bool {
  if word == "" {
    return true
  }
  [
    "return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw",
    "case", "do", "else", "yield", "await",
  ].contains(word)
}

///|

///|
/// If a regex literal starts at `start` (the opening `/`), the index of its
/// closing `/` including any flags. Returns `None` at a line break, so `/` in
/// `a / b` is left as division.
fn regex_literal_ends_at(chars : Array[Char], start : Int32) -> Int32? {
  let n = chars.length()
  let mut i = start + 1
  let mut in_class = false
  while i < n {
    let c = chars[i]
    if is_js_line_break(c) {
      return None
    }
    if c == '\\' {
      i += 2
      continue
    }
    if in_class {
      if c == ']' {
        in_class = false
      }
    } else if c == '[' {
      in_class = true
    } else if c == slash() {
      let mut j = i + 1
      while j < n &&
            is_ident_char(chars[j]) &&
            !(chars[j] >= '0' && chars[j] <= '9') {
        j += 1
      }
      return Some(j - 1)
    }
    i += 1
  }
  None
}
