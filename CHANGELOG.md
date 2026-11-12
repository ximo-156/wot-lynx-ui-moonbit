# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### MoonBit module planning

MoonImpact now plans MoonBit modules natively: without `--config`, a root
holding `moon.mod`/`moon.mod.json` is analyzed as a package graph read from the
`moon.pkg` manifests themselves — no toolchain invocation, no project code
executed. A changed file selects the packages that own it plus every package
that transitively imports them; `--run` invokes `moon test` per selected
package. Every module under the root is discovered, so nested and workspace
modules resolve imports against their own module, and every `import` block
counts — plain, `for "test"` and `#cfg`-conditional alike.

- The plan keeps the advisory contract: an unparseable manifest, a missing
  module descriptor or an unmodeled change requests every package; a manifest
  or descriptor change is a global input. The module root package is addressed
  as `.` by the runner.
- Verified on this repository (root package plus `cmd/main`, `cmd/impact` and
  four example modules) and by read-only planning of the public
  [moonbitlang/x](https://github.com/moonbitlang/x) monorepo: a `decimal`
  change selects 1 of 19 test-holding packages; an `encoding` change selects
  4 of 19 through importers whose dependency is declared `for "test"`.
- Cold-cache measurement on this repository: a full `moon test` after
  `moon clean` takes 5.4s and runs 555 tests; a CLI-only change plans `none`
  and `moon test` for the selected package takes 2.1s and runs no library
  tests.
- **Symlinked documents no longer block every plan.** A non-regular file is
  refused only when its content can matter — a source, stylesheet or manifest;
  a linked `README.md` stays membership data. Four linked READMEs in
  moonbitlang/x previously blocked all of its plans.
- The MoonBit planner is split into a filesystem wrapper and a pure planning
  function, so the package graph, strategies and evidence chains are
  unit-tested without a toolchain.


### MoonImpact real-project selective planning

Verified end to end on the public
[wot-lynx-ui](https://github.com/ximo-156/wot-lynx-ui) monorepo (135 test
files, 2261 tests) with the shipped
[`examples/impact-wot-lynx-ui.json`](<examples/impact-wot-lynx-ui.json>): a
change to `packages/core/src/common/formatDate.ts` produces a `related` plan
selecting 71 of 135 test files. The clean tree runs the full suite in 37.1s and
the selected subset in 20.9s; an injected `getFirstDayOfWeek` off-by-one is
caught by the selected subset (and by the full suite), and reverting it
restores green. The same three pre-existing failures — caused by duplicate
component directories in the local working tree, unrelated to the change —
appear in both runs.

- **`runner_dir` configuration** names the directory the test runner is
  configured in, for monorepos whose Vitest config is not at the analysis
  root. Selected test paths are passed relative to it; a selected test
  outside it is a configuration error rather than a silent miss.

### MoonImpact coverage and configuration

- **Membership is the whole tree; analysis stays scoped.** The file walk no
  longer stops at the configured `include` boundary: every regular file minus
  noise directories is known membership, so a read or import of an
  out-of-scope file resolves to a real leaf input. Which files are parsed as
  sources is still decided by `include`/`exclude` alone. Previously a test
  reading `docs/` or `scripts/` was reported as an unresolved input purely
  because the walk never entered those directories.
- **`style_load_paths` configuration** models Sass `loadPaths`: bare and
  `../`-style specifiers that do not resolve next to the importing file are
  tried against each configured root-relative directory, in order, exactly
  like the build's sass option. Relative resolution still wins.
- **`skip_dirs` override** replaces the default noise-directory list for
  projects whose tests genuinely read conventional build output (for example
  a docs `.vitepress` theme fixture). The default list now also skips
  `.pnpm-store`: a local 1.3GB pnpm content store was previously walked in
  full, costing 8.3s of a plan whose result is byte-identical without it
  (2.5s).
- **Glob dependency declarations.** A `dependencies` entry may name a glob;
  each current membership match becomes its own edge. A glob matching nothing
  is reported, never silently empty. Declaring a file also asserts that the
  declarations cover its unprovable reads, so that file's uncertainty issues
  are suppressed while I/O and safety failures still block. This is the
  documented contract for manifest-driven helpers and build scripts whose
  reads are known but not statically provable.
- **Static directory reads and existence checks are modeled.**
  `readdirSync`/`readdir` with a provable path becomes a `read-dir`
  reference: the reader depends on every current entry beneath that
  directory. `existsSync`/`statSync`/`accessSync` with a provable path becomes
  an `exists` reference that also covers paths that do not exist yet.
- **Literal `import.meta.glob` patterns are modeled.** A literal pattern
  (including the legacy `globEager` spelling) becomes a `glob-import`
  reference expanded against current membership; computed patterns stay
  uncertainty. Matches outside the analysis scope are leaf inputs.
- **Vue single-file components may open with a `/* */` or `//` header.** The
  top-level scanner previously reported every line of such a file as
  unsupported text; the comment is now skipped like an HTML comment.
- **Stylesheet interpolations no longer request fallback by themselves.** An
  interpolation cannot name a stylesheet: only `@use`/`@import`/`@forward`
  load files, and they already reject non-static paths themselves. Values,
  selectors and at-rule preludes are skipped, an unterminated interpolation
  still blocks, and a prelude interpolation still marks its block dynamic.
- **User-visible arrays are ordered lexicographically.** MoonBit's String
  comparison is length-first — a valid total order, but `mts/…` sorting
  before `component/…` surprises readers. Paths, the test inventory, the
  selected set, affected nodes, edges and issues now read like a directory
  listing; selection itself is unchanged.
- **Glob expansion is prefix-filtered.** Declared globs test their literal
  prefix before the full pattern, keeping large-tree expansion affordable
  (the wot-lynx-ui plan runs in about 2.5s for 982 analyzed sources).
- **Stability audit suite** (`tests/impact_stability.py`, read-only, wired into
  CI against a fresh clone of the public evaluation project): a 60-file
  change-input sweep with plan invariants, byte-identical repeated runs, Git
  input modes, degenerate inputs, create-only reports and a timing bound. The
  audit found the length-ordering and pnpm-store defects above.

### MoonImpact static input coverage


- Infer bounded immutable path constants and narrowly proved single-return
  filesystem readers, without trusting arbitrary `read`/`ROOT` names. Support
  module-relative `__dirname`, static `new URL(..., import.meta.url)` and genuine
  `fileURLToPath` imports while retaining full fallback for mutable/shadowed or
  escaping bindings, dynamic arguments, extra I/O and unsafe path semantics.
- Add a pure CSS/SCSS frontend for static imports, Sass modules/partials and
  asset URLs, including Vue inline/external styles and transitive evidence.
  Unknown preprocessors, custom importer ambiguity, dynamic styles, unresolved
  assets and out-of-scope stylesheet bodies remain explicit uncertainty.
- Preserve raw file-read names containing `?`/`#`; URL cleanup applies only to
  stylesheet URLs. Raw reads of known out-of-scope source/config files are
  opaque leaf inputs rather than an instruction to execute their imports.
- Guard recursive path evaluation and normalization-sensitive dirname forms;
  configured aliases that escape the root are not mistaken for npm packages.

### MoonImpact MVP

- Added an independent `cmd/impact` CLI for change-impact and regression-test
  planning. The existing moonlint CLI remains available at `cmd/main`.
- Added strict inert configuration, explicit/Git working-tree change input,
  reverse dependency traversal, one deterministic shortest evidence chain per
  related test, and related/full/none/blocked strategies. Missing/deleted or
  unmodeled inputs and unsupported dependency forms never silently authorize
  selective execution; source I/O failures block execution.
- Added static import and Vue script adapters, supported fs file-reading forms
  and explicitly configured root-reader wrappers, with conservative uncertainty
  reporting for dynamic paths, shadowed bindings and unsupported SFC features.
- Added text/JSON/script-free HTML plan reports; JSON report files are atomically
  created without overwriting existing paths. Plans are not test results.
- Added explicit `--run` support for fixed-argv local `pnpm exec vitest run`,
  stdout-to-stderr forwarding and process-group timeout cleanup. Planning does
  not execute project code or install packages. Git clean/process filters are
  refused rather than executed implicitly during change collection.
- Added isolated unit, CLI and native bridge regressions plus a synthetic
  charging-fee/stylesheet demo. No unibest business sources are included.

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

- **Structural findings materialize each snippet once per file line.**
  `snippet_at` re-split and re-trimmed the source for every finding, which on a
  minified file meant trimming a 1.3MB line hundreds of times: `no_require_imports`
  alone cost 0.49s on a 336-file project where the check itself is trivial.
  Snippets are now memoized per `(file, line)`. The full seven-rule structural
  pass dropped from 3.17s to 1.33s CPU (−58%), and the `imports` preset's
  uncached run from 2.55s to 1.49s (−42%), with byte-identical findings.
- **The structural verdict is reused for an unchanged tree.** A full-tree scan
  now caches the whole cross-file result, keyed by the rule fingerprint plus
  every participating file's content digest. A repeated `--incremental
  --preset imports` run on an unchanged 336-file Vue/TS tree skips the context
  read and the analysis: **2.28s → 0.26s CPU (−89%)**, with byte-identical
  findings. Any edit, addition, deletion or rule change alters the key and
  forces a recompute, and partial scans (scope exclusions, `--glob`,
  `--stdin`, `--changed`, `--staged`) are never reused this way because their
  dependency context is not part of the key. Cached structural findings omit
  snippets — a single minified line can exceed the whole cache — and snippets
  are re-derived from the scanned source, so reports stay identical.
- **An empty selection skips the dependency context.** Cross-file rules read
  unselected dependencies as context; when nothing is selected the project
  pass can only report on selected files, so reading the tree was pure waste
  (and turned an unrelated unreadable file into exit 2). An empty
  `--glob`/`--stdin`/scope selection now finishes without touching context:
  2.3s → <0.01s on a 336-file project, with `context_files_scanned`/`_failed`
  honestly reported as 0.
- **Structural models are cached.** `--incremental` now stores each file's
  parsed structural model (imports, exports, used names) keyed by content
  hash, so a repeated `--preset imports` scan skips tokenizing and parsing
  unchanged files. Cross-file findings are still re-derived every run — a dead
  export can become live when another file changes — but on a 336-file
  Vue/TS project the full `imports` preset dropped from 2.8s to 1.5s CPU
  (−47%), and a single structural rule from 1.52s to 0.28s (−82%). Models are
  rule-independent (they survive a config change), content-validated, and
  carry a parser generation so a front-end fix invalidates stale models while
  keeping per-file findings. The cache format version moved to 3.
- **`no_duplicate_lines` compares substantive lines only.** A minimum trimmed
  length (24 by default, configurable as `{"no_duplicate_lines": 40}`, `0` for
  the old behaviour) keeps structural lines such as `}`, `</view>`, `/**` and
  `return` out of the report. On a real Vue/TS project this cut the `file`
  preset from 24,159 to 3,727 findings (−85%); `no_duplicate_lines` alone went
  from 22,870 to 2,445.
- **`no_unused_exports` exempts ambient `.d.ts` files.** Declaration files
  describe the environment; nothing imports their declarations at runtime.
- **Performance: one MoonBit lex per file.** The engine used to lex every
  `.mbt` file about six times (validation, inline disables, code view, comment
  view, project pass, declaration scan). It now lexes once and shares the view,
  and the declaration scanner accepts a precomputed view. Measured on a
  57-file MoonBit tree: the line-rule path dropped 0.68s → 0.40s (−41%), the
  structural path 0.58s → 0.40s (−31%).
- **Performance: the raw view is only split when something reads it.** The
  per-line raw view (one string per line) is now built only when a
  `match_comments` rule or a file rule exists. On a 336-file TS/Vue tree a
  single-rule scan dropped 0.84s → 0.47s (−44%).
- **Performance: `split_lines` avoids a per-line character array.** A CRLF
  trim is only attempted when the line actually ends in `\r`.
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

- **Type annotations are no longer exported as names.** `parse_var_decl`
  recorded every identifier in a declaration head, so `export const a: Foo = 1`
  also exported `Foo` (and `Map`, `string`, `number` for generics). Type
  annotations are now skipped, including generic argument lists and function
  types. On the real project this removed 11 of 247 dead-export findings.
- **Unknown top-level config fields are rejected on the CLI path.** The
  CLI loads configs through `parse_config_with_extends`, which lacked the
  `config_fields` check that `parse_config` performs, so `{"bogus": 1}` was
  silently accepted even though the documented contract and the unit tests
  reject it. Both paths now fail with exit 2 and `config: unknown field '…'`.
- **A corrupt or outdated cache now warns.** The README promises that a
  missing, corrupt or version-mismatched cache "degrades to a full scan with a
  warning"; the fallback was correct but silent. A non-empty cache file that
  fails to parse now prints `ignoring unreadable or outdated cache file …;
  running a full scan` on stderr.
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
