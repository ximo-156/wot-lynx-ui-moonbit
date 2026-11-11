# MoonImpact / moonlint

## MoonImpact — change-impact and regression-test planning (MVP)

The new `cmd/impact` entry turns changed files into an **explainable test plan**
for Vue/TypeScript projects: static module dependencies, bounded file-read
and reader-wrapper inference, CSS/SCSS input chains, shortest evidence chains,
and conservative full-suite fallback.
It does not check naming or formatting, and a plan is not a passing test result.

```sh
moon build --target native
moon run cmd/impact -- plan --file src/fees.ts \
  --config examples/impact-demo/moonimpact.json examples/impact-demo
moon run cmd/impact -- plan --file src/theme.css \
  --config examples/impact-demo/moonimpact.json examples/impact-demo
```

Planning does not run tests or install dependencies. Only explicit `--run`
invokes the local Vitest installation through fixed process arguments.
Read the [MoonImpact guide](<docs/moonimpact.md>) and the
[synthetic demo](<examples/impact-demo/README.md>) for supported dependency
forms, limitations, Git input, JSON/HTML reports and execution safety.
See the [local verification record](<docs/moonimpact-verification.md>) for
real Vitest fault-injection evidence and the current full-fallback result on
unibest; selective whole-project CI reduction is not claimed.

This is substantial new functionality built on the existing project. The
original `cmd/main` moonlint CLI, module identity, license notices and history
remain intact; the new direction is not a rename of the old lint rules.

## Original moonlint CLI

