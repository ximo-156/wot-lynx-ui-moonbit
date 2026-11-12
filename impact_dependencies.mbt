///|
/// Conservative dependency extraction for MoonImpact. This module deliberately
/// does no filesystem work. Unsupported dependency expressions are issues, not
/// evidence that a file has no dependencies.
priv struct ImpactDepScan {
  file : String
  references : Array[ImpactReference]
  issues : Array[ImpactIssue]
}

///|
priv struct ImpactDepFunction {
  name_index : Int32
  params_open : Int32
  params_close : Int32
  body_open : Int32
  body_close : Int32
}

///|
/// A path without a host filesystem lookup: relative text, the project root,
/// or the containing file's directory. URL objects cannot enter path.join.
priv struct ImpactReadValue {
  base : String
  path : String
  is_url : Bool
}

///|
priv struct ImpactReadConst {
  name_index : Int32
  start : Int32
  end : Int32
}

///|
/// Only a single-return filesystem call is eligible for automatic inference.
/// The first-argument expression is re-evaluated symbolically at each caller.
priv struct ImpactReadWrapper {
  name_index : Int32
  parameter : String
  path_start : Int32
  path_end : Int32
  body_start : Int32
  body_end : Int32
}

///|
priv struct ImpactReadEnv {
  file : String
  tokens : Array[Token]
  mates : Array[Int32]
  roles : Map[String, String]
  blocked : Set[String]
  constants : Map[String, ImpactReadConst]
}

///|
priv struct ImpactDepHtmlTag {
  name : String
  attributes : Array[(String, String?)]
  start : Int32
  end : Int32
  closing : Bool
  self_closing : Bool
}

///|
fn impact_dep_issue(
  scan : ImpactDepScan,
  line : Int32,
  reason : String,
) -> Unit {
  if !scan.issues.any(issue => issue.line == line && issue.reason == reason) {
    scan.issues.push({ file: scan.file, line, reason, })
  }
}

///|
fn impact_dep_reference(
  scan : ImpactDepScan,
  specifier : String,
  kind : String,
  line : Int32,
  column : Int32,
) -> Unit {
  if !scan.references.any(reference => {
      reference.specifier == specifier &&
      reference.kind == kind &&
      reference.line == line &&
      reference.column == column
    }) {
    scan.references.push({ file: scan.file, specifier, kind, line, column, })
  }
}

///|
fn impact_dep_at(tokens : Array[Token], index : Int32, text : String) -> Bool {
  index >= 0 && index < tokens.length() && tokens[index].text == text
}

///|
fn impact_dep_member(tokens : Array[Token], index : Int32) -> Bool {
  index > 0 && impact_dep_at(tokens, index - 1, ".")
}

///|
/// Escapes are intentionally unsupported in dependency strings. A quoted
/// prefix of a concatenation is not a literal dependency expression either;
/// callers check that the complete expression consists of this token.
fn impact_dep_literal(text : String) -> String? {
  let chars = text.to_array()
  if chars.length() < 2 ||
    (chars[0] != '\'' && chars[0] != '"') ||
    chars[chars.length() - 1] != chars[0] {
    return None
  }
  for i in 1..<(chars.length() - 1) {
    let c = chars[i]
    if c == '\\' || c == '\u{0}' || is_line_break(c) || c == chars[0] {
      return None
    }
  }
  let value = String::from_array(chars[1:chars.length() - 1])
  if value == "" {
    None
  } else {
    Some(value)
  }
}

///|
/// Coordinates use the same character/CRLF conventions as tokenize().
fn impact_dep_position(chars : Array[Char], offset : Int32) -> (Int32, Int32) {
  let mut line = 1
  let mut column = 1
  let mut i = 0
  while i < offset && i < chars.length() {
    if is_line_break(chars[i]) {
      if chars[i] == '\r' && i + 1 < offset && chars[i + 1] == '\n' {
        i += 1
      }
      line += 1
      column = 1
    } else {
      column += 1
    }
    i += 1
  }
  (line, column)
}

///|
fn impact_dep_starts(
  chars : Array[Char],
  offset : Int32,
  text : String,
) -> Bool {
  let word = text.to_array()
  if offset < 0 || offset + word.length() > chars.length() {
    return false
  }
  for i in 0..<word.length() {
    if chars[offset + i] != word[i] {
      return false
    }
  }
  true
}

///|
/// Match ordinary groups and template interpolation groups without reading
/// punctuation that is inside string, regex or template-text tokens.
fn impact_dep_groups(
  scan : ImpactDepScan,
  tokens : Array[Token],
) -> (Array[Int32], Array[Int32]) {
  let mates = Array::make(tokens.length(), -1)
  let depths = Array::make(tokens.length(), 0)
  let stack : Array[Int32] = []
  let mut curly_depth = 0
  let mut backticks = 0
  for i in 0..<tokens.length() {
    let token = tokens[i]
    depths[i] = curly_depth
    if token.kind == Backtick {
      backticks += 1
    }
    if token.kind == Str {
      let chars = token.text.to_array()
      if chars.length() < 2 || chars[chars.length() - 1] != chars[0] {
        impact_dep_issue(scan, token.line, "unterminated JavaScript string")
      }
    }
    let opening = token.kind == InterpOpen ||
      (token.kind == Punct && ["(", "[", "{"].contains(token.text))
    let closing = token.kind == InterpClose ||
      (token.kind == Punct && [")", "]", "}"].contains(token.text))
    if opening {
      stack.push(i)
      if token.text == "{" || token.kind == InterpOpen {
        curly_depth += 1
      }
    } else if closing {
      if stack.is_empty() {
        impact_dep_issue(scan, token.line, "unbalanced JavaScript delimiter")
        continue
      }
      let open = stack[stack.length() - 1]
      let expected = match tokens[open].text {
        "(" => ")"
        "[" => "]"
        _ => "}"
      }
      if token.text != expected {
        impact_dep_issue(scan, token.line, "unbalanced JavaScript delimiter")
        continue
      }
      ignore(stack.pop())
      mates[open] = i
      mates[i] = open
      if expected == "}" && curly_depth > 0 {
        curly_depth -= 1
      }
    }
  }
  if !stack.is_empty() {
    impact_dep_issue(
      scan,
      tokens[stack[0]].line,
      "unclosed JavaScript delimiter",
    )
  }
  if backticks % 2 != 0 {
    impact_dep_issue(scan, 1, "unterminated or unsupported template literal")
  }
  (mates, depths)
}

///|
fn impact_dep_attr(tag : ImpactDepHtmlTag, name : String) -> String? {
  for (key, value) in tag.attributes {
    if key == name {
      return value
    }
  }
  None
}

///|
fn impact_dep_has_attr(tag : ImpactDepHtmlTag, name : String) -> Bool {
  tag.attributes.any(pair => pair.0 == name)
}

///|
fn impact_dep_html_name(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '-' ||
  c == '_' ||
  c == ':' ||
  c == '.'
}

///|
/// Read one actual HTML tag, respecting quoted attribute values. The caller
/// never invokes this inside HTML comments or script/style bodies.
fn impact_dep_html_tag(chars : Array[Char], start : Int32) -> ImpactDepHtmlTag? {
  let n = chars.length()
  if start >= n || chars[start] != '<' {
    return None
  }
  let mut i = start + 1
  let closing = i < n && chars[i] == '/'
  if closing {
    i += 1
  }
  let name_start = i
  while i < n && impact_dep_html_name(chars[i]) {
    i += 1
  }
  if i == name_start {
    return None
  }
  let name = String::from_array(chars[name_start:i]).to_lower()
  let attributes : Array[(String, String?)] = []
  while i < n {
    while i < n && vue_is_space(chars[i]) {
      i += 1
    }
    if i >= n {
      return None
    }
    if chars[i] == '>' {
      return Some({
        name,
        attributes,
        start,
        end: i + 1,
        closing,
        self_closing: false,
      })
    }
    if chars[i] == '/' && i + 1 < n && chars[i + 1] == '>' {
      return Some({
        name,
        attributes,
        start,
        end: i + 2,
        closing,
        self_closing: true,
      })
    }
    let key_start = i
    while i < n &&
          !vue_is_space(chars[i]) &&
          chars[i] != '=' &&
          chars[i] != '>' &&
          chars[i] != '/' {
      i += 1
    }
    if i == key_start {
      return None
    }
    let key = String::from_array(chars[key_start:i]).to_lower()
    while i < n && vue_is_space(chars[i]) {
      i += 1
    }
    let mut value : String? = None
    if i < n && chars[i] == '=' {
      i += 1
      while i < n && vue_is_space(chars[i]) {
        i += 1
      }
      if i >= n {
        return None
      }
      if chars[i] == '\'' || chars[i] == '"' {
        let quote = chars[i]
        i += 1
        let value_start = i
        while i < n && chars[i] != quote {
          i += 1
        }
        if i == n {
          return None
        }
        value = Some(String::from_array(chars[value_start:i]))
        i += 1
      } else {
        let value_start = i
        while i < n && !vue_is_space(chars[i]) && chars[i] != '>' {
          if chars[i] == '/' && i + 1 < n && chars[i + 1] == '>' {
            break
          }
          i += 1
        }
        value = Some(String::from_array(chars[value_start:i]))
      }
    }
    attributes.push((key, value))
  }
  None
}

///|
fn impact_dep_raw_close(
  chars : Array[Char],
  start : Int32,
  name : String,
) -> ImpactDepHtmlTag? {
  let mut i = start
  while i < chars.length() {
    if impact_dep_starts(chars, i, "</") {
      match impact_dep_html_tag(chars, i) {
        Some(tag) if tag.closing && tag.name == name => return Some(tag)
        _ => ()
      }
    }
    i += 1
  }
  None
}

