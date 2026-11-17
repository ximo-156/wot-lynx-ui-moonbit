# MoonImpact 第五轮：公开 MoonBit 模块上的端到端选择性执行

[English](<moonimpact-round5-verification.md>) | [简体中文](<moonimpact-round5-verification.zh-CN.md>)

本记录补齐此前各轮留下的缺口：之前记录测量了公开 MoonBit 模块上的**计划生成**和 JS/TS 项目上的**执行**，但从未在同一 MoonBit 目录树上同时测量两者。本轮通过 `--run` 在公开的 [moonbitlang/x](https://github.com/moonbitlang/x) monorepo 上执行计划，与完整套件比较，并注入两个故障来检查选中集合实际能够捕获什么。

本记录是本地工作区验证，并非发布、远程 CI 结果，也不保证在任意项目上选择性测试的安全性。[第四轮记录](<moonimpact-round4-verification.zh-CN.md>)覆盖 MoonBit 计划前端；[第三轮记录](<moonimpact-round3-verification.zh-CN.md>)覆盖 JS/TS 引擎。

## 固定的测量对象

| 项目 | 值 |
| --- | --- |
| 仓库 | `https://github.com/moonbitlang/x` |
| 提交 | `6b67e08c098c349f1e0fb48b0a624864d7e415e5`（"fix(fs): retry native open after interruption (#362)"） |
| 模块 / 包 | 1 个模块，25 个包，其中 19 个包含测试 |
| 工具链 | `moon 0.1.20261111 (8b8d15b)`、`moonc v0.10.21+f125caab5`、macOS native |
| 对象状态 | 干净目录树；下文每次测量均从 `git status` 干净状态开始，故障在该次运行后撤销 |

刻意固定了该提交。仓库较新的 `fs` 包使用 `@io.ReaderClosed`，而固定的本地 core（`0.10.21`）未导出该项，因此本次验证中检查的上游 `HEAD` 无法使用该工具链编译。这是上游/工具链版本不匹配，并非计划缺陷；测量采用了在该环境中找到的可编译并运行测试的最新提交。

## 计划与执行并列比较

两种运行使用相同的工具二进制、目录树和机器。“冷”表示紧接运行前执行 `moon clean`；“热”表示前次运行已填充构建缓存。

| 运行 | 策略 | 包数 | 测试数 | 结果 | 冷 | 热 |
| --- | --- | ---: | ---: | --- | ---: | ---: |
| 完整套件（`moon test`） | — | 25 | 795 | 794 个通过，1 个失败 | 4.67s | 4.05s |
| 选择性运行，`encoding` 变更 | related | 4 / 19 | 175 | 174 个通过，1 个失败 | 0.57s | 0.16s |
| 选择性运行，`decimal` 变更 | related | 1 / 19 | 27 | 27 个通过，0 个失败 | 0.48s | 0.05s |

选择性运行经过工具自身的 `--run` 路径，而非手写 `moon test <packages>` 列表：

```sh
moon build --target native
BIN="$PWD/_build/native/debug/build/cmd/impact/impact.exe"
"$BIN" plan --file encoding/encoding.mbt --run /tmp/x-checkout
```

`encoding` 的选中集合包含四个包——`crypto`、`encoding`、`fs` 和 `jwt`——通过已声明的依赖到达，其中包括 `crypto` 声明 `moonbitlang/x/encoding` 的 `for "test"` 导入。`decimal` 包是叶子：没有任何包导入它，因此只选中其自身包。

完整套件和 `encoding` 选中集合中的唯一失败是**既有的，与任何变更无关**：`crypto/chacha_test.mbt:59`（"chacha rejects counter exhaustion before writing output"）在原始固定提交上即失败。它在干净基线和每次故障运行中表现完全相同；`decimal` 选中集合不包含 `crypto`，因此那里不会出现它。

## 故障注入

注入了两个故障，分别对应两种选中集合形态，之后均已撤销（已验证 `git status` 干净）。

**故障 1——`encoding`，影响包含 4 个包的选中集合。** `encoding/encoding.mbt` 中的 `encode` 使用 `Buffer::write_char_utf16le` 写入 UTF-16 大端输出：

```diff
-    UTF16BE => Buffer::write_char_utf16be
+    UTF16BE => Buffer::write_char_utf16le
```

| 运行 | 测试数 | 结果 |
| --- | ---: | --- |
| 完整套件 | 795 | 792 个通过，3 个失败 |
| 选择性运行（4 个包） | 175 | 172 个通过，3 个失败 |

**故障 2——`decimal`，影响包含 1 个包的选中集合。** `decimal/decimal.mbt` 中的 `normalize` 在去除尾随零时将 scale 减二而非减一：

```diff
       coefficient = coefficient / 10N
-      scale = scale - 1
+      scale = scale - 2
```

| 运行 | 测试数 | 结果 |
| --- | ---: | --- |
| 选择性运行（1 个包） | 27 | 23 个通过，4 个失败 |

四个 decimal 失败分别是 `decimal_creation`、`decimal_string_conversion`、`decimal_comparison` 和 `decimal_normalization`。

## 选中集合捕获了什么，以及没有捕获什么

逐项比较故障 1 的完整运行和选择性运行中的失败测试集合：

| 失败测试 | 完整 | 选择性 |
| --- | --- | --- |
| `crypto/chacha_test.mbt`——chacha 拒绝计数器耗尽 | 失败 | 失败 |
| `encoding/encoding_test.mbt:84`——将 String 编码为 UTF16BE | 失败 | 失败 |
| `encoding/decoding_test.mbt:174`——流式解码 UTF16BE | 失败 | 失败 |

**失败集合完全相同：选中集合没有遗漏，也没有额外报告。** 对这次注入故障，包含 4 个包的选中集合在运行 175 个测试的同时，承载了 795 个测试的完整套件发现的所有失败。

这一结论的如实边界是：它仅适用于*这棵*目录树中的*这个*故障。选择性计划不是等价性证明。计划器读取清单导入，因此未在 `moon.pkg` 导入块中声明的依赖对它不可见；若某个包的测试通过这种未声明路径受到影响，该包将不会被选中。契约是单向的：模型只能证明它看得见的链接；未建模的变更会请求所有包，而非静默地声称没有影响。

## 确定性

对同一目录树连续两次运行 `plan --format json`，结果逐字节一致。

## 保留的边界

- 计划提供建议。`related` 计划指出模型将哪些包关联到变更；它不声称变更出错时每个选中测试都会失败，也绝不是测试通过结果。
- 选择性缩减能力取决于具体项目。175/795 和 27/795 这两组数字描述的是这棵目录树、这个提交和这套工具链。
- 实际耗时取决于机器，以测量值而非承诺的形式报告。提供冷/热配对数据，是为了明确显示编译缓存对差异的贡献，避免含糊暗示。
- 包图根据 `moon.pkg` 导入块构建。条件（`#cfg`）块在不求值条件的情况下保守计入；不对类型级依赖和运行时文件读取建模。
- 测量时读取被测对象。注入故障在各自运行结束后立即撤销，且前后均验证目录树干净。
