///|
/// Compiler-graph fixtures exercise the actual version-3 JSON schema without
/// parsing MoonBit source or introducing a second compiler/parser.
fn package_policy_test_node(
  module_name : String,
  rel : String,
  registry~ : Bool = false,
) -> Json {
  {
    "module": Json::string(module_name),
    "version": "1.0.0",
    "source": if registry {
      { "kind": "registry" }
    } else {
      { "kind": "local", "path": "/example project" }
    },
    "rel": Json::string(rel),
  }
}

///|
fn package_policy_test_nodes() -> Array[Json] {
  [
    package_policy_test_node("demo/app", "domain"),
    package_policy_test_node("demo/app", "ui"),
    package_policy_test_node("vendor/lib", "adapter", registry=true),
  ]
}

///|
fn package_policy_test_edge(
  from : Int32,
  to : Int32,
  kinds~ : Array[String] = ["source"],
  import_alias~ : String = "ui",
) -> Json {
  {
    "from": Json::number(from.to_double()),
    "to": Json::number(to.to_double()),
    "alias": Json::string(import_alias),
    "kinds": Json::array(kinds.map(Json::string)),
  }
}

///|
fn package_policy_test_graph_object() -> Map[String, Json] {
  {
    "version": Json::number(3.0),
    "status": Json::string("success"),
    "error": Json::null(),
    "target": Json::string("native"),
    "root": Json::array([Json::number(0.0), Json::number(1.0)]),
    "nodes": Json::array(package_policy_test_nodes()),
    "edges": Json::array([package_policy_test_edge(0, 1)]),
    "logs": Json::array([]),
  }
}

///|
fn package_policy_test_graph(
  edges : Array[Json],
  target~ : String = "native",
) -> String {
  let graph = package_policy_test_graph_object()
  graph["edges"] = Json::array(edges)
  graph["target"] = Json::string(target)
  Json::object(graph).stringify()
}

///|
fn package_policy_test_rule_object() -> Map[String, Json] {
  {
    "id": Json::string("arch/domain"),
    "severity": Json::string("error"),
    "from": Json::array([Json::string("demo/app/domain")]),
    "deny": Json::array([Json::string("demo/app/ui")]),
    "reason": Json::string("Domain must not import UI"),
  }
}

///|
fn package_policy_test_document(rules : Array[Json]) -> String {
  let json : Json = { "version": 1, "package_rules": Json::array(rules) }
  json.stringify()
}

///|
fn package_policy_test_rules() -> Array[PackagePolicyRule] {
  parse_package_policy(
    package_policy_test_document([
      Json::object(package_policy_test_rule_object()),
    ]),
  ).unwrap()
}

///|
fn package_policy_test_parse_error(src : String) -> String {
  match parse_package_policy(src) {
    Err(ConfigError(message)) => message
    Ok(_) => "accepted"
  }
}

///|
fn package_policy_test_graph_error(src : String) -> String {
  match check_package_graph(src, package_policy_test_rules()) {
    Err(ConfigError(message)) => message
    Ok(_) => "accepted"
  }
}

///|
fn package_policy_test_assert_rule_error(
  rule : Map[String, Json],
  expected : String,
) -> Unit raise {
  let message = package_policy_test_parse_error(
    package_policy_test_document([Json::object(rule)]),
  )
  assert_true(message != "accepted" && message.contains(expected), msg=message)
}

///|
fn package_policy_test_assert_graph_error(
  graph : Map[String, Json],
  expected : String,
) -> Unit raise {
  let message = package_policy_test_graph_error(Json::object(graph).stringify())
  assert_true(message != "accepted" && message.contains(expected), msg=message)
}

///|
fn package_policy_test_issue_keys(report : PolicyReport) -> Array[String] {
  report.issues.map(issue => {
    "\{issue.rule_id}|\{issue.details.get("from").unwrap()}|\{issue.details.get("to").unwrap()}|\{issue.details.get("kind").unwrap()}|\{issue.details.get("target").unwrap()}|\{issue.details.get("alias").unwrap()}"
  })
}

///|
test "package policy parses defaults and the confirmed v1 document" {
  let rule = package_policy_test_rules()[0]
  assert_eq(rule.id, "arch/domain")
  assert_eq(rule.severity, Severity::Error)
  assert_eq(rule.from, ["demo/app/domain"])
  assert_eq(rule.allow, None)
  assert_eq(rule.deny, Some(["demo/app/ui"]))
  assert_eq(rule.kinds, ["source"])
  assert_eq(rule.targets, None)
  assert_eq(rule.reason, "Domain must not import UI")
  let src =
    #|{"version":1,"package_rules":[{"id":"arch/domain","severity":"error","from":["demo/app/domain"],"deny":["demo/app/ui"],"kinds":["source"],"targets":["native"],"reason":"Domain must not import UI"}]}
  assert_eq(parse_package_policy(src).unwrap()[0].targets, Some(["native"]))
}

