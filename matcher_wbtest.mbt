///|
/// Tests for the matcher module.

///|
test "contains matches substring" {
  assert_eq(Contains("vue").matches("import from 'vue'"), true)
  assert_eq(Contains("xyz").matches("import from 'vue'"), false)
}

///|
test "has_prefix matches line start" {
  assert_eq(HasPrefix("import").matches("import x"), true)
  assert_eq(HasPrefix("export").matches("import x"), false)
}

///|
test "has_suffix matches line end" {
  assert_eq(HasSuffix(";").matches("let x = 1;"), true)
  assert_eq(HasSuffix(";").matches("let x = 1"), false)
}

///|
test "regex matches pattern" {
  let m = Regex("from[[:space:]]+['\"]vue['\"]")
  assert_eq(m.matches("import { x } from 'vue'"), true)
  assert_eq(m.matches("import { x } from 'vue-lynx'"), false)
}

///|
test "regex with invalid pattern returns false" {
  let m = Regex("[invalid")
  assert_eq(m.matches("anything"), false)
}

///|
test "validate accepts good regex" {
  assert_eq(Regex("[0-9]+").validate(), None)
}

///|
test "validate rejects bad regex" {
  assert_true(Regex("[bad").validate() is Some(_))
}

///|
test "equals matches trimmed line exactly" {
  assert_eq(Equals("export default").matches("export default"), true)
  assert_eq(Equals("export default").matches("  export default  "), true)
  assert_eq(Equals("export default").matches("export default x"), false)
  assert_eq(Equals("export default").matches("export"), false)
}

///|
test "word matches whole word only" {
  assert_eq(Word("foo").matches("let foo = 1"), true)
  assert_eq(Word("foo").matches("let foobar = 2"), false)
  assert_eq(Word("foo").matches("foo"), true)
  assert_eq(Word("foo").matches("foo_bar"), false)
  assert_eq(Word("foo").matches("myfoo"), false)
  assert_eq(Word("foo").matches("foo."), true)
  assert_eq(Word("foo").matches("(foo)"), true)
  assert_eq(Word("foo").matches(""), false)
}

///|
test "column_of points at the first match" {
  // Positions are character-based and 1-based, not byte offsets.
  assert_eq(MatchKind::Contains("TODO").column_of("    const x = TODO;"), 15)
  assert_eq(MatchKind::Contains("TODO").column_of("TODO"), 1)
  assert_eq(MatchKind::HasPrefix("import").column_of("import x from 'y'"), 1)
  assert_eq(MatchKind::HasSuffix(";").column_of("let x = 1;"), 10)
  assert_eq(MatchKind::Word("debugger").column_of("  debugger statement"), 3)
}

///|
test "column_of counts characters not bytes" {
  // Four CJK characters precede the pattern, so the match starts at column 5.
  assert_eq(MatchKind::Contains("TODO").column_of("中文注释TODO"), 5)
}

///|
test "column_of falls back to the first non-space column" {
  // A regex match position is not recoverable from the pattern alone.
  assert_eq(MatchKind::Regex("^\\s*debugger").column_of("   debugger"), 4)
  assert_eq(MatchKind::Contains("absent").column_of("    x"), 5)
}
