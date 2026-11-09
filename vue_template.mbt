///|
/// Vue single-file-component support.
///
/// A `.vue` file keeps its template expressions inside HTML attribute strings
/// (`:src="logoQuan"`, `v-if="canCancel(item)"`). The JS tokenizer sees the
/// attribute value as one string literal, so a binding used only in a template
/// looked unused to `no_unused_imports`. This module extracts those
/// expressions and reports their identifier reads; `parse_source_for` appends
/// them to the file's usage list.
///
/// Interpolations (`{{ expr }}`) need no handling here: they are ordinary
/// text, so the main tokenizer already reads the identifiers inside them.

///|
/// Whether `c` may start a Vue attribute name: an identifier start, or one of
/// the binding sigils `:`, `@` and `#`.
fn vue_attr_start(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  c == '_' ||
  c == ':' ||
  c == '@' ||
  c == '#'
}

///|
/// Whether `c` may continue a Vue attribute name.
fn vue_attr_char(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '_' ||
  c == '-' ||
  c == ':' ||
  c == '.' ||
  c == '@' ||
  c == '#'
}

///|
/// Whether an attribute name carries a JS expression: `:prop`, `@event`,
/// `#slot` and every `v-*` directive (`v-if`, `v-for`, `v-bind:`, `v-on:`).
fn vue_is_binding(name : String) -> Bool {
  name.has_prefix(":") ||
  name.has_prefix("@") ||
  name.has_prefix("#") ||
  name.has_prefix("v-")
}

///|
/// Whether `c` is HTML whitespace.
fn vue_is_space(c : Char) -> Bool {
  c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

///|
/// First index of `needle` in `chars` at or after `from`.
fn vue_find(chars : Array[Char], needle : String, from : Int32) -> Int32? {
  let w = needle.to_array()
  let n = chars.length()
  let m = w.length()
  if m == 0 || from >= n {
    return None
  }
  let mut i = from
  while i + m <= n {
    let mut k = 0
    while k < m && chars[i + k] == w[k] {
      k += 1
    }
    if k == m {
      return Some(i)
    }
    i += 1
  }
  None
}

///|
/// 1-based line and column of `offset` in `src`.
fn vue_position(src : String, offset : Int32) -> (Int32, Int32) {
  let chars = src.to_array()
  let limit = if offset < chars.length() { offset } else { chars.length() }
  let mut line = 1
  let mut column = 1
  for i in 0..<limit {
    if chars[i] == '\n' {
      line += 1
      column = 1
    } else {
      column += 1
    }
  }
  (line, column)
}

///|
/// Identifier reads inside one binding expression. `offset` is the source
/// position of the expression, used for the reported line and column.
fn vue_expr_usages(
  expr : String,
  src : String,
  offset : Int32,
) -> Array[UsedIdent] {
  let out : Array[UsedIdent] = []
  let tokens = tokenize(expr)
  let (line, column) = vue_position(src, offset)
  for (idx, tok) in tokens.iter2() {
    if tok.kind != TokenKind::Ident || is_keyword(tok.text) {
      continue
    }
    if is_property_name(tokens, idx) {
      continue
    }
    out.push({ name: tok.text, line, column, })
  }
  out
}

///|
/// Mark the characters inside `<script>` and `<style>` blocks, so binding-like
/// text there (a string that happens to look like `:src="x"`) is not mistaken
/// for a template binding. Nested `<template>` tags are common in Vue, so the
/// scan must not stop at the first `</template>`; masking the script/style
/// blocks instead lets the whole template — however nested — be scanned.
fn vue_skip_regions(src : String) -> Array[Bool] {
  let chars = src.to_array()
  let skip = Array::make(chars.length(), false)
  for pair in [("<script", "</script>"), ("<style", "</style>")] {
    let (open, close) = pair
    let mut from = 0
    let mut go = true
    while go {
      match vue_find(chars, open, from) {
        None => go = false
        Some(s) => {
          let e = match vue_find(chars, close, s) {
            Some(x) => x + close.length()
            None => chars.length()
          }
          for k in s..<e {
            if k < chars.length() {
              skip[k] = true
            }
          }
          from = e
        }
      }
    }
  }
  skip
}

///|
/// Identifier reads that occur inside template binding expressions. Only
/// binding attribute values are treated as expressions; plain text and static
/// attributes such as `class="..."` are left alone, and `<script>`/`<style>`
/// blocks are ignored.
pub fn vue_template_usages(src : String) -> Array[UsedIdent] {
  let out : Array[UsedIdent] = []
  let chars = src.to_array()
  let n = chars.length()
  let skip = vue_skip_regions(src)
  let mut i = 0
  while i < n {
    if skip[i] || !vue_attr_start(chars[i]) {
      i += 1
      continue
    }
    let mut j = i
    while j < n && vue_attr_char(chars[j]) {
      j += 1
    }
    let name = String::from_array(chars[i:j])
    let mut k = j
    while k < n && vue_is_space(chars[k]) {
      k += 1
    }
    if k < n && chars[k] == '=' {
      k += 1
      while k < n && vue_is_space(chars[k]) {
        k += 1
      }
      if k < n && (chars[k] == '"' || chars[k] == '\'') {
        let quote = chars[k]
        let expr_start = k + 1
        let mut e = expr_start
        while e < n && chars[e] != quote {
          e += 1
        }
        if vue_is_binding(name) {
          let expr = String::from_array(chars[expr_start:e])
          for u in vue_expr_usages(expr, src, expr_start) {
            out.push(u)
          }
        }
        i = if e < n { e + 1 } else { e }
        continue
      }
    }
    i = j
  }
  out
}

///|
/// Parse a source file, choosing the front end by extension. A `.vue` file
/// additionally gains the identifier reads of its template binding
/// expressions, which live inside HTML attribute strings.
pub fn parse_source_for(rel : String, src : String) -> FileModel {
  let model = parse_source(src)
  if !rel.has_suffix(".vue") {
    return model
  }
  let extra = vue_template_usages(src)
  if extra.is_empty() {
    return model
  }
  let used = model.used.copy()
  for u in extra {
    used.push(u)
  }
  {
    imports: model.imports,
    exports: model.exports,
    decls: model.decls,
    used,
  }
}