///|
/// A moustache's quoted text is not HTML markup. We only skip it; template
/// expressions are not interpreted as module-loading JavaScript.
fn impact_dep_moustache_end(chars : Array[Char], start : Int32) -> Int32? {
  let mut i = start + 2
  let mut quote : Char? = None
  while i < chars.length() {
    let c = chars[i]
    match quote {
      Some(q) => {
        if c == '\\' {
          i += 2
          continue
        }
        if c == q {
          quote = None
        }
      }
      None => {
        if impact_dep_starts(chars, i, "}}") {
          return Some(i + 2)
        }
        if c == '\'' || c == '"' || c == backtick() {
          quote = Some(c)
        }
      }
    }
    i += 1
  }
  None
}

///|
/// Find an outer template's closing tag using actual tags, not substring
/// search. Nested templates and HTML comments cannot expose fake script blocks.
fn impact_dep_template_end(
  scan : ImpactDepScan,
  chars : Array[Char],
  opening : ImpactDepHtmlTag,
) -> ImpactDepHtmlTag? {
  let stack : Array[String] = [opening.name]
  let void_tags = [
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param",
    "source", "track", "wbr",
  ]
  let mut i = opening.end
  while i < chars.length() {
    if impact_dep_starts(chars, i, "<!--") {
      match vue_find(chars, "-->", i + 4) {
        Some(end) => i = end + 3
        None => return None
      }
      continue
    }
    if impact_dep_starts(chars, i, "{{") {
      match impact_dep_moustache_end(chars, i) {
        Some(end) => i = end
        None => return None
      }
      continue
    }
    if chars[i] != '<' {
      i += 1
      continue
    }
    let tag = match impact_dep_html_tag(chars, i) {
      Some(tag) => tag
      None => {
        i += 1
        continue
      }
    }
    i = tag.end
    if tag.closing {
      if stack.is_empty() || stack[stack.length() - 1] != tag.name {
        let (line, _) = impact_dep_position(chars, tag.start)
        impact_dep_issue(scan, line, "unbalanced Vue template tags")
        return None
      }
      ignore(stack.pop())
      if stack.is_empty() {
        return Some(tag)
      }
    } else if !tag.self_closing && !void_tags.contains(tag.name) {
      if tag.name == "script" || tag.name == "style" {
        let (line, _) = impact_dep_position(chars, tag.start)
        impact_dep_issue(
          scan, line, "script/style inside a Vue template is unsupported",
        )
        match impact_dep_raw_close(chars, tag.end, tag.name) {
          Some(close) => i = close.end
          None => return None
        }
      } else {
        stack.push(tag.name)
      }
    }
  }
  None
}

///|
fn impact_dep_vue_external(
  scan : ImpactDepScan,
  chars : Array[Char],
  tag : ImpactDepHtmlTag,
) -> Unit {
  let (line, column) = impact_dep_position(chars, tag.start)
  if impact_dep_has_attr(tag, ":src") || impact_dep_has_attr(tag, "v-bind:src") {
    impact_dep_issue(scan, line, "dynamic Vue block src is unsupported")
  }
  if !impact_dep_has_attr(tag, "src") {
    return
  }
  let value = impact_dep_attr(tag, "src")
  match value {
    Some(path) if path != "" && !path.contains("&") && !path.contains("\\") =>
      impact_dep_reference(
        scan,
        path,
        if tag.name == "script" {
          "import"
        } else if tag.name == "style" {
          if impact_dep_attr(tag, "lang").unwrap_or("").to_lower() == "scss" ||
            path.has_suffix(".scss") {
            "style-import-scss"
          } else {
            "style-import-css"
          }
        } else {
          "read-file"
        },
        line,
        column,
      )
    _ =>
      impact_dep_issue(scan, line, "unsupported or missing Vue block src value")
  }
  if tag.name == "script" {
    impact_dep_issue(
      scan, line, "external Vue script src requires full fallback",
    )
  } else if tag.name == "template" {
    impact_dep_issue(
      scan, line, "external Vue template is not recursively analyzed",
    )
  }
}

///|
/// Preserve every source coordinate, but expose only actual top-level JS/TS
/// script block bodies to tokenize(). All template prose, HTML comments and
/// custom block text stay blank.
fn impact_dep_vue_code(scan : ImpactDepScan, source : String) -> String {
  let chars = source.to_array()
  let code = chars.map(c => if is_line_break(c) { c } else { ' ' })
  let mut i = 0
  let seen : Set[String] = Set([])
  while i < chars.length() {
    if vue_is_space(chars[i]) || chars[i] == '\u{FEFF}' {
      i += 1
      continue
    }
    // Block and line comments between top-level blocks carry no dependency.
    // Real single-file components open with a file-level /* */ header before
    // the first block, so this text is skipped rather than reported per line.
    if impact_dep_starts(chars, i, "/*") {
      match vue_find(chars, "*/", i + 2) {
        Some(end) => i = end + 2
        None => {
          let (line, _) = impact_dep_position(chars, i)
          impact_dep_issue(scan, line, "unterminated Vue block comment")
          break
        }
      }
      continue
    }
    if impact_dep_starts(chars, i, "//") {
      let mut end = i + 2
      while end < chars.length() && !is_line_break(chars[end]) {
        end += 1
      }
      i = end
      continue
    }
    if impact_dep_starts(chars, i, "<!--") {
      match vue_find(chars, "-->", i + 4) {
        Some(end) => i = end + 3
        None => {
          let (line, _) = impact_dep_position(chars, i)
          impact_dep_issue(scan, line, "unterminated Vue HTML comment")
          break
        }
      }
      continue
    }
    let (line, _) = impact_dep_position(chars, i)
    let tag = match impact_dep_html_tag(chars, i) {
      Some(tag) if !tag.closing => tag
      _ => {
        impact_dep_issue(
          scan, line, "unsupported text or malformed block at Vue top level",
        )
        i += 1
        continue
      }
    }
    if !["script", "template", "style"].contains(tag.name) {
      impact_dep_issue(
        scan,
        line,
        "unsupported Vue top-level block: " + tag.name,
      )
    }
    let block_id = tag.name +
      (if impact_dep_has_attr(tag, "setup") { ":setup" } else { "" })
    if tag.name != "style" && seen.contains(block_id) {
      impact_dep_issue(scan, line, "duplicate Vue top-level block: " + block_id)
    }
    seen.add(block_id)
    impact_dep_vue_external(scan, chars, tag)
    let language = impact_dep_attr(tag, "lang").unwrap_or("").to_lower()
    let script_supported = ["", "js", "ts", "javascript", "typescript"].contains(
      language,
    )
    if tag.name == "script" && !script_supported {
      impact_dep_issue(
        scan,
        line,
        "unsupported Vue script language: " + language,
      )
    }
    if tag.name == "style" && !["", "css", "scss"].contains(language) {
      impact_dep_issue(
        scan,
        line,
        "unsupported Vue stylesheet language: " + language,
      )
    }
    if tag.name == "template" && language != "" && language != "html" {
      impact_dep_issue(
        scan,
        line,
        "unsupported Vue template language: " + language,
      )
    }
    if tag.self_closing {
      i = tag.end
      continue
    }
    let closing_tag = if tag.name == "template" &&
      (language == "" || language == "html") {
      impact_dep_template_end(scan, chars, tag)
    } else {
      impact_dep_raw_close(chars, tag.end, tag.name)
    }
    let close = match closing_tag {
      Some(close) => close
      None => {
        impact_dep_issue(
          scan,
          line,
          "unclosed or unsupported Vue block: " + tag.name,
        )
        break
      }
    }
    if tag.name == "script" &&
      script_supported &&
      !impact_dep_has_attr(tag, "src") {
      for index in tag.end..<close.start {
        code[index] = chars[index]
      }
    }
    if tag.name == "style" &&
      !impact_dep_has_attr(tag, "src") &&
      ["", "css", "scss"].contains(language) {
      let body = String::from_array(chars[tag.end:close.start])
      let (body_line, body_column) = impact_dep_position(chars, tag.end)
      let (style_refs, style_issues) = impact_extract_style_references(
        scan.file,
        body,
        if language == "" {
          "css"
        } else {
          language
        },
        body_line,
        body_column,
      )
      for reference in style_refs {
        impact_dep_reference(
          scan,
          reference.specifier,
          reference.kind,
          reference.line,
          reference.column,
        )
      }
      for issue in style_issues {
        impact_dep_issue(scan, issue.line, issue.reason)
      }
    }
    i = close.end
  }
  String::from_array(code)
}

///|
fn impact_dep_fs_module(source : String) -> Bool {
  ["fs", "node:fs", "fs/promises", "node:fs/promises"].contains(source)
}

///|
fn impact_dep_path_module(source : String) -> Bool {
  source == "path" || source == "node:path"
}

///|
fn impact_dep_other_fs_read(name : String) -> Bool {
  [
    "open", "openSync", "createReadStream", "readlink", "readlinkSync", "realpath",
    "realpathSync",
  ].contains(name)
}

///|
fn impact_dep_fs_dir(name : String) -> Bool {
  name == "readdir" || name == "readdirSync"
}

///|
fn impact_dep_fs_exists(name : String) -> Bool {
  [
    "exists", "existsSync", "stat", "statSync", "lstat", "lstatSync", "access", "accessSync",
  ].contains(name)
}

