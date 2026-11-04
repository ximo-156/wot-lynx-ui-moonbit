///|
/// Locate a public declaration keyword in already literal/comment-masked text.
fn moonbit_public_offset(code : String) -> Int32? {
  let chars = code.to_array()
  let word = c => c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
    (c >= '0' && c <= '9') || c.to_int() >= 128
  for i in 0..<chars.length() {
    if i + 2 < chars.length() && chars[i] == 'p' && chars[i + 1] == 'u' && chars[i + 2] == 'b' &&
      (i == 0 || !word(chars[i - 1])) && (i + 3 == chars.length() || !word(chars[i + 3])) {
      return Some(i)
    }
  }
  None
}

///|
/// Public syntax outside this declaration scanner's vocabulary is inconclusive,
/// not an undocumented declaration silently disappearing from a clean report.
fn moonbit_validate_public_coverage(view : MoonbitLexView) -> Unit raise {
  let mut depth = 0
  for (line, source) in split_lines(view.declarations) {
    let code = source.trim().to_owned()
    if depth == 0 {
      match moonbit_public_offset(code) {
        Some(offset) => {
          let tail = String::from_array(code.to_array()[offset:])
          match moonbit_parse_decl(tail, line, false) {
            Some(decl) if !moonbit_needs_doc(decl.kind) || decl.name != "" => ()
            _ => raise Failure("unsupported public declaration syntax at line \{line}; run moon check and review frontend coverage")
          }
        }
        None => ()
      }
    }
    for c in source.iter() {
      if c == '{' { depth += 1 } else if c == '}' && depth > 0 { depth -= 1 }
    }
  }
}

///|
test "same-line and multiline closing attributes retain public documentation checks" {
  for source in [
    "#cfg(target=\"native\") pub fn missing() -> Unit {}",
    "#cfg(\n target=\"native\"\n) pub fn missing() -> Unit {}",
    "#cfg(target=\"native\") pub fn missing(\n x : Int\n) -> Unit { ignore(x) }",
  ] {
    validate_moonbit_source(source)
    let declarations = scan_moonbit_decls(source)
    assert_eq(declarations.length(), 1)
    assert_eq(declarations[0].name, "missing")
    assert_false(declarations[0].has_doc)
  }
  let hidden = scan_moonbit_decls("#doc(hidden) pub fn hidden() -> Unit {}")
  assert_true(hidden[0].has_doc)
}

///|
test "unsupported public syntax is inconclusive and BOM does not hide a declaration" {
  for source in ["pub future_keyword NewThing", "pub fn @foreign.Type::read() -> Unit {}"] {
    assert_true((try? validate_moonbit_source(source)) is Err(_))
  }
  let declarations = scan_moonbit_decls("\u{FEFF}pub fn missing() -> Unit {}")
  assert_eq(declarations.length(), 1)
  assert_false(declarations[0].has_doc)
}
