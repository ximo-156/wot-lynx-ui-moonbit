///|
/// Pure style-adapter regressions. No filesystem, compiler subprocess, or
/// business source is needed to reproduce these cases.
fn impact_style_test(
  source : String,
  syntax : String,
) -> (Array[ImpactReference], Array[ImpactIssue]) {
  impact_extract_style_references(
    "src/style/example.scss", source, syntax, 1, 1,
  )
}

///|
fn impact_style_specs(references : Array[ImpactReference]) -> Array[String] {
  references.map(reference => reference.specifier)
}

///|
test "styles real module and icon stylesheet forms" {
  let source =
    #|@use '@wot-ui/ui/styles/theme/index.scss' as *;
    #|@import '@/style/iconfont.css';
  let (references, issues) = impact_style_test(source, "scss")
  assert_eq(issues.length(), 0)
  assert_eq(impact_style_specs(references), [
    "@wot-ui/ui/styles/theme/index.scss", "@/style/iconfont.css",
  ])
  assert_eq(references[0].kind, "style-import-scss")
  assert_eq(references[1].kind, "style-import-css")
  assert_eq(references[0].line, 1)
  assert_eq(references[0].column, 6)
  assert_eq(references[1].line, 2)
  assert_eq(references[1].column, 9)
}

///|
test "styles font URLs retain aliases relative spelling query and fragment" {
  let source =
    #|@font-face {
    #|  src: url('@/style/iconfont.ttf'), url('./wd-icons.ttf');
    #|}
    #|.icon { src: url('iconfont.ttf?t=1794280199105#glyph'); }
  let (references, issues) = impact_style_test(source, "css")
  assert_eq(issues.length(), 0)
  assert_eq(impact_style_specs(references), [
    "@/style/iconfont.ttf", "./wd-icons.ttf", "iconfont.ttf?t=1794280199105#glyph",
  ])
  assert_true(references.all(reference => reference.kind == "style-url"))
}

///|
test "styles multiple SCSS imports and partial names remain literal" {
  let (references, issues) = impact_style_test(
    "@import 'a', \"b\", '_partial', 'partials/index';\n@forward 'tokens/_colors' as colors-*;",
    "scss",
  )
  assert_eq(issues.length(), 0)
  assert_eq(impact_style_specs(references), [
    "a", "b", "_partial", "partials/index", "tokens/_colors",
  ])
  assert_true(
    references.all(reference => reference.kind == "style-import-scss"),
  )
  assert_true(references[0].column < references[1].column)
}

///|
test "styles CSS URL imports preserve media tail and continue to later URLs" {
  let source =
    #|@IMPORT URL('theme.css') screen and (min-width: 900px), print;
    #|.a { background: UrL("icon.svg#shape"); }
  let (references, issues) = impact_style_test(source, "CSS")
  assert_eq(issues.length(), 0)
  assert_eq(impact_style_specs(references), ["theme.css", "icon.svg#shape"])
  assert_eq(references[0].kind, "style-import-css")
  assert_eq(references[0].line, 1)
  assert_eq(references[0].column, 9)
  assert_eq(references[1].kind, "style-url")
}

///|
test "styles SCSS import media query uses CSS import resolution" {
  let (references, issues) = impact_style_test(
    "@import 'theme' screen and (min-width: 30px);", "scss",
  )
  assert_eq(issues.length(), 0)
  assert_eq(references.length(), 1)
  assert_eq(references[0].specifier, "theme")
  assert_eq(references[0].kind, "style-import-css")
}

///|
test "styles SCSS mixed url and quoted imports keep distinct kinds" {
  let (references, issues) = impact_style_test(
    "@import url('base.css'), 'tokens';", "scss",
  )
  assert_eq(issues.length(), 0)
  assert_eq(impact_style_specs(references), ["base.css", "tokens"])
  assert_eq(references[0].kind, "style-import-css")
  assert_eq(references[1].kind, "style-import-scss")
}

///|
test "styles schemes and fragment-only URLs are retained for planner classification" {
  let source =
    #|@use 'sass:math';
    #|@import url('HTTPS://host/theme.css');
    #|.a { background: url(//cdn/a.png), url(data:image/png;base64,AAA=), url(#id), url(custom:asset), url(local.png?x=1#glyph); }
  let (references, issues) = impact_style_test(source, "scss")
  assert_eq(issues.length(), 0)
  assert_eq(impact_style_specs(references), [
    "sass:math", "HTTPS://host/theme.css", "//cdn/a.png", "data:image/png;base64,AAA=",
    "#id", "custom:asset", "local.png?x=1#glyph",
  ])
}

