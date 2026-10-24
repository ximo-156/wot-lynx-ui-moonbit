///|
/// A JavaScript/TypeScript tokenizer.
///
/// This is the foundation of moonlint's structural analysis: where the line
/// matcher sees text, the tokenizer sees tokens, so rules can reason about
/// declarations, imports and exports instead of line shapes.
///
/// The scanner is a single left-to-right pass with an explicit mode stack:
///
/// - Strings (`'...'`, `"..."`) are consumed whole, so a `//` inside a string
///   is text, never a comment opener.
/// - Template literals are decomposed into `` ` `` / `${` / `}` delimiters plus
///   raw `TemplateText` runs, so identifiers inside `${...}` interpolations are
///   still visible as ordinary identifier tokens.
/// - Comments are skipped entirely (their positions never reach the parser).
/// - A `/` is a regex literal or the division operator depending on the
///   previous token; the same keyword heuristic the comment stripper uses
///   decides it here.
///
/// Every token carries a 1-based line and column counted in characters, not
/// bytes, so positions stay correct after multi-byte text.

///|
/// The lexical class of a token.
pub enum TokenKind {
  /// An identifier or keyword; the parser separates the two.
  Ident
  /// A numeric literal (decimal, hex, octal, binary, bigint, separators).
  Number
  /// A quoted string literal, including its quotes.
  Str
  /// A raw run of template-literal body text between delimiters.
  TemplateText
  /// A backtick opening or closing a template literal.
  Backtick
  /// The `${` that opens a template interpolation.
  InterpOpen
  /// The `}` that closes a template interpolation.
  InterpClose
  /// A regular-expression literal, including its flags.
  RegexLit
  /// Any other operator or punctuation character.
  Punct
} derive(Debug, Eq)

///|
/// A token with its source position. `line` and `column` are 1-based and count
/// characters; `text` is the exact source slice the token covers.
pub struct Token {
  kind : TokenKind
  text : String
  line : Int32
  column : Int32
} derive(Debug)

