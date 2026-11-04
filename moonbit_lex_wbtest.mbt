///|
fn moonbit_test_rules(check : StructuralCheck) -> Array[StructuralRule] {
  [structural("test/code", Severity::warning(), "code policy", [".mbt"], check)]
}

///|
test "MoonBit empty block marker is not documentation" {
  let decls = scan_moonbit_decls("///|\npub fn empty() -> Unit {}\n")
  assert_eq(decls.length(), 1)
  assert_false(decls[0].has_doc)
  let documented = scan_moonbit_decls(
    "///|\n/// Real docs.\npub fn good() -> Unit {}\n",
  )
  assert_true(documented[0].has_doc)
}

///|
test "MoonBit raw quotes and interpolated text do not leak brace depth" {
  let raw =
    #|let template : String =
    #|  #|"
    #|pub fn after() -> Unit {}
  let decls = scan_moonbit_decls(raw)
  assert_eq(decls.length(), 2)
  assert_eq(decls[1].name, "after")
  let multiline =
    #|fn template() -> String {
    #|  $|{
    #|}
    #|pub fn after() -> Unit {}
  let found = scan_moonbit_decls(multiline)
  assert_eq(found.length(), 2)
  assert_eq(found[1].name, "after")
}

///|
test "MoonBit literal call text and qualified user methods are not builtin calls" {
  let src =
    #|fn text() -> String {
    #|  #|panic("text") println("text") value.unwrap()
    #|}
    #|fn Foo::panic(self : Foo) -> Unit {}
    #|fn Foo::println(self : Foo) -> Unit {}
    #|fn Foo::unwrap(self : Foo) -> Unit {}
    #|fn call() -> Unit { Foo::panic(); Foo::println() }
  for check in [MoonbitNoPanic, MoonbitNoPrintln, MoonbitNoUnwrap] {
    assert_eq(
      analyze_moonbit([("a.mbt", src)], moonbit_test_rules(check)).length(),
      0,
    )
  }
}

///|
test "MoonBit calls after strings and inside interpolations are found" {
  let src =
    #|fn run(value : Int?) -> String {
    #|  ignore("prefix"); panic()
    #|  ignore("prefix"); println("output")
    #|  let _ = "prefix"; value.unwrap()
    #|  "\{value.unwrap()}"
    #|}
  assert_eq(
    analyze_moonbit([("a.mbt", src)], moonbit_test_rules(MoonbitNoPanic)).length(),
    1,
  )
  assert_eq(
    analyze_moonbit([("a.mbt", src)], moonbit_test_rules(MoonbitNoPrintln)).length(),
    1,
  )
  let findings = analyze_moonbit(
    [("a.mbt", src)],
    moonbit_test_rules(MoonbitNoUnwrap),
  )
  assert_eq(findings.length(), 2)
  assert_eq(findings[0].line, 4)
  assert_eq(findings[1].line, 5)
  assert_true(findings[0].column > 1)
}

///|
test "MoonBit interpolations preserve nested code but not text for declarations" {
  let src =
    #|fn text(value : Int?) -> String {
    #|  $|literal { } " // text \{if true { value.unwrap() } else { 0 }}
    #|}
    #|pub fn after() -> Unit {}
  let view = moonbit_lex(src)
  assert_true(view.issues.is_empty())
  assert_true(view.code.contains("value.unwrap()"))
  assert_false(view.declarations.contains("value.unwrap()"))
  assert_eq(scan_moonbit_decls(src).length(), 2)
  assert_eq(
    analyze_moonbit([("a.mbt", src)], moonbit_test_rules(MoonbitNoUnwrap)).length(),
    1,
  )
}

///|
test "MoonBit top-level test bodies are exempt from call policies" {
  let src =
    #|test "allowed" { panic(); println("output"); value.unwrap() }
    #|fn run() -> Unit { panic() }
  let findings = analyze_moonbit(
    [("a.mbt", src)],
    moonbit_test_rules(MoonbitNoPanic),
  )
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].line, 2)
  assert_eq(
    analyze_moonbit([("a.mbt", src)], moonbit_test_rules(MoonbitNoPrintln)).length(),
    0,
  )
}

///|
test "MoonBit TODO checks see actual inline comments not raw string text" {
  let src =
    #|fn run() -> Unit {
    #|  let s = "// TODO: literal"
    #|  let t =
    #|    #|// FIXME: literal
    #|  ignore(s); ignore(t) // TODO: real
    #|  // FIXME later
    #|  /// a note about TODO markers
    #|  // TODOS are plural
    #|}
  let findings = analyze_moonbit(
    [("a.mbt", src)],
    moonbit_test_rules(MoonbitNoTodo),
  )
  assert_eq(findings.length(), 2)
  assert_eq(findings[0].line, 5)
  assert_eq(findings[1].line, 6)
}

///|
test "MoonBit suberror documentation and qualified receiver are indexed" {
  let src =
    #|pub(all) suberror MissingError { MissingError(String) }
    #|///|
    #|/// Method docs.
    #|pub fn Foo::method(self : Foo) -> Unit {}
  let decls = scan_moonbit_decls(src)
  assert_eq(decls.length(), 2)
  assert_eq(decls[0].kind, MSuberror)
  assert_eq(decls[1].receiver, "Foo")
  assert_true(decls[1].has_doc)
  assert_eq(
    analyze_moonbit(
      [("a.mbt", src)],
      moonbit_test_rules(MoonbitRequirePublicDoc),
    ).length(),
    1,
  )
}

///|
test "MoonBit multiline attributes preserve preceding documentation" {
  let src =
    #|///|
    #|/// Method docs.
    #|#deprecated(
    #|  "Use newer instead"
    #|)
    #|pub fn old_method() -> Unit {}
  assert_true(scan_moonbit_decls(src)[0].has_doc)
}

///|
test "MoonBit incomplete lexical inputs do not pass as complete" {
  assert_false(moonbit_lex("let s = \"unfinished\n").issues.is_empty())
  assert_false(moonbit_lex("/* unfinished").issues.is_empty())
  assert_false(moonbit_lex("let s = \"\\{value").issues.is_empty())
  assert_true(moonbit_lex("let s =\n  #|\"\n").issues.is_empty())
}

///|
test "MoonBit safe fixes keep raw and interpolated literal bytes intact" {
  let src =
    #|fn text() -> String {   
    #|  #|payload  
    #|}
    #|fn other() -> String {   
    #|  $|payload  
    #|}
  let fixed = fix_moonbit_whitespace(src, true, Some(4), true)
  assert_true(fixed.contains("#|payload  \n"))
  assert_true(fixed.contains("$|payload  \n"))
  assert_false(fixed.contains("{   \n"))
  assert_eq(fix_moonbit_whitespace(fixed, true, Some(4), true), fixed)
  let tabs = "\tlet s = \"a\tb\"\n\t#|a\tb\t  \n"
  let replaced = fix_moonbit_whitespace(tabs, true, Some(2), false)
  assert_true(replaced.contains("\"a\tb\""))
  assert_true(replaced.contains("#|a\tb\t  \n"))
  assert_true(replaced.has_prefix("  let"))
}

///|
test "MoonBit safe fixes preserve CRLF and skip final raw content newline" {
  let src = "let value = 1  \r\nlet other = 2"
  assert_eq(
    fix_moonbit_whitespace(src, true, None, true),
    "let value = 1\r\nlet other = 2\r\n",
  )
  let raw = "let value =\n  #|payload  "
  assert_eq(fix_moonbit_whitespace(raw, true, None, true), raw)
}
