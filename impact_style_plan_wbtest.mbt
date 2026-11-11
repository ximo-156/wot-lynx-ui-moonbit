///|
fn impact_style_fixture() -> Array[(String, String)] {
  [
    (
      "src/App.vue", "<template><view>demo</view></template>\n<style lang=\"scss\">\n@use '@/styles/theme' as *;\n</style>\n",
    ),
    (
      "src/styles/theme.scss", "@use './palette' as *;\n@import './fonts.css';\n",
    ),
    ("src/styles/_palette.scss", "$accent: red;\n"),
    (
      "src/styles/fonts.css", "@font-face { src: url('./font.woff2?v=1#glyph'); }\n",
    ),
    ("test/theme.test.ts", "const page = readSource('src/App.vue');\n"),
    ("test/other.test.ts", "const other = 1;\n"),
  ]
}

///|
fn impact_style_fixture_plan(changes : Array[String]) -> ImpactPlan raise {
  let sources = impact_style_fixture()
  let paths = sources.map(pair => pair.0)
  paths.push("src/styles/font.woff2")
  let config = parse_impact_config(
    "{\"aliases\":{\"@\":\"src\"},\"file_readers\":[\"readSource\"]}",
  )
  build_impact_plan("/fixture", sources, paths, changes, config, "explicit", [])
}

///|
test "impact Sass partial changes flow through Vue styles to tests" {
  let plan = impact_style_fixture_plan(["src/styles/_palette.scss"])
  assert_eq(plan.strategy, "related")
  assert_eq(plan.tests, ["test/theme.test.ts"])
  assert_eq(plan.traces[0].chain.length(), 3)
  assert_eq(plan.traces[0].chain[0].dependency, "src/styles/_palette.scss")
  assert_eq(plan.traces[0].chain[0].dependent, "src/styles/theme.scss")
  assert_eq(plan.traces[0].chain[1].dependent, "src/App.vue")
  assert_eq(plan.traces[0].chain[2].kind, "read-root")
}

///|
test "impact font URL query and fragment do not hide the asset dependency" {
  let plan = impact_style_fixture_plan(["src/styles/font.woff2"])
  assert_eq(plan.strategy, "related")
  assert_eq(plan.tests, ["test/theme.test.ts"])
  assert_eq(plan.traces[0].chain.length(), 4)
  assert_eq(plan.traces[0].chain[0].kind, "style-url")
  assert_eq(plan.traces[0].chain[0].dependency, "src/styles/font.woff2")
}

///|
test "impact style resolver skips external URLs but not dynamic local paths" {
  let config = impact_default_config()
  let paths : Set[String] = Set([])
  let edges : Array[ImpactEdge] = []
  let issues : Array[ImpactIssue] = []
  for
    spec in [
      "https://cdn.invalid/a.woff2?v=1", "//cdn.invalid/a.png", "data:image/svg+xml,%3Csvg/%3E",
      "#local-symbol",
    ] {
    impact_resolve_style_reference(
      {
        file: "src/a.css",
        specifier: spec,
        kind: "style-url",
        line: 1,
        column: 1,
      },
      paths,
      config,
      edges,
      issues,
    )
  }
  assert_eq(edges.length(), 0)
  assert_eq(issues.length(), 0)
  impact_resolve_style_reference(
    {
      file: "src/a.scss",
      specifier: "#{theme}/icon.png",
      kind: "style-url",
      line: 2,
      column: 3,
    },
    paths,
    config,
    edges,
    issues,
  )
  assert_eq(issues.length(), 1)
  assert_true(issues[0].reason.has_prefix("dynamic-style-path"))
}

///|
test "impact style resolver rejects ambiguous partial and legacy importer choices" {
  let config = impact_default_config()
  for
    candidates in [
      ["src/theme.scss", "src/_theme.scss"],
      ["src/theme.scss", "src/_theme.import.scss"],
    ] {
    let edges : Array[ImpactEdge] = []
    let issues : Array[ImpactIssue] = []
    impact_resolve_style_reference(
      {
        file: "src/a.scss",
        specifier: "./theme",
        kind: "style-import-scss",
        line: 1,
        column: 7,
      },
      Set::from_iter(candidates.iter()),
      config,
      edges,
      issues,
    )
    assert_eq(edges.length(), 0)
    assert_eq(issues.length(), 1)
  }
}

