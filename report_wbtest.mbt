///|
/// Tests for the JSON report and GitHub annotation renderers.

///|
fn report_finding(line : Int32) -> Finding {
  report_finding_in("src/app.ts", Severity::error(), line)
}

///|
fn report_finding_in(
  file : String,
  severity : Severity,
  line : Int32,
) -> Finding {
  {
    rule_id: "test/rule",
    severity,
    message: "forbidden token",
    file,
    line,
    column: 1,
    snippet: "FORBIDDEN",
  }
}

///|
fn report_result() -> LintResult {
  {
    findings: [report_finding(3)],
    files_selected: 4,
    files_scanned: 2,
    files_skipped: 1,
    files_failed: 1,
    files_out_of_scope: 5,
    baseline_hits: 0,
    diagnostics: [
      { file: "src/broken.ts", message: "source is not valid UTF-8", },
    ],
    skipped_files: [{ file: "src/no-rule.md", reason: "no-applicable-rule", }],
  }
}

///|
fn scan_info() -> ScanInfo {
  ScanInfo::new("tree", "/work/repo", [".ts"])
}

///|
test "json report carries scan read, failure and skip metadata" {
  let text = render_json(report_result(), scan_info())
  let json = @json.parse(text)
  let scan = json.value("scan").unwrap()
  assert_eq(scan.value("mode").unwrap().as_string().unwrap(), "tree")
  assert_eq(scan.value("root").unwrap().as_string().unwrap(), "/work/repo")
  assert_eq(scan.value("files_selected").unwrap().as_number().unwrap(), 4.0)
  assert_eq(scan.value("files_scanned").unwrap().as_number().unwrap(), 2.0)
  assert_eq(scan.value("files_skipped").unwrap().as_number().unwrap(), 1.0)
  assert_eq(scan.value("files_failed").unwrap().as_number().unwrap(), 1.0)
  assert_eq(scan.value("files_out_of_scope").unwrap().as_number().unwrap(), 5.0)
  assert_eq(
    scan.value("baseline_suppressed").unwrap().as_number().unwrap(),
    0.0,
  )
}

///|
test "json report lists skipped files with reasons" {
  let json = @json.parse(render_json(report_result(), scan_info()))
  let skipped = json
    .value("scan")
    .unwrap()
    .value("skipped_files")
    .unwrap()
    .as_array()
    .unwrap()
  assert_eq(skipped.length(), 1)
  assert_eq(
    skipped[0].value("file").unwrap().as_string().unwrap(),
    "src/no-rule.md",
  )
  assert_eq(
    skipped[0].value("reason").unwrap().as_string().unwrap(),
    "no-applicable-rule",
  )
}

///|
test "json report lists findings and diagnostics" {
  let json = @json.parse(render_json(report_result(), scan_info()))
  let findings = json.value("findings").unwrap().as_array().unwrap()
  assert_eq(findings.length(), 1)
  assert_eq(
    findings[0].value("rule_id").unwrap().as_string().unwrap(),
    "test/rule",
  )
  assert_eq(
    findings[0].value("severity").unwrap().as_string().unwrap(),
    "error",
  )
  assert_eq(
    findings[0].value("file").unwrap().as_string().unwrap(),
    "src/app.ts",
  )
  assert_eq(findings[0].value("line").unwrap().as_number().unwrap(), 3.0)
  assert_eq(findings[0].value("column").unwrap().as_number().unwrap(), 1.0)
  let diagnostics = json.value("diagnostics").unwrap().as_array().unwrap()
  assert_eq(diagnostics.length(), 1)
  assert_eq(
    diagnostics[0].value("file").unwrap().as_string().unwrap(),
    "src/broken.ts",
  )
}

///|
test "json report counts findings by severity" {
  let json = @json.parse(render_json(report_result(), scan_info()))
  let counts = json.value("counts").unwrap()
  assert_eq(counts.value("findings").unwrap().as_number().unwrap(), 1.0)
  assert_eq(counts.value("errors").unwrap().as_number().unwrap(), 1.0)
  assert_eq(counts.value("warnings").unwrap().as_number().unwrap(), 0.0)
}

///|
test "json report escapes special characters" {
  let result : LintResult = {
    findings: [
      {
        rule_id: "test/quote",
        severity: Severity::warning(),
        message: "he said \"stop\"\nnow",
        file: "src/a b.ts",
        line: 1,
        column: 1,
        snippet: "tab\there",
      },
    ],
    files_selected: 1,
    files_scanned: 1,
    files_skipped: 0,
    files_failed: 0,
    files_out_of_scope: 0,
    baseline_hits: 0,
    diagnostics: [],
    skipped_files: [],
  }
  let reparsed = @json.parse(render_json(result, scan_info()))
  let finding = reparsed.value("findings").unwrap().as_array().unwrap()[0]
  assert_eq(
    finding.value("message").unwrap().as_string().unwrap(),
    "he said \"stop\"\nnow",
  )
  assert_eq(finding.value("file").unwrap().as_string().unwrap(), "src/a b.ts")
}

