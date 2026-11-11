///|
/// File-read evidence tests use strings only: no host filesystem or JS runs.
fn impact_reads_check(
  source : String,
  rel : String,
) -> (Array[ImpactReference], Array[ImpactIssue]) {
  impact_extract_references(rel, source, [])
}

///|
fn impact_reads_paths(
  references : Array[ImpactReference],
) -> Array[(String, String)] {
  references
  .filter(reference => reference.kind != "import")
  .map(reference => (reference.kind, reference.specifier))
}

///|
test "impact reads root constants and unconfigured pure functions are inferred by body" {
  let source =
    #|import { readFileSync } from 'node:fs'
    #|import { resolve } from 'node:path'
    #|const ROOT = process.cwd()
    #|function read(file: string) { return readFileSync(resolve(ROOT, file), 'utf8') }
    #|const text = read('src/page.vue')
    #|read('src/other.vue')
  let (refs, issues) = impact_reads_check(source, "test/page.spec.ts")
  assert_eq(issues.length(), 0)
  assert_eq(impact_reads_paths(refs), [
    ("read-root", "src/page.vue"),
    ("read-root", "src/other.vue"),
  ])
  assert_eq(refs[2].line, 5)
  assert_eq(refs[2].column, 14)
}

///|
test "impact reads constant names are not hardcoded ROOT or read" {
  let source =
    #|import { readFileSync as bytes } from 'fs'
    #|import * as nodePath from 'path'
    #|const projectHome = process.cwd()
    #|const fixtures = nodePath.resolve(projectHome, 'fixtures')
    #|const inputFile = nodePath.join(fixtures, 'source.txt')
    #|function inspectInput(p: string) { return bytes(nodePath.resolve(projectHome, p), {encoding:'utf8'}) }
    #|inspectInput(inputFile)
  let (refs, issues) = impact_reads_check(source, "test/a.ts")
  assert_eq(issues.length(), 0)
  assert_eq(impact_reads_paths(refs), [("read-root", "fixtures/source.txt")])
}

///|
test "impact reads direct parameter wrappers and simple arrow wrappers" {
  for
    definition in [
      "function load(file) { return readFileSync(file, 'utf8') }", "const load = (file: string) => readFileSync(file, 'utf8')",
      "const load = file => { return readFileSync(file, 'utf8'); }", "const load = function(file) { return readFileSync(file, 'utf8') }",
    ] {
    let (refs, issues) = impact_reads_check(
      "import { readFileSync } from 'fs'\n" + definition + "\nload('input.txt')",
      "test/a.ts",
    )
    assert_eq(issues.length(), 0)
    assert_eq(impact_reads_paths(refs), [("read-root", "input.txt")])
  }
}

///|
test "impact reads unshadowed dirname is file relative" {
  let source =
    #|import { readFileSync } from 'fs'
    #|import { join, resolve } from 'path'
    #|readFileSync(join(__dirname, '../src/a.ts'), 'utf8')
    #|readFileSync(resolve(__dirname, 'fixtures/b.json'), 'utf8')
  let (refs, issues) = impact_reads_check(source, "test/a.ts")
  assert_eq(issues.length(), 0)
  assert_eq(impact_reads_paths(refs), [
    ("read-file", "../src/a.ts"),
    ("read-file", "fixtures/b.json"),
  ])
}

///|
test "impact reads new URL and imported fileURLToPath keep file anchoring" {
  let source =
    #|import { readFileSync } from 'node:fs'
    #|import { fileURLToPath as fromUrl } from 'node:url'
    #|import * as urls from 'url'
    #|readFileSync(new URL('../fixtures/a.txt', import.meta.url), 'utf8')
    #|readFileSync(fromUrl(new URL('./b.txt', import.meta.url)), 'utf8')
    #|readFileSync(urls.fileURLToPath(new URL('./c.txt', import.meta.url)), 'utf8')
  let (refs, issues) = impact_reads_check(source, "test/a.ts")
  assert_eq(issues.length(), 0)
  assert_eq(impact_reads_paths(refs), [
    ("read-file", "../fixtures/a.txt"),
    ("read-file", "./b.txt"),
    ("read-file", "./c.txt"),
  ])
}

