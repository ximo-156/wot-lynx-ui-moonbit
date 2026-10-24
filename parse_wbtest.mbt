///|
/// Tests for the structural parser.

///|
/// Import sources of a model, in order.
fn sources(model : FileModel) -> Array[String] {
  model.imports.map(s => s.source)
}

///|
test "parse static import with named and default" {
  let m = parse_source("import Def, { a, b as c } from './mod';")
  assert_eq(m.imports.length(), 1)
  let spec = m.imports[0]
  assert_eq(spec.kind, ImportKind::Static)
  assert_eq(spec.source, "'./mod'")
  assert_eq(spec.line, 1)
  assert_eq(spec.names.length(), 3)
  assert_eq(spec.names[0].local, "Def")
  assert_eq(spec.names[0].imported, "default")
  assert_eq(spec.names[1].local, "a")
  assert_eq(spec.names[1].imported, "a")
  assert_eq(spec.names[2].local, "c")
  assert_eq(spec.names[2].imported, "b")
}

///|
test "parse namespace and side-effect imports" {
  let m = parse_source("import * as ns from './a';\nimport './b';")
  assert_eq(m.imports.length(), 2)
  assert_eq(m.imports[0].names[0].local, "ns")
  assert_eq(m.imports[0].names[0].imported, "*")
  assert_eq(m.imports[1].names.length(), 0)
  assert_eq(m.imports[1].source, "'./b'")
}

///|
test "parse type-only import" {
  let m = parse_source("import type { Foo } from './types';")
  assert_eq(m.imports.length(), 1)
  assert_eq(m.imports[0].type_only, true)
  assert_eq(m.imports[0].names[0].local, "Foo")
}

///|
test "parse dynamic import and require" {
  let m = parse_source("const a = import('./x');\nconst b = require('./y');")
  assert_eq(m.imports.length(), 2)
  assert_eq(m.imports[0].kind, ImportKind::Dynamic)
  assert_eq(m.imports[0].source, "'./x'")
  assert_eq(m.imports[1].kind, ImportKind::Require)
  assert_eq(m.imports[1].source, "'./y'")
}

///|
test "parse import.meta is not an import" {
  let m = parse_source("const u = import.meta.url;")
  assert_eq(m.imports.length(), 0)
}

///|
test "parse re-export forms" {
  let m = parse_source(
    "export * from './all';\nexport { a, b as c } from './part';\nexport { d };",
  )
  assert_eq(m.imports.length(), 2)
  assert_eq(m.imports[0].kind, ImportKind::ReExport)
  assert_eq(m.imports[0].source, "'./all'")
  assert_eq(m.imports[0].names[0].imported, "*")
  assert_eq(m.exports.length(), 3)
  assert_eq(m.exports[1].names.length(), 2)
  assert_eq(m.exports[1].names[0], "a")
  assert_eq(m.exports[1].names[1], "c")
  assert_eq(m.exports[2].names[0], "d")
  assert_eq(m.exports[2].source, None)
}

///|
test "parse default export" {
  let m = parse_source("export default function App() {}")
  assert_eq(m.exports.length(), 1)
  assert_eq(m.exports[0].names[0], "default")
  assert_eq(m.exports[0].line, 1)
}

///|
test "parse declaration exports record decls" {
  let m = parse_source(
    "export const x = 1;\nexport function f() {}\nexport class C {}",
  )
  assert_eq(m.exports.length(), 3)
  assert_eq(m.exports[0].names[0], "x")
  assert_eq(m.exports[1].names[0], "f")
  assert_eq(m.exports[2].names[0], "C")
  assert_eq(m.decls.length(), 3)
  assert_eq(m.decls[0].kind, DeclKind::Var)
  assert_eq(m.decls[1].kind, DeclKind::Function)
  assert_eq(m.decls[2].kind, DeclKind::Class)
}

///|
test "parse nested declarations are not top-level" {
  let m = parse_source("function outer() { const inner = 1; }")
  assert_eq(m.decls.length(), 1)
  assert_eq(m.decls[0].name, "outer")
}

///|
test "parse destructuring keeps simple names" {
  let m = parse_source("const { a, b } = obj;\nconst [c, d] = arr;")
  // Destructured names are intentionally not tracked; the statement parses.
  assert_eq(m.decls.length(), 0)
  assert_eq(m.imports.length(), 0)
}

///|
test "parse multiple declarators" {
  let m = parse_source("let a = 1, b = 2, c;")
  assert_eq(m.decls.length(), 3)
  assert_eq(m.decls[2].name, "c")
}

///|
test "used identifiers exclude import names" {
  let m = parse_source("import { a, b } from './m';\na();\nb();")
  let names = m.used.map(u => u.name)
  // The import statement's own tokens are excluded, but later reads count.
  assert_eq(names.length(), 2)
  assert_eq(names[0], "a")
  assert_eq(names[1], "b")
}

///|
test "property names are not identifier reads" {
  let m = parse_source("import { readFile } from 'fs';\nfs.readFile('x');")
  // `readFile` is imported but only referenced as a property of `fs`...
  let names = m.used.map(u => u.name)
  assert_eq(names.contains("readFile"), false)
  assert_eq(names.contains("fs"), true)
}

///|
test "keywords are not identifier reads" {
  let m = parse_source("const x = typeof y;")
  let names = m.used.map(u => u.name)
  assert_eq(names.contains("typeof"), false)
  assert_eq(names.contains("y"), true)
}

///|
test "comments and strings do not produce imports" {
  let m = parse_source(
    "// import fake from './nope';\n/* import other from './nada'; */\nconst s = \"import x from './none'\";",
  )
  assert_eq(m.imports.length(), 0)
}

///|
test "template interpolation identifiers are reads" {
  let m = parse_source("import { name } from './m';\nconst t = `hi ${name}`;")
  assert_eq(m.used.map(u => u.name).contains("name"), true)
}

///|
test "import positions point at the keyword" {
  let m = parse_source("\n\nimport { a } from './m';")
  assert_eq(m.imports[0].line, 3)
  assert_eq(m.imports[0].column, 1)
}

///|
test "require inside expression is recorded" {
  let m = parse_source("const path = require('path');")
  assert_eq(m.imports.length(), 1)
  assert_eq(m.imports[0].kind, ImportKind::Require)
  assert_eq(m.imports[0].line, 1)
}

///|
test "async function and generator declarations" {
  let m = parse_source("async function f() {}\nfunction* g() {}")
  assert_eq(m.decls.length(), 2)
  assert_eq(m.decls[0].name, "f")
  assert_eq(m.decls[1].name, "g")
}

///|
test "export default arrow is still a default export" {
  let m = parse_source("export default () => 1;")
  assert_eq(m.exports.length(), 1)
  assert_eq(m.exports[0].names[0], "default")
}

///|
test "empty source yields empty model" {
  let m = parse_source("")
  assert_eq(m.imports.length(), 0)
  assert_eq(m.exports.length(), 0)
  assert_eq(m.decls.length(), 0)
  assert_eq(m.used.length(), 0)
}

///|
test "broken source still yields a model" {
  // A linter must not lose findings to a syntax error elsewhere.
  let m = parse_source("import { a } from './m'\nconst = = =;\nfunction (")
  assert_eq(m.imports.length(), 1)
  assert_eq(m.imports[0].source, "'./m'")
}
