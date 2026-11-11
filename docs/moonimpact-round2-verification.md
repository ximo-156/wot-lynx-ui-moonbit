# MoonImpact round two: static readers and stylesheet inputs

This records a local working-tree verification, not a release, remote CI result
or a guarantee of selective test safety on arbitrary projects. The
[initial MVP record](<moonimpact-verification.md>) is retained separately.

## Added coverage

- Symbolic root/module-relative paths: genuine fs/path/url imports, bounded
  immutable path constants, `process.cwd()`, `__dirname`, static module-relative
  URL construction and `fileURLToPath`.
- Reader wrappers are inferred only from a supported single-parameter,
  single-return filesystem-read body. Arbitrary `read` or `ROOT` names are not
  trusted. User-declared `file_readers` remain a separate explicit contract.
- CSS/SCSS imports, Sass modules/partials and static asset URLs form transitive
  evidence chains, including supported Vue inline and external styles.
- Raw reads treat known out-of-scope files as opaque data rather than executing
  their imports. Filesystem names retain literal `?`/`#`; only CSS URL semantics
  remove query/fragment suffixes.

## Safety retained

Mutation, shadowing, URL/wrapper escape, additional I/O and dynamic paths still
request full fallback. Files are never read outside the configured safe root.
Path evaluation has a depth limit; normalization-sensitive dirname forms with
intermediate dot segments are deliberately rejected rather than guessed. URL
leading/trailing control whitespace and embedded tabs/newlines are not treated
like literal filesystem filenames. Imported stylesheet bodies must actually be
analyzed; invalid UTF-8/unsafe source inputs block execution. Stylesheet
ambiguity, unknown preprocessors/custom importers and unresolved inputs remain
visible uncertainty.

The planner still does not execute project code, mutate business sources or
install dependencies. Only synthetic/isolated tests were run.

## Controlled unibest comparison

The old executable was preserved before code changes. Old and new versions ran
back-to-back against the **same configuration, changes and input tree**. Content
hashes before and after the paired runs matched:

```text
6c8e92fce8903e0273c89754083d30fc17fa3e27dc87809c1dc4f6a636b725f4
```

The two change inputs were the refund page and global theme SCSS. The target
project evolved independently since the initial MVP snapshot, so its historical
319 uncertainties must not be compared directly to these current measurements.

| Metric | Old executable | New executable |
| --- | ---: | ---: |
| Analyzed sources | 623 | 628 (includes CSS/SCSS) |
| Known dependency edges | 2,244 | 2,358 |
| Test inventory | 296 | 296 |
| Uncertainty observations | 334 | 267 |
| Dynamic/unsupported file-path observations | 196 | 146 |
| Excluded-source observations | 22 | 1 |
| Effective strategy | full | full |
| Selected test inventory | 296 | 296 |

There are **67 fewer uncertainty observations**, without changing the target
project or relaxing unknown-input fallback. This is improved input coverage,
**not a claim that whole-project CI now runs fewer tests**. The single-run plan
times were approximately 0.74s and 0.86s respectively; additional analysis has a
cost, and these are not statistical performance benchmarks.

Remaining observations include directory/existence queries (75), dynamic paths
(146), unresolved file inputs (37), conservative shadowing (5), Less style blocks
(2), one excluded module and one unresolved font URL. The last is a reference in
the root-level iconfont CSS to a font not present at that relative location; the
planner did not rewrite the business asset path or hide the issue. Dormant files
and incomplete configured scope need project-owner review, not automatic
exemption.

## Regression evidence

After interface generation, formatting, check and rebuild:

- Native unit tests: **529 passed**.
- MoonImpact CLI regressions: **23 passed**.
- Native process/report safety regressions: **15 passed**.
- Original moonlint CLI regressions: **207 passed**.
- Repository self-lint: no findings or source failures.

The optional real-Vitest synthetic smoke also passed: fee and theme tests run
selectively; a deliberate fee defect is caught by both selected and full runs.
The demo reader now uses an inferred `ROOT` + `read(file)` wrapper without a
reader-name trust entry. The [demo](<../examples/impact-demo/README.md>) also
shows a palette CSS -> theme CSS -> test chain. Dependency-based selection is
conservative; not every selected test is asserted to fail when an input changes.

Useful entry points:

- [Usage and scope](<moonimpact.md>)
- [Reader proof regressions](<../impact_reads_wbtest.mbt>)
- [Style extraction regressions](<../impact_styles_wbtest.mbt>)
- [Transitive stylesheet plan regressions](<../impact_style_plan_wbtest.mbt>)
- [CLI regressions](<../tests/impact_integration.py>)
