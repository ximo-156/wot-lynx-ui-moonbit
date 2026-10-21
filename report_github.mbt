///|
/// GitHub Actions workflow-command annotations.
///
/// Findings become `::error` / `::warning` annotations, files that could not
/// be read become `::error` annotations without a line, skipped files become
/// `::notice` annotations, and the run ends with a `::notice` summary carrying
/// the read / failure / skip counters.
///
/// Workflow command values are escaped as GitHub requires: `%`, `\r` and `\n`
/// in any value, plus `:` and `,` inside property values.
///
/// File paths are relative to the scan root. Run moonlint from the repository
/// root so the annotations link to the right files.

///|
pub fn render_github(result : LintResult) -> String {
  let lines : Array[String] = []
  for f in result.findings {
    lines.push(
      "::\{f.severity.tag()} file=\{escape_property(f.file)},line=\{f.line},col=1,title=\{escape_property(f.rule_id)}::\{escape_data(f.message)}",
    )
  }
  for d in result.diagnostics {
    lines.push(
      "::error file=\{escape_property(d.file)},title=moonlint/scan-failed::\{escape_data(d.message)}",
    )
  }
  for s in result.skipped_files {
    lines.push(
      "::notice file=\{escape_property(s.file)},title=moonlint/skipped::\{escape_data(s.reason)}",
    )
  }
  lines.push("::notice title=moonlint::\{escape_data(github_summary(result))}")
  lines.join("\n")
}

///|
fn github_summary(result : LintResult) -> String {
  let errors = result.count_by(Severity::error())
  let warnings = result.count_by(Severity::warning())
  "files selected: \{result.files_selected}, scanned: \{result.files_scanned}, skipped: \{result.files_skipped}, failed: \{result.files_failed}, out of scope: \{result.files_out_of_scope}, errors: \{errors}, warnings: \{warnings}, baseline-suppressed: \{result.baseline_hits}"
}

///|
/// Escape a workflow command message: `%`, carriage return and line feed.
/// A lone `\r` must be replaced too, or the runner reads the remainder as a
/// separate line and misinterprets it as a command.
fn escape_data(text : String) -> String {
  let out = StringBuilder::new()
  for c in text.iter() {
    match c {
      '%' => out.write_string("%25")
      '\r' => out.write_string("%0D")
      '\n' => out.write_string("%0A")
      _ => out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// Escape a workflow command property value: message escapes plus `:` and `,`.
fn escape_property(text : String) -> String {
  let out = StringBuilder::new()
  for c in text.iter() {
    match c {
      '%' => out.write_string("%25")
      '\r' => out.write_string("%0D")
      '\n' => out.write_string("%0A")
      ':' => out.write_string("%3A")
      ',' => out.write_string("%2C")
      _ => out.write_char(c)
    }
  }
  out.to_string()
}
