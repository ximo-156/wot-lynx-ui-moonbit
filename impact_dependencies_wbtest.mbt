///|
/// These tests deliberately avoid filesystem fixtures. The extractor supplies
/// evidence only; path resolution and conservative planning belong elsewhere.
fn impact_dep_test_paths(
  references : Array[ImpactReference],
  kind : String,
) -> Array[String] {
  references
  .filter(reference => reference.kind == kind)
  .map(reference => reference.specifier)
}

///|
test "impact extracts every static import and reexport independently of declarations" {
  let source =
    #|const preceding =
    #|  { nested: [1, 2] }
    #|import main from './main'
    #|import type { Item } from './types'
    #|import './side-effect'
    #|export { main as publicMain } from './reexport'
    #|export type { More } from './type-export'
    #|export * from './all'
    #|export * as group from './group'
    #|const later = import('./lazy')
    #|const common = require('./common')
  let (references, issues) = impact_extract_references("src/a.ts", source, [])
  assert_eq(issues.length(), 0)
  assert_eq(impact_dep_test_paths(references, "import"), [
    "./main", "./types", "./side-effect", "./reexport", "./type-export", "./all",
    "./group", "./lazy", "./common",
  ])
  assert_eq(references[0].file, "src/a.ts")
  assert_eq(references[0].line, 3)
  assert_eq(references[0].column, 1)
}

///|
test "impact sees literal loaders inside function bodies and interpolations" {
  let source =
    #|function load() { return import('./inside') }
    #|const message = `text ${require('./embedded')}`
  let (references, issues) = impact_extract_references("a.js", source, [])
  assert_eq(issues.length(), 0)
  assert_eq(impact_dep_test_paths(references, "import"), [
    "./inside", "./embedded",
  ])
}

///|
test "impact ignores fake modules inside strings comments templates and properties" {
  let source =
    #|// import './comment'
    #|/* require('./block') */
    #|const text = "import './quoted'"
    #|const template = `require('./text-only')`
    #|const regex = /import\('fake'\)/
    #|const object = { import: './property', require(name) { return name } }
    #|object.require('./method')
  let (references, issues) = impact_extract_references("a.ts", source, [])
  assert_eq(references.length(), 0)
  assert_eq(issues.length(), 0)
}

///|
test "impact refuses dynamic concatenated templated and escaped module paths" {
  for
    source in [
      "import(name)", "require(name)", "import('./prefix' + suffix)", "require('./prefix' + suffix)",
      "import(`./dynamic/${name}`)", "import './\\x66oo'", "export * from './\\u0066oo'",
    ] {
    let (references, issues) = impact_extract_references("a.ts", source, [])
    assert_eq(references.length(), 0)
    assert_true(issues.length() > 0)
  }
}

///|
test "impact import meta glob literal patterns become glob references" {
  let source =
    #|const pages = import.meta.glob('./pages/*.vue')
    #|const eager = import.meta.globEager('./other/*.ts')
  let (references, issues) = impact_extract_references("a.ts", source, [])
  assert_eq(references.length(), 2)
  assert_eq(issues.length(), 0)
  assert_eq(references[0].specifier, "./pages/*.vue")
  assert_eq(references[0].kind, "glob-import")
  assert_eq(references[1].specifier, "./other/*.ts")
  assert_eq(references[1].kind, "glob-import")
}

///|
test "impact dynamic import meta glob patterns stay inconclusive" {
  let source =
    #|const pages = import.meta.glob(pattern)
  let (references, issues) = impact_extract_references("a.ts", source, [])
  assert_eq(references.length(), 0)
  assert_eq(issues.length(), 1)
  assert_eq(issues[0].file, "a.ts")
  assert_true(issues[0].reason.contains("glob"))
}

///|
test "impact locally bound require is not mistaken for the module loader" {
  let (references, issues) = impact_extract_references(
    "a.ts",
    "function require(value) { return value }\nrequire('./not-a-module')",
    [],
  )
  assert_eq(references.length(), 0)
  assert_true(issues.length() > 0)
}