///|
test "package policy normalizes duplicate patterns kinds and targets" {
  let rule = package_policy_test_rule_object()
  rule["from"] = ["demo/app/ui", "demo/app/domain", "demo/app/ui"]
  rule["deny"] = ["vendor/**", "demo/app/ui", "vendor/**"]
  rule["kinds"] = ["wbtest", "source", "test", "source"]
  rule["targets"] = ["wasm-gc", "native", "js", "native"]
  rule["severity"] = "warning"
  let parsed = parse_package_policy(
      package_policy_test_document([Json::object(rule)]),
    ).unwrap()[0]
  assert_eq(parsed.from, ["demo/app/domain", "demo/app/ui"])
  assert_eq(parsed.deny, Some(["demo/app/ui", "vendor/**"]))
  assert_eq(parsed.kinds, ["source", "test", "wbtest"])
  assert_eq(parsed.targets, Some(["js", "native", "wasm-gc"]))
  assert_eq(parsed.severity, Severity::Warning)
}

///|
test "package policy legal acyclic ui to domain graph passes with an edge checked" {
  let rule = package_policy_test_rule_object()
  rule["from"] = ["demo/app/**"]
  let rules = parse_package_policy(
    package_policy_test_document([Json::object(rule)]),
  ).unwrap()
  let report = check_package_graph(
    package_policy_test_graph([
      package_policy_test_edge(1, 0, import_alias="domain"),
    ]),
    rules,
  ).unwrap()
  assert_eq(report.mode, "package-policy")
  assert_eq(report.issues.length(), 0)
  assert_eq(report.counts.get("packages"), Some(2))
  assert_eq(report.counts.get("edges_checked"), Some(1))
  assert_eq(report.metadata.get("applicability"), Some("checked"))
  assert_false(report.has_errors())
}

///|
test "package policy acyclic domain to ui violates despite a valid compiler graph" {
  let report = check_package_graph(
    package_policy_test_graph([package_policy_test_edge(0, 1)]),
    package_policy_test_rules(),
  ).unwrap()
  assert_eq(report.issues.length(), 1)
  assert_eq(report.counts.get("edges_checked"), Some(1))
  let issue = report.issues[0]
  assert_eq(issue.rule_id, "arch/domain")
  assert_eq(issue.severity, Severity::Error)
  assert_true(issue.message.contains("Domain must not import UI"))
  assert_eq(issue.details.get("from"), Some("demo/app/domain"))
  assert_eq(issue.details.get("to"), Some("demo/app/ui"))
  assert_eq(issue.details.get("kind"), Some("source"))
  assert_eq(issue.details.get("target"), Some("native"))
  assert_eq(issue.details.get("alias"), Some("ui"))
  assert_eq(issue.details.get("reason"), Some("Domain must not import UI"))
  assert_eq(issue.details.length(), 6)
  assert_false(issue.details.contains("file"))
  assert_false(issue.details.contains("line"))
  assert_true(report.has_errors())
  assert_eq(report.metadata.get("graph_version"), Some("3"))
  assert_eq(report.metadata.get("target"), Some("native"))
}

///|
test "package policy allowlist permits listed external destinations only" {
  let rule = package_policy_test_rule_object()
  rule.remove("deny")
  rule["allow"] = ["vendor/lib/**"]
  let rules = parse_package_policy(
    package_policy_test_document([Json::object(rule)]),
  ).unwrap()
  let report = check_package_graph(
    package_policy_test_graph([
      package_policy_test_edge(0, 2, import_alias="adapter"),
      package_policy_test_edge(0, 1),
    ]),
    rules,
  ).unwrap()
  assert_eq(report.counts.get("edges_checked"), Some(2))
  assert_eq(report.issues.length(), 1)
  assert_eq(report.issues[0].details.get("to"), Some("demo/app/ui"))
}

///|
test "package policy empty allowlist explicitly denies all direct destinations" {
  let rule = package_policy_test_rule_object()
  rule.remove("deny")
  rule["allow"] = []
  let rules = parse_package_policy(
    package_policy_test_document([Json::object(rule)]),
  ).unwrap()
  let report = check_package_graph(
    package_policy_test_graph([
      package_policy_test_edge(0, 1),
      package_policy_test_edge(0, 2, import_alias="adapter"),
    ]),
    rules,
  ).unwrap()
  assert_eq(report.issues.length(), 2)
  assert_eq(report.counts.get("edges_checked"), Some(2))
}

