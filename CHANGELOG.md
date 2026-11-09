# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Added

- **`aliases` config option** — an object mapping a bare-specifier prefix to a
  root-relative directory (`{"aliases": {"@": "src", "~": "."}}`), so path
  aliases such as `@/api/ka` resolve during cross-file analysis. Without it
  `no_unused_exports` treated every alias-imported export as dead; on a real
  Vue/TS project this cut the finding count from 628 to 247 with only ~15
  residual false positives (mostly TS type imports), and resolved 929 alias
  imports. Alias targets are relative to the scan root; prefixes match on a
  segment boundary (`@` matches `@/x` but not `@scope/pkg`), longer prefixes
  win, and escaping/absolute targets are rejected as config errors. Alias
  resolution is threaded through new `*_with` scan entry points; the original
  public signatures remain as wrappers with an empty alias set.
- **Vue template bindings count as usages** (`vue_template.mbt`) — a `.vue`
  file keeps expressions inside HTML attribute strings (`:src="logo"`,
  `v-if="canRun(item)"`, `@click="onTap"`). The JS tokenizer sees a string
  literal, so a binding used only in a template looked unused. The scanner now
  extracts those binding values (nested `<template>` supported, `<script>` and
  `<style>` blocks masked) and adds their identifier reads to the file's usage
  list. On the real project this removed every remaining `no_unused_imports`
  false positive (19 → 0).
- **`match_literals` rule option** — the default code view now blanks the
  contents of string, template and regex literals in JavaScript/TypeScript/JSX
  sources (delimiters and `${...}` interpolations preserved), so a line rule
  never matches literal text. A rule whose target only exists as a literal
  value opts into the literal view with `"match_literals": true`; the option
  takes part in the incremental cache fingerprint. Twelve shipped preset rules
  use it (`react/jsx-no-target-blank`, `react/jsx-no-script-url`,
  `next/no-html-link-for-pages`, `next/no-css-tags`,
  `next/google-font-display`, `next/no-unwanted-polyfillio`,
  `vue/no-target-blank`, `vue/no-useless-mustaches`,
  `vue/prefer-true-attribute-shorthand`, `solid/no-react-imports`,
  `nuxt/prefer-auto-imports`, `angular/relative-url-prefix`).
- **MoonBit source front end** (`moonbit_lang.mbt`) — MoonBit files are
  scanned for top-level `fn` / `struct` / `enum` / `type` / `trait` / `let` /
  `const` / `impl` / `test` declarations. Comments and string literals are
  blanked before brace-depth tracking, so bodies do not produce false
  top-level items; `///|` blocks are attached to the declaration that follows
  them, including across `#...` attribute lines.
- **`moonbit` preset** — `moonbit/require-public-doc` and
  `moonbit/naming` structural checks, plus `moonbit/no-unwrap`,
  `moonbit/no-panic`, `moonbit/no-println` and `moonbit/no-todo-comment` line
  rules. The preset excludes `*_test.mbt` and `*_wbtest.mbt` recursively:
  tests may unwrap, panic and print. `cmd/**` is excluded from `no-println`
  because CLI entry points print by design. `presets/moonbit.json` is the
  standalone copy.
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
  The repository's own config excludes `examples/**` from its scope.
- **Incremental cache walkthrough in `examples/README.md`** — documents the
  fourth layer end to end: which findings the cache stores per file (the
  line and file rules: 2 for `app.ts`, 1 for `helpers.ts`), why the four
  structural findings are deliberately re-derived every run (a dead-export
  answer can change when an unrelated file is edited), and how content-hash
  keying keeps the cache valid across byte-identical rewrites.

### Changed

- **JS/TS line rules no longer match literal text.** The code view blanks the
  contents of string, template and regex literals, aligning the JS/TS line
  matcher with the MoonBit front end. Rules that must see literal values opt
  in with the new `match_literals` option; the shipped presets that need it
  already carry it. `Plain`-mode sources (`.vue`, `.svelte`, `.astro`,
  unknown extensions) are unchanged: they have no literal-aware scanner.
