# MoonImpact

[English](<moonimpact.md>) | [简体中文](<moonimpact.zh-CN.md>)

MoonImpact 是使用 MoonBit 实现的**变更影响和回归测试计划工具**。它复用 moonlint 的源码和文件系统基础设施，但不检查命名、格式、文档或发布策略。

给定变更文件，它回答：

- 哪些测试与此变更存在已知依赖？
- 哪条引用链能解释每个选择？
- 为什么本次运行必须回退到完整套件，或被阻止？

计划只提供建议，**不是测试结果，也不是未选中测试不会失败的证明**。除非提供 `--run`，否则不会运行测试、构建或安装。MoonImpact 不会安装 Node.js、pnpm、Vitest 或任何项目依赖。

支持为两种项目生成计划：

| 类型 | 检测方式 | 测试单元 | 运行器（`--run`） |
| --- | --- | --- | --- |
| **MoonBit 模块/工作区**（默认） | 根目录包含 `moon.mod` / `moon.mod.json` 或 `moon.work`，未提供 `--config` | 包 | 一次执行 `moon test <package>...`，传入所有选中包路径 |
| **JS/TS 项目** | 显式 `--config moonimpact.json` | 测试文件 | 带 `./test-path` 过滤器的 `pnpm exec vitest run` |

MoonBit 路径完全无需配置：包图从目录树中的 `moon.pkg` 清单读取。JS/TS 路径保留下文所述的显式、纯数据配置契约。

## MoonBit 模块

MoonBit 模块是由包组成的目录树，每个包由 `moon.pkg`（或 `moon.pkg.json`）清单声明。MoonImpact 直接读取这些清单：

- 根目录下每个 `moon.mod` / `moon.mod.json` 声明一个模块；包基于**自身**模块解析导入，因此嵌套模块和工作区模块绝不会借用根模块名称；
- 模块描述文件（文本与 JSON）的 `source` 目录会将导入名称映射到实际包路径；嵌套模块分别解析；
- 除专用测试文件外，普通源码的测试块和 `mbt` / `moonbit` 的 `test` 与 `check` 文档代码块也会计入测试清单；
- 清单中的每个 `import` 块均计入——普通、`for "test"` 和 `#cfg(...)` 条件块一视同仁——因为仅测试依赖仍决定该包的测试能否观察到变更；
- 变更文件选中其所属包（最长的包目录前缀；模块根包拥有其余文件），以及每个传递导入它的包，包括仅测试导入；
- 每个测试文件只计入其所属包的测试清单，并使用相同的最长前缀规则，因此嵌套包不会增加父包的测试计数；
- 选中的**包**是执行单元：`--run` 将所有选中的实际包路径传给一次 `moon test` 调用，模块根包用 `.` 指定。`full` 则执行不带包过滤器的 `moon test`，不依赖静态测试清单是否为空。

清单解析会跳过注释和元数据字符串、解码导入路径，并保留 `@encoding/utf8` 这类限定别名。旧 JSON 清单的 `import`、`test-import`、`wbtest-import` 数组（包括 path/alias 对象）也参与建图。这是规划兼容性：新版 MoonBit 工具链可能要求先迁移 JSON 清单才能执行测试，MoonImpact 不会自动迁移。工作区根目录无需 `moon.mod` 即可识别；根目录相对的字面量 `members = [...]` 限定模块范围，同一最近工作区中的成员模块导入会建边。不支持 glob/动态成员，重复或不安全路径以及工作区边界外可能的本地依赖会回退到全量；符号链接成员目录会阻止执行。`moon.work` 变更也会请求全量回归，其他工作区设置不参与依赖规划。

新增[固定版本语料运行器](<../tests/impact_moonbit_corpus.py>)，对照实际运行器库存，并可选择注入故障、逐项比较选择性与全量的失败集合。见[七项目验证记录](<moonimpact-round7-verification.zh-CN.md>)。

构建要求 **moonc 1.0.0-rc1 或更新版本**，可先检查当前编译器。本仓库根目录是 MoonBit 模块，没有 `moon.work`；显式工作区样例位于 `examples/workspace-demo`：