///|
test "impact named filesystem aliases record literal root inputs" {
  let source =
    #|import { readFileSync as read, readFile } from 'node:fs'
    #|const a = read('src/a.vue', 'utf8')
    #|readFile('fixtures/input.json', callback)
  let (references, issues) = impact_extract_references("test/a.ts", source, [])
  assert_eq(issues.length(), 0)
  assert_eq(impact_dep_test_paths(references, "read-root"), [
    "src/a.vue", "fixtures/input.json",
  ])
  assert_eq(references[1].line, 2)
  assert_eq(references[1].column, 11)
}

///|
test "impact namespace and default filesystem imports record only supported reads" {
  let source =
    #|import * as fs from 'fs'
    #|import otherFs from 'node:fs'
    #|const a = fs.readFileSync('data/a.json', 'utf8')
    #|otherFs.readFile('data/b.json', callback)
    #|await fs.promises.readFile('data/c.json')
    #|fs.writeFileSync('output.json', 'content')
  let (references, issues) = impact_extract_references("a.ts", source, [])
  assert_eq(issues.length(), 0)
  assert_eq(impact_dep_test_paths(references, "read-root"), [
    "data/a.json", "data/b.json", "data/c.json",
  ])
}

///|
test "impact root resolve and join require a real path import binding" {
  let source =
    #|import { readFileSync } from 'node:fs'
    #|import { resolve as absolute, join } from 'node:path'
    #|import * as path from 'path'
    #|readFileSync(absolute(process.cwd(), 'src', 'one.vue'), 'utf8')
    #|readFileSync(join(process.cwd(), 'data/two.json'), 'utf8')
    #|readFileSync(path.resolve(process.cwd(), 'src/three.ts'), 'utf8')
    #|readFileSync(path.join('fixtures', 'four.json'), 'utf8')
  let (references, issues) = impact_extract_references("test/a.ts", source, [])
  assert_eq(issues.length(), 0)
  assert_eq(impact_dep_test_paths(references, "read-root"), [
    "src/one.vue", "data/two.json", "src/three.ts", "fixtures/four.json",
  ])
}

///|
test "impact rejects indirect dynamic escaped and unsafe URL filesystem paths" {
  for
    expression in [
      "name", "'src/' + name", "'src/\\x66oo'", "`src/${name}`", "resolve(process.cwd(), 'src', name)",
      "fakeResolve(process.cwd(), 'src/a')", "resolve(process.cwd(), '/absolute-reset')",
      "new URL('./data.json?version=1', import.meta.url)",
    ] {
    let source = "import { readFileSync } from 'fs'\nimport { resolve } from 'path'\nreadFileSync(" +
      expression +
      ", 'utf8')\n"
    let (references, issues) = impact_extract_references("a.ts", source, [])
    assert_eq(impact_dep_test_paths(references, "read-root").length(), 0)
    assert_true(issues.length() > 0)
  }
}

///|
test "impact does not infer unbound or unrelated methods as filesystem readers" {
  let source =
    #|function readFileSync(value) { return value }
    #|readFileSync('not-a-file')
    #|object.readFileSync('also-not-a-file')
    #|import { readFile as unrelated } from './custom'
    #|unrelated('not-a-known-reader')
  let (references, issues) = impact_extract_references("a.ts", source, [])
  assert_eq(impact_dep_test_paths(references, "read-root").length(), 0)
  assert_eq(impact_dep_test_paths(references, "import"), ["./custom"])
  assert_eq(issues.length(), 0)
}

///|
test "impact computed fs paths in unconfigured helper definitions force fallback" {
  let source =
    #|import { readFileSync } from 'node:fs'
    #|function readSource(file) { return readFileSync(file.trim(), 'utf8') }
    #|readSource('src/page.vue')
  let (references, issues) = impact_extract_references("test/a.ts", source, [])
  assert_eq(impact_dep_test_paths(references, "read-root").length(), 0)
  assert_true(issues.any(issue => issue.reason.contains("dynamic")))
}

