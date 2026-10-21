# moonlint CLI integration tests

This runner uses only the Python standard library. It invokes an **already built**
native executable; it does not run `moon build` or `moon test` and does not install
dependencies.

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
- Unknown/missing/conflicting CLI arguments, explicit unsupported incremental/watch,
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

Failures against the pre-repair executable are intentional regression evidence.
No test is marked expectedFailure: the same command must become green once the
implementation satisfies the agreed CLI contract.
