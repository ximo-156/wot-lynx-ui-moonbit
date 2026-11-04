///|
/// Project policy JSON reports keep package/symbol identities in details,
/// rather than pretending compiler graph edges have source-file locations.
pub fn render_policy_json(report : PolicyReport) -> String {
  let obj : Map[String, Json] = Map([])
  obj.set("tool", Json::string("moonlint"))
  obj.set("version", number_json(1))
  obj.set("mode", Json::string(report.mode))
  let metadata : Map[String, Json] = Map([])
  for (key, value) in report.metadata { metadata.set(key, Json::string(value)) }
  obj.set("metadata", Json::object(metadata))
  let counts : Map[String, Json] = Map([])
  for (key, value) in report.counts { counts.set(key, number_json(value)) }
  counts.set("findings", number_json(report.issues.length()))
  counts.set("errors", number_json(report.issues.count_if(i => i.severity == Severity::Error)))
  counts.set("warnings", number_json(report.issues.count_if(i => i.severity == Severity::Warning)))
  obj.set("counts", Json::object(counts))
  let findings : Array[Json] = []
  for issue in report.issues {
    let item : Map[String, Json] = Map([])
    item.set("rule_id", Json::string(issue.rule_id))
    item.set("severity", Json::string(issue.severity.tag()))
    item.set("message", Json::string(issue.message))
    let details : Map[String, Json] = Map([])
    for (key, value) in issue.details { details.set(key, Json::string(value)) }
    item.set("details", Json::object(details))
    findings.push(Json::object(item))
  }
  obj.set("findings", Json::array(findings))
  Json::object(obj).stringify(indent=2)
}

///|
/// Human-readable policy results, including explicit coverage/applicability.
pub fn render_policy_text(report : PolicyReport, summary~ : Bool = false) -> String {
  let lines : Array[String] = ["moonlint: \{report.mode}"]
  let keys = report.metadata.keys().to_array()
  keys.sort()
  for key in keys { lines.push("\{key}: \{report.metadata.get(key).unwrap_or("")}") }
  for issue in report.issues {
    lines.push("[\{issue.severity.tag()}] \{issue.rule_id} — \{issue.message}")
    if !summary {
      let detail_keys = issue.details.keys().to_array()
      detail_keys.sort()
      for key in detail_keys { lines.push("  \{key}: \{issue.details.get(key).unwrap_or("")}") }
    }
  }
  let counts = report.counts.keys().to_array()
  counts.sort()
  for key in counts { lines.push("\{key}: \{report.counts.get(key).unwrap_or(0)}") }
  lines.push("errors: \{report.issues.count_if(i => i.severity == Severity::Error)}  warnings: \{report.issues.count_if(i => i.severity == Severity::Warning)}")
  lines.join("\n")
}

///|
/// Workflow annotations without guessed file/line properties.
pub fn render_policy_github(report : PolicyReport) -> String {
  let lines : Array[String] = []
  for issue in report.issues {
    lines.push("::\{issue.severity.tag()} title=\{escape_property(issue.rule_id)}::\{escape_data(issue.message)}")
  }
  lines.push("::notice title=moonlint::\{escape_data(render_policy_text(report, summary=true))}")
  lines.join("\n")
}

///|
/// SARIF 2.1.0 project diagnostics. Snapshot/graph identities are properties;
/// locations are absent because no source ranges were supplied by the input.
pub fn render_policy_sarif(report : PolicyReport) -> String {
  let driver : Map[String, Json] = Map([])
  driver.set("name", Json::string("moonlint"))
  driver.set("informationUri", Json::string("https://github.com/ximo-156/wot-lynx-ui-moonbit"))
  let tool : Map[String, Json] = Map([])
  tool.set("driver", Json::object(driver))
  let results : Array[Json] = []
  for issue in report.issues {
    let item : Map[String, Json] = Map([])
    item.set("ruleId", Json::string(issue.rule_id))
    item.set("level", Json::string(issue.severity.tag()))
    let message : Map[String, Json] = Map([])
    message.set("text", Json::string(issue.message))
    item.set("message", Json::object(message))
    let properties : Map[String, Json] = Map([])
    for (key, value) in issue.details { properties.set(key, Json::string(value)) }
    item.set("properties", Json::object(properties))
    results.push(Json::object(item))
  }
  let run : Map[String, Json] = Map([])
  run.set("tool", Json::object(tool))
  run.set("results", Json::array(results))
  let properties : Map[String, Json] = Map([])
  properties.set("mode", Json::string(report.mode))
  for (key, value) in report.metadata { properties.set(key, Json::string(value)) }
  run.set("properties", Json::object(properties))
  let obj : Map[String, Json] = Map([])
  obj.set("version", Json::string("2.1.0"))
  obj.set("$schema", Json::string("https://json.schemastore.org/sarif-2.1.0.json"))
  obj.set("runs", Json::array([Json::object(run)]))
  Json::object(obj).stringify(indent=2)
}
