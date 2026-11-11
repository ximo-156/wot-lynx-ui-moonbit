///|
fn impact_fixture_sources() -> Array[(String, String)] {
  [
    ("src/value.ts", "export const value = 1;\n"),
    (
      "src/wrapper.ts", "import { value } from './value';\nexport const wrapped = value;\n",
    ),
    ("src/other.ts", "export const other = 2;\n"),
    (
      "test/value.test.ts", "import { wrapped } from '../src/wrapper';\nconsole.log(wrapped);\n",
    ),
    (
      "test/other.test.ts", "import { other } from '../src/other';\nconsole.log(other);\n",
    ),
  ]
}

///|
fn impact_fixture_plan(
  changes : Array[String],
  config : ImpactConfig,
) -> ImpactPlan raise {
  let files = impact_fixture_sources()
  build_impact_plan(
    "/fixture",
    files,
    files.map(pair => pair.0),
    changes,
    config,
    "explicit",
    [],
  )
}

///|
test "impact configuration is independent strict inert JSON" {
  let config = parse_impact_config(
    "{\"version\":1,\"aliases\":{\"@\":\"src\"},\"file_readers\":[\"readSource\"],\"include\":[\"src/**\",\"test/**\"]}",
  )
  assert_eq(config.aliases, [("@", "src")])
  assert_eq(config.file_readers, ["readSource"])
  assert_eq(config.max_source_bytes, 2000000)
  for
    json in [
      "[]", "{broken", "{\"tests\":[]}", "{\"version\":2}", "{\"command\":\"echo bad\"}",
      "{\"file_readers\":[\"x.y\"]}", "{\"include\":[\"../escape\"]}", "{\"aliases\":{\"@\":\"/absolute\"}}",
      "{\"aliases\":{\"@\":\"src/..\"}}", "{\"aliases\":{\"@\":1}}", "{\"aliases\":{\"@\":\"src\",\"@/\":\"elsewhere\"}}",
      "{\"max_source_bytes\":0}", "{\"max_source_bytes\":1.5}", "{\"tests\":[],\"tests\":[\"test/**\"]}",
    ] {
    let rejected = try {
      ignore(parse_impact_config(json))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}

///|
test "impact follows reverse transitive imports to relevant tests" {
  let plan = impact_fixture_plan(["src/value.ts"], impact_default_config())
  assert_eq(plan.strategy, "related")
  assert_eq(plan.tests, ["test/value.test.ts"])
  assert_eq(plan.inventory, ["test/other.test.ts", "test/value.test.ts"])
  assert_eq(plan.traces.length(), 1)
  assert_eq(plan.traces[0].chain.length(), 2)
  assert_eq(plan.traces[0].chain[0].dependency, "src/value.ts")
  assert_eq(plan.traces[0].chain[0].dependent, "src/wrapper.ts")
  assert_eq(plan.traces[0].chain[1].dependent, "test/value.test.ts")
  assert_eq(plan.traces[0].chain[1].line, 1)
  assert_eq(plan.issues.length(), 0)
}

///|
test "impact explicit changes are normalized deduplicated and stable" {
  let config = impact_default_config()
  let a = impact_fixture_plan(
    ["./src/value.ts", "src/value.ts", "src/other.ts"],
    config,
  )
  let b = impact_fixture_plan(["src/other.ts", "src/value.ts"], config)
  assert_eq(a.changed, b.changed)
  assert_eq(render_impact_json(a), render_impact_json(b))
  assert_eq(a.tests, a.inventory)
}

///|
test "impact refuses escaped absolute and binary input paths" {
  for path in ["../value.ts", "/src/value.ts", "C:\\value.ts", "a\u{0}.ts"] {
    let rejected = try {
      ignore(impact_fixture_plan([path], impact_default_config()))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}

///|
test "impact a directly changed test has an empty witness chain" {
  let plan = impact_fixture_plan(
    ["test/value.test.ts"],
    impact_default_config(),
  )
  assert_eq(plan.strategy, "related")
  assert_eq(plan.tests, ["test/value.test.ts"])
  assert_eq(plan.traces[0].chain.length(), 0)
  assert_eq(plan.traces[0].changed, "test/value.test.ts")
}

///|
test "impact empty changes do not pretend to execute tests" {
  let plan = impact_fixture_plan([], impact_default_config())
  assert_eq(plan.strategy, "none")
  assert_eq(plan.tests.length(), 0)
  assert_eq(plan.traces.length(), 0)
  assert_true(plan.reasons[0].has_prefix("no-changes"))
}

///|
test "impact unresolved and dynamic imports fall back to full inventory" {
  for
    source in [
      "import { value } from './missing';\nexport const wrapper = value;\n", "export const load = () => import(dynamicPath);\n",
      "import { value } from '@/missing';\n",
    ] {
    let files = impact_fixture_sources()
    files[1] = ("src/wrapper.ts", source)
    let plan = build_impact_plan(
      "/fixture",
      files,
      files.map(pair => pair.0),
      ["src/value.ts"],
      impact_default_config(),
      "explicit",
      [],
    )
    assert_eq(plan.strategy, "full")
    assert_eq(plan.tests, plan.inventory)
    assert_true(plan.issues.length() > 0)
  }
}

///|
test "impact deletion and rename old paths request a full regression" {
  let plan = impact_fixture_plan(
    ["src/deleted.ts", "src/value.ts"],
    impact_default_config(),
  )
  assert_eq(plan.strategy, "full")
  assert_true(
    plan.reasons.any(reason => reason.has_prefix("removed-or-missing-input")),
  )
}

///|
test "impact changing global configuration requests full regression" {
  let plan = impact_fixture_plan(["package.json"], impact_default_config())
  assert_eq(plan.strategy, "full")
  assert_true(
    plan.reasons.any(reason => reason.has_prefix("global-input-changed")),
  )
}

///|
test "impact all tests are not the same as a known evidence chain" {
  let plan = impact_fixture_plan(
    ["src/value.ts", "package.json"],
    impact_default_config(),
  )
  assert_eq(plan.strategy, "full")
  assert_eq(plan.tests.length(), 2)
  assert_eq(plan.traces.length(), 1)
  assert_eq(plan.traces[0].test_file, "test/value.test.ts")
}

///|
test "impact configured root readers create non-import data dependencies" {
  let files : Array[(String, String)] = [
    ("test/theme.test.ts", "const css = readSource('src/theme.scss');\n"),
    ("test/other.test.ts", "const unrelated = 1;\n"),
  ]
  let config = parse_impact_config("{\"file_readers\":[\"readSource\"]}")
  let plan = build_impact_plan(
    "/fixture",
    files,
    ["test/theme.test.ts", "test/other.test.ts", "src/theme.scss"],
    ["src/theme.scss"],
    config,
    "explicit",
    [],
  )
  assert_eq(plan.strategy, "related")
  assert_eq(plan.tests, ["test/theme.test.ts"])
  assert_eq(plan.traces[0].chain[0].kind, "read-root")
  assert_eq(plan.traces[0].chain[0].line, 1)
}

///|
test "impact explicit dependency edges retain config provenance" {
  let files = impact_fixture_sources()
  let config = parse_impact_config(
    "{\"dependencies\":[{\"dependent\":\"test/value.test.ts\",\"dependency\":\"src/theme.scss\"}]}",
  )
  let paths = files.map(pair => pair.0)
  paths.push("src/theme.scss")
  let plan = build_impact_plan(
    "/fixture",
    files,
    paths,
    ["src/theme.scss"],
    config,
    "explicit",
    [],
  )
  assert_eq(plan.strategy, "related")
  assert_eq(plan.traces[0].chain[0].kind, "explicit")
  assert_eq(plan.traces[0].chain[0].line, 0)
}

///|
test "impact configured aliases are segment-bounded and root-relative" {
  let files : Array[(String, String)] = [
    ("src/value.ts", "export const value = 1;\n"),
    (
      "test/value.test.ts", "import { value } from '@/value';\nimport { it } from '@scope/package';\nit(value);\n",
    ),
  ]
  let config = parse_impact_config("{\"aliases\":{\"@\":\"src\"}}")
  let plan = build_impact_plan(
    "/fixture",
    files,
    files.map(pair => pair.0),
    ["src/value.ts"],
    config,
    "explicit",
    [],
  )
  assert_eq(plan.strategy, "related")
  assert_eq(plan.issues.length(), 0)
}

///|
test "impact ambiguous extensions never yield a confident selective plan" {
  let files = impact_fixture_sources()
  files.push(("src/value.js", "export const value = 2;\n"))
  let plan = build_impact_plan(
    "/fixture",
    files,
    files.map(pair => pair.0),
    ["src/value.ts"],
    impact_default_config(),
    "explicit",
    [],
  )
  assert_eq(plan.strategy, "full")
  assert_true(
    plan.issues.any(issue => issue.reason.has_prefix("ambiguous-input")),
  )
}

///|
test "impact cycles terminate and evidence is the shortest known chain" {
  let files : Array[(String, String)] = [
    ("src/a.ts", "import './b';\n"),
    ("src/b.ts", "import './a';\n"),
    ("test/a.test.ts", "import '../src/a';\n"),
  ]
  let plan = build_impact_plan(
    "/fixture",
    files,
    files.map(pair => pair.0),
    ["src/a.ts"],
    impact_default_config(),
    "explicit",
    [],
  )
  assert_eq(plan.strategy, "related")
  assert_eq(plan.tests, ["test/a.test.ts"])
  assert_eq(plan.traces[0].chain.length(), 1)
}

///|
test "impact missing inventory and read failures block execution" {
  let files : Array[(String, String)] = [
    ("src/value.ts", "export const x = 1;\n"),
  ]
  let plan = build_impact_plan(
    "/fixture",
    files,
    ["src/value.ts"],
    ["src/value.ts"],
    impact_default_config(),
    "explicit",
    [],
  )
  assert_eq(plan.strategy, "blocked")
  let all = impact_fixture_sources()
  let blocked = build_impact_plan(
    "/fixture",
    all,
    all.map(pair => pair.0),
    ["src/value.ts"],
    impact_default_config(),
    "explicit",
    [{ file: "test/broken.test.ts", line: 0, reason: "io: invalid UTF-8", }],
  )
  assert_eq(blocked.strategy, "blocked")
  assert_eq(blocked.tests.length(), 0)
}

///|
test "impact report escapes HTML and is a plan rather than a test verdict" {
  let plan = impact_fixture_plan(["src/value.ts"], impact_default_config())
  let unsafe = ImpactPlan::{
    ..plan,
    root: "</title><script>alert('x')</script>",
  }
  let html = render_impact_html(unsafe)
  assert_false(html.contains("<script>"))
  assert_true(html.contains("&lt;script&gt;"))
  assert_true(html.contains("Content-Security-Policy"))
  assert_true(render_impact_text(plan).contains("not a passing test result"))
  let json = @json.parse(render_impact_json(plan))
  assert_true(
    json is Object(obj) && obj.get("kind") == Some(Json::string("test-plan")),
  )
}
