///|
/// Tests for the MoonBit source front end.

///|
test "scan_moonbit_decls attaches doc blocks and records public items" {
  let src =
    #|///|
    #|/// Doc.
    #|pub fn good_name() -> Unit { }
    #|
    #|pub fn BadName() -> Unit { }
    #|
    #|///|
    #|/// Struct.
    #|#derive(Debug)
    #|pub struct Foo { }
    #|
    #|const lower = 1
    #|
  let decls = scan_moonbit_decls(src)
  assert_eq(decls.length(), 4)
  assert_eq(decls[0].kind, MFn)
  assert_eq(decls[0].name, "good_name")
  assert_eq(decls[0].line, 3)
  assert_true(decls[0].is_pub)
  assert_true(decls[0].has_doc)
  assert_eq(decls[1].name, "BadName")
  assert_eq(decls[1].line, 5)
  assert_true(decls[1].is_pub)
  assert_false(decls[1].has_doc)
  assert_eq(decls[2].kind, MStruct)
  assert_eq(decls[2].name, "Foo")
  assert_true(decls[2].has_doc)
  assert_eq(decls[3].kind, MConst)
  assert_eq(decls[3].name, "lower")
  assert_false(decls[3].is_pub)
}

///|
test "scan_moonbit_decls ignores strings, comments and nested bodies" {
  let src =
    #|pub fn outer() -> Unit {
    #|  let s = "pub fn fake() { }"
    #|  // pub fn fake2() { }
    #|}
    #|
    #|pub fn after() -> Unit { }
    #|
  let decls = scan_moonbit_decls(src)
  assert_eq(decls.length(), 2)
  assert_eq(decls[0].name, "outer")
  assert_eq(decls[1].name, "after")
}

///|
test "scan_moonbit_decls handles impl, test and method syntax" {
  let src =
    #|pub impl Show for Foo with fn output(self, logger) {
    #|}
    #|
    #|test "works" {
    #|  let x = 1
    #|}
    #|
    #|pub fn after() -> Unit { }
    #|
  let decls = scan_moonbit_decls(src)
  assert_eq(decls.length(), 3)
  assert_eq(decls[0].kind, MImpl)
  assert_eq(decls[0].name, "Foo")
  assert_eq(decls[1].kind, MTest)
  assert_eq(decls[2].name, "after")
}

///|
test "scan_moonbit_decls reads type parameters and qualified names" {
  let src =
    #|pub fn[T : Compare] maximum(x : T, y : T) -> T { x }
    #|pub fn Foo::method(self : Foo) -> Unit { }
    #|pub(all) struct Bar[T] { value : T }
    #|
  let decls = scan_moonbit_decls(src)
  assert_eq(decls.length(), 3)
  assert_eq(decls[0].name, "maximum")
  assert_eq(decls[1].name, "method")
  assert_eq(decls[2].name, "Bar")
  assert_true(decls[2].is_pub)
}

///|
test "analyze_moonbit reports missing public docs and bad names" {
  let src =
    #|///|
    #|/// Documented.
    #|pub fn good_name() -> Unit { }
    #|
    #|pub fn BadName() -> Unit { }
    #|pub struct bad_struct { }
    #|
  let rules = [
    structural(
      "test/require-public-doc",
      Severity::warning(),
      "missing doc",
      [".mbt"],
      MoonbitRequirePublicDoc,
    ),
    structural(
      "test/naming",
      Severity::warning(),
      "bad name",
      [".mbt"],
      MoonbitNaming,
    ),
  ]
  let findings = analyze_moonbit([("a.mbt", src)], rules)
  assert_eq(findings.length(), 4)
  assert_true(
    findings.any(f => f.rule_id == "test/require-public-doc" && f.line == 5),
  )
  assert_true(
    findings.any(f => f.rule_id == "test/require-public-doc" && f.line == 6),
  )
  assert_true(findings.any(f => f.rule_id == "test/naming" && f.line == 5))
  assert_true(findings.any(f => f.rule_id == "test/naming" && f.line == 6))
}

///|
test "analyze_moonbit ignores non-MoonBit files" {
  let src = "pub fn BadName() -> Unit { }\n"
  let rules = [
    structural(
      "test/naming",
      Severity::warning(),
      "bad name",
      [".mbt"],
      MoonbitNaming,
    ),
  ]
  let findings = analyze_moonbit([("a.ts", src)], rules)
  assert_eq(findings.length(), 0)
}
