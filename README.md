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
- **Comment-aware** — `//` and `/* */` comments are blanked out before matching, preserving line numbers
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
| `common` | `.js` `.jsx` `.ts` `.tsx` `.mjs` `.cjs` `.vue` `.svelte` | 5 | Framework-agnostic hygiene: no-console-log, no-debugger, no-alert, no-eval, no-var |
| `react` | `.jsx` `.tsx` | 20 | React/JSX: no-danger, no-string-refs, jsx-key, self-closing, target-blank, button-type, ... |
| `vue` | `.vue` `.js` `.ts` | 11 | Vue 3: no-v-html, require-v-for-key, no-v-if-with-v-for, require-scoped-style, ... |
| `angular` | `.ts` | 9 | Angular: no-input-rename, no-output-native, no-forward-ref, relative-url-prefix, ... |
| `svelte` | `.svelte` | 8 | Svelte: no-at-html, require-each-key, a11y-missing-attribute, no-goto-without-base, ... |
| `next` | `.jsx` `.tsx` `.js` `.ts` | 7 | Next.js: no-img-element, no-head-element, no-html-link-for-pages, google-font-display, ... |

The same rule sets are also available as standalone JSON files under
`presets/` for users who prefer to copy and customize them:

```bash
moon run cmd/main -- --config presets/react.json /path/to/project
```

> **Note:** Preset rules are line-oriented — they match one source line at a
> time, after comments have been blanked out. Rules that need an AST (unused
> variables, hook dependencies, prop types) are intentionally absent.

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
      "column": 1,
      "snippet": "import { createApp } from 'vue'"
    }
  ],
  "diagnostics": [{ "file": "src/broken.ts", "message": "source is not valid UTF-8" }]
}
```

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

## Exit Codes

- `0` — no error-severity findings
- `1` — error-severity findings found
- `2` — argument, configuration, Git, or I/O error (including any file that could
  not be read, a reference that cannot be resolved, and an unmerged index)

## Architecture

```
moonlint/
├── types.mbt         — Severity, MatchKind, Rule, Finding, LintResult, ScanInfo
├── matcher.mbt       — MatchKind evaluation (contains/prefix/suffix/regex)
├── scanner.mbt       — comment stripping, file walking, line splitting
├── scope.mbt         — include/exclude glob scopes
├── scan.mbt          — scan modes, glob matching, file selection
├── git.mbt           — native filesystem/Git bridge (fixed argv, no shell)
├── git_native.c      — lstat, Git (merge-base/changed/staged/blob), atomic write
├── engine.mbt        — rule application, scope filtering, scan accounting
├── config.mbt        — JSON config parsing and validation
├── presets.mbt       — built-in framework presets (react, vue, angular, svelte, next, common)
├── presets/          — standalone JSON copies of each preset for customization
├── baseline.mbt      — hash-based finding exemption
├── report.mbt        — detail and summary rendering
├── report_json.mbt   — JSON report
├── report_github.mbt — GitHub Actions annotations
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