///|
test "package policy source default excludes blackbox and whitebox imports" {
  let report = check_package_graph(
    package_policy_test_graph([
      package_policy_test_edge(0, 1, kinds=["blackbox-test", "whitebox-test"]),
    ]),
    package_policy_test_rules(),
  ).unwrap()
  assert_eq(report.issues.length(), 0)
  assert_eq(report.counts.get("edges_checked"), Some(0))
  assert_eq(report.metadata.get("applicability"), Some("no-applicable-edges"))
}

///|
test "package policy source test and wbtest are evaluated independently" {
  for
    (policy_kind, graph_kind) in [
      ("source", "source"),
      ("test", "blackbox-test"),
      ("wbtest", "whitebox-test"),
    ] {
    let rule = package_policy_test_rule_object()
    rule["kinds"] = Json::array([Json::string(policy_kind)])
    let rules = parse_package_policy(
      package_policy_test_document([Json::object(rule)]),
    ).unwrap()
    let report = check_package_graph(
      package_policy_test_graph([
        package_policy_test_edge(0, 1, kinds=[
          "source", "blackbox-test", "whitebox-test",
        ]),
      ]),
      rules,
    ).unwrap()
    assert_eq(report.issues.length(), 1)
    assert_eq(report.counts.get("edges_checked"), Some(1))
    assert_eq(report.issues[0].details.get("kind"), Some(policy_kind))
    let only_other = if graph_kind == "source" {
      "whitebox-test"
    } else {
      "source"
    }
    let other_report = check_package_graph(
      package_policy_test_graph([
        package_policy_test_edge(0, 1, kinds=[only_other]),
      ]),
      rules,
    ).unwrap()
    assert_eq(other_report.counts.get("edges_checked"), Some(0))
    assert_eq(other_report.issues.length(), 0)
  }
}

///|
test "package policy test allowlist exception never exempts a source edge" {
  let source_rule = package_policy_test_rule_object()
  let test_rule = package_policy_test_rule_object()
  test_rule["id"] = "arch/domain-test"
  test_rule["kinds"] = ["test"]
  test_rule.remove("deny")
  test_rule["allow"] = ["demo/app/ui"]
  let rules = parse_package_policy(
    package_policy_test_document([
      Json::object(source_rule),
      Json::object(test_rule),
    ]),
  ).unwrap()
  let report = check_package_graph(
    package_policy_test_graph([
      package_policy_test_edge(0, 1, kinds=[
        "source", "blackbox-test", "whitebox-test",
      ]),
    ]),
    rules,
  ).unwrap()
  assert_eq(report.counts.get("edges_checked"), Some(2))
  assert_eq(report.issues.length(), 1)
  assert_eq(report.issues[0].details.get("kind"), Some("source"))
}

///|
test "package policy external destination patterns and import aliases are preserved" {
  let rule = package_policy_test_rule_object()
  rule["deny"] = ["vendor/*/adap?er"]
  let rules = parse_package_policy(
    package_policy_test_document([Json::object(rule)]),
  ).unwrap()
  let report = check_package_graph(
    package_policy_test_graph([
      package_policy_test_edge(0, 2, import_alias="custom_adapter_2"),
    ]),
    rules,
  ).unwrap()
  assert_eq(report.issues.length(), 1)
  assert_eq(report.issues[0].details.get("to"), Some("vendor/lib/adapter"))
  assert_eq(report.issues[0].details.get("alias"), Some("custom_adapter_2"))
}

///|
test "package policy root identities have no trailing slash and globs match full identities" {
  let graph = package_policy_test_graph_object()
  graph["nodes"] = Json::array([
    package_policy_test_node("demo/app", ""),
    package_policy_test_node("vendor/lib", "", registry=true),
  ])
  graph["root"] = [0]
  let rule = package_policy_test_rule_object()
  rule["from"] = ["demo/app"]
  rule["deny"] = ["vendor/lib"]
  let rules = parse_package_policy(
    package_policy_test_document([Json::object(rule)]),
  ).unwrap()
  let report = check_package_graph(Json::object(graph).stringify(), rules).unwrap()
  assert_eq(report.issues[0].details.get("from"), Some("demo/app"))
  assert_eq(report.issues[0].details.get("to"), Some("vendor/lib"))
  let nonroot_report = check_package_graph(
    package_policy_test_graph([package_policy_test_edge(0, 1)]),
    rules,
  ).unwrap()
  assert_eq(
    nonroot_report.metadata.get("applicability"),
    Some("no-selected-root-packages"),
  )
}

