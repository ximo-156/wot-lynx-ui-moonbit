///|
/// MoonBit source front end.
///
/// The JS/TS front end (`lex.mbt` / `parse.mbt`) cannot read MoonBit
/// syntax, so MoonBit files are handled by a declaration scanner instead:
/// comments and string literals are blanked in place, brace depth separates
/// top-level items from function/impl/test bodies, and `///|` blocks are
/// attached to the declaration that follows them. That is enough for the
/// conventions neither `moon check` nor `moon fmt` enforces: public API
/// documentation, naming, and the panic-prone calls covered by the preset's
/// line rules.

///|
/// The kind of a top-level MoonBit declaration.
priv enum MoonbitDeclKind {
  MFn
  MStruct
  MEnum
  MType
  MTrait
  MImpl
  MLet
  MConst
  MTest
} derive(Debug, Eq)

///|
/// One top-level declaration found in a MoonBit source file.
priv struct MoonbitDecl {
  kind : MoonbitDeclKind
  /// The declared name. Empty when the syntax does not expose a simple name
  /// (for example `let (a, b) = ...` or `test { ... }`).
  name : String
  /// 1-based line of the declaration keyword.
  line : Int32
  /// Whether the declaration starts with `pub` / `pub(...)`.
  is_pub : Bool
  /// Whether a `///|` doc block is attached to the declaration.
  has_doc : Bool
} derive(Debug)