///|
test "impact configured function reader trusts balanced implementation but checks callers" {
  let source =
    #|import { readFileSync } from 'node:fs'
    #|import { resolve } from 'node:path'
    #|function readSource(file: string): string {
    #|  if (file) { return readFileSync(resolve(process.cwd(), file), 'utf8') }
    #|  return readFileSync(file, 'utf8')
    #|}
    #|readSource('src/a.vue')
    #|readSource('src/b.vue')
  let (references, issues) = impact_extract_references("test/a.ts", source, [
    "readSource",
  ])
  assert_eq(issues.length(), 0)
  assert_eq(impact_dep_test_paths(references, "read-root"), [
    "src/a.vue", "src/b.vue",
  ])
  assert_eq(references[2].line, 7)
  assert_eq(references[2].column, 1)
}

///|
test "impact configured root reader still rejects dynamic external calls" {
  let source =
    #|import { readFileSync } from 'fs'
    #|function readSource(file) { return readFileSync(file) }
    #|readSource(variablePath)
    #|readSource('src/' + suffix)
  let (references, issues) = impact_extract_references("a.ts", source, [
    "readSource",
  ])
  assert_eq(impact_dep_test_paths(references, "read-root").length(), 0)
  assert_eq(issues.length(), 2)
  assert_eq(issues[0].line, 3)
  assert_eq(issues[1].line, 4)
}

///|
test "impact configured block arrow reader is a trusted implementation" {
  let source =
    #|import { readFileSync } from 'fs'
    #|const readSource = (file: string) => { return readFileSync(file, 'utf8') }
    #|readSource('data/input.json')
  let (references, issues) = impact_extract_references("a.ts", source, [
    "readSource",
  ])
  assert_eq(issues.length(), 0)
  assert_eq(impact_dep_test_paths(references, "read-root"), ["data/input.json"])
}

///|
test "impact filesystem binding shadowing is explicit uncertainty" {
  for
    source in [
      "import { readFileSync } from 'fs'\nfunction f(readFileSync) { return readFileSync('a') }",
      "import * as fs from 'fs'\nconst f = (fs) => fs.readFileSync('a')", "import { readFile } from 'fs'\nreadFile = other\nreadFile('a')",
    ] {
    let (references, issues) = impact_extract_references("a.ts", source, [])
    assert_eq(impact_dep_test_paths(references, "read-root").length(), 0)
    assert_true(issues.length() > 0)
  }
}

///|
test "impact namespace computed access and reader aliasing force fallback" {
  for
    source in [
      "import * as fs from 'fs'\nfs['readFileSync']('data.json')", "import { readFileSync } from 'fs'\nconst indirect = readFileSync\nindirect('data.json')",
      "import * as fs from 'fs'\nconst alias = fs\nalias.readFileSync('data.json')",
    ] {
    let (_, issues) = impact_extract_references("a.ts", source, [])
    assert_true(issues.length() > 0)
  }
}

///|
test "impact same named object methods are not configured reader calls" {
  let source =
    #|const thing = { readSource(path) { return path } }
    #|thing.readSource('fake')
  let (references, issues) = impact_extract_references("a.ts", source, [
    "readSource",
  ])
  assert_eq(references.length(), 0)
  assert_eq(issues.length(), 0)
}

///|
test "impact Vue only exposes actual top level script content" {
  let source =
    #|<!-- <script>import './comment'</script> -->
    #|<template>
    #|  <view>import './prose'; require('./fake')</view>
    #|  <template v-if="ok"><view>text</view></template>
    #|  {{ "import './moustache'" }}
    #|</template>
    #|<script setup lang="ts">
    #|  const first =
    #|    { ok: true }
    #|  import actual from './actual'
    #|  const later = import('./later')
    #|</script>
    #|<style scoped>.x { content: "require('./css-text')" }</style>
  let (references, issues) = impact_extract_references("src/Page.vue", source, [])
  assert_eq(issues.length(), 0)
  assert_eq(impact_dep_test_paths(references, "import"), ["./actual", "./later"])
  assert_eq(references[0].line, 10)
  assert_eq(references[0].column, 3)
}

///|
test "impact Vue reader coordinates are original file coordinates" {
  let source = "\n<template>prose</template>\n<script setup lang=\"ts\">\n  import foo from './foo'\n  const data = readSource('src/bar')\n</script>\n"
  let (references, issues) = impact_extract_references("Page.vue", source, [
    "readSource",
  ])
  assert_eq(issues.length(), 0)
  assert_eq(references[0].line, 4)
  assert_eq(references[0].column, 3)
  assert_eq(references[1].line, 5)
  assert_eq(references[1].column, 16)
}