```sh
python3 tests/check_toolchain.py
moon build --target native
BIN="$PWD/_build/native/debug/build/cmd/impact/impact.exe"

# 跨模块和测试专用导入的合成工作区。
"$BIN" plan --file shared/shared.mbt examples/workspace-demo

# 库变更选中根包及其导入方。
"$BIN" plan --file impact_plan.mbt .

# 仅 CLI 变更不选中任何包：没有受影响的包包含测试。
"$BIN" plan --file cmd/impact/main.mbt .

# 清单变更可能改变图本身：选中所有包。
"$BIN" plan --file moon.mod .

# 执行选中集合。
"$BIN" plan --file impact_plan.mbt --run .
```

保守回退的原则保持不变：无法解析的清单、缺失的模块描述文件、不属于任何包的变更，或清单/描述文件变更，都会请求**所有**包，而非假装没有测试受影响。源码仅为发现测试而读取；读取或 UTF-8 解码失败会阻止执行。符号链接形式的源码（包括 `.mbt.md`）、样式表和清单会被拒绝；普通符号链接文档属于成员数据，不会阻止计划。

## 构建并试用本地演示

在本仓库根目录执行：

```sh
moon build --target native
BIN="$PWD/_build/native/debug/build/cmd/impact/impact.exe"

# 模块依赖：fees -> summary -> 其测试，以及直接的费用测试。
"$BIN" plan --file src/fees.ts \
  --config examples/impact-demo/moonimpact.json examples/impact-demo

# 文件输入依赖：样式表由测试读取，而非导入。
"$BIN" plan --file src/theme.css \
  --config examples/impact-demo/moonimpact.json examples/impact-demo

# 供 CI 使用的 JSON，或没有外部资源/脚本的独立 HTML。
"$BIN" plan --file src/theme.css --format json \
  --config examples/impact-demo/moonimpact.json examples/impact-demo
"$BIN" plan --file src/theme.css --format html \
  --config examples/impact-demo/moonimpact.json examples/impact-demo > impact-demo.html
```

与现有 moonlint 文件系统桥接一样，该可执行文件目前面向 **macOS/Linux native**。原有 `cmd/main` moonlint 入口保留。

## 变更输入

必须且只能选择一种输入模式：

| 选项 | 含义 |
| --- | --- |
| `--file <path>` | 显式指定相对根目录的变更路径，可重复提供；不会静默地按扩展名过滤路径。 |
| `--worktree` | 从 HEAD 到实时工作区的变更，包括已暂存、未暂存和未被忽略的未跟踪文件。 |
| `--base <ref>` | 从指定提交到实时工作区的变更，包括未跟踪文件。这是直接的提交比较，不是基于 merge-base 的 PR 语义。 |

根目录默认为当前目录。Git 模式目前要求使用 **Git 仓库根目录**。未知引用和 Git 失败以 2 退出，而非声称变更集为空。Git 变更收集不会运行仓库钩子或外部 diff/textconv 命令。配置了 Git clean/process 过滤器的仓库会被拒绝，退出码为 2；应使用显式 `--file` 输入，或在使用 Git 输入前移除可执行过滤器，因为 Git diff 在检查工作区内容时可能调用它。重命名由旧路径和新路径共同表示；缺失/已删除输入要求完整回归，因为 MoonImpact 不会重建先前的依赖图。

这些模式有意区别于 moonlint 的 HEAD/index blob 扫描模式。分析始终读取**实时工作区**，并非原子的仓库快照；生成计划或执行测试期间，应避免并发修改 Git/源码。

## 配置

仅加载显式 `--config` 路径。配置是仅含数据的 JSON：不执行 JavaScript 配置，不支持任意命令模板，也不安装依赖。路径、别名和模式相对于所分析项目的根目录，**不是**配置文件所在目录。

```json
{
  "version": 1,
  "include": ["src/**", "test/**"],
  "exclude": ["src/vendor/**", "**/*.min.js"],
  "tests": ["test/**/*.test.ts", "test/**/*.spec.ts"],
  "aliases": {"@": "src"},
  "file_readers": ["readSource"],
  "dependencies": [
    {"dependent": "test/theme.test.ts", "dependency": "src/theme.css"}
  ],
  "max_source_bytes": 2000000
}
```