///|
test "package policy target restriction never merges backend graphs" {
  let rule = package_policy_test_rule_object()
  rule["targets"] = ["native"]
  let rules = parse_package_policy(
    package_policy_test_document([Json::object(rule)]),
  ).unwrap()
  let edges = [package_policy_test_edge(0, 1)]
  let native = check_package_graph(package_policy_test_graph(edges), rules).unwrap()
  let js = check_package_graph(
    package_policy_test_graph(edges, target="js"),
    rules,
  ).unwrap()
  assert_eq(native.issues.length(), 1)
  assert_eq(js.issues.length(), 0)
  assert_eq(js.counts.get("edges_checked"), Some(0))
  assert_eq(js.metadata.get("target"), Some("js"))
  assert_eq(js.metadata.get("applicability"), Some("no-rules-for-target"))
}

///|
test "package policy accepts every supported graph backend separately" {
  for target in ["native", "js", "wasm", "wasm-gc", "llvm"] {
    let report = check_package_graph(
      package_policy_test_graph([package_policy_test_edge(0, 1)], target~),
      package_policy_test_rules(),
    ).unwrap()
    assert_eq(report.issues.length(), 1)
    assert_eq(report.metadata.get("target"), Some(target))
    assert_eq(report.issues[0].details.get("target"), Some(target))
  }
}

///|
test "package policy checks only direct edges originating at selected roots" {
  let graph = package_policy_test_graph_object()
  graph["root"] = [0]
  graph["edges"] = Json::array([
    package_policy_test_edge(0, 2, import_alias="adapter"),
    package_policy_test_edge(2, 1),
    package_policy_test_edge(1, 0, import_alias="domain"),
  ])
  let rule = package_policy_test_rule_object()
  rule["from"] = ["**"]
  let report = check_package_graph(
    Json::object(graph).stringify(),
    parse_package_policy(package_policy_test_document([Json::object(rule)])).unwrap(),
  ).unwrap()
  assert_eq(report.counts.get("packages"), Some(1))
  assert_eq(report.counts.get("edges_checked"), Some(1))
  assert_eq(report.issues.length(), 0)
  assert_true(
    report.metadata.get("coverage").unwrap().contains("no transitive checks"),
  )
}

///|
test "package policy documents omitted stdlib and excludes supplied stdlib nodes" {
  let graph = package_policy_test_graph_object()
  graph["nodes"] = Json::array([
    package_policy_test_node("demo/app", "domain"),
    package_policy_test_node("moonbitlang/core", "builtin", registry=true),
  ])
  graph["root"] = [0]
  let rule = package_policy_test_rule_object()
  rule["deny"] = ["**"]
  let report = check_package_graph(
    Json::object(graph).stringify(),
    parse_package_policy(package_policy_test_document([Json::object(rule)])).unwrap(),
  ).unwrap()
  assert_eq(report.counts.get("edges_checked"), Some(0))
  assert_eq(report.issues.length(), 0)
  assert_true(
    report.metadata.get("coverage").unwrap().contains("stdlib omitted"),
  )
}

///|
test "package policy deduplicates edges and kinds while preserving distinct aliases" {
  let rule = package_policy_test_rule_object()
  rule["kinds"] = ["source", "test", "wbtest"]
  let rules = parse_package_policy(
    package_policy_test_document([Json::object(rule)]),
  ).unwrap()
  let report = check_package_graph(
    package_policy_test_graph([
      package_policy_test_edge(
        0,
        1,
        kinds=["whitebox-test", "source", "source", "blackbox-test"],
        import_alias="z",
      ),
      package_policy_test_edge(
        0,
        1,
        kinds=["source", "blackbox-test", "whitebox-test"],
        import_alias="z",
      ),
      package_policy_test_edge(0, 1, import_alias="a"),
    ]),
    rules,
  ).unwrap()
  assert_eq(report.counts.get("edges_checked"), Some(4))
  assert_eq(report.issues.length(), 4)
  assert_eq(package_policy_test_issue_keys(report), [
    "arch/domain|demo/app/domain|demo/app/ui|source|native|a", "arch/domain|demo/app/domain|demo/app/ui|source|native|z",
    "arch/domain|demo/app/domain|demo/app/ui|test|native|z", "arch/domain|demo/app/domain|demo/app/ui|wbtest|native|z",
  ])
}

