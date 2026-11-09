///|
/// Tests for the cross-file structural analysis engine.

///|
fn test_index(files : Array[(String, String)]) -> ProjectIndex {
  build_index(files)
}

///|
fn structural_rule(
  id : String,
  check : StructuralCheck,
  extensions : Array[String],
) -> StructuralRule {
  {
    id,
    severity: Severity::error(),
    message: "test structural rule",
    extensions,
    check,
    scope: Scope::empty(),
  }
}

///|
test "resolve joins directories and probes extensions" {
  let index = test_index([
    ("src/a.ts", ""),
    ("src/b.tsx", ""),
    ("lib/c.js", ""),
    ("src/d/index.ts", ""),
  ])
  assert_eq(index.resolve("src/main.ts", "'./a'"), Some("src/a.ts"))
  assert_eq(index.resolve("src/main.ts", "'./b'"), Some("src/b.tsx"))
  assert_eq(index.resolve("src/main.ts", "'./d'"), Some("src/d/index.ts"))
  assert_eq(index.resolve("src/x.ts", "'../lib/c'"), Some("lib/c.js"))
  assert_eq(index.resolve("src/deep/x.ts", "'../../lib/c'"), Some("lib/c.js"))
  assert_eq(index.resolve("src/deep/x.ts", "'../../..'"), None)
  assert_eq(index.resolve("src/main.ts", "'./missing'"), None)
  assert_eq(index.resolve("src/main.ts", "'react'"), None)
  assert_eq(index.resolve("src/main.ts", "\"./a\""), Some("src/a.ts"))
}

///|
test "unused imports are reported once per binding" {
  let index = test_index([
    ("src/a.ts", "import { used, unused } from './b';\nexport const used = 1;"),
    ("src/b.ts", "export const used = 1;\nexport const unused = 2;"),
  ])
  let rules = [
    structural_rule("imports/no-unused-imports", NoUnusedImports, [".ts"]),
  ]
  let findings = analyze(index, rules)
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].file, "src/a.ts")
  assert_eq(findings[0].line, 1)
  assert_true(findings[0].message.contains("unused"))
}

///|
test "side-effect import binds nothing and is never unused" {
  let index = test_index([
    ("src/a.ts", "import './b';\n"),
    ("src/b.ts", "export const x = 1;\n"),
  ])
  let rules = [
    structural_rule("imports/no-unused-imports", NoUnusedImports, [".ts"]),
  ]
  assert_eq(analyze(index, rules).length(), 0)
}

///|
test "duplicate imports report every statement after the first" {
  let index = test_index([
    ("src/a.ts", "import { x } from './b';\nimport { y } from './b';\n"),
    ("src/b.ts", "export const x = 1;\nexport const y = 2;\n"),
  ])
  let rules = [
    structural_rule("imports/no-duplicate-imports", NoDuplicateImports, [".ts"]),
  ]
  let findings = analyze(index, rules)
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].line, 2)
}

///|
test "unresolved relative import is reported" {
  let index = test_index([("src/a.ts", "import { x } from './gone';\n")])
  let rules = [
    structural_rule(
      "imports/no-unresolved-relative-imports",
      NoUnresolvedRelativeImports,
      [".ts"],
    ),
  ]
  let findings = analyze(index, rules)
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].line, 1)
  assert_eq(findings[0].snippet, "import { x } from './gone';")
}

///|
test "bare specifier is never unresolved" {
  let index = test_index([("src/a.ts", "import React from 'react';\n")])
  let rules = [
    structural_rule(
      "imports/no-unresolved-relative-imports",
      NoUnresolvedRelativeImports,
      [".ts"],
    ),
  ]
  assert_eq(analyze(index, rules).length(), 0)
}

///|
test "import cycle is reported for each file in the cycle" {
  let index = test_index([
    ("src/a.ts", "import { b } from './b';\nexport const a = 1;\n"),
    ("src/b.ts", "import { a } from './a';\nexport const b = 2;\n"),
  ])
  let rules = [
    structural_rule("imports/no-import-cycles", NoImportCycles, [".ts"]),
  ]
  let findings = analyze(index, rules)
  assert_eq(findings.length(), 2)
  assert_eq(findings[0].file, "src/a.ts")
  assert_eq(findings[1].file, "src/b.ts")
}

///|
test "acyclic imports pass" {
  let index = test_index([
    ("src/a.ts", "import { b } from './b';\nexport const a = 1;\n"),
    ("src/b.ts", "export const b = 2;\n"),
  ])
  let rules = [
    structural_rule("imports/no-import-cycles", NoImportCycles, [".ts"]),
  ]
  assert_eq(analyze(index, rules).length(), 0)
}

///|
test "default export is reported" {
  let index = test_index([("src/a.ts", "export default function main() {}\n")])
  let rules = [
    structural_rule("imports/no-default-export", NoDefaultExport, [".ts"]),
  ]
  let findings = analyze(index, rules)
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].line, 1)
}

