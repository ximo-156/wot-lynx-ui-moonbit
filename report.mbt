///|
/// Report rendering.
///
/// Two output shapes:
/// - `render_detail` — one line per finding, grouped for human reading.
/// - `render_summary` — a compact per-rule tally plus totals.

///|
/// Render findings as a human-readable detail listing.
pub fn render_detail(findings : Array[Finding]) -> String {
  if findings.length() == 0 {
    return "No findings."
  }
  let lines : Array[String] = []
  for f in findings {
    lines.push(
      "\{f.file}:\{f.line}: [\{f.severity.tag()}] \{f.rule_id} — \{f.message}",
    )
    lines.push("    \{f.snippet}")
  }
  lines.join("\n")
}

///|
/// Render a per-rule summary tally.
pub fn render_summary(result : LintResult) -> String {
  let lines : Array[String] = []
  // Tally by rule id.
  let by_rule : Map[String, Int32] = Map::new()
  for f in result.findings {
    let cur = by_rule.get(f.rule_id).unwrap_or(0)
    by_rule.set(f.rule_id, cur + 1)
  }
  lines.push("rule | count")
  lines.push("--- | ---")
  // Stable order: sort rule ids.
  let ids : Array[String] = by_rule.keys().to_array()
  ids.sort()
  for id in ids {
    let count = by_rule.get(id).unwrap_or(0)
    lines.push("\{id} | \{count}")
  }
  let errors = result.count_by(Severity::Error)
  let warnings = result.count_by(Severity::Warning)
  lines.push("")
  lines.push(
    "files selected: \{result.files_selected}  files scanned: \{result.files_scanned}  skipped: \{result.files_skipped}  failed: \{result.files_failed}  errors: \{errors}  warnings: \{warnings}  baseline-suppressed: \{result.baseline_hits}",
  )
  lines.join("\n")
}