///|
test "impact reads derived ESM dirname constants and imported URL aliases" {
  let source =
    #|import { readFileSync } from 'fs'
    #|import { dirname, resolve } from 'path'
    #|import { fileURLToPath, URL as FileUrl } from 'node:url'
    #|const filename = fileURLToPath(import.meta.url)
    #|const __dirname = dirname(filename)
    #|const path = resolve(__dirname, '../src/page.vue')
    #|readFileSync(path, 'utf8')
    #|readFileSync(new FileUrl('./data.txt', import.meta.url), 'utf8')
  let (refs, issues) = impact_reads_check(source, "test/a.ts")
  assert_eq(issues.length(), 0)
  assert_eq(impact_reads_paths(refs), [
    ("read-file", "../src/page.vue"),
    ("read-file", "./data.txt"),
  ])
}

///|
test "impact reads URL objects are only trusted as unescaped direct inputs" {
  let source =
    #|import { readFileSync } from 'fs'
    #|import { fileURLToPath } from 'node:url'
    #|const SOURCE = new URL('./source.txt', import.meta.url)
    #|const textPath = fileURLToPath(SOURCE)
    #|readFileSync(SOURCE, 'utf8')
    #|readFileSync(textPath, 'utf8')
  let (refs, issues) = impact_reads_check(source, "test/a.ts")
  assert_eq(issues.length(), 0)
  assert_eq(impact_reads_paths(refs), [
    ("read-file", "./source.txt"),
    ("read-file", "./source.txt"),
  ])
}

///|
test "impact reads URL fragments queries percent escapes remote URLs are rejected" {
  for
    path in [
      "./a.txt?q=1", "./a.txt#part", "./a%20b.txt", "https://example.invalid/a",
      "file:///etc/passwd", "//other/a", "/etc/passwd",
    ] {
    let source = "import { readFileSync } from 'fs'\nreadFileSync(new URL('" +
      path +
      "', import.meta.url), 'utf8')"
    let (refs, issues) = impact_reads_check(source, "test/a.ts")
    assert_eq(impact_reads_paths(refs).length(), 0)
    assert_true(issues.length() > 0)
  }
}

///|
test "impact reads ordinary FS strings retain query and fragment characters" {
  let source = "import { readFileSync } from 'fs'\nreadFileSync('fixtures/a?#%.txt', 'utf8')"
  let (refs, issues) = impact_reads_check(source, "test/a.ts")
  assert_eq(issues.length(), 0)
  assert_eq(impact_reads_paths(refs), [("read-root", "fixtures/a?#%.txt")])
}

///|
test "impact reads ROOT shadowing and writes do not retain inferred constants" {
  for
    perturb in [
      "function other(ROOT) { return ROOT }", "const other = (ROOT) => ROOT", "class Example { method(ROOT) { return ROOT } }",
      "ROOT = another", "ROOT += '/changed'", "({ ROOT } = unknownObject)",
    ] {
    let source = "import { readFileSync } from 'fs'\nimport { resolve } from 'path'\nconst ROOT = process.cwd()\n" +
      perturb +
      "\nreadFileSync(resolve(ROOT, 'src/a.ts'), 'utf8')"
    let (refs, issues) = impact_reads_check(source, "test/a.ts")
    assert_eq(impact_reads_paths(refs).length(), 0)
    assert_true(issues.length() > 0)
  }
}

///|
test "impact reads cwd mutation is explicit uncertainty" {
  let source = "import { readFileSync } from 'fs'\nimport { resolve } from 'path'\nconst ROOT=process.cwd()\nprocess.chdir('elsewhere')\nreadFileSync(resolve(ROOT, 'src/a.ts'))"
  let (refs, issues) = impact_reads_check(source, "test/a.ts")
  assert_eq(impact_reads_paths(refs).length(), 0)
  assert_true(issues.any(issue => issue.reason.contains("chdir")))
}

///|
test "impact reads namespace method mutation blocks proven callees" {
  for
    perturb in [
      "path.resolve = fake", "fs.readFileSync = fake", "path['resolve'] = fake",
    ] {
    let source = "import * as fs from 'fs'\nimport * as path from 'path'\n" +
      perturb +
      "\nfs.readFileSync(path.resolve(process.cwd(), 'src/a.ts'))"
    let (refs, issues) = impact_reads_check(source, "test/a.ts")
    assert_eq(impact_reads_paths(refs).length(), 0)
    assert_true(issues.length() > 0)
  }
}

