# MoonBit demo

A small MoonBit source file with five deliberate convention violations. It is
lint input, not a buildable package: there is no `moon.mod` here on purpose.

```bash
moonlint --preset moonbit examples/moonbit-demo/src
```

Expected output:

```text
lib.mbt:7: [error] moonbit/naming — Name does not follow the MoonBit naming convention (fn 'BadName' should be snake_case)
    pub fn BadName() -> Int {
lib.mbt:7: [error] moonbit/require-public-doc — Public item is missing a ///| doc comment (public fn 'BadName' has no ///| doc comment)
    pub fn BadName() -> Int {
lib.mbt:12: [error] moonbit/naming — Name does not follow the MoonBit naming convention (struct 'point' should be PascalCase)
    pub struct point {
lib.mbt:18: [warning] moonbit/no-unwrap — unwrap() can panic; handle the error explicitly
    let value = @json.parse(text).unwrap()
lib.mbt:19: [warning] moonbit/no-todo-comment — TODO/FIXME comment left in code
    // TODO: handle malformed input
```

The test files are excluded by the preset on purpose: `*_test.mbt` and
`*_wbtest.mbt` may unwrap, panic and print.
