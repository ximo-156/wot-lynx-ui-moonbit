# MoonImpact

MoonImpact is a **change-impact and regression-test planning tool**, implemented
in MoonBit. It reuses moonlint's source and filesystem foundations, but it does
not check naming, formatting, documentation or release policy.

Given changed files, it answers:

- Which test files have a known dependency on this change?
- What reference chain explains each selection?
- Why must this run fall back to the full suite, or be blocked?

A plan is advisory, **not a test result or a proof that unselected tests cannot
fail**. No tests, builds or installations run unless `--run` is supplied.
MoonImpact does not install Node.js, pnpm, Vitest or any project dependencies.

## Build and try the local demo

From this repository's root:

```sh
moon build --target native
BIN="$PWD/_build/native/debug/build/cmd/impact/impact.exe"

# Module dependency: fees -> summary -> its test, plus the direct fee test.
"$BIN" plan --file src/fees.ts \
  --config examples/impact-demo/moonimpact.json examples/impact-demo

# File input dependency: the stylesheet is read by a test, not imported.
"$BIN" plan --file src/theme.css \
  --config examples/impact-demo/moonimpact.json examples/impact-demo

# JSON for CI, or standalone HTML with no external assets/scripts.
"$BIN" plan --file src/theme.css --format json \
  --config examples/impact-demo/moonimpact.json examples/impact-demo
"$BIN" plan --file src/theme.css --format html \
  --config examples/impact-demo/moonimpact.json examples/impact-demo > impact-demo.html
```

The executable currently targets **macOS/Linux native**, like the existing
moonlint filesystem bridge. The old `cmd/main` moonlint entry is preserved.

## Change input

Choose exactly one input mode:

| Option | Meaning |
| --- | --- |
| `--file <path>` | Explicit root-relative changed path, repeatable; paths are not silently extension-filtered. |
| `--worktree` | Changes from HEAD to the live working tree, including staged, unstaged and non-ignored untracked files. |
| `--base <ref>` | Changes from the specified commit to the live working tree, including untracked files. This is a direct commit comparison, not merge-base PR semantics. |

The root defaults to the current directory. Git modes currently require the
**Git repository root**. Unknown references and Git failures exit 2 rather than
claiming an empty change set. Git change collection does not run repository
hooks or external diff/textconv commands. Repositories with configured Git
clean/process filters are refused with exit 2; use explicit `--file` input or
remove the executable filter before using Git input, since Git diff could
otherwise invoke it while examining worktree content. Renames are represented by both old
and new paths; missing/deleted inputs request full regression because MoonImpact
does not reconstruct the previous dependency graph.

These modes intentionally differ from moonlint's HEAD/index blob scan modes.
Analysis always reads a **live working tree**, not an atomic repository snapshot;
avoid concurrent Git/source changes while planning or executing tests.

## Configuration

Only an explicit `--config` path is loaded. Configuration is inert JSON: no
JavaScript config execution, arbitrary command templates or dependency installs.
Paths, aliases and patterns are relative to the analyzed project root, **not**
to the configuration file's directory.

```json
{
  "version": 1,
  "include": ["src/**", "test/**"],
  "exclude": ["src/vendor/**", "**/*.min.js"],
  "tests": ["test/**/*.test.ts", "test/**/*.spec.ts"],
  "aliases": {"@": "src"},
  "file_readers": ["readSource"],
  "dependencies": [
    {"dependent": "test/theme.test.ts", "dependency": "src/theme.css"}
  ],
  "max_source_bytes": 2000000
}
```

- Without `include`, all non-noise directories participate; the default noise
  directories (`.git`, `node_modules`, `dist`, `target`, `_build`,
  `.mooncakes`, `coverage`, `.rspeedy`, `.vitepress`, `.preview`) are not
  traversed. `skip_dirs` replaces that list for projects whose tests genuinely
  read conventional build output.
- **Membership is the whole tree; analysis is scoped.** Every regular file
  minus noise directories is known membership, so a read or import of an
  out-of-scope file resolves to a real leaf input. `include`/`exclude` decide
  which files are parsed as sources. A changed file that nothing reads or
  imports is reported as an unmodeled input; a changed file with a known
  consumer — even outside the analysis scope — plans normally.