///|
test "impact reads fake URL converter and path bindings are not recognized" {
  for
    source in [
      "import { readFileSync } from 'fs'\nconst URL=FakeUrl\nreadFileSync(new URL('./a', import.meta.url))",
      "import { readFileSync } from 'fs'\nfunction f(URL) { return readFileSync(new URL('./a', import.meta.url)) }",
      "import { readFileSync } from 'fs'\nimport { fileURLToPath } from './fake'\nreadFileSync(fileURLToPath(new URL('./a', import.meta.url)))",
      "import { readFileSync } from 'fs'\nimport { resolve } from './fake'\nreadFileSync(resolve(process.cwd(), 'a'))",
      "import { readFileSync } from 'fs'\nglobalThis.URL = fake\nreadFileSync(new URL('./a', import.meta.url))",
      "import { readFileSync } from 'fs'\nimport.meta.url = 'file:///elsewhere/a.js'\nreadFileSync(new URL('./a', import.meta.url))",
    ] {
    let (refs, issues) = impact_reads_check(source, "test/a.ts")
    assert_eq(impact_reads_paths(refs).length(), 0)
    assert_true(issues.length() > 0)
  }
}

///|
test "impact reads mutable URL constant aliases cannot change a proven target" {
  for
    perturb in [
      "SOURCE.pathname = '/another'", "const alias = SOURCE; alias.pathname = '/another'",
      "mutate(SOURCE)",
    ] {
    let source = "import { readFileSync } from 'fs'\nconst SOURCE = new URL('./a.txt', import.meta.url)\n" +
      perturb +
      "\nreadFileSync(SOURCE)"
    let (refs, issues) = impact_reads_check(source, "test/a.ts")
    assert_eq(impact_reads_paths(refs).length(), 0)
    assert_true(issues.length() > 0)
  }
}

///|
test "impact reads wrappers cannot hide additional IO or conditional bodies" {
  for
    body in [
      "const extra = readFileSync('extra.txt'); return readFileSync(file, 'utf8')",
      "if (file) { return readFileSync(file) } return ''", "file = 'elsewhere'; return readFileSync(file)",
      "return readFileSync(file, readFileSync('extra.txt'))", "return readFileSync(file, getOptions())",
      "return readFileSync(file) + readFileSync('extra.txt')", "return\nreadFileSync(file)",
    ] {
    let source = "import { readFileSync } from 'fs'\nfunction load(file) { " +
      body +
      " }\nload('source.txt')"
    let (refs, issues) = impact_reads_check(source, "test/a.ts")
    assert_false(impact_reads_paths(refs).contains(("read-root", "source.txt")))
    assert_true(issues.length() > 0)
    if body.contains("extra.txt") {
      assert_true(impact_reads_paths(refs).contains(("read-root", "extra.txt")))
    }
  }
}

///|
test "impact reads inferred wrappers cannot escape be rebound or be exported" {
  for
    tail in [
      "const alias = load; alias('source.txt')", "consume(load)", "load = other; load('source.txt')",
      "obj.fn = load", "export { load }", "load.call(null, 'source.txt')", "function other(load) { return load('source.txt') }",
      "load(dynamicPath)",
    ] {
    let source = "import { readFileSync } from 'fs'\nfunction load(file) { return readFileSync(file, 'utf8') }\n" +
      tail
    let (_, issues) = impact_reads_check(source, "test/a.ts")
    assert_true(issues.length() > 0)
  }
  let (_, issues) = impact_reads_check(
    "import { readFileSync } from 'fs'\nexport function load(file) { return readFileSync(file) }",
    "test/a.ts",
  )
  assert_true(issues.length() > 0)
}

///|
test "impact reads named function expression does not invent a global reader" {
  let source = "import { readFileSync } from 'fs'\nconst outer = function inner(file) { return readFileSync(file) }; outer('source.txt')"
  let (_, issues) = impact_reads_check(source, "test/a.ts")
  assert_true(issues.length() > 0)
}

///|
test "impact reads path constants reject forward references cycles and continuation expressions" {
  for
    source in [
      "readFileSync(FILE); const FILE = 'source.txt'", "const FILE = OTHER; const OTHER = FILE; readFileSync(FILE)",
      "const FILE = process.cwd()\n + dynamicSuffix\nreadFileSync(FILE)", "let FILE = 'source.txt'; readFileSync(FILE)",
    ] {
    let (refs, issues) = impact_reads_check(
      "import { readFileSync } from 'fs'\n" + source,
      "test/a.ts",
    )
    assert_eq(impact_reads_paths(refs).length(), 0)
    assert_true(issues.length() > 0)
  }
}