- 未提供 `include` 时，所有非噪声目录均参与；默认噪声目录（`.git`、`node_modules`、`.pnpm-store`、`dist`、`target`、`_build`、`.mooncakes`、`coverage`、`.rspeedy`、`.vitepress`、`.preview`）不会被遍历。若项目测试确实读取常规构建输出，可用 `skip_dirs` 替换该列表。
- **成员清单覆盖整棵树；分析受范围限制。** 除噪声目录外的每个普通文件均为已知成员。`include`/`exclude` 决定将哪些文件作为源码解析。原始读取可将范围外文件解析为叶子输入；对范围外代码或样式的普通导入仍要求回退，除非显式声明覆盖了被导入文件的依赖。没有任何读取方或导入方的变更文件会报告为未建模输入；若不存在其他要求回退的不确定性，已知消费者可支持选择性选择。
- 默认测试为 JS/TS 系列扩展名下的 `*.test` / `*.spec`。其 glob 路径支持 `*`、`?` 和整路径段 `**`，不支持花括号展开。
- 别名前缀按路径段边界匹配，最长前缀优先。`@` 映射不会匹配 `@scope/package` 等 npm 包。
- `file_readers` 显式声明简单包装函数名称，其**第一个参数是相对项目根目录的输入路径**。例如 `readSource('src/theme.css')`。这是用户提供的契约，不是对任意函数实现的证明。非字面量路径调用仍有不确定性。适配器可能抑制已识别配置包装函数定义内部的动态读取；调用方仍会逐一检查。
- `dependencies` 添加精确的手动边，使用 `kind: explicit`，不伪造源码坐标（`line`/`column` 为零）。依赖也可以是 **glob**（`*` / `?` / 整路径段 `**`），针对当前成员清单展开；每个匹配生成独立的边，未匹配任何内容的 glob 会被报告，而非静默为空。声明某个文件即断言声明覆盖其无法证明的读取——预期用途是清单驱动的辅助程序和构建脚本——因此会抑制该文件的不确定性问题，但 I/O 和安全失败仍会阻止执行。声明不足会静默遗漏依赖：应对照真实读取验证声明。
- `style_load_paths` 列出相对根目录的目录，在导入文件自身目录之后尝试，模拟 Sass `loadPaths`。支持裸说明符（`@use 'styles/variable.scss'`），也支持只能通过组件加载路径解析的 `../` 风格外观转发；相对解析仍优先，歧义或未解析结果仍属于不确定性。
- `runner_dir` 指定测试运行器配置所在目录，适用于 Vitest 配置不在分析根目录的 monorepo。它仅影响 `--run` 执行：测试进程在那里运行，选中测试路径以相对该目录的形式传入。
- `global_inputs` 可覆盖默认的完整回归触发项：包清单/锁文件、Vite/Vitest/TypeScript 配置、常用 setup 文件、环境文件、常规 Vue 应用入口和 `moonimpact.json`。
- 超过 `max_source_bytes` 的受支持代码或 CSS/SCSS 源码不被解析，并导致回退；限制在读取字节后检查。JSON、字体和图像仍作为成员/叶子输入，不会被解码为 JavaScript 或 CSS。
- 无效/未知配置字段、重复键、不安全路径、无效测试 glob 和无效数字限制均会被拒绝。

## 静态文件读取适配器

文件读取通过符号方式解析；绝不通过求值项目代码来查找路径。适配器区分相对根目录的字符串与基于源模块目录的路径。

支持的形式包括直接字面量 fs 读取、使用固定路径段和已知基准（`process.cwd()` 或未被遮蔽的 `__dirname`）的已导入 path `join`/`resolve`，以及静态 `new URL('./input', import.meta.url)`，后者可选地通过实际导入的 `fileURLToPath` 转换。受支持的不可变顶层常量可携带这些已知值。无法安全解析的 URL 协议、编码/查询/片段形式仍保持为不确定性，不会猜测文件路径。

也可推断小型、**经证明的**单返回包装函数，无需将其名称加入 `file_readers`：

```ts
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
const ROOT = process.cwd()
function read(file: string) {
  return readFileSync(resolve(ROOT, file), 'utf8')
}
const page = read('src/Page.vue')
```

