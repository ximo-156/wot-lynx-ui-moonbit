# moonlint demo

A tiny TypeScript project that violates `demo/moonlint.json` in seven
predictable ways — one per layer of the engine, so a reviewer can see every
layer fire from a single command.

## Run it

From the repository root:

```sh
moon build --target native
moonlint --config examples/demo/moonlint.json examples/demo/src
```

(`moonlint` is the built `cmd/main` binary; on Windows the file is
`main.exe`.)

## Expected output

```text
app.ts:1: [warning] demo/no-unused-imports — Imported binding is never used ('unusedHelper' is imported but never used)
    import { formatDate, unusedHelper } from "./helpers";
app.ts:2: [error] demo/no-unresolved-relative-imports — Relative import cannot be resolved to a scanned file (cannot resolve './missing')
    import { broken } from "./missing";
app.ts:4: [warning] demo/no-unused-exports — Exported name is never imported by another file ('renderDate' is never imported by another file)
    export function renderDate(date: Date): string {
app.ts:6: [warning] demo/max-line-length — Line is too long (line has 76 characters (limit: 60))
    // this comment line is deliberately much longer than the configured limit
app.ts:9: [warning] demo/no-console-log — Avoid console.log in committed code
    console.log(formatted, tag);
helpers.ts:2: [warning] demo/no-todo-comment — TODO/FIXME comment left in code
    // TODO: honour the caller's locale
helpers.ts:10: [warning] demo/no-unused-exports — Exported name is never imported by another file ('alsoUnused' is never imported by another file)
    export const alsoUnused = 42;
```

Findings are sorted by file, then line, then rule id. The run exits 1
because one finding is an error.

## What each finding demonstrates

| Finding | Layer | Why it fires |
| --- | --- | --- |
| `demo/no-unused-imports` | structural | `unusedHelper` is imported on line 1 but never referenced again — decided by the usage pass over the token stream |
| `demo/no-unresolved-relative-imports` | structural | `./missing` resolves to no scanned file, even after probing extensions and `index.*` |
| `demo/no-unused-exports` (app.ts) | structural | nothing imports `app.ts`, so `renderDate` is a dead export — see the caveat below |
| `demo/max-line-length` | file | line 6 is 76 characters against a limit of 60 |
| `demo/no-console-log` | line | plain substring match on the comment-stripped view |
| `demo/no-todo-comment` | line | `"match_comments": true` puts this rule on the raw view, so it sees the `// TODO` on line 2 |
| `demo/no-unused-exports` (helpers.ts) | structural | `alsoUnused` is exported but no scanned file imports it |

Two deliberate near-misses prove the guards work:

- The `// TODO … moonlint-ok` comment on `app.ts:5` does **not** appear: the
  rule's `unless` matcher (`{"all": [{"contains": "moonlint-ok"}]}`)
  suppresses it.
- `broken` is imported and then referenced (`const tag = broken`), so the
  unused-import check stays quiet and only the resolution check fires.

## The entry-point caveat

`renderDate` is flagged as a dead export because the demo directory is the
whole world: nothing imports `app.ts`. In a real project, point moonlint at
the library sources (the global `scope` `include` list), or grandfather the
finding with `--update-baseline`.

The repository's own `moonlint.json` excludes `examples/demo` from its
scope, so these intentional violations never show up when moonlint lints
itself.

## The incremental cache layer

The same scan with `--incremental` exercises the fourth layer (pick any
cache path outside the scanned tree):

```sh
moonlint --config examples/demo/moonlint.json \
  --incremental --cache-file /tmp/moonlint-demo-cache.json \
  examples/demo/src
```

The report is identical — all seven findings, same order, same exit code —
and a cache file now sits next to the command. What it contains:

- One entry per file, keyed by a content hash of the source plus a
  fingerprint of the effective rule set (matchers, `unless` guards, scope,
  structural rules).
- `app.ts` contributes 2 findings (the line and file rules);
  `helpers.ts` contributes 1 (the TODO comment).
- The four structural findings are **not** in the cache: whether
  `renderDate` is a dead export depends on the whole project, so the
  project pass re-derives them every run. Caching them per file would be
  unsound — editing one file can change another file's answer.

Run it a second time and the per-file matchers are skipped for unchanged
files. Rewrite a file with identical bytes and the cache stays valid:
entries are keyed by content hash, not modification time. Edit a file and
only that file is re-linted; edit the config and the whole cache is
invalidated, because the fingerprint changed.

## MoonBit demo

The MoonBit source front end has its own five-finding sample under
[`moonbit-demo/`](moonbit-demo/). It exercises the declaration scanner
(public docs and naming) and the line rules (unwrap, TODO), and it is pinned
by the `moonbit` integration phase:

```sh
moonlint --preset moonbit examples/moonbit-demo/src
```
