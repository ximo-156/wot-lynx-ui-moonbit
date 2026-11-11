///|
fn impact_json_strings(values : Array[String]) -> Json {
  Json::array(values.map(value => Json::string(value)))
}

///|
fn impact_edge_json(edge : ImpactEdge) -> Json {
  Json::object({
    "dependency": Json::string(edge.dependency),
    "dependent": Json::string(edge.dependent),
    "kind": Json::string(edge.kind),
    "line": Json::number(edge.line.to_double()),
    "column": Json::number(edge.column.to_double()),
  })
}

///|
/// Render a versioned advisory plan. This schema deliberately contains no
/// passing-test verdict: it records selection and evidence, not execution.
pub fn render_impact_json(plan : ImpactPlan) -> String {
  let traces = plan.traces.map(trace => {
    Json::object({
      "test": Json::string(trace.test_file),
      "changed": Json::string(trace.changed),
      "chain": Json::array(trace.chain.map(impact_edge_json)),
    })
  })
  let issues = plan.issues.map(issue => {
    Json::object({
      "file": Json::string(issue.file),
      "line": Json::number(issue.line.to_double()),
      "reason": Json::string(issue.reason),
    })
  })
  Json::object({
    "tool": Json::string("moonimpact"),
    "version": Json::number(1.0),
    "kind": Json::string("test-plan"),
    "advisory": Json::boolean(true),
    "root": Json::string(plan.root),
    "input": Json::string(plan.input),
    "source_snapshot": Json::string("live-working-tree"),
    "strategy": Json::string(plan.strategy),
    "changed": impact_json_strings(plan.changed),
    "tests": impact_json_strings(plan.tests),
    "inventory": impact_json_strings(plan.inventory),
    "affected": impact_json_strings(plan.affected),
    "traces": Json::array(traces),
    "reasons": impact_json_strings(plan.reasons),
    "issues": Json::array(issues),
    "counts": Json::object({
      "changed": Json::number(plan.changed.length().to_double()),
      "sources": Json::number(plan.source_count.to_double()),
      "edges": Json::number(plan.edge_count.to_double()),
      "inventory": Json::number(plan.inventory.length().to_double()),
      "selected_tests": Json::number(plan.tests.length().to_double()),
      "known_affected": Json::number(plan.affected.length().to_double()),
      "issues": Json::number(plan.issues.length().to_double()),
    }),
    "limitations": impact_json_strings([
      "Selection uses supported static dependencies and explicit configuration, not complete language semantics.",
      "No test success is established by this plan; --run executes trusted project code using the local Vitest installation.",
      "Git input describes changes; analyzed sources are a live working tree, not an atomic repository snapshot.",
      "Full fallback requests all tests from Vitest; the runner may discover additional tests beyond this inventory.",
    ]),
  }).stringify(indent=2)
}

///|
/// Quote text to keep control characters in filenames out of terminal output.
fn impact_quote(value : String) -> String {
  Json::string(value).stringify()
}

///|
/// Human-readable selection with one shortest known witness per related test.
pub fn render_impact_text(plan : ImpactPlan) -> String {
  let lines : Array[String] = [
    "MoonImpact — advisory test plan",
    "root: " + impact_quote(plan.root),
    "input: " + impact_quote(plan.input),
    "strategy: " + plan.strategy,
    "changed: \{plan.changed.length()}  sources: \{plan.source_count}  edges: \{plan.edge_count}",
    "test inventory: \{plan.inventory.length()}  selected: \{plan.tests.length()}  uncertainties: \{plan.issues.length()}",
    "This is a plan, not a passing test result. Tests run only with --run.",
  ]
  if plan.strategy == "full" {
    lines.push(
      "Full fallback: request the runner's full suite; known chains below are not a coverage guarantee.",
    )
  }
  if !plan.reasons.is_empty() {
    lines.push("")
    lines.push("Reasons:")
    for reason in plan.reasons {
      lines.push("  - " + impact_quote(reason))
    }
  }
  if !plan.tests.is_empty() {
    lines.push("")
    lines.push("Selected test files:")
    for path in plan.tests {
      lines.push("  " + impact_quote(path))
    }
  }
  if !plan.traces.is_empty() {
    lines.push("")
    lines.push("Known dependency evidence:")
    for trace in plan.traces {
      lines.push(
        "  " +
        impact_quote(trace.changed) +
        " => " +
        impact_quote(trace.test_file),
      )
      if trace.chain.is_empty() {
        lines.push("    directly changed test")
      }
      for edge in trace.chain {
        lines.push(
          "    " +
          impact_quote(edge.dependency) +
          " -> " +
          impact_quote(edge.dependent) +
          " [\{edge.kind}; reference at \{edge.line}:\{edge.column}]",
        )
      }
    }
  }
  if !plan.issues.is_empty() {
    lines.push("")
    lines.push("Uncertainties / blocked inputs:")
    for issue in plan.issues {
      lines.push(
        "  " +
        impact_quote(issue.file) +
        ":\{issue.line} " +
        impact_quote(issue.reason),
      )
    }
  }
  lines.join("\n")
}

