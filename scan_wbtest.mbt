///|
/// Tests for scan mode file selection and glob matching.

///|
test "glob: literal match" {
  let pattern = GlobPattern::new("test.mbt")
  assert_true(pattern.matches("test.mbt"))
  assert_false(pattern.matches("other.mbt"))
}

///|
test "glob: star matches within segment" {
  let pattern = GlobPattern::new("*.mbt")
  assert_true(pattern.matches("test.mbt"))
  assert_true(pattern.matches("a.mbt"))
  assert_false(pattern.matches("dir/test.mbt"))
}

///|
test "glob: double star matches across segments" {
  let pattern = GlobPattern::new("**/*.mbt")
  assert_true(pattern.matches("test.mbt"))
  assert_true(pattern.matches("dir/test.mbt"))
  assert_true(pattern.matches("a/b/c/test.mbt"))
}

///|
test "glob: question mark matches single char" {
  let pattern = GlobPattern::new("test?.mbt")
  assert_true(pattern.matches("test1.mbt"))
  assert_true(pattern.matches("testA.mbt"))
  assert_false(pattern.matches("test.mbt"))
  assert_false(pattern.matches("test12.mbt"))
}

///|
test "glob: prefix literal" {
  let pattern = GlobPattern::new("src/*.ts")
  assert_true(pattern.matches("src/main.ts"))
  assert_false(pattern.matches("lib/main.ts"))
}

///|
test "glob: suffix literal" {
  let pattern = GlobPattern::new("*.test.ts")
  assert_true(pattern.matches("main.test.ts"))
  assert_false(pattern.matches("main.ts"))
}

///|
test "scan mode: tree is default" {
  let mode = ScanMode::tree()
  assert_true(mode is ScanMode::Tree(_))
}

///|
test "scan mode: changed constructor" {
  let mode = ScanMode::changed("HEAD")
  assert_true(mode is ScanMode::Changed("HEAD"))
}

///|
test "scan mode: staged constructor" {
  let mode = ScanMode::staged()
  assert_true(mode is ScanMode::Staged(_))
}

///|
test "scan mode: glob constructor" {
  let mode = ScanMode::glob("*.mbt")
  assert_true(mode is ScanMode::Glob("*.mbt"))
}

///|
test "scan mode: stdin constructor" {
  let mode = ScanMode::stdin()
  assert_true(mode is ScanMode::Stdin(_))
}

///|
test "scan mode: incremental constructor" {
  let mode = ScanMode::incremental()
  assert_true(mode is ScanMode::Incremental(_))
}

///|
test "lint_files: scans specific file list" {
  let rules = [
    Rule::{
      id: "test/rule",
      severity: Severity::error(),
      message: "test message",
      extensions: [".mbt"],
      match_: MatchKind::Contains("bad"),
      unless: None,
    },
  ]
  let result = lint_files(".", ["test.mbt"], rules)
  assert_eq(result.files_scanned, 1)
}

///|
test "lint_files: empty file list yields empty result" {
  let rules : Array[Rule] = []
  let result = lint_files(".", [], rules)
  assert_eq(result.files_scanned, 0)
  assert_eq(result.findings.length(), 0)
}
