# moonlint 演示

[English](<README.md>) | [简体中文](<README.zh-CN.md>)

这是一个小型 TypeScript 项目，在行级、文件级和结构级规则层中，以七种可预期的方式违反 [`demo/moonlint.json`](<demo/moonlint.json>) 中的规则。

## 运行方式

在仓库根目录执行：

```sh
moon build --target native
BIN="$PWD/_build/native/debug/build/cmd/main/main.exe"
"$BIN" --config examples/demo/moonlint.json examples/demo/src
```

下文命令会复用当前 shell 中的 `BIN`。

## 预期输出

```text
app.ts:1: [warning] demo/no-unused-imports — Imported binding is never used ('unusedHelper' is imported but never used)
    import { formatDate, unusedHelper } from "./helpers";
app.ts:2: [error] demo/no-unresolved-relative-imports — Relative import cannot be resolved to a scanned file (cannot resolve './missing')
    import { broken } from "./missing";
app.ts:4: [warning] demo/no-unused-exports — Exported name is never imported by another file (exported 'renderDate' is never imported by another file)
    export function renderDate(date: Date): string {
app.ts:6: [warning] demo/max-line-length — Line is too long (line has 76 characters (limit: 60))
    // this comment line is deliberately much longer than the configured limit
app.ts:9: [warning] demo/no-console-log — Avoid console.log in committed code
    console.log(formatted, tag);
helpers.ts:2: [warning] demo/no-todo-comment — TODO/FIXME comment left in code
    // TODO: honour the caller's locale
helpers.ts:10: [warning] demo/no-unused-exports — Exported name is never imported by another file (exported 'alsoUnused' is never imported by another file)
    export const alsoUnused = 42;
```

检查结果先按文件排序，再按行号和规则 ID 排序。由于其中一条结果属于错误，本次运行的退出码为 1。

## 各条检查结果展示的行为

| 检查结果 | 规则层 | 触发原因 |
| --- | --- | --- |
| `demo/no-unused-imports` | 结构级 | 第 1 行导入了 `unusedHelper`，但之后没有再引用它；这是通过遍历词法单元流的使用情况分析得出的 |
| `demo/no-unresolved-relative-imports` | 结构级 | 即使尝试了扩展名和 `index.*`，`./missing` 仍无法解析到任何已扫描文件 |
| `demo/no-unused-exports`（app.ts） | 结构级 | 没有文件导入 `app.ts`，因此 `renderDate` 是未使用的导出；参见下文的注意事项 |
| `demo/max-line-length` | 文件级 | 第 6 行有 76 个字符，超过了 60 个字符的限制 |
| `demo/no-console-log` | 行级 | 在去除注释的视图上进行普通子串匹配 |
| `demo/no-todo-comment` | 行级 | `"match_comments": true` 使此规则使用原始视图，因此能看到第 2 行的 `// TODO` |
| `demo/no-unused-exports`（helpers.ts） | 结构级 | `alsoUnused` 已导出，但没有任何已扫描文件导入它 |

另外两个特意设计的未触发案例证明了保护条件确实有效：

- `app.ts:5` 上的 `// TODO … moonlint-ok` 注释**不会**出现在结果中：规则的 `unless` 匹配器（`{"all": [{"contains": "moonlint-ok"}]}`）会抑制这条结果。
- `broken` 在导入后被引用了（`const tag = broken`），因此不会触发未使用导入检查，只会触发解析检查。

## 入口文件的注意事项

`renderDate` 被标记为未使用的导出，是因为演示目录就是完整的分析范围：没有任何文件导入 `app.ts`。在实际项目中，应让 moonlint 扫描相关源文件及其使用方（通过顶层 `include` 列表指定），或者使用 `--update-baseline` 将这条结果记录到基线中。

仓库自身的 `moonlint.json` 将 `examples/demo` 排除在检查范围之外，因此 moonlint 检查自身时，不会报告这些故意设置的违规。

## 增量缓存层

对同一次扫描使用 `--incremental` 即可体验缓存复用（请选择扫描目录树之外的可写缓存路径）：

```sh
"$BIN" --config examples/demo/moonlint.json \
  --incremental --cache-file /tmp/moonlint-demo-cache.json \
  examples/demo/src
```

报告完全相同：仍是全部七条结果，顺序和退出码也相同。缓存会写入 `/tmp/moonlint-demo-cache.json`，其中包含：

- 每个文件对应一个条目，以源文件内容的哈希值和实际生效规则集的指纹作为键。规则集包括匹配器、`unless` 保护条件、作用范围和结构规则。
- `app.ts` 提供 2 条结果（来自行级和文件级规则）；`helpers.ts` 提供 1 条结果（TODO 注释）。
- 四条结构级结果不存储在这些逐文件结果列表中。解析后的结构模型和项目级判定会单独缓存。项目输入未变化时会复用该判定；一次编辑可能使其失效，因为一个文件可能改变另一个文件的分析结果。

再次运行时，未变化文件的逐文件匹配器会被跳过。即使重新写入文件，只要字节内容相同，其缓存结果仍然有效：条目以内容哈希值为键，而不是以修改时间为键。编辑文件后，其逐文件结果会重新计算，结构分析也可能需要重新运行。更改实际生效的规则集会使缓存指纹失效。

## MoonBit 演示

MoonBit 源码前端在 [`moonbit-demo/`](<moonbit-demo/README.zh-CN.md>) 下有独立示例，会产生六条检查结果。它涵盖声明扫描器（公共文档和命名）、语法层面的 unwrap 检查，以及 TODO 注释检查。其输出由 `moonbit` 集成测试阶段固定验证：

```sh
"$BIN" --preset moonbit examples/moonbit-demo/src
```
