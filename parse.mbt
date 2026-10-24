///|
/// A structural parser for JavaScript/TypeScript sources.
///
/// Where the line matcher sees text and the tokenizer sees tokens, this
/// module sees *structure*: which modules a file imports, which names it
/// exports, which bindings it declares, and which identifiers it uses. That
/// model is what makes cross-file rules possible — unused imports, unresolved
/// relative imports, import cycles, dead exports — none of which a per-line
/// matcher can express.
///
/// The parser is deliberately partial. It recognizes the statement shapes it
/// needs (`import`/`export`/`require` and top-level declarations) and treats
/// everything else as an opaque token stream. It never fails on syntax it does
/// not understand: a linter that refuses to scan a file with a syntax error
/// would hide every other finding in that file.

///|
/// How a module reference entered the file.
pub enum ImportKind {
  /// `import ... from '...'` or `import '...'`
  Static
  /// `import('...')`
  Dynamic
  /// `require('...')`
  Require
  /// `export ... from '...'` (a re-export is also an import)
  ReExport
} derive(Debug, Eq)

///|
/// One name introduced by an import: the local binding and the name as the
/// imported module exports it (`"default"` for default imports, `"*"` for
/// namespace imports).
pub struct ImportName {
  local : String
  imported : String
} derive(Debug)

///|
/// A module reference with its position (1-based, pointing at the `import`,
/// `export` or `require` keyword that starts it).
pub struct ImportSpec {
  kind : ImportKind
  /// The module specifier exactly as written, including quotes.
  source : String
  names : Array[ImportName]
  line : Int32
  column : Int32
  /// Whether this is a `import type` / `export type` (TypeScript).
  type_only : Bool
} derive(Debug)

///|
/// A name this file exports. `"default"` marks a default export; `"*"` marks
/// `export * from`. `source` is set for re-exports.
pub struct ExportSpec {
  names : Array[String]
  source : String?
  line : Int32
  column : Int32
} derive(Debug)

///|
/// The kind of a top-level binding.
pub enum DeclKind {
  Var
  Function
  Class
} derive(Debug, Eq)

///|
/// A declared binding name with its position.
pub struct Decl {
  name : String
  kind : DeclKind
  line : Int32
  column : Int32
} derive(Debug)

///|
/// An identifier read in code (not as part of an import statement), used to
/// decide whether an imported binding is referenced.
pub struct UsedIdent {
  name : String
  line : Int32
  column : Int32
} derive(Debug)

///|
/// The structural model of one source file.
pub struct FileModel {
  imports : Array[ImportSpec]
  exports : Array[ExportSpec]
  decls : Array[Decl]
  used : Array[UsedIdent]
} derive(Debug)

///|
/// Parse a source string into a structural model.
pub fn parse_source(src : String) -> FileModel {
  parse_tokens(tokenize(src))
}

