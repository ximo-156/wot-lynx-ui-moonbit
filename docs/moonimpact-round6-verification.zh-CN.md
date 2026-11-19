# MoonImpact 第六轮：公开项目漏测修复与故障复验

日期：2026-11-19。本记录为 macOS 本地验证，非远程 CI 结果。

本轮使用当前工作区构建的工具，包含已有暂存改动及本轮修复，未提交代码。
工具链：`moon 0.1.20261111 (8b8d15b)`、`moonc v0.10.21+f125caab5`。
公共项目均通过 GitHub 克隆，固定下列提交，未更改依赖版本。

| 项目 | 固定提交 | 布局与目标后端 | 干净全量基线 |
| --- | --- | --- | --- |
| [mizchi/css](https://github.com/mizchi/css) | `1c2aaa038277b411a78e80b1c4c7ff3a029b6bbf` | `source = "src"`，默认 JS | 1,666 / 1,666 通过 |
| [moonbitlang/quickcheck](https://github.com/moonbitlang/quickcheck) | `d1149a8eceb995776a6f53977058fc13c47fa443` | `source = "src"`，默认 wasm | 252 / 252 通过 |

## 首次评估发现的问题

1. 导入名按模块目录解析，没有叠加模块的 `source` 目录。CSS 的 `selector` 变更只选中自身，尽管 `cascade` 在清单里直接导入它。
2. 测试库存仅通过 `_test.mbt` / `_wbtest.mbt` 文件名发现测试，漏掉普通源码中的测试。QuickCheck 的 `src/laws/axiom.mbt` 有内联测试，但改动该文件时得到 `none`。
3. MoonBit 的 `full` 执行仍传入静态库存中的包。QuickCheck 全量 252 项，但工具的 `full` 只执行 31 项，仍漏掉 `laws` 的失败。

## 修复内容

- 模块自身的 `source` 配置参与导入名称到实际包目录的映射；覆盖文本与 JSON 描述文件及嵌套模块。无法处理的 source 值产生回退原因。
- 在专用测试文件以外，利用已有 MoonBit 词法和声明扫描器发现普通源码测试；可执行文档测试围栏（`mbt` / `moonbit` 的 `test` 与 `check`）也使所属包进入库存。文档围栏采用保守识别，执行语义仍由工具链决定。
- 读取源码以发现测试；读取或 UTF-8 解码失败阻止执行，符号链接 `.mbt` / `.mbt.md` 不被跟随。
- `full` 通过独立入口执行一次不带包过滤器的 `moon test`，不依赖静态库存。即便库存为空，已有回退原因仍允许真正的全量执行；不安全或 I/O 问题仍阻止执行。
- JSON / HTML 报告不再将 MoonBit 执行描述为 Vitest。

## 相同故障，修复前后比较

全部故障只修改公开项目临时检出的实现，不修改测试或快照。每个故障运行后按原始字节恢复，并确认 `git status --porcelain` 为空。

| 故障 | 修复前选择性执行 | 修复后选择性执行 | 故障后的全量 |
| --- | --- | --- | --- |
| CSS：类选择器优先级 `(0,1,0)` 改为 `(0,0,1)` | 213 项，7 失败 | 1,329 项，7 失败 | 1,666 项，7 失败 |
| CSS：ID 选择器优先级改为零 | 213 项，8 失败，漏 1 项 | 1,329 项，9 失败 | 1,666 项，9 失败 |
| QuickCheck：调试表示标签 `Equivalence` 改为 `Pair` | `none`，0 项 | 172 项，1 失败 | 252 项，1 失败 |
| QuickCheck：上述故障并显式触发清单变更回退 | `full`，31 项全部通过，漏测 | `full`，252 项，1 失败 | 252 项，1 失败 |

逐项比较由运行器打印的失败测试标识，三次选择性执行的失败集合均与各自完整执行一致，QuickCheck 的回退执行也一致。
CSS 之前漏掉的是 `cascade/cascade_wbtest.mbt:354` 的 `specificity - ID beats class`。
QuickCheck 之前漏掉的是 `laws/axiom.mbt:22` 的 `Equivalence debug output is opaque`。

修复后 CSS 选择 `src`、`src/cascade`、`src/computed`、`src/parser`、`src/selector`、`src/wpt` 六个包；QuickCheck 的 laws 选择 `src/internal/testing`、`src/internal/testing/tutorial_en`、`src/internal/testing/tutorial_zh` 与 `src/laws` 四个包。

额外用 QuickCheck 的 `moon test --outline` 核对实际包含测试的包：运行器列出 10 个包，修复后的静态库存有 11 个包，没有遗漏，额外的一个是保守纳入的 benchmark 包。此处是该固定项目的库存核验，并非通用语法完整性证明。

## 复现方法

在所列固定版本的临时项目目录中，先执行 `moon test` 建立干净基线。
本仓库执行 `moon build --target native`，将产物绝对路径记为 `BIN`，公共项目绝对路径记为 `SUBJECT`：

```sh
# CSS 干净计划 / 执行：
"$BIN" plan --file src/selector/specificity.mbt --format json --run "$SUBJECT"
# QuickCheck 干净计划 / 执行：
"$BIN" plan --file src/laws/axiom.mbt --format json --run "$SUBJECT"
# 临时注入上述一种故障后：
"$BIN" plan --worktree --format json --run "$SUBJECT"
# 在 SUBJECT 目录执行 moon test，对比逐项失败集合。
# 使用显式文件输入检验回退，不需要实际改写清单：
"$BIN" plan --file moon.mod --file src/laws/axiom.mbt --format json --run "$SUBJECT"
```

## 本仓库回归

- `moon info`、`moon fmt`、native 构建均成功；公共接口仅新增显式全量执行入口，保留原过滤执行接口。
- `moon test --target native`：560 / 560 通过。
- `python3 tests/impact_integration.py --binary ...`：44 / 44 通过。
- `python3 tests/impact_native.py`：15 / 15 通过（包括以 `-Wall -Wextra -Werror` 编译 C 桥接测试驱动）。
- `git diff --check` 通过。原有暂存改动保留；本轮修改未暂存、未提交、未推送。

## 结果边界

这三项故障的检出集合一致，不构成任意变更下的完整性证明。未声明依赖、运行时文件读取以及未建模的语言特性仍有边界。
CSS 修复后的选中集合从 213 项扩大到 1,329 项，这是补齐依赖后的必要变化，不能继续引用旧样例的缩减比例。
本轮不做速度提升承诺：不同执行的缓存与编译状态会变化，修复后的选择性实跑也未表现出稳定的墙钟时间优势。

另外尝试了官方 parser、moonyacc、markdown.mbt、sqlparser 和 moonbit-step 等候选；有的所需版本不在本机注册表索引中，有的依赖安装受到环境权限限制，未取得有效端到端结果，因此不计入成功验证。未通过降低依赖版本或放宽权限来美化结果。