- Default tests are `*.test` / `*.spec` in JS/TS-family extensions. Their glob
  paths support `*`, `?` and whole-segment `**`, not brace expansion.
- Alias prefixes match segment boundaries and the longest prefix wins. An
  `@` mapping does not capture npm packages such as `@scope/package`.
- `file_readers` explicitly declares simple wrapper names whose **first
  argument is a project-root-relative input path**. For example,
  `readSource('src/theme.css')`. This is a user-supplied contract, not a proof
  about an arbitrary function's implementation. Calls with nonliteral paths
  remain uncertain. The adapter may suppress dynamic reads inside a recognized
  configured wrapper definition; callers are still checked individually.
- `dependencies` adds exact manual edges with `kind: explicit` and no fabricated
  source coordinates (`line`/`column` zero). A dependency may also be a **glob**
  (`*` / `?` / whole-segment `**`), expanded against current membership; each
  match becomes its own edge and a glob matching nothing is reported rather
  than silently empty. Declaring a file asserts that the declarations cover its
  unprovable reads — manifest-driven helpers and build scripts are the intended
  use — so that file's uncertainty issues are suppressed while I/O and safety
  failures still block. Under-declaring silently misses dependencies: verify
  the declarations against the real reads.
- `style_load_paths` lists root-relative directories tried after the importing
  file's own directory, mirroring Sass `loadPaths`. Both bare specifiers
  (`@use 'styles/variable.scss'`) and `../`-style facade forwards that only
  resolve through a component load path are supported; relative resolution
  still wins, and an ambiguous or unresolved result stays an uncertainty.
- `runner_dir` names the directory the test runner is configured in, for
  monorepos whose Vitest config is not at the analysis root. It affects only
  `--run` execution: the test process runs there and selected test paths are
  passed relative to it.
- `global_inputs` can override the default full-regression triggers: package
  manifests/lockfiles, Vite/Vitest/TypeScript configs, common setup files,
  environment files, the conventional Vue app entry, and `moonimpact.json`.
- A supported code or CSS/SCSS source over `max_source_bytes` is not parsed and
  causes fallback; the limit is checked after reading bytes. JSON, fonts and
  images remain membership/leaf inputs and are not decoded as JavaScript or CSS.
- Invalid/unknown config fields, duplicate keys, unsafe paths, invalid test
  globs and invalid numeric limits are rejected.

## Static file-reading adapters

File reads are resolved symbolically; project code is never evaluated to find
paths. The adapter distinguishes root-relative strings from paths based on the
source module's directory.

Supported forms include direct literal fs reads, imported path `join`/`resolve`
with fixed segments and a known base (`process.cwd()` or unshadowed `__dirname`),
and a static `new URL('./input', import.meta.url)`, optionally converted using
an actually imported `fileURLToPath`. Supported immutable top-level constants
can carry these known values. URL schemes, encoding/query/fragment forms that
cannot be safely resolved remain uncertainty rather than guessed file paths.

A small, **proved** single-return wrapper may also be inferred without adding
its name to `file_readers`:

```ts
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
const ROOT = process.cwd()
function read(file: string) {
  return readFileSync(resolve(ROOT, file), 'utf8')
}
const page = read('src/Page.vue')
```

This inference is intentionally narrower than general function analysis: the
callee must be an actual fs import, the parameter/path relationship must be
known, and extra statements, additional I/O, computed parameters, shadowing or
rebinding must not be hidden. Call sites still need statically known inputs.
Explicit `file_readers` configuration remains a separate user-supplied contract;
an arbitrary function is not trusted merely because it is named `read`.

Raw reads treat a file as data, not as a module to execute. Reading the text of
a root configuration file outside `include` does not require parsing its own
imports, provided that exact file is in known membership. This does not expand
the directory scope or follow symlinks. Raw filesystem filenames retain literal
`?` and `#`; URL cleanup is not applied to them.

## Stylesheet dependencies

In-scope CSS and SCSS files are parsed with a dedicated static scanner, not the
JavaScript parser. Vue inline styles use the same scanner while preserving
source-file coordinates. Static imports, Sass module references and asset URLs
can therefore form a transitive chain:

```text
font.woff2 -> fonts.css -> theme.scss -> Card.vue -> card.test.ts
```

- CSS `@import`, static `url(...)`, SCSS `@use` / `@forward` and literal import
  lists are recognized. Comments and quoted prose do not become dependencies.
