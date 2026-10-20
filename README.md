# moonlint

A config-driven convention linter for source trees, written in [MoonBit](https://www.moonbitlang.com/).

Ported from `wot-lynx-ui`'s `scripts/review-lint.mjs` as an entry for the 2026 MoonBit Hackathon.

## What it does

`moonlint` scans a directory tree, applies a set of declarative rules to each source file, and reports violations. Rules are loaded from a JSON config file, so the same engine can enforce any project's conventions.

## Features

- **Config-driven** — rules defined in JSON, no code changes needed
- **Regex + substring matching** — `contains`, `prefix`, `suffix`, and `regex` matchers
- **Negative guards** — `unless` field to suppress false positives (e.g. "import from 'vue' but not 'vue-lynx'")
- **Comment-aware** — `//` and `/* */` comments are blanked out before matching, preserving line numbers
- **Baseline support** — hash-based exemption for existing violations, enabling incremental adoption
- **Severity levels** — `error` and `warning`, with exit code 1 on any error-severity finding
- **Summary mode** — per-rule tally for quick overview

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

# Skip files whose content hash matches the cache
moon run cmd/main -- --incremental /path/to/project
```

### Glob syntax

| Pattern | Matches |
|---------|---------|
| `*` | Any characters except `/` |
| `**` | Any characters including `/` |
| `?` | Any single character except `/` |
| Literal | Exact match |

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

### Matcher types

A matcher object has exactly one of:

- `{ "contains": "substring" }` — line contains the substring
- `{ "prefix": "text" }` — line starts with the text
- `{ "suffix": "text" }` — line ends with the text
- `{ "regex": "pattern" }` — line matches the regex

> **Note:** MoonBit's regex engine supports POSIX character classes (`[[:space:]]`, `[[:digit:]]`, `[[:alpha:]]`) but not Perl-style escapes (`\d`, `\w`, `\s`).

## Exit Codes

- `0` — no error-severity findings
- `1` — error-severity findings found
- `2` — configuration or I/O error

## Architecture

```
moonlint/
├── types.mbt       — Severity, MatchKind, Rule, Finding, LintResult
├── matcher.mbt     — MatchKind evaluation (contains/prefix/suffix/regex)
├── scanner.mbt     — comment stripping, file walking, line splitting
├── engine.mbt      — rule application, tree linting
├── config.mbt      — JSON config parsing and validation
├── baseline.mbt    — hash-based finding exemption
├── report.mbt      — detail and summary rendering
└── cmd/main/       — CLI entry point
```

## License

Apache-2.0
