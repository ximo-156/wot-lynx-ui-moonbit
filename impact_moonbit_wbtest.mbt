///|
/// MoonBit front end tests use strings only: a synthetic module with a root
/// package, two importers and a nested module, planned through the pure
/// entry point. No filesystem and no toolchain is involved.

///|
fn impact_mbt_fixture_sources() -> Array[(String, String)] {
  [
    ("moon.mod", "name = \"demo/mod\"\n\nversion = \"0.1.0\"\n"),
    ("moon.pkg", ""),
    ("lib.mbt", "pub fn lib() -> Int32 { 1 }\n"),
    ("lib_test.mbt", "test \"lib\" { assert_eq(lib(), 1) }\n"),
    ("cli/moon.pkg", "import {\n  \"demo/mod\" @lib,\n}\n"),
    ("cli/main.mbt", "fn main { println(@lib.lib()) }\n"),
    (
      "extra/moon.pkg", "import {\n  \"demo/mod\" @lib,\n}\ntest-import {\n  \"demo/mod\" @lib,\n}\n",
    ),
    ("extra/helper.mbt", "pub fn helper() -> Int32 { 2 }\n"),
    ("extra/helper_test.mbt", "test \"helper\" { assert_eq(helper(), 2) }\n"),
    ("nested/moon.mod", "name = \"demo/nested\"\n\nversion = \"0.1.0\"\n"),
    ("nested/pkg/moon.pkg", "import {\n  \"demo/nested/other\" @other,\n}\n"),
    ("nested/pkg/use.mbt", "pub fn use() -> Int32 { @other.value() }\n"),
    ("nested/other/moon.pkg", ""),
    ("nested/other/value.mbt", "pub fn value() -> Int32 { 3 }\n"),
  ]
}

///|
fn impact_mbt_fixture_paths() -> Array[String] {
  impact_mbt_fixture_sources().map(pair => pair.0)
}

///|
fn impact_mbt_fixture_plan(changes : Array[String]) -> ImpactPlan raise {
  impact_moonbit_plan_from(
    "/fixture",
    impact_mbt_fixture_paths(),
    impact_mbt_fixture_sources(),
    changes,
    "explicit",
    [],
  )
}

///|
test "moonbit manifest import blocks are parsed strictly" {
  let plain = "import {\n  \"demo/mod\" @lib,\n  \"moonbitlang/x/fs\",\n}\n"
  assert_eq(
    impact_mbt_manifest_imports(plain, "import"),
    Some(["demo/mod", "moonbitlang/x/fs"]),
  )
  let both = "import {\n  \"demo/mod\" @lib,\n}\ntest-import {\n  \"demo/mod\" @lib,\n}\n"
  assert_eq(
    impact_mbt_manifest_imports(both, "test-import"),
    Some(["demo/mod"]),
  )
  // A package with no import block has no dependencies, which is not an error.
  assert_eq(impact_mbt_manifest_imports("", "import"), Some([]))
  assert_eq(
    impact_mbt_manifest_imports("pkgtype(kind: \"executable\")", "import"),
    Some([]),
  )
  // The plain keyword must not match inside "test-import".
  assert_eq(
    impact_mbt_manifest_imports("test-import {\n  \"demo/mod\",\n}\n", "import"),
    Some([]),
  )
  // Malformed blocks are reported, never silently empty.
  assert_true(
    impact_mbt_manifest_imports("import {\n  \"demo/mod\",\n", "import") is None,
  )
  assert_true(
    impact_mbt_manifest_imports("import {\n  \"unclosed,\n}\n", "import")
    is None,
  )
}

///|
test "moonbit manifests may hold several import blocks" {
  // Real manifests combine plain, `for "test"` and #cfg-conditional blocks;
  // every block names a dependency.
  let crypto_like = "warnings = \"-alert_experimental\"\n\n" +
    "import {\n  \"moonbitlang/core/cmp\",\n}\n\n" +
    "import {\n  \"moonbitlang/core/test\",\n  \"demo/mod\" @lib,\n} for \"test\"\n"
  assert_eq(
    impact_mbt_manifest_imports(crypto_like, "import"),
    Some(["moonbitlang/core/cmp", "moonbitlang/core/test", "demo/mod"]),
  )
  let cfg_like = "#cfg(any(target=\"native\", target=\"wasm\"))\n" +
    "import {\n  \"moonbitlang/core/async/io\",\n}\n\n" +
    "import {\n  \"demo/mod\" @lib,\n}\n"
  assert_eq(
    impact_mbt_manifest_imports(cfg_like, "import"),
    Some(["moonbitlang/core/async/io", "demo/mod"]),
  )
  let duplicated = "import {\n  \"demo/mod\" @lib,\n}\nimport {\n  \"demo/mod\" @lib,\n}\n"
  assert_eq(
    impact_mbt_manifest_imports(duplicated, "import"),
    Some(["demo/mod"]),
  )
}

///|
test "moonbit modules are discovered longest directory first" {
  let modules = impact_mbt_modules(impact_mbt_fixture_sources())
  assert_eq(modules.length(), 2)
  assert_eq(modules[0].0, "nested")
  assert_eq(modules[0].1, "demo/nested")
  assert_eq(modules[1].0, "")
  assert_eq(modules[1].1, "demo/mod")
}