///|
test "impact reads above-root paths are never emitted as trusted dependencies" {
  for
    expression in [
      "'../escape.txt'", "resolve(process.cwd(), '../escape.txt')", "new URL('../../escape.txt', import.meta.url)",
    ] {
    let (refs, issues) = impact_reads_check(
      "import { readFileSync } from 'fs'\nimport { resolve } from 'path'\nreadFileSync(" +
      expression +
      ")",
      "test/a.ts",
    )
    assert_eq(impact_reads_paths(refs).length(), 0)
    assert_true(issues.length() > 0)
  }
}

///|
test "impact reads configured contracts remain a separate opt-in mode" {
  let source = "import { readFileSync } from 'fs'\nfunction contract(file) { if (file) return readFileSync(file); return '' }\ncontract('source.txt')"
  let (refs, issues) = impact_extract_references("test/a.ts", source, [
    "contract",
  ])
  assert_eq(issues.length(), 0)
  assert_eq(impact_reads_paths(refs), [("read-root", "source.txt")])
}

///|
test "impact reads file-relative URL evidence retains Unicode CRLF coordinates" {
  let source = "import { readFileSync } from 'fs'\r\nconst note='中'; readFileSync(new URL('./数据.txt', import.meta.url));\r\n"
  let (refs, issues) = impact_reads_check(source, "test/a.ts")
  assert_eq(issues.length(), 0)
  let read = refs.filter(reference => reference.kind == "read-file")[0]
  assert_eq(read.line, 2)
  assert_eq(read.column, 17)
  assert_eq(read.specifier, "./数据.txt")
}

///|
test "impact reads symbolic evaluation depth is bounded for nested calls" {
  let mut expression = "process.cwd()"
  for _ in 0..<80 {
    expression = "resolve(" + expression + ", 'nested')"
  }
  let source = "import { readFileSync } from 'fs'\nimport { resolve } from 'path'\nreadFileSync(" +
    expression +
    ")"
  let (refs, issues) = impact_reads_check(source, "test/a.ts")
  assert_eq(impact_reads_paths(refs).length(), 0)
  assert_true(issues.length() > 0)
}

///|
test "impact reads dirname refuses normalization-sensitive symbolic values" {
  for
    expression in [
      "dirname(resolve(process.cwd(), 'src', '..'))", "dirname(join(__dirname, 'nested', '..'))",
      "dirname(fileURLToPath(new URL('./nested/../a.txt', import.meta.url)))",
    ] {
    let source = "import { readFileSync } from 'fs'\nimport { resolve, join, dirname } from 'path'\nimport { fileURLToPath } from 'node:url'\nreadFileSync(" +
      expression +
      ")"
    let (refs, issues) = impact_reads_check(source, "test/a.ts")
    assert_eq(impact_reads_paths(refs).length(), 0)
    assert_true(issues.length() > 0)
  }
}

///|
test "impact reads URL whitespace is not preserved as a false filename" {
  for
    path in [" ./a.txt", "./a.txt ", "./a\tb.txt", "\t./a.txt", "./a.txt\u{C}"] {
    let source = "import { readFileSync } from 'fs'\nreadFileSync(new URL('" +
      path +
      "', import.meta.url))"
    let (refs, issues) = impact_reads_check(source, "test/a.ts")
    assert_eq(impact_reads_paths(refs).length(), 0)
    assert_true(issues.length() > 0)
  }
}

///|
test "impact reads ordinary FS filenames keep leading trailing and internal spaces" {
  let source = "import { readFileSync } from 'fs'\nreadFileSync(' a b?#%.txt ', 'utf8')"
  let (refs, issues) = impact_reads_check(source, "test/a.ts")
  assert_eq(issues.length(), 0)
  assert_eq(impact_reads_paths(refs), [("read-root", " a b?#%.txt ")])
}

///|
test "impact reads a read-only import meta env cast is not a filesystem uncertainty" {
  let (refs, issues) = impact_reads_check(
    "const platform = (import.meta as any).env?.UNI_PLATFORM", "src/platform.ts",
  )
  assert_eq(refs.length(), 0)
  assert_eq(issues.length(), 0)
  let source = "import { readFileSync } from 'fs'\nconst escaped = import.meta\nmutate(escaped)\nreadFileSync(new URL('./file', import.meta.url))"
  let (unsafe_refs, unsafe_issues) = impact_reads_check(source, "test/a.ts")
  assert_eq(impact_reads_paths(unsafe_refs).length(), 0)
  assert_true(unsafe_issues.length() > 0)
}