///|
/// Tokenize a whole source file. The scan never fails: malformed input (an
/// unterminated string, a stray `$`) is consumed on a best-effort basis and
/// reported as tokens, because a linter must not lose findings to a typo.
pub fn tokenize(src : String) -> Array[Token] {
  let chars = src.to_array()
  let n = chars.length()
  let tokens : Array[Token] = []
  // Position tracking. `line` starts at 1 so the first token reports 1:1.
  let mut line = 1
  let mut col = 1
  // Mode stack for template literals. Each entry is either -1 ("inside the
  // template body") or the brace depth of one open `${...}` interpolation.
  let frames : Array[Int32] = []
  // Whether a `/` here starts a regex literal (true after operators and
  // expression keywords, false after values and identifiers).
  let mut regex_ok = true
  // The identifier just scanned, for the keyword heuristic below.
  let mut word = ""
  let mut i = 0
  // A `#!` hashbang line is a comment in JavaScript.
  if n >= 2 && chars[0] == '#' && chars[1] == '!' {
    while i < n && !is_line_break(chars[i]) {
      i += 1
      col += 1
    }
  }
  while i < n {
    let c = chars[i]
    // ---- line breaks ------------------------------------------------
    if is_line_break(c) {
      // CRLF is one break, not two.
      if c == '\r' && i + 1 < n && chars[i + 1] == '\n' {
        i += 2
      } else {
        i += 1
      }
      line += 1
      col = 1
      continue
    }
    // ---- whitespace --------------------------------------------------
    if c == ' ' || c == '\u{9}' || c == '\u{B}' || c == '\u{C}' || c == '\u{A0}' {
      i += 1
      col += 1
      continue
    }
    // ---- comments -----------------------------------------------------
    if c == '/' && i + 1 < n && (chars[i + 1] == '/' || chars[i + 1] == '*') {
      if chars[i + 1] == '/' {
        i += 2
        col += 2
        while i < n && !is_line_break(chars[i]) {
          i += 1
          col += 1
        }
      } else {
        i += 2
        col += 2
        while i < n {
          if chars[i] == '*' && i + 1 < n && chars[i + 1] == '/' {
            i += 2
            col += 2
            break
          }
          if is_line_break(chars[i]) {
            line += 1
            col = 1
          } else {
            col += 1
          }
          i += 1
        }
      }
      // Comments do not change regex context: `x /* c */ /re/` still divides.
      continue
    }
    // ---- template body ------------------------------------------------
    if !frames.is_empty() && frames[frames.length() - 1] == -1 {
      if c == '$' && i + 1 < n && chars[i + 1] == '{' {
        tokens.push({
          kind: TokenKind::InterpOpen,
          text: "${",
          line,
          column: col,
        })
        i += 2
        col += 2
        frames[frames.length() - 1] = 0
        regex_ok = true
        word = ""
        continue
      }
      if c == backtick() {
        tokens.push({ kind: TokenKind::Backtick, text: "`", line, column: col, })
        i += 1
        col += 1
        ignore(frames.pop())
        regex_ok = false
        word = ""
        continue
      }
      // Raw template text: consume until the next delimiter, remembering
      // backslash escapes so `\${` does not open an interpolation.
      let start = i
      let start_line = line
      let start_col = col
      let mut escaped = false
      while i < n {
        let t = chars[i]
        if escaped {
          escaped = false
        } else if t == '\\' {
          escaped = true
        } else if t == backtick() ||
          (t == '$' && i + 1 < n && chars[i + 1] == '{') {
          break
        }
        if is_line_break(t) {
          line += 1
          col = 1
        } else {
          col += 1
        }
        i += 1
      }
      if i > start {
        tokens.push({
          kind: TokenKind::TemplateText,
          text: String::from_array(chars[start:i]),
          line: start_line,
          column: start_col,
        })
      }
      continue
    }
    // ---- backtick: enter a template body -------------------------------
    if c == backtick() {
      tokens.push({ kind: TokenKind::Backtick, text: "`", line, column: col, })
      i += 1
      col += 1
      frames.push(-1)
      regex_ok = false
      word = ""
      continue
    }
    // ---- strings --------------------------------------------------------
    if c == '\'' || c == '"' {
      let start = i
      let start_line = line
      let start_col = col
      let quote = c
      i += 1
      col += 1
      let mut escaped = false
      while i < n {
        let s = chars[i]
        if escaped {
          escaped = false
        } else if s == '\\' {
          escaped = true
        } else if s == quote {
          // The closing quote belongs to the string.
          i += 1
          col += 1
          break
        } else if is_line_break(s) {
          // A line break ends an unterminated string; it is left for the
          // line-break branch to account for, so the linter keeps scanning
          // the next line instead of swallowing the rest of the file.
          break
        }
        if is_line_break(s) {
          line += 1
          col = 1
        } else {
          col += 1
        }
        i += 1
      }
      tokens.push({
        kind: TokenKind::Str,
        text: String::from_array(chars[start:i]),
        line: start_line,
        column: start_col,
      })
      regex_ok = false
      word = ""
      continue
    }
    // ---- regex literal vs division --------------------------------------
    if c == '/' && regex_ok {
      match regex_literal_span(chars, i) {
        Some(end) => {
          let start = i
          let start_line = line
          let start_col = col
          while i <= end {
            if is_line_break(chars[i]) {
              line += 1
              col = 1
            } else {
              col += 1
            }
            i += 1
          }
          tokens.push({
            kind: TokenKind::RegexLit,
            text: String::from_array(chars[start:i]),
            line: start_line,
            column: start_col,
          })
          regex_ok = false
          word = ""
          continue
        }
        None => ()
      }
    }
    // ---- numbers ----------------------------------------------------------
    if is_digit(c) || (c == '.' && i + 1 < n && is_digit(chars[i + 1])) {
      let start = i
      let start_line = line
      let start_col = col
      // Hex/octal/binary prefixes consume their own alphabet.
      if c == '0' &&
        i + 1 < n &&
        (
          chars[i + 1] == 'x' ||
          chars[i + 1] == 'X' ||
          chars[i + 1] == 'o' ||
          chars[i + 1] == 'O' ||
          chars[i + 1] == 'b' ||
          chars[i + 1] == 'B'
        ) {
        i += 2
        col += 2
        while i < n && (lex_ident_char(chars[i]) || chars[i] == '.') {
          i += 1
          col += 1
        }
      } else {
        while i < n && (is_digit(chars[i]) || chars[i] == '_') {
          i += 1
          col += 1
        }
        if i < n && chars[i] == '.' {
          i += 1
          col += 1
          while i < n && (is_digit(chars[i]) || chars[i] == '_') {
            i += 1
            col += 1
          }
        }
        // Exponent, with an optional sign.
        if i < n && (chars[i] == 'e' || chars[i] == 'E') {
          let save_i = i
          let save_col = col
          i += 1
          col += 1
          if i < n && (chars[i] == '+' || chars[i] == '-') {
            i += 1
            col += 1
          }
          if i < n && is_digit(chars[i]) {
            while i < n && (is_digit(chars[i]) || chars[i] == '_') {
              i += 1
              col += 1
            }
          } else {
            // Not an exponent after all; rewind so `1e` stays two tokens.
            i = save_i
            col = save_col
          }
        }
        // Bigint suffix.
        if i < n && chars[i] == 'n' {
          i += 1
          col += 1
        }
      }
      tokens.push({
        kind: TokenKind::Number,
        text: String::from_array(chars[start:i]),
        line: start_line,
        column: start_col,
      })
      regex_ok = false
      word = ""
      continue
    }
    // ---- identifiers --------------------------------------------------------
    if lex_ident_start(c) {
      let start = i
      let start_line = line
      let start_col = col
      while i < n && lex_ident_char(chars[i]) {
        i += 1
        col += 1
      }
      let text = String::from_array(chars[start:i])
      tokens.push({
        kind: TokenKind::Ident,
        text,
        line: start_line,
        column: start_col,
      })
      word = text
      // After a value-like identifier a `/` divides; after an expression
      // keyword it starts a regex.
      regex_ok = lex_regex_ok_after_keyword(text)
      continue
    }
    // ---- punctuation ---------------------------------------------------------
    // A `}` closes an interpolation when the innermost template frame has no
    // open braces of its own; otherwise it is an ordinary block brace.
    if c == '}' && !frames.is_empty() {
      let top = frames.length() - 1
      if frames[top] == 0 {
        tokens.push({
          kind: TokenKind::InterpClose,
          text: "}",
          line,
          column: col,
        })
        i += 1
        col += 1
        frames[top] = -1
        regex_ok = false
        word = ""
        continue
      }
      if frames[top] > 0 {
        // An ordinary brace inside the interpolation.
        frames[top] -= 1
      }
    }
    if c == '{' && !frames.is_empty() && frames[frames.length() - 1] >= 0 {
      frames[frames.length() - 1] += 1
    }
    tokens.push({
      kind: TokenKind::Punct,
      text: c.to_string(),
      line,
      column: col,
    })
    i += 1
    col += 1
    regex_ok = regex_ok_after_punct(c)
    word = ""
  }
  tokens
}

