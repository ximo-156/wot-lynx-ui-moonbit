///|
fn impact_mbt_diamond_sources() -> Array[(String, String)] {
  [
    ("moon.mod", "name = \"fixture/diamond\""),
    ("base/moon.pkg", ""),
    ("base/value.mbt", "test {}"),
    ("left/moon.pkg", "import { \"fixture/diamond/base\", }"),
    ("left/value.mbt", "test {}"),
    ("right/moon.pkg", "import { \"fixture/diamond/base\", } for \"test\""),
    ("right/value.mbt", "test {}"),
    (
      "tip/moon.pkg", "import { \"fixture/diamond/left\", \"fixture/diamond/right\", } for \"wbtest\"",
    ),
    ("tip/value.mbt", "test {}"),
    ("island/moon.pkg", ""),
    ("island/value.mbt", "test {}"),
  ]
}

///|
fn impact_mbt_diamond_plan(changes : Array[String]) -> ImpactPlan raise {
  let sources = impact_mbt_diamond_sources()
  impact_moonbit_plan_from(
    "/fixture",
    sources.map(pair => pair.0),
    sources,
    impact_unique_paths(changes),
    "explicit",
    [],
  )
}

///|
test "diamond imports select both branches but not disconnected tests" {
  let plan = impact_mbt_diamond_plan(["base/value.mbt"])
  assert_eq(plan.strategy, "related")
  assert_eq(plan.tests, ["base", "left", "right", "tip"])
  let trace = plan.traces.filter(trace => trace.test_file == "tip")[0]
  assert_eq(trace.chain.length(), 3)
  assert_eq(trace.chain[1].dependency, "base")
  assert_eq(trace.chain[1].dependent, "left")
  assert_eq(trace.chain[2].dependent, "tip")
  assert_eq(
    render_impact_json(plan),
    render_impact_json(impact_mbt_diamond_plan(["base/value.mbt"])),
  )
}

///|
test "multiple changes union affected islands and remove duplicate input" {
  let plan = impact_mbt_diamond_plan([
    "left/value.mbt", "island/value.mbt", "left/value.mbt",
  ])
  assert_eq(plan.tests, ["island", "left", "tip"])
  assert_eq(plan.changed, ["island/value.mbt", "left/value.mbt"])
  let leaf = impact_mbt_diamond_plan(["tip/value.mbt"])
  assert_eq(leaf.tests, ["tip"])
}

///|
test "cyclic manifest graphs terminate without cyclic evidence chains" {
  // The compiler rejects cyclic imports; the planner must still terminate
  // deterministically when asked to inspect an incomplete working tree.
  let sources = [
    ("moon.mod", "name = \"fixture/cycle\""),
    ("a/moon.pkg", "import { \"fixture/cycle/b\", }"),
    ("a/value.mbt", "test {}"),
    ("b/moon.pkg", "import { \"fixture/cycle/a\", }"),
    ("b/value.mbt", "test {}"),
  ]
  let plan = impact_moonbit_plan_from(
    "/fixture",
    sources.map(p => p.0),
    sources,
    ["a/value.mbt"],
    "explicit",
    [],
  )
  assert_eq(plan.tests, ["a", "b"])
  assert_true(plan.traces.all(trace => trace.chain.length() <= 2))
}