///|
test "github annotations use workflow command syntax" {
  let text = render_github(report_result())
  let lines = text.split("\n").to_array()
  assert_eq(
    lines[0],
    "::error file=src/app.ts,line=3,col=1,title=test/rule::forbidden token",
  )
  assert_true(
    lines[1].contains("::error file=src/broken.ts,title=moonlint/scan-failed::"),
  )
  assert_true(lines[lines.length() - 1].has_prefix("::notice title=moonlint::"))
}

///|
test "github annotations escape property and message values" {
  let result : LintResult = {
    findings: [
      {
        rule_id: "a,b:c",
        severity: Severity::warning(),
        message: "100% broken\r\nline",
        file: "src/a,b:c.ts",
        line: 7,
        column: 1,
        snippet: "x",
      },
    ],
    files_selected: 1,
    files_scanned: 1,
    files_skipped: 0,
    files_failed: 0,
    files_out_of_scope: 0,
    baseline_hits: 0,
    diagnostics: [],
    skipped_files: [],
  }
  let text = render_github(result)
  assert_true(text.contains("title=a%2Cb%3Ac"))
  assert_true(text.contains("file=src/a%2Cb%3Ac.ts"))
  assert_true(text.contains("::100%25 broken%0D%0Aline"))
}

///|
test "github annotations annotate skipped files with their reason" {
  let text = render_github(report_result())
  assert_true(
    text.contains(
      "::notice file=src/no-rule.md,title=moonlint/skipped::no-applicable-rule",
    ),
  )
}

///|
test "github annotations keep one line per finding and end with a summary" {
  let text = render_github(report_result())
  let lines = text.split("\n").to_array()
  // one finding, one failure, one skip, one summary
  assert_eq(lines.length(), 4)
  assert_true(lines[3].contains("files selected: 4"))
  assert_true(lines[3].contains("scanned: 2"))
  assert_true(lines[3].contains("skipped: 1"))
  assert_true(lines[3].contains("failed: 1"))
  assert_true(lines[3].contains("out of scope: 5"))
}

///|
test "github annotations use warning severity for warning findings" {
  let result : LintResult = {
    findings: [report_finding_in("src/app.ts", Severity::warning(), 9)],
    files_selected: 1,
    files_scanned: 1,
    files_skipped: 0,
    files_failed: 0,
    files_out_of_scope: 0,
    baseline_hits: 0,
    diagnostics: [],
    skipped_files: [],
  }
  assert_true(
    render_github(result).has_prefix("::warning file=src/app.ts,line=9,col=1"),
  )
}

///|
test "json report is parseable and round-trips every counter" {
  let result = report_result()
  let json = @json.parse(render_json(result, scan_info()))
  let scan = json.value("scan").unwrap()
  assert_eq(scan.value("extensions").unwrap().as_array().unwrap().length(), 1)
  assert_eq(
    scan.value("baseline_suppressed").unwrap().as_number().unwrap(),
    result.baseline_hits.to_double(),
  )
  assert_eq(
    scan.value("files_out_of_scope").unwrap().as_number().unwrap(),
    result.files_out_of_scope.to_double(),
  )
  // The document declares its own version and tool identity.
  assert_eq(json.value("tool").unwrap().as_string().unwrap(), "moonlint")
  assert_eq(json.value("version").unwrap().as_number().unwrap(), 1.0)
}

///|
test "json report escapes control characters in file names" {
  let result : LintResult = {
    findings: [report_finding_in("odd\nname\t.ts", Severity::error(), 1)],
    files_selected: 1,
    files_scanned: 1,
    files_skipped: 0,
    files_failed: 0,
    files_out_of_scope: 0,
    baseline_hits: 0,
    diagnostics: [],
    skipped_files: [],
  }
  let reparsed = @json.parse(render_json(result, scan_info()))
  let file = reparsed.value("findings").unwrap().as_array().unwrap()[0]
    .value("file")
    .unwrap()
  assert_eq(file.as_string().unwrap(), "odd\nname\t.ts")
}

///|
test "summary rendering reports scope and skip counters" {
  let text = render_summary(report_result())
  assert_true(text.contains("files selected: 4"))
  assert_true(text.contains("skipped: 1"))
  assert_true(text.contains("failed: 1"))
  assert_true(text.contains("test/rule | 1"))
}
