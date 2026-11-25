///|
/// Pure fixtures for workspace-level module linking and conservative fallbacks.
/// All inputs are strings; these tests do not touch the filesystem.

///|
fn impact_mbt_workspace_plan(
  sources : Array[(String, String)],
  changes : Array[String],
) -> ImpactPlan raise {
  impact_moonbit_plan_from(
    "/fixture",
    sources.map(pair => pair.0),
    sources,
    changes,
    "explicit",
    [],
  )
}

///|
fn impact_mbt_workspace_modules_sources() -> Array[(String, String)] {
  [
    ("moon.work", "members = [\".\", \"./lib\", \"./app\"]\n"),
    ("moon.mod", "name = \"fixture/root\"\n"),
    ("moon.pkg", ""),
    ("lib/moon.mod", "name = \"fixture/lib\"\nsource = \"src\"\n"),
    ("lib/src/value/moon.pkg", ""),
    ("lib/src/value/value.mbt", "pub fn value() -> Int { 1 }\n"),
    ("app/moon.mod", "name = \"fixture/app\"\n"),
    ("app/moon.pkg", "test-import {\n  \"fixture/lib/value\" @value,\n}\n"),
    ("app/app_test.mbt", "test { assert_eq(@value.value(), 1) }\n"),
  ]
}

///|
test "workspace library changes reach test-only importers with evidence" {
  let sources = impact_mbt_workspace_modules_sources()
  let plan = impact_mbt_workspace_plan(sources, ["lib/src/value/value.mbt"])
  assert_eq(plan.strategy, "related")
  assert_eq(plan.tests, ["app"])
  assert_true(plan.traces.length() == 1)
  let trace = plan.traces[0]
  assert_eq(trace.test_file, "app")
  assert_eq(trace.changed, "lib/src/value/value.mbt")
  assert_eq(trace.chain.length(), 2)
  assert_eq(trace.chain[0].dependency, "lib/src/value/value.mbt")
  assert_eq(trace.chain[0].dependent, "lib/src/value")
  assert_eq(trace.chain[0].kind, "owns")
  assert_eq(trace.chain[1].dependency, "lib/src/value")
  assert_eq(trace.chain[1].dependent, "app")
  assert_eq(trace.chain[1].kind, "test-imports")
  assert_true(plan.issues.is_empty())
}

///|
test "workspace-only roots discover member modules and their dependency graph" {
  let sources = [
    ("moon.work", "members = [\"./lib\", \"./app\"]\n"),
    ("lib/moon.mod", "name = \"fixture/lib\"\nsource = \"src\"\n"),
    ("lib/src/value/moon.pkg", ""),
    ("lib/src/value/value.mbt", "pub fn value() -> Int { 1 }\n"),
    ("app/moon.mod", "name = \"fixture/app\"\n"),
    ("app/moon.pkg", "test-import {\n  \"fixture/lib/value\" @value,\n}\n"),
    ("app/app_test.mbt", "test { assert_eq(@value.value(), 1) }\n"),
  ]
  let plan = impact_mbt_workspace_plan(sources, ["lib/src/value/value.mbt"])
  assert_eq(plan.strategy, "related")
  assert_eq(plan.tests, ["app"])
  assert_true(
    plan.traces.any(trace => {
      trace.test_file == "app" &&
      trace.chain.length() == 2 &&
      trace.chain[1].dependent == "app" &&
      trace.chain[1].kind == "test-imports"
    }),
  )
  assert_true(plan.issues.is_empty())
}

///|
test "independent nested modules without workspace membership stay uncertain" {
  let sources = [
    ("moon.mod", "name = \"fixture/root\"\n"),
    ("moon.pkg", ""),
    ("nested/lib/moon.mod", "name = \"fixture/lib\"\n"),
    ("nested/lib/value/moon.pkg", ""),
    ("nested/lib/value/value.mbt", "pub fn value() -> Int { 1 }\n"),
    ("nested/app/moon.mod", "name = \"fixture/app\"\n"),
    (
      "nested/app/moon.pkg", "test-import {\n  \"fixture/lib/value\" @value,\n}\n",
    ),
    ("nested/app/app_test.mbt", "test { assert_true(@value.value() == 1) }\n"),
  ]
  let plan = impact_mbt_workspace_plan(sources, ["nested/lib/value/value.mbt"])
  assert_eq(plan.strategy, "full")
  assert_true(!plan.issues.is_empty())
  assert_true(!plan.affected.contains("nested/app"))
}

