///|
/// MoonBit source front end.
///
/// The JS/TS front end (`lex.mbt` / `parse.mbt`) cannot read MoonBit
/// syntax, so MoonBit files are handled by a declaration scanner instead:
/// comments and string literals are blanked in place, brace depth separates
/// top-level items from function/impl/test bodies, and `///|` blocks are
/// attached to the declaration that follows them. The compiler already offers
/// missing_doc (W74); this layer supplies configurable scopes, naming and
/// syntactic call policies without claiming a complete AST or type resolver.

///|
/// The kind of a top-level MoonBit declaration.
#derive(Debug, Eq)
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
  MSuberror
  MExtern
  MUsing
  MExtend
}

///|
/// One top-level declaration found in a MoonBit source file.
#derive(Debug)
priv struct MoonbitDecl {
  kind : MoonbitDeclKind
  /// The declared name. Empty when the syntax does not expose a simple name
  /// (for example `let (a, b) = ...` or `test { ... }`).
  name : String
  /// Receiver identity is retained for qualified methods.
  receiver : String
  /// 1-based line of the declaration keyword.
  line : Int32
  /// Whether the declaration starts with `pub` / `pub(...)`.
  is_pub : Bool
  /// Whether a `///|` doc block is attached to the declaration.
  has_doc : Bool
}

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
  moonbit_lex(src).declarations
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
  let mut receiver = ""
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
        receiver = first
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
    "suberror" => {
      let (name, _) = moonbit_read_word(chars, i)
      (MSuberror, name)
    }
    "extern" => {
      if moonbit_match_word(chars, i, "fn") {
        i = moonbit_skip_spaces(chars, i + 2)
      }
      let (name, _) = moonbit_read_word(chars, i)
      (MExtern, name)
    }
    "using" => (MUsing, "")
    "extend" => (MExtend, "")
    _ => return None
  }
  Some({ kind, name, receiver, line: lineno, is_pub, has_doc, })
}

///|
/// Scan an already-lexed MoonBit source for top-level declarations.
///
/// `///|` opens a documentation block; `///` lines continue it; `#...`
/// attribute lines may sit between the block and the declaration. Anything
/// else (a blank line, an ordinary comment, another declaration) closes the
/// pending block.
fn scan_moonbit_decls_view(view : MoonbitLexView) -> Array[MoonbitDecl] {
  let decls : Array[MoonbitDecl] = []
  let comments = split_lines(view.comments)
  let code_lines = split_lines(view.declarations)
  let mut depth = 0
  let mut doc_active = false
  let mut attribute_depth = 0
  for idx in 0..<code_lines.length() {
    let (lineno, code_line) = code_lines[idx]
    let (_, comment) = comments[idx]
    let text = comment.trim().to_owned()
    let mut code = code_line.trim().to_owned()
    if depth == 0 && code == "" && text.has_prefix("///|") {
      doc_active = false
      continue
    }
    if depth == 0 && code == "" && text.has_prefix("///") {
      if text[3:].trim().to_owned() != "" {
        doc_active = true
      }
      continue
    }
    if depth == 0 && (code.has_prefix("#") || attribute_depth > 0) {
      if code.contains("#doc(hidden)") {
        doc_active = true
      }
      let prefix = match moonbit_public_offset(code) {
        Some(offset) => String::from_array(code.to_array()[:offset])
        None => code
      }
      for c in prefix.iter() {
        if c == '(' || c == '[' {
          attribute_depth += 1
        } else if (c == ')' || c == ']') && attribute_depth > 0 {
          attribute_depth -= 1
        }
      }
      match moonbit_public_offset(code) {
        Some(offset) if attribute_depth == 0 =>
          code = String::from_array(code.to_array()[offset:])
        _ => {
          for c in code_line.iter() {
            if c == '{' {
              depth += 1
            } else if c == '}' && depth > 0 {
              depth -= 1
            }
          }
          continue
        }
      }
    }
    if code == "" {
      doc_active = false
      continue
    }
    if depth == 0 {
      match moonbit_parse_decl(code, lineno, doc_active) {
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
      } else if c == '}' && depth > 0 {
        depth -= 1
      }
    }
  }
  decls
}

///|
/// Lex and scan a MoonBit source file for top-level declarations.
fn scan_moonbit_decls(src : String) -> Array[MoonbitDecl] {
  scan_moonbit_decls_view(moonbit_lex(src))
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
    MSuberror => "suberror"
    MExtern => "extern fn"
    MUsing => "using"
    MExtend => "extend"
  }
}

///|
/// Whether a declaration kind is part of the public API surface and therefore
/// expected to carry a `///|` doc block when it is `pub`.
fn moonbit_needs_doc(kind : MoonbitDeclKind) -> Bool {
  match kind {
    MFn
    | MStruct
    | MEnum
    | MType
    | MTrait
    | MLet
    | MConst
    | MSuberror
    | MExtern => true
    MImpl | MTest | MUsing | MExtend => false
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
    MFn | MLet | MExtern => moonbit_is_snake(name)
    MStruct | MEnum | MType | MTrait | MSuberror => moonbit_is_pascal(name)
    MConst => moonbit_is_screaming(name)
    MImpl | MTest | MUsing | MExtend => true
  }
}

///|
fn moonbit_expected_style(kind : MoonbitDeclKind) -> String {
  match kind {
    MFn | MLet | MExtern => "snake_case"
    MStruct | MEnum | MType | MTrait | MSuberror => "PascalCase"
    MConst => "SCREAMING_SNAKE_CASE"
    MImpl | MTest | MUsing | MExtend => ""
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
    let view = moonbit_lex(source)
    let decls = scan_moonbit_decls_view(view)
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
                  "public \{moonbit_kind_name(decl.kind)} '\{decl.name}' has no non-empty doc comment",
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
        MoonbitNoUnwrap | MoonbitNoPanic | MoonbitNoPrintln =>
          for finding in moonbit_call_findings(rel, source, view, rule) {
            findings.push(finding)
          }
        MoonbitNoTodo =>
          for finding in moonbit_todo_findings(rel, source, view, rule) {
            findings.push(finding)
          }
        _ => ()
      }
    }
  }
  findings
}
