///|
/// Machine-readable JSON report.
///
/// The document is versioned (`"version": 1`) and has four top-level keys:
///
/// - `scan` — how the run was configured (mode, root, extension filter) and
///   the read / failure / skip metadata: `files_selected`, `files_scanned`,
///   `files_skipped`, `files_failed`, `files_out_of_scope`,
///   `baseline_suppressed` and a `skipped_files` list with per-file reasons.
/// - `counts` — finding totals per severity.
/// - `findings` — every reported violation, sorted by file then line.
/// - `diagnostics` — files that could not be read, with the reason.
///
/// Rendering never raises: a report is always produced from a completed scan.

///|
pub fn render_json(result : LintResult, scan : ScanInfo) -> String {
  let root : Map[String, Json] = Map([])
  root.set("tool", Json::string("moonlint"))
  root.set("version", Json::number(1.0))
  root.set("scan", scan_json(result, scan))
  root.set("counts", counts_json(result))
  root.set("findings", findings_json(result.findings))
  root.set("diagnostics", diagnostics_json(result.diagnostics))
  Json::object(root).stringify(indent=2)
}

///|
fn scan_json(result : LintResult, scan : ScanInfo) -> Json {
  let obj : Map[String, Json] = Map([])
  obj.set("mode", Json::string(scan.mode))
  obj.set("root", Json::string(scan.root))
  obj.set("extensions", strings_json(scan.extensions))
  obj.set("files_selected", number_json(result.files_selected))
  obj.set("files_scanned", number_json(result.files_scanned))
  obj.set("files_skipped", number_json(result.files_skipped))
  obj.set("files_failed", number_json(result.files_failed))
  obj.set("files_out_of_scope", number_json(result.files_out_of_scope))
  obj.set("baseline_suppressed", number_json(result.baseline_hits))
  obj.set("skipped_files", skipped_json(result.skipped_files))
  Json::object(obj)
}

///|
fn counts_json(result : LintResult) -> Json {
  let obj : Map[String, Json] = Map([])
  obj.set("findings", number_json(result.findings.length()))
  obj.set("errors", number_json(result.count_by(Severity::error())))
  obj.set("warnings", number_json(result.count_by(Severity::warning())))
  Json::object(obj)
}

///|
fn findings_json(findings : Array[Finding]) -> Json {
  let items : Array[Json] = []
  for f in findings {
    let obj : Map[String, Json] = Map([])
    obj.set("rule_id", Json::string(f.rule_id))
    obj.set("severity", Json::string(f.severity.tag()))
    obj.set("message", Json::string(f.message))
    obj.set("file", Json::string(f.file))
    obj.set("line", number_json(f.line))
    // Rules match whole lines, so every finding starts at the first column.
    obj.set("column", Json::number(1.0))
    obj.set("snippet", Json::string(f.snippet))
    items.push(Json::object(obj))
  }
  Json::array(items)
}

///|
fn diagnostics_json(diagnostics : Array[Diagnostic]) -> Json {
  let items : Array[Json] = []
  for d in diagnostics {
    let obj : Map[String, Json] = Map([])
    obj.set("file", Json::string(d.file))
    obj.set("message", Json::string(d.message))
    items.push(Json::object(obj))
  }
  Json::array(items)
}

///|
fn skipped_json(skipped : Array[SkippedFile]) -> Json {
  let items : Array[Json] = []
  for s in skipped {
    let obj : Map[String, Json] = Map([])
    obj.set("file", Json::string(s.file))
    obj.set("reason", Json::string(s.reason))
    items.push(Json::object(obj))
  }
  Json::array(items)
}

///|
fn strings_json(values : Array[String]) -> Json {
  Json::array(values.map(v => Json::string(v)))
}

///|
/// Render an integer count as a JSON number without a fractional part.
fn number_json(value : Int32) -> Json {
  Json::number(value.to_double())
}
