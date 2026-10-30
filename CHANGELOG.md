# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Added

- **MoonBit source front end** (`moonbit_lang.mbt`) — MoonBit files are
  scanned for top-level `fn` / `struct` / `enum` / `type` / `trait` / `let` /
  `const` / `impl` / `test` declarations. Comments and string literals are
  blanked before brace-depth tracking, so bodies do not produce false
  top-level items; `///|` blocks are attached to the declaration that follows
  them, including across `#...` attribute lines.
- **`moonbit` preset** — `moonbit/require-public-doc` and
  `moonbit/naming` structural checks, plus `moonbit/no-unwrap`,
  `moonbit/no-panic`, `moonbit/no-println` and `moonbit/no-todo-comment` line
  rules. The preset excludes `*_test.mbt` and `*_wbtest.mbt`: tests may
  unwrap, panic and print. `presets/moonbit.json` is the standalone copy.
- **`examples/moonbit-demo`** — a five-finding MoonBit sample with the exact
  expected report, exercised by the `moonbit` CLI integration phase.
- **`match_comments` rule option** — line rules normally match the
  comment-stripped view of a file; `"match_comments": true` opts a rule into
  the raw view so it can target comments themselves. The starter config
  written by `--init` uses it for the no-TODO rule, which previously could
  never fire on a `// TODO` comment. The option takes part in the incremental
  cache fingerprint, so toggling it invalidates cached results.
- **`common/no-todo-comment` preset rule** — the `common` preset now ships a
  comment-targeting TODO/FIXME rule (`match_comments: true`, matched through
  the `any` combinator), so the new option is part of the preset surface and
  not only of `--init`. `presets/common.json` carries the same rule.
- **`examples/demo`** — a tiny TypeScript project whose report under the
  shipped config is hand-verified finding by finding: seven findings across
  the line, file and structural layers, plus two deliberate near-misses (an
  `unless`-suppressed TODO and an import that is resolved-but-unused). The
  demo runs as a CLI integration phase and asserts the exact report text.
  The repository's own config excludes `examples/demo` from its scope.
- **Incremental cache walkthrough in `examples/README.md`** — documents the
  fourth layer end to end: which findings the cache stores per file (the
  line and file rules: 2 for `app.ts`, 1 for `helpers.ts`), why the four
  structural findings are deliberately re-derived every run (a dead-export
  answer can change when an unrelated file is edited), and how content-hash
  keying keeps the cache valid across byte-identical rewrites.

### Tests

- 282 whitebox unit tests pass on the native target; on the wasm-gc target
  278 of 283 pass. The 5 failures are the known native filesystem/Git-bridge
  tests that wasm cannot run.
- 167 CLI integration test methods across 11 phases (the `moonbit` phase pins
  the MoonBit demo's full report and checks that the built-in preset and
  `presets/moonbit.json` agree; the `demo` phase pins the TS demo's output,
  `--errors-only` filtering, `--summary` tally and the incremental cache
  round trip).

## [0.2.0] — 2026-10-24

The "engineering depth" release: moonlint grows from a line matcher into a
layered static-analysis engine — tokenizer, parser, cross-file analysis,
incremental caching, and a boolean matcher DSL.

### Added

- **JS/TS tokenizer** (`lex.mbt`) — strings, template literals with `${}`
  interpolation, regex literals, comments, identifiers and punctuators.
- **Structured parser** (`parse.mbt`) — import/export statements, binding
  names, usage positions and relative specifiers per file.
- **Cross-file analysis engine** (`analysis.mbt`) — builds a project index,
  resolves relative specifiers, constructs the import graph, and evaluates
  eight structural checks:
  - `no_unused_imports` — an imported binding is never referenced
  - `no_duplicate_imports` — the same module imported twice
  - `no_unresolved_relative_imports` — a relative import resolves to nothing
  - `no_import_cycles` — reported per file in a relative-import cycle
  - `no_default_export` — `export default` usage
  - `no_deep_relative_imports` — `../` climbing beyond a limit
  - `no_require_imports` — `require()` in an ES module codebase
  - `no_unused_exports` — an exported name no scanned file imports
- **`structural_rules` config array** — project-level rules with the same
  severity / message / extensions / scope fields as line rules; supported in
  `extends` inheritance and de-duplicated with line rules by id.
- **`imports` preset** (`--preset imports`, plus `presets/imports.json`) —
  the seven structural checks above (minus `no_default_export`) ready to run.
- **Matcher combinators** — `match` and `unless` now accept
  `{"all": [...]}`, `{"any": [...]}` and `{"not": {...}}`, nested arbitrarily
  deep, so a rule can express any boolean formula over the leaf matchers.
  Nested regexes are compiled once per rule like any other, and a malformed
  sub-matcher is reported with its index in the config error.
- **Incremental caching** — `--incremental` re-lints only files whose content
  hash changed; `--cache-file` chooses the location (default
  `.moonlint-cache.json`). The cache stores a fingerprint of the effective
  config, so any rule change invalidates all entries; a missing, corrupt or
  version-mismatched cache degrades to a full scan with a warning.
- Structural findings respect inline `// moonlint-disable` comments and rule
  scopes, exactly like line findings.

### Changed

- `--watch` / `--watch-interval` remain unsupported, but the rejection message
  now points at `--incremental` for fast repeated scans.
- The starter config written by `--init` demonstrates the combinator DSL.
- README documents the structural rules, the matcher DSL, incremental caching
  and the new module layout.

### Tests

- 270 whitebox unit tests: 265 pass on the wasm-gc target; the 5 failures are
  the known native filesystem/Git-bridge tests that wasm cannot run.
- 160 CLI integration test methods across 9 phases, including 15 new tests
  for incremental caching and structural rules, 6 new tests for the matcher
  DSL, and the updated watch-rejection expectations.

[0.2.0]: https://github.com/ximo-156/wot-lynx-ui-moonbit
