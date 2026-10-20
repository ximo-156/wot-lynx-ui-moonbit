///|
/// Regressions for source views and file selection.

///|
test "empty extension filter includes extensionless files" {
  assert_true(has_wanted_ext("LICENSE", Set::from_iter([].iter())))
  assert_true(has_wanted_ext("file.ts", Set::from_iter([].iter())))
}

///|
test "comment stripping preserves quoted URLs and following code" {
  let source = "const url = \"https://host/path\"; FORBIDDEN // example\n"
  let stripped = strip_comments(source)
  assert_true(stripped.contains("https://host/path"))
  assert_true(stripped.contains("FORBIDDEN"))
  assert_false(stripped.contains("example"))
  assert_eq(stripped.to_array().length(), source.to_array().length())
}

///|
test "comment stripping preserves escaped strings" {
  let source = "const s = 'it\\'s // not a comment'; FORBIDDEN\n"
  assert_true(strip_comments(source).contains("FORBIDDEN"))
}

///|
test "HTML comments are blanked without shifting lines" {
  let source = "<template>\n<!-- FORBIDDEN\nexample -->\n<view />\n</template>\n"
  let stripped = strip_comments(source)
  assert_false(stripped.contains("FORBIDDEN"))
  assert_true(stripped.contains("<view />"))
  assert_eq(split_lines(stripped).length(), split_lines(source).length())
  assert_eq(stripped.to_array().length(), source.to_array().length())
}

///|
test "glob double star slash cannot eat part of a segment" {
  let pattern = GlobPattern::new("src/**/test.ts")
  assert_true(pattern.matches("src/test.ts"))
  assert_true(pattern.matches("src/a/b/test.ts"))
  assert_false(pattern.matches("src/contest.ts"))
  assert_false(pattern.matches("src/atest.ts"))
}

///|
test "glob Unicode question mark consumes one character" {
  let pattern = GlobPattern::new("src/?.ts")
  assert_true(pattern.matches("src/中.ts"))
  assert_true(pattern.matches("src/😀.ts"))
  assert_false(pattern.matches("src/中文.ts"))
}