///|
/// The backtick character, built from its code point: a backtick inside a
/// char literal reads as a template-string delimiter in MoonBit source.
fn backtick() -> Char {
  Char::from_int(96)
}

///|
/// Whether `c` ends a line: the JavaScript line-terminator set includes the
/// Unicode separators, not just CR/LF.
fn is_line_break(c : Char) -> Bool {
  c == '\n' || c == '\r' || c == '\u{2028}' || c == '\u{2029}'
}

///|
/// Whether `c` may start an identifier. ASCII covers the common cases; every
/// non-ASCII character is accepted too, because JavaScript identifiers are
/// Unicode-aware and splitting them would corrupt positions.
fn lex_ident_start(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  c == '_' ||
  c == '$' ||
  c.to_int() >= 0x80
}

///|
/// Whether `c` may continue an identifier.
fn lex_ident_char(c : Char) -> Bool {
  lex_ident_start(c) || is_digit(c)
}

///|
/// Whether `c` is an ASCII digit.
fn is_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
/// After which keywords a `/` starts a regex rather than dividing. The list
/// matches the one used by the comment stripper, so both views of the source
/// agree on where literals are.
fn lex_regex_ok_after_keyword(word : String) -> Bool {
  if word == "" {
    return true
  }
  [
    "return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw",
    "case", "do", "else", "yield", "await",
  ].contains(word)
}

///|
/// Whether a `/` after this punctuation character starts a regex. After a
/// value (`]`, `)`) it divides; after every other operator it opens a regex.
fn regex_ok_after_punct(c : Char) -> Bool {
  c != ']' && c != ')'
}

///|
/// If a regex literal starts at `start` (its opening `/`), the index of the
/// last character of the literal including flags; `None` when the `/` is a
/// division operator (no closing `/` before a line break).
fn regex_literal_span(chars : Array[Char], start : Int32) -> Int32? {
  let n = chars.length()
  let mut i = start + 1
  let mut in_class = false
  while i < n {
    let c = chars[i]
    if is_line_break(c) {
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
    } else if c == '/' {
      let mut j = i + 1
      while j < n && is_ident_char(chars[j]) && !is_digit(chars[j]) {
        j += 1
      }
      return Some(j - 1)
    }
    i += 1
  }
  None
}

///|
/// Expose derived impls as regular methods for external callers.

///|
pub extend TokenKind with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend TokenKind with Eq::{equal, not_equal}

///|
pub extend Token with @moonbitlang/core/debug.Debug::{to_repr}
