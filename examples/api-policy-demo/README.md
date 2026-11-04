# API policy example

Both modules compile and pass their tests. `before` is 0.2.0 and exports
`greeting` plus `old_api`; `after` is 0.3.0 and removes `old_api`.

From the moonlint checkout root:

```bash
ROOT="$PWD"
TOOLCHAIN="moon 0.1.20261102; moonc v0.10.19+bee578715"
BIN="$ROOT/_build/native/debug/build/cmd/main/main.exe"
(cd examples/api-policy-demo/before && moon check --target native && moon test --target native && moon info)
(cd examples/api-policy-demo/after && moon check --target native && moon test --target native && moon info)
"$BIN" --api-snapshot examples/api-policy-demo/before/pkg.generated.mbti \
  --api-toolchain "$TOOLCHAIN" --api-backend native --api-module-version 0.2.0 \
  > examples/api-policy-demo/before/api.snapshot.json
"$BIN" --api-snapshot examples/api-policy-demo/after/pkg.generated.mbti \
  --api-toolchain "$TOOLCHAIN" --api-backend native --api-module-version 0.3.0 \
  > examples/api-policy-demo/after/api.snapshot.json
"$BIN" --api-check examples/api-policy-demo/before/api.snapshot.json \
  examples/api-policy-demo/after/api.snapshot.json --format json
# Default review gate: exit 1 for removed public old_api, despite the version bump.
"$BIN" --api-check examples/api-policy-demo/before/api.snapshot.json \
  examples/api-policy-demo/after/api.snapshot.json --api-version-policy semver --format json
# Opt-in 0.x minor breaking release: exit 0, removal still reported as warning.
```

Record the toolchain actually used instead of copying this example metadata
when your compiler differs. These are declaration snapshots, not behavioral,
ABI or type-assignability proof. Unsupported syntax/context returns exit 2.
Snapshot outputs are generated locally and not checked in.
