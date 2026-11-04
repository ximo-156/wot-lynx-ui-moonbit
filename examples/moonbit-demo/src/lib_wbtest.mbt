///|
test "source compiles and behavior works despite policy findings" {
  assert_eq(add(2, 3), 5)
  assert_eq(badName(), 1)
  assert_eq(parse("moon"), 4)
}
