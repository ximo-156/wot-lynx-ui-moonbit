///|
/// Tests for the lint engine.

///|
fn test_rule(id : String, match_ : MatchKind, unless : MatchKind?) -> Rule {
  Rule::{
    id,
    severity: Severity::error(),
    message: "test rule",
    extensions: [".ts"],
    match_,
    unless,
    scope: Scope::empty(),
  }
}

///|
test "lint_lines finds violations" {
  let rules = [test_rule("no-foo", Contains("foo"), None)]
  let lines = [(1, "let x = 1"), (2, "let y = foo"), (3, "let z = 3")]
  let findings = lint_lines("test.ts", lines, rules)
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].line, 2)
  assert_eq(findings[0].rule_id, "no-foo")
}

///|
test "lint_lines respects unless guard" {
  let rules = [
    test_rule(
      "no-vue",
      Regex("from[[:space:]]+['\"]vue['\"]"),
      Some(Regex("from[[:space:]]+['\"]vue-lynx['\"]")),
    ),
  ]
  let lines = [
    (1, "import { x } from 'vue'"),
    (2, "import { y } from 'vue-lynx'"),
  ]
  let findings = lint_lines("test.ts", lines, rules)
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].line, 1)
}

///|
test "lint_lines respects extensions" {
  let rules = [test_rule("no-foo", Contains("foo"), None)]
  let lines = [(1, "foo")]
  // Rule applies to .ts, file is .ts
  let findings_ts = lint_lines("test.ts", lines, rules)
  assert_eq(findings_ts.length(), 1)
  // Rule applies to .ts, file is .vue — should not match
  let findings_vue = lint_lines("test.vue", lines, rules)
  assert_eq(findings_vue.length(), 0)
}

///|
test "lint_lines respects a rule-level scope" {
  let scope = Scope::new(["src/**"], ["src/legacy/**"]).unwrap()
  let rule = Rule::{
    id: "no-foo",
    severity: Severity::error(),
    message: "test",
    extensions: [".ts"],
    match_: Contains("foo"),
    unless: None,
    scope,
  }
  let lines = [(1, "foo")]
  assert_eq(lint_lines("src/app.ts", lines, [rule]).length(), 1)
  assert_eq(lint_lines("lib/app.ts", lines, [rule]).length(), 0)
  assert_eq(lint_lines("src/legacy/app.ts", lines, [rule]).length(), 0)
}

///|
test "lint_lines with empty extensions matches all" {
  let rule : Rule = Rule::{
    id: "no-foo",
    severity: Severity::error(),
    message: "test",
    extensions: [],
    match_: Contains("foo"),
    unless: None,
    scope: Scope::empty(),
  }
  let lines = [(1, "foo")]
  let findings = lint_lines("test.js", lines, [rule])
  assert_eq(findings.length(), 1)
}

///|
test "lint_tree on real directory" {
  // Create a temp directory with a test file
  let dir = "tmp_lint_test"
  // Clean up from any previous run, then create fresh
  @fs.remove_file("\{dir}/test.ts") catch {
    _ => ()
  }
  @fs.remove_dir(dir) catch {
    _ => ()
  }
  @fs.create_dir(dir) catch {
    _ => ()
  }
  let content = "let x = 1\nlet y = foo\n"
  @fs.write_string_to_file("\{dir}/test.ts", content) catch {
    _ => ()
  }
  let rules = [test_rule("no-foo", Contains("foo"), None)]
  let result = lint_tree(dir, rules, [".ts"], Scope::empty())
  assert_true(result is Ok(_))
  let r = result.unwrap()
  assert_eq(r.findings.length(), 1)
  assert_eq(r.findings[0].file, "test.ts")
  // Cleanup
  @fs.remove_file("\{dir}/test.ts") catch {
    _ => ()
  }
  @fs.remove_dir(dir) catch {
    _ => ()
  }
}

///|
test "lint_tree on nonexistent directory returns error" {
  let rules = [test_rule("no-foo", Contains("foo"), None)]
  let result = lint_tree("nonexistent_dir_xyz", rules, [".ts"], Scope::empty())
  assert_true(result is Err(_))
}

///|
test "lint_selected counts files removed by the global scope" {
  let rules = [test_rule("no-foo", Contains("foo"), None)]
  let scope = Scope::new(["src/**"], []).unwrap()
  let result = lint_files(".", ["src/a.ts", "lib/b.ts"], rules, scope)
  assert_eq(result.files_selected, 1)
  assert_eq(result.files_out_of_scope, 1)
}

///|
test "lint_selected records why a file was skipped" {
  let rules = [test_rule("no-foo", Contains("foo"), None)]
  let result = lint_files(".", ["README.md"], rules, Scope::empty())
  assert_eq(result.files_selected, 1)
  assert_eq(result.files_scanned, 0)
  assert_eq(result.files_skipped, 1)
  assert_eq(result.skipped_files.length(), 1)
  assert_eq(result.skipped_files[0].reason, "no-applicable-rule")
}
