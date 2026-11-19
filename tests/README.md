# moonlint CLI integration tests

[English](<README.md>) | [简体中文](<README.zh-CN.md>)

[integration.py](integration.py) uses only the Python standard library. It invokes
an **already built** native moonlint executable and does not build moonlint or
install dependencies. The `policies` phase also invokes the installed MoonBit
toolchain (`moon check`, `moon test`, `moon info`, and `moon tree`) on isolated
fixtures; those compiler cases are skipped if `moon` is unavailable.

```sh
# Build first, then run the suite against the native binary.
moon build --target native
python3 tests/integration.py \
  --binary "$PWD/_build/native/debug/build/cmd/main/main.exe" \
  --phase all
```

`--binary` must identify an existing executable using an absolute path. Runner exit
status is 0 for a passing suite, 1 for assertion failures, and 2 for invalid runner
arguments. `--phase` accepts a phase name or `all` (default):

| Phase | Focus |
|-------|-------|
| `repairs` | Scan reliability: glob/stdin selection, extension filters, path safety, argument validation, baseline refresh, skipped/failed accounting |
| `git` | Git safety: option injection, merge-base PR semantics, true index contents, unmerged index, Git symlinks, renames |
| `scope` | Global and rule-level `include` / `exclude` |
| `output` | JSON reports, GitHub annotations, read/failure/skip metadata |
| `presets` | Built-in presets, config inheritance, inline suppression, SARIF, initialization, and fixes |
| `observable` | Match columns, comment/literal handling, summaries, and dry-run/fix output |
| `incremental` | Content-based cache reuse, invalidation, malformed-cache fallback, and structural caching |
| `structural` | Imports, exports, cycles, aliases, and dependency context |
| `combinator` | Matcher composition and `unless` guards |
| `demo` | Exact TypeScript demo output, summaries, and cache round trips |
| `moonbit` | MoonBit demo output, preset equivalence, and exclusions |
| `policies` | Package/API policies, compiler-backed fixtures, MoonBit syntax/fixes, and baseline v2 |
| `git-context` | Immutable Git project context and isolation from worktree/config changes |

## Isolation

Each test owns a separate `tempfile.TemporaryDirectory` with a unique
`moonlint-<random>-` prefix. The scan root lives below it, while config and
baseline files live outside the scan root. Git init/add/commit/checkout/rm
commands only run with `git -C` pointing at that test's temporary repository.
User Git configuration, hook execution, and signing are disabled for fixture
setup. The CLI itself runs with its working directory inside the same temporary
area. All recursive cleanup is performed by tempfile after asserting the resolved
target is the exact owned directory. No Git writes target the actual project
checkout.

Python 3.9+ and Git with `init --initial-branch` support are expected. Git cases are
skipped if Git is unavailable. Permission-denied cases are skipped if the current
account can still read the intentionally inaccessible fixtures. Symlink cases are
skipped on hosts that do not support creating symlinks.

## Repairs coverage

- Positive text findings using `.ts`, error severity, and `contains: FORBIDDEN`.
- Glob `*`, whole-segment `**` (zero/many directories), `?`, repeated-pattern union
  and deduplication, and unsupported brace/class rejection.
- Real stdin pipes for line and NUL path lists, spaces (including trailing space),
  Unicode, quotes, newlines, dash names, and duplicate candidates; NUL bytes are
  rejected in line mode but accepted in `--stdin0`.
- Empty glob and empty stdin/stdin0 selections: a clean exit, an explicit
  "no files selected" notice in text mode, and zero counters in JSON.
- Consistent extension filters across tree/glob/stdin/stdin0/staged/changed modes;
  empty rule extension arrays scan all regular files.
- Unknown/missing/conflicting CLI arguments and explicit rejection of unsupported
  `--watch` / `--watch-interval` options,
  symlink skip/cycle protection, outside-root rejection, and I/O failures —
  including an unreadable subdirectory, which is an error rather than a silently
  partial scan.
- Raw/idempotent baseline refresh, preserving current entries while adding new ones,
  clearing stale entries on full refresh, errors-only independence, partial-update
  rejection without rewriting, malformed inputs, and baseline write failure.
- Fixed noise directories are excluded even when a rule applies to all regular files.

## Git coverage

- Committed HEAD blobs versus worktree contents, and complete-file rather than
  diff-line linting; PR merge-base semantics when the upstream branch has diverged.
- True index contents in `--staged` in both directions (dirty index with a clean
  worktree, and a clean index with a dirty worktree).
- NUL-safe paths with spaces, quotes, Unicode and embedded newlines, with
  subdirectory roots and deletion handling; renames are scanned at their new path.
- Reference values that look like Git options are rejected as references, so they
  can never be interpreted as flags.
- An unmerged index, a repository outside the scan root, and an unknown ref all
  produce exit 2 instead of an empty successful result.

## Scope coverage

- Global `include`/`exclude` restrictions, `./` prefixes, directory patterns that
  cover their subtree (but not same-prefix siblings), file patterns, and
  exclusion-wins-over-inclusion.
- Rule-level scope limits a single rule without widening the global scan set.
- Scope applies to every scan mode, and scope-rejected files are counted in
  `files_out_of_scope` and never read.
- Invalid patterns and malformed scope lists are configuration errors (exit 2),
  for both global and rule-level scopes.

## Output coverage

- JSON: versioned document, findings with rule/severity/file/line/column/snippet,
  per-severity counts, diagnostics, and every read/failure/skip/scope/baseline
  counter, including a per-file `skipped_files` list with reasons.
- JSON reports are written to `--report <file>` atomically, also when the scan
  fails.
- GitHub: `::error`/`::warning` annotations with escaped property and message
  values, `::error` annotations for unreadable files, `::notice` annotations for
  skipped files, a final summary notice, and no forged commands from embedded
  newlines.

No test is marked `expectedFailure`; assertion failures are regressions against
the CLI contract. Tests whose host prerequisites are unavailable may be skipped.

## Separate MoonImpact runners

These scripts are not included in `integration.py --phase all`:

| Runner | Requirements and scope |
|--------|------------------------|
| [impact_integration.py](impact_integration.py) | Pass `--binary /absolute/path/to/impact.exe`; exercises planning and execution with isolated fixtures and fake runners. |
| [impact_native.py](impact_native.py) | Run directly with Python; builds a temporary C driver using `cc` on macOS/Linux to test the native bridge. |
| [impact_moonbit_corpus.py](impact_moonbit_corpus.py) | Supply `--binary` and repeated `--project NAME=DIR` for clean checkouts at the commits in [the corpus manifest](impact_moonbit_corpus.json). Runs the project's full suite and compares `moon test --outline` with static inventory; `--mutate` additionally injects declared faults and compares failure identities. Restores source bytes after each fault. No clones, toolchain changes or snapshot updates; `moon` may resolve dependencies and write build outputs. |
| [impact_moonbit_corpus_test.py](impact_moonbit_corpus_test.py) | Five dependency-free tests for runner evidence parsing and source restoration on failed execution; included in CI. |
| [impact_stability.py](impact_stability.py) | Pass `--binary`, `--project`, and optionally `--config` / `--samples`; audits an existing project without modifying it or running its tests. Skips without `--project`. |
| [impact_vitest_smoke.py](impact_vitest_smoke.py) | Pass `--binary` and `--vitest-dir` containing `vitest.mjs`; requires existing Node.js and pnpm, runs a temporary synthetic fixture, and installs nothing. |

Build the MoonImpact executable with `moon build --target native`; its default
path is `_build/native/debug/build/cmd/impact/impact.exe`.
