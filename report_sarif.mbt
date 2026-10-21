///|
/// SARIF (Static Analysis Results Interchange Format) 2.1.0 report.
///
/// SARIF is the standard format for static analysis tools, supported by
/// GitHub code scanning, VS Code, and most CI platforms.
///
/// See: https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html

///|
/// Render a SARIF 2.1.0 document from a lint result.
pub fn render_sarif(result : LintResult, scan : ScanInfo) -> String {
  let root : Map[String, Json] = Map([])
  root.set("version", Json::string("2.1.0"))
  root.set(
    "$schema",
    Json::string(
      "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json",
    ),
  )
  root.set("runs", Json::array([run_json(result, scan)]))
  Json::object(root).stringify(indent=2)
}

///|
/// Build the `runs` array entry.
fn run_json(result : LintResult, scan : ScanInfo) -> Json {
  let obj : Map[String, Json] = Map([])
  let tool : Map[String, Json] = Map([])
  let driver : Map[String, Json] = Map([])
  driver.set("name", Json::string("moonlint"))
  driver.set("version", Json::string("0.1.0"))
  driver.set(
    "informationUri",
    Json::string("https://github.com/ximo-156/wot-lynx-ui-moonbit"),
  )
  // Collect unique rule ids
  let rule_ids : Array[String] = []
  let seen : Set[String] = Set::new()
  for f in result.findings {
    if !seen.contains(f.rule_id) {
      seen.add(f.rule_id)
      rule_ids.push(f.rule_id)
    }
  }
  rule_ids.sort()
  let rules : Array[Json] = []
  for id in rule_ids {
    let rule_obj : Map[String, Json] = Map([])
    rule_obj.set("id", Json::string(id))
    rule_obj.set("name", Json::string(id))
    rules.push(Json::object(rule_obj))
  }
  driver.set("rules", Json::array(rules))
  tool.set("driver", Json::object(driver))
  obj.set("tool", Json::object(tool))
  obj.set("results", results_json(result))
  Json::object(obj)
}

///|
/// Build the `results` array.
fn results_json(result : LintResult) -> Json {
  let items : Array[Json] = []
  for f in result.findings {
    let obj : Map[String, Json] = Map([])
    obj.set("ruleId", Json::string(f.rule_id))
    obj.set("level", Json::string(sarif_level(f.severity)))
    let message : Map[String, Json] = Map([])
    message.set("text", Json::string(f.message))
    obj.set("message", Json::object(message))
    let location : Map[String, Json] = Map([])
    let physical : Map[String, Json] = Map([])
    let artifact : Map[String, Json] = Map([])
    artifact.set("uri", Json::string(f.file))
    physical.set("artifactLocation", Json::object(artifact))
    let region : Map[String, Json] = Map([])
    region.set("startLine", Json::number(f.line.to_double()))
    region.set("startColumn", Json::number(1.0))
    physical.set("region", Json::object(region))
    location.set("physicalLocation", Json::object(physical))
    obj.set("locations", Json::array([Json::object(location)]))
    items.push(Json::object(obj))
  }
  Json::array(items)
}

///|
/// Map severity to SARIF level.
fn sarif_level(severity : Severity) -> String {
  match severity {
    Error => "error"
    Warning => "warning"
  }
}
