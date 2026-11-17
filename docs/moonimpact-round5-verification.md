# MoonImpact round five: end-to-end selective execution on a public MoonBit module

This record closes the gap left by the earlier rounds: the previous records
measured **planning** on a public MoonBit module and **execution** on a JS/TS
project, but never both on the same MoonBit tree. This round executes the
plan with `--run` on the public [moonbitlang/x](https://github.com/moonbitlang/x)
monorepo, compares it against the full suite, and injects two faults to check
what the selection actually catches.

It records a local working-tree verification, not a release, a remote CI
result, or a guarantee of selective test safety on arbitrary projects. The
[round-four record](<moonimpact-round4-verification.md>) covers the MoonBit
planning front end; the [round-three record](<moonimpact-round3-verification.md>)
covers the JS/TS engine.

## Fixed subject

| Item | Value |
| --- | --- |
| Repository | `https://github.com/moonbitlang/x` |
| Commit | `6b67e08c098c349f1e0fb48b0a624864d7e415e5` ("fix(fs): retry native open after interruption (#362)") |
| Modules / packages | 1 module, 25 packages, 19 holding tests |
| Toolchain | `moon 0.1.20261111 (8b8d15b)`, `moonc v0.10.21+f125caab5`, macOS native |
| Subject state | clean tree; every measurement below starts from `git status` clean and the fault reverted after its run |

The commit is pinned deliberately. The repository's later `fs` package uses
`@io.ReaderClosed`, which the pinned local core (`0.10.21`) does not export, so
the current upstream `HEAD` does not compile with this toolchain. That is an
upstream/toolchain version skew, not a planning defect, and the measurement
uses the newest commit that both compiles and runs its tests here.

## Plan and execution, side by side

Both runs use the same tool binary, the same tree and the same machine. "Cold"
means `moon clean` immediately before the run; "warm" means the build cache is
already populated from the preceding run.

| Run | Strategy | Packages | Tests | Result | Cold | Warm |
| --- | --- | ---: | ---: | --- | ---: | ---: |
| Full suite (`moon test`) | — | 25 | 795 | 794 passed, 1 failed | 4.67s | 4.05s |
| Selective, `encoding` change | related | 4 / 19 | 175 | 174 passed, 1 failed | 0.57s | 0.16s |
| Selective, `decimal` change | related | 1 / 19 | 27 | 27 passed, 0 failed | 0.48s | 0.05s |

The selective runs went through the tool's own `--run` path, not a hand-written
`moon test <packages>` list:

```sh
moon build --target native
BIN="$PWD/_build/native/debug/build/cmd/impact/impact.exe"
"$BIN" plan --file encoding/encoding.mbt --run /tmp/x-checkout
```

The `encoding` selection is four packages — `crypto`, `encoding`, `fs` and
`jwt` — reached through declared dependencies, including the `for "test"`
import from `crypto` that declares `moonbitlang/x/encoding`. The `decimal`
package is a leaf: nothing imports it, so only its own package is selected.

The single failure in the full suite and in the `encoding` selection is
**pre-existing and unrelated** to any change: `crypto/chacha_test.mbt:59`
("chacha rejects counter exhaustion before writing output") fails on the
pristine pinned commit. It appears identically in the clean baseline and in
every fault run, and the `decimal` selection does not contain `crypto`, so it
does not appear there.

## Fault injection

Two faults were injected, one in each selection shape, and reverted afterwards
(`git status` clean, verified).

**Fault 1 — `encoding`, affecting the 4-package selection.** `encode` in
`encoding/encoding.mbt` wrote UTF-16 big-endian output with
`Buffer::write_char_utf16le`:

```diff
-    UTF16BE => Buffer::write_char_utf16be
+    UTF16BE => Buffer::write_char_utf16le
```

| Run | Tests | Result |
| --- | ---: | --- |
| Full suite | 795 | 792 passed, 3 failed |
| Selective (4 packages) | 175 | 172 passed, 3 failed |

**Fault 2 — `decimal`, affecting the 1-package selection.** `normalize` in
`decimal/decimal.mbt` decremented the scale by two instead of one while
stripping trailing zeros:

```diff
       coefficient = coefficient / 10N
-      scale = scale - 1
+      scale = scale - 2
```

| Run | Tests | Result |
| --- | ---: | --- |
| Selective (1 package) | 27 | 23 passed, 4 failed |

The four decimal failures are `decimal_creation`, `decimal_string_conversion`,
`decimal_comparison` and `decimal_normalization`.

## What the selection caught, and what it did not

Comparing the failing-test sets of the full run and the selective run for
fault 1, item by item:

| Failing test | Full | Selective |
| --- | --- | --- |
| `crypto/chacha_test.mbt` — chacha rejects counter exhaustion | failed | failed |
| `encoding/encoding_test.mbt:84` — encoding String to UTF16BE | failed | failed |
| `encoding/decoding_test.mbt:174` — streaming decoding UTF16BE | failed | failed |

**The failure sets are identical: the selection missed nothing and reported
nothing extra.** For this injected fault, the 4-package selection carried
every failure the 795-test full suite found, while running 175 tests.

The honest boundary of that statement: it holds for *this* fault in *this*
tree. A selective plan is not a proof of equivalence. The planner reads
manifest imports, so a dependency that is not declared in a `moon.pkg` import
block is invisible to it, and a package whose tests are affected through such
an undeclared path would not be selected. The contract is one-directional:
the model can only prove the links it can see, and unmodeled changes request
every package rather than silently claiming no impact.

## Determinism

Two consecutive `plan --format json` runs over the same tree are byte-identical.

## Boundaries retained

- The plan is advisory. A `related` plan says which packages the model links
  to the change; it does not assert that every selected test would fail if the
  change were wrong, and it is never a passing test result.
- Selective reduction is a per-project property. The 175/795 and 27/795
  figures describe this tree, this commit and this toolchain.
- Wall times are machine-dependent and are reported as measurements, not
  promises. The cold/warm pairs are given so the compile-cache share of the
  difference is visible rather than implied.
- The package graph is built from `moon.pkg` import blocks. Conditional
  (`#cfg`) blocks are counted conservatively without evaluating conditions;
  type-level dependencies and runtime file reads are not modelled.
- The subject is read for measurement. The injected faults were reverted
  immediately after their runs, and the tree was verified clean before and
  after.
