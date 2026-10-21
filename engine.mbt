///|
/// Apply declarative line rules to successfully read source content.
pub fn lint_lines(
  rel : String,
  lines : Array[(Int32, String)],
  rules : Array[Rule],
) -> Array[Finding] {
  let findings : Array[Finding] = []
  for rule in rules {
    if !rule_applies(rule, rel) {
      continue
    }
    for (lineno, text) in lines {
      if rule.match_.matches(text) {
        let skip = match rule.unless {
          None => false
          Some(unless_) => unless_.matches(text)
        }
        if !skip {
          findings.push({
            rule_id: rule.id,
            severity: rule.severity,
            message: rule.message,
            file: rel,
            line: lineno,
            snippet: text.trim().to_owned(),
          })
        }
      }
    }
  }
  findings
}

///|
fn rule_applies(rule : Rule, rel : String) -> Bool {
  has_wanted_ext(
    rel,
    Set::from_iter(rule.extensions.iter().map(e => e.to_lower())),
  ) &&
  rule.scope.allows(rel)
}

///|
pub fn lint_tree(
  root : String,
  rules : Array[Rule],
  file_rules : Array[FileRule],
  exts : Array[String],
  scope : Scope,
) -> Result[LintResult, Error] {
  try {
    let absolute = canonical_root(root)
    let files = select_files(Tree, absolute, exts)
    Ok(lint_selected(absolute, Tree, files, rules, file_rules, scope))
  } catch {
    error => Err(error)
  }
}

///|
/// Lint explicit working-tree paths. Paths are validated and deduplicated;
/// unreadable/missing files produce diagnostics instead of successful counters.
pub fn lint_files(
  root : String,
  files : Array[String],
  rules : Array[Rule],
  file_rules : Array[FileRule],
  scope : Scope,
) -> LintResult raise {
  lint_selected(canonical_root(root), Tree, files, rules, file_rules, scope)
}

///|
/// `Changed` uses committed HEAD blobs; `Staged` uses actual index blobs.
/// Other modes read regular working-tree files without following links.
///
/// The global `scope` is applied to the candidate list first: candidates it
/// rejects are counted in `files_out_of_scope` and never read. Rule-level
/// scope then decides which rules see each selected file.
pub fn lint_selected(
  root : String,
  mode : ScanMode,
  files : Array[String],
  rules : Array[Rule],
  file_rules : Array[FileRule],
  scope : Scope,
) -> LintResult raise {
  let candidates : Array[String] = []
  let seen : Set[String] = Set::from_iter([].iter())
  for file in files {
    let rel = normalize_relative(file)
    if !seen.contains(rel) {
      candidates.push(rel)
      seen.add(rel)
    }
  }
  candidates.sort()
  let selected = candidates.filter(rel => scope.allows(rel))
  let out_of_scope = candidates.length() - selected.length()
  let findings : Array[Finding] = []
  let diagnostics : Array[Diagnostic] = []
  let skipped_files : Array[SkippedFile] = []
  let mut scanned = 0
  let mut skipped = 0
  let mut failed = 0
  for rel in selected {
    // No applicable rule is intentionally skipped; it is not a successful read.
    if !rules.any(rule => rule_applies(rule, rel)) &&
      !file_rules.any(fr => file_rule_applies(fr, rel)) {
      skipped += 1
      skipped_files.push({ file: rel, reason: "no-applicable-rule", })
      continue
    }
    try {
      let kind = match mode {
        Changed(_) => git_source_kind(root, rel, false)
        Staged => git_source_kind(root, rel, true)
        _ => rooted_source_kind(root, rel)
      }
      if kind == 3 {
        skipped += 1
        skipped_files.push({ file: rel, reason: "not-a-regular-file", })
        continue
      }
      if kind != 1 {
        raise Failure("source is missing or is not a regular file")
      }
      let source = match mode {
        Changed(_) => git_blob(root, rel, false)
        Staged => git_blob(root, rel, true)
        _ => read_source(join_path(root, rel))
      }
      if source.contains("\x00") {
        raise Failure("binary source contains NUL bytes")
      }
      let lines = split_lines(strip_comments(source))
      for finding in lint_lines(rel, lines, rules) {
        findings.push(finding)
      }
      for finding in lint_file(rel, source, lines, file_rules) {
        findings.push(finding)
      }
      scanned += 1
    } catch {
      error => {
        failed += 1
        diagnostics.push({ file: rel, message: error_message(error), })
      }
    }
  }
  findings.sort_by((a, b) => {
    let file_order = a.file.compare(b.file)
    if file_order != 0 {
      file_order
    } else {
      let line_order = a.line.compare(b.line)
      if line_order != 0 {
        line_order
      } else {
        a.rule_id.compare(b.rule_id)
      }
    }
  })
  {
    findings,
    files_selected: selected.length(),
    files_scanned: scanned,
    files_skipped: skipped,
    files_failed: failed,
    files_out_of_scope: out_of_scope,
    baseline_hits: 0,
    diagnostics,
    skipped_files,
  }
}