///|
test "impact style URL absolute percent encoded and escaping paths stay inconclusive" {
  let edges : Array[ImpactEdge] = []
  let issues : Array[ImpactIssue] = []
  for
    spec in [
      "/public/a.png", "../../outside.png", "font%20name.ttf", "file:///private/a.ttf",
      "javascript:alert(1)",
    ] {
    impact_resolve_style_reference(
      {
        file: "src/a.css",
        specifier: spec,
        kind: "style-url",
        line: 1,
        column: 1,
      },
      Set([]),
      impact_default_config(),
      edges,
      issues,
    )
  }
  assert_eq(edges.length(), 0)
  assert_eq(issues.length(), 5)
}

///|
test "impact escaping configured aliases are not mistaken for external npm" {
  let config = parse_impact_config(
    "{\"aliases\":{\"local\":\"src\",\"@scope/pkg\":\"src\"}}",
  )
  let edges : Array[ImpactEdge] = []
  let issues : Array[ImpactIssue] = []
  impact_resolve_reference(
    {
      file: "test/a.test.ts",
      specifier: "local/../../outside",
      kind: "import",
      line: 1,
      column: 1,
    },
    Set([]),
    config,
    edges,
    issues,
  )
  impact_resolve_reference(
    {
      file: "src/a.scss",
      specifier: "@scope/pkg/../../../outside",
      kind: "style-import-scss",
      line: 1,
      column: 1,
    },
    Set([]),
    config,
    edges,
    issues,
  )
  assert_eq(edges.length(), 0)
  assert_eq(issues.length(), 2)
}

///|
test "impact imported styles require a parsed body for transitive analysis" {
  let sources : Array[(String, String)] = [
    ("test/a.test.ts", "import '../src/a.css';\n"),
  ]
  let plan = build_impact_plan(
    "/fixture",
    sources,
    ["test/a.test.ts", "src/a.css"],
    ["src/a.css"],
    impact_default_config(),
    "explicit",
    [],
  )
  assert_eq(plan.strategy, "full")
  assert_true(
    plan.issues.any(issue => {
      issue.reason.has_prefix("style-source-not-analyzed")
    }),
  )
}

///|
test "impact raw source reads outside includes remain opaque leaf inputs" {
  let config = parse_impact_config(
    "{\"include\":[\"test/**\"],\"file_readers\":[\"readSource\"]}",
  )
  let sources : Array[(String, String)] = [
    ("test/a.test.ts", "const text = readSource('outside.ts');\n"),
  ]
  let plan = build_impact_plan(
    "/fixture",
    sources,
    ["test/a.test.ts", "outside.ts"],
    ["test/a.test.ts"],
    config,
    "explicit",
    [],
  )
  assert_eq(plan.strategy, "related")
  assert_eq(plan.issues.length(), 0)
}

///|
test "impact raw file reads retain literal question marks and hashes" {
  let config = parse_impact_config("{\"file_readers\":[\"readSource\"]}")
  let sources : Array[(String, String)] = [
    ("test/a.test.ts", "const text = readSource('data/file?#raw.txt');\n"),
  ]
  let plan = build_impact_plan(
    "/fixture",
    sources,
    ["test/a.test.ts", "data/file?#raw.txt"],
    ["data/file?#raw.txt"],
    config,
    "explicit",
    [],
  )
  assert_eq(plan.strategy, "related")
  assert_eq(plan.traces[0].chain[0].dependency, "data/file?#raw.txt")
}

///|
test "impact stylesheet modules outside the analysis scope still request full fallback" {
  let config = parse_impact_config("{\"include\":[\"test/**\"]}")
  let sources : Array[(String, String)] = [
    ("test/a.test.ts", "import '../outside.css';\n"),
  ]
  let plan = build_impact_plan(
    "/fixture",
    sources,
    ["test/a.test.ts", "outside.css"],
    ["test/a.test.ts"],
    config,
    "explicit",
    [],
  )
  assert_eq(plan.strategy, "full")
  assert_true(
    plan.issues.any(issue => issue.reason.has_prefix("excluded-source-input")),
  )
}

///|
test "impact unknown Sass interpolation keeps the full fallback" {
  let sources : Array[(String, String)] = [
    ("src/a.scss", "@use '#{chosen}/theme';\n"),
    ("test/a.test.ts", "import '../src/a.scss';\n"),
  ]
  let plan = build_impact_plan(
    "/fixture",
    sources,
    sources.map(pair => pair.0),
    ["src/a.scss"],
    impact_default_config(),
    "explicit",
    [],
  )
  assert_eq(plan.strategy, "full")
  assert_true(plan.issues.length() > 0)
}