///|
test "moonbit specifiers resolve inside their own module only" {
  assert_eq(impact_mbt_resolve("demo/mod", "demo/mod", ""), Some(""))
  assert_eq(impact_mbt_resolve("demo/mod/cli", "demo/mod", ""), Some("cli"))
  assert_eq(
    impact_mbt_resolve("demo/nested/other", "demo/nested", "nested"),
    Some("nested/other"),
  )
  assert_eq(impact_mbt_resolve("moonbitlang/x/fs", "demo/mod", ""), None)
  assert_eq(impact_mbt_resolve("demo/other", "demo/mod", ""), None)
}

///|
test "moonbit file ownership is the longest package prefix" {
  let sources = impact_mbt_fixture_sources()
  let modules = impact_mbt_modules(sources)
  let (packages, issues) = impact_mbt_packages(
    Set::from_iter(impact_mbt_fixture_paths().iter()),
    modules,
    impact_mbt_fixture_sources(),
  )
  assert_eq(issues.length(), 0)
  assert_eq(impact_mbt_owner("lib.mbt", packages), Some(""))
  assert_eq(impact_mbt_owner("cli/main.mbt", packages), Some("cli"))
  assert_eq(impact_mbt_owner("extra/helper.mbt", packages), Some("extra"))
  assert_eq(
    impact_mbt_owner("nested/pkg/use.mbt", packages),
    Some("nested/pkg"),
  )
  assert_eq(impact_mbt_owner("README.md", packages), Some(""))
}

///|
test "moonbit package graph connects importers transitively" {
  let sources = impact_mbt_fixture_sources()
  let modules = impact_mbt_modules(sources)
  let (packages, issues) = impact_mbt_packages(
    Set::from_iter(impact_mbt_fixture_paths().iter()),
    modules,
    impact_mbt_fixture_sources(),
  )
  assert_eq(issues.length(), 0)
  let by_path = packages.map(package => (package.path, package.imports))
  assert_true(by_path.contains(("cli", [""])))
  assert_true(by_path.contains(("extra", [""])))
  assert_true(by_path.contains(("nested/pkg", ["nested/other"])))
  let has_tests = packages.map(package => (package.path, package.has_tests))
  assert_true(has_tests.contains(("", true)))
  assert_true(has_tests.contains(("cli", false)))
  assert_true(has_tests.contains(("extra", true)))
}

///|
test "moonbit plan selects owning packages and every importer" {
  let plan = impact_mbt_fixture_plan(["lib.mbt"])
  assert_eq(plan.mode, "moonbit")
  assert_eq(plan.strategy, "related")
  // The root package and its test-holding importer run; the CLI importer has
  // no tests and is affected but not selected.
  assert_eq(plan.tests, ["", "extra"])
  assert_eq(plan.affected, ["", "cli", "extra"])
  assert_eq(plan.inventory, ["", "extra"])
  let mut trace : ImpactTrace? = None
  for candidate in plan.traces {
    if candidate.test_file == "extra" {
      trace = Some(candidate)
    }
  }
  let trace = trace.unwrap()
  assert_eq(trace.changed, "lib.mbt")
  assert_eq(trace.chain.length(), 2)
  assert_eq(trace.chain[0].dependency, "lib.mbt")
  assert_eq(trace.chain[0].dependent, "")
  assert_eq(trace.chain[0].kind, "owns")
  assert_eq(trace.chain[1].dependency, "")
  assert_eq(trace.chain[1].dependent, "extra")
  assert_eq(trace.chain[1].kind, "imports")
}

///|
test "moonbit plan runs nothing when the affected package has no tests" {
  let plan = impact_mbt_fixture_plan(["cli/main.mbt"])
  assert_eq(plan.strategy, "none")
  assert_eq(plan.tests, [])
  assert_eq(plan.affected, ["cli"])
  assert_true(
    plan.reasons.any(reason => reason.has_prefix("no-known-related-packages")),
  )
}

///|
test "moonbit nested module edges stay inside their own module" {
  let plan = impact_mbt_fixture_plan(["nested/other/value.mbt"])
  assert_eq(plan.strategy, "none")
  assert_eq(plan.affected, ["nested/other", "nested/pkg"])
}

///|
test "moonbit manifest and descriptor changes request every package" {
  for path in ["moon.mod", "moon.pkg", "cli/moon.pkg", "nested/moon.mod"] {
    let plan = impact_mbt_fixture_plan([path])
    assert_eq(plan.strategy, "full")
    assert_eq(plan.tests, plan.inventory)
    assert_true(
      plan.reasons.any(reason => reason.has_prefix("global-input-changed")),
    )
  }
}

///|
test "moonbit missing files and empty changes are honest" {
  let missing = impact_mbt_fixture_plan(["lib.mbt", "gone.mbt"])
  assert_eq(missing.strategy, "full")
  assert_true(
    missing.reasons.any(reason => reason.has_prefix("removed-or-missing-input")),
  )
  let empty = impact_moonbit_plan_from(
    "/fixture",
    impact_mbt_fixture_paths(),
    impact_mbt_fixture_sources(),
    [],
    "explicit",
    [],
  )
  assert_eq(empty.strategy, "none")
  assert_eq(empty.tests, [])
}

///|
test "moonbit malformed manifests request every package instead of guessing" {
  let sources = impact_mbt_fixture_sources()
  sources[4] = ("cli/moon.pkg", "import {\n  \"demo/mod\",\n")
  let plan = impact_moonbit_plan_from(
    "/fixture",
    impact_mbt_fixture_paths(),
    sources,
    ["lib.mbt"],
    "explicit",
    [],
  )
  assert_eq(plan.strategy, "full")
  assert_true(plan.issues.length() > 0)
  assert_true(
    plan.issues.any(issue => {
      issue.reason.has_prefix("moonbit: package manifest")
    }),
  )
}
