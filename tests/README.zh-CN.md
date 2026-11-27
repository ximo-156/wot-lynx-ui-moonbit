# moonlint CLI 集成测试

[English](<README.md>) | [简体中文](<README.zh-CN.md>)

[integration.py](<integration.py>) 仅使用 Python 标准库。它调用**已经构建好**的 native moonlint 可执行文件，不会构建 moonlint 或安装依赖。`policies` 阶段还会在隔离的测试样例中调用已安装的 MoonBit 工具链（`moon check`、`moon test`、`moon info` 和 `moon tree`）；如果 `moon` 不可用，则跳过这些编译器测试用例。

构建可执行文件与运行依托编译器的测试用例要求 **moonc 1.0.0-rc1 或更新版本**。[check_toolchain_test.py](<check_toolchain_test.py>) 检查版本边界解析；[check_toolchain.py](<check_toolchain.py>) 根据当前 `moonc -v` 强制检查最低版本。CI 会运行二者：

```sh
# 检查工具链、构建，再针对 native 可执行文件运行测试套件。
moon version --all
python3 tests/check_toolchain_test.py
python3 tests/check_toolchain.py
moon build --target native
python3 tests/integration.py \
  --binary "$PWD/_build/native/debug/build/cmd/main/main.exe" \
  --phase all
```

`--binary` 必须使用绝对路径指向一个已存在的可执行文件。测试运行器的退出码为：测试套件通过时为 0，断言失败时为 1，运行器参数无效时为 2。`--phase` 接受阶段名称或 `all`（默认值）：

| 阶段 | 重点 |
|-------|-------|
| `repairs` | 扫描可靠性：glob/stdin 选择、扩展名过滤、路径安全、参数验证、基线刷新，以及跳过和失败计数 |
| `git` | Git 安全：选项注入、PR 的 merge-base 语义、真实索引内容、未合并索引、Git 符号链接和重命名 |
| `scope` | 全局及规则级 `include` / `exclude` |
| `output` | JSON 报告、GitHub 注解，以及读取、失败和跳过的元数据 |
| `presets` | 内置预设、配置继承、行内抑制、SARIF、初始化和修复 |
| `observable` | 匹配列位置、注释和字面量处理、摘要，以及试运行和修复输出 |
| `incremental` | 基于内容的缓存复用、失效、损坏缓存回退和结构缓存 |
| `structural` | 导入、导出、循环、别名和依赖上下文 |
| `combinator` | 匹配器组合和 `unless` 保护条件 |
| `demo` | TypeScript 演示的精确输出、摘要，以及缓存写入后再读取的验证 |
| `moonbit` | MoonBit 演示输出、预设等价性和排除规则 |
| `policies` | 包/API 策略、依托编译器的测试样例、MoonBit 语法和修复，以及基线 v2 |
| `git-context` | 不可变的 Git 项目上下文，以及与工作树和配置变更的隔离 |

## 隔离

每项测试独占一个 `tempfile.TemporaryDirectory`，使用唯一的 `moonlint-<random>-` 前缀。扫描根目录位于其中，配置文件和基线文件则位于扫描根目录之外。Git 的 init/add/commit/checkout/rm 命令仅在 `git -C` 指向该测试的临时仓库时运行。准备测试样例时会禁用用户 Git 配置、钩子执行和签名。CLI 自身的工作目录也位于同一临时区域内。所有递归清理由 tempfile 执行，执行前会断言解析后的目标恰好就是测试独占的目录。任何 Git 写操作都不会针对实际项目仓库。

测试要求 Python 3.9+，以及支持 `init --initial-branch` 的 Git。如果 Git 不可用，将跳过 Git 测试用例。如果当前账户仍能读取被刻意设为不可访问的测试样例，将跳过权限拒绝测试用例。如果宿主系统不支持创建符号链接，将跳过符号链接测试用例。

## 修复相关覆盖范围

- 使用 `.ts`、错误严重级别和 `contains: FORBIDDEN` 验证能产生文本检查结果的正向案例。
- Glob 的 `*`、完整路径段 `**`（零层或多层目录）、`?`、重复模式的并集与去重，以及拒绝不支持的花括号和字符类模式。
- 通过真实 stdin 管道输入按行分隔和 NUL 分隔的路径列表，涵盖空格（包括尾随空格）、Unicode、引号、换行、以短横线开头的名称及重复候选路径；按行模式拒绝 NUL 字节，`--stdin0` 则接受 NUL 分隔输入。
- 空 glob 和空 stdin/stdin0 选择：正常退出、文本模式中明确的“no files selected”提示，以及 JSON 中全为零的计数器。
- 在目录树/glob/stdin/stdin0/staged/changed 模式下保持一致的扩展名过滤；规则的扩展名数组为空时扫描所有普通文件。
- 未知、缺失或冲突的 CLI 参数，明确拒绝不支持的 `--watch` / `--watch-interval` 选项，符号链接跳过和循环保护，拒绝根目录之外的路径，以及 I/O 失败。其中包括不可读的子目录：这种情况属于错误，不会静默变成不完整扫描。
- 原始内容且幂等的基线刷新，添加新条目时保留现有条目，完整刷新时清除过期条目，仅错误模式的独立性，拒绝部分更新且不重写文件，格式错误的输入，以及基线写入失败。
- 即使某条规则适用于所有普通文件，也会排除固定的干扰目录。