- Configured aliases work for local stylesheet and asset references. Sass
  partials (`_name.scss`) and index modules are considered; ambiguous choices,
  legacy `.import.scss` precedence and custom importer/load-path assumptions
  remain full fallback.
- CSS URL query/fragment suffixes do not alter the underlying asset path. Remote
  HTTP(S)/data URLs and local fragment URLs are not read from disk. `sass:`
  builtins and scoped Sass npm packages are external dependencies governed by
  package/lockfile changes; node_modules is not recursively analyzed.
- Dynamic interpolation/variables, escaped or percent-encoded local paths that
  are not decoded, unknown protocols, unresolved paths and root-absolute web
  URLs without a mapping remain explicit uncertainty.
- Only CSS/SCSS are parsed. Other preprocessors remain unsupported. Missing,
  excluded or unparsed stylesheet bodies never authorize selective execution.
- Transitive analysis remains within configured filesystem scope. Referenced
  fonts/images are leaf inputs, not decoded as text. Style read/encoding
  failures block execution just like code-source failures.

## Dependency coverage and conservative fallback

The planner covers static imports, re-exports and supported literal module calls,
plus supported file-read forms and explicitly configured reader wrappers.
Vue SFC adapters distinguish real script regions from template text, and keep
reference positions in the original file; a file-level `/* */` or `//` header
before the first block is skipped like an HTML comment. This is **not** the Vue
compiler, TypeScript type checker, complete binding resolver or a universal
dynamic-I/O tracer. JSX/TSX currently request fallback rather than pretending
JSX text is JavaScript. Static CSS/SCSS and supported Vue style blocks use the
stylesheet adapter above; dynamic stylesheet inputs and unsupported preprocessors
still request full fallback.

Three further input forms are modeled:

- **Directory reads.** `readdirSync`/`readdir` with a provable path becomes a
  dependency on every current entry beneath that directory. Adding, removing
  or editing any entry changes the plan; the reader is never assumed to depend
  on a fixed file list.
- **Existence checks.** `existsSync`/`statSync`/`accessSync` with a provable
  path depend on that path whether or not it exists now, so creating or
  deleting it later still reaches the reader.
- **Literal `import.meta.glob` patterns.** A literal pattern (including the
  legacy `globEager` spelling) expands to the modules it currently names;
  computed patterns stay uncertainty. Matches outside the analysis scope are
  leaf inputs whose own dependencies are not analyzed.

Unsupported dynamic imports/reads, unresolved local aliases, ambiguous module
resolution, unknown source constructs and excluded source dependencies are
reported as uncertainties. They request all tests, rather than silently turning
an absent edge into a confident no-impact answer. Extra full-suite fallbacks are
preferable to unsupported selective execution.

| Strategy | Behavior |
| --- | --- |
| `related` | Select inventoried tests reachable from changed inputs; attach one deterministic shortest known chain to each. |
| `full` | Report why selective analysis is inconclusive or a global input changed; `--run` requests Vitest's full suite. |
| `none` | No changes, or no known reachable tests under the configured supported model. No test command is run. This is not a full-suite pass. |
| `blocked` | Source I/O/encoding/unsafe-path failures, or no usable test inventory. Do not execute. |

Full fallback can include tests without an evidence chain. Those tests are not
claimed to be proved affected. Vitest may discover tests outside MoonImpact's
configured inventory when running its full suite. Regular full-suite validation
is still needed; compare against your actual runner configuration before using
selective runs as a CI optimization.

MoonImpact builds a fresh dependency graph. It **does not reuse moonlint's cached
structural verdict**: the graph, file-input dependencies and test inventory have
a different identity and correctness contract.

## Explicit test execution

After reviewing the plan, add `--run` in a trusted project with pnpm/Vitest and
its dependencies already installed:

```sh
"$BIN" plan --file src/fees.ts --run --timeout-ms 60000 \
  --config examples/impact-demo/moonimpact.json examples/impact-demo
```

The process uses fixed argv (`pnpm exec vitest run` plus separate `./test-path`
filters), not shell command interpolation. Full fallback deliberately omits
filters. Empty related selections never accidentally invoke the full suite.
Child stdout/stderr go to stderr so JSON/HTML plan output remains parseable.
Test processes run with your permissions and may perform the normal side effects
of project tests; `--run` is **not** a sandbox.