///|
fn impact_dep_import_role(
  module_name : String,
  imported_name : String,
) -> String? {
  if impact_dep_fs_module(module_name) {
    if imported_name == "*" ||
      imported_name == "default" ||
      imported_name == "promises" {
      return Some("fs-object")
    }
    if imported_name == "readFileSync" || imported_name == "readFile" {
      return Some("fs-read")
    }
    if impact_dep_fs_dir(imported_name) {
      return Some("fs-dir")
    }
    if impact_dep_fs_exists(imported_name) {
      return Some("fs-exists")
    }
    if impact_dep_other_fs_read(imported_name) {
      return Some("fs-unsupported")
    }
  }
  if impact_dep_path_module(module_name) {
    if imported_name == "*" || imported_name == "default" {
      return Some("path-object")
    }
    if imported_name == "join" {
      return Some("path-join")
    }
    if imported_name == "resolve" {
      return Some("path-resolve")
    }
    if imported_name == "dirname" {
      return Some("path-dirname")
    }
  }
  if module_name == "node:url" || module_name == "url" {
    if imported_name == "fileURLToPath" {
      return Some("url-to-path")
    }
    if imported_name == "URL" {
      return Some("url-constructor")
    }
    if imported_name == "*" || imported_name == "default" {
      return Some("url-object")
    }
  }
  None
}

///|
/// Import helpers are invoked at each individual import/re-export token. We
/// intentionally never use parse_source's statement walk, which can skip a
/// dependency after an unfinished/multiline declaration.
fn impact_dep_static_imports(
  scan : ImpactDepScan,
  tokens : Array[Token],
  roles : Map[String, String],
  imported_names : Set[String],
  import_mask : Array[Bool],
) -> Unit {
  for i in 0..<tokens.length() {
    let token = tokens[i]
    if token.kind != Ident || impact_dep_member(tokens, i) || import_mask[i] {
      continue
    }
    let specs : Array[ImportSpec] = []
    let mut end = i + 1
    if token.text == "import" {
      if impact_dep_at(tokens, i + 1, "(") ||
        impact_dep_at(tokens, i + 1, ".") ||
        impact_dep_at(tokens, i + 1, ":") {
        continue
      }
      let spans : Array[(Int32, Int32)] = []
      end = parse_import(tokens, i, specs, spans)
      if specs.is_empty() {
        impact_dep_issue(scan, token.line, "unsupported import declaration")
      }
    } else if token.text == "export" {
      let j = if impact_dep_at(tokens, i + 1, "type") { i + 2 } else { i + 1 }
      if !impact_dep_at(tokens, j, "{") && !impact_dep_at(tokens, j, "*") {
        continue
      }
      let exports : Array[ExportSpec] = []
      let decls : Array[Decl] = []
      end = parse_export(tokens, i, exports, specs, decls, 0)
      if impact_dep_at(tokens, j, "*") && specs.is_empty() {
        impact_dep_issue(
          scan,
          token.line,
          "unsupported export-from declaration",
        )
      }
    } else {
      continue
    }
    for j in i..<end {
      if j < import_mask.length() {
        import_mask[j] = true
      }
    }
    for spec in specs {
      let module_name = match impact_dep_literal(spec.source) {
        Some(value) => value
        None => {
          impact_dep_issue(
            scan,
            token.line,
            "module specifier must be an unescaped string literal",
          )
          continue
        }
      }
      impact_dep_reference(
        scan,
        module_name,
        "import",
        token.line,
        token.column,
      )
      if spec.kind != Static {
        continue
      }
      if i + 2 < tokens.length() && impact_dep_at(tokens, i + 2, "=") {
        impact_dep_issue(
          scan,
          token.line,
          "TypeScript import-equals needs full fallback",
        )
      }
      for name in spec.names {
        if imported_names.contains(name.local) {
          impact_dep_issue(
            scan,
            token.line,
            "ambiguous duplicate import binding: " + name.local,
          )
        }
        imported_names.add(name.local)
        if !spec.type_only {
          match impact_dep_import_role(module_name, name.imported) {
            Some(role) => roles.set(name.local, role)
            None => ()
          }
        }
      }
    }
  }
}

///|
/// Function definitions are kept separately from call sites. Only balanced
/// block bodies can be trusted as configured root-reader implementations.
fn impact_dep_functions(
  tokens : Array[Token],
  mates : Array[Int32],
  import_mask : Array[Bool],
) -> Array[ImpactDepFunction] {
  let functions : Array[ImpactDepFunction] = []
  for i in 0..<tokens.length() {
    if import_mask[i] ||
      tokens[i].kind != Ident ||
      tokens[i].text != "function" ||
      impact_dep_member(tokens, i) {
      continue
    }
    let mut j = i + 1
    if impact_dep_at(tokens, j, "*") {
      j += 1
    }
    let mut name_index = -1
    if j < tokens.length() && tokens[j].kind == Ident {
      name_index = j
      j += 1
    } else if i >= 2 &&
      impact_dep_at(tokens, i - 1, "=") &&
      tokens[i - 2].kind == Ident {
      name_index = i - 2
    }
    if !impact_dep_at(tokens, j, "(") || mates[j] < 0 {
      continue
    }
    let params_close = mates[j]
    let mut body_open = params_close + 1
    // Simple return annotations are harmless; object/function return types
    // remain unsupported, so the balanced body requirement cannot be fooled.
    if impact_dep_at(tokens, body_open, ":") {
      body_open += 1
      while body_open < tokens.length() &&
            (
              tokens[body_open].kind == Ident ||
              [".", "[", "]", "|", "?"].contains(tokens[body_open].text)
            ) {
        body_open += 1
      }
    }
    let body_close = if impact_dep_at(tokens, body_open, "{") {
      mates[body_open]
    } else {
      -1
    }
    functions.push({
      name_index,
      params_open: j,
      params_close,
      body_open,
      body_close,
    })
  }
  functions
}

///|
fn impact_dep_mark_shadow(
  scan : ImpactDepScan,
  tokens : Array[Token],
  index : Int32,
  roles : Map[String, String],
  blocked : Set[String],
) -> Unit {
  if index >= 0 && index < tokens.length() && roles.contains(tokens[index].text) {
    blocked.add(tokens[index].text)
    // A string constant unused by readers should not cause unrelated fallback.
    // Its blocked value becomes an issue if a reader actually depends on it.
    if roles.get(tokens[index].text) != Some("path-constant") {
      impact_dep_issue(
        scan,
        tokens[index].line,
        "shadowed or rebound dependency binding: " + tokens[index].text,
      )
    }
  }
}

///|
fn impact_dep_trusted_functions(
  scan : ImpactDepScan,
  tokens : Array[Token],
  mates : Array[Int32],
  depths : Array[Int32],
  functions : Array[ImpactDepFunction],
  readers : Array[String],
  roles : Map[String, String],
  blocked : Set[String],
  definitions : Set[Int32],
) -> Array[(Int32, Int32)] {
  let trusted : Array[(Int32, Int32)] = []
  let declared : Set[String] = Set([])
  for function in functions {
    let index = function.name_index
    if index >= 0 {
      definitions.add(index)
      let name = tokens[index].text
      if readers.contains(name) &&
        depths[index] == 0 &&
        function.body_close >= 0 &&
        !declared.contains(name) {
        trusted.push((function.body_open, function.body_close + 1))
        declared.add(name)
      } else {
        impact_dep_mark_shadow(scan, tokens, index, roles, blocked)
      }
    }
    for j in (function.params_open + 1)..<function.params_close {
      if tokens[j].kind == Ident {
        impact_dep_mark_shadow(scan, tokens, j, roles, blocked)
      }
    }
  }
  // A configured `const reader = (...) => { ... }` is the same explicit
  // contract. Expression-bodied and destructuring definitions fall back.
  for i in 0..<tokens.length() {
    if tokens[i].kind != Ident ||
      !["const", "let", "var"].contains(tokens[i].text) {
      continue
    }
    let name_index = i + 1
    if name_index >= tokens.length() ||
      !readers.contains(tokens[name_index].text) ||
      depths[i] != 0 ||
      !impact_dep_at(tokens, i + 2, "=") {
      continue
    }
    let mut start = i + 3
    if impact_dep_at(tokens, start, "async") {
      start += 1
    }
    let arrow = if impact_dep_at(tokens, start, "(") && mates[start] >= 0 {
      mates[start] + 1
    } else if start < tokens.length() && tokens[start].kind == Ident {
      start + 1
    } else {
      continue
    }
    if !impact_dep_at(tokens, arrow, "=") ||
      !impact_dep_at(tokens, arrow + 1, ">") ||
      !impact_dep_at(tokens, arrow + 2, "{") ||
      mates[arrow + 2] < 0 {
      continue
    }
    let name = tokens[name_index].text
    if declared.contains(name) {
      impact_dep_mark_shadow(scan, tokens, name_index, roles, blocked)
      continue
    }
    declared.add(name)
    definitions.add(name_index)
    trusted.push((arrow + 2, mates[arrow + 2] + 1))
  }
  trusted
}

