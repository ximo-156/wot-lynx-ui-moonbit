///|
/// The demo still works even though its domain-to-UI dependency violates policy.
pub fn label() -> String {
  @domain.label()
}

///|
test "demo is functional" {
  assert_eq(label(), "MoonBit")
}