A MoonBit-native convention linter for MoonBit source trees, written in
[MoonBit](https://www.moonbitlang.com/). It also ships JavaScript/TypeScript
presets for mixed repositories, but MoonBit is the primary target.

## Why this exists

`moon check` checks compilation and includes the optional W74 `missing_doc`
warning (disabled by default); `moon fmt` formats code. moonlint does not
replace either. It puts project conventions, exception budgets, package-layer
constraints and historical public-interface review into explicit CI checks.
ESLint and Biome's supplied JS/TS parsers do not parse MoonBit; their JS/TS
checks remain useful in mixed repositories.

The source frontend is a lexical/declaration scanner, not a complete AST or
binding/type resolver. A clean lint result is not proof that source compiles.
Always run `moon check` separately.

## Origin

moonlint began as a MoonBit rewrite of the review-lint script in
[`ximo-156/wot-lynx-ui`](https://github.com/ximo-156/wot-lynx-ui), a Vue Lynx
component library. The referenced script is `scripts/review-lint.mjs`; its
MIT notice names **2026 wot-lynx-ui contributors**. The rule catalogue informed
the compatibility presets. This is a reference/porting relationship, not an
independently proven absence of copied code. This repository declares
Apache-2.0 in [LICENSE](<LICENSE>); see [third-party attribution](<THIRD_PARTY_NOTICES.md>).

The local manifest now targets **0.3.0** because public result fields and
structural-check variants changed. The tested result is the current working tree, not a published release. During
this work HEAD / the local origin/main tracking ref moved to intermediate commit
4bebde5; subsequent fixes remain uncommitted. This session issued no project
commit, push or release command.

## What it does

`moonlint` scans a directory tree, applies declarative rules to each source
file, and reports violations. Rules are loaded from JSON, so the same engine
can enforce any project's conventions. MoonBit files are read by a declaration
scanner that associates non-empty `///` documentation with top-level items;
`///|` alone is only a block separator. JS/TS files are read by
the tokenizer and import-graph layers.

## Features

- **MoonBit first** — the `moonbit` preset covers public documentation, naming,
  `unwrap()` / `panic()`, `println()` and TODO comments; test files are
  excluded recursively and CLI entry points are excluded from the print rule
- **Config-driven** — rules defined in JSON, no code changes needed
- **JS/TS compatibility presets** — ready-to-use rule sets for React, Vue,
  Angular, Svelte, Next.js, SolidJS, Astro, Nuxt, common JS/TS hygiene,
  file-level checks and cross-file import checks; activate with
  `--preset <name>`
- **Regex + substring matching** — `contains`, `prefix`, `suffix`, `regex`, `equals` and `word` matchers
- **Matcher combinators** — `all` / `any` / `not` nest within bounded parser limits, so `match` expresses any boolean formula over the leaf matchers
- **Negative guards** — `unless` field to suppress false positives (e.g. "import from 'vue' but not 'vue-lynx'")
- **Comment-aware** — `//` and `/* */` comments are blanked out before matching, preserving line numbers and columns; in JS/TS/JSX files the scanner understands template literals, `${}` interpolations, strings and regex literals, so a `//` inside a template string is text, not a comment. The default code view also blanks literal *contents*, so `const q = "FORBIDDEN"` is not code; rules whose target only exists as a literal value opt in with `"match_literals": true`, and rules that *target* comments opt in with `"match_comments": true`
- **Cross-file structural rules** — a JS/TS tokenizer + parser builds a project-wide import graph, powering unused imports, duplicate imports, unresolved relative imports, import cycles, deep relative imports, `require()` usage, `export default` and dead exports (`--preset imports`)
- **Baseline v2** — explicit, count-limited content exemptions with reason, owner, expiry and full-tree unused-budget audits; legacy arrays remain readable
- **Package policies** — direct dependency constraints over supplied compiler v3 package graphs, with separate source/test/wbtest kinds and backend selection
- **API review gate** — historical `.mbti` declaration snapshots identify removals and conservative shape changes; optional semver policy records intentional breaking releases
- **Incremental caching** — `--incremental` re-lints only files whose content hash changed, invalidated automatically when the effective config changes
- **Severity levels** — `error` and `warning`, with exit code 1 on any error-severity finding
- **Scoped findings** — global and per-rule `include`/`exclude` control reports; unselected/excluded dependency files may still be read as explicitly counted project context
- **CI output** — machine-readable JSON reports, GitHub Actions annotations and SARIF 2.1.0, with read / failure / skip metadata
- **Honest counters** — every selected file is reported as scanned, skipped (with a reason) or failed; a scan never silently degrades to "clean"
- **Summary mode** — per-rule tally plus read/skip/failure counts

## Installation

```bash
# Clone and build
git clone https://github.com/ximo-156/wot-lynx-ui-moonbit
cd wot-lynx-ui-moonbit
moon build --target native
```

## Usage

```bash
# Create a MoonBit starter config in the current directory
moon run cmd/main -- --init

# Lint a MoonBit package with the built-in preset
moon run cmd/main -- --preset moonbit packages/

# Lint with the generated config
moon run cmd/main -- .

# Lint a specific directory
moon run cmd/main -- /path/to/project

# Use a custom config
moon run cmd/main -- --config my-rules.json /path/to/project

# Summary mode
moon run cmd/main -- --summary /path/to/project

# Only show errors
moon run cmd/main -- --errors-only /path/to/project

# Generate a baseline (exempts all current findings)
moon run cmd/main -- --update-baseline /path/to/project

# Use a baseline
moon run cmd/main -- --baseline moonlint.baseline.json /path/to/project

# Machine-readable JSON report on stdout, and written to a file
moon run cmd/main -- --format json /path/to/project
moon run cmd/main -- --report moonlint-report.json /path/to/project

# GitHub Actions annotations
moon run cmd/main -- --format github /path/to/project

# Cross-file import checks for a JS/TS compatibility scan
moon run cmd/main -- --preset imports /path/to/project

# Fast repeated scans: only changed files are re-linted
moon run cmd/main -- --incremental /path/to/project
```

## Built-in Presets

The primary preset is `moonbit`. The JS/TS presets are compatibility sets for
repositories that also contain frontend code. Activate one or more with
`--preset <name>` (repeatable); rules from multiple presets are merged with
de-duplication by rule id.

```bash
# List available presets
moon run cmd/main -- --list-presets

# Lint MoonBit sources
moon run cmd/main -- --preset moonbit packages/

# Lint a React project
moon run cmd/main -- --preset react /path/to/project

# Lint a Vue project
moon run cmd/main -- --preset vue /path/to/project

# Combine presets (e.g. React + common hygiene)
moon run cmd/main -- --preset react --preset common /path/to/project
```

`--preset` and `--config` are mutually exclusive. An unknown preset name is a
usage error (exit code 2).

### Available presets

| Preset | Extensions | Rules | Focus |
|--------|-----------|-------|-------|
| `moonbit` | `.mbt` | 6 structural rules | MoonBit: require-public-doc, naming, no-unwrap, no-panic, no-println, no-todo-comment |
| `common` | `.js` `.jsx` `.ts` `.tsx` `.mjs` `.cjs` `.vue` `.svelte` `.astro` | 6 | Framework-agnostic hygiene: no-console-log, no-debugger, no-alert, no-eval, no-var, no-todo-comment |
| `react` | `.jsx` `.tsx` | 20 | React/JSX: no-danger, no-string-refs, jsx-key, self-closing, target-blank, button-type, ... |
| `vue` | `.vue` `.js` `.ts` | 11 | Vue 3: no-v-html, require-v-for-key, no-v-if-with-v-for, require-scoped-style, ... |
| `angular` | `.ts` | 9 | Angular: no-input-rename, no-output-native, no-forward-ref, relative-url-prefix, ... |
| `svelte` | `.svelte` | 8 | Svelte: no-at-html, require-each-key, a11y-missing-attribute, no-goto-without-base, ... |
| `next` | `.jsx` `.tsx` `.js` `.ts` | 7 | Next.js: no-img-element, no-head-element, no-html-link-for-pages, google-font-display, ... |
| `solid` | `.jsx` `.tsx` | 6 | SolidJS: no-innerhtml, prefer-for, no-react-imports, event-directives, ... |
| `astro` | `.astro` | 5 | Astro: no-set-html-directive, prefer-class-list, no-unused-define-vars, ... |
| `nuxt` | `.vue` `.js` `.ts` | 5 | Nuxt: no-env-in-runtime, prefer-use-fetch, no-window-in-ssr, ... |
| `file` | `.js` `.jsx` `.ts` `.tsx` `.mjs` `.cjs` `.vue` `.svelte` `.astro` | 6 file rules | File-level: max-lines, max-line-length, no-trailing-whitespace, no-tabs, final-newline, no-duplicate-lines |
| `imports` | `.js` `.jsx` `.ts` `.tsx` `.mjs` `.cjs` `.mts` `.cts` `.vue` `.svelte` `.astro` | 7 structural rules | Cross-file: no-unused-imports, no-duplicate-imports, no-unresolved-relative-imports, no-import-cycles, no-deep-relative-imports, no-require-imports, no-unused-exports |

The `moonbit` preset checks top-level public items only. `*_test.mbt` and
`*_wbtest.mbt` are excluded recursively; `cmd/**` is excluded from the
`no-println` rule because CLI entry points print by design.

Every preset is also shipped as a standalone JSON file under `presets/`
(`angular`, `astro`, `common`, `file`, `imports`, `moonbit`, `next`, `nuxt`,
`react`, `solid`, `svelte`, `vue`) for users who prefer to copy and customize
them:

```bash
moon run cmd/main -- --config presets/react.json /path/to/project
```

> **Note:** The framework presets are line-oriented — they match one source line
> at a time, after comments have been blanked out. Rules that need an AST
> (unused variables, hook dependencies, prop types) are intentionally absent
> from those presets; the `imports` preset instead uses best-effort cross-file import
> analysis (see [Cross-File Structural Rules](#cross-file-structural-rules)).
> The `moonbit` preset goes through a declaration scanner instead of the JS/TS
> parser; it reads non-empty documentation and top-level items, and it skips
> `*_test.mbt` / `*_wbtest.mbt` because tests may unwrap, panic and print.

## Matcher Types

A matcher object has exactly one of:

- `{ "contains": "substring" }` — line contains the substring
- `{ "prefix": "text" }` — line starts with the text
- `{ "suffix": "text" }` — line ends with the text
- `{ "regex": "pattern" }` — line matches the regex
- `{ "equals": "text" }` — trimmed line equals the text exactly
- `{ "word": "text" }` — line contains the text as a whole word

### Matcher combinators

Any matcher — including `unless` — may instead be a boolean combination of
matchers, nested within bounded parser limits:

- `{ "all": [ … ] }` — every sub-matcher must match (an empty list matches every line)
- `{ "any": [ … ] }` — at least one sub-matcher must match (an empty list matches no line)
- `{ "not": { … } }` — the sub-matcher must not match

```json
{
  "id": "common/no-unguarded-console",
  "severity": "warning",
  "message": "console.log without a lint exemption",
  "extensions": [".ts"],
  "match": {
    "all": [
      { "contains": "console.log" },
      { "not": { "any": [ { "word": "allow" }, { "contains": "moonlint-ok" } ] } }
    ]
  }
}
```

This fires on `console.log(x)` but not on `console.log(x) // moonlint-ok`.
A bad regex nested inside a combinator is a config error (exit 2), reported
with the path to the offending sub-matcher.

### Matching inside comments

Line rules normally see the comment-stripped view of a file: comments are
blanked to spaces before matching, so a stringified script or a URL fragment
never looks like code. A rule that targets comments themselves — a no-TODO
rule, say — opts into the raw view instead:

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

`match_comments` is per-rule and defaults to `false`. The opt-in sees the file
exactly as written — line and block comments included, but strings and
template literals too, since those are also "raw". The `unless` guard and
inline `// moonlint-disable` comments apply as usual.

### Matching inside literals

The default view — the *code view* — blanks the contents of string, template
and regex literals in JavaScript/TypeScript/JSX sources, so
`const q = "FORBIDDEN"` is not code and no rule matches it. This aligns the
JS/TS line matcher with the MoonBit front end, which has always blanked
literal contents. Deliberately preserved: the delimiters (`"`, `'`, `` ` ``,
`/`), so attribute-shaped matches such as `ref="` still work, and `${...}`
interpolations, because an interpolation is an expression, not a value.
Line and column positions are unchanged. `.vue`, `.svelte`, `.astro` and
unknown extensions have no literal-aware scanner, so their view is the
comment-stripped one, as before.

A rule whose target only exists as a literal value — an attribute value such
as `target="_blank"`, a module specifier such as `from 'react'`, a URL —
opts into the *literal view*, which is the historical comment-stripped view
with literal text intact:

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

`match_literals` is per-rule and defaults to `false`. The `unless` guard sees
the same view as the matcher. It is ignored when `match_comments` is set,
because the raw view already contains literal text. The shipped presets use
it for the rules that need it (`react/jsx-no-target-blank`,
`next/google-font-display`, `angular/relative-url-prefix`, …), and
`presets/*.json` carry the same flag. View selection takes part in the
incremental cache fingerprint, so toggling either flag invalidates cached
results.

## File-Level Rules

File-level rules check whole-file properties (size, whitespace, naming,
duplicates) rather than individual lines. They are declared in a separate
`file_rules` array in the config:

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

### File check types

| Check | JSON | Description |
|-------|------|-------------|
| `max_lines` | `{ "max_lines": 500 }` | File must not exceed N lines |
| `max_line_length` | `{ "max_line_length": 120 }` | No line may exceed N characters |
| `no_trailing_whitespace` | `{ "no_trailing_whitespace": true }` | No trailing whitespace on any line |
| `no_tabs` | `{ "no_tabs": true }` | No tab characters |
| `final_newline` | `{ "final_newline": true }` | File must end with a newline |
| `no_duplicate_lines` | `{ "no_duplicate_lines": true }` or `{ "no_duplicate_lines": 40 }` | No repeated line of at least N trimmed characters (default 24; `0` compares any non-empty line) |
| `file_naming` | `{ "file_naming": "kebab-case" }` | File name must follow a convention (camelCase, PascalCase, snake_case, kebab-case) |
| `max_file_size` | `{ "max_file_size": 10000 }` | File must not exceed N bytes |
| `no_empty_files` | `{ "no_empty_files": true }` | File must not be empty |
| `line_ending` | `{ "line_ending": "lf" }` | File must use consistent line endings (lf or crlf) |
| `no_bom` | `{ "no_bom": true }` | File must not start with a UTF-8 BOM |

The `rules` array is optional when `file_rules` is present.

`no_duplicate_lines` only compares lines long enough to be substantive: a
minimum trimmed length (24 by default) keeps `}`, `</view>`, `/**` and
`return` — which repeat in every file by construction — from flooding the
report. Set an explicit number to tune it, or `0` to compare every non-empty
line.

## Cross-File Structural Rules

Line and file rules see one file at a time. JS/TS structural rules use a
best-effort tokenizer/declaration/import model, not a complete JS/TS AST or
Node module/type resolver. Cross-file checks load additional dependency context
and report findings only for selected paths; context read failures return exit 2.

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

Or activate the whole set with `--preset imports`.

### Structural check types

| Check | JSON | Description |
|-------|------|-------------|
| `no_unused_imports` | `{ "no_unused_imports": true }` | An imported binding is never referenced in the importing file |
| `no_duplicate_imports` | `{ "no_duplicate_imports": true }` | The same module is imported by more than one import statement |
| `no_unresolved_relative_imports` | `{ "no_unresolved_relative_imports": true }` | A relative import cannot be resolved in the supplied project/context membership |
| `no_import_cycles` | `{ "no_import_cycles": true }` | The file takes part in a cycle of relative imports (reported per file) |
| `no_default_export` | `{ "no_default_export": true }` | `export default` is used |
| `no_deep_relative_imports` | `{ "no_deep_relative_imports": 2 }` | A relative import climbs more than N directories with `../` |
| `no_require_imports` | `{ "no_require_imports": true }` | `require()` is used in an ES module codebase |
| `no_unused_exports` | `{ "no_unused_exports": true }` | An exported name is never imported by the available project/context files (ambient `.d.ts` files are exempt) |

The `rules` array is optional when `structural_rules` is present. Structural
findings respect inline `// moonlint-disable <rule-id>` comments and rule
scopes, exactly like line findings.

Cross-file checks read unselected dependencies as context. When the selection
is empty there is nothing they could report — findings outside the selection
are dropped — so the context read is skipped entirely and an unrelated
unreadable file cannot turn an empty scan into exit 2.

### Path aliases

Bare specifiers that go through a path alias (`@/api/ka`, `~/utils/date`) do
not resolve on their own, so `no_unused_exports` would count every
alias-imported export as dead. Declare the aliases so the cross-file pass can
follow them:

```json
{
  "aliases": { "@": "src", "~": "." },
  "structural_rules": [
    { "id": "imports/no-unused-exports", "severity": "warning", "message": "dead export", "extensions": [], "check": { "no_unused_exports": true } }
  ]
}
```

Alias targets are **relative to the scan root** (the directory being linted),
so a config used with `moonlint src` maps `@` to `.`, while one used with
`moonlint .` maps `@` to `src`. A prefix matches on a segment boundary — `@`
matches `@/x` but not the package `@scope/pkg` — and a longer prefix wins over
a shorter one (`@/lib` before `@`). Absolute targets, `..` escapes and
non-string values are configuration errors (exit 2). Aliases also make
`no_unused_imports` no longer necessary for template bindings: a `.vue`
binding such as `:src="logo"` is already counted as a usage.

## Inline Disable Comments

Suppress findings without editing the config:

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

- `// moonlint-disable [rule-id ...]` — disable from this line onward
- `// moonlint-disable-next-line [rule-id ...]` — disable on the next line only
- `// moonlint-enable [rule-id ...]` — re-enable from this line onward
- Without rule ids, all rules are affected

## Config Inheritance

Configs can extend other configs with the `extends` field:

```json
{
  "extends": "presets/react.json",
  "rules": [
    { "id": "custom/no-foo", "message": "...", "match": { "contains": "foo" } }
  ]
}
```

`extends` accepts a string or an array of strings. Inheritance is recursive:
each path resolves relative to **the config file that declares it**, so a
`lvl1/mid.json` may itself extend `lvl2/leaf.json`. Rules from extended configs
are merged with the current config's rules; the current config takes precedence
on id conflicts, which is the intended overriding mechanism.

Cyclic `extends` chains (`a.json` → `b.json` → `a.json`) are detected and
reported as a config error (exit 2) rather than recursing indefinitely.
Duplicate ids within a file, including across rule kinds, are rejected.
Same-kind ids may deliberately override inherited rules. Unknown fields,
ignored `scope` objects (use top-level `include`/`exclude`), invalid severities,
empty extension entries, duplicate JSON keys and ambiguous match/check objects
are errors rather than silently ignored configuration.

## Auto-Fix

The `--fix` flag repairs fixable file-level violations in place:

```bash
# Fix trailing whitespace and missing final newlines
moonlint --preset file --fix /path/to/project

# Additionally normalise tabs to 4 spaces (opt-in)
moonlint --preset file --fix --fix-tab-width 4 /path/to/project

# Show what would change without writing anything
moonlint --preset file --fix --dry-run /path/to/project
```

Candidate checks: `no_trailing_whitespace`, `final_newline`, and `no_tabs`.
MoonBit fixes protect quoted/raw/interpolated literal spans and preserve BOM,
Unicode and CRLF. File checks still inspect original literal whitespace, so
unfixable literal properties remain findings; fixes never suppress them. A final
raw-content line is conservatively left without an inserted newline.

Non-MoonBit fixes are deliberately narrower: simple script sources only;
templates/markup remain untouched, and tab replacement is skipped when quote or
regex-like spans could carry values. Other languages are not automatically
rewritten. A remaining finding is not a successful repair.
Properties that make `--fix` safe to run on a real tree:

| Behaviour | Detail |
|-----------|--------|
| Scope-aware | A rule's `include`/`exclude` and `extensions` are honoured, so excluded trees (e.g. `vendor/**`) are never written |
| Line-ending preserving | `final_newline` appends `\r\n` to a CRLF file, never a bare `\n` |
| Tab opt-in | Tabs change indentation width and can alter semantics (Python, YAML, Makefiles), so `no_tabs` is only fixed with an explicit `--fix-tab-width` |
| Safe target / atomic writes | Reject symlink targets/ancestors, reread before replacement and refuse an observed content change; this is not a filesystem compare-and-swap transaction |
| stderr messages | Progress goes to stderr, keeping `--format json`/`sarif` stdout parseable |
| Working tree only | `--fix` is rejected together with `--changed`/`--staged`, which read Git blobs rather than the working tree |
| Dry run | `--dry-run` reports `would fix <file>` and writes nothing; findings are reported as they still are, since the tree is unchanged |

Every run reports a per-file line plus a total (`fixed N file(s)` / `would fix N file(s)`) on stderr. After fixing, the linter re-scans and reports remaining findings.

## Inline Disable Scope

Inline `moonlint-disable` comments suppress **line-level** findings only.
Whole-file properties — `bom`, `line_ending`, `max_file_size`, `no_empty_files`,
`file_naming`, `max_lines` — cannot be masked by a comment, because they
describe the file rather than a line. Per-line file checks
(`no_trailing_whitespace`, `no_tabs`, `max_line_length`) remain suppressible.

## Quick Start

```bash
# Create a starter config
moonlint --init

# Lint MoonBit sources
moonlint --preset moonbit packages/

# Lint with a framework preset
moonlint --preset react /path/to/project

# Run cross-file import analysis
moonlint --preset imports /path/to/project

# Auto-fix and re-lint
moonlint --preset file --fix /path/to/project

# See every layer fire at once on the shipped demos
moonlint --config examples/demo/moonlint.json examples/demo/src
moonlint --preset moonbit examples/moonbit-demo/src
```

## Scan Modes

By default, moonlint walks the directory tree recursively. Five alternative scan modes are available:

```bash
# Only scan files changed since a git ref (ideal for CI)
moon run cmd/main -- --changed origin/main /path/to/project

# Only scan staged files (ideal for pre-commit hooks)
moon run cmd/main -- --staged /path/to/project

# Only scan files matching a glob pattern
moon run cmd/main -- --glob "src/**/*.ts" /path/to/project

# Read file paths from stdin, one per line
git diff --name-only | moon run cmd/main -- --stdin /path/to/project

```

`--watch` is **not implemented**; it is rejected with exit code 2 and an
`unsupported` message rather than being accepted and silently ignored. For fast
repeated scans use `--incremental` (see below).

Scan modes are mutually exclusive. Every mode shares one selection contract:
paths are root-relative, de-duplicated, sorted, extension-filtered and
scope-filtered. `--glob` may be repeated; the patterns form a union.

- `--changed <ref>` compares `merge-base(ref, HEAD)` with `HEAD`, so a pull
  request is measured against its true base, and reads the **committed HEAD
  blobs** — not the working tree and not only the changed lines.
- `--staged` reads the **actual index contents**, so a clean working tree cannot
  mask a dirty staged file (or vice versa).
- Git failures (not a repository, unknown ref, unmerged index) exit 2 instead of
  producing an empty, apparently clean scan.

## Package dependency policies

Generate the official graph in the owning module, then pass it to moonlint:

```bash
(cd examples/package-policy-demo && moon tree --package --json --target native > graph.native.json)
moonlint --package-graph examples/package-policy-demo/graph.native.json \
  --config examples/package-policy-demo/policy.json --format json
# Expected exit 1: the acyclic domain -> ui edge violates the team rule.
```

[The example](<examples/package-policy-demo/README.md>) compiles and tests before
the policy gate. Policy v1 requires `package_rules` with stable id, severity,
`from`, exactly one of `allow`/`deny`, `kinds` (`source`, `test`, `wbtest`),
optional `targets`, and a reason. Empty `allow` denies every applicable edge;
empty `deny` is invalid. Graph v3 validation is strict. The gate covers direct
selected-root edges to supplied non-stdlib nodes, not transitive dependencies
or stdlib edges. Zero applicability is explicitly reported, not presented as
proof that every target was checked. No compiler build/download is triggered.

## Historical public-interface gate

```bash
# First generate each interface with the intended compiler/backend.
moon info
moonlint --api-snapshot pkg.generated.mbti \
  --api-toolchain "moon 0.1.20261102; moonc v0.10.19+bee578715" \
  --api-backend native --api-module-version 0.3.0 > api.snapshot.json
moonlint --api-check before.snapshot.json after.snapshot.json --format sarif
# Opt in to an intentional breaking 0.x minor / stable major release:
moonlint --api-check before.snapshot.json after.snapshot.json --api-version-policy semver
```

Snapshots record package, toolchain, backend and module version. Metadata is
caller-supplied, **not compiler provenance attestation**: use the same actual
compiler/backend before and after. Different contexts, malformed data and
unsupported declaration syntax are inconclusive (exit 2). Removals and shape
changes block by default, even if the version changed. Opt-in `semver` changes
review findings to warnings only after a sufficient version increment;
prerelease/build versions are explicitly unsupported by that policy.

This compares supported historical public declarations/symbols, not just
interface text or export count. It is conservative review evidence, not an ABI,
type-assignability or behavioral-compatibility proof. Bodies/docs/private or
hidden exports are outside the snapshot surface; member additions may require
review. See [the compiling before/after example](<examples/api-policy-demo/README.md>).

Package/API/audit reports use `mode`, `metadata`, `counts`, `findings` and
identity details, not fabricated `scan` counters or source coordinates. SARIF
results have no `locations` for those project findings; GitHub annotations omit
file/line properties. `--report` writes the same project JSON schema.

## Baseline v2 and exception auditing

A baseline is never discovered implicitly. A write registers debt and returns
write-mode 0; it is **not a successful lint/CI verdict**.

```bash
moonlint --preset moonbit --update-baseline --baseline-format v2 \
  --baseline debt.json --baseline-reason "existing review debt" \
  --baseline-owner "package-maintainer" --baseline-expires 2026-12-31 .
moonlint --preset moonbit --baseline debt.json .
moonlint --preset moonbit --baseline debt.json --changed origin/main .
# Full-tree audit, with reproducible UTC-date override if needed:
moonlint --preset moonbit --audit-baseline --baseline debt.json \
  --baseline-today 2026-11-04 --format json .
# Convert only still-matching old exemptions, not newly introduced errors:
moonlint --preset moonbit --migrate-baseline --baseline legacy.json \
  --baseline-reason "reviewed legacy debt" --baseline-owner "package-maintainer" .
```

V2 fingerprints omit line/column, retain rule/file/severity/message and the
end-trimmed snippet, and preserve internal/literal whitespace. Each entry has a
positive occurrence budget, nonempty reason/owner, and nullable expiry. The
expiry day itself is valid; earlier expiry never suppresses. Default date is
host UTC. Audit errors identify expired, unused and partially unused budgets;
`unused_occurrences` totals the unused quota. Normal lint warns about audit
issues but does not silently turn normal suppression into an audit gate.

This is a **non-cryptographic content-identity MVP**, not ancestor or semantic
identity. Identical replacement within the stored count is indistinguishable;
rename, message/severity or snippet changes lose the exemption. Full-tree audits
must not be narrowed by `--changed`, `--staged`, `--glob`, stdin or `--ext`.
Migration returns 1 when unsuppressed errors remain; it never approves newly
introduced debt. Update/migration/audit cannot combine with fixes/project modes.
Legacy arrays remain explicit, line-sensitive inputs; overwriting a v2 baseline
requires an explicit v2 write and metadata rather than downgrading it silently.

### Frontend limits

MoonBit source checks share code/declaration/comment/literal views. Nonempty
documentation is required; comment-looking raw text and an empty separator are
not docs. Calls after literals and within supported single-line interpolations
are visible; definitions and test bodies are not mistaken for ordinary calls.
These are syntactic name policies, not binding resolution (a local bare `panic`
can still be a name-policy match). Qualified user `Foo::panic`/`println` are not
assumed to be builtin calls. Unknown public-declaration forms and unfinished
lexical input are inconclusive. Cross-physical-line interpolation is currently
unsupported and rejected, not counted as successfully parsed source.

The JS/TS front end is a tokenizer and structural parser, not a Vue SFC
compiler. For `.vue` files it reads the script for imports/exports and
extracts the template's binding expressions (`:prop`, `v-*`, `@event`) as
identifier reads, so a binding used only in a template still counts as a
usage. It does not evaluate template control flow, resolve component
registration, or follow aliases unless they are declared in `aliases`.

Git modes capture immutable blob-id maps for selected/context sources; replace
refs are disabled. Selection precedes capture, so concurrent changes **during
selection** are not an atomic repository snapshot. Avoid concurrent Git edits
when selecting files. Tree/glob/stdin context is likewise a live-tree read, not
a filesystem transaction. Context counters/failures disclose these extra reads.

### Incremental caching

`--incremental` keeps a content-hash cache of per-file results, so a repeated
scan only re-lints files whose source changed:

```bash
# First run populates .moonlint-cache.json; later runs reuse unchanged files
moon run cmd/main -- --incremental /path/to/project

# Custom cache location
moon run cmd/main -- --incremental --cache-file /tmp/moonlint.cache.json /path/to/project
```

Properties that make the cache safe:

| Behaviour | Detail |
|-----------|--------|
| Content-keyed | Each entry is keyed by a non-cryptographic hash of strictly decoded source (BOM/Unicode preserved); an edit, even whitespace, re-lints that file |
| Config-aware | The cache stores a fingerprint of the effective rules, file rules, structural rules and scopes; any change invalidates every entry |
| Self-healing | A missing, corrupt or version-mismatched cache file degrades to a full scan with a warning, never a wrong result |
| Structural-safe | Cached runs still collect project sources for cross-file checks, and refresh full dependency context under the same rules; context failures block the verdict |
| Opt-in | Without `--incremental` no cache file is read or written |

The cache also keeps each file's **parsed structural model** (imports, exports
and the set of used names), keyed by the same content hash. Findings still
never come from the cache for cross-file rules on a changed tree — a dead
export can become live when an unrelated file is edited — but the expensive
tokenize/parse step is skipped for unchanged files, which is what made
`--incremental` worthwhile for `--preset imports` scans. Models are
rule-independent, so they survive a configuration change, and they carry a
parser generation: bumping the parser drops stale models without discarding
the per-file findings.

On top of that, a full-tree scan records the **structural verdict itself**,
keyed by the rule fingerprint plus every participating file's content hash.
When an unchanged tree is scanned again under the same rules, the whole
cross-file pass is skipped — no context reads, no analysis. Because that key
covers every file that took part, any edit, addition or deletion changes it and
forces a recompute. Partial scans (`--glob`, `--stdin`, `--changed`,
`--staged`) and scans that exclude files by scope are never reused this way,
since their unselected dependency context is not part of the key.

| Behaviour | Detail |
|-----------|--------|
| Content-keyed models | A model is reused only when its stored hash equals the source being scanned |
| Rule-independent | Models are reused across rule changes; only cross-file findings are re-derived |
| Parser generation | A model written by an older parser (`model_version`) is dropped, so a front-end fix is never masked by a stale parse |
| Bounded | Only files in the current selection keep an entry; a deleted file leaves no model behind |
| Verdict identity | The cached structural verdict is keyed by the rule fingerprint plus every participating file's digest, so any edit invalidates it |
| No snippets stored | Cached structural findings omit snippets (a minified line can be larger than the cache); they are re-derived from the scanned source, so reports stay byte-identical |

### Glob syntax

| Pattern | Matches |
|---------|---------|
| `*` | Any characters except `/` |
| `**` | Any characters including `/` |
| `?` | Any single character except `/` |
| Literal | Exact match |

A pattern that matches a directory also covers everything below it, so the
scope pattern `vendor` excludes `vendor/pkg/index.ts` while leaving
`vendorless/index.ts` alone.

## Configuration

Rules are defined in a JSON file (default: `moonlint.json`):

```json
{
  "rules": [
    {
      "id": "vue/import-from-vue",
      "severity": "error",
      "message": "Must import from 'vue-lynx', not 'vue'",
      "extensions": [".vue", ".ts"],
      "match": { "regex": "from[[:space:]]+['\"]vue['\"]" },
      "unless": { "regex": "from[[:space:]]+['\"]vue-lynx['\"]" }
    }
  ]
}
```

### Rule fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Stable identifier, e.g. `vue/import-from-vue` |
| `severity` | string | `"error"` or `"warning"` (default: `"warning"`) |
| `message` | string | Human-readable explanation |
| `extensions` | string[] | File extensions to check (empty = all files) |
| `match` | object | Primary matcher (see below) |
| `unless` | object | Optional negative guard |
| `match_comments` | bool | Match the raw view (comments included). Default `false` |
| `match_literals` | bool | Match the literal view (string/template/regex contents intact). Default `false`; ignored when `match_comments` is set |
| `include` | string[] | Optional paths this rule applies to |
| `exclude` | string[] | Optional paths this rule never applies to |

### Scopes

The same `include` / `exclude` keys may appear at the top level of the config
(global scope) and inside each rule (rule scope). Both take root-relative glob
patterns using the syntax above; a leading `./` is accepted.

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

- An empty `include` list means "no restriction"; any `exclude` match wins over
  `include`.
- The **global** scope is applied first: rejected files are counted in
  `files_out_of_scope` and receive no findings. They can still be read as dependency context for cross-file checks.
- A **rule** scope only decides which rules see an already-selected file. It
  cannot widen the global scan set. A selected file that no rule applies to is
  counted in `files_skipped` with the reason `no-applicable-rule`.
- Invalid or unsupported patterns (braces, character classes, absolute paths,
  `..`) are configuration errors — exit code 2, not a silently narrower scan.

Run `moonlint` from the repository root so reported paths (and GitHub
annotations) resolve correctly.

### Matcher types

See [Matcher Types](#matcher-types) above for the leaf matchers and the
`all` / `any` / `not` combinators. Both `match` and `unless` accept any of them.

> **Note:** MoonBit's regex engine supports POSIX character classes (`[[:space:]]`, `[[:digit:]]`, `[[:alpha:]]`) but not Perl-style escapes (`\d`, `\w`, `\s`).

## Output

### `--format text` (default)

One block per finding, plus a notice when nothing was selected:

```
src/app.ts:12: [error] vue/import-from-vue — Must import from 'vue-lynx', not 'vue'
    import { createApp } from 'vue'
```

`--summary` prints a per-rule tally with the scan counters instead.

### `--format json`

A versioned document (`"version": 1`):

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

`line` and `column` are 1-based and count characters, not bytes, so a finding
after multi-byte text points at the right place. `column` is the first character
of the match: for `contains`, `prefix` and `whole-word` rules that is where the
pattern text appears, for `suffix` rules the start of the trailing text, and for
`regex` rules the first non-space character (the match offset is not recoverable
from the pattern alone). SARIF `startColumn` uses the same value with `columnKind: unicodeCodePoints`.

`files_selected` is counted after path normalization, extension filtering and
de-duplication. Every selected file is either scanned, skipped (with a reason in
`skipped_files`) or failed (with a diagnostic). `--errors-only` filters the
findings and their counts, but never the scan metadata.

`--report <file>` writes the same JSON document to a file atomically, in addition
to whatever goes to stdout; it is also written when the scan fails.

### `--format github`

Emits GitHub Actions workflow commands:

```
::error file=src/app.ts,line=12,col=22,title=vue/import-from-vue::Must import from 'vue-lynx', not 'vue'
::error file=src/broken.ts,title=moonlint/scan-failed::source is not valid UTF-8
::notice file=docs/notes.md,title=moonlint/skipped::no-applicable-rule
::notice title=moonlint::files selected: 12, scanned: 10, skipped: 1, failed: 1, …
```

Property values and messages are escaped as GitHub requires, so a newline in a
rule message can never forge an extra command.

### `--format sarif`

Emits a SARIF 2.1.0 document (`$schema`, `runs[].tool.driver.rules` and
`results[]` with `ruleId`, `level` and `physicalLocation`), suitable for GitHub
code scanning, VS Code and most CI static-analysis integrations.

## Exit Codes

- `0` — no error-severity findings
- `1` — error-severity findings found
- `2` — argument, configuration, Git, or I/O error (including any file that could
  not be read, a reference that cannot be resolved, an unmerged index, a cyclic
  or unreadable `extends` chain, and `--fix` combined with `--changed`/`--staged`)

## Architecture

```
moonlint/
├── types.mbt         — Severity, MatchKind (leaves + all/any/not), Rule,
│                       Finding, FileRule, StructuralRule, LintResult, ScanInfo
├── matcher.mbt       — MatchKind evaluation; `prepare()` compiles each regex
│                       once per rule, not per line, and pre-compiles nested
│                       combinators depth-first
├── comment.mbt       — comment blanking: JS/TS mode (template literals,
│                       interpolations, strings, regex) and plain mode
├── lex.mbt           — JS/TS tokenizer: strings, template literals with ${}
│                       interpolation, regex literals, comments, identifiers
├── parse.mbt         — structured parser: import/export statements, bindings,
│                       usage positions, relative specifiers
├── analysis.mbt      — cross-file engine: project index, import resolution,
│                       import graph, and the 8 structural checks
├── moonbit_lang.mbt  — MoonBit front end: comment/string blanking, top-level
│                       declaration scanner, ///| attachment, public-doc and
│                       naming checks
├── scanner.mbt       — file walking, line splitting, source reading
├── scope.mbt         — include/exclude glob scopes
├── scan.mbt          — scan modes, glob matching, file selection
├── git.mbt           — native filesystem/Git bridge (fixed argv, no shell)
├── git_native.c      — lstat, Git (merge-base/changed/staged/blob), atomic write
├── engine.mbt        — rule application, scope filtering, scan accounting,
│                       structural pass and incremental-cache plumbing
├── cache.mbt         — incremental cache: content hashes, config fingerprint,
│                       JSON render/parse (strict; corrupt input degrades to
│                       a full scan)
├── config.mbt        — JSON config parsing, validation, and extends
├── presets.mbt       — built-in presets (common, react, vue, angular, svelte,
│                       next, solid, astro, nuxt, file, imports, moonbit)
├── presets/          — standalone JSON copies of each preset for customization
├── disable.mbt       — inline disable comment parsing (// moonlint-disable)
├── baseline.mbt      — hash-based finding exemption
├── report.mbt        — detail and summary rendering
├── report_json.mbt   — JSON report
├── report_github.mbt — GitHub Actions annotations
├── report_sarif.mbt  — SARIF 2.1.0 report
├── tests/            — dependency-free CLI integration tests
├── examples/         — TS and MoonBit demos with hand-verified reports
└── cmd/main/         — CLI entry point
```

The MoonBit front end is a declaration scanner: it blanks comments and
literals, tracks brace depth to separate top-level items from bodies, attaches
non-empty documentation, and evaluates public-doc, naming and syntactic call checks. The JS/TS
compatibility path is the tokenizer → parser → project index/import graph.
Both share the line/file layers, rule engine, cache and reporters. The
implementation is pure MoonBit except for the native filesystem/Git bridge in
`git_native.c`, and each layer is unit-tested in isolation.

## Development and verification

The executable requires the **native backend on macOS/Linux** for filesystem,
Git and UTC-date operations. Building it requires MoonBit plus a C toolchain;
using the built executable does not require a Node.js or Rust toolchain.

```bash
moon check --target native
moon test --target native
moon build --target native
python3 tests/integration.py \
  --binary "$PWD/_build/native/debug/build/cmd/main/main.exe" --phase all
moon info && moon fmt
# Review generated interface/source diffs, then rerun affected gates.
```

[CI](<.github/workflows/ci.yml>) runs explicit native gates and compiles the
examples. Its installer fetches latest, **not a pinned toolchain**; versions are
recorded and interface/format drift is checked. Remote CI was not verified in
this session. Current local evidence and known limits are in
[verification notes](<docs/verification.md>); historical wasm failures are not
claimed fixed. The JS/TS legacy line matcher still sees literal text in two
known expected-failure cases; they are not counted as repaired behavior.

`moonlint .` uses [the repository config](<moonlint.json>), which deliberately
excludes the negative examples. No new blanket baseline was added to hide
missing public documentation.

## License

Apache-2.0; [LICENSE](<LICENSE>) and [third-party attribution](<THIRD_PARTY_NOTICES.md>).