///|
fn impact_dep_shadowing(
  scan : ImpactDepScan,
  tokens : Array[Token],
  mates : Array[Int32],
  import_mask : Array[Bool],
  imported_names : Set[String],
  roles : Map[String, String],
  definitions : Set[Int32],
  blocked : Set[String],
) -> Unit {
  if imported_names.contains("require") {
    blocked.add("require")
  }
  if imported_names.contains("process") {
    blocked.add("process")
  }
  for i in 0..<tokens.length() {
    if import_mask[i] {
      continue
    }
    let token = tokens[i]
    if token.kind == Ident &&
      ["const", "let", "var", "class"].contains(token.text) &&
      i + 1 < tokens.length() {
      if tokens[i + 1].kind == Ident {
        if !definitions.contains(i + 1) {
          impact_dep_mark_shadow(scan, tokens, i + 1, roles, blocked)
        }
      } else if (
          impact_dep_at(tokens, i + 1, "{") || impact_dep_at(tokens, i + 1, "[")
        ) &&
        mates[i + 1] >= 0 {
        for j in (i + 2)..<mates[i + 1] {
          if tokens[j].kind == Ident {
            impact_dep_mark_shadow(scan, tokens, j, roles, blocked)
          }
        }
      }
    }
    if token.kind == Ident &&
      !impact_dep_member(tokens, i) &&
      !definitions.contains(i) &&
      impact_dep_at(tokens, i + 1, "=") &&
      !impact_dep_at(tokens, i + 2, "=") &&
      !impact_dep_at(tokens, i + 2, ">") {
      impact_dep_mark_shadow(scan, tokens, i, roles, blocked)
    }
    // Arrow parameter shadowing is intentionally conservative across the
    // whole file; claiming unrelated scopes were proved safe would be worse.
    if token.text == "=" && impact_dep_at(tokens, i + 1, ">") && i > 0 {
      if impact_dep_at(tokens, i - 1, ")") && mates[i - 1] >= 0 {
        for j in (mates[i - 1] + 1)..<(i - 1) {
          if tokens[j].kind == Ident {
            impact_dep_mark_shadow(scan, tokens, j, roles, blocked)
          }
        }
      } else if tokens[i - 1].kind == Ident {
        impact_dep_mark_shadow(scan, tokens, i - 1, roles, blocked)
      }
    }
    if token.kind == Ident &&
      token.text == "catch" &&
      impact_dep_at(tokens, i + 1, "(") &&
      mates[i + 1] >= 0 {
      for j in (i + 2)..<mates[i + 1] {
        impact_dep_mark_shadow(scan, tokens, j, roles, blocked)
      }
    }
  }
}

///|
/// Half-open token spans for each argument, skipping balanced nested groups.
fn impact_dep_arguments(
  tokens : Array[Token],
  mates : Array[Int32],
  opening : Int32,
) -> Array[(Int32, Int32)]? {
  if !impact_dep_at(tokens, opening, "(") || mates[opening] < 0 {
    return None
  }
  let close = mates[opening]
  let args : Array[(Int32, Int32)] = []
  let mut start = opening + 1
  let mut i = start
  while i < close {
    if tokens[i].kind == Punct && tokens[i].text == "," {
      if i == start {
        return None
      }
      args.push((start, i))
      start = i + 1
    } else if mates[i] > i {
      i = mates[i]
    }
    i += 1
  }
  if start < close {
    args.push((start, close))
  }
  Some(args)
}

///|
fn impact_dep_one_string(
  tokens : Array[Token],
  span : (Int32, Int32),
) -> String? {
  let (start, end) = span
  if end != start + 1 || start >= tokens.length() || tokens[start].kind != Str {
    return None
  }
  impact_dep_literal(tokens[start].text)
}

///|
fn impact_dep_method_definition(
  tokens : Array[Token],
  mates : Array[Int32],
  index : Int32,
) -> Bool {
  let opening = index + 1
  if !impact_dep_at(tokens, opening, "(") ||
    mates[opening] < 0 ||
    !impact_dep_at(tokens, mates[opening] + 1, "{") {
    return false
  }
  index > 0 &&
  ["{", ",", ";", "static", "get", "set", "async", "*"].contains(
    tokens[index - 1].text,
  )
}

///|
fn impact_dep_module_calls(
  scan : ImpactDepScan,
  tokens : Array[Token],
  mates : Array[Int32],
  import_mask : Array[Bool],
  definitions : Set[Int32],
  blocked : Set[String],
) -> Unit {
  for i in 0..<tokens.length() {
    let token = tokens[i]
    if token.kind != Ident ||
      import_mask[i] ||
      definitions.contains(i) ||
      impact_dep_member(tokens, i) {
      continue
    }
    if token.text == "import" && impact_dep_at(tokens, i + 1, ".") {
      // import.meta.glob is handled by impact_dep_glob_imports, which turns a
      // literal pattern into a glob-import reference.
      continue
    }
    if token.text != "import" && token.text != "require" {
      continue
    }
    if token.text == "require" && impact_dep_at(tokens, i + 1, ".") {
      if impact_dep_at(tokens, i + 2, "resolve") ||
        impact_dep_at(tokens, i + 2, "context") {
        impact_dep_issue(
          scan,
          token.line,
          "require helper calls are unsupported",
        )
      }
      continue
    }
    if !impact_dep_at(tokens, i + 1, "(") ||
      impact_dep_method_definition(tokens, mates, i) {
      continue
    }
    if token.text == "require" && blocked.contains("require") {
      impact_dep_issue(
        scan,
        token.line,
        "require is locally bound; module loading is ambiguous",
      )
      continue
    }
    let args = match impact_dep_arguments(tokens, mates, i + 1) {
      Some(args) if !args.is_empty() => args
      _ => {
        impact_dep_issue(scan, token.line, "malformed module loader call")
        continue
      }
    }
    match impact_dep_one_string(tokens, args[0]) {
      Some(specifier) => {
        impact_dep_reference(
          scan,
          specifier,
          "import",
          token.line,
          token.column,
        )
        // The module dependency is known, but CommonJS destructuring and
        // reassignment need binding analysis not provided by this MVP.
        if token.text == "require" &&
          (impact_dep_fs_module(specifier) || impact_dep_path_module(specifier)) {
          impact_dep_issue(
            scan,
            token.line,
            "CommonJS fs/path bindings are unsupported; use explicit imports",
          )
        }
      }
      None =>
        impact_dep_issue(
          scan,
          token.line,
          "dynamic or escaped " +
          token.text +
          " specifier requires full fallback",
        )
    }
  }
}

///|
fn impact_dep_cwd(tokens : Array[Token], start : Int32, end : Int32) -> Bool {
  end == start + 5 &&
  impact_dep_at(tokens, start, "process") &&
  impact_dep_at(tokens, start + 1, ".") &&
  impact_dep_at(tokens, start + 2, "cwd") &&
  impact_dep_at(tokens, start + 3, "(") &&
  impact_dep_at(tokens, start + 4, ")")
}

///|
/// End of a simple expression, keeping newline continuations in the span.
/// This is intentionally not a complete ASI parser: unrecognized tails make
/// the evaluator fail rather than treating a literal prefix as the value.
fn impact_read_expression_end(
  tokens : Array[Token],
  mates : Array[Int32],
  start : Int32,
) -> Int32 {
  let mut i = start
  while i < tokens.length() {
    let text = tokens[i].text
    if [";", ",", "}"].contains(text) {
      break
    }
    if i > start &&
      tokens[i].line > tokens[i - 1].line &&
      ![
        ".", "(", "[", "+", "-", "*", "/", "%", "=", "<", ">", "?", "&", "|", "^",
        ":", "as", "satisfies",
      ].contains(text) &&
      ![
        ".", "+", "-", "*", "/", "%", "=", "<", ">", "?", "&", "|", "^", ":", "as",
        "satisfies",
      ].contains(tokens[i - 1].text) {
      break
    }
    if mates[i] > i {
      i = mates[i]
    }
    i += 1
  }
  i
}

///|
fn impact_read_top_level(
  mates : Array[Int32],
  depths : Array[Int32],
  index : Int32,
) -> Bool {
  if depths[index] != 0 {
    return false
  }
  for i in 0..<index {
    if mates[i] > index {
      return false
    }
  }
  true
}

///|
/// Collect only simple top-level const bindings, not let/var or destructuring.
fn impact_read_constants(
  tokens : Array[Token],
  mates : Array[Int32],
  depths : Array[Int32],
  import_mask : Array[Bool],
  blocked : Set[String],
) -> Map[String, ImpactReadConst] {
  let result : Map[String, ImpactReadConst] = Map([])
  for i in 0..<tokens.length() {
    if import_mask[i] ||
      tokens[i].text != "const" ||
      !impact_read_top_level(mates, depths, i) ||
      i + 2 >= tokens.length() ||
      tokens[i + 1].kind != Ident {
      continue
    }
    let mut equals = i + 2
    if impact_dep_at(tokens, equals, ":") {
      equals += 1
      while equals < tokens.length() &&
            (
              tokens[equals].kind == Ident ||
              [".", "[", "]", "|", "?"].contains(tokens[equals].text)
            ) {
        equals += 1
      }
    }
    if !impact_dep_at(tokens, equals, "=") ||
      impact_dep_at(tokens, equals + 1, ">") {
      continue
    }
    let start = equals + 1
    let end = impact_read_expression_end(tokens, mates, start)
    let name = tokens[i + 1].text
    if result.contains(name) {
      blocked.add(name)
    }
    result.set(name, { name_index: i + 1, start, end, })
  }
  result
}