///|
test "escaped text module names resolve to decoded import paths" {
  let sources = [
    ("moon.mod", "name = \"fixture\\u002fescaped\"\n"),
    ("moon.pkg", ""),
    ("base/moon.pkg", ""),
    ("base/value.mbt", "pub fn value() -> Int { 1 }\n"),
    ("use/moon.pkg", "import {\n  \"fixture/escaped/base\" @base,\n}\n"),
    ("use/use_test.mbt", "test { assert_eq(@base.value(), 1) }\n"),
  ]
  let plan = impact_mbt_workspace_plan(sources, ["base/value.mbt"])
  assert_eq(plan.strategy, "related")
  assert_eq(plan.tests, ["use"])
  assert_true(
    plan.traces.any(trace => {
      trace.test_file == "use" &&
      trace.chain.length() == 2 &&
      trace.chain[1].dependent == "use" &&
      trace.chain[1].kind == "imports"
    }),
  )
  assert_true(plan.issues.is_empty())
}

///|
test "malformed nested module descriptors preserve an uncertainty boundary" {
  let sources = [
    ("moon.mod", "name = \"fixture/root\"\n"),
    ("moon.pkg", ""),
    ("nested/moon.mod", "name = ???\n"),
    ("nested/base/moon.pkg", ""),
    ("nested/base/value.mbt", "pub fn value() -> Int { 1 }\n"),
    ("nested/use/moon.pkg", "test-import { \"fixture/nested/base\" @base, }\n"),
    ("nested/use/use_test.mbt", "test { assert_true(true) }\n"),
  ]
  let plan = impact_mbt_workspace_plan(sources, ["nested/base/value.mbt"])
  assert_eq(plan.strategy, "full")
  assert_true(plan.issues.any(issue => issue.file == "nested/moon.mod"))
  assert_true(
    plan.reasons.any(reason => reason.has_prefix("uncertain-dependencies")),
  )
}

///|
test "duplicate module names in a workspace are not linked speculatively" {
  let sources = [
    ("moon.work", "members = [\"./lib\", \"./app\"]\n"),
    ("lib/moon.mod", "name = \"fixture/shared\"\nsource = \"src\"\n"),
    ("lib/src/value/moon.pkg", ""),
    ("lib/src/value/value.mbt", "pub fn value() -> Int { 1 }\n"),
    ("app/moon.mod", "name = \"fixture/shared\"\n"),
    ("app/moon.pkg", "test-import {\n  \"fixture/shared/value\" @value,\n}\n"),
    ("app/app_test.mbt", "test { assert_true(true) }\n"),
  ]
  let plan = impact_mbt_workspace_plan(sources, ["lib/src/value/value.mbt"])
  assert_eq(plan.strategy, "full")
  assert_true(!plan.issues.is_empty())
  assert_true(!plan.affected.contains("app"))
}

///|
test "same-named non-member modules do not create workspace evidence" {
  let sources = [
    ("moon.work", "members = [\".\", \"./app\"]\n"),
    ("moon.mod", "name = \"fixture/root\"\n"),
    ("moon.pkg", ""),
    ("lib/moon.mod", "name = \"fixture/lib\"\nsource = \"src\"\n"),
    ("lib/src/value/moon.pkg", ""),
    ("lib/src/value/value.mbt", "pub fn value() -> Int { 1 }\n"),
    ("app/moon.mod", "name = \"fixture/app\"\n"),
    ("app/moon.pkg", "test-import {\n  \"fixture/lib/value\" @value,\n}\n"),
    ("app/app_test.mbt", "test { assert_true(true) }\n"),
  ]
  let plan = impact_mbt_workspace_plan(sources, ["lib/src/value/value.mbt"])
  assert_eq(plan.strategy, "full")
  assert_true(!plan.affected.contains("app"))
}

