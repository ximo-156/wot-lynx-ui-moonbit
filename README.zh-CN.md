# MoonImpact

[English](<README.md>) | [简体中文](<README.zh-CN.md>)

MoonImpact 针对一次代码变更回答一个问题：**应该运行哪些测试，以及为什么**。它使用 [MoonBit](https://www.moonbitlang.com/) 编写，支持为两类项目生成测试计划：

- **MoonBit 模块与工作区**（无需配置）：从 `moon.pkg` 清单读取包依赖图。根目录存在 `moon.work` 时，仅分析显式列出的成员模块，并连接成员模块之间已声明的导入；普通、`for "test"` 和 `#cfg` 导入块都会计入。文件变更会选中其所属包及所有传递导入方；`--run` 会针对每个选中的包调用 `moon test`。无法识别的工作区语法会回退到完整测试套件。
- **JS/TS 项目**（显式提供 `moonimpact.json`）：支持静态导入、有界的文件读取与读取器包装函数推断、CSS/SCSS 输入链、字面量 `import.meta.glob` 模式、目录读取和存在性检查。

无论哪种模式，计划都**可解释**：每个选中的测试都附有一条确定性的最短证据链；对于模型检测到但尚未建模的情况，会请求运行完整测试套件，而不会悄然宣称“没有影响”。计划只是建议，绝不等同于测试通过结果。

模型只能证明它能看到的关联。清单中从未声明的依赖对模型不可见，因此，计划不能证明所有受影响的包都已被选中。

```sh
moon build --target native

# MoonBit 模块：本仓库就是一个。
moon run cmd/impact -- plan --file impact_plan.mbt .
moon run cmd/impact -- plan --file cmd/impact/main.mbt .

# MoonBit 工作区：跨模块依赖由成员清单显式声明。
moon run cmd/impact -- plan --file shared/shared.mbt \
  examples/workspace-demo

# 使用显式配置的 JS/TS 项目。
moon run cmd/impact -- plan --file src/fees.ts \
  --config examples/impact-demo/moonimpact.json examples/impact-demo
```

生成计划不会运行测试、构建或安装依赖；只有 `--run` 才会使用固定参数执行项目自身的运行器。两种模式、JS/TS 合成[演示](<examples/impact-demo/README.zh-CN.md>)与 MoonBit [工作区样例](<examples/workspace-demo/moon.work>)、Git 输入、JSON/HTML 报告及执行安全性，详见 [MoonImpact 指南](<docs/moonimpact.zh-CN.md>)。

以下是实测结果，而非承诺。在公开的 [moonbitlang/x](https://github.com/moonbitlang/x) 单体仓库中，固定到提交 `6b67e08`（25 个包，其中 19 个包含测试），使用 **`--run` 执行计划**，并与完整测试套件对比：

| 变更 | 计划 | 完整测试套件 | 选中部分的执行 | 墙钟时间（冷启动） |
| --- | --- | --- | --- | --- |
| `encoding/encoding.mbt` | 4 / 19 个包 | 795 个测试 | 175 个测试 | 4.67s → 0.57s |
| `decimal/decimal.mbt` | 1 / 19 个包 | 795 个测试 | 27 个测试 | 4.67s → 0.48s |

选中的测试捕获了注入故障。将 UTF-16 大端输出写成小端，导致两个 `encoding` 测试失败。加上原有的 `crypto` 失败，选中的 4 个包与包含 795 个测试的完整套件恰好出现相同的三个失败测试。`decimal` 归一化中的故障也被选中的 1 个包捕获。包含被测项目中一个原有且无关的失败在内的详情，见[第五轮记录](<docs/moonimpact-round5-verification.zh-CN.md>)。

在公开的 [wot-lynx-ui](https://github.com/ximo-156/wot-lynx-ui) 单体仓库中，一次核心工具函数变更从 135 个测试文件中选出 71 个，墙钟时间缩短 44%，且选中的子集捕获了注入的偏一错误（off-by-one）。该 wot-lynx-ui 数据是在包含项目可选参考副本 `.wot-ref` 的工作区中测得的；该副本被 Git 忽略。在全新克隆中，五项 `.wot-ref` 声明会报告 `unresolved-explicit-dependency`，计划会如实回退到 `full`（135/135），见[第三轮记录](<docs/moonimpact-round3-verification.zh-CN.md>)。能否通过选择测试减少执行量取决于具体项目，并无保证。

仓库还包含 **moonlint**，这是本工具发展所基于的约定与项目策略检查器：`cmd/main` 完整保留其 CLI、模块标识、许可证声明和历史，MoonImpact 复用其源码与文件系统基础设施。两个入口相互独立。

## MoonImpact 如何决策

给定一组变更文件，MoonImpact 回答三个问题：哪些测试与变更存在已知依赖关系，哪条引用链解释了每次选择，以及为什么必须回退到完整测试套件或阻止执行。

| 类型 | 检测方式 | 测试单元 | 运行器（`--run`） |
| --- | --- | --- | --- |
| **MoonBit 模块/工作区**（默认） | 根目录包含 `moon.mod` / `moon.mod.json` 或 `moon.work`，未指定 `--config` | 包 | 为每个选中的包执行 `moon test <package>` |
| **JS/TS 项目** | 显式指定 `--config moonimpact.json` | 测试文件 | 执行 `pnpm exec vitest run`，使用 `./test-path` 过滤器 |

对于 MoonBit 模块，包依赖图直接从 `moon.pkg` 清单读取。若根目录有 `moon.work`，清单只纳入显式成员模块，并解析成员模块之间已声明的本地导入。当前支持非空的字面量 `members = [...]` 根目录相对路径列表；不支持的语法、缺失成员或有歧义的本地导入都会请求完整测试套件。文件变更会选中其所属包及所有直接或间接导入该包的包。

四种策略如实表达各自的适用范围：

| 策略 | 含义 |
| --- | --- |
| `related` | 选中的测试文件或包与变更之间存在已知依赖链 |
| `full` | 模型无法安全地缩小变更影响范围，因此请求完整 Vitest 套件或不带包过滤器的 `moon test` |
| `none` | 没有变更，或在受支持模型下没有受影响的测试文件或含测试的包 |
| `blocked` | I/O 或不安全路径条件阻止执行 |

计划只是建议，绝不等同于测试通过结果。不传入 `--run` 就不会执行任何内容，而 `--run` 并不是沙箱。

### 复现实测结果

```sh
moon build --target native
BIN="$PWD/_build/native/debug/build/cmd/impact/impact.exe"

# 公开被测项目，固定到提交 6b67e08：
git clone https://github.com/moonbitlang/x /tmp/x-checkout
git -C /tmp/x-checkout checkout 6b67e08

# 先运行被测项目的完整套件，再通过本工具运行选中的子集。
( cd /tmp/x-checkout && moon test )
"$BIN" plan --file encoding/encoding.mbt --run /tmp/x-checkout
```

固定提交是有意为之：第五轮验证时，上游 `HEAD` 的 `fs` 包使用了 `@io.ReaderClosed`，而记录中本地工具链的 core 并未导出它。该检出版本无法使用那套工具链编译；此处记录的是版本不匹配，而非规划缺陷，也不代表上游当前的构建状态。

## 验证记录

每份记录对应一轮独立测量，被测对象、命令和边界均在记录中说明：

| 记录 | 被测对象 | 验证内容 |
| --- | --- | --- |
| [MoonImpact 初始验证](<docs/moonimpact-verification.zh-CN.md>) | 初始 MVP | JS/TS 影响分析 MVP 在首个评估项目上的表现 |
| [第二轮](<docs/moonimpact-round2-verification.zh-CN.md>) | 扩展后的 MVP | 静态读取器、符号路径和样式表输入 |
| [第三轮](<docs/moonimpact-round3-verification.zh-CN.md>) | wot-lynx-ui（JS/TS） | 整棵目录树的成员集合、声明契约、真实项目中的选择性执行 |
| [第四轮](<docs/moonimpact-round4-verification.zh-CN.md>) | moonbitlang/x（MoonBit） | MoonBit 前端及其规划测量 |
| [第五轮](<docs/moonimpact-round5-verification.zh-CN.md>) | moonbitlang/x（MoonBit） | 在固定提交上进行端到端选择性执行和故障注入 |

[第六轮](<docs/moonimpact-round6-verification.zh-CN.md>)记录 source 布局、内联测试与全量执行的修复；[第七轮](<docs/moonimpact-round7-verification.zh-CN.md>)将固定版本语料扩展到 7 个公开项目，并提供库存核验及故障注入运行器。

## moonlint 检查器

本文其余部分介绍 **moonlint**，这是本工具发展所基于的约定与项目策略检查器。它保留自己的 CLI（`cmd/main`）、预设、基线和历史。MoonImpact 复用其源码与文件系统基础设施；两个入口相互独立。

### 为什么需要它

`moon check` 检查编译情况，并提供可选的 W74 `missing_doc` 警告（默认关闭）；`moon fmt` 负责格式化代码。moonlint 不替代二者。它将项目约定、例外额度、包分层约束和历史公共接口审查转化为显式 CI 检查。ESLint 和 Biome 自带的 JS/TS 解析器无法解析 MoonBit；在混合仓库中，它们的 JS/TS 检查仍然有用。

源码前端是词法/声明扫描器，并非完整 AST 或绑定/类型解析器。lint 结果无问题并不证明源码能编译。始终应单独运行 `moon check`。

### 起源

moonlint 最初是 Vue Lynx 组件库 [`ximo-156/wot-lynx-ui`](https://github.com/ximo-156/wot-lynx-ui) 中代码审查 lint 脚本的 MoonBit 重写版本。所参考的脚本为 `scripts/review-lint.mjs`；其 MIT 声明署名为 **2026 wot-lynx-ui contributors**。该规则目录为兼容预设提供了参考。这是一种参考/移植关系，并不意味着已经独立证明不存在代码复制。本仓库在 [LICENSE](<LICENSE>) 中声明采用 Apache-2.0；另见[第三方归属声明](<THIRD_PARTY_NOTICES.zh-CN.md>)。

由于公共结果字段和结构检查变体发生变化，本地清单现以 **0.3.0** 为目标版本。验证记录描述的是特定本地运行，而非已发布版本。MoonBit 模块规划工作已在 `1a5d8ce`（2026-11-12）中提交；各次运行的范围见[验证记录](#验证记录)。

### 它能做什么

`moonlint` 扫描目录树，对每个源文件应用声明式规则，并报告违规。规则从 JSON 加载，因此同一引擎可执行任意项目的约定。MoonBit 文件由声明扫描器读取，将非空 `///` 文档关联到顶层条目；单独的 `///|` 只是块分隔符。JS/TS 文件则由分词器和导入图层读取。

### 功能

- **MoonBit 优先** — `moonbit` 预设涵盖公共文档、命名、`unwrap()` / `panic()`、`println()` 和 TODO 注释；递归排除测试文件，打印规则还会排除 CLI 入口。
- **配置驱动** — 规则定义在 JSON 中，无需修改代码。
- **JS/TS 兼容预设** — 提供 React、Vue、Angular、Svelte、Next.js、SolidJS、Astro、Nuxt、通用 JS/TS 代码规范、文件级检查和跨文件导入检查的即用规则集；通过 `--preset <name>` 启用。
- **正则表达式与子串匹配** — 支持 `contains`、`prefix`、`suffix`、`regex`、`equals` 和 `word` 匹配器。
- **匹配器组合** — `all` / `any` / `not` 可在解析器限制范围内嵌套，因此 `match` 可表达叶子匹配器上的任意布尔公式。
- **否定保护条件** — 使用 `unless` 字段抑制误报（例如“从 'vue' 导入，但不是 'vue-lynx'”）。
- **理解注释** — 匹配前将 `//` 和 `/* */` 注释替换为空格，同时保留行列位置；JS/TS/JSX 扫描器理解模板字面量、`${}` 插值、字符串和正则字面量，因此模板字符串中的 `//` 是文本而非注释。默认代码视图还会清空字面量的*内容*，因此 `const q = "FORBIDDEN"` 不会被视为代码；目标仅存在于字面量值中的规则通过 `"match_literals": true` 显式启用，*以注释为目标*的规则通过 `"match_comments": true` 启用。
- **跨文件结构规则** — JS/TS 分词器和解析器构建项目范围的导入图，支持未使用的导入、重复导入、无法解析的相对导入、导入循环、过深的相对导入、`require()` 使用、`export default` 和无用导出检查（`--preset imports`）。
- **基线 v2** — 显式、按次数限额的内容豁免，附带原因、负责人、到期时间和全树未使用额度审计；仍可读取旧数组格式。
- **包策略** — 对提供的编译器 v3 包依赖图施加直接依赖约束，区分 source/test/wbtest 类型并支持后端选择。
- **API 审查关卡** — 历史 `.mbti` 声明快照识别移除和保守的结构变化；可选 semver 策略用于记录有意的不兼容版本发布。
- **增量缓存** — `--incremental` 只重新检查内容哈希变化的文件；生效配置变化时自动失效。
- **严重级别** — 支持 `error` 和 `warning`，任何 error 级别问题都会使退出码为 1。
- **按作用域报告** — 全局及每条规则的 `include`/`exclude` 控制报告范围；未选中或被排除的依赖文件仍可能作为项目上下文读取，并明确计数。
- **CI 输出** — 机器可读 JSON 报告、GitHub Actions 注解和 SARIF 2.1.0，包含读取、失败和跳过元数据。
- **如实计数** — 每个选中文件都报告为已扫描、已跳过（附原因）或失败；扫描绝不会悄然降级为“无问题”。
- **摘要模式** — 按规则汇总，并列出读取/跳过/失败计数。

### 安装

```bash
# 克隆并构建
git clone https://github.com/ximo-156/wot-lynx-ui-moonbit
cd wot-lynx-ui-moonbit
moon build --target native
```

### 用法

在本检出目录中使用 `moon run cmd/main --` 运行检查器。下文使用简写 `moonlint` 命令的示例，假定你已将构建产物 `_build/native/debug/build/cmd/main/main.exe` 以 `moonlint` 名称放入 `PATH`；单独执行 `moon build` 不会安装该命令。

```bash
# 在当前目录创建 MoonBit 初始配置
moon run cmd/main -- --init

# 使用内置预设检查 MoonBit 包
moon run cmd/main -- --preset moonbit packages/

# 使用生成的配置进行检查
moon run cmd/main -- .

# 检查指定目录
moon run cmd/main -- /path/to/project

# 使用自定义配置
moon run cmd/main -- --config my-rules.json /path/to/project

# 摘要模式
moon run cmd/main -- --summary /path/to/project

# 仅显示错误
moon run cmd/main -- --errors-only /path/to/project

# 生成基线（豁免当前所有问题）
moon run cmd/main -- --update-baseline /path/to/project

# 使用基线
moon run cmd/main -- --baseline moonlint.baseline.json /path/to/project

# 将机器可读 JSON 报告输出到 stdout，并写入文件
moon run cmd/main -- --format json /path/to/project
moon run cmd/main -- --report moonlint-report.json /path/to/project

# GitHub Actions 注解
moon run cmd/main -- --format github /path/to/project

# JS/TS 兼容扫描中的跨文件导入检查
moon run cmd/main -- --preset imports /path/to/project

# 快速重复扫描：仅重新检查发生变化的文件
moon run cmd/main -- --incremental /path/to/project
```

### 内置预设

主要预设为 `moonbit`。JS/TS 预设是为同时包含前端代码的仓库提供的兼容规则集。使用 `--preset <name>`（可重复指定）启用一个或多个预设；多个预设的规则合并后按规则 id 去重。

```bash
# 列出可用预设
moon run cmd/main -- --list-presets

# 检查 MoonBit 源码
moon run cmd/main -- --preset moonbit packages/

# 检查 React 项目
moon run cmd/main -- --preset react /path/to/project

# 检查 Vue 项目
moon run cmd/main -- --preset vue /path/to/project

# 组合预设（例如 React + 通用代码规范）
moon run cmd/main -- --preset react --preset common /path/to/project
```

`--preset` 与 `--config` 互斥。未知的预设名属于用法错误（退出码 2）。

#### 可用预设

| 预设 | 扩展名 | 规则数 | 重点 |
|--------|-----------|-------|-------|
| `moonbit` | `.mbt` | 6 条结构规则 | MoonBit：require-public-doc, naming, no-unwrap, no-panic, no-println, no-todo-comment |
| `common` | `.js` `.jsx` `.ts` `.tsx` `.mjs` `.cjs` `.vue` `.svelte` `.astro` | 6 | 框架无关的代码规范：no-console-log, no-debugger, no-alert, no-eval, no-var, no-todo-comment |
| `react` | `.jsx` `.tsx` | 20 | React/JSX：no-danger, no-string-refs, jsx-key, self-closing, target-blank, button-type, ... |
| `vue` | `.vue` `.js` `.ts` | 11 | Vue 3：no-v-html, require-v-for-key, no-v-if-with-v-for, require-scoped-style, ... |
| `angular` | `.ts` | 9 | Angular：no-input-rename, no-output-native, no-forward-ref, relative-url-prefix, ... |
| `svelte` | `.svelte` | 8 | Svelte：no-at-html, require-each-key, a11y-missing-attribute, no-goto-without-base, ... |
| `next` | `.jsx` `.tsx` `.js` `.ts` | 7 | Next.js：no-img-element, no-head-element, no-html-link-for-pages, google-font-display, ... |
| `solid` | `.jsx` `.tsx` | 6 | SolidJS：no-innerhtml, prefer-for, no-react-imports, event-directives, ... |
| `astro` | `.astro` | 5 | Astro：no-set-html-directive, prefer-class-list, no-unused-define-vars, ... |
| `nuxt` | `.vue` `.js` `.ts` | 5 | Nuxt：no-env-in-runtime, prefer-use-fetch, no-window-in-ssr, ... |
| `file` | `.js` `.jsx` `.ts` `.tsx` `.mjs` `.cjs` `.vue` `.svelte` `.astro` | 6 条文件规则 | 文件级：max-lines, max-line-length, no-trailing-whitespace, no-tabs, final-newline, no-duplicate-lines |
| `imports` | `.js` `.jsx` `.ts` `.tsx` `.mjs` `.cjs` `.mts` `.cts` `.vue` `.svelte` `.astro` | 7 条结构规则 | 跨文件：no-unused-imports, no-duplicate-imports, no-unresolved-relative-imports, no-import-cycles, no-deep-relative-imports, no-require-imports, no-unused-exports |

`moonbit` 预设的文档和命名规则检查顶层公共条目。调用和 TODO 规则也检查常规实现代码。`*_test.mbt` 和 `*_wbtest.mbt` 会被递归排除；`cmd/**` 从 `no-println` 规则中排除，因为 CLI 入口本来就需要打印。

每个预设也在 `presets/` 下提供独立 JSON 文件（`angular`、`astro`、`common`、`file`、`imports`、`moonbit`、`next`、`nuxt`、`react`、`solid`、`svelte`、`vue`），便于复制和定制：

```bash
moon run cmd/main -- --config presets/react.json /path/to/project
```

> **注意：** 框架预设按行工作：注释被替换为空格后，每次匹配一行源码。这些预设有意不提供需要 AST 的规则（未使用变量、hook 依赖、prop 类型）；`imports` 预设则尽力进行跨文件导入分析（见[跨文件结构规则](#跨文件结构规则)）。`moonbit` 预设使用声明扫描器而非 JS/TS 解析器；它读取非空文档和顶层条目，并跳过 `*_test.mbt` / `*_wbtest.mbt`，因为测试中可能需要 unwrap、panic 和打印。

### 匹配器类型

一个匹配器对象必须且只能包含以下一种：

- `{ "contains": "substring" }` — 行包含该子串。
- `{ "prefix": "text" }` — 行以该文本开头。
- `{ "suffix": "text" }` — 行以该文本结尾。
- `{ "regex": "pattern" }` — 行匹配该正则表达式。
- `{ "equals": "text" }` — 去掉首尾空白后的行与该文本完全相等。
- `{ "word": "text" }` — 行以完整单词形式包含该文本。

#### 匹配器组合

任意匹配器（包括 `unless`）均可改为匹配器的布尔组合，并在解析器限制范围内嵌套：

- `{ "all": [ … ] }` — 每个子匹配器都必须匹配（空列表匹配所有行）。
- `{ "any": [ … ] }` — 至少一个子匹配器必须匹配（空列表不匹配任何行）。
- `{ "not": { … } }` — 子匹配器必须不匹配。

```json
{
  "id": "common/no-unguarded-console",
  "severity": "warning",
  "message": "console.log without a lint exemption",
  "extensions": [".ts"],
  "match_comments": true,
  "match": {
    "all": [
      { "contains": "console.log" },
      { "not": { "any": [ { "word": "allow" }, { "contains": "moonlint-ok" } ] } }
    ]
  }
}
```

该规则会对 `console.log(x)` 报告问题，但不会对 `console.log(x) // moonlint-ok` 报告问题。显式的 `match_comments` 选项让保护条件能看到注释标记；同时也使规则按原文检查字面量文本和注释。组合器内部嵌套的错误正则表达式属于配置错误（退出码 2），报告会包含出错子匹配器的路径。

#### 在注释内匹配

行规则通常看到的是文件的去注释视图：匹配前将注释替换为空格，因此字符串化脚本或 URL 片段不会看起来像代码。以注释本身为目标的规则（例如禁止 TODO 的规则）需显式选择原始视图：

```json
{
  "id": "common/no-todo-comment",
  "severity": "warning",
  "message": "TODO/FIXME comment left in code",
  "extensions": [".ts"],
  "match": { "any": [ { "word": "TODO" }, { "word": "FIXME" } ] },
  "match_comments": true
}
```

`match_comments` 按规则设置，默认为 `false`。启用后会看到文件原文，包括行注释和块注释，也包括字符串和模板字面量，因为它们同样属于“原始”内容。`unless` 保护条件和行内 `// moonlint-disable` 注释照常生效。

#### 在字面量内匹配

默认视图即*代码视图*，会清空 JavaScript/TypeScript/JSX 源码中字符串、模板和正则字面量的内容，因此 `const q = "FORBIDDEN"` 不会被视为代码，也不会被任何规则匹配。这使 JS/TS 行匹配器与一直清空字面量内容的 MoonBit 前端保持一致。有意保留的部分包括分隔符（`"`、`'`、`` ` ``、`/`），使 `ref="` 等属性形式的匹配仍然有效；以及 `${...}` 插值，因为插值是表达式而不是值。行列位置保持不变。`.vue`、`.svelte`、`.astro` 和未知扩展名没有理解字面量的扫描器，因此仍沿用去注释视图。

目标仅存在于字面量值中的规则，例如属性值 `target="_blank"`、模块说明符 `from 'react'` 或 URL，需显式选择*字面量视图*，即保留字面量文本的历史去注释视图：

```json
{
  "id": "react/jsx-no-target-blank",
  "severity": "warning",
  "message": "target=\"_blank\" without rel=\"noopener\" is a security risk",
  "extensions": [".jsx", ".tsx"],
  "match": { "regex": "target=\"_blank\"" },
  "unless": { "regex": "noopener" },
  "match_literals": true
}
```

`match_literals` 按规则设置，默认为 `false`。`unless` 保护条件与匹配器看到相同视图。设置 `match_comments` 时该选项被忽略，因为原始视图已包含字面量文本。随附预设为需要它的规则启用此选项（`react/jsx-no-target-blank`、`next/google-font-display`、`angular/relative-url-prefix` 等），`presets/*.json` 也包含同样的标志。视图选择参与增量缓存指纹，因此切换任一标志都会使缓存结果失效。

### 文件级规则

文件级规则检查整个文件的属性（大小、空白、命名、重复），而非单独一行。它们在配置中通过独立的 `file_rules` 数组声明：

```json
{
  "rules": [],
  "file_rules": [
    {
      "id": "file/max-lines",
      "severity": "warning",
      "message": "File exceeds 500 lines",
      "extensions": [".ts", ".tsx"],
      "check": { "max_lines": 500 }
    },
    {
      "id": "file/no-trailing-whitespace",
      "severity": "warning",
      "message": "Trailing whitespace found",
      "extensions": [],
      "check": { "no_trailing_whitespace": true }
    },
    {
      "id": "file/naming",
      "severity": "warning",
      "message": "File name must be kebab-case",
      "extensions": [".ts"],
      "check": { "file_naming": "kebab-case" }
    }
  ]
}
```

#### 文件检查类型

| 检查 | JSON | 说明 |
|-------|------|-------------|
| `max_lines` | `{ "max_lines": 500 }` | 文件不得超过 N 行 |
| `max_line_length` | `{ "max_line_length": 120 }` | 任何行不得超过 N 个字符 |
| `no_trailing_whitespace` | `{ "no_trailing_whitespace": true }` | 任何行不得有尾随空白 |
| `no_tabs` | `{ "no_tabs": true }` | 不得包含制表符 |
| `final_newline` | `{ "final_newline": true }` | 文件必须以换行符结尾 |
| `no_duplicate_lines` | `{ "no_duplicate_lines": true }` 或 `{ "no_duplicate_lines": 40 }` | 去掉首尾空白后至少有 N 个字符的行不得重复（默认 24；`0` 比较任意非空行） |
| `file_naming` | `{ "file_naming": "kebab-case" }` | 文件名必须遵循命名约定（camelCase、PascalCase、snake_case、kebab-case） |
| `max_file_size` | `{ "max_file_size": 10000 }` | 文件不得超过 N 字节 |
| `no_empty_files` | `{ "no_empty_files": true }` | 文件不得为空 |
| `line_ending` | `{ "line_ending": "lf" }` | 文件必须使用一致的行尾（lf 或 crlf） |
| `no_bom` | `{ "no_bom": true }` | 文件不得以 UTF-8 BOM 开头 |

存在 `file_rules` 时，`rules` 数组可省略。

`no_duplicate_lines` 只比较足够长、具有实质内容的行：最小去空白长度（默认 24）可避免 `}`、`</view>`、`/**` 和 `return` 等本来就会在各个文件中反复出现的内容淹没报告。可显式设置数字进行调整，或设置为 `0` 以比较所有非空行。

### 跨文件结构规则

行规则和文件规则每次只看到一个文件。JS/TS 结构规则使用尽力而为的分词器/声明/导入模型，并非完整 JS/TS AST 或 Node 模块/类型解析器。跨文件检查加载额外依赖上下文，只为选中的路径报告问题；上下文读取失败时返回退出码 2。

```json
{
  "rules": [],
  "structural_rules": [
    {
      "id": "imports/no-unused-imports",
      "severity": "error",
      "message": "Imported binding is never used",
      "extensions": [".ts", ".tsx"],
      "check": { "no_unused_imports": true }
    },
    {
      "id": "imports/no-import-cycles",
      "severity": "error",
      "message": "Import cycle detected",
      "extensions": [],
      "check": { "no_import_cycles": true }
    }
  ]
}
```

也可使用 `--preset imports` 启用整套规则。

#### 结构检查类型

| 检查 | JSON | 说明 |
|-------|------|-------------|
| `no_unused_imports` | `{ "no_unused_imports": true }` | 导入的绑定在导入文件中从未被引用 |
| `no_duplicate_imports` | `{ "no_duplicate_imports": true }` | 多条 import 语句导入同一模块 |
| `no_unresolved_relative_imports` | `{ "no_unresolved_relative_imports": true }` | 相对导入无法在提供的项目/上下文成员集合中解析 |
| `no_import_cycles` | `{ "no_import_cycles": true }` | 文件参与相对导入循环（按文件报告） |
| `no_default_export` | `{ "no_default_export": true }` | 使用了 `export default` |
| `no_deep_relative_imports` | `{ "no_deep_relative_imports": 2 }` | 相对导入通过 `../` 向上跨越超过 N 层目录 |
| `no_require_imports` | `{ "no_require_imports": true }` | ES 模块代码库中使用了 `require()` |
| `no_unused_exports` | `{ "no_unused_exports": true }` | 导出的名称从未被可用的项目/上下文文件导入（环境声明 `.d.ts` 文件豁免） |

存在 `structural_rules` 时，`rules` 数组可省略。结构问题与行问题一样，遵守行内 `// moonlint-disable <rule-id>` 注释和规则作用域。

跨文件检查会将未选中的依赖作为上下文读取。选择集合为空时，没有任何可报告内容（选择范围外的问题会被丢弃），因此会完全跳过上下文读取，不相关的不可读文件不会将空扫描变成退出码 2。

#### 路径别名

通过路径别名的裸说明符（`@/api/ka`、`~/utils/date`）无法自行解析，因此 `no_unused_exports` 会将所有通过别名导入的导出视为无用。请声明别名，以便跨文件处理能够跟踪它们：

```json
{
  "aliases": { "@": "src", "~": "." },
  "structural_rules": [
    { "id": "imports/no-unused-exports", "severity": "warning", "message": "dead export", "extensions": [], "check": { "no_unused_exports": true } }
  ]
}
```

别名目标**相对于扫描根目录**（正在检查的目录），因此与 `moonlint src` 一起使用的配置应将 `@` 映射到 `.`，而与 `moonlint .` 一起使用的配置应将 `@` 映射到 `src`。前缀按路径段边界匹配：`@` 匹配 `@/x`，但不匹配包 `@scope/pkg`；较长前缀优先于较短前缀（`@/lib` 优先于 `@`）。绝对目标、通过 `..` 逃逸和非字符串值属于配置错误（退出码 2）。不论是否解析别名，Vue 模板绑定（如 `:src="logo"`）都计为 `no_unused_imports` 的使用。

### 行内禁用注释

无需修改配置即可抑制问题报告：

```typescript
// moonlint-disable-next-line
const x = 1;  // this line is not linted

// moonlint-disable-next-line no-console-log
console.log('debug');  // only no-console-log is suppressed here

// moonlint-disable
// everything below is not linted
const y = 2;

// moonlint-enable
// linting resumes here
const z = 3;
```

- `// moonlint-disable [rule-id ...]` — 从本行开始禁用。
- `// moonlint-disable-next-line [rule-id ...]` — 仅在下一行禁用。
- `// moonlint-enable [rule-id ...]` — 从本行开始重新启用。
- 不指定规则 id 时，影响所有规则。

### 配置继承

配置可通过 `extends` 字段继承其他配置：

```json
{
  "extends": "presets/react.json",
  "rules": [
    { "id": "custom/no-foo", "message": "...", "match": { "contains": "foo" } }
  ]
}
```

`extends` 接受字符串或字符串数组。继承是递归的：每个路径相对于**声明它的配置文件**解析，因此 `lvl1/mid.json` 自身还可继承 `lvl2/leaf.json`。继承配置的规则与当前配置规则合并；id 冲突时，当前配置优先，这就是预期的覆盖机制。

循环 `extends` 链（`a.json` → `b.json` → `a.json`）会被检测并报告为配置错误（退出码 2），不会无限递归。同一文件中重复的 id（包括跨规则类型）会被拒绝。同类型 id 可有意覆盖继承规则。未知字段、被忽略的 `scope` 对象（请使用顶层 `include`/`exclude`）、无效严重级别、空扩展名条目、重复 JSON 键和有歧义的 match/check 对象都会作为错误报告，不会静默忽略配置。

### 自动修复

`--fix` 标志会就地修复可修复的文件级违规：

```bash
# 修复尾随空白和缺失的末尾换行
moonlint --preset file --fix /path/to/project

# 额外将制表符统一为 4 个空格（显式启用）
moonlint --preset file --fix --fix-tab-width 4 /path/to/project

# 显示拟修改内容，不写入任何内容
moonlint --preset file --fix --dry-run /path/to/project
```

候选检查包括 `no_trailing_whitespace`、`final_newline` 和 `no_tabs`。MoonBit 修复会保护引号/原始/插值字面量区域，并保留 BOM、Unicode 和 CRLF。文件检查仍会检查原始字面量中的空白，因此不可修复的字面量属性仍会被报告；修复绝不会抑制这些问题。对于末尾的原始内容行，会保守地不插入换行符。

非 MoonBit 的修复范围有意更窄：仅支持简单脚本源码；模板/标记保持不变，当引号或类似正则的区域可能携带值时，跳过制表符替换。其他语言不会被自动重写。仍有问题报告不代表修复成功。使 `--fix` 能够安全用于真实目录树的属性如下：

| 行为 | 详情 |
|-----------|--------|
| 遵守作用域 | 遵守规则的 `include`/`exclude` 和 `extensions`，因此绝不写入被排除的目录树（例如 `vendor/**`） |
| 保留行尾 | `final_newline` 为 CRLF 文件追加 `\r\n`，绝不追加单独的 `\n` |
| 显式启用制表符修复 | 制表符会改变缩进宽度，并可能改变语义（Python、YAML、Makefile），因此仅显式指定 `--fix-tab-width` 时才修复 `no_tabs` |
| 安全目标 / 原子写入 | 拒绝符号链接目标/祖先目录，替换前重新读取并在观察到内容变化时拒绝操作；这并非文件系统比较并交换事务 |
| stderr 消息 | 进度写入 stderr，使 `--format json`/`sarif` 的 stdout 保持可解析 |
| 仅工作区 | `--fix` 不能与 `--changed`/`--staged` 同用，后两者读取的是 Git blob 而非工作区 |
| 试运行 | `--dry-run` 报告 `would fix <file>` 而不写入；由于目录树未变，问题仍按现状报告 |

每次运行都会在 stderr 上按文件输出一行，并输出总计（`fixed N file(s)` / `would fix N file(s)`）。修复后，检查器重新扫描并报告剩余问题。

### 行内禁用的作用范围

行内 `moonlint-disable` 注释只能抑制**行级**问题。整个文件的属性（`bom`、`line_ending`、`max_file_size`、`no_empty_files`、`file_naming`、`max_lines`）无法通过注释屏蔽，因为它们描述的是文件而非某一行。按行执行的文件检查（`no_trailing_whitespace`、`no_tabs`、`max_line_length`）仍可抑制。

### 快速开始

```bash
# 创建初始配置
moonlint --init

# 检查 MoonBit 源码
moonlint --preset moonbit packages/

# 使用框架预设检查
moonlint --preset react /path/to/project

# 运行跨文件导入分析
moonlint --preset imports /path/to/project

# 自动修复并重新检查
moonlint --preset file --fix /path/to/project

# 在随附演示中一次查看所有层的效果
moonlint --config examples/demo/moonlint.json examples/demo/src
moonlint --preset moonbit examples/moonbit-demo/src
```

### 扫描模式

默认情况下，moonlint 递归遍历目录树。另外提供四种扫描模式：

```bash
# 仅扫描相对某个 Git 引用发生变化的文件（适合 CI）
moon run cmd/main -- --changed origin/main /path/to/project

# 仅扫描暂存文件（适合 pre-commit 钩子）
moon run cmd/main -- --staged /path/to/project

# 仅扫描匹配 glob 模式的文件
moon run cmd/main -- --glob "src/**/*.ts" /path/to/project

# 从 stdin 读取文件路径，每行一个
git diff --name-only | moon run cmd/main -- --stdin /path/to/project

```

`--watch` **尚未实现**；它会被拒绝，返回退出码 2 和 `unsupported` 消息，而不会接受后静默忽略。需要快速重复扫描时，请使用 `--incremental`（见下文）。

扫描模式互斥。所有模式共享相同选择契约：路径相对于根目录，经过去重、排序、扩展名过滤和作用域过滤。`--glob` 可重复指定，各个 glob 模式取并集。

- `--changed <ref>` 比较 `merge-base(ref, HEAD)` 与 `HEAD`，因此拉取请求相对于其真实基点衡量，并读取**已提交的 HEAD blob**，而非工作区，也并非仅读取变更行。
- `--staged` 读取**实际索引内容**，因此干净工作区无法掩盖有改动的暂存文件，反之亦然。
- Git 失败（非仓库、未知引用、未合并索引）会以退出码 2 结束，而不会产生看似无问题的空扫描。

### 包依赖策略

在所属模块中生成官方依赖图，然后传给 moonlint：

```bash
(cd examples/package-policy-demo && moon tree --package --json --target native > graph.native.json)
moonlint --package-graph examples/package-policy-demo/graph.native.json \
  --config examples/package-policy-demo/policy.json --format json
# 预期退出码为 1：无环的 domain -> ui 边违反团队规则。
```

[示例](<examples/package-policy-demo/README.zh-CN.md>) 在策略关卡前会先编译并测试。策略 v1 要求 `package_rules` 包含稳定 id、严重级别、`from`、`allow`/`deny` 中恰好一个、`kinds`（`source`、`test`、`wbtest`）、可选 `targets` 以及原因。空 `allow` 禁止所有适用的边；空 `deny` 无效。图 v3 的验证严格执行。关卡覆盖从选中根节点到所提供非标准库节点的直接边，不覆盖传递依赖或标准库边。适用项为零时会明确报告，不会将其当作已检查所有目标的证明。不会触发编译器构建/下载。

### 历史公共接口关卡

```bash
# 先使用预期编译器/后端生成各个接口。
moon info
moonlint --api-snapshot pkg.generated.mbti \
  --api-toolchain "moon 0.1.20261102; moonc v0.10.19+bee578715" \
  --api-backend native --api-module-version 0.3.0 > api.snapshot.json
moonlint --api-check before.snapshot.json after.snapshot.json --format sarif
# 显式启用有意不兼容的 0.x 次版本 / 稳定版主版本发布：
moonlint --api-check before.snapshot.json after.snapshot.json --api-version-policy semver
```

快照记录包、工具链、后端和模块版本。元数据由调用者提供，**不是编译器来源证明**：前后应使用实际相同的编译器/后端。上下文不同、数据格式错误和不支持的声明语法都会得出无法定论的结果（退出码 2）。即使版本变化，默认也会阻止移除和结构变化。显式启用 `semver` 后，只有版本增量足够时才会将审查问题降为警告；该策略明确不支持预发布/构建版本。

此功能比较受支持的历史公共声明/符号，而非仅比较接口文本或导出数量。它是保守的审查证据，不是 ABI、类型可赋值性或行为兼容性证明。函数体、文档、私有或隐藏导出不在快照范围内；成员新增也可能需要审查。见[可编译的变更前后示例](<examples/api-policy-demo/README.zh-CN.md>)。

包/API/审计报告使用 `mode`、`metadata`、`counts`、`findings` 和标识详情，不虚构 `scan` 计数或源码坐标。SARIF 结果不会为这些项目级问题设置 `locations`；GitHub 注解省略文件/行属性。`--report` 写入相同的项目 JSON 模式。

### 基线 v2 与例外审计

基线从不隐式发现。写入操作登记技术债务，并返回写入模式的退出码 0；它**不是 lint/CI 成功结论**。

```bash
moonlint --preset moonbit --update-baseline --baseline-format v2 \
  --baseline debt.json --baseline-reason "existing review debt" \
  --baseline-owner "package-maintainer" --baseline-expires 2026-12-31 .
moonlint --preset moonbit --baseline debt.json .
moonlint --preset moonbit --baseline debt.json --changed origin/main .
# 全树审计，必要时覆盖 UTC 日期以便复现：
moonlint --preset moonbit --audit-baseline --baseline debt.json \
  --baseline-today 2026-11-04 --format json .
# 仅转换仍匹配的旧豁免，不转换新引入的错误：
moonlint --preset moonbit --migrate-baseline --baseline legacy.json \
  --baseline-reason "reviewed legacy debt" --baseline-owner "package-maintainer" .
```

V2 指纹省略行/列，保留规则/文件/严重级别/消息和去掉末尾空白的代码片段，保留内部/字面量空白。每项包含正数的出现次数额度、非空原因/负责人，以及可为 null 的到期时间。到期当天仍有效；此前已过期的项不会抑制问题。默认日期为主机 UTC 日期。审计错误会指出已过期、未使用和部分未使用额度；`unused_occurrences` 汇总未使用配额。普通 lint 会警告审计问题，但不会悄然将正常抑制变成审计关卡。

这是**非密码学的内容标识 MVP**，不是祖先关系或语义标识。存储次数范围内的相同替换无法区分；重命名、消息/严重级别或片段变化都会失去豁免。全树审计不得通过 `--changed`、`--staged`、`--glob`、stdin 或 `--ext` 缩小范围。迁移后仍存在未抑制错误时返回 1；它绝不会批准新增债务。更新/迁移/审计不能与修复/项目模式组合。旧数组仍作为显式、对行号敏感的输入；覆盖 v2 基线需要显式 v2 写入和元数据，不会悄然降级。

#### 前端限制

MoonBit 源码检查共享代码/声明/注释/字面量视图。文档必须非空；看似注释的原始文本和空分隔符不是文档。字面量之后以及受支持的单行插值内的调用可见；定义和测试体不会误作普通调用。这些属于语法层面的名称策略，而非绑定解析（局部裸名称 `panic` 仍可能匹配名称策略）。带限定的用户 `Foo::panic`/`println` 不会被假定为内置调用。未知公共声明形式和未完成的词法输入无法定论。目前不支持跨物理行插值，会拒绝处理，而不会计为成功解析的源码。

JS/TS 前端是分词器和结构解析器，并非 Vue SFC 编译器。对于 `.vue` 文件，它从脚本中读取导入/导出，并将模板绑定表达式（`:prop`、`v-*`、`@event`）提取为标识符读取，因此仅在模板中使用的绑定也计为使用。它不求值模板控制流，不解析组件注册，也不跟踪别名，除非在 `aliases` 中声明。

Git 模式为选中/上下文源码捕获不可变的 blob-id 映射；替换引用被禁用。选择发生在捕获之前，因此**选择期间**的并发变更不构成原子仓库快照。选择文件时应避免并发 Git 编辑。目录树/glob/stdin 上下文同样是实时目录树读取，并非文件系统事务。上下文计数/失败会披露这些额外读取。

#### 增量缓存

`--incremental` 保存按内容哈希组织的逐文件结果缓存，因此重复扫描只会重新检查源码发生变化的文件：

```bash
# 首次运行填充 .moonlint-cache.json；后续运行复用未变化文件
moon run cmd/main -- --incremental /path/to/project

# 自定义缓存位置
moon run cmd/main -- --incremental --cache-file /tmp/moonlint.cache.json /path/to/project
```

使缓存安全的属性如下：

| 行为 | 详情 |
|-----------|--------|
| 以内容为键 | 每项以严格解码源码的非密码学哈希为键（保留 BOM/Unicode）；任何编辑，即使仅空白变化，也会重新检查该文件 |
| 理解配置 | 缓存保存生效规则、文件规则、结构规则和作用域的指纹；任何变化都会使全部条目失效 |
| 自愈 | 缓存缺失、为空或不可读时启动完整扫描；非空缓存若解析或版本验证失败，还会发出警告 |
| 结构检查安全 | 使用缓存仍会收集跨文件检查所需的项目源码，并在相同规则下刷新完整依赖上下文；上下文失败会阻止给出结论 |
| 显式启用 | 不指定 `--incremental` 就不读写缓存文件 |

缓存还保存每个文件的**已解析结构模型**（导入、导出和已使用名称集合），以相同内容哈希为键。在目录树变化时，跨文件规则的问题结果仍绝不会来自缓存：编辑一个无关文件可能使无用导出变为有用；但未变化文件可跳过昂贵的分词/解析步骤，这正是 `--incremental` 对 `--preset imports` 扫描有价值的原因。模型独立于规则，因此配置变化后仍可保留，并携带解析器代次：提升解析器代次会丢弃陈旧模型，同时保留逐文件问题结果。

此外，全树扫描会记录**结构检查结论本身**，以规则指纹加上每个参与文件的内容哈希为键。当未变化的目录树在相同规则下再次扫描时，会跳过整个跨文件阶段，不读取上下文，也不分析。由于该键覆盖所有参与文件，任何编辑、新增或删除都会改变它并强制重新计算。部分扫描（`--glob`、`--stdin`、`--changed`、`--staged`）和通过作用域排除文件的扫描绝不会如此复用，因为它们未选中的依赖上下文不属于键的一部分。

| 行为 | 详情 |
|-----------|--------|
| 以内容为键的模型 | 仅存储哈希与被扫描源码一致时才复用模型 |
| 独立于规则 | 规则变化后复用模型；只重新推导跨文件问题 |
| 解析器代次 | 旧解析器（`model_version`）写入的模型会被丢弃，因此前端修复不会被陈旧解析结果掩盖 |
| 有界 | 只有当前选择集合中的文件保留条目；已删除文件不会留下模型 |
| 结论标识 | 缓存的结构结论以规则指纹加每个参与文件的摘要为键，因此任何编辑都会使其失效 |
| 不存储片段 | 缓存的结构问题省略代码片段（压缩后的一行可能比缓存还大）；片段从扫描源码重新推导，因此报告保持逐字节一致 |

#### Glob 语法

| 模式 | 匹配内容 |
|---------|---------|
| `*` | 除 `/` 外的任意字符 |
| `**` | 包括 `/` 在内的任意字符 |
| `?` | 除 `/` 外的任意单个字符 |
| 字面文本 | 精确匹配 |

匹配目录的模式同时覆盖其下所有内容，因此作用域模式 `vendor` 会排除 `vendor/pkg/index.ts`，但不影响 `vendorless/index.ts`。

### 配置

规则定义在 JSON 文件中（默认 `moonlint.json`）：

```json
{
  "rules": [
    {
      "id": "vue/import-from-vue",
      "severity": "error",
      "message": "Must import from 'vue-lynx', not 'vue'",
      "extensions": [".vue", ".ts"],
      "match_literals": true,
      "match": { "regex": "from[[:space:]]+['\"]vue['\"]" },
      "unless": { "regex": "from[[:space:]]+['\"]vue-lynx['\"]" }
    }
  ]
}
```

#### 规则字段

| 字段 | 类型 | 说明 |
|-------|------|-------------|
| `id` | string | 稳定标识符，例如 `vue/import-from-vue` |
| `severity` | string | `"error"` 或 `"warning"`（默认 `"warning"`） |
| `message` | string | 人类可读的说明 |
| `extensions` | string[] | 要检查的文件扩展名（空数组 = 所有文件） |
| `match` | object | 主匹配器（见下文） |
| `unless` | object | 可选否定保护条件 |
| `match_comments` | bool | 匹配原始视图（包含注释）。默认 `false` |
| `match_literals` | bool | 匹配字面量视图（保留字符串/模板/正则内容）。默认 `false`；设置 `match_comments` 时忽略 |
| `include` | string[] | 可选，规则适用的路径 |
| `exclude` | string[] | 可选，规则绝不适用的路径 |

#### 作用域

相同的 `include` / `exclude` 键可出现在配置顶层（全局作用域）和各条规则内部（规则作用域）。二者均接受相对于根目录、使用上述语法的 glob 模式；允许前导 `./`。

```json
{
  "include": ["src/**", "app/**"],
  "exclude": ["**/*.generated.ts", "src/vendor"],
  "rules": [
    {
      "id": "vue/import-from-vue",
      "include": ["src/components/**"],
      "exclude": ["**/*.test.ts"],
      "message": "…",
      "match": { "regex": "…" }
    }
  ]
}
```

- 空 `include` 列表表示“不限制”；任何 `exclude` 匹配均优先于 `include`。
- 先应用**全局**作用域：被拒绝的文件计入 `files_out_of_scope`，不会收到问题报告。它们仍可作为跨文件检查的依赖上下文读取。
- **规则**作用域只决定哪些规则看到已选中的文件，不能扩大全局扫描集合。选中但没有适用规则的文件计入 `files_skipped`，原因为 `no-applicable-rule`。
- 无效或不支持的模式（花括号、字符类、绝对路径、`..`）属于配置错误，返回退出码 2，而不会静默缩小扫描范围。

请从仓库根目录运行 `moonlint`，确保报告路径（和 GitHub 注解）正确解析。

#### 匹配器类型说明

叶子匹配器及 `all` / `any` / `not` 组合器见上文[匹配器类型](#匹配器类型)。`match` 和 `unless` 都接受其中任一种。

> **注意：** MoonBit 正则引擎支持 POSIX 字符类（`[[:space:]]`、`[[:digit:]]`、`[[:alpha:]]`），但不支持 Perl 风格转义（`\d`、`\w`、`\s`）。

### 输出

#### `--format text`（默认）

每个问题输出一个块；未选中任何内容时还会输出提示：

```
src/app.ts:12: [error] vue/import-from-vue — Must import from 'vue-lynx', not 'vue'
    import { createApp } from 'vue'
```

`--summary` 则输出按规则汇总的计数和扫描计数。

#### `--format json`

带版本的文档（`"version": 1`）：

```json
{
  "tool": "moonlint",
  "version": 1,
  "scan": {
    "mode": "tree",
    "root": "/repo",
    "extensions": [".ts", ".vue"],
    "files_selected": 12,
    "files_scanned": 10,
    "files_skipped": 1,
    "files_failed": 1,
    "files_out_of_scope": 3,
    "context_files_scanned": 2,
    "context_files_failed": 0,
    "source_snapshot": "working-tree",
    "baseline_suppressed": 0,
    "skipped_files": [{ "file": "docs/notes.md", "reason": "no-applicable-rule" }]
  },
  "counts": { "findings": 1, "errors": 1, "warnings": 0 },
  "findings": [
    {
      "rule_id": "vue/import-from-vue",
      "severity": "error",
      "message": "Must import from 'vue-lynx', not 'vue'",
      "file": "src/app.ts",
      "line": 12,
      "column": 22,
      "snippet": "import { createApp } from 'vue'"
    }
  ],
  "diagnostics": [{ "file": "src/broken.ts", "message": "source is not valid UTF-8" }]
}
```

`line` 和 `column` 从 1 开始，按字符而非字节计数，因此多字节文本之后的问题仍能指向正确位置。`column` 表示匹配内容的首字符：对于 `contains`、`prefix` 和 `whole-word` 规则，为模式文本出现的位置；对于 `suffix` 规则，为末尾文本的起点；对于 `regex` 规则，为第一个非空白字符（无法仅从模式恢复匹配偏移量）。SARIF `startColumn` 使用相同值，并设置 `columnKind: unicodeCodePoints`。

`files_selected` 在路径规范化、扩展名过滤和去重之后计数。每个选中文件要么已扫描，要么已跳过（`skipped_files` 中有原因），要么失败（附诊断）。`--errors-only` 过滤问题及其计数，但绝不影响扫描元数据。

`--report <file>` 除 stdout 输出之外，还会以原子方式将相同 JSON 文档写入文件；扫描失败时同样写入。

#### `--format github`

输出 GitHub Actions 工作流命令：

```
::error file=src/app.ts,line=12,col=22,title=vue/import-from-vue::Must import from 'vue-lynx', not 'vue'
::error file=src/broken.ts,title=moonlint/scan-failed::source is not valid UTF-8
::notice file=docs/notes.md,title=moonlint/skipped::no-applicable-rule
::notice title=moonlint::files selected: 12, scanned: 10, skipped: 1, failed: 1, …
```

属性值和消息按 GitHub 要求转义，因此规则消息中的换行符绝不会伪造额外命令。

#### `--format sarif`

输出 SARIF 2.1.0 文档（`$schema`、`runs[].tool.driver.rules`，以及包含 `ruleId`、`level` 和 `physicalLocation` 的 `results[]`），适用于 GitHub 代码扫描、VS Code 和大多数 CI 静态分析集成。

### 退出码

- `0` — 没有 error 级别问题。
- `1` — 发现 error 级别问题。
- `2` — 参数、配置、Git 或 I/O 错误（包括无法读取文件、无法解析引用、未合并索引、循环或不可读的 `extends` 链，以及 `--fix` 与 `--changed`/`--staged` 组合使用）。

## 架构

```
repo root/
├── cmd/impact/       — MoonImpact CLI 入口
├── cmd/main/         — moonlint CLI 入口
├── impact_types.mbt  — 计划/配置/边/问题/追踪类型
├── impact_config.mbt — 严格、无执行行为的 MoonImpact JSON 配置
├── impact_moonbit.mbt — MoonBit 前端：模块发现、moon.pkg 导入
│                       解析（`import`、`test-import`、`#cfg` 块）、
│                       归属关系、包依赖图、策略
├── impact_dependencies.mbt — JS/TS/Vue 引用提取：导入、文件
│                       读取、目录读取、存在性检查、glob 导入
├── impact_styles.mbt — CSS/SCSS 引用扫描器（导入、Sass 模块、URL）
├── impact_style_resolution.mbt — 样式表候选解析、加载路径
├── impact_plan.mbt   — 计划构建：成员集合、引用解析、
│                       反向 BFS、策略、声明契约
├── impact_report.mbt — 文本/JSON/无脚本 HTML 计划渲染
├── impact_native.mbt — Git 输入、运行器执行和报告的原生桥接
├── impact_native.c   — 进程组执行、仅创建文件的原子报告写入
├── git.mbt           — 原生文件系统/Git 桥接（固定 argv、不使用 shell）
├── git_native.c      — lstat、Git（merge-base/changed/staged/blob）、原子写入
├── scanner.mbt       — 文件遍历、分行、源码读取
├── scope.mbt         — include/exclude glob 作用域
├── scan.mbt          — 扫描模式、glob 匹配、文件选择
├── types.mbt         — Severity、MatchKind（叶子 + all/any/not）、Rule、
│                       Finding、FileRule、StructuralRule、LintResult、ScanInfo
├── matcher.mbt       — MatchKind 求值；`prepare()` 为每个规则的每个正则
│                       只编译一次，而非逐行编译，并按深度优先顺序
│                       预编译嵌套组合器
├── comment.mbt       — 注释清空：JS/TS 模式（模板字面量、
│                       插值、字符串、正则）和普通模式
├── lex.mbt           — JS/TS 分词器：字符串、带 ${} 的模板字面量
│                       插值、正则字面量、注释、标识符
├── parse.mbt         — 结构化解析器：import/export 语句、绑定、
│                       使用位置、相对说明符
├── analysis.mbt      — 跨文件引擎：项目索引、导入解析、
│                       导入图及 8 项结构检查
├── moonbit_lang.mbt  — MoonBit 声明扫描器：注释/字符串清空、
│                       顶层条目、///| 关联、公共文档和命名
├── engine.mbt        — 规则应用、作用域过滤、扫描计数、
│                       结构处理阶段和增量缓存衔接
├── cache.mbt         — 增量缓存：内容哈希、配置指纹、
│                       JSON 渲染/解析（严格；损坏输入回退为
│                       完整扫描）
├── config.mbt        — JSON 配置解析、验证及 extends 继承
├── presets.mbt       — 内置预设（common、react、vue、angular、svelte、
│                       next、solid、astro、nuxt、file、imports、moonbit）
├── presets/          — 各预设的独立 JSON 副本，供自定义使用
├── disable.mbt       — 行内禁用注释解析（// moonlint-disable）
├── baseline.mbt      — 基于哈希的问题豁免
├── report.mbt        — 详情和摘要渲染
├── report_json.mbt   — JSON 报告
├── report_github.mbt — GitHub Actions 注解
├── report_sarif.mbt  — SARIF 2.1.0 报告
├── tests/            — 无额外依赖的 CLI 集成测试
└── examples/         — TS 和 MoonBit 演示，附人工核验报告
```

两个入口共享文件系统、Git、遍历和报告层，但规划内容不同。MoonImpact 的 MoonBit 前端将 `moon.pkg` 清单读成包依赖图，并据此规划；其 JS/TS 前端为分词器 → 解析器 → 项目索引/导入图。moonlint 的前端是 MoonBit 声明扫描器和 JS/TS 分词器/导入图，为规则引擎、缓存和基线层提供输入。

除 `git_native.c` 中的原生文件系统/Git 桥接和 `impact_native.c` 中的进程边界外，实现均为纯 MoonBit；每一层均有独立单元测试。

## 开发与验证

可执行程序需要 **macOS/Linux 上的 native 后端**，以执行文件系统、Git 和 UTC 日期操作。构建需要 MoonBit 和 C 工具链；运行构建好的程序不需要 Node.js 或 Rust 工具链。

```bash
moon check --target native
moon test --target native
moon build --target native
python3 tests/integration.py \
  --binary "$PWD/_build/native/debug/build/cmd/main/main.exe" --phase all
python3 tests/impact_integration.py \
  --binary "$PWD/_build/native/debug/build/cmd/impact/impact.exe"
python3 tests/impact_native.py
moon info && moon fmt
# 审查生成的接口/源码差异，然后重新运行受影响的关卡。
```

[CI](<.github/workflows/ci.yml>) 执行显式的 native 关卡并编译示例。其安装器获取最新版，**并未固定工具链**；会记录版本并检查接口/格式漂移。提交 `e318b9e` 中记录的一次历史 CI 失败报告称，作业因账户计费锁定而无法启动。该记录不能证明当前远程 CI 状态。以上命令涵盖核心本地关卡；CI 还会执行稳定性审计并构建/测试示例模块，具体见工作流。

[moonlint 验证说明](<docs/verification.md>) 描述的是 2026-11-04 的运行及其限制，并非当前测试结果。后续 MoonImpact 测量见[第三轮](<docs/moonimpact-round3-verification.zh-CN.md>)、[第四轮](<docs/moonimpact-round4-verification.zh-CN.md>)和[第五轮](<docs/moonimpact-round5-verification.zh-CN.md>)。此前两个 JS/TS 字面量文本预期失败现已成为普通回归测试：默认代码视图会清空字面量内容。本文不声称历史 wasm 失败已修复。

`moonlint .` 使用[仓库配置](<moonlint.json>)，该配置有意排除负面示例。没有为隐藏缺失的公共文档而新增一揽子基线。

## 许可证

Apache-2.0；见 [LICENSE](<LICENSE>) 和[第三方归属声明](<THIRD_PARTY_NOTICES.zh-CN.md>)。
