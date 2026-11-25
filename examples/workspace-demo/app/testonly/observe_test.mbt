///|
test "test-only observes shared" {
  assert_eq(@shared.value(), 42)
}