///|
fn impact_html_escape(text : String) -> String {
  let out = StringBuilder()
  for c in text {
    match c {
      '&' => out.write_string("&amp;")
      '<' => out.write_string("&lt;")
      '>' => out.write_string("&gt;")
      '"' => out.write_string("&quot;")
      '\'' => out.write_string("&#39;")
      _ => out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// Generate a standalone, script-free HTML report. All project-controlled
/// strings are escaped; the report fetches no external assets or scripts.
pub fn render_impact_html(plan : ImpactPlan) -> String {
  let out = StringBuilder()
  out.write_string(
    (
      #|<!doctype html>
      #|<html lang="en"><head><meta charset="utf-8">
      #|<meta name="viewport" content="width=device-width, initial-scale=1">
      #|<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
      #|<title>MoonImpact — Test plan</title>
      #|<style>
      #|body{margin:0;background:#f4f6fa;color:#172033;font:15px/1.6 system-ui,sans-serif}
      #|main{max-width:1080px;margin:40px auto;padding:0 24px 64px}h1{font-size:38px;margin:0}h2{margin:0 0 16px;font-size:20px}
      #|small{color:#546176}.tag{display:inline-block;padding:4px 12px;border-radius:20px;background:#dfe8ff;color:#244788;font-weight:650}
      #|section{background:white;border:1px solid #dee3ed;border-radius:14px;margin-top:24px;padding:24px}
      #|.stats{display:flex;gap:32px;flex-wrap:wrap;margin-top:22px}.stats strong{display:block;font-size:28px}.notice{border-left:4px solid #d79225;padding-left:16px}
      #|code,pre{font:13px/1.7 ui-monospace,SFMono-Regular,monospace;overflow-wrap:anywhere;white-space:pre-wrap}
      #|table{width:100%;border-collapse:collapse;text-align:left;table-layout:fixed}td,th{padding:10px;border-bottom:1px solid #e5e9f2;overflow-wrap:anywhere;vertical-align:top}
      #|li{margin:6px 0}.muted{color:#627087}details{padding:12px 0;border-bottom:1px solid #e5e9f2}summary{cursor:pointer}
      #|</style></head><body><main><small>CHANGE IMPACT / VUE + TYPESCRIPT</small><h1>MoonImpact</h1>
      #|<p class="notice">Advisory selection, not a passing test result. Unsupported dependencies trigger a full-suite fallback.</p>
    ),
  )
  out.write_string(
    "<p><span class=\"tag\">" +
    impact_html_escape(plan.strategy) +
    "</span></p>",
  )
  out.write_string(
    "<p><strong>Root:</strong> <code>" +
    impact_html_escape(plan.root) +
    "</code><br>",
  )
  out.write_string(
    "<strong>Input:</strong> <code>" +
    impact_html_escape(plan.input) +
    "</code></p>",
  )
  out.write_string(
    "<div class=\"stats\"><div><strong>\{plan.changed.length()}</strong>Changes</div><div><strong>\{plan.tests.length()} / \{plan.inventory.length()}</strong>Selected / inventoried tests</div><div><strong>\{plan.edge_count}</strong>Known dependency edges</div><div><strong>\{plan.issues.length()}</strong>Uncertainties</div></div>",
  )
  out.write_string("<section><h2>Selection reasons</h2><ul>")
  for reason in plan.reasons {
    out.write_string("<li>" + impact_html_escape(reason) + "</li>")
  }
  if plan.reasons.is_empty() {
    out.write_string(
      "<li>Related tests were found using the known dependency graph.</li>",
    )
  }
  out.write_string(
    "</ul><p class=\"muted\">The live working tree is not an atomic Git snapshot. Full fallback runs Vitest's full suite, which may include files outside this inventory.</p></section>",
  )
  out.write_string("<section><h2>Selected tests</h2><ul>")
  for path in plan.tests {
    out.write_string("<li><code>" + impact_html_escape(path) + "</code></li>")
  }
  if plan.tests.is_empty() {
    out.write_string(
      "<li>No test execution is selected. Review the strategy and reasons above.</li>",
    )
  }
  out.write_string("</ul></section><section><h2>Known evidence chains</h2>")
  for trace in plan.traces {
    out.write_string(
      "<details open><summary><code>" +
      impact_html_escape(trace.test_file) +
      "</code></summary><p>Change: <code>" +
      impact_html_escape(trace.changed) +
      "</code></p><ul>",
    )
    if trace.chain.is_empty() {
      out.write_string("<li>The test file itself changed.</li>")
    }
    for edge in trace.chain {
      out.write_string(
        "<li><code>" +
        impact_html_escape(edge.dependency) +
        " → " +
        impact_html_escape(edge.dependent) +
        "</code><br><small>" +
        impact_html_escape(edge.kind) +
        " · reference \{edge.line}:\{edge.column}</small></li>",
      )
    }
    out.write_string("</ul></details>")
  }
  out.write_string(
    "</section><section><h2>Uncertainties / blocked inputs</h2><table><thead><tr><th>File / line</th><th>Reason</th></tr></thead><tbody>",
  )
  for issue in plan.issues {
    out.write_string(
      "<tr><td><code>" +
      impact_html_escape(issue.file) +
      ":\{issue.line}</code></td><td>" +
      impact_html_escape(issue.reason) +
      "</td></tr>",
    )
  }
  out.write_string(
    "</tbody></table></section><p class=\"muted\">MoonImpact MVP · supported static module and file-input dependencies only · no test success asserted</p></main></body></html>\n",
  )
  out.to_string()
}
