# MoonImpact 第七轮：固定版本语料与验证多样性

日期：2026-11-19。继续围绕 MoonBit 包级变更影响和回归测试规划，扩展项目领域、包布局、依赖关系和测试组织方式。本轮没有增加新的产品方向。

## 固定版本的公开项目

完整提交 SHA、源码布局和故障替换内容见[语料清单](<../tests/impact_moonbit_corpus.json>)。以下均为公开仓库的未修改版本，使用本机 `moon 0.1.20261111`、`moonc v0.10.21+f125caab5`，按各项目默认后端执行 `moon test`，未更新快照、依赖或工具链。

| 项目 | 固定提交 | 干净全量通过数 | 实际含测试包 / 静态库存 | 新增验证维度 |
| --- | --- | ---: | ---: | --- |
| [mizchi/css](https://github.com/mizchi/css) | `1c2aaa0` | 1,666 | 12 / 12 | source 目录、传递依赖、跨包故障 |
| [moonbitlang/quickcheck](https://github.com/moonbitlang/quickcheck) | `d1149a8` | 252 | 10 / 11 | 内联测试、中英文文档测试、保守库存 |
| [moonbitlang/regexp.mbt](https://github.com/moonbitlang/regexp.mbt) | `24f7b7d` | 157 | 5 / 5 | 根包、内部 Unicode/AST/解析器/VM 依赖 |
| [TheWaWaR/clap.mbt](https://github.com/TheWaWaR/clap.mbt) | `fa59e57` | 15 | 1 / 1 | source 根包、命令行参数、幸存故障 |
| [moonbit-community/NyaCSV](https://github.com/moonbit-community/NyaCSV) | `19ab9ca` | 47 | 1 / 1 | 模块根包、限定别名、实现文件内测试 |
| [moonbit-community/xml-mbt](https://github.com/moonbit-community/xml-mbt) | `bf5d07e` | 1,821 | 1 / 1 | 大量一致性用例、source 根包 |
| [moonbit-community/prettyprinter](https://github.com/moonbit-community/prettyprinter) | `683b838` | 7 | 1 / 1 | 小型库、限定别名；只做基线和库存验证 |

合计 3,965 项干净基线测试全部通过。库存的独立参照是 `moon test --outline`，再按语料清单中的模块名和 source 目录映射到实际包路径，不复用 MoonImpact 的清单解析器。7 个项目均未漏掉运行器列出的测试包。QuickCheck 多出的一个包是保守纳入的 benchmark 包；库存不要求与执行数严格相等。

## 逐项故障对照

每次只在指定的干净检出中替换一处实现，运行 MoonImpact `--worktree --run` 与完整 `moon test`，逐项比较失败测试标识。无论执行成功、失败或解析异常，源码均在 `finally` 中按原始字节恢复，并检查 Git 状态。

| 项目与故障 | 选择性测试数 | 全量测试数 | 双方失败数 | 结论 |
| --- | ---: | ---: | ---: | --- |
| CSS：类优先级错误 | 1,329 | 1,666 | 7 | 失败集合一致 |
| CSS：ID 优先级归零 | 1,329 | 1,666 | 9 | 失败集合一致 |
| QuickCheck：调试标签错误 | 172 | 252 | 1 | 失败集合一致 |
| Regexp：单词字符判断移除下划线 | 157 | 157 | 1 | 失败集合一致，无测试缩减 |
| Clap：禁用短 flag 识别 | 15 | 15 | 5 | 失败集合一致，单包不缩减 |
| NyaCSV：行数加一 | 47 | 47 | 3 | 失败集合一致，单包不缩减 |
| XML：小于号转义为大于号 | 1,821 | 1,821 | 5 | 失败集合一致，单包不缩减 |
| Clap：单参数长度约束由 1 改为 2 | 15 | 15 | 0 | 故障在全量中也幸存，不能算作检出成功 |

8 次注入中，7 次产生可对照的失败，且集合一致；1 次在全量中也未被检出。后者记录为 `survived_full_suite`，不是 MoonImpact 漏选，也不能用于证明选择性测试有效。本轮不宣称所有项目都能减少执行量或墙钟时间。

## 实测驱动的实现与回归

1. **旧 JSON 清单不再静默丢边。** 额外检查 [Lampese/MCIL](https://github.com/Lampese/MCIL) 的 `5c28aaff24ab76ad26c5c856815898284362642a`：此前修改 `src/cil/cfg.mbt` 只关联 `src/cil`，漏掉清单中声明的 ext/frontc 导入方；现在正确关联三者。JSON 字符串和 path/alias 对象形式的普通、黑盒、白盒导入均有纯模型和 CLI 回归。该检出不能通过当前工具链的普通构建命令，因为工具链已拒绝 JSON 清单；因此这里仅记录规划验证，不计为第八个端到端成功项目。
2. **文本清单按词法单元读取导入。** 复用现有词法基础，避免注释、描述字符串里的 `import` 或未闭合引号伪造依赖；支持真实项目中的 `@encoding/utf8`、`@immut/vector` 限定别名。无法识别的导入内容回退，不静默变成无依赖。
3. **工作区配置变化触发全量。** `moon.work` 会影响成员集合，作为全局变更处理，CLI 回归确认执行没有包过滤器。未据此宣称已实现工作区根目录发现或完整跨模块链接。
4. **图形状回归。** 增加菱形依赖的两分支选择与确定性最短证据、断开的包集合、多改动合并和去重，以及循环依赖输入下的有限遍历。循环清单不是合法编译项目，这项测试只验证分析器不会在编辑中的无效目录树上死循环。
5. **稳定性审计能真正检查 MoonBit。** 源文件采样支持 `.mbt`；允许根包的空字符串身份；小项目不再因文件数不足而失败；显式 JS/TS 配置在混合仓库中仍被遵守。全量计划清单与全量实际执行的含义分开描述。

旧格式执行边界参照 [MoonBit 官方包配置说明](https://docs.moonbitlang.com/en/latest/toolchain/moon/package.html)。MoonImpact 只读取旧格式建图，不自动迁移外部项目。

## 可复现运行器

新增 [impact_moonbit_corpus.py](<../tests/impact_moonbit_corpus.py>) 和固定语料清单。运行器不克隆仓库、不修改工具链、不执行 Git 写命令；`moon` 自身可能解析依赖和写构建产物。

先准备清单指定提交的干净检出目录，再在本仓库执行：

```sh
moon build --target native
BIN="$PWD/_build/native/debug/build/cmd/impact/impact.exe"

# 不传 --mutate：全量基线、运行器库存与静态库存、重复计划一致性。
python3 tests/impact_moonbit_corpus.py --binary "$BIN" \
  --project regexp=/absolute/path/to/regexp.mbt \
  --project csv=/absolute/path/to/NyaCSV

# 显式加 --mutate 才会临时修改实现；--report 仅创建新文件。
python3 tests/impact_moonbit_corpus.py --binary "$BIN" \
  --project regexp=/absolute/path/to/regexp.mbt \
  --project csv=/absolute/path/to/NyaCSV \
  --mutate --report /absolute/path/to/new-result.json
```

可用名称为 `css`、`quickcheck`、`regexp`、`clap`、`csv`、`xml`、`prettyprinter`。提交不匹配、目录不干净、缺少运行器摘要或失败标识、库存漏包、选择性漏测都会报错。全量也检不出的故障单独记录，不伪装成通过故障检出验证。

[本轮机器可读结果](<../tests/results/moonimpact-corpus-2026-11-19.json>)包含固定提交、工具链、工具二进制与语料清单 SHA-256、各次执行计数和逐项失败标识。耗时仅为当次观察，未控制冷缓存，不作为性能对比结论。

## 本地验证与保留边界

- `moon info`、`moon fmt`、native 构建成功；本轮未新增公共接口。
- 566 项 native 单元测试、46 项 CLI 回归、15 项 C 桥接测试、5 项语料证据与恢复测试全部通过。
- 本仓库以及 7 个公开 MoonBit 项目均做了每项 6 类稳定性检查，含多文件采样、重复输出、Git 输入、异常输入和报告创建约束。XML 的首次并发审计有一次子进程 `setpgid` 启动错误，独立复验 6 项通过；没有隐藏首次错误，也没有将它归因于图规划或宣称已经修复该启动偶发性。JS 演示的 6 类检查中，5 项通过，1 项因演示目录不是独立 Git 仓库而跳过。
- 7 个公共检出在故障测试后均为干净状态。原工作区暂存内容保留，本轮没有提交或推送。CI 仅新增无需外部仓库的语料证据自测步骤，未验证远程 CI 状态。
- TOML 候选项目的工作区需要当前本机索引没有的 async 版本，未取得有效全量基线，没有修改依赖以将其算入成功样本。
- 这些项目和故障的结果不是任意程序影响分析完整性的证明；未声明的运行时依赖、工作区跨模块链接等边界仍然存在。