///|
test "styles remote URLs do not become SCSS comments or swallow local successors" {
  let source = ".x { background: url(https://example.test/a.png), url('./local.png'), url(//cdn.test/b.png), url(last.png); }"
  let (references, issues) = impact_style_test(source, "scss")
  assert_eq(issues.length(), 0)
  assert_eq(impact_style_specs(references), [
    "https://example.test/a.png", "./local.png", "//cdn.test/b.png", "last.png",
  ])
}

///|
test "styles block comments SCSS line comments and ordinary strings never add references" {
  let source =
    #|/* A note: @use theme; @import 'fake'; url(no.png); */
    #|// @use 'no'; url(nope.ttf)
    #|.a { content: 'url(fake.png) @import "text"'; background: url(real.png); }
  let (references, issues) = impact_style_test(source, "scss")
  assert_eq(issues.length(), 0)
  assert_eq(impact_style_specs(references), ["real.png"])
}

///|
test "styles ordinary escaped content remains opaque" {
  let source =
    #|.a { content: "say \"url(fake.png)\""; background: url(real.png); }
  let (references, issues) = impact_style_test(source, "css")
  assert_eq(issues.length(), 0)
  assert_eq(impact_style_specs(references), ["real.png"])
}

///|
test "styles comment trivia around quoted url arguments does not change the path" {
  let source = "/* header */ @import /* a */ 'x.css' /* b */ screen; .a { src: URL( /* c */ 'font.ttf' /* d */ ); }"
  let (references, issues) = impact_style_test(source, "css")
  assert_eq(issues.length(), 0)
  assert_eq(impact_style_specs(references), ["x.css", "font.ttf"])
}

///|
test "styles URL identifiers have token boundaries" {
  let source = ".a { x: myurl('a'); y: curl('b'); content: 'url(fake)'; src: url(real.ttf); }"
  let (references, issues) = impact_style_test(source, "css")
  assert_eq(issues.length(), 0)
  assert_eq(impact_style_specs(references), ["real.ttf"])
}

///|
test "styles CSS use and forward are explicitly unsupported" {
  let (references, issues) = impact_style_test(
    "@use 'theme'; @forward 'more';", "css",
  )
  assert_eq(references.length(), 0)
  assert_true(issues.length() >= 2)
  assert_true(
    issues.all(issue => issue.reason.contains("not supported in CSS")),
  )
}

///|
test "styles CSS comma path lists are not silently treated as valid CSS" {
  let (references, issues) = impact_style_test(
    "@import 'a.css', 'b.css';", "css",
  )
  assert_eq(impact_style_specs(references), ["a.css", "b.css"])
  assert_true(issues.any(issue => issue.reason.contains("comma-separated")))
}

///|
test "styles dynamic dependency expressions never emit a guessed literal prefix" {
  for
    source in [
      "@import $path;", "@use \"#{$theme}\";", "@forward \"@{theme}\";", "@import \"${theme}\";",
      "@import 'base' + '-dark';", "@use 'a' 'b';", "@import var(--theme);", "@import '\\66oo';",
      ".x { background: url(var(--asset)); }", ".x { background: url(calc(1 + 2)); }",
      ".x { background: url('a' + '.png'); }", ".x { background: url(a b.png); }",
      ".x { background: url(foo\\20bar.png); }", ".x { background: url(#{image()}); }",
      ".x { background: u\\72l(foo.png); }",
    ] {
    let (references, issues) = impact_style_test(source, "scss")
    assert_true(issues.length() > 0)
    assert_eq(references.length(), 0)
  }
}

///|
test "styles recovery preserves known imports around one dynamic item" {
  let (references, issues) = impact_style_test(
    "@import 'a', $theme, 'c'; .x { src: url(after.ttf); }", "scss",
  )
  assert_true(issues.length() > 0)
  assert_eq(impact_style_specs(references), ["a", "c", "after.ttf"])
}

///|
test "styles recovery after nested url computation reaches the following static url" {
  let (references, issues) = impact_style_test(
    ".x { background: url(var(--x)), url(after.png); }", "css",
  )
  assert_true(issues.length() > 0)
  assert_eq(impact_style_specs(references), ["after.png"])
}

///|
test "styles malformed or unfinished input is always inconclusive" {
  for
    source in [
      "/* @use 'bad';", "'unclosed", "@import \"oops", "url(", "url(x", "url('x'",
      "url('x", "url()", "url('')", "@use", "@import;", "@import 'a',", "@import 'a.css' screen and (",
      ".x { background: url('x.png');", ".x { content: 'oops\n}", "@import 'x.css' /* unclosed",
      "#{missing", ".x { src: url(\u{0}); }",
    ] {
    let (_, issues) = impact_style_test(source, "scss")
    assert_true(issues.length() > 0)
  }
}