///|
/// Return a real imported callee role and its opening paren, never a name guess.
fn impact_read_callee(
  env : ImpactReadEnv,
  start : Int32,
  end : Int32,
) -> (String, Int32)? {
  let tokens = env.tokens
  if start >= end ||
    tokens[start].kind != Ident ||
    env.blocked.contains(tokens[start].text) {
    return None
  }
  let role = env.roles.get(tokens[start].text).unwrap_or("")
  if impact_dep_at(tokens, start + 1, "(") {
    return Some((role, start + 1))
  }
  if !impact_dep_at(tokens, start + 1, ".") || start + 3 >= end {
    return None
  }
  let mut property_index = start + 2
  if role == "fs-object" &&
    impact_dep_at(tokens, property_index, "promises") &&
    impact_dep_at(tokens, property_index + 1, ".") {
    property_index += 2
  }
  if property_index >= end || !impact_dep_at(tokens, property_index + 1, "(") {
    return None
  }
  let property_name = tokens[property_index].text
  let resolved = if role == "path-object" {
    match property_name {
      "join" => "path-join"
      "resolve" => "path-resolve"
      "dirname" => "path-dirname"
      _ => ""
    }
  } else if role == "fs-object" &&
    ["readFileSync", "readFile"].contains(property_name) {
    "fs-read"
  } else if role == "fs-object" && impact_dep_fs_dir(property_name) {
    "fs-dir"
  } else if role == "fs-object" && impact_dep_fs_exists(property_name) {
    "fs-exists"
  } else if role == "url-object" {
    match property_name {
      "fileURLToPath" => "url-to-path"
      "URL" => "url-constructor"
      _ => ""
    }
  } else {
    ""
  }
  if resolved == "" {
    None
  } else {
    Some((resolved, property_index + 1))
  }
}

///|
fn impact_read_meta_url(
  tokens : Array[Token],
  start : Int32,
  end : Int32,
) -> Bool {
  end == start + 5 &&
  impact_dep_at(tokens, start, "import") &&
  impact_dep_at(tokens, start + 1, ".") &&
  impact_dep_at(tokens, start + 2, "meta") &&
  impact_dep_at(tokens, start + 3, ".") &&
  impact_dep_at(tokens, start + 4, "url")
}

///|
fn impact_read_url_relative(path : String) -> Bool {
  if path == "" {
    return false
  }
  let chars = path.to_array()
  // WHATWG URL parsing trims edge C0/space and drops tabs/newlines. Do not
  // pretend that such a URL has the same filename as the raw input string.
  // NUL is only the internal wrapper-proof hole, never a source literal.
  let first = chars[0].to_int()
  let last = chars[chars.length() - 1].to_int()
  if (first > 0 && first <= 32) ||
    (last > 0 && last <= 32) ||
    path.contains("\t") ||
    path.contains("\r") ||
    path.contains("\n") {
    return false
  }
  !path.has_prefix("/") &&
  !path.contains("\\") &&
  !path.contains("?") &&
  !path.contains("#") &&
  !path.contains("%") &&
  !path.contains(":")
}

///|
fn impact_read_append(left : String, right : String) -> String {
  if left == "" {
    right
  } else if right == "" {
    left
  } else {
    left + "/" + right
  }
}

///|
/// Pure symbolic evaluation. The NUL sentinel exists only during wrapper
/// proof; dependency literals reject NUL, and concrete references never emit it.
fn impact_read_eval(
  env : ImpactReadEnv,
  start : Int32,
  end : Int32,
  parameter : String,
  argument : ImpactReadValue?,
  seen : Array[String],
  limit : Int32,
  depth : Int32,
) -> ImpactReadValue? {
  if start >= end ||
    end > env.tokens.length() ||
    seen.length() > 24 ||
    depth > 32 {
    return None
  }
  let tokens = env.tokens
  if impact_dep_at(tokens, start, "(") && env.mates[start] == end - 1 {
    return impact_read_eval(
      env,
      start + 1,
      end - 1,
      parameter,
      argument,
      seen,
      limit,
      depth + 1,
    )
  }
  match impact_dep_one_string(tokens, (start, end)) {
    Some(path) => return Some({ base: "relative", path, is_url: false, })
    None => ()
  }
  if impact_dep_cwd(tokens, start, end) {
    if env.blocked.contains("process") ||
      env.roles.get("process") != Some("cwd") {
      return None
    }
    return Some({ base: "root", path: "", is_url: false, })
  }
  if impact_read_meta_url(tokens, start, end) {
    if env.blocked.contains("import.meta.url") {
      return None
    }
    let pieces = env.file.split("/").map(part => part.to_owned()).to_array()
    return Some({
      base: "file",
      path: pieces[pieces.length() - 1],
      is_url: true,
    })
  }
  if end == start + 1 && tokens[start].kind == Ident {
    let name = tokens[start].text
    if name == parameter && argument is Some(value) {
      return Some(value)
    }
    if env.blocked.contains(name) {
      return None
    }
    if name == "__dirname" && env.roles.get(name) == Some("file-dir") {
      return Some({ base: "file", path: "", is_url: false, })
    }
    match env.constants.get(name) {
      Some(binding) if binding.name_index < limit && !seen.contains(name) => {
        let visited = seen.copy()
        visited.push(name)
        return impact_read_eval(
          env,
          binding.start,
          binding.end,
          "",
          None,
          visited,
          binding.name_index,
          depth + 1,
        )
      }
      _ => return None
    }
  }
  let construct = impact_dep_at(tokens, start, "new")
  let callee_start = if construct { start + 1 } else { start }
  let (role, opening) = match impact_read_callee(env, callee_start, end) {
    Some(callee) => callee
    None => return None
  }
  if env.mates[opening] != end - 1 {
    return None
  }
  let args = match impact_dep_arguments(tokens, env.mates, opening) {
    Some(args) => args
    None => return None
  }
  if construct {
    if !["url-global", "url-constructor"].contains(role) ||
      args.length() != 2 ||
      env.blocked.contains("import.meta.url") ||
      !impact_read_meta_url(tokens, args[1].0, args[1].1) {
      return None
    }
    let value = match
      impact_read_eval(
        env,
        args[0].0,
        args[0].1,
        parameter,
        argument,
        seen,
        limit,
        depth + 1,
      ) {
      Some(value) => value
      None => return None
    }
    if value.base != "relative" ||
      value.is_url ||
      !impact_read_url_relative(value.path) {
      return None
    }
    return Some({ base: "file", path: value.path, is_url: true, })
  }
  if role == "url-to-path" {
    if args.length() != 1 {
      return None
    }
    let value = match
      impact_read_eval(
        env,
        args[0].0,
        args[0].1,
        parameter,
        argument,
        seen,
        limit,
        depth + 1,
      ) {
      Some(value) if value.is_url => value
      _ => return None
    }
    return Some({ ..value, is_url: false, })
  }
  if role == "path-dirname" {
    if args.length() != 1 {
      return None
    }
    let value = match
      impact_read_eval(
        env,
        args[0].0,
        args[0].1,
        parameter,
        argument,
        seen,
        limit,
        depth + 1,
      ) {
      Some(value) if !value.is_url && !value.path.contains("\u{0}") => value
      _ => return None
    }
    // dirname after resolve/join/URL needs normalization before removing a
    // component. Rather than guess normalization across a symbolic root,
    // refuse dot-segment inputs here. The common dirname(fileURLToPath(
    // import.meta.url)) case has only the known filename and remains exact.
    if value.path.split("/").any(part => part == "." || part == "..") {
      return None
    }
    let parts = value.path
      .split("/")
      .map(part => part.to_owned())
      .filter(part => part != "")
      .to_array()
    let path = if parts.is_empty() {
      if value.base == "relative" {
        "."
      } else {
        ".."
      }
    } else {
      ignore(parts.pop())
      parts.join("/")
    }
    return Some({ ..value, path, })
  }
  if !["path-join", "path-resolve"].contains(role) || args.is_empty() {
    return None
  }
  let mut combined : ImpactReadValue = {
    base: "relative",
    path: "",
    is_url: false,
  }
  for i in 0..<args.length() {
    let value = match
      impact_read_eval(
        env,
        args[i].0,
        args[i].1,
        parameter,
        argument,
        seen,
        limit,
        depth + 1,
      ) {
      Some(value) if !value.is_url => value
      _ => return None
    }
    if value.path.has_prefix("/") || value.path.contains("\\") {
      return None
    }
    if value.base != "relative" {
      if role == "path-join" && i != 0 {
        return None
      }
      combined = value
    } else {
      combined = {
        ..combined,
        path: impact_read_append(combined.path, value.path),
      }
    }
  }
  if role == "path-resolve" && combined.base == "relative" {
    combined = { ..combined, base: "root", }
  }
  Some(combined)
}

///|
/// Validate containment symbolically using the source's known relative path.
/// Ordinary fs strings retain literal ?/#/%; only URL construction rejects them.
/// The kind prefix selects the reference family: "read" for file contents,
/// "read-dir" for a directory's current entries, "exists" for an existence
/// check on a path that may not exist yet.
fn impact_read_emit(
  scan : ImpactDepScan,
  value : ImpactReadValue,
  token : Token,
  kind_prefix : String,
) -> Unit {
  let path = value.path
  let chars = path.to_array()
  let drive = chars.length() >= 2 && chars[1] == ':'
  let mut valid = path != "" &&
    !path.has_prefix("/") &&
    !path.contains("\\") &&
    !path.contains("\u{0}") &&
    !drive
  let parts : Array[String] = []
  if value.base == "file" {
    let owner = scan.file.split("/").map(part => part.to_owned()).to_array()
    if !owner.is_empty() {
      ignore(owner.pop())
    }
    for part in owner {
      parts.push(part)
    }
  }
  for view in path.split("/") {
    let part = view.to_owned()
    if part == ".." {
      if parts.is_empty() {
        valid = false
      } else {
        ignore(parts.pop())
      }
    } else if part != "." && part != "" {
      parts.push(part)
    }
  }
  if !valid || parts.is_empty() {
    impact_dep_issue(
      scan,
      token.line,
      "file path is empty, absolute or escapes the project root",
    )
    return
  }
  let kind = kind_prefix +
    (if value.base == "file" { "-file" } else { "-root" })
  impact_dep_reference(scan, path, kind, token.line, token.column)
}

