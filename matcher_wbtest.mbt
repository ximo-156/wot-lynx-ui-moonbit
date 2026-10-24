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

///|
test "all requires every sub-matcher" {
  let m = All([Contains("console."), Contains("log")])
  assert_eq(m.matches("console.log(x)"), true)
  assert_eq(m.matches("console.warn(x)"), false)
  assert_eq(m.matches("logger.info(x)"), false)
}

///|
test "all with an empty list matches every line" {
  // Vacuous truth: there is no sub-matcher that could fail.
  assert_eq(All([]).matches("anything"), true)
  assert_eq(All([]).matches(""), true)
}

///|
test "any requires at least one sub-matcher" {
  let m = Any([Contains("TODO"), Contains("FIXME")])
  assert_eq(m.matches("// TODO: fix"), true)
  assert_eq(m.matches("// FIXME: fix"), true)
  assert_eq(m.matches("// nothing here"), false)
}

///|
test "any with an empty list matches no line" {
  assert_eq(Any([]).matches("anything"), false)
}

///|
test "not negates its sub-matcher" {
  let m = Not(Contains("allow"))
  assert_eq(m.matches("console.log(x)"), true)
  assert_eq(m.matches("console.log(x) // allow"), false)
}

///|
test "combinators nest arbitrarily deep" {
  // "contains console. but not on a line that mentions allow"
  let m = All([Contains("console."), Not(Contains("allow"))])
  assert_eq(m.matches("console.log(x)"), true)
  assert_eq(m.matches("console.log(x) // allow"), false)
  assert_eq(m.matches("logger.info(x)"), false)
  // Triple nesting: any of two all-groups, negated as a whole.
  let deep = Not(Any([All([Contains("a"), Contains("b")]), Word("skip")]))
  assert_eq(deep.matches("just a line"), true)
  assert_eq(deep.matches("a and b"), false)
  assert_eq(deep.matches("please skip"), false)
}

///|
test "prepared matchers evaluate combinators" {
  // Exercises the Prepared::AllOf / AnyOf / NotOf paths, not just the
  // direct MatchKind::matches recursion.
  let all = All([Contains("a"), Regex("b")]).prepare()
  assert_eq(all.matches("xxaxxb"), true)
  assert_eq(all.matches("xxaxx"), false)
  let any = Any([Regex("[invalid"), Contains("z")]).prepare()
  assert_eq(any.matches("no match"), false)
  assert_eq(any.matches("has z"), true)
  let not = Not(Regex("[bad")).prepare()
  assert_eq(not.matches("anything"), true)
}

///|
test "prepare collapses an all containing a never-match child" {
  // A bad regex child makes the whole All unable to fire.
  assert_true(All([Contains("a"), Regex("[bad")]).prepare() is NeverMatch)
  assert_true(All([Contains("a"), Any([])]).prepare() is NeverMatch)
}

///|
test "column_of reports the first matching sub-matcher column" {
  // All: both children match; the first child's column wins.
  let all = All([Contains("TODO"), Contains("log")])
  assert_eq(all.column_of("  // TODO log"), 6)
  // Any: only the second child matches; its column is used.
  let any = Any([Contains("absent"), Contains("b")])
  assert_eq(any.column_of("a b c"), 3)
  // Not has no positive pattern, so it falls back to the first non-space.
  let not = Not(Contains("absent"))
  assert_eq(not.column_of("   x"), 4)
}

///|
test "validate reports a bad regex nested in a combinator" {
  assert_eq(
    All([Contains("a"), Regex("[bad")]).validate(),
    Some("invalid regex: [bad"),
  )
  assert_eq(Any([Regex("ok")]).validate(), None)
  assert_eq(
    Not(All([Any([Regex("[bad")])])).validate(),
    Some("invalid regex: [bad"),
  )
  assert_eq(All([Not(Regex("ok"))]).validate(), None)
}
