# MoonBit convention example

This is a real dependency-free MoonBit module. Its valid source intentionally
fails six team checks: camelCase function name, three empty/missing public docs,
one syntactic unwrap call, and one TODO comment. `Some(...).unwrap()` is safe
here at runtime; the project rule is still an explicit no-unwrap name policy.
The compiler already has optional W74 documentation checking.

From the moonlint checkout root:

```bash
(cd examples/moonbit-demo && moon check --target native && moon test --target native && moon build --target native)
_build/native/debug/build/cmd/main/main.exe --preset moonbit examples/moonbit-demo/src
# Expect exit 1: four errors and two warnings.
```

Expected formatted-source output:

```text
lib.mbt:8: [error] moonbit/naming — Name does not follow the MoonBit naming convention (fn 'badName' should be snake_case)
    pub fn badName() -> Int32 {
lib.mbt:8: [error] moonbit/require-public-doc — Public item is missing documentation (public fn 'badName' has no non-empty doc comment)
    pub fn badName() -> Int32 {
lib.mbt:13: [error] moonbit/require-public-doc — Public item is missing documentation (public struct 'Point' has no non-empty doc comment)
    pub struct Point {
lib.mbt:18: [error] moonbit/require-public-doc — Public item is missing documentation (public fn 'parse' has no non-empty doc comment)
    pub fn parse(text : String) -> Int32 {
lib.mbt:19: [warning] moonbit/no-unwrap — Method named unwrap() requires review; it may panic
    let value = Some(text.length()).unwrap()
lib.mbt:20: [warning] moonbit/no-todo-comment — TODO/FIXME comment left in code
    // TODO: handle malformed input
```

The preset recursively excludes test files. Empty block separators are not
substantive documentation. The tests verify the module's actual functions;
compiler success and the convention-policy failure are separate verdicts.
