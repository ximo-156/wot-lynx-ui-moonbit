# MoonBit 规范示例

[English](<README.md>) | [简体中文](<README.zh-CN.md>)

这是一个真实的、无依赖的 MoonBit 模块。其有效源码故意未通过六项团队检查：一个 camelCase 函数名、三处为空或缺失的公共文档、一次语法层面的 unwrap 调用，以及一条 TODO 注释。这里的 `Some(...).unwrap()` 在运行时是安全的；项目规则仍然明确按名称实施禁止 unwrap 的策略。编译器本身已提供可选的 W74 文档检查。

在 moonlint 仓库根目录执行：

```bash
moon build --target native
(cd examples/moonbit-demo && moon check --target native && moon test --target native && moon build --target native)
_build/native/debug/build/cmd/main/main.exe --preset moonbit examples/moonbit-demo/src
# 预期退出码为 1：四条错误和两条警告。
```

针对格式化后源码的预期输出：

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

该预设会递归排除测试文件。空的代码块分隔符不算实质性文档。测试用于验证模块函数的实际行为；编译成功与规范策略检查失败是两项独立的判定。