///|
test "workspace members cannot escape the analyzed root" {
  let sources = [
    ("moon.work", "members = [\".\", \"../outside\"]\n"),
    ("moon.mod", "name = \"fixture/root\"\n"),
    ("moon.pkg", ""),
    ("app/moon.mod", "name = \"fixture/app\"\n"),
    ("app/moon.pkg", ""),
    ("app/app_test.mbt", "test { assert_true(true) }\n"),
  ]
  let plan = impact_mbt_workspace_plan(sources, ["app/app_test.mbt"])
  assert_eq(plan.strategy, "full")
  assert_true(!plan.issues.is_empty())
  assert_true(plan.issues.any(issue => issue.file == "moon.work"))
}

///|
test "workspace parser supports comments and rejects malformed membership" {
  assert_eq(
    impact_mbt_workspace_members(
      "// generated workspace members\n" +
      "members = [\"./lib\", \"./app\",]\n" +
      "preferred_target = \"native\"\n",
    ),
    Some(["lib", "app"]),
  )
  assert_eq(impact_mbt_workspace_members("// members = [\"./lib\"]\n"), None)
  assert_eq(
    impact_mbt_workspace_members("members = [\"./lib\"] unexpected\n"),
    None,
  )
  assert_eq(
    impact_mbt_workspace_members(
      "members = [\"./lib\"]\nmembers = [\"./app\"]\n",
    ),
    None,
  )
}

///|
test "text descriptor assignments reject trailing same-line tokens" {
  assert_eq(
    impact_mbt_text_string(
      "name = \"fixture/mod\"\nversion = \"1.0\"\n",
      "name",
      None,
    ),
    Some("fixture/mod"),
  )
  assert_eq(
    impact_mbt_text_string("name = \"fixture/mod\" extra\n", "name", None),
    None,
  )
}

///|
test "workspace inventory includes only declared modules" {
  let sources = [
    ("moon.work", "members = [\"./lib\", \"./app\"]\n"),
    ("lib/moon.mod", "name = \"fixture/lib\"\n"),
    ("lib/moon.pkg", ""),
    ("lib/lib_test.mbt", "test { assert_true(true) }\n"),
    ("app/moon.mod", "name = \"fixture/app\"\n"),
    ("app/moon.pkg", ""),
    ("app/app_test.mbt", "test { assert_true(true) }\n"),
    ("tools/moon.mod", "name = \"fixture/tools\"\n"),
    ("tools/moon.pkg", ""),
    ("tools/tools_test.mbt", "test { assert_true(true) }\n"),
  ]
  let plan = impact_mbt_workspace_plan(sources, ["lib/lib_test.mbt"])
  assert_eq(plan.strategy, "related")
  assert_eq(plan.inventory, ["app", "lib"])
  assert_eq(plan.tests, ["lib"])
  assert_true(!plan.affected.contains("tools"))
}

///|
test "workspace module boundary prevents parent package claiming excluded tests" {
  let sources = [
    ("moon.work", "members = [\".\"]\n"),
    ("moon.mod", "name = \"fixture/root\"\n"),
    ("moon.pkg", ""),
    ("root_test.mbt", "test { assert_true(true) }\n"),
    ("foreign/moon.mod", "name = \"fixture/foreign\"\n"),
    ("foreign/moon.pkg", ""),
    ("foreign/foreign_test.mbt", "test { assert_true(true) }\n"),
  ]
  let plan = impact_mbt_workspace_plan(sources, ["root_test.mbt"])
  assert_eq(plan.strategy, "related")
  assert_eq(plan.inventory, [""])
  assert_eq(plan.tests, [""])
}

///|
test "malformed workspace membership falls back without losing inventory" {
  let sources = [
    ("moon.work", "members = [\"../outside\"]\n"),
    ("app/moon.mod", "name = \"fixture/app\"\n"),
    ("app/moon.pkg", ""),
    ("app/app_test.mbt", "test { assert_true(true) }\n"),
  ]
  let plan = impact_mbt_workspace_plan(sources, ["app/app_test.mbt"])
  assert_eq(plan.strategy, "full")
  assert_eq(plan.inventory, ["app"])
  assert_eq(plan.tests, ["app"])
  assert_true(plan.issues.any(issue => issue.file == "moon.work"))
}
