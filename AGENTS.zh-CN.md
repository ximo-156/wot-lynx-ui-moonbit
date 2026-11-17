# 项目 Agent 指南

[English](<AGENTS.md>) | [简体中文](<AGENTS.zh-CN.md>)

这是一个 [MoonBit](https://docs.moonbitlang.com) 项目。

可在以下地址浏览和安装额外技能：
<https://github.com/moonbitlang/skills>

## 项目结构

- MoonBit 包按目录组织，每个包目录包含一个列出依赖的 `moon.pkg` 文件。各包中包含源码、黑盒测试文件（以 `_test.mbt` 结尾）和白盒测试文件（以 `_wbtest.mbt` 结尾）。
- 顶层目录中的 `moon.mod` 文件声明模块元数据。

## 编码约定

- MoonBit 代码按块组织，块之间以 `///|` 分隔。各块的顺序无关紧要，部分重构可以逐块独立处理。
- 尽量将各目录中已弃用的代码块集中放入 `deprecated.mbt`。

## 工具

- 使用 `moon fmt` 格式化代码。
- `moon ide` 提供 `peek-def`、`outline`、`find-references` 等代码导航功能。详见 `$moonbit-agent-guide`。
- 使用 `moon info` 更新包的生成接口。每个包都有一个 `.mbti` 生成接口文件，用于简要、正式地描述包的接口。如果 `.mbti` 没有变化，说明改动没有改变外部用户可见的接口，通常属于安全的重构。
- 最后运行 `moon info && moon fmt`，更新接口并格式化代码。检查 `.mbti` 的差异，确认变化符合预期。
- 运行 `moon test`，确认测试通过。MoonBit 支持快照测试；若变更影响输出，可运行 `moon test --update` 更新快照。
- 对稳定或极少变化的结果，优先使用 `assert_eq` 或 `assert_true(pattern is Pattern(...))`。记录结构化调试输出的快照测试应派生 `Debug` 并使用 `debug_inspect`，不要为了调试而派生 `Show`。对于有明确结果的计算（例如科学计算），优先采用断言测试。可运行 `moon coverage analyze > uncovered.log` 查看测试未覆盖的代码。
