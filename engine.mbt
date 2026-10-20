///|
/// The lint engine: apply a set of rules to a source tree.
///
/// `lint_tree` walks the directory, reads each matching file, and tests every
/// line against every applicable rule. A finding is emitted when a rule's
/// `match` fires and its optional `unless` guard does not.

///|
/// Lint a single file's content against the rules. `rel` is the path used in
/// findings; `lines` are the comment-stripped `(lineno, text)` pairs.
pub fn lint_lines(
  rel : String,
  lines : Array[(Int32, String)],
  rules : Array[Rule],
) -> Array[Finding] {
  let findings : Array[Finding] = []
  for rule in rules {
    for (lineno, text) in lines {
      if not(rule_applies(rule, rel)) {
        continue
      }
      if rule.match_.matches(text) {
        // Negative guard: skip when `unless` also matches.
        let skip = match rule.unless {
          None => false
          Some(u) => u.matches(text)
        }
        if not(skip) {
          findings.push({
            rule_id: rule.id,
            severity: rule.severity,
            message: rule.message,
            file: rel,
            line: lineno,
            snippet: text.trim_space().to_owned(),
          })
        }
      }
    }
  }
  findings
}

///|
/// Whether a rule applies to a file, based on its extension list. An empty
/// extension list means the rule applies to every scanned file.
fn rule_applies(rule : Rule, rel : String) -> Bool {
  if rule.extensions.length() == 0 {
    return true
  }
  match rel.rev_split_once(".") {
    None => false
    Some((_, ext)) => {
      let ext_lower = ext.to_owned().to_lower()
      // Rule extensions may be written with or without a leading dot.
      rule.extensions.any(e => {
        let normalized = if e.starts_with(".") {
          e.substring(start=1).to_lower()
        } else {
          e.to_lower()
        }
        normalized == ext_lower
      })
    }
  }
}

///|
/// Lint an entire directory tree.
///
/// `root` is the directory to scan; `rules` the rule set; `exts` the file
/// extensions to consider (union of all rule extensions is a good default).
/// Findings are returned sorted by file then line for stable output.
pub fn lint_tree(
  root : String,
  rules : Array[Rule],
  exts : Array[String],
) -> Result[LintResult, Error] {
  let files = walk_files(root, exts) catch {
    _ => return Err(Failure("cannot scan directory"))
  }
  let findings : Array[Finding] = []
  for rel in files {
    let full = join_root(root, rel)
    let lines = read_lines(full)
    let file_findings = lint_lines(rel, lines, rules)
    for f in file_findings {
      findings.push(f)
    }
  }
  findings.sort_by((a, b) => {
    let c = a.file.compare(b.file)
    if c != 0 {
      c
    } else {
      a.line.compare(b.line)
    }
  })
  Ok({ findings, files_scanned: files.length(), baseline_hits: 0, })
}

///|
/// Lint a specific list of files.
///
/// Unlike `lint_tree`, this does not walk the directory — the caller
/// provides the exact file list (e.g. from git diff, glob, or stdin).
/// `root` is used to resolve relative paths to absolute paths for reading.
pub fn lint_files(
  root : String,
  files : Array[String],
  rules : Array[Rule],
) -> LintResult {
  let findings : Array[Finding] = []
  let mut scanned = 0
  for rel in files {
    let full = join_root(root, rel)
    let lines = read_lines(full)
    scanned += 1
    let file_findings = lint_lines(rel, lines, rules)
    for f in file_findings {
      findings.push(f)
    }
  }
  findings.sort_by((a, b) => {
    let c = a.file.compare(b.file)
    if c != 0 {
      c
    } else {
      a.line.compare(b.line)
    }
  })
  { findings, files_scanned: scanned, baseline_hits: 0, }
}

///|
/// Join the scan root with a relative path.
fn join_root(root : String, rel : String) -> String {
  if root.has_suffix("/") {
    "\{root}\{rel}"
  } else {
    "\{root}/\{rel}"
  }
}
