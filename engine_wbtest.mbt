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
  let result = lint_tree(dir, rules, [], [".ts"], Scope::empty())
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
  let result = lint_tree(
    "nonexistent_dir_xyz",
    rules,
    [],
    [".ts"],
    Scope::empty(),
  )
  assert_true(result is Err(_))
}

///|
test "lint_selected counts files removed by the global scope" {
  let rules = [test_rule("no-foo", Contains("foo"), None)]
  let scope = Scope::new(["src/**"], []).unwrap()
  let result = lint_files(".", ["src/a.ts", "lib/b.ts"], rules, [], scope)
  assert_eq(result.files_selected, 1)
  assert_eq(result.files_out_of_scope, 1)
}

///|
test "lint_selected records why a file was skipped" {
  let rules = [test_rule("no-foo", Contains("foo"), None)]
  let result = lint_files(".", ["README.md"], rules, [], Scope::empty())
  assert_eq(result.files_selected, 1)
  assert_eq(result.files_scanned, 0)
  assert_eq(result.files_skipped, 1)
  assert_eq(result.skipped_files.length(), 1)
  assert_eq(result.skipped_files[0].reason, "no-applicable-rule")
}

///|
fn test_file_rule(id : String, check : FileCheck) -> FileRule {
  FileRule::{
    id,
    severity: Severity::warning(),
    message: "test file rule",
    extensions: [".ts"],
    check,
    scope: Scope::empty(),
  }
}

///|
test "lint_file detects max_lines violation" {
  let lines = [(1, "a"), (2, "b"), (3, "c")]
  let frs = [test_file_rule("file/max-lines", MaxLines(2))]
  let findings = lint_file("test.ts", "a\nb\nc\n", lines, frs)
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].rule_id, "file/max-lines")
  assert_eq(findings[0].line, 3)
}

///|
test "lint_file detects max_line_length violation" {
  let lines = [
    (1, "short"),
    (2, "this is a very long line that exceeds the limit"),
  ]
  let frs = [test_file_rule("file/max-line-length", MaxLineLength(10))]
  let findings = lint_file("test.ts", "short\nlong\n", lines, frs)
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].line, 2)
}

///|
test "lint_file detects trailing whitespace" {
  let lines = [(1, "clean"), (2, "trailing   ")]
  let frs = [
    test_file_rule("file/no-trailing-whitespace", NoTrailingWhitespace),
  ]
  let findings = lint_file("test.ts", "clean\ntrailing   \n", lines, frs)
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].line, 2)
}

///|
test "lint_file detects tabs" {
  let lines = [(1, "clean"), (2, "\thas tab")]
  let frs = [test_file_rule("file/no-tabs", NoTabs)]
  let findings = lint_file("test.ts", "clean\n\thas tab\n", lines, frs)
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].line, 2)
}

///|
test "lint_file detects missing final newline" {
  let lines = [(1, "no newline at end")]
  let frs = [test_file_rule("file/final-newline", FinalNewline)]
  let findings = lint_file("test.ts", "no newline at end", lines, frs)
  assert_eq(findings.length(), 1)
}

///|
test "lint_file accepts final newline" {
  let lines = [(1, "has newline")]
  let frs = [test_file_rule("file/final-newline", FinalNewline)]
  let findings = lint_file("test.ts", "has newline\n", lines, frs)
  assert_eq(findings.length(), 0)
}

///|
test "lint_file detects duplicate lines" {
  let lines = [(1, "same"), (2, "different"), (3, "same")]
  let frs = [test_file_rule("file/no-duplicate-lines", NoDuplicateLines)]
  let findings = lint_file("test.ts", "same\ndifferent\nsame\n", lines, frs)
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].line, 3)
}

///|
test "lint_file ignores empty lines for duplicates" {
  let lines = [(1, "code"), (2, ""), (3, ""), (4, "code")]
  let frs = [test_file_rule("file/no-duplicate-lines", NoDuplicateLines)]
  let findings = lint_file("test.ts", "code\n\n\ncode\n", lines, frs)
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].line, 4)
}

///|
test "lint_file detects naming violation" {
  let frs = [test_file_rule("file/naming", FileNaming(KebabCase))]
  let findings = lint_file("myComponent.ts", "code\n", [(1, "code")], frs)
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].rule_id, "file/naming")
}

///|
test "lint_file accepts correct naming" {
  let frs = [test_file_rule("file/naming", FileNaming(KebabCase))]
  let findings = lint_file("my-component.ts", "code\n", [(1, "code")], frs)
  assert_eq(findings.length(), 0)
}

///|
test "lint_file respects extensions" {
  let frs = [test_file_rule("file/max-lines", MaxLines(1))]
  let lines = [(1, "a"), (2, "b")]
  // .ts matches
  let ts_findings = lint_file("test.ts", "a\nb\n", lines, frs)
  assert_eq(ts_findings.length(), 1)
  // .js does not match
  let js_findings = lint_file("test.js", "a\nb\n", lines, frs)
  assert_eq(js_findings.length(), 0)
}

///|
test "lint_file with no file rules yields no findings" {
  let lines = [(1, "a"), (2, "b")]
  let findings = lint_file("test.ts", "a\nb\n", lines, [])
  assert_eq(findings.length(), 0)
}