///|
test "deep relative imports report the climb count" {
  let index = test_index([("src/a.ts", "import { x } from '../../lib/x';\n")])
  let rules = [
    structural_rule(
      "imports/no-deep-relative-imports",
      NoDeepRelativeImports(1),
      [".ts"],
    ),
  ]
  let findings = analyze(index, rules)
  assert_eq(findings.length(), 1)
  assert_true(findings[0].message.contains("2 levels"))
}

///|
test "require imports are reported" {
  let index = test_index([("src/a.ts", "const x = require('./b');\n")])
  let rules = [
    structural_rule("imports/no-require-imports", NoRequireImports, [".ts"]),
  ]
  let findings = analyze(index, rules)
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].line, 1)
}

///|
test "unused exports are reported unless imported" {
  let index = test_index([
    ("src/a.ts", "export const used = 1;\nexport const dead = 2;\n"),
    ("src/b.ts", "import { used } from './a';\n"),
  ])
  let rules = [
    structural_rule("imports/no-unused-exports", NoUnusedExports, [".ts"]),
  ]
  let findings = analyze(index, rules)
  assert_eq(findings.length(), 1)
  assert_true(findings[0].message.contains("dead"))
  assert_eq(findings[0].line, 2)
}

///|
test "namespace import consumes every export" {
  let index = test_index([
    ("src/a.ts", "export const x = 1;\nexport const y = 2;\n"),
    ("src/b.ts", "import * as ns from './a';\n"),
  ])
  let rules = [
    structural_rule("imports/no-unused-exports", NoUnusedExports, [".ts"]),
  ]
  assert_eq(analyze(index, rules).length(), 0)
}

///|
test "re-export counts as usage of the source module export" {
  let index = test_index([
    ("src/a.ts", "export const x = 1;\n"),
    ("src/b.ts", "export { x } from './a';\n"),
  ])
  let rules = [
    structural_rule("imports/no-unused-exports", NoUnusedExports, [".ts"]),
  ]
  // a.ts's x is re-exported by b.ts, so it is not dead; b.ts's re-export
  // itself has no importer and is the only finding.
  let findings = analyze(index, rules)
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].file, "src/b.ts")
}

///|
test "structural rule extensions filter which files are checked" {
  let index = test_index([
    ("src/a.ts", "export default 1;\n"),
    ("src/b.js", "export default 2;\n"),
  ])
  let rules = [
    structural_rule("imports/no-default-export", NoDefaultExport, [".js"]),
  ]
  let findings = analyze(index, rules)
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].file, "src/b.js")
}

///|
fn test_index_with_aliases(
  files : Array[(String, String)],
  aliases : Array[(String, String)],
) -> ProjectIndex {
  build_index_with_aliases(files, aliases)
}

///|
test "aliases resolve a bare specifier to a root-relative path" {
  let index = test_index_with_aliases([
    ("src/api/ka.ts", "export const getKa = 1;\n"),
    ("src/app.ts", "import { getKa } from '@/api/ka';\nconsole.log(getKa);\n"),
  ], [("@", "src")])
  assert_eq(index.resolve("src/app.ts", "@/api/ka"), Some("src/api/ka.ts"))
  // A `@scope/pkg` package import must not match the `@` alias.
  assert_true(index.resolve("src/app.ts", "@scope/pkg") is None)
  // A `@/` prefix form works too.
  let index2 = test_index_with_aliases([
    ("src/api/ka.ts", ""),
    ("src/app.ts", ""),
  ], [("@/", "src")])
  assert_eq(index2.resolve("src/app.ts", "@/api/ka"), Some("src/api/ka.ts"))
}

///|
test "aliased imports keep an export from being reported unused" {
  let rules = [
    structural_rule("imports/no-unused-exports", NoUnusedExports, [".ts"]),
  ]
  let files : Array[(String, String)] = [
    ("src/api/ka.ts", "export const getKa = 1;\n"),
    ("src/app.ts", "import { getKa } from '@/api/ka';\nconsole.log(getKa);\n"),
  ]
  // Without aliases the import cannot be resolved, so the export looks dead.
  assert_eq(analyze(test_index(files), rules).length(), 1)
  // With the alias configured, the export is seen as used.
  assert_eq(
    analyze(test_index_with_aliases(files, [("@", "src")]), rules).length(),
    0,
  )
}

///|
test "a longer alias prefix wins over a shorter one" {
  let index = test_index_with_aliases([
    ("src/lib/x.ts", ""),
    ("other/lib/x.ts", ""),
  ], [("@", "src"), ("@/lib", "other/lib")])
  assert_eq(index.resolve("a.ts", "@/lib/x"), Some("other/lib/x.ts"))
}