///|
/// Find the opening paren of a supported FS reader and its effective role, or
/// report a computed/escaping namespace access. Non-reading FS methods are
/// intentionally ignored.
fn impact_dep_fs_call(
  scan : ImpactDepScan,
  tokens : Array[Token],
  index : Int32,
  role : String,
) -> (Int32, String)? {
  let token = tokens[index]
  if role == "fs-read" || role == "fs-dir" || role == "fs-exists" {
    if impact_dep_at(tokens, index + 1, "(") {
      return Some((index + 1, role))
    }
    impact_dep_issue(
      scan,
      token.line,
      "filesystem reader escapes direct-call analysis: " + token.text,
    )
    return None
  }
  if role == "fs-unsupported" {
    if impact_dep_at(tokens, index + 1, "(") {
      impact_dep_issue(
        scan,
        token.line,
        "filesystem reader is unsupported: " + token.text,
      )
      return None
    }
    impact_dep_issue(
      scan,
      token.line,
      "filesystem reader escapes direct-call analysis: " + token.text,
    )
    return None
  }
  if role != "fs-object" {
    return None
  }
  if !impact_dep_at(tokens, index + 1, ".") {
    impact_dep_issue(
      scan,
      token.line,
      "computed or aliased filesystem namespace access",
    )
    return None
  }
  let mut property_index = index + 2
  if impact_dep_at(tokens, property_index, "promises") &&
    impact_dep_at(tokens, property_index + 1, ".") {
    property_index += 2
  }
  if property_index >= tokens.length() {
    return None
  }
  let name = tokens[property_index].text
  let effective = if name == "readFile" || name == "readFileSync" {
    "fs-read"
  } else if impact_dep_fs_dir(name) {
    "fs-dir"
  } else if impact_dep_fs_exists(name) {
    "fs-exists"
  } else {
    ""
  }
  if effective == "" {
    if impact_dep_other_fs_read(name) &&
      impact_dep_at(tokens, property_index + 1, "(") {
      impact_dep_issue(
        scan,
        token.line,
        "filesystem reader is unsupported: " + name,
      )
    }
    return None
  }
  if impact_dep_at(tokens, property_index + 1, "(") {
    return Some((property_index + 1, effective))
  }
  impact_dep_issue(
    scan,
    token.line,
    "filesystem reader is aliased, rebound or called indirectly: " + name,
  )
  None
}

///|
fn impact_read_write(tokens : Array[Token], index : Int32) -> Bool {
  if impact_dep_at(tokens, index, "=") {
    return !impact_dep_at(tokens, index + 1, "=") &&
      !impact_dep_at(tokens, index + 1, ">")
  }
  if index >= tokens.length() {
    return false
  }
  let op = tokens[index].text
  (["+", "-"].contains(op) && impact_dep_at(tokens, index + 1, op)) ||
  (
    ["+", "-", "*", "/", "%", "&", "|", "^", "?", "<", ">"].contains(op) &&
    (
      impact_dep_at(tokens, index + 1, "=") ||
      (
        impact_dep_at(tokens, index + 1, op) &&
        impact_dep_at(tokens, index + 2, "=")
      )
    )
  )
}

///|
/// Check method/global mutation, compound writes and additional lexical binders.
/// Whole-file blocking is intentionally conservative across different scopes.
fn impact_read_extra_shadow(
  scan : ImpactDepScan,
  env : ImpactReadEnv,
  functions : Array[ImpactDepFunction],
  import_mask : Array[Bool],
  allowed : Map[String, Int32],
) -> Unit {
  let tokens = env.tokens
  for function in functions {
    let index = function.name_index
    if index >= 0 && allowed.get(tokens[index].text) != Some(index) {
      impact_dep_mark_shadow(scan, tokens, index, env.roles, env.blocked)
    }
    for i in (function.params_open + 1)..<function.params_close {
      if tokens[i].kind == Ident {
        impact_dep_mark_shadow(scan, tokens, i, env.roles, env.blocked)
      }
    }
  }
  for i in 0..<tokens.length() {
    if import_mask[i] {
      continue
    }
    let token = tokens[i]
    if token.text == "import" &&
      impact_dep_at(tokens, i + 1, ".") &&
      impact_dep_at(tokens, i + 2, "meta") {
      let mutated = impact_dep_at(tokens, i + 3, ".") &&
        impact_dep_at(tokens, i + 4, "url") &&
        impact_read_write(tokens, i + 5)
      if mutated || !impact_dep_at(tokens, i + 3, ".") {
        env.blocked.add("import.meta.url")
        // A cast/read such as (import.meta as any).env does not itself add a
        // file dependency. Keep its base untrusted, but only a real URL/file
        // read that needs the base should force fallback.
        if mutated {
          impact_dep_issue(scan, token.line, "mutated import.meta.url base")
        }
      }
    }
    if token.text == "=" &&
      i > 0 &&
      ["}", "]"].contains(tokens[i - 1].text) &&
      env.mates[i - 1] >= 0 {
      for j in (env.mates[i - 1] + 1)..<(i - 1) {
        if tokens[j].kind == Ident {
          impact_dep_mark_shadow(scan, tokens, j, env.roles, env.blocked)
        }
      }
    }
    // Methods (including constructor parameters) are lexical binders too.
    if token.text == "(" &&
      env.mates[i] > i &&
      i > 0 &&
      !is_keyword(tokens[i - 1].text) &&
      (tokens[i - 1].kind == Ident || tokens[i - 1].text == ">") &&
      impact_dep_at(tokens, env.mates[i] + 1, "{") {
      for j in (i + 1)..<env.mates[i] {
        if tokens[j].kind == Ident {
          impact_dep_mark_shadow(scan, tokens, j, env.roles, env.blocked)
        }
      }
    }
    if token.kind != Ident || impact_dep_member(tokens, i) {
      continue
    }
    if env.roles.contains(token.text) &&
      allowed.get(token.text) != Some(i) &&
      (
        impact_read_write(tokens, i + 1) ||
        (
          i >= 2 &&
          ["+", "-"].contains(tokens[i - 1].text) &&
          tokens[i - 2].text == tokens[i - 1].text
        )
      ) {
      impact_dep_mark_shadow(scan, tokens, i, env.roles, env.blocked)
    }
    let role = env.roles.get(token.text).unwrap_or("")
    if ![
        "fs-object", "path-object", "url-object", "cwd", "url-global", "url-constructor",
        "path-constant",
      ].contains(role) {
      continue
    }
    if token.text == "process" &&
      impact_dep_at(tokens, i + 1, ".") &&
      impact_dep_at(tokens, i + 2, "chdir") &&
      impact_dep_at(tokens, i + 3, "(") {
      env.blocked.add("process")
      impact_dep_issue(
        scan,
        token.line,
        "process.chdir changes the assumed project-root cwd",
      )
    }
    if impact_dep_at(tokens, i + 1, ".") || impact_dep_at(tokens, i + 1, "[") {
      let mut after = i + 1
      while after < tokens.length() {
        if impact_dep_at(tokens, after, ".") &&
          after + 1 < tokens.length() &&
          tokens[after + 1].kind == Ident {
          after += 2
        } else if impact_dep_at(tokens, after, "[") && env.mates[after] > after {
          after = env.mates[after] + 1
        } else {
          break
        }
      }
      if impact_read_write(tokens, after) {
        impact_dep_mark_shadow(scan, tokens, i, env.roles, env.blocked)
        impact_dep_issue(
          scan,
          token.line,
          "mutated path/fs/url or path-value member: " + token.text,
        )
      }
    } else if ["fs-object", "path-object", "url-object"].contains(role) &&
      allowed.get(token.text) != Some(i) {
      env.blocked.add(token.text)
      impact_dep_issue(
        scan,
        token.line,
        "filesystem/path/URL namespace escapes direct analysis: " + token.text,
      )
    }
    if ["globalThis", "global", "window"].contains(token.text) {
      continue
    }
  }
  // Explicit writes through the global object also shadow the implicit names.
  for i in 0..<tokens.length() {
    if !["globalThis", "global", "window"].contains(tokens[i].text) {
      continue
    }
    if impact_dep_at(tokens, i + 1, ".") &&
      i + 2 < tokens.length() &&
      ["URL", "process", "__dirname"].contains(tokens[i + 2].text) {
      let mut end = i + 3
      while impact_dep_at(tokens, end, ".") && end + 1 < tokens.length() {
        end += 2
      }
      if impact_read_write(tokens, end) {
        env.blocked.add(tokens[i + 2].text)
        impact_dep_issue(
          scan,
          tokens[i].line,
          "mutated implicit path global: " + tokens[i + 2].text,
        )
      }
    }
  }
}

///|
fn impact_read_parameter(
  tokens : Array[Token],
  start : Int32,
  end : Int32,
) -> String? {
  if start >= end || tokens[start].kind != Ident {
    return None
  }
  if end == start + 1 {
    return Some(tokens[start].text)
  }
  if end == start + 3 &&
    tokens[start + 1].text == ":" &&
    tokens[start + 2].text == "string" {
    return Some(tokens[start].text)
  }
  None
}