///|
/// Parse a token stream into a structural model.
///
/// Two logical passes over the same array: the statement walker records
/// imports, exports and declarations (and the token spans of import
/// statements), then a usage walker collects identifier reads outside those
/// spans. Import statements are excluded so that an import's own names never
/// count as usages of themselves.
pub fn parse_tokens(tokens : Array[Token]) -> FileModel {
  let imports : Array[ImportSpec] = []
  let exports : Array[ExportSpec] = []
  let decls : Array[Decl] = []
  // Token index ranges covered by import statements, for usage exclusion.
  let import_spans : Array[(Int32, Int32)] = []
  let n = tokens.length()
  let mut i = 0
  // Brace depth of ordinary blocks, so declarations inside functions are not
  // mistaken for top-level ones.
  let mut depth = 0
  while i < n {
    let tok = tokens[i]
    if tok.kind == TokenKind::Punct {
      if tok.text == "{" {
        depth += 1
      } else if tok.text == "}" {
        if depth > 0 {
          depth -= 1
        }
      }
      i += 1
      continue
    }
    if tok.kind != TokenKind::Ident {
      i += 1
      continue
    }
    let word = tok.text
    if word == "import" && !next_is_dot(tokens, i) {
      i = parse_import(tokens, i, imports, import_spans)
      continue
    }
    if word == "export" {
      i = parse_export(tokens, i, exports, imports, decls, depth)
      continue
    }
    if word == "require" && next_is_punct(tokens, i, "(") {
      i = parse_require(tokens, i, imports, import_spans)
      continue
    }
    if word == "const" || word == "let" || word == "var" {
      // Only top-level bindings enter the symbol table; a `const` inside a
      // function body is a local, not a module-level declaration.
      if depth == 0 {
        i = parse_var_decl(tokens, i, decls)
      } else {
        i += 1
      }
      continue
    }
    if word == "function" ||
      (word == "async" && nth_is_word(tokens, i, 1, "function")) {
      i = parse_function_decl(tokens, i, decls, depth)
      continue
    }
    if word == "class" {
      i = parse_class_decl(tokens, i, decls, depth)
      continue
    }
    i += 1
  }
  // Usage pass: every identifier outside import statement spans, skipping
  // property names (`.foo`) which are not variable reads.
  let used : Array[UsedIdent] = []
  for (idx, tok) in tokens.iter2() {
    if tok.kind != TokenKind::Ident || is_keyword(tok.text) {
      continue
    }
    if in_spans(import_spans, idx) {
      continue
    }
    if idx > 0 &&
      tokens[idx - 1].kind == TokenKind::Punct &&
      tokens[idx - 1].text == "." {
      continue
    }
    used.push({ name: tok.text, line: tok.line, column: tok.column, })
  }
  { imports, exports, decls, used, }
}

///|
/// Whether the token after `i` is the `.` punctuator (`import.meta` is not an
/// import statement).
fn next_is_dot(tokens : Array[Token], i : Int32) -> Bool {
  next_is_punct(tokens, i, ".")
}

///|
/// Whether the token after `i` is the given punctuator.
fn next_is_punct(tokens : Array[Token], i : Int32, text : String) -> Bool {
  i + 1 < tokens.length() &&
  tokens[i + 1].kind == TokenKind::Punct &&
  tokens[i + 1].text == text
}

///|
/// Whether the token `offset` positions after `i` is the given word.
fn nth_is_word(
  tokens : Array[Token],
  i : Int32,
  offset : Int32,
  word : String,
) -> Bool {
  i + offset < tokens.length() &&
  tokens[i + offset].kind == TokenKind::Ident &&
  tokens[i + offset].text == word
}

///|
/// Whether token index `idx` falls inside any recorded span.
fn in_spans(spans : Array[(Int32, Int32)], idx : Int32) -> Bool {
  for (start, end) in spans {
    if idx >= start && idx < end {
      return true
    }
  }
  false
}

