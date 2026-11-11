# MoonImpact demo

A synthetic Vue/TypeScript-style regression project with module dependencies
and a non-imported stylesheet input. It does not contain business code.

From the moonlint repository root:

```sh
moon build --target native
BIN="$PWD/_build/native/debug/build/cmd/impact/impact.exe"
"$BIN" --file src/fees.ts --config examples/impact-demo/moonimpact.json examples/impact-demo
"$BIN" --file src/theme.css --config examples/impact-demo/moonimpact.json examples/impact-demo
"$BIN" --file src/palette.css --config examples/impact-demo/moonimpact.json examples/impact-demo
```

Expected selections:

- `src/fees.ts` -> `test/fees.test.ts` and `test/summary.test.ts`, with direct
  and transitive import evidence. The unrelated stylesheet test is not selected.
- `src/theme.css` -> `test/theme.test.ts`, through the statically proved
  `ROOT` + single-return `read(file)` wrapper rather than an import. The demo
  does not need a `file_readers` trust entry for this wrapper.
- `src/palette.css` -> `src/theme.css` -> `test/theme.test.ts`, a conservative
  transitive stylesheet-input chain. Selection is not a guarantee that an
  assertion will change; it is a dependency-based regression recommendation.
- `package.json` or a removed input -> full fallback, with a reason.

Planning does not require Node.js or Vitest. To run the actual synthetic tests,
install this demo's declared dependencies yourself in this directory first
(`pnpm install`), then append `--run` to a plan command. MoonImpact never installs
dependencies automatically. Tests run with the caller's permissions.

See [the MoonImpact guide](<../../docs/moonimpact.md>) for scope, configuration,
output formats, execution semantics and limitations. This demo is not a claim
that all possible dynamic dependencies are understood.