///|
test "package policy output stays stable under rule node root and edge reordering" {
  let z = package_policy_test_rule_object()
  z["id"] = "z"
  z["deny"] = ["**"]
  let a = package_policy_test_rule_object()
  a["id"] = "a"
  a["deny"] = ["**"]
  let rules1 = parse_package_policy(
    package_policy_test_document([Json::object(z), Json::object(a)]),
  ).unwrap()
  let rules2 = parse_package_policy(
    package_policy_test_document([Json::object(a), Json::object(z)]),
  ).unwrap()
  let graph1 = package_policy_test_graph_object()
  graph1["root"] = [1, 0, 0]
  graph1["edges"] = Json::array([
    package_policy_test_edge(0, 2, import_alias="adapter"),
    package_policy_test_edge(0, 1, import_alias="z"),
    package_policy_test_edge(0, 1, import_alias="a"),
  ])
  let graph2 = package_policy_test_graph_object()
  graph2["nodes"] = Json::array([
    package_policy_test_node("vendor/lib", "adapter", registry=true),
    package_policy_test_node("demo/app", "ui"),
    package_policy_test_node("demo/app", "domain"),
  ])
  graph2["root"] = [2, 1]
  graph2["edges"] = Json::array([
    package_policy_test_edge(2, 1, import_alias="a"),
    package_policy_test_edge(2, 1, import_alias="z"),
    package_policy_test_edge(2, 0, import_alias="adapter"),
    package_policy_test_edge(2, 1, import_alias="a"),
  ])
  let first = check_package_graph(Json::object(graph1).stringify(), rules1).unwrap()
  let second = check_package_graph(Json::object(graph2).stringify(), rules2).unwrap()
  assert_eq(first.counts, second.counts)
  assert_eq(first.counts.get("packages"), Some(2))
  assert_eq(first.counts.get("edges_checked"), Some(3))
  assert_eq(first.issues.length(), 6)
  assert_eq(
    package_policy_test_issue_keys(first),
    package_policy_test_issue_keys(second),
  )
  assert_eq(first.issues[0].rule_id, "a")
  assert_eq(first.issues[3].rule_id, "z")
  assert_eq(rules1[0].id, "z")
}

///|
test "package policy no selected packages and valid empty edge sets are explicit" {
  let rule = package_policy_test_rule_object()
  rule["from"] = ["other/module/**"]
  let rules = parse_package_policy(
    package_policy_test_document([Json::object(rule)]),
  ).unwrap()
  let report = check_package_graph(
    package_policy_test_graph([package_policy_test_edge(0, 1)]),
    rules,
  ).unwrap()
  assert_eq(
    report.metadata.get("applicability"),
    Some("no-selected-root-packages"),
  )
  assert_eq(report.counts.get("edges_checked"), Some(0))
  let empty = check_package_graph(
    package_policy_test_graph([]),
    package_policy_test_rules(),
  ).unwrap()
  assert_eq(empty.metadata.get("applicability"), Some("no-applicable-edges"))
  assert_eq(empty.counts.get("packages"), Some(2))
}

///|
test "package policy rejects invalid JSON incomplete documents and empty rule sets" {
  for
    src in [
      "not json", "[]", "null", "true", "{}", "{\"version\":1}", "{\"version\":1,\"package_rules\":[]}",
    ] {
    assert_true(package_policy_test_parse_error(src) != "accepted", msg=src)
  }
  assert_true(
    check_package_graph(package_policy_test_graph([]), [])
    is Err(ConfigError(_)),
  )
}

///|
test "package policy rejects unknown versions noninteger versions and root fields" {
  for
    version in [
      "0", "2", "-1", "1.5", "1.0", "1e0", "null", "true", "\"1\"", "2147483648",
    ] {
    let src = "{\"version\":\{version},\"package_rules\":[]}"
    assert_true(
      package_policy_test_parse_error(src).contains("version"),
      msg=src,
    )
  }
  assert_true(
    package_policy_test_parse_error(
      "{\"version\":1,\"package_rules\":[],\"rules\":[]}",
    ).contains("unknown field"),
  )
  for field in ["id", "severity", "from", "reason"] {
    let rule = package_policy_test_rule_object()
    rule.remove(field)
    package_policy_test_assert_rule_error(rule, field)
  }
  let rule = package_policy_test_rule_object()
  rule["unknown"] = true
  package_policy_test_assert_rule_error(rule, "unknown field")
}