///|
/// Parse an `import` statement at `i`; returns the index just past it.
fn parse_import(
  tokens : Array[Token],
  i : Int32,
  imports : Array[ImportSpec],
  spans : Array[(Int32, Int32)],
) -> Int32 {
  let n = tokens.length()
  let head = tokens[i]
  let mut j = i + 1
  // `import('...')` — dynamic import, no bindings.
  if j < n && tokens[j].kind == TokenKind::Punct && tokens[j].text == "(" {
    j += 1
    if j < n && tokens[j].kind == TokenKind::Str {
      imports.push({
        kind: ImportKind::Dynamic,
        source: tokens[j].text,
        names: [],
        line: head.line,
        column: head.column,
        type_only: false,
      })
      j += 1
      // Skip to the closing paren; anything else is tolerated.
      while j < n &&
            !(tokens[j].kind == TokenKind::Punct && tokens[j].text == ")") {
        j += 1
      }
      if j < n {
        j += 1
      }
      spans.push((i, j))
      return j
    }
    spans.push((i, j))
    return j
  }
  // `import '...'` — side-effect only.
  if j < n && tokens[j].kind == TokenKind::Str {
    imports.push({
      kind: ImportKind::Static,
      source: tokens[j].text,
      names: [],
      line: head.line,
      column: head.column,
      type_only: false,
    })
    spans.push((i, j + 1))
    return j + 1
  }
  // Clause form: optional `type`, then default / namespace / named.
  let mut type_only = false
  if j < n &&
    tokens[j].kind == TokenKind::Ident &&
    tokens[j].text == "type" &&
    nth_is_word(tokens, j, 1, "{") == false &&
    j + 1 < n &&
    (
      tokens[j + 1].kind == TokenKind::Ident ||
      (
        tokens[j + 1].kind == TokenKind::Punct &&
        (tokens[j + 1].text == "{" || tokens[j + 1].text == "*")
      )
    ) {
    type_only = true
    j += 1
  }
  let names : Array[ImportName] = []
  let mut source = ""
  let mut j2 = j
  while j2 < n {
    let t = tokens[j2]
    if t.kind == TokenKind::Punct && t.text == "{" {
      j2 = parse_named_imports(tokens, j2, names)
      continue
    }
    if t.kind == TokenKind::Punct && t.text == "*" {
      // `* as ns`
      let mut local_name = "*"
      if nth_is_word(tokens, j2, 1, "as") &&
        j2 + 2 < n &&
        tokens[j2 + 2].kind == TokenKind::Ident {
        local_name = tokens[j2 + 2].text
        j2 += 3
      } else {
        j2 += 1
      }
      names.push({ local: local_name, imported: "*", })
      continue
    }
    if t.kind == TokenKind::Ident && t.text == "from" {
      if j2 + 1 < n && tokens[j2 + 1].kind == TokenKind::Str {
        source = tokens[j2 + 1].text
        j2 += 2
      }
      break
    }
    if t.kind == TokenKind::Ident && t.text == "require" {
      // `import x = require('...')`
      if j2 + 2 < n &&
        tokens[j2 + 1].kind == TokenKind::Punct &&
        tokens[j2 + 1].text == "(" &&
        tokens[j2 + 2].kind == TokenKind::Str {
        source = tokens[j2 + 2].text
        j2 += 3
      }
      break
    }
    if t.kind == TokenKind::Ident && !is_keyword(t.text) {
      // Default import: `import a` or `import a, { b }`.
      names.push({ local: t.text, imported: "default", })
      j2 += 1
      if j2 < n && tokens[j2].kind == TokenKind::Punct && tokens[j2].text == "," {
        j2 += 1
      }
      continue
    }
    if t.kind == TokenKind::Punct && (t.text == ";" || t.text == ",") {
      j2 += 1
      continue
    }
    break
  }
  imports.push({
    kind: ImportKind::Static,
    source,
    names,
    line: head.line,
    column: head.column,
    type_only,
  })
  spans.push((i, j2))
  j2
}

///|
/// Parse a `{ a, b as c }` named list starting at the `{` token; returns the
/// index just past the closing `}`.
fn parse_named_imports(
  tokens : Array[Token],
  start : Int32,
  names : Array[ImportName],
) -> Int32 {
  let n = tokens.length()
  let mut j = start + 1
  while j < n {
    let t = tokens[j]
    if t.kind == TokenKind::Punct && t.text == "}" {
      return j + 1
    }
    if t.kind == TokenKind::Ident && !is_keyword(t.text) {
      let imported = t.text
      let mut local_name = imported
      j += 1
      if j + 1 < n &&
        tokens[j].kind == TokenKind::Ident &&
        tokens[j].text == "as" &&
        tokens[j + 1].kind == TokenKind::Ident {
        local_name = tokens[j + 1].text
        j += 2
      }
      names.push({ local: local_name, imported, })
      continue
    }
    if t.kind == TokenKind::Punct && (t.text == "," || t.text == "type") {
      j += 1
      continue
    }
    // Anything else (a stray token) is skipped to stay resilient.
    j += 1
  }
  j
}

