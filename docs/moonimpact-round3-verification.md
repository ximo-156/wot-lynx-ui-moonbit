# MoonImpact round three: whole-tree membership and real-project selective planning

This records a local working-tree verification, not a release, remote CI result
or a guarantee of selective test safety on arbitrary projects. The
[round-two record](<moonimpact-round2-verification.md>) is retained separately;
its unibest measurements predate this work and must not be compared directly.

## What changed

- **Membership is the whole tree; analysis stays scoped.** The walk no longer
  stops at the configured `include` boundary. Reads and imports of out-of-scope
  files resolve to real leaf inputs; `include`/`exclude` decide only which files
  are parsed. On the evaluation project this alone reclassified hundreds of
  "unresolved input" reports that were purely walk-scope artifacts.
- **`style_load_paths`** models Sass `loadPaths` for bare and `../`-style
  specifiers; relative resolution still wins.
- **`skip_dirs`** replaces the default noise-directory list.
- **Glob dependency declarations** with a suppression contract for files whose
  reads are known but not statically provable; an empty glob is reported, never
  silent.
- **Directory reads and existence checks** are modeled as dependencies on the
  directory's current entries and on the path (including paths that do not
  exist yet).
- **Literal `import.meta.glob` patterns** expand against current membership.
- **Vue top-level `/* */` and `//` headers** are skipped; stylesheet
  interpolations no longer request fallback by themselves (an interpolation
  cannot name a stylesheet), while an unterminated one still blocks.
- **Glob expansion is prefix-filtered** so large trees stay affordable.
- **`runner_dir`** runs `--run` in the directory where the test runner is
  configured, so a monorepo's selective execution works end to end through the
  tool; selected tests outside that directory are a configuration error.

## Evaluation project

The public [wot-lynx-ui](https://github.com/ximo-156/wot-lynx-ui) monorepo,
read-only, with the project's real alias map, Sass load paths and test globs
declared in [`examples/impact-wot-lynx-ui.json`](<../examples/impact-wot-lynx-ui.json>).
The project's manifest-driven test helpers and build scripts read trees their
runtime arguments name, so their reads are declared through the `dependencies`
contract; every declaration was verified against the code it covers.

| Metric | Round two (unibest) | Now (wot-lynx-ui) |
| --- | ---: | ---: |
| Analyzed sources | 628 | 982 |
| Known dependency edges | 2,358 | 11,929 |
| Test inventory | 296 | 135 |
| Uncertainty observations | 267 | 0 after declarations (64 covered by explicit contracts) |
| Effective strategy | full | related |
| Selected tests | 296 (full) | 71 / 135 for a core-utility change |

Two explicit changes were planned:

| Change | Strategy | Selected |
| --- | --- | --- |
| `packages/core/src/common/formatDate.ts` | related | 71 / 135 |
| `packages/core/src/common/host.ts` | related | 101 / 135 |

`host.ts` is imported across the suite (`configureHost`), so its larger
selection is the real dependency graph, not over-selection: 97 of the 101
selected files reach it through import edges.

## Execution evidence

Clean working tree, executed through the tool itself with `--run` (the shipped
configuration sets `runner_dir` to `packages/ui`, where that project configures
Vitest; the analysis root stays the monorepo root):

| Run | Test files | Result | Wall time |
| --- | --- | --- | --- |
| Full suite | 135 | 3 pre-existing failures, 2185 passed | 37.1s |
| Selected subset (formatDate change) | 71 | same 3 failures, 1398 passed | 20.9s |
| Selected subset, injected `getFirstDayOfWeek` off-by-one | 71 | 4 failures; the format-date test catches the fault | 21.3s |
| Full suite, same injected fault | 135 | 4 failures; same catch | 39.7s |

The three pre-existing failures are component-inventory mismatches caused by
duplicate component directories in that local working tree; they are unrelated
to the change and appear identically in both runs. The injected fault was
reverted after measurement and the file verified clean.

The declaration contract caught a real configuration error during this work:
four declarations named a non-existent `packages/ui/demo/**` tree and were
silently suppressed by the earlier blanket suppression. Splitting configuration
errors out of the suppression surfaced them as
`unresolved-explicit-dependency`, and the corrected `packages/demo/**`
declarations restored the plan.

## Automated coverage

- Native unit suite: **543 passed** (new: directory/existence references, glob
  imports, glob declarations, suppression contract, `style_load_paths` and
  `skip_dirs` validation, Vue header comments, interpolation precision).
- MoonImpact CLI regressions: **33 passed** (new: out-of-scope membership reads,
  directory reads, existence ghosts, glob imports, style load paths, skip-dir
  override, declaration coverage, empty-glob reporting).
- Native bridge regressions: **15 passed**.
- Original moonlint CLI regressions: **207 passed**.
- Repository self-lint: no findings or source failures.

## Boundaries retained

Dynamic paths whose arguments are runtime values, `createRequire` resolution
into `node_modules` (governed by the lockfile), JSX/TSX, and the Vue compiler's
own resolution all remain uncertainty or declaration territory. Selective
selection is conservative: not every selected test is asserted to fail when an
input changes, and a plan is advisory, never a passing test result.