///|
test "package policy rejects duplicate rule ids and duplicate JSON keys" {
  let rule = Json::object(package_policy_test_rule_object())
  assert_true(
    package_policy_test_parse_error(package_policy_test_document([rule, rule])).contains(
      "duplicate package rule id",
    ),
  )
  assert_true(
    package_policy_test_parse_error(
      "{\"version\":1,\"version\":1,\"package_rules\":[]}",
    ).contains("duplicate JSON field"),
  )
  let src =
    #|{"version":1,"package_rules":[{"id":"x","id":"y","severity":"error","from":["**"],"deny":["**"],"reason":"r"}]}
  assert_true(
    package_policy_test_parse_error(src).contains("duplicate JSON field"),
  )
}

///|
test "package policy requires exactly one allow or deny with safe array semantics" {
  let neither = package_policy_test_rule_object()
  neither.remove("deny")
  package_policy_test_assert_rule_error(neither, "exactly one")
  let both = package_policy_test_rule_object()
  both["allow"] = ["**"]
  package_policy_test_assert_rule_error(both, "exactly one")
  for
    (field, value) in [
      ("from", Json::array([])),
      ("from", Json::string("**")),
      ("from", Json::array([Json::number(1.0)])),
      ("deny", Json::array([])),
      ("deny", Json::null()),
      ("deny", Json::string("**")),
    ] {
    let rule = package_policy_test_rule_object()
    rule[field] = value
    package_policy_test_assert_rule_error(rule, field)
  }
  let rule = package_policy_test_rule_object()
  rule.remove("deny")
  rule["allow"] = Json::null()
  package_policy_test_assert_rule_error(rule, "allow")
}

///|
test "package policy rejects malformed identifiers severity and explanations" {
  for
    (field, value) in [
      ("id", Json::string("")),
      ("id", Json::string("a b")),
      ("id", Json::string("a\u{0}b")),
      ("id", Json::number(1.0)),
      ("severity", Json::string("warn")),
      ("severity", Json::string("ERROR")),
      ("severity", Json::null()),
      ("severity", Json::number(1.0)),
      ("reason", Json::string(" \t\n")),
      ("reason", Json::null()),
      ("reason", Json::string("x\u{0}")),
    ] {
    let rule = package_policy_test_rule_object()
    rule[field] = value
    package_policy_test_assert_rule_error(rule, field)
  }
}

///|
test "package policy validates the portable glob subset in every pattern field" {
  for field in ["from", "allow", "deny"] {
    for
      pattern in [
        "", "/demo/**", "demo/[a]", "demo/{a,b}", "demo\\ui", "!demo/**", "demo//ui",
        "demo/../ui", "demo/./ui", "demo/**bad", "demo/\u{0}",
      ] {
      let rule = package_policy_test_rule_object()
      if field == "allow" {
        rule.remove("deny")
      }
      rule[field] = Json::array([Json::string(pattern)])
      package_policy_test_assert_rule_error(rule, field)
    }
  }
}

///|
test "package policy rejects unknown malformed or empty policy kinds and targets" {
  for
    (field, value) in [
      ("kinds", Json::array([])),
      ("kinds", Json::string("source")),
      ("kinds", Json::null()),
      ("kinds", Json::array([Json::number(1.0)])),
      ("kinds", Json::array([Json::string("blackbox-test")])),
      ("kinds", Json::array([Json::string("whitebox-test")])),
      ("kinds", Json::array([Json::string("all")])),
      ("targets", Json::array([])),
      ("targets", Json::string("native")),
      ("targets", Json::null()),
      ("targets", Json::array([Json::number(1.0)])),
      ("targets", Json::array([Json::string("wasm_gc")])),
      ("targets", Json::array([Json::string("all")])),
    ] {
    let rule = package_policy_test_rule_object()
    rule[field] = value
    package_policy_test_assert_rule_error(rule, field)
  }
}

///|
test "package policy graph rejects unsupported versions and noninteger version tokens" {
  for
    version in [
      Json::number(2.0),
      Json::number(4.0),
      Json::number(-1.0),
      Json::number(3.5),
      Json::number(3.0, repr="3.0"),
      Json::number(3.0, repr="3e0"),
      Json::number(2147483648.0),
      Json::string("3"),
      Json::null(),
      Json::boolean(true),
    ] {
    let graph = package_policy_test_graph_object()
    graph["version"] = version
    package_policy_test_assert_graph_error(graph, "version")
  }
}

///|
test "package policy graph requires every v3 field and rejects unknown fields" {
  for
    field in [
      "version", "status", "error", "target", "root", "nodes", "edges", "logs",
    ] {
    let graph = package_policy_test_graph_object()
    graph.remove(field)
    package_policy_test_assert_graph_error(graph, field)
  }
  for src in ["[]", "null", "not json", "{}"] {
    assert_true(package_policy_test_graph_error(src) != "accepted", msg=src)
  }
  let graph = package_policy_test_graph_object()
  graph["targets"] = ["native", "js"]
  package_policy_test_assert_graph_error(graph, "unknown field")
  let graph = package_policy_test_graph_object()
  graph["logs"] = "warning"
  package_policy_test_assert_graph_error(graph, "logs")
}

