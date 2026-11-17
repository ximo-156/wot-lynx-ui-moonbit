# API 策略示例

[English](<README.md>) | [简体中文](<README.zh-CN.md>)

两个模块都能编译并通过各自的测试。`before` 的版本为 0.2.0，导出了 `greeting` 和 `old_api`；`after` 的版本为 0.3.0，移除了 `old_api`。

在 moonlint 仓库根目录执行：

```bash
moon build --target native
ROOT="$PWD"
TOOLCHAIN="moon 0.1.20261102; moonc v0.10.19+bee578715"
BIN="$ROOT/_build/native/debug/build/cmd/main/main.exe"
(cd examples/api-policy-demo/before && moon check --target native && moon test --target native && moon info)
(cd examples/api-policy-demo/after && moon check --target native && moon test --target native && moon info)
"$BIN" --api-snapshot examples/api-policy-demo/before/pkg.generated.mbti \
  --api-toolchain "$TOOLCHAIN" --api-backend native --api-module-version 0.2.0 \
  > examples/api-policy-demo/before/api.snapshot.json
"$BIN" --api-snapshot examples/api-policy-demo/after/pkg.generated.mbti \
  --api-toolchain "$TOOLCHAIN" --api-backend native --api-module-version 0.3.0 \
  > examples/api-policy-demo/after/api.snapshot.json
"$BIN" --api-check examples/api-policy-demo/before/api.snapshot.json \
  examples/api-policy-demo/after/api.snapshot.json --format json
# 默认审查门禁：即使版本已提升，移除公共 old_api 仍会以退出码 1 结束。
"$BIN" --api-check examples/api-policy-demo/before/api.snapshot.json \
  examples/api-policy-demo/after/api.snapshot.json --api-version-policy semver --format json
# 显式启用 0.x 次版本破坏性发布策略：退出码为 0，移除操作仍作为警告报告。
```

如果你的编译器不同，请记录实际使用的工具链，不要照抄示例中的元数据。这些是声明快照，不能证明行为、ABI 或类型可赋值性是否兼容。遇到不支持的语法或上下文时，退出码为 2。快照输出在本地生成，不纳入版本控制。