这种推断有意比通用函数分析更窄：被调用方必须是真实 fs 导入，参数/路径关系必须已知，而且不能隐藏额外语句、额外 I/O、计算参数、遮蔽或重新绑定。调用点仍需要静态已知输入。显式 `file_readers` 配置仍是独立的用户契约；不会仅因任意函数名为 `read` 就信任它。

原始读取将文件视为数据，而非要执行的模块。读取 `include` 之外根配置文件的文本时，只要该确切文件属于已知成员，就无需解析它自身的导入。这不会扩大目录范围，也不会跟随符号链接。原始文件系统文件名保留字面的 `?` 和 `#`，不会对其应用 URL 清理。

## 样式表依赖

范围内的 CSS 和 SCSS 文件通过专门的静态扫描器解析，而非 JavaScript 解析器。Vue 内联样式使用同一扫描器，并保留源文件坐标。因此，静态导入、Sass 模块引用和资源 URL 可以形成传递链：

```text
font.woff2 -> fonts.css -> theme.scss -> Card.vue -> card.test.ts
```

- 识别 CSS `@import`、静态 `url(...)`、SCSS `@use` / `@forward` 和字面量导入列表。注释和引号中的普通文本不会变成依赖。
- 配置别名适用于本地样式表和资源引用。会考虑 Sass 局部文件（`_name.scss`）和索引模块；有歧义的选择、旧式 `.import.scss` 优先级以及自定义导入器/加载路径假设仍会导致完整回退。
- CSS URL 的查询/片段后缀不改变底层资源路径。远程 HTTP(S)/data URL 和本地片段 URL 不会从磁盘读取。`sass:` 内置项和带作用域的 Sass npm 包是外部依赖，由包/锁文件变更约束；不会递归分析 node_modules。
- 动态插值/变量、未解码的转义或百分号编码本地路径、未知协议、未解析路径，以及无映射的 Web 根绝对 URL，仍是显式不确定性。
- 只解析 CSS/SCSS。其他预处理器仍不受支持。缺失、被排除或未解析的样式表内容绝不会授权选择性执行。
- 传递分析仍限于配置的文件系统范围。引用的字体/图像是叶子输入，不会解码为文本。样式读取/编码失败与代码源码失败一样会阻止执行。

## 依赖覆盖和保守回退

计划器覆盖静态导入、重新导出和受支持的字面量模块调用，以及支持的文件读取形式和显式配置的读取器包装函数。Vue SFC 适配器区分真实脚本区域和模板文本，并保持原始文件中的引用位置；首个块之前的文件级 `/* */` 或 `//` 文件头会像 HTML 注释一样被跳过。这**不是** Vue 编译器、TypeScript 类型检查器、完整绑定解析器或通用动态 I/O 追踪器。JSX/TSX 目前要求回退，不会假装 JSX 文本是 JavaScript。静态 CSS/SCSS 和受支持的 Vue 样式块使用上述样式表适配器；动态样式表输入和不支持的预处理器仍要求完整回退。

另外建模了三种输入形式：

- **目录读取。** 具有可证明路径的 `readdirSync`/`readdir` 成为对该目录下每个当前条目的依赖。添加、删除或编辑任何条目都会改变计划；绝不会假定读取方依赖固定的文件列表。
- **存在性检查。** 具有可证明路径的 `existsSync`/`statSync`/`accessSync` 依赖该路径，无论它目前是否存在，因此之后创建或删除它仍会到达读取方。
- **字面量 `import.meta.glob` 模式。** 字面量模式（包括旧式 `globEager` 写法）展开为其当前指向的模块；计算得到的模式仍为不确定性。分析范围之外的匹配项是叶子输入，不分析它们自身的依赖。

不支持的动态导入/读取、未解析的本地别名、有歧义的模块解析、未知源码结构和被排除的源码依赖，均报告为不确定性。它们会请求所有测试，而非静默地把缺失边变成自信的无影响答案。相比不受支持的选择性执行，额外的完整套件回退更可取。

| 策略 | 行为 |
| --- | --- |
| `related` | 选中从变更输入可达的清单内测试；为每个测试附上一条确定性的最短已知链。 |
| `full` | 报告选择性分析无法得出结论或全局输入发生变更的原因；`--run` 请求 Vitest 不带过滤的完整套件，或执行不带包过滤器的 `moon test`，不依赖静态测试清单。 |
| `none` | 没有变更，或在配置的受支持模型下没有已知可达测试。不运行测试命令。这不代表完整套件通过。 |
| `blocked` | 源码 I/O/编码/不安全路径失败，或没有可用测试清单。不得执行。 |