///|
test "package policy graph rejects compiler errors unknown status and malformed target" {
  for
    (field, value) in [
      ("status", Json::string("error")),
      ("status", Json::string("pending")),
      ("status", Json::number(1.0)),
      ("status", Json::null()),
      ("error", Json::string("compiler failed")),
      ("error", Json::boolean(false)),
      ("error", Json::object({ "message": Json::string("failed") })),
      ("target", Json::string("all")),
      ("target", Json::string("wasm_gc")),
      ("target", Json::string("")),
      ("target", Json::null()),
      ("target", Json::array([Json::string("native")])),
    ] {
    let graph = package_policy_test_graph_object()
    graph[field] = value
    package_policy_test_assert_graph_error(graph, field)
  }
}

///|
test "package policy graph rejects malformed missing and ambiguous node identifiers" {
  let valid_node : Map[String, Json] = {
    "module": Json::string("demo/app"),
    "version": Json::string("1.0.0"),
    "source": { "kind": "local", "path": "/project" },
    "rel": Json::string("domain"),
  }
  for field in ["module", "version", "source", "rel"] {
    let node = valid_node.copy()
    node.remove(field)
    let graph = package_policy_test_graph_object()
    graph["nodes"] = Json::array([Json::object(node)])
    package_policy_test_assert_graph_error(graph, field)
  }
  for
    (field, value) in [
      ("module", Json::number(1.0)),
      ("module", Json::string("")),
      ("module", Json::string("/demo/app")),
      ("module", Json::string("demo//app")),
      ("module", Json::string("demo/../app")),
      ("module", Json::string("demo/*")),
      ("module", Json::string("demo app")),
      ("module", Json::string("demo\\app")),
      ("rel", Json::null()),
      ("rel", Json::string("/ui")),
      ("rel", Json::string("../ui")),
      ("rel", Json::string("ui/")),
      ("rel", Json::string("ui/**")),
      ("rel", Json::string("ui\u{0}")),
      ("version", Json::null()),
      ("version", Json::string("")),
    ] {
    let node = valid_node.copy()
    node[field] = value
    let graph = package_policy_test_graph_object()
    graph["nodes"] = Json::array([Json::object(node)])
    package_policy_test_assert_graph_error(graph, field)
  }
  let graph = package_policy_test_graph_object()
  graph["nodes"] = []
  package_policy_test_assert_graph_error(graph, "nodes")
  let graph = package_policy_test_graph_object()
  graph["nodes"] = [true]
  package_policy_test_assert_graph_error(graph, "nodes[0]")
  let node = valid_node.copy()
  node["id"] = 0.5
  let graph = package_policy_test_graph_object()
  graph["nodes"] = Json::array([Json::object(node)])
  package_policy_test_assert_graph_error(graph, "unknown field")
  let graph = package_policy_test_graph_object()
  graph["nodes"] = Json::array([
    Json::object(valid_node),
    Json::object(valid_node),
  ])
  package_policy_test_assert_graph_error(graph, "duplicate package identity")
}

///|
test "package policy graph validates registry and local node source objects" {
  for
    source in [
      Json::null(),
      Json::string("local"),
      Json::object({}),
      Json::object({ "kind": Json::string("git") }),
      Json::object({
        "kind": Json::string("registry"),
        "path": Json::string("/p"),
      }),
      Json::object({ "kind": Json::string("local") }),
      Json::object({ "kind": Json::string("local"), "path": Json::null() }),
      Json::object({ "kind": Json::string("local"), "path": Json::string("") }),
      Json::object({
        "kind": Json::string("local"),
        "path": Json::string("/p\u{0}"),
      }),
      Json::object({
        "kind": Json::string("local"),
        "path": Json::string("/p"),
        "extra": Json::boolean(true),
      }),
    ] {
    let node : Json = {
      "module": "demo/app",
      "version": "1.0.0",
      "rel": "domain",
      "source": source,
    }
    let graph = package_policy_test_graph_object()
    graph["nodes"] = Json::array([node])
    package_policy_test_assert_graph_error(graph, "source")
  }
}