## Git 覆盖范围

- 已提交的 HEAD blob 与工作树内容之间的区别，以及对完整文件而非差异行进行 lint 检查；上游分支已分叉时的 PR merge-base 语义。
- 在两个方向上验证 `--staged` 使用真实的索引内容：索引有修改而工作树干净，以及索引干净而工作树有修改。
- 安全使用 NUL 分隔，处理含空格、引号、Unicode 和内嵌换行的路径，同时涵盖子目录根路径和删除处理；重命名文件按新路径扫描。
- 看起来像 Git 选项的引用值会被作为无效引用拒绝，因此绝不会被解释为标志。
- 未合并的索引、位于扫描根目录之外的仓库，以及未知引用，都会产生退出码 2，而不是空的成功结果。

## 作用范围覆盖范围

- 全局 `include`/`exclude` 限制、`./` 前缀、覆盖子树但不覆盖同前缀兄弟目录的目录模式、文件模式，以及排除优先于包含。
- 规则级作用范围只限制单条规则，不会扩大全局扫描集合。
- 作用范围适用于每种扫描模式；被作用范围拒绝的文件计入 `files_out_of_scope`，且绝不会被读取。
- 对全局及规则级作用范围，无效模式和格式错误的范围列表都属于配置错误（退出码 2）。

## 输出覆盖范围

- JSON：带版本的文档，包含规则、严重级别、文件、行、列和片段的检查结果，各严重级别的计数、诊断信息，以及所有读取、失败、跳过、作用范围和基线计数器，还包括逐文件的 `skipped_files` 列表及其原因。
- JSON 报告会以原子方式写入 `--report <file>`，即使扫描失败也会写入。
- GitHub：属性值和消息值经过转义的 `::error`/`::warning` 注解，不可读文件的 `::error` 注解，跳过文件的 `::notice` 注解，最终摘要通知，以及确保内嵌换行无法伪造命令。

没有任何测试被标记为 `expectedFailure`；断言失败表示 CLI 契约出现回归。如果宿主系统不满足前置条件，可以跳过相应测试。

## 独立的 MoonImpact 测试运行器

以下脚本不包含在 `integration.py --phase all` 中：

| 运行器 | 要求和覆盖范围 |
|--------|------------------------|
| [impact_integration.py](<impact_integration.py>) | 传入 `--binary /absolute/path/to/impact.exe`；通过隔离的测试样例和模拟运行器验证计划生成与执行。 |
| [impact_native.py](<impact_native.py>) | 直接使用 Python 运行；在 macOS/Linux 上使用 `cc` 构建临时 C 驱动程序，测试原生桥接。 |
| [impact_moonbit_corpus.py](<impact_moonbit_corpus.py>) | 传入 `--binary` 和多个 `--project NAME=DIR`，使用[语料清单](<impact_moonbit_corpus.json>)中固定提交的干净检出目录。执行全量测试，并将 `moon test --outline` 与静态库存对照；加 `--mutate` 会临时注入声明的故障、逐项比较失败集合，之后恢复源码原始字节。不克隆、不改工具链、不更新快照；`moon` 可能解析依赖并写入构建产物。 |
| [impact_moonbit_corpus_test.py](<impact_moonbit_corpus_test.py>) | 5 项无额外依赖的测试，覆盖运行器证据解析和异常时的源码恢复，纳入 CI。 |
| [impact_stability.py](<impact_stability.py>) | 传入 `--binary`、`--project`，以及可选的 `--config` / `--samples`；审查现有项目，不修改项目或运行其测试。未传入 `--project` 时跳过。 |
| [impact_vitest_smoke.py](<impact_vitest_smoke.py>) | 传入 `--binary` 和包含 `vitest.mjs` 的 `--vitest-dir`；要求已安装 Node.js 和 pnpm，运行临时的人工构造测试样例，脚本自身不安装任何内容。CI 提供 Node.js 22、pnpm 10.24.0 和安装在临时前缀下的 Vitest 3.2.6，再运行此 smoke 测试。 |

使用 `moon build --target native` 构建 MoonImpact 可执行文件；默认路径为 `_build/native/debug/build/cmd/impact/impact.exe`。

[CI](<../.github/workflows/ci.yml>) 还会在[工作区样例](<../examples/workspace-demo/moon.work>)根目录执行 native check/test/build，然后以 `plan --file shared/shared.mbt --run examples/workspace-demo` 调用 MoonImpact，验证成员模块间的选中包执行。
