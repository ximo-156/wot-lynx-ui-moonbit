///|
/// Apply declarative line rules to successfully read source content.
///
/// Each matcher is compiled once per rule (see `MatchKind::prepare`), then
/// reused for every line — compiling per line dominates scan time otherwise.
///
/// Two views of the file are passed in: `lines` is the comment-stripped view
/// (see `comment.mbt`) and `raw_lines` is the file exactly as written. A rule
/// matches against `lines` unless it sets `match_comments`, in which case it
/// sees `raw_lines` — the opt-in a comment-targeting rule needs.
pub fn lint_lines(
  rel : String,
  lines : Array[(Int32, String)],
  raw_lines : Array[(Int32, String)],
  rules : Array[Rule],
) -> Array[Finding] {
  let findings : Array[Finding] = []
  for rule in rules {
    if !rule_applies(rule, rel) {
      continue
    }
    let matcher = rule.match_.prepare()
    let unless = match rule.unless {
      None => None
      Some(unless_) => Some(unless_.prepare())
    }
    let view = if rule.match_comments { raw_lines } else { lines }
    for (lineno, text) in view {
      if matcher.matches(text) {
        let skip = match unless {
          None => false
          Some(prepared) => prepared.matches(text)
        }
        if !skip {
          findings.push({
            rule_id: rule.id,
            severity: rule.severity,
            message: rule.message,
            file: rel,
            line: lineno,
            column: rule.match_.column_of(text),
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
  structural_rules : Array[StructuralRule],
  exts : Array[String],
  scope : Scope,
) -> Result[LintResult, Error] {
  try {
    let absolute = canonical_root(root)
    let files = select_files(Tree, absolute, exts)
    Ok(
      lint_selected(
        absolute,
        Tree,
        files,
        rules,
        file_rules,
        structural_rules,
        scope,
      ),
    )
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
  structural_rules : Array[StructuralRule],
  scope : Scope,
) -> LintResult raise {
  lint_selected(
    canonical_root(root),
    Tree,
    files,
    rules,
    file_rules,
    structural_rules,
    scope,
  )
}

///|
/// `Changed` uses committed HEAD blobs; `Staged` uses actual index blobs.
/// Other modes read regular working-tree files without following links.
///
/// The global `scope` is applied to the candidate list first: candidates it
/// rejects are counted in `files_out_of_scope` and never read. Rule-level
/// scope then decides which rules see each selected file.
///
/// The scan runs in two stages: the per-file stage applies line rules and
/// file rules, then — when structural rules are configured — the sources of
/// every scanned file are parsed and analysed as one project, which is what
/// cross-file checks (unused imports, import cycles, dead exports) need.
pub fn lint_selected(
  root : String,
  mode : ScanMode,
  files : Array[String],
  rules : Array[Rule],
  file_rules : Array[FileRule],
  structural_rules : Array[StructuralRule],
  scope : Scope,
) -> LintResult raise {
  lint_selected_impl(
    root,
    mode,
    files,
    rules,
    file_rules,
    structural_rules,
    scope,
    None,
  ).0
}

///|
/// Cache-aware variant of `lint_selected`. Returns the lint result together
/// with the refreshed cache, which the caller persists. Passing a cache whose
/// fingerprint does not match the effective rule set (or a stale format
/// version) degrades to a full scan — correctness first, speed second.
pub fn lint_selected_cached(
  root : String,
  mode : ScanMode,
  files : Array[String],
  rules : Array[Rule],
  file_rules : Array[FileRule],
  structural_rules : Array[StructuralRule],
  scope : Scope,
  cache : Cache?,
) -> (LintResult, Cache) raise {
  lint_selected_impl(
    root, mode, files, rules, file_rules, structural_rules, scope, cache,
  )
}

///|
/// The scan core, shared by the plain and cache-aware entry points. `cache`
/// is the previous run's cache (or `None`); the returned cache always carries
/// the current fingerprint and one entry per successfully scanned file.
fn lint_selected_impl(
  root : String,
  mode : ScanMode,
  files : Array[String],
  rules : Array[Rule],
  file_rules : Array[FileRule],
  structural_rules : Array[StructuralRule],
  scope : Scope,
  cache : Cache?,
) -> (LintResult, Cache) raise {
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
  // Sources of successfully scanned files, kept for the project pass.
  let project_sources : Array[(String, String)] = []
  let disable_maps : Array[(String, DisableMap)] = []
  // The cache is only reusable when the effective rule set is unchanged.
  let fingerprint = config_fingerprint(
    rules, file_rules, structural_rules, scope,
  )
  let reusable : Cache? = match cache {
    Some(previous) =>
      if previous.is_current(fingerprint) {
        Some(previous)
      } else {
        None
      }
    None => None
  }
  let updated = Cache::new(fingerprint)
  let mut scanned = 0
  let mut skipped = 0
  let mut failed = 0
  for rel in selected {
    // No applicable rule is intentionally skipped; it is not a successful read.
    if !rules.any(rule => rule_applies(rule, rel)) &&
      !file_rules.any(fr => file_rule_applies(fr, rel)) &&
      !structural_rules.any(sr => sr.applies_to(rel)) {
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
      let hash = content_hash(source)
      // A cache hit means identical content under an identical rule set, so
      // the previous findings are still exactly right: reuse them instead of
      // re-running the matchers. The source is still needed for the project
      // pass when structural rules are configured.
      let cached : CacheEntry? = match reusable {
        Some(previous) =>
          match previous.get(rel) {
            Some(entry) => if entry.hash == hash { Some(entry) } else { None }
            None => None
          }
        None => None
      }
      match cached {
        Some(entry) => {
          for finding in entry.findings {
            findings.push(finding)
          }
          if !structural_rules.is_empty() {
            project_sources.push((rel, source))
            disable_maps.push((rel, parse_disable_comments(source)))
          }
          updated.put(rel, hash, entry.findings)
          scanned += 1
          continue
        }
        None => ()
      }
      let disable_map = parse_disable_comments(source)
      let raw_lines = split_lines(source)
      let lines = split_lines(strip_comments(source, comment_mode_for(rel)))
      // Per-file findings are collected separately so they can be stored in
      // the cache; the project pass appends its own afterwards.
      let file_findings : Array[Finding] = []
      for finding in lint_lines(rel, lines, raw_lines, rules) {
        if !disable_map.is_disabled(finding.rule_id, finding.line) {
          file_findings.push(finding)
        }
      }
      for finding in lint_file(rel, source, raw_lines, file_rules) {
        // Whole-file checks (BOM, line ending, size, empty file, naming) are
        // properties of the file, not of a line: a `// moonlint-disable` on
        // line 1 must not be able to mask them. Only per-line file checks
        // (trailing whitespace, tabs, max_line_length) are suppressible.
        let per_line = is_per_line_check(finding.rule_id, file_rules)
        if !per_line || !disable_map.is_disabled(finding.rule_id, finding.line) {
          file_findings.push(finding)
        }
      }
      for finding in file_findings {
        findings.push(finding)
      }
      updated.put(rel, hash, file_findings)
      if !structural_rules.is_empty() {
        project_sources.push((rel, source))
        disable_maps.push((rel, disable_map))
      }
      scanned += 1
    } catch {
      error => {
        failed += 1
        diagnostics.push({ file: rel, message: error_message(error), })
      }
    }
  }
  // Project pass: one index over every scanned file, then every structural
  // rule. Findings honour inline disables like per-file findings do.
  if !structural_rules.is_empty() {
    // The JS/TS index does not need to parse MoonBit files; handing them to
    // the JS parser would only produce empty models. MoonBit rules get the
    // raw sources and their own declaration scanner.
    let js_sources = project_sources.filter(pair => {
      let (rel, _) = pair
      !rel.has_suffix(".mbt")
    })
    let index = build_index(js_sources)
    let structural_findings = analyze(index, structural_rules)
    for finding in analyze_moonbit(project_sources, structural_rules) {
      structural_findings.push(finding)
    }
    for finding in structural_findings {
      let suppressed = disable_maps.any(pair => {
        let (rel, map) = pair
        rel == finding.file && map.is_disabled(finding.rule_id, finding.line)
      })
      if !suppressed {
        findings.push(finding)
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
  let result : LintResult = {
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
  (result, updated)
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
/// Public view of `file_rule_applies`, so the CLI's `--fix` path honours the
/// same extension and include/exclude scope as the scan.
pub fn FileRule::applies_to(self : FileRule, rel : String) -> Bool {
  file_rule_applies(self, rel)
}

///|
/// Whether a structural (project-level) rule applies to a given path.
pub fn StructuralRule::applies_to(self : StructuralRule, rel : String) -> Bool {
  file_rule_applies(
    {
      id: self.id,
      severity: self.severity,
      message: self.message,
      extensions: self.extensions,
      check: NoEmptyFiles,
      scope: self.scope,
    },
    rel,
  )
}

///|
/// Whether a file check reports per offending line (and so may be silenced by
/// an inline `moonlint-disable` for that line), as opposed to describing a
/// whole-file property.
fn is_per_line_check(rule_id : String, file_rules : Array[FileRule]) -> Bool {
  for fr in file_rules {
    if fr.id == rule_id {
      return match fr.check {
        MaxLineLength(_) | NoTrailingWhitespace | NoTabs => true
        _ => false
      }
    }
  }
  false
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
              file_finding_at(
                fr,
                rel,
                lineno,
                "line has \{text.length()} characters (limit: \{limit})",
                text.trim().to_owned(),
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
        let seen : Set[String] = Set([])
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
      MaxFileSize(limit) => {
        let size = source.length()
        if size > limit {
          findings.push(
            file_finding(fr, rel, 1, "file is \{size} bytes (limit: \{limit})"),
          )
        }
      }
      NoEmptyFiles =>
        if source.trim().to_owned() == "" {
          findings.push(file_finding(fr, rel, 1, "file is empty"))
        }
      LineEnding(style) => {
        let has_crlf = source.contains("\r\n")
        let has_lf_only = source.contains("\n") && !source.contains("\r\n")
        match style {
          Lf =>
            if has_crlf {
              findings.push(
                file_finding(
                  fr, rel, 1, "file uses CRLF line endings; expected LF",
                ),
              )
            }
          Crlf =>
            if has_lf_only {
              findings.push(
                file_finding(
                  fr, rel, 1, "file uses LF line endings; expected CRLF",
                ),
              )
            }
        }
      }
      NoBom =>
        if source.length() >= 3 && source[0] == '\u{FEFF}' {
          findings.push(
            file_finding(fr, rel, 1, "file starts with a UTF-8 BOM"),
          )
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
  file_finding_at(fr, file, line, detail, detail)
}

///|
/// A file-level finding with an explicit snippet. Per-line checks
/// (`max_line_length`, trailing whitespace, tabs) pass the offending source
/// line; whole-file properties pass the detail sentence instead.
fn file_finding_at(
  fr : FileRule,
  file : String,
  line : Int32,
  detail : String,
  snippet : String,
) -> Finding {
  {
    rule_id: fr.id,
    severity: fr.severity,
    message: "\{fr.message} (\{detail})",
    file,
    line,
    // Whole-file checks describe a property of the file, not a position on
    // one line, so they report the first column.
    column: 1,
    snippet,
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
