# moonlint

A config-driven convention linter for source trees, written in [MoonBit](https://www.moonbitlang.com/).

Ported from `wot-lynx-ui`'s `scripts/review-lint.mjs` as an entry for the 2026 MoonBit Hackathon.

## What it does

`moonlint` scans a directory tree, applies a set of declarative rules to each source file, and reports violations. Rules are loaded from a JSON config file, so the same engine can enforce any project's conventions.

## Features

- **Config-driven** — rules defined in JSON, no code changes needed
- **Built-in framework presets** — ready-to-use rule sets for React, Vue, Angular, Svelte, Next.js and common JS/TS hygiene; activate with `--preset <name>`
- **Regex + substring matching** — `contains`, `prefix`, `suffix`, and `regex` matchers
- **Negative guards** — `unless` field to suppress false positives (e.g. "import from 'vue' but not 'vue-lynx'")
- **Comment-aware** — `//` and `/* */` comments are blanked out before matching, preserving line numbers and columns; in JS/TS/JSX files the scanner understands template literals, `${}` interpolations, strings and regex literals, so a `//` inside a template string is text, not a comment
- **Baseline support** — hash-based exemption for existing violations, enabling incremental adoption; `--update-baseline` refreshes it atomically from a full scan
- **Severity levels** — `error` and `warning`, with exit code 1 on any error-severity finding
- **Scoped rules** — global and per-rule `include`/`exclude` glob patterns decide which files are read and which rules see them
- **CI output** — machine-readable JSON reports and GitHub Actions annotations, with read / failure / skip metadata
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

Every preset is also shipped as a standalone JSON file under `presets/`
(`angular`, `astro`, `common`, `file`, `next`, `nuxt`, `react`, `solid`,
`svelte`, `vue`) for users who prefer to copy and customize them:

```bash
moon run cmd/main -- --config presets/react.json /path/to/project
```

> **Note:** Preset rules are line-oriented — they match one source line at a
> time, after comments have been blanked out. Rules that need an AST (unused
> variables, hook dependencies, prop types) are intentionally absent.

## Matcher Types

A matcher object has exactly one of:

- `{ "contains": "substring" }` — line contains the substring
- `{ "prefix": "text" }` — line starts with the text
- `{ "suffix": "text" }` — line ends with the text
- `{ "regex": "pattern" }` — line matches the regex
- `{ "equals": "text" }` — trimmed line equals the text exactly
- `{ "word": "text" }` — line contains the text as a whole word

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

`--incremental` (cached re-scans) and `--watch` are **not implemented**. They are
rejected with exit code 2 and an `unsupported` message rather than being accepted
and silently ignored.

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

A matcher object has exactly one of:

- `{ "contains": "substring" }` — line contains the substring
- `{ "prefix": "text" }` — line starts with the text
- `{ "suffix": "text" }` — line ends with the text
- `{ "regex": "pattern" }` — line matches the regex

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
├── types.mbt         — Severity, MatchKind, Rule, Finding, LintResult, ScanInfo
├── matcher.mbt       — MatchKind evaluation (contains/prefix/suffix/regex);
│                       `prepare()` compiles each regex once per rule, not per line
├── comment.mbt       — comment blanking: JS/TS mode (template literals,
│                       interpolations, strings, regex) and plain mode
├── scanner.mbt       — file walking, line splitting, source reading
├── scope.mbt         — include/exclude glob scopes
├── scan.mbt          — scan modes, glob matching, file selection
├── git.mbt           — native filesystem/Git bridge (fixed argv, no shell)
├── git_native.c      — lstat, Git (merge-base/changed/staged/blob), atomic write
├── engine.mbt        — rule application, scope filtering, scan accounting
├── config.mbt        — JSON config parsing, validation, and extends
├── presets.mbt       — built-in framework presets (react, vue, angular, svelte, next, solid, astro, nuxt, file, common)
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

## Development

```bash
moon info          # refresh .mbti interfaces
moon fmt           # format
moon test          # unit tests (native target)
moon build --target native
python3 tests/integration.py \
  --binary "$PWD/_build/native/debug/build/cmd/main/main.exe" --phase all
```

## License

Apache-2.0
