# moonlint

A config-driven convention linter for source trees, written in [MoonBit](https://www.moonbitlang.com/).

Ported from `wot-lynx-ui`'s `scripts/review-lint.mjs` as an entry for the 2026 MoonBit Hackathon.

## What it does

`moonlint` scans a directory tree, applies a set of declarative rules to each source file, and reports violations. Rules are loaded from a JSON config file, so the same engine can enforce any project's conventions.

## Features

- **Config-driven** — rules defined in JSON, no code changes needed
- **Built-in framework presets** — ready-to-use rule sets for React, Vue, Angular, Svelte, Next.js, SolidJS, Astro, Nuxt, common JS/TS hygiene, file-level checks and cross-file import checks; activate with `--preset <name>`
- **Regex + substring matching** — `contains`, `prefix`, `suffix`, `regex`, `equals` and `word` matchers
- **Matcher combinators** — `all` / `any` / `not` nest arbitrarily deep, so `match` expresses any boolean formula over the leaf matchers
- **Negative guards** — `unless` field to suppress false positives (e.g. "import from 'vue' but not 'vue-lynx'")
- **Comment-aware** — `//` and `/* */` comments are blanked out before matching, preserving line numbers and columns; in JS/TS/JSX files the scanner understands template literals, `${}` interpolations, strings and regex literals, so a `//` inside a template string is text, not a comment. Rules that *target* comments opt in with `"match_comments": true`
- **Cross-file structural rules** — a JS/TS tokenizer + parser builds a project-wide import graph, powering unused imports, duplicate imports, unresolved relative imports, import cycles, deep relative imports, `require()` usage, `export default` and dead exports (`--preset imports`)
- **Baseline support** — hash-based exemption for existing violations, enabling incremental adoption; `--update-baseline` refreshes it atomically from a full scan
- **Incremental caching** — `--incremental` re-lints only files whose content hash changed, invalidated automatically when the effective config changes
- **Severity levels** — `error` and `warning`, with exit code 1 on any error-severity finding
- **Scoped rules** — global and per-rule `include`/`exclude` glob patterns decide which files are read and which rules see them
- **CI output** — machine-readable JSON reports, GitHub Actions annotations and SARIF 2.1.0, with read / failure / skip metadata
- **Honest counters** — every selected file is reported as scanned, skipped (with a reason) or failed; a scan never silently degrades to "clean"
- **Summary mode** — per-rule tally plus read/skip/failure counts

## Installation

```bash
# Clone and build
git clone https://github.com/ximo-156/wot-lynx-ui-moonbit
cd wot-lynx-ui-moonbit
moon build
```

## Usage

```bash
# Lint current directory with default config
moon run cmd/main

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

# Cross-file import checks (unused imports, cycles, unresolved paths, ...)
moon run cmd/main -- --preset imports /path/to/project

# Fast repeated scans: only changed files are re-linted
moon run cmd/main -- --incremental /path/to/project
```

## Framework Presets

moonlint ships built-in rule sets for popular frontend frameworks. Activate
one or more with `--preset <name>` (repeatable); rules from multiple presets
are merged with de-duplication by rule id.

```bash
# List available presets
moon run cmd/main -- --list-presets

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
| `common` | `.js` `.jsx` `.ts` `.tsx` `.mjs` `.cjs` `.vue` `.svelte` `.astro` | 5 | Framework-agnostic hygiene: no-console-log, no-debugger, no-alert, no-eval, no-var |
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

Every preset is also shipped as a standalone JSON file under `presets/`
(`angular`, `astro`, `common`, `file`, `imports`, `next`, `nuxt`, `react`,
`solid`, `svelte`, `vue`) for users who prefer to copy and customize them:

```bash
moon run cmd/main -- --config presets/react.json /path/to/project
```

> **Note:** The framework presets are line-oriented — they match one source line
> at a time, after comments have been blanked out. Rules that need an AST
> (unused variables, hook dependencies, prop types) are intentionally absent
> from those presets; the `imports` preset instead runs real cross-file program
> analysis (see [Cross-File Structural Rules](#cross-file-structural-rules)).

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
matchers, nested arbitrarily deep:

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
| `no_duplicate_lines` | `{ "no_duplicate_lines": true }` | No duplicate lines |
| `file_naming` | `{ "file_naming": "kebab-case" }` | File name must follow a convention (camelCase, PascalCase, snake_case, kebab-case) |
| `max_file_size` | `{ "max_file_size": 10000 }` | File must not exceed N bytes |
| `no_empty_files` | `{ "no_empty_files": true }` | File must not be empty |
| `line_ending` | `{ "line_ending": "lf" }` | File must use consistent line endings (lf or crlf) |
| `no_bom` | `{ "no_bom": true }` | File must not start with a UTF-8 BOM |

The `rules` array is optional when `file_rules` is present.

## Cross-File Structural Rules

Line and file rules see one file at a time. Structural rules see the whole
project at once: moonlint tokenizes and parses every JS/TS file into an import
graph, then evaluates checks that are impossible per-line.

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
| `no_unresolved_relative_imports` | `{ "no_unresolved_relative_imports": true }` | A relative import cannot be resolved to any scanned file |
| `no_import_cycles` | `{ "no_import_cycles": true }` | The file takes part in a cycle of relative imports (reported per file) |
| `no_default_export` | `{ "no_default_export": true }` | `export default` is used |
| `no_deep_relative_imports` | `{ "no_deep_relative_imports": 2 }` | A relative import climbs more than N directories with `../` |
| `no_require_imports` | `{ "no_require_imports": true }` | `require()` is used in an ES module codebase |
| `no_unused_exports` | `{ "no_unused_exports": true }` | An exported name is never imported by any other scanned file |

The `rules` array is optional when `structural_rules` is present. Structural
findings respect inline `// moonlint-disable <rule-id>` comments and rule
scopes, exactly like line findings.

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
Duplicate rule ids **within a single file** are rejected, since the later rule
would otherwise be silently shadowed.

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

Auto-fixable checks: `no_trailing_whitespace`, `final_newline`, and `no_tabs`.
Properties that make `--fix` safe to run on a real tree:

| Behaviour | Detail |
|-----------|--------|
| Scope-aware | A rule's `include`/`exclude` and `extensions` are honoured, so excluded trees (e.g. `vendor/**`) are never written |
| Line-ending preserving | `final_newline` appends `\r\n` to a CRLF file, never a bare `\n` |
| Tab opt-in | Tabs change indentation width and can alter semantics (Python, YAML, Makefiles), so `no_tabs` is only fixed with an explicit `--fix-tab-width` |
| Atomic writes | Files are replaced atomically; an interrupted fix cannot truncate source |
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

# Lint with a framework preset
moonlint --preset react /path/to/project

# Run cross-file import analysis
moonlint --preset imports /path/to/project

# Auto-fix and re-lint
moonlint --preset file --fix /path/to/project
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
| Content-keyed | Each entry is keyed by a hash of the file's exact bytes; an edit, even whitespace, re-lints that file |
| Config-aware | The cache stores a fingerprint of the effective rules, file rules, structural rules and scopes; any change invalidates every entry |
| Self-healing | A missing, corrupt or version-mismatched cache file degrades to a full scan with a warning, never a wrong result |
| Structural-safe | Cached runs still collect project sources for cross-file checks, so structural findings stay correct |
| Opt-in | Without `--incremental` no cache file is read or written |

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
  `files_out_of_scope` and are never read.
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
from the pattern alone). SARIF `startColumn` uses the same value.

