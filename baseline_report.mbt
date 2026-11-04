///|
/// Add unsuppressed source findings to an explicit exception-audit report.
/// File/line facts are retained as details, with no synthetic source locations.
pub fn baseline_audit_with_findings(audit : PolicyReport, result : LintResult) -> PolicyReport {
  let issues = audit.issues.copy()
  for finding in result.findings {
    issues.push({ rule_id: "baseline/unbaselined", severity: finding.severity,
      message: "\{finding.file}:\{finding.line}: \{finding.rule_id} — \{finding.message}",
      details: Map([("file", finding.file), ("line", finding.line.to_string()),
        ("column", finding.column.to_string()), ("rule_id", finding.rule_id), ("snippet", finding.snippet)]) })
  }
  let counts : Map[String, Int32] = Map([])
  for (key, value) in audit.counts { counts.set(key, value) }
  counts.set("unsuppressed", result.findings.length())
  let metadata : Map[String, String] = Map([])
  for (key, value) in audit.metadata { metadata.set(key, value) }
  metadata.set("source_snapshot", result.source_snapshot.unwrap_or("working-tree"))
  { mode: audit.mode, metadata, counts, issues }
}