完整回退可包含没有证据链的测试。不会声称这些测试已被证明受影响。运行完整套件时，Vitest 可能发现 MoonImpact 配置清单之外的测试。仍需定期验证完整套件；将选择性运行用于 CI 优化前，应与实际运行器配置对比。

MoonImpact 构建全新的依赖图。它**不复用 moonlint 缓存的结构判定**：图、文件输入依赖和测试清单具有不同的身份和正确性契约。

## 显式测试执行

审查计划后，在已经安装 pnpm/Vitest 及其依赖的可信项目中添加 `--run`：

```sh
"$BIN" plan --file src/fees.ts --run --timeout-ms 60000 \
  --config examples/impact-demo/moonimpact.json examples/impact-demo
```

进程使用固定 argv（`pnpm exec vitest run` 加上独立的 `./test-path` 过滤器），不进行 shell 命令插值。完整回退刻意省略过滤器。空的 related 选中集合绝不会意外调用完整套件。子进程标准输出/标准错误均发送到标准错误，以保持 JSON/HTML 计划输出可解析。测试进程以你的权限运行，可能产生项目测试的正常副作用；`--run` **不是**沙箱。

monorepo 通常在包目录而非分析根目录配置运行器。`runner_dir` 指定该目录：测试进程在那里运行，每个选中测试路径以相对该目录的形式传入。选中测试位于运行器目录之外属于配置错误，绝不会被静默丢弃过滤器——运行器无法定位它看不到的路径。

`--report <new-file>` 还会以原子、仅创建的语义发布 JSON 计划。父目录必须存在；不会替换已有文件、目录和符号链接。每次报告应使用新文件名。

退出码：

- `0`：生成了未被阻止的计划；若实际运行了测试进程，则其成功退出。默认仅生成计划时的退出码 0 **不**意味着测试通过。
- `1`：显式启动的测试进程未成功退出。
- `2`：用法/配置/Git/I/O/启动/超时错误，或被阻止的计划。

## 真实项目测量

### MoonBit 模块