///|
test "styles conditional dependencies keep their static target but request fallback" {
  for
    source in [
      "@if $enabled { @import 'theme'; }", "@media (min-width: $width) { .x { background: url(a.png); } }",
      "@import 'theme.css' screen and (min-width: var(--width));",
    ] {
    let (references, issues) = impact_style_test(source, "scss")
    assert_eq(references.length(), 1)
    assert_true(issues.length() > 0)
  }
}

///|
test "styles constant media blocks do not require dynamic fallback" {
  let (references, issues) = impact_style_test(
    "@media screen and (min-width: 800px) { .x { background: url(a.png); } }", "css",
  )
  assert_eq(issues.length(), 0)
  assert_eq(impact_style_specs(references), ["a.png"])
}

///|
test "styles interpolation text cannot create a fake static dependency" {
  let source =
    #|#{'@import "fake.css"; url(fake.png)'}
    #|.x { src: url(real.ttf); }
  let (references, issues) = impact_style_test(source, "scss")
  assert_true(issues.length() > 0)
  assert_eq(impact_style_specs(references), ["real.ttf"])
}

///|
test "styles Unicode columns and CRLF lines are character based" {
  let source = "中文: url('图.png');\r\n@import '二.css';"
  let (references, issues) = impact_style_test(source, "css")
  assert_eq(issues.length(), 0)
  assert_eq(references[0].line, 1)
  assert_eq(references[0].column, 5)
  assert_eq(references[1].line, 2)
  assert_eq(references[1].column, 9)
  assert_eq(impact_style_specs(references), ["图.png", "二.css"])
}

///|
test "styles inline origin offsets only the first physical line column" {
  let (references, issues) = impact_extract_style_references(
    "src/Page.vue", "url('a');\r\n  url('b')", "css", 40, 7,
  )
  assert_eq(issues.length(), 0)
  assert_eq(references[0].file, "src/Page.vue")
  assert_eq(references[0].line, 40)
  assert_eq(references[0].column, 7)
  assert_eq(references[1].line, 41)
  assert_eq(references[1].column, 3)
  let (unicode, _) = impact_extract_style_references(
    "src/页面.vue", "中 url('c')", "css", 10, 4,
  )
  assert_eq(unicode[0].column, 6)
}

///|
test "styles CR LF and CRLF each advance exactly one line" {
  let (references, issues) = impact_extract_style_references(
    "x.css", "url(a)\rurl(b)\nurl(c)\r\nurl(d)", "css", 5, 1,
  )
  assert_eq(issues.length(), 0)
  assert_eq(references.map(reference => reference.line), [5, 6, 7, 8])
}

///|
test "styles filenames with spaces are not trimmed or decoded" {
  let (references, issues) = impact_style_test(
    ".a { src: url(' font name.ttf '); }", "css",
  )
  assert_eq(issues.length(), 0)
  assert_eq(references[0].specifier, " font name.ttf ")
}

///|
test "styles URL inputs in module configuration tails are still extracted" {
  let (references, issues) = impact_style_test(
    "@use 'theme' with ($font: url('font.ttf'));", "scss",
  )
  assert_eq(impact_style_specs(references), ["theme", "font.ttf"])
  assert_eq(references[1].kind, "style-url")
  // The fixed targets survive, but arbitrary Sass configuration is not proved.
  assert_true(issues.length() > 0)
}

///|
test "styles a leading BOM does not hide a URL" {
  let (references, issues) = impact_style_test("\u{FEFF}url('font.ttf')", "css")
  assert_eq(issues.length(), 0)
  assert_eq(impact_style_specs(references), ["font.ttf"])
  assert_eq(references[0].column, 2)
}

///|
test "styles Sass load-css is not silently treated as having no inputs" {
  let (_, issues) = impact_style_test(
    "@include meta.load-css($module);", "scss",
  )
  assert_true(issues.any(issue => issue.reason.contains("load-css")))
}

///|
test "styles only CSS and SCSS with positive source origins are supported" {
  let (less, issues) = impact_extract_style_references(
    "x.less", "@import 'x';", "less", 1, 1,
  )
  assert_eq(less.length(), 0)
  assert_eq(issues.length(), 1)
  let (bad, bad_origin) = impact_extract_style_references(
    "x.css", "url(x)", "css", 0, 0,
  )
  assert_eq(bad.length(), 0)
  assert_eq(bad_origin.length(), 1)
  let (empty, empty_issues) = impact_style_test("", "scss")
  assert_eq(empty.length(), 0)
  assert_eq(empty_issues.length(), 0)
}
