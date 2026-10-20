# moonlint CLI integration tests

This runner uses only the Python standard library. It invokes an **already built**
native executable; it does not run `moon build` or `moon test` and does not install
dependencies.

```sh
python3 tests/integration.py \
  --binary /absolute/path/to/moonlint \
  --phase repairs
```

`--binary` must identify an existing executable using an absolute path. Runner exit
status is 0 for a passing suite, 1 for assertion failures, and 2 for invalid runner
arguments. `--phase` accepts `repairs`, `scope`, `output`, or `all` (default). At this
stage only repairs cases are implemented: `all` explicitly notes that it runs
repairs only; requesting scope/output returns a clear runner usage error rather
than silently succeeding without tests. Those phases can be added to `PHASES`
without changing the runner interface.

## Isolation

Each test owns a separate `tempfile.TemporaryDirectory`. The scan root lives below
it, while config and baseline files live outside the scan root. Git init/add/
commit/checkout/rm commands only run with `git -C` pointing at that test's temporary
repository. User Git configuration, hook execution, and signing are disabled for
fixture setup. The CLI itself runs with its working directory inside the same
temporary area. All recursive cleanup is performed by tempfile after asserting
the resolved target is the exact owned directory. No Git writes target the actual
project checkout.

Python 3.9+ and Git with `init --initial-branch` support are expected. Git cases are
skipped if Git is unavailable. Permission-denied cases are skipped if the current
account can still read the intentionally inaccessible fixtures. Symlink cases are
skipped on hosts that do not support creating symlinks.

## Repairs coverage

- Positive text findings using `.ts`, error severity, and `contains: FORBIDDEN`.
- Glob `*`, whole-segment `**` (zero/many directories), `?`, repeated-pattern union
  and deduplication, and unsupported brace/class rejection.
- Real stdin pipes for line and NUL path lists, spaces (including trailing space),
  Unicode, quotes, newlines, dash names, and duplicate candidates.
- Consistent extension filters across tree/glob/stdin/stdin0/staged/changed modes;
  empty rule extension arrays scan all regular files.
- Committed HEAD blobs versus worktree contents, complete-file rather than diff-line
  linting, true index contents in both directions, and PR merge-base semantics.
- Git NUL path safety with subdirectory roots and deletion handling; Git failures
  must produce exit 2 instead of an empty successful result.
- Unknown/missing/conflicting CLI arguments, explicit unsupported incremental/watch,
  symlink skip/cycle protection, outside-root rejection, and I/O failures.
- Raw/idempotent baseline refresh, preserving current entries while adding new ones,
  clearing stale entries on full refresh, errors-only independence, partial-update
  rejection without rewriting, malformed inputs, and baseline write failure.
- Fixed noise directories are excluded even when a rule applies to all regular files.

Failures against the pre-repair executable are intentional regression evidence.
No test is marked expectedFailure: the same command must become green once the
implementation satisfies the agreed CLI contract.
