///|
test "moonbit inventory includes inline tests and executable documentation" {
  assert_true(
    impact_mbt_source_contains_tests(
      "lib.mbt", "test \"inline\" { assert_true(true) }",
    ),
  )
  assert_true(
    !impact_mbt_source_contains_tests(
      "lib.mbt", "// test \"comment\" {}\nlet s = \"test {}\"",
    ),
  )
  assert_true(
    impact_mbt_source_contains_tests(
      "README.mbt.md", "```mbt test\ntest { assert_true(true) }\n```",
    ),
  )
  assert_true(
    impact_mbt_source_contains_tests(
      "README.mbt.md", "```mbt check\ntest {}\n```",
    ),
  )
  assert_true(
    impact_mbt_source_contains_tests(
      "lib.mbt", "/// ```mbt test\n/// test { assert_true(true) }\n/// ```\npub fn f() -> Unit {}",
    ),
  )
  assert_true(
    !impact_mbt_source_contains_tests("README.md", "```mbt test\ntest {}\n```"),
  )
  assert_true(
    impact_mbt_source_contains_tests(
      "lib.mbt", "/// ```mbt check\n/// test {}\n/// ```\npub fn f() -> Unit {}",
    ),
  )
}

///|
test "source directory maps module import names to disk packages" {
  for
    descriptor in [
      ("moon.mod", "name = \"demo/mod\"\nsource = \"src\"\n"),
      ("moon.mod.json", "{\"name\":\"demo/mod\",\"source\":\"src\"}"),
    ] {
    let sources = [
      descriptor,
      ("src/base/moon.pkg", ""),
      (
        "src/base/base.mbt", "pub fn value() -> Int { 1 }\ntest { assert_eq(value(), 1) }",
      ),
      ("src/use/moon.pkg", "import { \"demo/mod/base\", }"),
      ("src/use/use.mbt", "test { assert_true(true) }"),
      ("src/doc/moon.pkg", ""),
      ("src/doc/README.mbt.md", "```mbt test\ntest {}\n```"),
    ]
    let plan = impact_moonbit_plan_from(
      "/fixture",
      sources.map(p => p.0),
      sources,
      ["src/base/base.mbt"],
      "explicit",
      [],
    )
    assert_eq(plan.strategy, "related")
    assert_eq(plan.tests, ["src/base", "src/use"])
    assert_eq(plan.inventory, ["src/base", "src/doc", "src/use"])
  }
}

///|
test "nested modules resolve source directories independently" {
  let sources = [
    ("moon.mod", "name = \"demo/root\"\nsource = \"src\""),
    ("other/moon.mod", "name = \"demo/other\"\nsource = \"code\""),
    ("other/code/base/moon.pkg", ""),
    ("other/code/base/value.mbt", "test {}"),
    ("other/code/use/moon.pkg", "import { \"demo/other/base\", }"),
    ("other/code/use/value.mbt", "test {}"),
  ]
  let plan = impact_moonbit_plan_from(
    "/fixture",
    sources.map(p => p.0),
    sources,
    ["other/code/base/value.mbt"],
    "explicit",
    [],
  )
  assert_eq(plan.tests, ["other/code/base", "other/code/use"])
}

///|
test "unsupported source layout requests full even with no static inventory" {
  let sources = [
    ("moon.mod", "name = \"demo/mod\"\nsource = \"../escape\""),
    ("moon.pkg", ""),
    ("lib.mbt", "pub fn f() -> Unit {}"),
  ]
  let plan = impact_moonbit_plan_from(
    "/fixture",
    sources.map(p => p.0),
    sources,
    ["lib.mbt"],
    "explicit",
    [],
  )
  assert_eq(plan.strategy, "full")
  assert_true(!plan.issues.is_empty())
}

///|
test "legacy JSON manifests preserve source test and whitebox edges" {
  let sources = [
    ("moon.mod.json", "{\"name\":\"demo/mod\"}"),
    ("base/moon.pkg.json", "{}"),
    ("base/value.mbt", "test {}"),
    (
      "normal/moon.pkg.json", "{\"import\":[{\"path\":\"demo/mod/base\",\"alias\":\"b\"}]}",
    ),
    ("normal/value.mbt", "test {}"),
    ("black/moon.pkg.json", "{\"test-import\":[\"demo/mod/base\"]}"),
    ("black/value.mbt", "test {}"),
    ("white/moon.pkg.json", "{\"wbtest-import\":[\"demo/mod/base\"]}"),
    ("white/value.mbt", "test {}"),
  ]
  let plan = impact_moonbit_plan_from(
    "/fixture",
    sources.map(p => p.0),
    sources,
    ["base/value.mbt"],
    "explicit",
    [],
  )
  assert_eq(plan.strategy, "related")
  assert_eq(plan.tests, ["base", "black", "normal", "white"])
  assert_eq(impact_mbt_manifest_imports("{\"import\":false}", "import"), None)
  assert_eq(impact_mbt_manifest_imports("{\"import\":[17]}", "import"), None)
}

///|
test "manifest metadata comments and quoted import text cannot invent dependencies" {
  let source = "// import { \"demo/ghost\", }\n" +
    "description = \"import { ignored }\"\n" +
    "import { \"demo/mod/base\" @deep/b, // ignored \"quote\n}\n" +
    "#cfg(target=\"native\")\nimport { \"demo/mod/native\", } for \"wbtest\""
  assert_eq(
    impact_mbt_manifest_imports(source, "import"),
    Some(["demo/mod/base", "demo/mod/native"]),
  )
  assert_eq(
    impact_mbt_manifest_imports("import { unknown_expression }", "import"),
    None,
  )
}

///|
test "workspace membership changes always request full regression" {
  let plan = impact_mbt_fixture_plan(["moon.work"])
  assert_eq(plan.strategy, "full")
  assert_true(plan.reasons.contains("global-input-changed: moon.work"))
}
