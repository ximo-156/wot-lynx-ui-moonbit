# MoonImpact round four: MoonBit module planning

This records a local working-tree verification, not a release, remote CI result
or a guarantee of selective test safety on arbitrary projects. The
[round-three record](<moonimpact-round3-verification.md>) covers the JS/TS
engine and stays valid; this record adds the MoonBit front end.

## What was added

A second project kind, planned without any configuration: a root holding
`moon.mod` / `moon.mod.json` is analyzed as a package graph read from the
`moon.pkg` manifests themselves. No toolchain is invoked and no project code is
executed during planning.

- **Multi-module discovery.** Every module descriptor under the root declares a
  module; a package resolves its imports against its own module, so nested and
  workspace modules never borrow the root module's name.
- **Every import block counts.** Plain `import { … }`, `import { … } for "test"`
  and `#cfg(...)`-conditional blocks all name dependencies, because a test-only
  dependency still decides whether that package's tests observe a change. An
  earlier single-block parser silently dropped the `for "test"` importer of
  `encoding` in moonbitlang/x; the multi-block parser was written after that
  miss was measured.
- **Ownership and reverse traversal.** A changed file selects the package with
  the longest directory prefix (the module root package owns the rest) plus
  every transitive importer, test-only imports included. The module root
  package is addressed as `.` by the runner.
- **Advisory contract retained.** An unparseable manifest, a missing module
  descriptor, a change outside every package, or any manifest/descriptor change
  requests every package; I/O failures block.
- **Symlinked documents no longer block every plan.** A non-regular file is
  refused only when its content can matter — source, stylesheet or manifest.
  Four linked `README.md` files in moonbitlang/x previously blocked all of its
  plans; linked documents are membership data.
- **Pure planning core.** The planner is split into a filesystem wrapper and a
  pure function over an already-collected membership, so the graph, strategies
  and evidence chains are unit-tested without a toolchain.

## Public-project measurement (read-only)

[moonbitlang/x](https://github.com/moonbitlang/x), 25 packages, 19 holding
tests, planned with no configuration:

| Change | Strategy | Selected packages | Note |
| --- | --- | --- | --- |
| `decimal/decimal.mbt` | related | 1 / 19 | leaf package; nothing imports it |
| `encoding/encoding.mbt` | related | 4 / 19 | `crypto`, `fs`, `jwt` — declared `for "test"` |

## Repository measurement

This repository is itself a multi-module workspace: the root package,
`cmd/main`, `cmd/impact` and four example modules. Cold-cache comparison
after `moon clean`:

| Run | Wall time | Tests |
| --- | --- | --- |
| Full suite (`moon test`) | 5.4s | 555 |
| CLI-only change (`moon test cmd/impact`) | 2.1s | 0 — the plan is `none` |

A library change (`impact_plan.mbt`) selects the root package and runs its 555
tests, which is the honest answer: the CLI packages import the library, so
their builds are affected but they hold no tests.

## Automated coverage

- Native unit suite: **555 passed** (12 new: manifest parsing including
  multi-block and malformed forms, module discovery and ordering, specifier
  resolution per module, ownership, package-graph edges, strategies, evidence
  chains, global inputs, missing and empty changes).
- MoonImpact CLI regressions: **38 passed** (5 new: native MoonBit planning
  without a config, a CLI-only change planning `none`, a descriptor change
  requesting every package, `moon test` argv for the selected package, and the
  explicit error when neither a config nor a module is present).
- Native bridge regressions: **15 passed**; original moonlint CLI regressions:
  **207 passed**; repository self-lint: no findings.
- The read-only stability suite passes in **both** modes: against this
  repository as a MoonBit module (no configuration) and against the JS/TS
  project with its configuration — change-input sweeps, byte-identical repeated
  runs, Git input modes, degenerate inputs, create-only reports and the timing
  bound. CI now runs both gates.

## Boundaries retained

Planning reads manifests and the tree; it does not evaluate MoonBit code,
resolve type-level dependencies, or model conditional compilation beyond
counting the import blocks. A plan is advisory: not every selected package is
asserted to fail when an input changes, and selective reduction is a
per-project property.