- **`lint_lines` takes three views** — code, literal and raw — instead of two.
  The engine picks the view per rule (`match_comments` > `match_literals` >
  code view). This is a source-compatible-breaking change for external callers
  constructing views themselves, consistent with the 0.x interface policy.
- **A regex literal after `=` is recognised.** `const re = /x/` was scanned as
  division, because the keyword-based `regex_ok` flag still saw the identifier
  before the `=`; the previous significant character now decides, so the
  common assignment shape blanks its regex body like any other literal while
  `total / 2` stays division.
- **`${...}` interpolations are code.** The state machine returned to the
  template body after `${`+`{`, so comments, strings and nested templates
  inside an interpolation were treated as template text — a comment inside
  `${...}` survived stripping, and the interpolation brace-depth tracking was
  unreachable. The `}` that closes an interpolation now returns to the
  template body, as the depth machinery always intended.
- **MoonBit is the primary target.** The root `moonlint.json` now extends
  `presets/moonbit.json` and excludes `examples/**`; `moonlint .` lints the
  repository's own MoonBit sources with no findings. `--init` writes a MoonBit
  starter config instead of a JS/TS one. The JS/TS presets remain for mixed
  repositories and are documented as a compatibility layer.
- **`moonbit` preset false positives fixed.** `no-println` no longer matches
  `eprintln` and skips `cmd/**`; `no-todo-comment` matches only TODO/FIXME at
  the start of a comment; test-file exclusions are recursive
  (`**/*_test.mbt`, `**/*_wbtest.mbt`).
- **Removed `ScanMode::incremental`.** The deprecated variant always raised;
  `--incremental` is the supported cache path. `\x00` literals were replaced
  with `\u{0}`.
- **Vue preset regex compatibility.** `vue/prefer-true-attribute-shorthand`
  escapes the hyphen in its character class; the current MoonBit regex engine
  rejects the unescaped form.

### Fixed

- **Spread syntax no longer hides a usage.** The tokenizer emits one `Punct`
  per character, so `...foo` has a `.` immediately before `foo` exactly like
  `.foo` does; the usage walker skipped both as property names, so a binding
  used only through `{ ...foo }` looked unused. `is_property_name` now checks
  the dot before the dot. On a real Vue/TS project this removed 16 of 19
  `no_unused_imports` findings, all false positives.
- **Semicolon-less declarations no longer swallow the next statement.** The
  initializer skip in `parse_var_decl` ran to the next `,` or `;`, ignoring
  line breaks, so `export const a = 1` + newline + `export const b = 2` yielded
  one export and could even report a swallowed token as a bogus export name
  (`'string'`). The walk now ends at a line break at bracket depth 0, matching
  automatic semicolon insertion. On the same project this recovered 180
  exports that had been invisible to `no_unused_exports`.
- **String, template and regex literal text no longer matches line rules.**
  The two CLI integration cases `test_string_literal_text_is_not_code` and
  `test_template_literal_text_is_not_code` were carried as
  `@unittest.expectedFailure` "known defects"; both now pass as ordinary
  tests and the suite reports zero expected failures. Comments inside
  `${...}` interpolations are blanked by the same change.
- **A regex literal after `=` is recognised** (`const re = /x/` was scanned as
  division), and **`${...}` interpolations are scanned as code**, so nested
  strings, nested templates and comments inside them behave like code.

### Tests

- 395 whitebox unit tests pass on the native target (12 new: code-view
  literal blanking, interpolation handling, regex/division disambiguation,
  `match_literals` parsing, cache fingerprinting and the literal-view preset
  contract).
- 174 CLI integration test methods across 11 phases, with **zero**
  `expectedFailure` markers: the two former known-defect cases now pass, and
  new cases cover regex literals, interpolations, the `match_literals` opt-in
  and the react preset's attribute-value rule end to end.

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