///|
/// Parse `require('...')` at `i`; returns the index just past it.
fn parse_require(
  tokens : Array[Token],
  i : Int32,
  imports : Array[ImportSpec],
  spans : Array[(Int32, Int32)],
) -> Int32 {
  let n = tokens.length()
  let head = tokens[i]
  let mut j = i + 2
  let mut source = ""
  if j < n && tokens[j].kind == TokenKind::Str {
    source = tokens[j].text
    j += 1
  }
  while j < n && !(tokens[j].kind == TokenKind::Punct && tokens[j].text == ")") {
    j += 1
  }
  if j < n {
    j += 1
  }
  imports.push({
    kind: ImportKind::Require,
    source,
    names: [],
    line: head.line,
    column: head.column,
    type_only: false,
  })
  spans.push((i, j))
  j
}

///|
/// Parse an `export` statement at `i`; returns the index just past the part
/// that matters (the specifier for re-exports, the declared name for
/// declarations). Export spans are *not* excluded from usage collection,
/// because `export { foo }` references `foo`.
fn parse_export(
  tokens : Array[Token],
  i : Int32,
  exports : Array[ExportSpec],
  imports : Array[ImportSpec],
  decls : Array[Decl],
  depth : Int32,
) -> Int32 {
  let n = tokens.length()
  let head = tokens[i]
  let mut j = i + 1
  // `export type ...`
  if j < n &&
    tokens[j].kind == TokenKind::Ident &&
    tokens[j].text == "type" &&
    j + 1 < n &&
    (
      tokens[j + 1].kind == TokenKind::Ident ||
      (
        tokens[j + 1].kind == TokenKind::Punct &&
        (tokens[j + 1].text == "{" || tokens[j + 1].text == "*")
      )
    ) {
    j += 1
  }
  // `export declare ...`
  if j < n && tokens[j].kind == TokenKind::Ident && tokens[j].text == "declare" {
    j += 1
  }
  if j >= n {
    return j
  }
  let t = tokens[j]
  // `export * [as ns] from '...'`
  if t.kind == TokenKind::Punct && t.text == "*" {
    let mut name = "*"
    j += 1
    if j + 1 < n &&
      tokens[j].kind == TokenKind::Ident &&
      tokens[j].text == "as" &&
      tokens[j + 1].kind == TokenKind::Ident {
      name = tokens[j + 1].text
      j += 2
    }
    let mut source : String? = None
    if j + 1 < n &&
      tokens[j].kind == TokenKind::Ident &&
      tokens[j].text == "from" &&
      tokens[j + 1].kind == TokenKind::Str {
      source = Some(tokens[j + 1].text)
      j += 2
    }
    exports.push({
      names: [name],
      source,
      line: head.line,
      column: head.column,
    })
    match source {
      Some(src) =>
        imports.push({
          kind: ImportKind::ReExport,
          source: src,
          names: [{ local: name, imported: "*", }],
          line: head.line,
          column: head.column,
          type_only: false,
        })
      None => ()
    }
    return j
  }
  // `export { a, b as c } [from '...']`
  if t.kind == TokenKind::Punct && t.text == "{" {
    let names : Array[String] = []
    let re_names : Array[ImportName] = []
    j = parse_named_exports(tokens, j, names, re_names)
    let mut source : String? = None
    if j < n &&
      tokens[j].kind == TokenKind::Ident &&
      tokens[j].text == "from" &&
      j + 1 < n &&
      tokens[j + 1].kind == TokenKind::Str {
      source = Some(tokens[j + 1].text)
      j += 2
    }
    exports.push({ names, source, line: head.line, column: head.column, })
    match source {
      Some(src) =>
        imports.push({
          kind: ImportKind::ReExport,
          source: src,
          names: re_names,
          line: head.line,
          column: head.column,
          type_only: false,
        })
      None => ()
    }
    return j
  }
  // `export default ...`
  if t.kind == TokenKind::Ident && t.text == "default" {
    exports.push({
      names: ["default"],
      source: None,
      line: head.line,
      column: head.column,
    })
    return j + 1
  }
  // `export const/let/var/function/class ...` — declaration exports.
  if t.kind == TokenKind::Ident &&
    (t.text == "const" || t.text == "let" || t.text == "var") {
    let before = decls.length()
    j = parse_var_decl(tokens, j, decls)
    let names : Array[String] = []
    for k in before..<decls.length() {
      names.push(decls[k].name)
    }
    if names.length() > 0 {
      exports.push({
        names,
        source: None,
        line: head.line,
        column: head.column,
      })
    }
    return j
  }
  if t.kind == TokenKind::Ident &&
    (
      t.text == "function" ||
      (t.text == "async" && nth_is_word(tokens, j, 1, "function")) ||
      t.text == "class"
    ) {
    let before = decls.length()
    if t.text == "class" {
      j = parse_class_decl(tokens, j, decls, depth)
    } else {
      j = parse_function_decl(tokens, j, decls, depth)
    }
    let names : Array[String] = []
    for k in before..<decls.length() {
      names.push(decls[k].name)
    }
    if names.length() > 0 {
      exports.push({
        names,
        source: None,
        line: head.line,
        column: head.column,
      })
    }
    return j
  }
  // Unknown export form: skip the keyword and keep scanning.
  j
}

