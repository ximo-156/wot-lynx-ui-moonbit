///|
/// Tests for the tokenizer.

///|
/// Short name for a token kind, for compact assertions.
fn kind_name(kind : TokenKind) -> String {
  match kind {
    Ident => "ident"
    Number => "number"
    Str => "str"
    TemplateText => "text"
    Backtick => "tick"
    InterpOpen => "open"
    InterpClose => "close"
    RegexLit => "regex"
    Punct => "punct"
  }
}

///|
/// Render tokens as `kind:text` pairs for compact assertions.
fn render(tokens : Array[Token]) -> String {
  tokens.map(t => "\{kind_name(t.kind)}:\{t.text}").join(" ")
}

///|
test "tokenize simple statement" {
  let toks = tokenize("const x = 1;")
  assert_eq(render(toks), "ident:const ident:x punct:= number:1 punct:;")
}

///|
test "tokenize string keeps quotes and escapes" {
  let toks = tokenize("const s = 'a\\'b';")
  assert_eq(toks.length(), 5)
  assert_eq(toks[3].kind, TokenKind::Str)
  assert_eq(toks[3].text, "'a\\'b'")
}

///|
test "tokenize skips comments" {
  let toks = tokenize("// leading\nlet x = 1; /* tail */ let y = 2;")
  let words = toks.map(t => t.text)
  assert_eq(words, ["let", "x", "=", "1", ";", "let", "y", "=", "2", ";"])
  // The comment does not shift line numbers of later tokens.
  assert_eq(toks[5].line, 2)
}

///|
test "tokenize template literal" {
  let toks = tokenize("const t = `a${b}c${d}e`;")
  let kinds = toks.map(t => t.kind)
  assert_eq(kinds, [
    TokenKind::Ident,
    TokenKind::Ident,
    TokenKind::Punct,
    TokenKind::Backtick,
    TokenKind::TemplateText,
    TokenKind::InterpOpen,
    TokenKind::Ident,
    TokenKind::InterpClose,
    TokenKind::TemplateText,
    TokenKind::InterpOpen,
    TokenKind::Ident,
    TokenKind::InterpClose,
    TokenKind::TemplateText,
    TokenKind::Backtick,
    TokenKind::Punct,
  ])
}

///|
test "tokenize template with nested braces and objects" {
  // `${ {a: 1}.a }` — the inner braces belong to the interpolation.
  let toks = tokenize("const t = `${ {a: 1}.a }`;")
  let interp_open = toks.count_if(t => t.kind == TokenKind::InterpOpen)
  let interp_close = toks.count_if(t => t.kind == TokenKind::InterpClose)
  assert_eq(interp_open, 1)
  assert_eq(interp_close, 1)
  assert_eq(toks.count_if(t => t.kind == TokenKind::Backtick), 2)
}

///|
test "tokenize escaped dollar in template" {
  // `\${` is text, not an interpolation.
  let toks = tokenize("const t = `\\${x}`;")
  assert_eq(toks.count_if(t => t.kind == TokenKind::InterpOpen), 0)
  assert_eq(toks.count_if(t => t.kind == TokenKind::Backtick), 2)
}

///|
test "tokenize url in template is not a comment" {
  let toks = tokenize("const u = `https://x.dev//y`;")
  assert_eq(toks.count_if(t => t.kind == TokenKind::TemplateText), 1)
  assert_eq(toks[4].text, "https://x.dev//y")
}

///|
test "tokenize regex vs division" {
  let re = tokenize("const re = /ab+c/gi;")
  assert_eq(re[3].kind, TokenKind::RegexLit)
  assert_eq(re[3].text, "/ab+c/gi")
  let div = tokenize("const q = a / b;")
  assert_eq(div.count_if(t => t.kind == TokenKind::RegexLit), 0)
  assert_eq(div[4].kind, TokenKind::Punct)
}

///|
test "tokenize regex after return keyword" {
  let toks = tokenize("function f() { return /x/.test(s); }")
  assert_eq(toks.count_if(t => t.kind == TokenKind::RegexLit), 1)
}

///|
test "tokenize positions count characters" {
  let toks = tokenize("  const 中文 = 1;")
  let decl = toks[1]
  assert_eq(decl.text, "中文")
  assert_eq(decl.line, 1)
  // Two spaces + `const` + one space: the identifier starts at column 9.
  assert_eq(decl.column, 9)
}

///|
test "tokenize multiline string positions" {
  let toks = tokenize("const a = 1;\nconst b = 2;")
  assert_eq(toks[6].line, 2)
  assert_eq(toks[6].column, 7)
}

///|
test "tokenize numbers" {
  let toks = tokenize(
    "let a = 0xFF; let b = 1.5e3; let c = 10n; let d = 1_000;",
  )
  assert_eq(toks[3].text, "0xFF")
  assert_eq(toks[8].text, "1.5e3")
  assert_eq(toks[13].text, "10n")
  assert_eq(toks[18].text, "1_000")
}

///|
test "tokenize unterminated string stops at line break" {
  let toks = tokenize("const s = 'oops\nconst t = 1;")
  assert_eq(toks[3].kind, TokenKind::Str)
  assert_eq(toks[3].text, "'oops")
  // Scanning continues on the next line instead of swallowing the file.
  assert_eq(toks[4].line, 2)
}

///|
test "tokenize hashbang is skipped" {
  let toks = tokenize("#!/usr/bin/env node\nconst x = 1;")
  assert_eq(toks[0].text, "const")
  assert_eq(toks[0].line, 2)
}

///|
test "tokenize import statement shape" {
  let toks = tokenize("import { a, b as c } from './m';")
  let words = toks.map(t => t.text)
  assert_eq(words, [
    "import", "{", "a", ",", "b", "as", "c", "}", "from", "'./m'", ";",
  ])
}