///|
/// Literal encoding options contain no calls, getters, spreads or callbacks.
fn impact_read_options(env : ImpactReadEnv, start : Int32, end : Int32) -> Bool {
  let tokens = env.tokens
  if impact_dep_one_string(tokens, (start, end)) is Some(_) {
    return true
  }
  if end == start + 1 && ["null", "undefined"].contains(tokens[start].text) {
    return tokens[start].text == "null"
  }
  if !impact_dep_at(tokens, start, "{") || env.mates[start] != end - 1 {
    return false
  }
  let mut i = start + 1
  let seen : Set[String] = Set([])
  while i < end - 1 {
    if i + 2 >= end - 1 ||
      !["encoding", "flag"].contains(tokens[i].text) ||
      seen.contains(tokens[i].text) ||
      !impact_dep_at(tokens, i + 1, ":") ||
      impact_dep_one_string(tokens, (i + 2, i + 3)) is None {
      return false
    }
    seen.add(tokens[i].text)
    i += 3
    if i < end - 1 {
      if !impact_dep_at(tokens, i, ",") {
        return false
      }
      i += 1
    }
  }
  true
}

///|
/// Prove one whole return expression rather than just finding a nested read.
fn impact_read_wrapper_expression(
  env : ImpactReadEnv,
  name_index : Int32,
  parameter : String,
  start : Int32,
  end : Int32,
  body_start : Int32,
  body_end : Int32,
) -> ImpactReadWrapper? {
  let mut first = start
  let mut last = end
  while impact_dep_at(env.tokens, first, "(") && env.mates[first] == last - 1 {
    first += 1
    last -= 1
  }
  let (role, opening) = match impact_read_callee(env, first, last) {
    Some(callee) => callee
    None => return None
  }
  if role != "fs-read" || env.mates[opening] != last - 1 {
    return None
  }
  let args = match impact_dep_arguments(env.tokens, env.mates, opening) {
    Some(args) if args.length() >= 1 && args.length() <= 2 => args
    _ => return None
  }
  if args.length() == 2 && !impact_read_options(env, args[1].0, args[1].1) {
    return None
  }
  let hole : ImpactReadValue = {
    base: "relative",
    path: "\u{0}",
    is_url: false,
  }
  let value = match
    impact_read_eval(
      env,
      args[0].0,
      args[0].1,
      parameter,
      Some(hole),
      [],
      env.tokens.length(),
      0,
    ) {
    Some(value) => value
    None => return None
  }
  if value.path.split("\u{0}").to_array().length() != 2 {
    return None
  }
  Some({
    name_index,
    parameter,
    path_start: args[0].0,
    path_end: args[0].1,
    body_start,
    body_end,
  })
}

///|
fn impact_read_wrapper_block(
  env : ImpactReadEnv,
  name_index : Int32,
  parameter : String,
  opening : Int32,
  close : Int32,
) -> ImpactReadWrapper? {
  if opening < 0 ||
    close <= opening + 2 ||
    !impact_dep_at(env.tokens, opening + 1, "return") {
    return None
  }
  let start = opening + 2
  if env.tokens[start].line != env.tokens[opening + 1].line {
    return None
  }
  let end = if impact_dep_at(env.tokens, close - 1, ";") {
    close - 1
  } else {
    close
  }
  impact_read_wrapper_expression(
    env,
    name_index,
    parameter,
    start,
    end,
    opening,
    close + 1,
  )
}

///|
/// Candidate wrappers are not trusted by name. A candidate must have exactly
/// one parameter and a whole single-return FS expression, and cannot be public.
fn impact_read_wrapper_candidates(
  env : ImpactReadEnv,
  functions : Array[ImpactDepFunction],
  depths : Array[Int32],
  imported_names : Set[String],
  readers : Array[String],
) -> Map[String, ImpactReadWrapper] {
  let result : Map[String, ImpactReadWrapper] = Map([])
  let tokens = env.tokens
  for function in functions {
    let index = function.name_index
    if index < 0 ||
      !impact_read_top_level(env.mates, depths, index) ||
      function.body_close < 0 {
      continue
    }
    let name = tokens[index].text
    let mut keyword = index - 1
    let declaration = impact_dep_at(tokens, keyword, "function")
    if declaration && keyword > 0 && tokens[keyword - 1].text == "async" {
      keyword -= 1
    }
    let named_expression = keyword > 0 &&
      ["=", ":", ",", "return", "("].contains(tokens[keyword - 1].text)
    let assigned_anonymous = index > 0 &&
      tokens[index - 1].text == "const" &&
      impact_dep_at(tokens, index + 1, "=") &&
      impact_dep_at(tokens, index + 2, "function")
    if (!declaration || named_expression) && !assigned_anonymous {
      continue
    }
    if imported_names.contains(name) ||
      readers.contains(name) ||
      env.roles.contains(name) {
      continue
    }
    let parameter = match
      impact_read_parameter(
        tokens,
        function.params_open + 1,
        function.params_close,
      ) {
      Some(parameter) => parameter
      None => continue
    }
    match
      impact_read_wrapper_block(
        env,
        index,
        parameter,
        function.body_open,
        function.body_close,
      ) {
      Some(wrapper) => {
        if result.contains(name) {
          env.blocked.add(name)
        }
        result.set(name, wrapper)
      }
      None => ()
    }
  }
  for (name, binding) in env.constants {
    if imported_names.contains(name) ||
      readers.contains(name) ||
      env.roles.contains(name) {
      continue
    }
    let mut start = binding.start
    if impact_dep_at(tokens, start, "async") {
      start += 1
    }
    let (parameter_start, parameter_end, arrow) = if impact_dep_at(
        tokens, start, "(",
      ) &&
      env.mates[start] > start {
      (start + 1, env.mates[start], env.mates[start] + 1)
    } else {
      (start, start + 1, start + 1)
    }
    if !impact_dep_at(tokens, arrow, "=") ||
      !impact_dep_at(tokens, arrow + 1, ">") {
      continue
    }
    let parameter = match
      impact_read_parameter(tokens, parameter_start, parameter_end) {
      Some(parameter) => parameter
      None => continue
    }
    let body = arrow + 2
    let wrapper = if impact_dep_at(tokens, body, "{") &&
      env.mates[body] == binding.end - 1 {
      impact_read_wrapper_block(
        env,
        binding.name_index,
        parameter,
        body,
        env.mates[body],
      )
    } else {
      impact_read_wrapper_expression(
        env,
        binding.name_index,
        parameter,
        body,
        binding.end,
        body,
        binding.end,
      )
    }
    match wrapper {
      Some(wrapper) => {
        if result.contains(name) {
          env.blocked.add(name)
        }
        result.set(name, wrapper)
      }
      None => ()
    }
  }
  result
}

///|
/// An inferred wrapper must stay local and only occur as a direct call. Export,
/// callbacks, field assignment, call/apply/bind and construction are escapes.
fn impact_read_wrapper_escapes(
  scan : ImpactDepScan,
  env : ImpactReadEnv,
  wrappers : Map[String, ImpactReadWrapper],
) -> Unit {
  let tokens = env.tokens
  for (name, wrapper) in wrappers {
    let mut declaration_start = wrapper.name_index
    while declaration_start > 0 &&
          ["function", "const", "async", "default", "export"].contains(
            tokens[declaration_start - 1].text,
          ) {
      declaration_start -= 1
    }
    if impact_dep_at(tokens, declaration_start, "export") {
      env.blocked.add(name)
      impact_dep_issue(
        scan,
        tokens[wrapper.name_index].line,
        "inferred reader is exported; cross-file argument inference is unsupported: " +
        name,
      )
    }
    for i in 0..<tokens.length() {
      if tokens[i].kind != Ident ||
        tokens[i].text != name ||
        i == wrapper.name_index ||
        impact_dep_member(tokens, i) {
        continue
      }
      if !impact_dep_at(tokens, i + 1, "(") ||
        (i > 0 && tokens[i - 1].text == "new") {
        env.blocked.add(name)
        impact_dep_issue(
          scan,
          tokens[i].line,
          "inferred reader escapes direct-call analysis: " + name,
        )
      }
    }
  }
}

///|
/// URL objects are mutable. Unlike immutable string constants, they are only
/// accepted when used directly by a proven reader/converter, never aliased out.
fn impact_read_url_escapes(scan : ImpactDepScan, env : ImpactReadEnv) -> Unit {
  let allowed : Set[Int32] = Set([])
  for i in 0..<env.tokens.length() {
    if env.tokens[i].kind != Ident || impact_dep_member(env.tokens, i) {
      continue
    }
    match impact_read_callee(env, i, env.tokens.length()) {
      Some((role, opening)) if ["fs-read", "url-to-path", "inferred-reader"].contains(
          role,
        ) =>
        match impact_dep_arguments(env.tokens, env.mates, opening) {
          Some(args) if !args.is_empty() && args[0].1 == args[0].0 + 1 =>
            allowed.add(args[0].0)
          _ => ()
        }
      _ => ()
    }
  }
  for (name, binding) in env.constants {
    let value = impact_read_eval(
      env,
      binding.start,
      binding.end,
      "",
      None,
      [name],
      binding.name_index,
      0,
    )
    if value is Some(path) && path.is_url {
      for i in 0..<env.tokens.length() {
        if env.tokens[i].kind == Ident &&
          env.tokens[i].text == name &&
          i != binding.name_index &&
          !impact_dep_member(env.tokens, i) &&
          !allowed.contains(i) {
          env.blocked.add(name)
          impact_dep_issue(
            scan,
            env.tokens[i].line,
            "mutable URL constant escapes proven read/conversion: " + name,
          )
        }
      }
    }
  }
}