///|
/// Parse an `export { a, b as c }` list; returns the index past the `}`. In an
/// export clause the name *before* `as` is the local binding and the name
/// *after* it is what the module exports — the opposite of an import clause.
fn parse_named_exports(
  tokens : Array[Token],
  start : Int32,
  names : Array[String],
  re_names : Array[ImportName],
) -> Int32 {
  let n = tokens.length()
  let mut j = start + 1
  while j < n {
    let t = tokens[j]
    if t.kind == TokenKind::Punct && t.text == "}" {
      return j + 1
    }
    if t.kind == TokenKind::Ident && !is_keyword(t.text) {
      let local_name = t.text
      let mut exported = local_name
      j += 1
      if j + 1 < n &&
        tokens[j].kind == TokenKind::Ident &&
        tokens[j].text == "as" &&
        tokens[j + 1].kind == TokenKind::Ident {
        exported = tokens[j + 1].text
        j += 2
      }
      names.push(exported)
      re_names.push({ local: local_name, imported: exported, })
      continue
    }
    j += 1
  }
  j
}

///|
/// Parse a `const`/`let`/`var` declaration starting at the keyword; records
/// each simple binding name. Destructuring patterns are skipped: their inner
/// names are not tracked, which only limits future variable-usage rules.
fn parse_var_decl(
  tokens : Array[Token],
  i : Int32,
  decls : Array[Decl],
) -> Int32 {
  let n = tokens.length()
  let head = tokens[i]
  let mut j = i + 1
  while j < n {
    let t = tokens[j]
    if t.kind == TokenKind::Punct && (t.text == ";" || t.text == "}") {
      if t.text == ";" {
        j += 1
      }
      break
    }
    if t.kind == TokenKind::Punct && t.text == "{" {
      // Skip a destructuring pattern, braces balanced.
      let mut d = 1
      j += 1
      while j < n && d > 0 {
        if tokens[j].kind == TokenKind::Punct && tokens[j].text == "{" {
          d += 1
        } else if tokens[j].kind == TokenKind::Punct && tokens[j].text == "}" {
          d -= 1
        }
        j += 1
      }
      continue
    }
    if t.kind == TokenKind::Punct && t.text == "[" {
      let mut d = 1
      j += 1
      while j < n && d > 0 {
        if tokens[j].kind == TokenKind::Punct && tokens[j].text == "[" {
          d += 1
        } else if tokens[j].kind == TokenKind::Punct && tokens[j].text == "]" {
          d -= 1
        }
        j += 1
      }
      continue
    }
    if t.kind == TokenKind::Ident && !is_keyword(t.text) {
      decls.push({
        name: t.text,
        kind: DeclKind::Var,
        line: t.line,
        column: t.column,
      })
      j += 1
      continue
    }
    if t.kind == TokenKind::Punct && t.text == "," {
      j += 1
      continue
    }
    if t.kind == TokenKind::Punct && t.text == "=" {
      // Skip the initializer up to the next `,` or `;` at this level. A
      // dynamic `import(...)` or `require(...)` stops the whole declaration
      // walk so the main loop can record it as a module reference.
      j += 1
      let mut d = 0
      let mut stop = false
      while j < n {
        let u = tokens[j]
        if u.kind == TokenKind::Ident &&
          (u.text == "import" || u.text == "require") &&
          j + 1 < n &&
          tokens[j + 1].kind == TokenKind::Punct &&
          tokens[j + 1].text == "(" {
          stop = true
          break
        }
        if u.kind == TokenKind::Punct {
          if u.text == "{" || u.text == "[" || u.text == "(" {
            d += 1
          } else if u.text == "}" || u.text == "]" || u.text == ")" {
            if d == 0 {
              break
            }
            d -= 1
          } else if (u.text == "," || u.text == ";") && d == 0 {
            break
          }
        }
        j += 1
      }
      if stop {
        break
      }
      continue
    }
    // Type annotations and anything else are skipped.
    j += 1
  }
  ignore(head)
  j
}

