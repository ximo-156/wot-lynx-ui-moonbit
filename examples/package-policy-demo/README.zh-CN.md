# 包策略示例

[English](<README.md>) | [简体中文](<README.zh-CN.md>)

此模块没有外部依赖，且依赖关系无环：root -> domain -> ui。编译器允许该依赖关系；提供的团队策略则禁止 native 源码依赖边中的 domain -> ui。这刻意不是一个会被编译器拒绝的循环依赖示例。

在 moonlint 仓库根目录执行：

```bash
moon build --target native
(cd examples/package-policy-demo && moon check --target native && moon test --target native && moon build --target native)
(cd examples/package-policy-demo && moon tree --package --json --target native > graph.native.json)
_build/native/debug/build/cmd/main/main.exe \
  --package-graph examples/package-policy-demo/graph.native.json \
  --config examples/package-policy-demo/policy.json --format json
# 预期退出码为 1，规则为 architecture/domain-no-ui，并附有实际的包、别名和种类详情。
```

将策略方向反转为 ui -> domain（无需更改这个有效模块），即可得到一个允许通过的案例。编译器生成的依赖图包含本地路径，不纳入版本控制。此门禁检查所提供编译器 v3 依赖图中的直接非标准库依赖边，不会虚构源码位置。