///|
/// Human-readable operational errors with their useful context retained.
pub fn error_message(error : Error) -> String {
  match error {
    Failure(message) => message
    @fs.IOError(message) => message
    NativeError(message) => message
    ConfigError(message) => message
    _ => "scan operation failed"
  }
}

///|
/// Whether a file rule applies to a given path.
fn file_rule_applies(fr : FileRule, rel : String) -> Bool {
  has_wanted_ext(
    rel,
    Set::from_iter(fr.extensions.iter().map(e => e.to_lower())),
  ) &&
  fr.scope.allows(rel)
}

///|
/// Evaluate file-level rules against a file's content. Each finding points to
/// the specific line where the violation occurs (or line 1 for file-level
/// properties like naming).
pub fn lint_file(
  rel : String,
  source : String,
  lines : Array[(Int32, String)],
  file_rules : Array[FileRule],
) -> Array[Finding] {
  let findings : Array[Finding] = []
  for fr in file_rules {
    if !file_rule_applies(fr, rel) {
      continue
    }
    match fr.check {
      MaxLines(limit) =>
        if lines.length() > limit {
          findings.push(
            file_finding(
              fr,
              rel,
              lines.length(),
              "file has \{lines.length()} lines (limit: \{limit})",
            ),
          )
        }
      MaxLineLength(limit) =>
        for (lineno, text) in lines {
          if text.length() > limit {
            findings.push(
              file_finding(
                fr,
                rel,
                lineno,
                "line has \{text.length()} characters (limit: \{limit})",
              ),
            )
          }
        }
      NoTrailingWhitespace =>
        for (lineno, text) in lines {
          if text.length() > 0 && text.has_suffix(" ") {
            findings.push(file_finding(fr, rel, lineno, "trailing whitespace"))
          } else if text.length() > 0 && text.has_suffix("\t") {
            findings.push(file_finding(fr, rel, lineno, "trailing whitespace"))
          }
        }
      NoTabs =>
        for (lineno, text) in lines {
          if text.contains("\t") {
            findings.push(file_finding(fr, rel, lineno, "tab character found"))
          }
        }
      FinalNewline =>
        if source.length() > 0 && !source.has_suffix("\n") {
          findings.push(
            file_finding(
              fr,
              rel,
              lines.length(),
              "file does not end with a newline",
            ),
          )
        }
      NoDuplicateLines => {
        let seen : Set[String] = Set::new()
        for (lineno, text) in lines {
          let trimmed = text.trim().to_owned()
          if trimmed != "" {
            if seen.contains(trimmed) {
              findings.push(
                file_finding(fr, rel, lineno, "duplicate line: \{trimmed}"),
              )
            } else {
              seen.add(trimmed)
            }
          }
        }
      }
      FileNaming(style) => {
        let name = file_stem(rel)
        if !naming_matches(style, name) {
          findings.push(
            file_finding(
              fr,
              rel,
              1,
              "file name \"\{name}\" does not match \{naming_style_name(style)} convention",
            ),
          )
        }
      }
    }
  }
  findings
}

///|
/// Build a finding for a file-level rule.
fn file_finding(
  fr : FileRule,
  file : String,
  line : Int32,
  detail : String,
) -> Finding {
  {
    rule_id: fr.id,
    severity: fr.severity,
    message: "\{fr.message} (\{detail})",
    file,
    line,
    snippet: detail,
  }
}

///|
/// Extract the file name without extension from a relative path.
fn file_stem(rel : String) -> String {
  let name = match rel.rev_split_once("/") {
    Some((_, n)) => n.to_owned()
    None => rel
  }
  match name.rev_split_once(".") {
    Some((stem, _)) => stem.to_owned()
    None => name
  }
}

///|
/// Whether a file name matches the given naming convention.
fn naming_matches(style : NamingStyle, name : String) -> Bool {
  if name == "" {
    return false
  }
  match style {
    CamelCase =>
      // First char lowercase, no underscores or hyphens
      name[0] >= 'a' &&
      name[0] <= 'z' &&
      !name.contains("_") &&
      !name.contains("-")
    PascalCase =>
      // First char uppercase, no underscores or hyphens
      name[0] >= 'A' &&
      name[0] <= 'Z' &&
      !name.contains("_") &&
      !name.contains("-")
    SnakeCase =>
      // All lowercase with underscores, no hyphens
      !name.contains("-") &&
      name
      .iter()
      .all(c => (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')
    KebabCase =>
      // All lowercase with hyphens, no underscores
      !name.contains("_") &&
      name
      .iter()
      .all(c => (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')
  }
}

///|
/// Human-readable name for a naming style.
fn naming_style_name(style : NamingStyle) -> String {
  match style {
    CamelCase => "camelCase"
    PascalCase => "PascalCase"
    SnakeCase => "snake_case"
    KebabCase => "kebab-case"
  }
}