///|
test "package policy graph rejects malformed roots and every noninteger index form" {
  for
    roots in [
      Json::null(),
      Json::string("0"),
      Json::array([]),
      Json::array([Json::number(3.0)]),
      Json::array([Json::number(-1.0)]),
      Json::array([Json::number(0.5)]),
      Json::array([Json::string("0")]),
      Json::array([Json::boolean(false)]),
      Json::array([Json::number(0.0, repr="0.0")]),
      Json::array([Json::number(0.0, repr="0e0")]),
      Json::array([Json::number(0.0, repr="-0")]),
      Json::array([Json::number(2147483648.0)]),
      Json::array([Json::number(9007199254740992.0, repr="9007199254740993")]),
    ] {
    let graph = package_policy_test_graph_object()
    graph["root"] = roots
    package_policy_test_assert_graph_error(graph, "root")
  }
}

///|
test "package policy graph rejects incomplete edges and bad from to indices" {
  let edge : Map[String, Json] = {
    "from": Json::number(0.0),
    "to": Json::number(1.0),
    "alias": Json::string("ui"),
    "kinds": ["source"],
  }
  for field in ["from", "to", "alias", "kinds"] {
    let malformed = edge.copy()
    malformed.remove(field)
    let graph = package_policy_test_graph_object()
    graph["edges"] = Json::array([Json::object(malformed)])
    package_policy_test_assert_graph_error(graph, field)
  }
  for field in ["from", "to"] {
    for
      value in [
        Json::number(-1.0),
        Json::number(3.0),
        Json::number(0.1),
        Json::number(0.0, repr="0.0"),
        Json::number(0.0, repr="0e0"),
        Json::number(2147483648.0),
        Json::string("0"),
        Json::null(),
        Json::boolean(true),
      ] {
      let malformed = edge.copy()
      malformed[field] = value
      let graph = package_policy_test_graph_object()
      graph["edges"] = Json::array([Json::object(malformed)])
      package_policy_test_assert_graph_error(graph, field)
    }
  }
  let graph = package_policy_test_graph_object()
  graph["edges"] = [false]
  package_policy_test_assert_graph_error(graph, "edges[0]")
  let malformed = edge.copy()
  malformed["target"] = "js"
  let graph = package_policy_test_graph_object()
  graph["edges"] = Json::array([Json::object(malformed)])
  package_policy_test_assert_graph_error(graph, "unknown field")
}

///|
test "package policy graph rejects malformed aliases kinds and kind aliases" {
  for
    import_alias in [
      "", "@ui", "bad/name", "two names", "bad-name", "1ui", "ui\u{0}",
    ] {
    let graph = package_policy_test_graph_object()
    graph["edges"] = Json::array([package_policy_test_edge(0, 1, import_alias~)])
    package_policy_test_assert_graph_error(graph, "alias")
  }
  for
    (field, value) in [
      ("alias", Json::number(1.0)),
      ("alias", Json::null()),
      ("kinds", Json::null()),
      ("kinds", Json::string("source")),
      ("kinds", Json::array([])),
      ("kinds", Json::array([Json::number(1.0)])),
      ("kinds", Json::array([Json::string("test")])),
      ("kinds", Json::array([Json::string("wbtest")])),
      ("kinds", Json::array([Json::string("unknown")])),
    ] {
    let edge : Json = { "from": 0, "to": 1, "alias": "ui", "kinds": ["source"] }
    guard edge is Object(obj) else { fail("invalid test fixture") }
    obj[field] = value
    let graph = package_policy_test_graph_object()
    graph["edges"] = Json::array([Json::object(obj)])
    package_policy_test_assert_graph_error(graph, field)
  }
}

///|
test "package policy validates malformed edges even with no applicable target or roots" {
  let rule = package_policy_test_rule_object()
  rule["targets"] = ["js"]
  rule["from"] = ["other/module/**"]
  let rules = parse_package_policy(
    package_policy_test_document([Json::object(rule)]),
  ).unwrap()
  let graph = package_policy_test_graph_object()
  graph["edges"] = Json::array([
    package_policy_test_edge(2, 1, kinds=["invalid-kind"]),
  ])
  let result = check_package_graph(Json::object(graph).stringify(), rules)
  assert_true(result is Err(ConfigError(_)))
}

///|
test "package policy graph rejects duplicate JSON fields anywhere" {
  for
    src in [
      "{\"version\":3,\"version\":3}", "{\"version\":3,\"nodes\":[{\"module\":\"demo/app\",\"module\":\"demo/other\"}]}",
      "{\"version\":3,\"edges\":[{\"from\":0,\"from\":1}]}",
    ] {
    assert_true(
      package_policy_test_graph_error(src).contains("duplicate JSON field"),
      msg=src,
    )
  }
}
