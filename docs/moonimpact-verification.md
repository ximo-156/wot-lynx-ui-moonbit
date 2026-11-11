# MoonImpact MVP local verification — 2026-11-10

This is the initial MVP snapshot. See the [round-two record](<moonimpact-round2-verification.md>)
for subsequent static-reader/style coverage, paired unibest measurements and
updated test counts. Historical counts below are intentionally retained.

## Scope

This record describes the current working tree, not a published release or a
remote CI result. The original moonlint entry remains intact; MoonImpact is a
new CLI and plan schema, not a renamed set of lint rules. No project commit,
push, registration submission or dependency installation was performed for this
verification.

Environment: macOS Native, moon 0.1.20261104, moonc
v0.10.20+65efd5b93, Node v22.23.2. The optional real-run check used the existing
trusted Vitest 3.2.7 package, with all demo sources, runner configuration, caches
and fault injection isolated in an owned temporary directory. Business tests
were not run.

## Functional evidence

The [synthetic demo](<../examples/impact-demo/README.md>) contains three test
files and four tests:

| Change | Planned strategy | Selected test files | Evidence |
| --- | --- | --- | --- |
| Fee calculation module | related | fee test + summary test (2/3 files) | direct import and a two-edge transitive chain |
| Theme CSS | related | theme test (1/3 files) | configured root-reader file input, not a module import |
| Package manifest or missing/deleted input | full | complete inventoried set | explicit global-input / missing-input fallback reasons |

Actual Vitest execution in the isolated demo verified:

- Fee change: two test files / three tests passed, CLI exit 0.
- CSS change: one test file / one test passed, CLI exit 0.
- Injecting `return 0` into the synthetic fee function: the same selected test
  files detected both affected failing assertions, CLI exit 1. The negative
  duration assertion still passed.
- Full regression on that faulted fixture also detected the two failing
  assertions (with the stylesheet test still passing).
- Vitest 3.2.7 `related --run src/theme.css` reported no test files for this
  synthetic CSS input; MoonImpact selected the theme test via its file-input
  edge. This observation is specific to the fixture and installed version.
- JSON stdout remained a parseable advisory plan while Vitest output was sent
  to stderr. A plan-only exit 0 was not represented as test success.

The repeatable optional smoke is [impact_vitest_smoke.py](<../tests/impact_vitest_smoke.py>).
It requires explicitly supplied, already-installed dependencies and does not
install anything. It also prints a comparison with `vitest related` for the CSS
input; this is a specific dependency-coverage demonstration, not a general
benchmark or a claim that MoonImpact replaces Vitest.

## Real-project read-only evaluation

The supplied unibest configuration is [impact-unibest.json](<../examples/impact-unibest.json>).
The captured run used two explicit changes: the refund page and global theme
SCSS. It observed:

| Metric | Captured value |
| --- | ---: |
| Analyzed source files | 618 |
| Known dependency edges | 2,241 |
| Test-file inventory | 291 |
| Known affected graph nodes (including inputs) | 25 |
| Uncertainty observations | 319 |
| Effective strategy | full |

The plan includes known read-source links to refund, header/theme and other
relevant tests, but **does not claim those links are complete**. Dynamic reads,
directory scans, unsupported style dependencies and inputs outside the chosen
scope trigger full fallback. This first MVP therefore does **not** demonstrate
safe whole-project test-count reduction on unibest yet. The plan took about
0.9 seconds in one local run; this is not an execution-speed benchmark.

Only the synthetic fixture ran tests. unibest's Git status was identical before
and after the read-only plan evaluation. Do not publish its private business
source or private report details as part of the public demo.

## Automated coverage

- Native unit suite: 462 passed after final `moon info && moon fmt`, type check
  and rebuild. Compiler warnings remain; this is not a warning-free claim.
- [MoonImpact CLI regressions](<../tests/impact_integration.py>): 15 passed.
- [Native bridge regressions](<../tests/impact_native.py>): 15 passed, including
  Git path/ref handling, process arguments, timeout cleanup, nonexecuting default
  behavior, and create-only report publication under contention.
- Original moonlint CLI regression suite: 207 passed.

The native bridge refuses repository clean/process filters rather than allowing
Git diff to invoke them. Default plans do not execute Node code. Explicit
`--run` is not a sandbox and should only be used in trusted projects.

Remaining boundaries include dynamic I/O, broad CSS/framework-generated
dependencies, JSX/TSX parsing, historical graph reconstruction for deletions,
Windows support and automatic test-runner configuration discovery. New support
must keep conservative fallback rather than turn missing analysis into a
confident no-impact verdict.
