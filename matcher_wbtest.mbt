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