///|
/// Parse a `function` (or `async function`) declaration at `i`.
fn parse_function_decl(
  tokens : Array[Token],
  i : Int32,
  decls : Array[Decl],
  depth : Int32,
) -> Int32 {
  let n = tokens.length()
  let mut j = i + 1
  if tokens[j - 1].text == "async" {
    j += 1
  }
  // Generator marker.
  if j < n && tokens[j].kind == TokenKind::Punct && tokens[j].text == "*" {
    j += 1
  }
  if depth == 0 && j < n && tokens[j].kind == TokenKind::Ident {
    let name = tokens[j]
    decls.push({
      name: name.text,
      kind: DeclKind::Function,
      line: name.line,
      column: name.column,
    })
    return j + 1
  }
  j
}

///|
/// Parse a `class` declaration at `i`.
fn parse_class_decl(
  tokens : Array[Token],
  i : Int32,
  decls : Array[Decl],
  depth : Int32,
) -> Int32 {
  let n = tokens.length()
  let j = i + 1
  if depth == 0 && j < n && tokens[j].kind == TokenKind::Ident {
    let name = tokens[j]
    decls.push({
      name: name.text,
      kind: DeclKind::Class,
      line: name.line,
      column: name.column,
    })
    return j + 1
  }
  j
}

///|
/// Reserved words. They are never bindings, and listing them keeps the usage
/// pass from counting language keywords as identifier reads.
fn is_keyword(word : String) -> Bool {
  [
    "break", "case", "catch", "class", "const", "continue", "debugger", "default",
    "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for",
    "function", "if", "import", "in", "instanceof", "new", "null", "return", "super",
    "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while", "with",
    "yield", "let", "static", "async", "await", "from", "as", "of", "get", "set",
    "type", "declare", "abstract", "implements", "interface", "namespace", "private",
    "protected", "public", "readonly", "keyof", "infer", "is", "asserts", "satisfies",
    "undefined", "NaN", "Infinity",
  ].contains(word)
}

///|
/// Expose derived impls as regular methods for external callers.

///|
pub extend ImportKind with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend ImportKind with Eq::{equal, not_equal}

///|
pub extend ImportName with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend ImportSpec with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend ExportSpec with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend DeclKind with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend DeclKind with Eq::{equal, not_equal}

///|
pub extend Decl with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend UsedIdent with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend FileModel with @moonbitlang/core/debug.Debug::{to_repr}