Monorepos often configure the runner in a package directory rather than the
analysis root. `runner_dir` names that directory: the test process runs there
and each selected test path is passed relative to it. A selected test outside
the runner directory is a configuration error, never a silently dropped
filter — the runner cannot address a path it cannot see.

`--report <new-file>` additionally publishes the JSON plan with atomic,
create-only semantics. Its parent must exist; existing files, directories and
symlinks are not replaced. Use a new filename for each report.

Exit codes:

- `0`: a nonblocked plan was produced; when a test process actually ran, it
  exited successfully. A default plan-only exit 0 does **not** mean tests passed.
- `1`: the explicitly started test process exited unsuccessfully.
- `2`: usage/config/Git/I/O/startup/timeout error or blocked plan.

## Real-project measurement

A read-only evaluation against the public
[wot-lynx-ui](https://github.com/ximo-156/wot-lynx-ui) monorepo (982 analyzed
sources, 11,929 known edges, 135 test files / 2261 tests) with the two explicit
changes `packages/core/src/common/formatDate.ts` and
`packages/core/src/common/host.ts`. The configuration used is
[`examples/impact-wot-lynx-ui.json`](<../examples/impact-wot-lynx-ui.json>);
the measurements below are reproducible with it.

| Change | Strategy | Selected | Notes |
| --- | --- | --- | --- |
| `formatDate.ts` | related | 71 / 135 | dedicated unit test plus transitive component and parity tests |
| `host.ts` | related | 101 / 135 | `configureHost` is imported across the suite |

The same project previously measured 618 sources / 2,241 edges / 319
uncertainties and fell back to `full` on every change; the coverage above is
what turned those measurements into selective plans. The project's
manifest-driven test helpers (`component-roots.ts`, build scripts under
`scripts/`) read trees their arguments name at runtime, so the demo
configuration declares those reads explicitly with the `dependencies` contract
— the plan reports `declared-dependencies: 64 uncertainties covered by explicit
contracts` whenever it relies on them. Every declaration was verified against
the code it covers.

Execution evidence (clean working tree, `vitest run` from `packages/ui`):

| Run | Test files | Result | Wall time |
| --- | --- | --- | --- |
| Full suite | 135 | 3 pre-existing failures, 2185 passed | 37.1s |
| Selected subset (formatDate change) | 71 | same 3 failures, 1398 passed | 20.9s |
| Selected subset, injected `getFirstDayOfWeek` off-by-one | 71 | 4 failures — the format-date test catches the fault | 21.3s |
| Full suite, same injected fault | 135 | 4 failures — same catch | 39.7s |

The subset rows were produced through the tool itself with
`--run` (the shipped configuration sets `runner_dir` to `packages/ui`, where
that project configures Vitest), so the table is reproducible end to end:

```sh
moon build --target native
BIN="$PWD/_build/native/debug/build/cmd/impact/impact.exe"
"$BIN" plan --file packages/core/src/common/formatDate.ts --run \
  --config examples/impact-wot-lynx-ui.json /path/to/wot-lynx-ui
```

The three pre-existing failures are component-inventory mismatches caused by
duplicate component directories in that local working tree; they are unrelated
to the change and appear identically in both runs. The injected fault was
reverted after measurement. Selective selection is conservative: not every
selected test is asserted to fail when an input changes.

## Verification

```sh
moon check --target native --no-mbti
moon test --target native
moon build --target native
python3 tests/impact_integration.py \
  --binary "$PWD/_build/native/debug/build/cmd/impact/impact.exe"
python3 tests/impact_native.py
# Optional: point at an existing trusted Vitest package; no installation occurs.
python3 tests/impact_vitest_smoke.py \
  --binary "$PWD/_build/native/debug/build/cmd/impact/impact.exe" \
  --vitest-dir /path/to/installed/node_modules/vitest
# Keep the original moonlint regression suite too:
python3 tests/integration.py \
  --binary "$PWD/_build/native/debug/build/cmd/main/main.exe" --phase all
```

Tests use owned temporary directories and a fake local pnpm executable to
verify process arguments and safety without installing dependencies or running
business-project tests. The demo is synthetic and contains no unibest source,
private endpoints, customer data or credentials. Real-project evaluation should
be local and read-only unless test execution is separately requested.
