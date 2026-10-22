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
  let stripped = strip_comments(source, Plain)
  assert_true(stripped.contains("https://host/path"))
  assert_true(stripped.contains("FORBIDDEN"))
  assert_false(stripped.contains("example"))
  assert_eq(stripped.to_array().length(), source.to_array().length())
}

///|
test "comment stripping preserves escaped strings" {
  let source = "const s = 'it\\'s // not a comment'; FORBIDDEN\n"
  assert_true(strip_comments(source, Plain).contains("FORBIDDEN"))
}

///|
test "HTML comments are blanked without shifting lines" {
  let source = "<template>\n<!-- FORBIDDEN\nexample -->\n<view />\n</template>\n"
  let stripped = strip_comments(source, Plain)
  assert_false(stripped.contains("FORBIDDEN"))
  assert_true(stripped.contains("<view />"))
  assert_eq(split_lines(stripped).length(), split_lines(source).length())
  assert_eq(stripped.to_array().length(), source.to_array().length())
}

///|
test "JS mode keeps // inside a multi-line template literal" {
  // MoonBit's `\n` is "line break + this line's indentation", which would
  // reopen the template on indented lines, so join with an explicit LF.
  let lines : Array[String] = [
    "const script = `", "console.log(\"inside\")", "// FORBIDDEN", "`;", "",
  ]
  let source = lines.join("\u{A}")
  let stripped = strip_comments(source, Js)
  assert_true(stripped.contains("console.log(\"inside\")"))
  // The template line is untouched: the `//` and its text survive.
  assert_true(stripped.contains("// FORBIDDEN"))
  assert_eq(stripped, source)
}

///|
test "JS mode still strips real comments after a template literal" {
  let source = "const s = `a${1 + 1}b`; FORBIDDEN // gone\n"
  let stripped = strip_comments(source, Js)
  assert_true(stripped.contains("`a${1 + 1}b`"))
  assert_true(stripped.contains("FORBIDDEN"))
  assert_false(stripped.contains("gone"))
}

///|
test "JS mode leaves template bodies alone across lines" {
  // A literal backtick followed by `$` would start an interpolation in the
  // MoonBit source of this test, so the opener is built at run time.
  let opened = template_source(["a", "// still text", "b", "`;", ""])
  let stripped = strip_comments(opened, Js)
  // Nothing inside a template body is a comment, so the source is unchanged.
  assert_eq(stripped, opened)
}

///|
test "JS mode keeps comment openers inside a template body" {
  let opened = template_source([
    "a", "/* not a comment */ // neither is this", "b", "`;", "",
  ])
  let stripped = strip_comments(opened, Js)
  assert_eq(stripped, opened)
}

///|
test "JS mode blanks a comment inside an interpolation" {
  let opened = template_source([
    "a // HIDDEN", "}`;", "const after = FORBIDDEN", "",
  ])
  let stripped = strip_comments(opened, Js)
  // The interpolation is code, so the comment is blanked in place: same
  // length, same line count, and the trailing code is untouched.
  assert_eq(stripped.to_array().length(), opened.to_array().length())
  assert_eq(split_lines(stripped).length(), split_lines(opened).length())
  assert_true(stripped.contains("const after = FORBIDDEN"))
}

///|
test "JS mode does not end interpolation on a brace inside a string" {
  let opened = template_source([
    " { a: \"}\" }.a } // HIDDEN", "console.log(1)", "",
  ])
  let stripped = strip_comments(opened, Js)
  // A `}` inside the string must not resume the template early: that would
  // make the escaped quote and the rest of the line template text, so the
  // next line would still be code and the blanked length would differ.
  assert_eq(stripped.to_array().length(), opened.to_array().length())
  assert_true(stripped.contains("console.log(1)"))
}

///|
test "JS mode preserves regex literals" {
  let source = "const re = /console.log/gi; // note\nconst ok = FORBIDDEN\n"
  let stripped = strip_comments(source, Js)
  assert_true(stripped.contains("console.log"))
  assert_false(stripped.contains("note"))
  assert_true(stripped.contains("FORBIDDEN"))
}

///|
test "JS mode keeps division and division-assignment" {
  let source = "const half = total / 2; const x = 1; const y = a / b;\n"
  let stripped = strip_comments(source, Js)
  assert_eq(stripped, source)
}

///|
test "JS mode treats a slash after an operator as a regex" {
  let source = "if (x) return /a\\/b/; const y = 1;\n"
  assert_eq(strip_comments(source, Js), source)
}

///|
test "JS mode does not let division swallow code" {
  let source = "const x = a / b;\nconsole.log(x)\n"
  let stripped = strip_comments(source, Js)
  assert_true(stripped.contains("console.log(x)"))
}

///|
test "JS mode blanks block comments across lines without shifting" {
  let source = "a;\n/* FORBIDDEN\n   FORBIDDEN */\nb;\n"
  let stripped = strip_comments(source, Js)
  assert_false(stripped.contains("FORBIDDEN"))
  assert_eq(split_lines(stripped).length(), split_lines(source).length())
  assert_eq(stripped.to_array().length(), source.to_array().length())
}

///|
test "comment mode is chosen from the extension" {
  assert_eq(comment_mode_for("src/app.ts"), Js)
  assert_eq(comment_mode_for("src/App.JSX"), Js)
  assert_eq(comment_mode_for("src/app.mts"), Js)
  assert_eq(comment_mode_for("src/Button.vue"), Plain)
  assert_eq(comment_mode_for("LICENSE"), Plain)
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

///|
/// A one-character string for `code`, so a test can build a template opener
/// without writing one: a backtick followed by `$` would start a MoonBit
/// interpolation in the test source itself.
fn char_from(code : Int32) -> String {
  String::from_array([code.unsafe_to_char()])
}

///|
/// A source whose first line opens a template literal and whose interpolation
/// body is `parts`. The `` `$ `` opener is assembled at run time because a
/// literal one would start an interpolation in the MoonBit source itself.
fn template_source(parts : Array[String]) -> String {
  let opener = char_from(96) + char_from(36) + char_from(123)
  "const s = " + opener + parts.join("\u{A}")
}
