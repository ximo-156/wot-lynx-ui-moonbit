# Package policy example

This module is dependency-free and acyclic: root -> domain -> ui. Compilation
permits the dependency; the supplied team policy forbids domain -> ui on native
source edges. It is deliberately not a compiler-rejected cycle example.

From the moonlint checkout root:

```bash
(cd examples/package-policy-demo && moon check --target native && moon test --target native && moon build --target native)
(cd examples/package-policy-demo && moon tree --package --json --target native > graph.native.json)
_build/native/debug/build/cmd/main/main.exe \
  --package-graph examples/package-policy-demo/graph.native.json \
  --config examples/package-policy-demo/policy.json --format json
# Expect exit 1, architecture/domain-no-ui, with actual package/alias/kind details.
```

Reverse the policy direction to ui -> domain (without changing the valid module)
to obtain a permitted case. Generated compiler graphs contain local paths and
are not checked in. The gate covers direct non-stdlib edges in the supplied
compiler v3 graph and does not invent source positions.