///|
test "impact Vue Unicode and CRLF preserve character columns" {
  let source = "<template>🦊</template>\r\n<script>const q = '中'; import x from './x'</script>\r\n"
  let (references, issues) = impact_extract_references("Page.vue", source, [])
  assert_eq(issues.length(), 0)
  assert_eq(references.length(), 1)
  assert_eq(references[0].line, 2)
  assert_eq(references[0].column, 24)
}

///|
test "impact Vue static external src references retain explicit limitations" {
  let source =
    #|<template src="./body.html"></template>
    #|<script src="./logic.ts"></script>
    #|<style src="./skin.css"></style>
  let (references, issues) = impact_extract_references("src/Page.vue", source, [])
  assert_eq(impact_dep_test_paths(references, "read-file"), ["./body.html"])
  assert_eq(impact_dep_test_paths(references, "style-import-css"), [
    "./skin.css",
  ])
  assert_eq(impact_dep_test_paths(references, "import"), ["./logic.ts"])
  assert_true(issues.any(issue => issue.reason.contains("external Vue script")))
  assert_true(
    issues.any(issue => issue.reason.contains("external Vue template")),
  )
}

///|
test "impact Vue custom blocks and unsupported languages are not guessed" {
  for
    source in [
      "<docs>import './fake'</docs>", "<script lang='coffee'>require('./fake')</script>",
      "<template lang='pug'>script import('./fake')</template>", "<template><view></template><script>import './fake'</script>",
    ] {
    let (references, issues) = impact_extract_references("Page.vue", source, [])
    assert_eq(references.length(), 0)
    assert_true(issues.length() > 0)
  }
}

///|
test "impact Vue comments and attribute values cannot introduce top level scripts" {
  let source =
    #|<!-- <script src='./fake.ts'/> -->
    #|<template>
    #|  <view title="<script>import './fake'</script>">plain</view>
    #|</template>
  let (references, issues) = impact_extract_references("Page.vue", source, [])
  assert_eq(references.length(), 0)
  assert_eq(issues.length(), 0)
}

///|
test "impact Vue inline stylesheet inputs are extracted rather than discarded" {
  for
    body in [
      "@import './theme.css';", "@use './theme.scss';", "@forward './shared';", ".x { background: url('./picture.png') }",
    ] {
    let (references, issues) = impact_extract_references(
      "Page.vue",
      "<style lang='scss'>" + body + "</style>",
      [],
    )
    assert_eq(references.length(), 1)
    assert_true(references[0].kind.has_prefix("style-"))
    assert_eq(issues.length(), 0)
  }
  let (_, plain_issues) = impact_extract_references(
    "Page.vue",
    "<style>.x { color: red }</style>",
    [],
  )
  assert_eq(plain_issues.length(), 0)
}

///|
test "impact Vue dynamic stylesheet and unknown preprocessors still require fallback" {
  for
    source in [
      "<style lang='scss'>@use '#{theme}/style';</style>", "<style lang='less'>.x { color: @red }</style>",
      "<style>@use './not-css';</style>",
    ] {
    let (_, issues) = impact_extract_references("Page.vue", source, [])
    assert_true(issues.length() > 0)
  }
}

///|
test "impact JSX is explicitly unsupported rather than interpreting prose as code" {
  let source = "import x from './real'; const page = <div>import './fake'</div>"
  for rel in ["Page.jsx", "Page.tsx"] {
    let (references, issues) = impact_extract_references(rel, source, [])
    assert_eq(references.length(), 0)
    assert_eq(issues.length(), 1)
    assert_true(issues[0].reason.contains("JSX"))
  }
}

///|
test "impact malformed dependency expressions force fallback" {
  for
    source in [
      "import('./x'", "require(variable", "import './unterminated", "import { readFile } from 'fs'; readFile(",
    ] {
    let (_, issues) = impact_extract_references("a.ts", source, [])
    assert_true(issues.length() > 0)
  }
}