///|
fn impact_dep_file_calls(
  scan : ImpactDepScan,
  env : ImpactReadEnv,
  import_mask : Array[Bool],
  definitions : Set[Int32],
  trusted : Array[(Int32, Int32)],
  wrappers : Map[String, ImpactReadWrapper],
) -> Unit {
  let tokens = env.tokens
  let mates = env.mates
  let roles = env.roles
  let blocked = env.blocked
  for i in 0..<tokens.length() {
    let token = tokens[i]
    if token.kind != Ident ||
      import_mask[i] ||
      definitions.contains(i) ||
      impact_dep_member(tokens, i) {
      continue
    }
    let role = roles.get(token.text).unwrap_or("")
    if role != "root-reader" &&
      role != "inferred-reader" &&
      role != "fs-read" &&
      role != "fs-dir" &&
      role != "fs-exists" &&
      role != "fs-object" &&
      role != "fs-unsupported" {
      continue
    }
    if impact_dep_method_definition(tokens, mates, i) {
      continue
    }
    if role != "root-reader" && in_spans(trusted, i) {
      continue
    }
    if blocked.contains(token.text) {
      impact_dep_issue(
        scan,
        token.line,
        "cannot resolve shadowed reader binding: " + token.text,
      )
      continue
    }
    let mut effective = role
    let opening = if role == "root-reader" || role == "inferred-reader" {
      if !impact_dep_at(tokens, i + 1, "(") {
        impact_dep_issue(
          scan,
          token.line,
          "configured file reader must be called directly: " + token.text,
        )
        continue
      }
      i + 1
    } else {
      match impact_dep_fs_call(scan, tokens, i, role) {
        Some((opening, resolved)) => {
          effective = resolved
          opening
        }
        None => continue
      }
    }
    let args = match impact_dep_arguments(tokens, mates, opening) {
      Some(args) if !args.is_empty() => args
      _ => {
        impact_dep_issue(
          scan,
          token.line,
          "file reader requires a supported first argument",
        )
        continue
      }
    }
    let argument = impact_read_eval(
      env,
      args[0].0,
      args[0].1,
      "",
      None,
      [],
      i,
      0,
    )
    let path = if role == "inferred-reader" {
      match (wrappers.get(token.text), argument) {
        (Some(wrapper), Some(value)) if args.length() == 1 =>
          impact_read_eval(
            env,
            wrapper.path_start,
            wrapper.path_end,
            wrapper.parameter,
            Some(value),
            [],
            i,
            0,
          )
        _ => None
      }
    } else if role == "root-reader" {
      match argument {
        Some(value) if value.base == "relative" && !value.is_url => Some(value)
        _ => None
      }
    } else {
      argument
    }
    match path {
      Some(value) =>
        if effective == "fs-dir" {
          impact_read_emit(scan, value, token, "read-dir")
        } else if effective == "fs-exists" {
          impact_read_emit(scan, value, token, "exists")
        } else {
          impact_read_emit(scan, value, token, "read")
        }
      None =>
        impact_dep_issue(
          scan,
          token.line,
          "dynamic, escaped or unsupported file path: " + token.text,
        )
    }
  }
}

///|
/// Extract syntactically proven references. Configured reader names are
/// explicit root-relative contracts, not guessed helper names. The planner
/// owns extension/alias resolution and turns every issue into a full fallback.
fn impact_extract_references(
  rel : String,
  source : String,
  readers : Array[String],
) -> (Array[ImpactReference], Array[ImpactIssue]) {
  let scan : ImpactDepScan = { file: rel, references: [], issues: [], }
  if rel.has_suffix(".jsx") || rel.has_suffix(".tsx") {
    impact_dep_issue(
      scan, 1, "JSX source needs a dedicated frontend; dependency extraction is unsupported",
    )
    return (scan.references, scan.issues)
  }
  let code = if rel.has_suffix(".vue") {
    impact_dep_vue_code(scan, source)
  } else {
    source
  }
  let tokens = tokenize(code)
  let (mates, depths) = impact_dep_groups(scan, tokens)
  let roles : Map[String, String] = Map([])
  roles.set("require", "loader")
  roles.set("process", "cwd")
  roles.set("__dirname", "file-dir")
  roles.set("URL", "url-global")
  for reader in readers {
    roles.set(reader, "root-reader")
  }
  let import_mask = Array::make(tokens.length(), false)
  let imported_names : Set[String] = Set([])
  impact_dep_static_imports(scan, tokens, roles, imported_names, import_mask)
  let functions = impact_dep_functions(tokens, mates, import_mask)
  let blocked : Set[String] = Set([])
  let definitions : Set[Int32] = Set([])
  let trusted = impact_dep_trusted_functions(
    scan, tokens, mates, depths, functions, readers, roles, blocked, definitions,
  )
  if imported_names.contains("__dirname") {
    blocked.add("__dirname")
  }
  if imported_names.contains("URL") &&
    roles.get("URL") != Some("url-constructor") {
    blocked.add("URL")
  }
  let constants = impact_read_constants(
    tokens, mates, depths, import_mask, blocked,
  )
  let env : ImpactReadEnv = {
    file: rel,
    tokens,
    mates,
    roles,
    blocked,
    constants,
  }
  let allowed : Map[String, Int32] = Map([])
  // The explicit reader contract remains separate from automatic inference.
  for function in functions {
    let index = function.name_index
    if index >= 0 &&
      readers.contains(tokens[index].text) &&
      in_spans(trusted, function.body_open) {
      allowed.set(tokens[index].text, index)
    }
  }
  for index in definitions {
    if readers.contains(tokens[index].text) &&
      depths[index] == 0 &&
      !blocked.contains(tokens[index].text) {
      allowed.set(tokens[index].text, index)
    }
  }
  for (name, binding) in constants {
    if blocked.contains(name) {
      continue
    }
    let value = impact_read_eval(
      env,
      binding.start,
      binding.end,
      "",
      None,
      [name],
      binding.name_index,
      0,
    )
    let derived_dirname = name == "__dirname" &&
      !imported_names.contains(name) &&
      value is Some(directory) &&
      directory.base == "file" &&
      directory.path == "" &&
      !directory.is_url
    if roles.contains(name) && !derived_dirname {
      continue
    }
    if value is Some(_) {
      roles.set(name, "path-constant")
      definitions.add(binding.name_index)
      allowed.set(name, binding.name_index)
    }
  }
  let candidates = impact_read_wrapper_candidates(
    env, functions, depths, imported_names, readers,
  )
  for (name, wrapper) in candidates {
    roles.set(name, "inferred-reader")
    definitions.add(wrapper.name_index)
    allowed.set(name, wrapper.name_index)
  }
  impact_dep_shadowing(
    scan, tokens, mates, import_mask, imported_names, roles, definitions, blocked,
  )
  impact_read_extra_shadow(scan, env, functions, import_mask, allowed)
  impact_read_wrapper_escapes(scan, env, candidates)
  impact_read_url_escapes(scan, env)
  let wrappers : Map[String, ImpactReadWrapper] = Map([])
  for (name, wrapper) in candidates {
    if blocked.contains(name) {
      continue
    }
    let hole : ImpactReadValue = {
      base: "relative",
      path: "\u{0}",
      is_url: false,
    }
    if impact_read_eval(
        env,
        wrapper.path_start,
        wrapper.path_end,
        wrapper.parameter,
        Some(hole),
        [],
        tokens.length(),
        0,
      )
      is Some(_) {
      wrappers.set(name, wrapper)
      trusted.push((wrapper.body_start, wrapper.body_end))
    }
  }
  impact_dep_module_calls(
    scan, tokens, mates, import_mask, definitions, blocked,
  )
  impact_dep_glob_imports(scan, tokens, mates, import_mask)
  impact_dep_file_calls(scan, env, import_mask, definitions, trusted, wrappers)
  (scan.references, scan.issues)
}

///|
/// Vite's import.meta.glob('<literal pattern>') statically names a module set.
/// A literal pattern becomes a glob-import reference the planner expands
/// against current membership; a computed pattern stays an uncertainty.
/// The legacy globEager spelling is recognized as the same construct.
fn impact_dep_glob_imports(
  scan : ImpactDepScan,
  tokens : Array[Token],
  mates : Array[Int32],
  import_mask : Array[Bool],
) -> Unit {
  for i in 0..<tokens.length() {
    if import_mask[i] ||
      tokens[i].kind != Ident ||
      tokens[i].text != "import" ||
      !impact_dep_at(tokens, i + 1, ".") ||
      !impact_dep_at(tokens, i + 2, "meta") ||
      !impact_dep_at(tokens, i + 3, ".") ||
      i + 4 >= tokens.length() ||
      tokens[i + 4].kind != Ident ||
      !tokens[i + 4].text.has_prefix("glob") ||
      !impact_dep_at(tokens, i + 5, "(") {
      continue
    }
    let args = match impact_dep_arguments(tokens, mates, i + 5) {
      Some(args) if !args.is_empty() => args
      _ => {
        impact_dep_issue(
          scan,
          tokens[i].line,
          "import.meta.glob requires a pattern argument",
        )
        continue
      }
    }
    match impact_dep_one_string(tokens, (args[0].0, args[0].1)) {
      Some(pattern) if pattern != "" && !pattern.contains("\u{0}") =>
        impact_dep_reference(
          scan,
          pattern,
          "glob-import",
          tokens[i].line,
          tokens[i].column,
        )
      _ =>
        impact_dep_issue(
          scan,
          tokens[i].line,
          "dynamic import.meta.glob pattern requires full fallback",
        )
    }
  }
}
