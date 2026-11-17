# MoonImpact 演示

[English](<README.md>) | [简体中文](<README.zh-CN.md>)

这是一个人工构造的 Vue/TypeScript 风格回归测试项目，包含模块依赖和一个未通过导入引用的样式表输入，不包含业务代码。

在 moonlint 仓库根目录执行：

```sh
moon build --target native
BIN="$PWD/_build/native/debug/build/cmd/impact/impact.exe"
"$BIN" --file src/fees.ts --config examples/impact-demo/moonimpact.json examples/impact-demo
"$BIN" --file src/theme.css --config examples/impact-demo/moonimpact.json examples/impact-demo
"$BIN" --file src/palette.css --config examples/impact-demo/moonimpact.json examples/impact-demo
```

预期选择结果：

- `src/fees.ts` -> `test/fees.test.ts` 和 `test/summary.test.ts`，附有直接和传递导入的证据。无关的样式表测试不会被选中。
- `src/theme.css` -> `test/theme.test.ts`，依据是经静态分析证明的 `ROOT` 加上仅有一个返回语句的 `read(file)` 包装函数，而不是导入关系。本演示无需为该包装函数添加 `file_readers` 信任条目。
- `src/palette.css` -> `src/theme.css` -> `test/theme.test.ts`，这是一条保守的传递样式表输入依赖链。被选中不保证断言结果会变化；这是一项基于依赖关系的回归测试建议。
- `package.json` 或已删除的输入 -> 回退为全量测试，并给出原因。

生成测试计划不需要 Node.js 或 Vitest。要运行实际的人工构造测试，请先自行在本目录安装本演示声明的依赖（`pnpm install`），然后为生成计划的命令追加 `--run`。MoonImpact 从不自动安装依赖。测试以调用者的权限运行。

有关适用范围、配置、输出格式、执行语义和限制，请参见 [MoonImpact 指南](<../../docs/moonimpact.zh-CN.md>)。本演示并不表示工具能理解所有可能的动态依赖。
