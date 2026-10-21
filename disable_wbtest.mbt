///|
/// Tests for inline disable comment parsing.

///|
test "disable-next-line suppresses all rules on next line" {
  let source = "// moonlint-disable-next-line\nconst x = 1\nconst y = 2\n"
  let map = parse_disable_comments(source)
  assert_true(map.is_disabled("any/rule", 2))
  assert_false(map.is_disabled("any/rule", 3))
}

///|
test "disable-next-line with rule id suppresses only that rule" {
  let source = "// moonlint-disable-next-line no-foo\nconst x = 1\n"
  let map = parse_disable_comments(source)
  assert_true(map.is_disabled("no-foo", 2))
  assert_false(map.is_disabled("no-bar", 2))
}

///|
test "disable suppresses all rules from that line onward" {
  let source = "const x = 1\n// moonlint-disable\nconst y = 2\nconst z = 3\n"
  let map = parse_disable_comments(source)
  assert_false(map.is_disabled("any/rule", 1))
  assert_true(map.is_disabled("any/rule", 3))
  assert_true(map.is_disabled("any/rule", 4))
}

///|
test "disable with rule id suppresses only that rule" {
  let source = "// moonlint-disable no-foo\nconst x = 1\n"
  let map = parse_disable_comments(source)
  assert_true(map.is_disabled("no-foo", 2))
  assert_false(map.is_disabled("no-bar", 2))
}

///|
test "enable re-enables rules" {
  let source = "// moonlint-disable\nconst x = 1\n// moonlint-enable\nconst y = 2\n"
  let map = parse_disable_comments(source)
  assert_true(map.is_disabled("any/rule", 2))
  assert_false(map.is_disabled("any/rule", 4))
}

///|
test "enable with rule id re-enables only that rule" {
  let source = "// moonlint-disable no-foo no-bar\n// moonlint-enable no-foo\nconst x = 1\n"
  let map = parse_disable_comments(source)
  assert_false(map.is_disabled("no-foo", 3))
  assert_true(map.is_disabled("no-bar", 3))
}

///|
test "no disable comments means nothing is disabled" {
  let source = "const x = 1\nconst y = 2\n"
  let map = parse_disable_comments(source)
  assert_false(map.is_disabled("any/rule", 1))
  assert_false(map.is_disabled("any/rule", 2))
}

///|
test "disable comments in non-comment lines are ignored" {
  let source = "const x = \"// moonlint-disable\"\nconst y = 2\n"
  let map = parse_disable_comments(source)
  assert_false(map.is_disabled("any/rule", 2))
}

///|
test "multiple disable-next-line directives on consecutive lines" {
  let source = "// moonlint-disable-next-line no-foo\n// moonlint-disable-next-line no-bar\nconst x = 1\n"
  let map = parse_disable_comments(source)
  assert_true(map.is_disabled("no-foo", 2))
  assert_false(map.is_disabled("no-bar", 2))
  assert_false(map.is_disabled("no-foo", 3))
  assert_true(map.is_disabled("no-bar", 3))
}
