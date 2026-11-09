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
  // A multi-line template body is text: the `//` inside it is not a comment.
  // The opener is a bare backtick, because a `${` would make what follows an
  // interpolation — code — rather than template body.
  let bt = char_from(96)
  let lines : Array[String] = [
    "const s = \{bt}",
    "a",
    "// still text",
    "b",
    "\{bt};",
    "",
  ]
  let source = lines.join("\u{A}")
  let stripped = strip_comments(source, Js)
  assert_eq(stripped, source)
}

///|
test "JS mode keeps comment openers inside a template body" {
  let bt = char_from(96)
  let lines : Array[String] = [
    "const s = \{bt}",
    "a",
    "/* not a comment */ // neither is this",
    "b",
    "\{bt};",
    "",
  ]
  let source = lines.join("\u{A}")
  assert_eq(strip_comments(source, Js), source)
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
  // The comment text itself is gone: it was code, not template body.
  assert_false(stripped.contains("HIDDEN"))
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
test "the code view blanks string contents but keeps the delimiters" {
  let blank = " ".repeat("FORBIDDEN".length())
  let source = "const q = \"FORBIDDEN\"; const r = 'FORBIDDEN';\n"
  let code = strip_comments_code(source, Js)
  // Literal values are not code; the quotes stay, so attribute-shaped
  // matches such as `ref="` keep working.
  assert_false(code.contains("FORBIDDEN"))
  assert_eq(code, "const q = \"\{blank}\"; const r = '\{blank}';\n")
  assert_eq(code.to_array().length(), source.to_array().length())
}

///|
test "the code view blanks template bodies but keeps interpolations" {
  let bt = char_from(96)
  let source = "const t = \{bt}text FORBIDDEN ${FORBIDDEN} more\{bt};\n"
  let code = strip_comments_code(source, Js)
  // An interpolation is code and survives; the surrounding body is blanked.
  assert_true(code.contains("${FORBIDDEN}"))
  assert_false(code.contains("text FORBIDDEN"))
  assert_false(code.contains("more"))
  assert_eq(code.to_array().length(), source.to_array().length())
}

///|
test "the code view blanks a comment inside an interpolation" {
  // `${...}` is an expression: a comment inside it is a code comment and is
  // blanked, and the code after the closed template is still code.
  let bt = char_from(96)
  let source = "const s = \{bt}${a // HIDDEN\n}\{bt};\nconst after = FORBIDDEN\n"
  let code = strip_comments_code(source, Js)
  assert_false(code.contains("HIDDEN"))
  assert_true(code.contains("const after = FORBIDDEN"))
  assert_eq(code.to_array().length(), source.to_array().length())
}

///|
test "the code view blanks regex bodies but keeps delimiters and flags" {
  let blank = " ".repeat("FORBIDDEN".length())
  let source = "const re = /FORBIDDEN/gi; const ok = 1;\n"
  let code = strip_comments_code(source, Js)
  assert_false(code.contains("FORBIDDEN"))
  assert_true(code.contains("/\{blank}/gi"))
  assert_eq(code.to_array().length(), source.to_array().length())
}

///|
test "division after an identifier is not mistaken for a regex" {
  // The previous significant character decides: an operand before the slash
  // means division, so the code after it stays visible.
  let source = "const half = total / 2; const y = a / b;\n"
  let code = strip_comments_code(source, Js)
  assert_eq(code, source)
}

///|
test "the code view preserves line numbers inside a multi-line template" {
  let bt = char_from(96)
  let lines : Array[String] = [
    "const s = \{bt}",
    "FORBIDDEN",
    "\{bt};",
    "const after = FORBIDDEN",
    "",
  ]
  let source = lines.join("\u{A}")
  let code_lines = split_lines(strip_comments_code(source, Js))
  assert_eq(code_lines.length(), split_lines(source).length())
  assert_false(code_lines[1].1.contains("FORBIDDEN"))
  assert_true(code_lines[3].1.contains("FORBIDDEN"))
}

///|
test "the code view leaves Plain and MoonBit sources unchanged" {
  // `.vue` and friends have no literal-aware scanner, and the MoonBit front
  // end already blanks literals in its own code view.
  let html = "<a target=\"_blank\">x</a>\n"
  assert_eq(strip_comments_code(html, Plain), html)
  let mbt = "///|\n/// Doc.\npub fn f() -> Int32 {\n  let s = \"FORBIDDEN\"\n  s\n}\n"
  assert_eq(strip_comments_code(mbt, Moonbit), strip_comments(mbt, Moonbit))
  assert_false(strip_comments_code(mbt, Moonbit).contains("FORBIDDEN"))
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