公开的 [moonbitlang/x](https://github.com/moonbitlang/x) monorepo（25 个包，其中 19 个包含测试）无需配置即可生成计划。固定在提交 `6b67e08`，通过 `--run` 执行计划，并与完整套件比较：

| 变更 | 策略 | 选中的包 | 完整套件 | 选择性运行 | 冷缓存实际耗时 |
| --- | --- | --- | --- | --- | --- |
| `decimal/decimal.mbt` | related | 1 / 19 | 795 个测试 | 27 个测试 | 4.67s → 0.48s |
| `encoding/encoding.mbt` | related | 4 / 19 | 795 个测试 | 175 个测试 | 4.67s → 0.57s |

`encoding` 选中集合是 `crypto`、`encoding`、`fs` 和 `jwt`，通过声明的依赖到达，包括来自 `crypto` 的 `for "test"` 导入。`decimal` 包是叶子，因此只选中其自身包。

注入故障均被捕获。将 UTF-16 大端输出写成小端，在 `encoding` 中引入两个失败；包含 4 个包的选中集合和 795 个测试的完整套件均报告了这些失败，以及同一个既有 `crypto` 失败。`decimal` 规范化中的故障被包含 1 个包的选中集合捕获。完整记录（含被测项目中既有且无关的失败）见[第五轮验证](<moonimpact-round5-verification.zh-CN.md>)。

刻意固定了该提交。第五轮验证时检查的上游 `HEAD` 在 `fs` 中使用 `@io.ReaderClosed`，而该次验证固定的 core 未导出该项。由于上游/工具链版本不匹配，它在该环境中无法编译，这并非计划缺陷。

本仓库在执行 `moon clean` 后的一次冷缓存比较记录：

| 运行 | 实际耗时 | 测试数 |
| --- | --- | --- |
| 完整套件（`moon test`） | 5.4s | 555 |
| 仅 CLI 变更（`moon test cmd/impact`） | 2.1s | 0——计划为 `none` |

第二行显示了没有受影响包包含测试时计划器得出的结论；这是对覆盖情况的陈述，并非对需要测试的变更节省了多少工作的测量。第五轮记录提供了选中集合确实运行了套件中相当一部分测试的案例。

### JS/TS 项目

针对公开的 [wot-lynx-ui](https://github.com/ximo-156/wot-lynx-ui) monorepo 的只读评估（982 个已分析源码、12,019 条已知边、135 个测试文件 / 2261 个测试），使用两个明确变更：`packages/core/src/common/formatDate.ts` 和 `packages/core/src/common/host.ts`。所用配置为 [impact-wot-lynx-ui.json](<../examples/impact-wot-lynx-ui.json>)；在同时包含该项目可选、被 git 忽略的 `.wot-ref` 参考副本的工作区中，可使用它复现下列测量。

| 变更 | 策略 | 选中数量 | 备注 |
| --- | --- | --- | --- |
| `formatDate.ts` | related | 71 / 135 | 专用单元测试，以及传递关联的组件和一致性测试 |
| `host.ts` | related | 101 / 135 | 整个套件广泛导入 `configureHost` |

对另一个项目 unibest 的初始 MVP 评估测得 618 个源码 / 2,241 条边 / 319 个不确定性项，并对两个变更输入回退到 `full`。这些数字不构成与本次 wot-lynx-ui 评估的前后对比。后者由清单驱动的测试辅助程序（`component-roots.ts`、`scripts/` 下的构建脚本）会读取运行时参数指定的目录树，因此演示配置使用 `dependencies` 契约显式声明这些读取——计划依赖这些声明时，会报告 `declared-dependencies: 64 uncertainties covered by explicit contracts`。每个声明都已对照其覆盖的代码验证。

执行证据（干净工作区，从 `packages/ui` 执行 `vitest run`）：

| 运行 | 测试文件 | 结果 | 实际耗时 |
| --- | --- | --- | --- |
| 完整套件 | 135 | 3 个既有失败，2185 个通过 | 37.1s |
| 选中子集（formatDate 变更） | 71 | 相同的 3 个失败，1398 个通过 | 20.9s |
| 选中子集，注入 `getFirstDayOfWeek` 差一错误 | 71 | 4 个失败——format-date 测试捕获了故障 | 21.3s |
| 完整套件，相同的注入故障 | 135 | 4 个失败——捕获结果相同 | 39.7s |

子集各行通过工具自身的 `--run` 产生（随附配置将 `runner_dir` 设为 `packages/ui`，该项目在那里配置 Vitest），因此在相同 `.wot-ref` 条件下，该表可端到端复现；在全新克隆（无 `.wot-ref`）中，五个声明报告 `unresolved-explicit-dependency`，计划回退到 `full`，而非静默地匹配不到任何内容：

```sh
moon build --target native
BIN="$PWD/_build/native/debug/build/cmd/impact/impact.exe"
"$BIN" plan --file packages/core/src/common/formatDate.ts --run \
  --config examples/impact-wot-lynx-ui.json /path/to/wot-lynx-ui
```

三个既有失败是该本地工作区中重复组件目录导致的组件清单不匹配；它们与变更无关，在两次运行中表现完全相同。测量后已撤销注入故障。选择性选择是保守的：并不声称输入变化时每个选中测试都会失败。

## 验证

```sh
moon check --target native --no-mbti
moon test --target native
moon build --target native
python3 tests/impact_integration.py \
  --binary "$PWD/_build/native/debug/build/cmd/impact/impact.exe"
python3 tests/impact_native.py
# 可选：指向已有且可信的 Vitest 包；不会安装任何内容。
python3 tests/impact_vitest_smoke.py \
  --binary "$PWD/_build/native/debug/build/cmd/impact/impact.exe" \
  --vitest-dir /path/to/installed/node_modules/vitest
# 同时保留原有 moonlint 回归套件：
python3 tests/integration.py \
  --binary "$PWD/_build/native/debug/build/cmd/main/main.exe" --phase all
```

测试使用自有临时目录和本地伪 pnpm 可执行文件，在不安装依赖、不运行业务项目测试的情况下验证进程参数和安全性。演示是合成的，不包含 unibest 源码、私有端点、客户数据或凭据。真实项目评估应在本地以只读方式进行，除非另行要求执行测试。