///|
/// Whether `c` can start a MoonBit identifier. Non-ASCII identifiers are not
/// classified here; they are left alone rather than guessed at.
fn moonbit_is_ident_start(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

///|
/// Whether `c` can continue a MoonBit identifier.
fn moonbit_is_ident_char(c : Char) -> Bool {
  moonbit_is_ident_start(c) || (c >= '0' && c <= '9')
}

///|
/// Blank comments and string/char literals in place, preserving newlines and
/// columns so brace depth and line numbers still line up with the raw source.
///
/// Block comments are handled even though current MoonBit style uses `//`:
/// an unrecognised comment opener would otherwise let braces inside it leak
/// into the depth count.
fn moonbit_strip(src : String) -> String {
  let chars = src.to_array()
  let out : Array[Char] = []
  let n = chars.length()
  let mut i = 0
  while i < n {
    let c = chars[i]
    if c == '/' && i + 1 < n && chars[i + 1] == '/' {
      while i < n && chars[i] != '\n' {
        out.push(' ')
        i += 1
      }
      continue
    }
    if c == '/' && i + 1 < n && chars[i + 1] == '*' {
      out.push(' ')
      out.push(' ')
      i += 2
      while i < n {
        if chars[i] == '*' && i + 1 < n && chars[i + 1] == '/' {
          out.push(' ')
          out.push(' ')
          i += 2
          break
        }
        if chars[i] == '\n' {
          out.push('\n')
        } else {
          out.push(' ')
        }
        i += 1
      }
      continue
    }
    if c == '"' || c == '\'' {
      let quote = c
      out.push(' ')
      i += 1
      let mut escaped = false
      while i < n {
        let d = chars[i]
        if escaped {
          escaped = false
          if d == '\n' {
            out.push('\n')
          } else {
            out.push(' ')
          }
          i += 1
          continue
        }
        if d == '\\' {
          escaped = true
          out.push(' ')
          i += 1
          continue
        }
        if d == quote {
          out.push(' ')
          i += 1
          break
        }
        if d == '\n' {
          out.push('\n')
        } else {
          out.push(' ')
        }
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
fn moonbit_skip_spaces(chars : Array[Char], start : Int32) -> Int32 {
  let mut i = start
  while i < chars.length() && (chars[i] == ' ' || chars[i] == '\t') {
    i += 1
  }
  i
}

///|
/// Read one identifier at `start`, returning it and the index after it.
fn moonbit_read_word(chars : Array[Char], start : Int32) -> (String, Int32) {
  let n = chars.length()
  let mut i = start
  if i >= n || !moonbit_is_ident_start(chars[i]) {
    return ("", start)
  }
  while i < n && moonbit_is_ident_char(chars[i]) {
    i += 1
  }
  (String::from_array(chars[start:i]), i)
}

///|
/// Whether `word` occurs at `start` and is not the prefix of a longer
/// identifier (`pub` must not match `public`).
fn moonbit_match_word(
  chars : Array[Char],
  start : Int32,
  word : String,
) -> Bool {
  let w = word.to_array()
  let n = chars.length()
  if start + w.length() > n {
    return false
  }
  for i in 0..<w.length() {
    if chars[start + i] != w[i] {
      return false
    }
  }
  let end = start + w.length()
  !(end < n && moonbit_is_ident_char(chars[end]))
}

///|
/// Skip a balanced `open`/`close` group starting at `start`. If no group
/// starts there, the index is returned unchanged.
fn moonbit_skip_group(
  chars : Array[Char],
  start : Int32,
  open : Char,
  close : Char,
) -> Int32 {
  if start >= chars.length() || chars[start] != open {
    return start
  }
  let mut i = start + 1
  let mut depth = 1
  while i < chars.length() && depth > 0 {
    if chars[i] == open {
      depth += 1
    } else if chars[i] == close {
      depth -= 1
    }
    i += 1
  }
  i
}

///|
/// Parse the declaration on one code line. `line` is the sanitized line, so
/// comments and literals are already blank. Returns `None` when the line does
/// not begin a declaration.
fn moonbit_parse_decl(
  line : String,
  lineno : Int32,
  has_doc : Bool,
) -> MoonbitDecl? {
  let chars = line.to_array()
  let n = chars.length()
  let mut i = moonbit_skip_spaces(chars, 0)
  if i >= n {
    return None
  }
  let mut is_pub = false
  if moonbit_match_word(chars, i, "pub") {
    is_pub = true
    i += 3
    i = moonbit_skip_spaces(chars, i)
    if i < n && chars[i] == '(' {
      i = moonbit_skip_group(chars, i, '(', ')')
      i = moonbit_skip_spaces(chars, i)
    }
  } else if moonbit_match_word(chars, i, "priv") {
    i += 4
    i = moonbit_skip_spaces(chars, i)
  }
  if moonbit_match_word(chars, i, "async") {
    i += 5
    i = moonbit_skip_spaces(chars, i)
  }
  let (keyword, after) = moonbit_read_word(chars, i)
  if keyword == "" {
    return None
  }
  i = moonbit_skip_spaces(chars, after)
  let (kind, name) = match keyword {
    "fn" => {
      if i < n && chars[i] == '[' {
        i = moonbit_skip_group(chars, i, '[', ']')
        i = moonbit_skip_spaces(chars, i)
      }
      let (first, j) = moonbit_read_word(chars, i)
      let mut name = first
      let mut k = j
      if k + 1 < n && chars[k] == ':' && chars[k + 1] == ':' {
        k += 2
        let (second, l) = moonbit_read_word(chars, k)
        if second != "" {
          name = second
        }
        k = l
      }
      ignore(k)
      (MFn, name)
    }
    "struct" => {
      if i < n && chars[i] == '[' {
        i = moonbit_skip_group(chars, i, '[', ']')
        i = moonbit_skip_spaces(chars, i)
      }
      let (name, _) = moonbit_read_word(chars, i)
      (MStruct, name)
    }
    "enum" => {
      if i < n && chars[i] == '[' {
        i = moonbit_skip_group(chars, i, '[', ']')
        i = moonbit_skip_spaces(chars, i)
      }
      let (name, _) = moonbit_read_word(chars, i)
      (MEnum, name)
    }
    "type" => {
      if i < n && chars[i] == '[' {
        i = moonbit_skip_group(chars, i, '[', ']')
        i = moonbit_skip_spaces(chars, i)
      }
      let (name, _) = moonbit_read_word(chars, i)
      (MType, name)
    }
    "trait" => {
      if i < n && chars[i] == '[' {
        i = moonbit_skip_group(chars, i, '[', ']')
        i = moonbit_skip_spaces(chars, i)
      }
      let (name, _) = moonbit_read_word(chars, i)
      (MTrait, name)
    }
    "let" => {
      let (first, j) = moonbit_read_word(chars, i)
      let mut name = first
      let mut k = j
      if name == "mut" {
        k = moonbit_skip_spaces(chars, k)
        let (second, l) = moonbit_read_word(chars, k)
        name = second
        k = l
      }
      ignore(k)
      (MLet, name)
    }
    "const" => {
      let (name, _) = moonbit_read_word(chars, i)
      (MConst, name)
    }
    "impl" => {
      if i < n && chars[i] == '[' {
        i = moonbit_skip_group(chars, i, '[', ']')
        i = moonbit_skip_spaces(chars, i)
      }
      let (first, j) = moonbit_read_word(chars, i)
      let mut name = first
      let mut k = j
      k = moonbit_skip_spaces(chars, k)
      if moonbit_match_word(chars, k, "for") {
        k += 3
        k = moonbit_skip_spaces(chars, k)
        let (target, l) = moonbit_read_word(chars, k)
        if target != "" {
          name = target
        }
        k = l
      }
      ignore(k)
      (MImpl, name)
    }
    "test" => (MTest, "")
    _ => return None
  }
  Some({ kind, name, line: lineno, is_pub, has_doc, })
}

///|
/// Scan a MoonBit source file for top-level declarations.
///
/// `///|` opens a documentation block; `///` lines continue it; `#...`
/// attribute lines may sit between the block and the declaration. Anything
/// else (a blank line, an ordinary comment, another declaration) closes the
/// pending block.
fn scan_moonbit_decls(src : String) -> Array[MoonbitDecl] {
  let decls : Array[MoonbitDecl] = []
  let raw_lines = split_lines(src)
  let code_lines = split_lines(moonbit_strip(src))
  let limit = if raw_lines.length() < code_lines.length() {
    raw_lines.length()
  } else {
    code_lines.length()
  }
  let mut depth = 0
  let mut doc_active = false
  for idx in 0..<limit {
    let (lineno, code_line) = code_lines[idx]
    let (_, raw_line) = raw_lines[idx]
    let raw_trim = raw_line.trim().to_owned()
    if depth == 0 && raw_trim.has_prefix("///|") {
      doc_active = true
      continue
    }
    if depth == 0 && raw_trim.has_prefix("///") {
      if doc_active {
        continue
      }
    }
    if raw_trim == "" {
      doc_active = false
      continue
    }
    if raw_trim.has_prefix("#") {
      continue
    }
    if depth == 0 {
      match
        moonbit_parse_decl(code_line.trim().to_owned(), lineno, doc_active) {
        Some(decl) => {
          decls.push(decl)
          doc_active = false
        }
        None => doc_active = false
      }
    } else {
      doc_active = false
    }
    for c in code_line.iter() {
      if c == '{' {
        depth += 1
      } else if c == '}' {
        if depth > 0 {
          depth -= 1
        }
      }
    }
  }
  decls
}

///|
fn moonbit_kind_name(kind : MoonbitDeclKind) -> String {
  match kind {
    MFn => "fn"
    MStruct => "struct"
    MEnum => "enum"
    MType => "type"
    MTrait => "trait"
    MImpl => "impl"
    MLet => "let"
    MConst => "const"
    MTest => "test"
  }
}

///|
/// Whether a declaration kind is part of the public API surface and therefore
/// expected to carry a `///|` doc block when it is `pub`.
fn moonbit_needs_doc(kind : MoonbitDeclKind) -> Bool {
  match kind {
    MFn | MStruct | MEnum | MType | MTrait | MLet | MConst => true
    MImpl | MTest => false
  }
}

///|
fn moonbit_is_snake(name : String) -> Bool {
  let chars = name.to_array()
  let n = chars.length()
  let mut i = 0
  while i < n && chars[i] == '_' {
    i += 1
  }
  if i >= n {
    return false
  }
  if chars[i] < 'a' || chars[i] > 'z' {
    return false
  }
  let mut prev_underscore = false
  for j in i..<n {
    let c = chars[j]
    if c == '_' {
      if prev_underscore {
        return false
      }
      prev_underscore = true
    } else if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') {
      prev_underscore = false
    } else {
      return false
    }
  }
  !prev_underscore
}

///|
fn moonbit_is_pascal(name : String) -> Bool {
  let chars = name.to_array()
  if chars.length() == 0 {
    return false
  }
  if chars[0] < 'A' || chars[0] > 'Z' {
    return false
  }
  for i in 1..<chars.length() {
    let c = chars[i]
    if !((c >= 'A' && c <= 'Z') ||
      (c >= 'a' && c <= 'z') ||
      (c >= '0' && c <= '9') ||
      c == '_') {
      return false
    }
  }
  true
}

///|
fn moonbit_is_screaming(name : String) -> Bool {
  let chars = name.to_array()
  if chars.length() == 0 {
    return false
  }
  if chars[0] < 'A' || chars[0] > 'Z' {
    return false
  }
  let mut prev_underscore = false
  for i in 1..<chars.length() {
    let c = chars[i]
    if c == '_' {
      if prev_underscore {
        return false
      }
      prev_underscore = true
    } else if (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
      prev_underscore = false
    } else {
      return false
    }
  }
  !prev_underscore
}

///|
fn moonbit_name_ok(kind : MoonbitDeclKind, name : String) -> Bool {
  match kind {
    MFn | MLet => moonbit_is_snake(name)
    MStruct | MEnum | MType | MTrait => moonbit_is_pascal(name)
    MConst => moonbit_is_screaming(name)
    MImpl | MTest => true
  }
}

///|
fn moonbit_expected_style(kind : MoonbitDeclKind) -> String {
  match kind {
    MFn | MLet => "snake_case"
    MStruct | MEnum | MType | MTrait => "PascalCase"
    MConst => "SCREAMING_SNAKE_CASE"
    MImpl | MTest => ""
  }
}

///|
fn moonbit_snippet(source : String, lineno : Int32) -> String {
  let mut current = 1
  for view in source.split("\n") {
    if current == lineno {
      return view.to_owned().trim().to_owned()
    }
    current += 1
  }
  ""
}

///|
fn moonbit_finding(
  rule : StructuralRule,
  rel : String,
  source : String,
  line : Int32,
  detail : String,
) -> Finding {
  {
    rule_id: rule.id,
    severity: rule.severity,
    message: "\{rule.message} (\{detail})",
    file: rel,
    line,
    column: 1,
    snippet: moonbit_snippet(source, line),
  }
}

///|
/// Evaluate the MoonBit structural rules over the scanned project sources.
/// Only `.mbt` files participate; every other extension is left to the JS/TS
/// analyzer.
fn analyze_moonbit(
  sources : Array[(String, String)],
  rules : Array[StructuralRule],
) -> Array[Finding] {
  let findings : Array[Finding] = []
  for (rel, source) in sources {
    if !rel.has_suffix(".mbt") {
      continue
    }
    let decls = scan_moonbit_decls(source)
    for rule in rules {
      if !rule.applies_to(rel) {
        continue
      }
      match rule.check {
        MoonbitRequirePublicDoc =>
          for decl in decls {
            if decl.is_pub && moonbit_needs_doc(decl.kind) && !decl.has_doc {
              findings.push(
                moonbit_finding(
                  rule,
                  rel,
                  source,
                  decl.line,
                  "public \{moonbit_kind_name(decl.kind)} '\{decl.name}' has no ///| doc comment",
                ),
              )
            }
          }
        MoonbitNaming =>
          for decl in decls {
            if decl.name != "" && !moonbit_name_ok(decl.kind, decl.name) {
              findings.push(
                moonbit_finding(
                  rule,
                  rel,
                  source,
                  decl.line,
                  "\{moonbit_kind_name(decl.kind)} '\{decl.name}' should be \{moonbit_expected_style(decl.kind)}",
                ),
              )
            }
          }
        _ => ()
      }
    }
  }
  findings
}