`files_selected` is counted after path normalization, extension filtering and
de-duplication. Every selected file is either scanned, skipped (with a reason in
`skipped_files`) or failed (with a diagnostic). `--errors-only` filters the
findings and their counts, but never the scan metadata.

`--report <file>` writes the same JSON document to a file atomically, in addition
to whatever goes to stdout; it is also written when the scan fails.

### `--format github`

Emits GitHub Actions workflow commands:

```
::error file=src/app.ts,line=12,col=1,title=vue/import-from-vue::Must import from 'vue-lynx', not 'vue'
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
│                       next, solid, astro, nuxt, file, imports)
├── presets/          — standalone JSON copies of each preset for customization
├── disable.mbt       — inline disable comment parsing (// moonlint-disable)
├── baseline.mbt      — hash-based finding exemption
├── report.mbt        — detail and summary rendering
├── report_json.mbt   — JSON report
├── report_github.mbt — GitHub Actions annotations
├── report_sarif.mbt  — SARIF 2.1.0 report
├── tests/            — dependency-free CLI integration tests
└── cmd/main/         — CLI entry point
```

The engine is layered: **tokenizer → parser → project index/import graph** for
cross-file checks, on top of the line and file layers. Each layer is pure
MoonBit with no native dependency (the native bridge is limited to filesystem
and Git access), and each is unit-tested in isolation.

## Development

```bash
moon info          # refresh .mbti interfaces
moon fmt           # format
moon test          # unit tests (native target)
moon build --target native
python3 tests/integration.py \
  --binary "$PWD/_build/native/debug/build/cmd/main/main.exe" --phase all
```

CI (`.github/workflows/ci.yml`) runs the full gate on every push:
`moon check` → `moon test` (native) → `moon info` → native build → all
integration phases. On toolchains without a native C toolchain, the unit suite
also runs on the wasm-gc target (`moon test --target wasm-gc`); the only
expected failures there are the handful of tests that exercise the native
filesystem/Git bridge, which wasm cannot provide.

Project management artifacts live in [`docs/`](docs/):
[`PROJECT_PLAN.md`](docs/PROJECT_PLAN.md) (schedule, risks, review strategy)
and [`SUBMISSION_CHECKLIST.md`](docs/SUBMISSION_CHECKLIST.md).

## License

Apache-2.0
