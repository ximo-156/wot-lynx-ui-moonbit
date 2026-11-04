///|
fn baseline_v2_test_finding(
  rule_id~ : String = "moonbit/doc",
  file~ : String = "domain/api.mbt",
  line~ : Int32 = 10,
  column~ : Int32 = 1,
  severity~ : Severity = Severity::Error,
  message~ : String = "Public function unsafe lacks documentation",
  snippet~ : String = "pub fn unsafe() -> Unit { panic() }",
) -> Finding {
  { rule_id, file, line, column, severity, message, snippet, }
}

///|
fn baseline_v2_test_capture(findings : Array[Finding]) -> BaselineV2 {
  BaselineV2::capture(findings, "Tracked debt", "team-platform", None).unwrap()
}

///|
fn baseline_v2_test_entry() -> Map[String, Json] {
  {
    "key": Json::string("0123456789abcdef"),
    "rule_id": Json::string("moonbit/doc"),
    "file": Json::string("domain/api.mbt"),
    "count": Json::number(1.0),
    "reason": Json::string("Tracked debt"),
    "owner": Json::string("team-platform"),
    "expires": Json::null(),
  }
}

///|
fn baseline_v2_test_document(entries : Array[Json]) -> String {
  let json : Json = {
    "version": 2,
    "fingerprint": "moonlint-content-v2",
    "entries": Json::array(entries),
  }
  json.stringify()
}

///|
fn baseline_v2_test_parse_error(src : String) -> String {
  match BaselineV2::parse(src) {
    Err(ConfigError(message)) => message
    Ok(_) => "accepted"
  }
}

///|
fn baseline_v2_test_assert_entry_error(
  entry : Map[String, Json],
  field : String,
) -> Unit raise {
  let message = baseline_v2_test_parse_error(
    baseline_v2_test_document([Json::object(entry)]),
  )
  assert_true(message != "accepted" && message.contains(field), msg=message)
}

///|
test "baseline v2 capture groups equal content by count rather than locations" {
  let baseline = baseline_v2_test_capture([
    baseline_v2_test_finding(line=1),
    baseline_v2_test_finding(line=80, column=5),
    baseline_v2_test_finding(file="ui/api.mbt"),
  ])
  assert_eq(baseline.entries.length(), 2)
  assert_eq(
    baseline.entries.map(entry => entry.count).fold(init=0, (a, b) => a + b),
    3,
  )
  assert_true(baseline.entries.any(entry => entry.count == 2))
  for entry in baseline.entries {
    assert_eq(entry.reason, "Tracked debt")
    assert_eq(entry.owner, "team-platform")
    assert_eq(entry.expires, None)
    assert_eq(entry.key.length(), 16)
  }
}

///|
test "baseline v2 key remains stable after line and column shifts" {
  let before = baseline_v2_test_finding()
  let after = baseline_v2_test_finding(line=500, column=19)
  assert_eq(baseline_v2_key(before), baseline_v2_key(after))
  assert_true(finding_hash(before) != finding_hash(after))
  let (remaining, suppressed, audit) = baseline_v2_test_capture([before])
    .partition([after], "2026-11-04")
    .unwrap()
  assert_eq(remaining.length(), 0)
  assert_eq(suppressed.length(), 1)
  assert_eq(suppressed[0].line, 500)
  assert_eq(audit.counts.get("suppressed"), Some(1))
  assert_eq(audit.counts.get("unused_occurrences"), Some(0))
  assert_false(audit.has_errors())
}

///|
test "baseline v2 trims only snippet ends without changing message or file text" {
  let finding = baseline_v2_test_finding()
  let indented = baseline_v2_test_finding(
    snippet=" \tpub fn unsafe() -> Unit { panic() }\r\n",
  )
  assert_eq(baseline_v2_key(finding), baseline_v2_key(indented))
  let (remaining, suppressed, _) = baseline_v2_test_capture([finding])
    .partition([indented], "2026-11-04")
    .unwrap()
  assert_eq(remaining.length(), 0)
  assert_eq(suppressed.length(), 1)
  assert_true(
    baseline_v2_key(finding) !=
    baseline_v2_key(
      baseline_v2_test_finding(
        message=" Public function unsafe lacks documentation",
      ),
    ),
  )
}

///|
test "baseline v2 conservatively invalidates every content key component" {
  let original = baseline_v2_test_finding()
  let baseline = baseline_v2_test_capture([original])
  for
    changed in [
      baseline_v2_test_finding(rule_id="moonbit/other"),
      baseline_v2_test_finding(file="other/api.mbt"),
      baseline_v2_test_finding(severity=Severity::Warning),
      baseline_v2_test_finding(
        message="Public function renamed lacks documentation",
      ),
      baseline_v2_test_finding(snippet="pub fn renamed() -> Unit { panic() }"),
    ] {
    assert_true(baseline_v2_key(original) != baseline_v2_key(changed))
    let (remaining, suppressed, audit) = baseline
      .partition([changed], "2026-11-04")
      .unwrap()
    assert_eq(remaining.length(), 1)
    assert_eq(suppressed.length(), 0)
    assert_eq(audit.counts.get("unused_entries"), Some(1))
  }
}

///|
test "baseline v2 preserves literal and internal whitespace in content keys" {
  for
    (before, after) in [
      ("let message = \"a b\"", "let message = \"a  b\""),
      ("let message = \" a \"", "let message = \"a\""),
      ("let value = foo()", "let  value = foo()"),
      ("let value = foo()", "let value=foo()"),
      ("let value = foo()", "let\tvalue = foo()"),
    ] {
    let original = baseline_v2_test_finding(snippet=before)
    let changed = baseline_v2_test_finding(snippet=after)
    let (_, suppressed, _) = baseline_v2_test_capture([original])
      .partition([changed], "2026-11-04")
      .unwrap()
    assert_eq(suppressed.length(), 0)
  }
}

///|
test "baseline v2 length encoding avoids delimiter collisions" {
  let first = baseline_v2_test_finding(rule_id="a|b", file="c")
  let second = baseline_v2_test_finding(rule_id="a", file="b|c")
  assert_true(baseline_v2_content(first) != baseline_v2_content(second))
  assert_true(baseline_v2_key(first) != baseline_v2_key(second))
  let unicode = baseline_v2_test_finding(
    message="函数 unsafe 缺少文档 🦊",
  )
  assert_eq(baseline_v2_key(unicode).length(), 16)
}

///|
test "baseline v2 copied findings cannot exceed captured multiplicity" {
  let baseline = baseline_v2_test_capture([baseline_v2_test_finding()])
  let (remaining, suppressed, audit) = baseline
    .partition(
      [
        baseline_v2_test_finding(line=40),
        baseline_v2_test_finding(line=1),
        baseline_v2_test_finding(line=99),
      ],
      "2026-11-04",
    )
    .unwrap()
  assert_eq(suppressed.map(f => f.line), [40])
  assert_eq(remaining.map(f => f.line), [1, 99])
  assert_eq(audit.counts.get("suppressed"), Some(1))
  assert_eq(audit.counts.get("unused_occurrences"), Some(0))
  assert_eq(audit.issues.length(), 0)
}

///|
test "baseline v2 partial budget is an explicit audit error with metadata" {
  let finding = baseline_v2_test_finding()
  let baseline = baseline_v2_test_capture([finding, finding, finding])
  let (remaining, suppressed, audit) = baseline
    .partition([finding], "2026-11-04")
    .unwrap()
  assert_eq(remaining.length(), 0)
  assert_eq(suppressed.length(), 1)
  assert_eq(audit.counts.get("unused_entries"), Some(0))
  assert_eq(audit.counts.get("unused_occurrences"), Some(2))
  assert_eq(audit.issues.length(), 1)
  let issue = audit.issues[0]
  assert_eq(issue.rule_id, "baseline/unused-budget")
  assert_eq(issue.severity, Severity::Error)
  assert_eq(issue.details.get("count"), Some("3"))
  assert_eq(issue.details.get("unused_count"), Some("2"))
  assert_eq(issue.details.get("key"), Some(baseline_v2_key(finding)))
  assert_eq(issue.details.get("rule"), Some(finding.rule_id))
  assert_eq(issue.details.get("file"), Some(finding.file))
  assert_eq(issue.details.get("reason"), Some("Tracked debt"))
  assert_eq(issue.details.get("owner"), Some("team-platform"))
  assert_eq(issue.details.get("expires"), Some("null"))
  assert_true(audit.has_errors())
  let (_, _, full) = baseline
    .partition([finding, finding, finding], "2026-11-04")
    .unwrap()
  assert_eq(full.issues.length(), 0)
  assert_eq(full.counts.get("unused_occurrences"), Some(0))
}

///|
test "baseline v2 completely unused entries have one diagnostic not duplicated budget issues" {
  let finding = baseline_v2_test_finding()
  let (_, suppressed, audit) = baseline_v2_test_capture([finding, finding])
    .partition([], "2026-11-04")
    .unwrap()
  assert_eq(suppressed.length(), 0)
  assert_eq(audit.counts.get("unused_entries"), Some(1))
  assert_eq(audit.counts.get("unused_occurrences"), Some(2))
  assert_eq(audit.issues.length(), 1)
  assert_eq(audit.issues[0].rule_id, "baseline/unused")
  assert_eq(audit.issues[0].details.get("unused_count"), Some("2"))
}

///|
test "baseline v2 expiry and unused auditing independently overlap" {
  let finding = baseline_v2_test_finding()
  let baseline = BaselineV2::capture(
    [finding, finding],
    "Temporary debt",
    "team",
    Some("2026-11-03"),
  ).unwrap()
  let (_, _, audit) = baseline.partition([], "2026-11-04").unwrap()
  assert_eq(audit.counts.get("expired_entries"), Some(1))
  assert_eq(audit.counts.get("unused_entries"), Some(1))
  assert_eq(audit.counts.get("unused_occurrences"), Some(2))
  assert_eq(audit.issues.map(issue => issue.rule_id), [
    "baseline/expired", "baseline/unused",
  ])
  assert_eq(audit.issues[0].details.get("expires"), Some("2026-11-03"))
}

///|
test "baseline v2 expired matching findings remain while same-day expiry is valid" {
  let finding = baseline_v2_test_finding()
  let baseline = BaselineV2::capture(
    [finding],
    "Temporary debt",
    "team",
    Some("2026-11-04"),
  ).unwrap()
  for today in ["2026-11-03", "2026-11-04"] {
    let (remaining, suppressed, audit) = baseline
      .partition([finding], today)
      .unwrap()
    assert_eq(remaining.length(), 0)
    assert_eq(suppressed.length(), 1)
    assert_eq(audit.counts.get("expired_entries"), Some(0))
  }
  let (remaining, suppressed, audit) = baseline
    .partition([finding], "2026-11-05")
    .unwrap()
  assert_eq(remaining.length(), 1)
  assert_eq(suppressed.length(), 0)
  assert_eq(audit.counts.get("expired_entries"), Some(1))
  assert_eq(audit.counts.get("unused_entries"), Some(0))
  assert_eq(audit.counts.get("unused_occurrences"), Some(0))
  assert_eq(audit.issues[0].rule_id, "baseline/expired")
}

///|
test "baseline v2 expired partial budgets still report unused occurrences" {
  let finding = baseline_v2_test_finding()
  let baseline = BaselineV2::capture(
    [finding, finding, finding],
    "Temporary",
    "team",
    Some("2026-11-03"),
  ).unwrap()
  let (remaining, suppressed, audit) = baseline
    .partition([finding], "2026-11-04")
    .unwrap()
  assert_eq(remaining.length(), 1)
  assert_eq(suppressed.length(), 0)
  assert_eq(audit.counts.get("unused_entries"), Some(0))
  assert_eq(audit.counts.get("unused_occurrences"), Some(2))
  assert_eq(audit.issues.map(issue => issue.rule_id), [
    "baseline/expired", "baseline/unused-budget",
  ])
}

///|
test "baseline v2 capture requires nonblank reason owner and valid finding identifiers" {
  for
    (reason, owner, field) in [
      ("", "team", "reason"),
      (" \t\n", "team", "reason"),
      ("x\u{0}", "team", "reason"),
      ("reason", "", "owner"),
      ("reason", "x\u{0}", "owner"),
    ] {
    let message = match BaselineV2::capture([], reason, owner, None) {
      Err(ConfigError(message)) => message
      Ok(_) => "accepted"
    }
    assert_true(message.contains(field), msg=message)
  }
  assert_true(
    BaselineV2::capture(
      [baseline_v2_test_finding(rule_id="")],
      "reason",
      "owner",
      None,
    )
    is Err(ConfigError(_)),
  )
  assert_true(
    BaselineV2::capture(
      [baseline_v2_test_finding(file="\u{0}")],
      "reason",
      "owner",
      None,
    )
    is Err(ConfigError(_)),
  )
}

///|
test "baseline v2 valid Gregorian leap years and year endpoints roundtrip" {
  for
    date in [
      "0001-01-01", "9999-12-31", "2000-02-29", "2024-02-29", "2400-02-29", "2026-04-30",
      "2026-01-31",
    ] {
    let baseline = BaselineV2::capture(
      [baseline_v2_test_finding()],
      "Reason",
      "Owner",
      Some(date),
    ).unwrap()
    assert_eq(
      BaselineV2::parse(baseline.render()).unwrap().entries[0].expires,
      Some(date),
    )
    assert_true(baseline.partition([], date) is Ok(_))
  }
}

///|
test "baseline v2 invalid dates fail capture parse and explicit today validation" {
  for
    date in [
      "", "2026-1-01", "2026-01-1", "2026/01/01", "2026-00-01", "2026-13-01", "2026-01-00",
      "2026-01-32", "2026-04-31", "2023-02-29", "1900-02-29", "2100-02-29", "0000-01-01",
      "2026-01-01T00:00:00Z", " 2026-01-01", "2026-01-01\n", "202a-01-01",
    ] {
    assert_true(
      BaselineV2::capture([], "Reason", "Owner", Some(date))
      is Err(ConfigError(_)),
      msg=date,
    )
    let entry = baseline_v2_test_entry()
    entry["expires"] = Json::string(date)
    baseline_v2_test_assert_entry_error(entry, "expires")
    assert_true(
      baseline_v2_test_capture([]).partition([], date) is Err(ConfigError(_)),
      msg=date,
    )
  }
}

///|
test "baseline v2 stable rendering is independent of finding declaration order" {
  let a = baseline_v2_test_finding(file="a.mbt")
  let b = baseline_v2_test_finding(file="b.mbt")
  let c = baseline_v2_test_finding(file="c.mbt")
  let first = baseline_v2_test_capture([a, b, a, c])
  let second = baseline_v2_test_capture([c, a, b, a])
  assert_eq(first.render(), second.render())
  let keys = first.entries.map(entry => entry.key)
  let sorted = keys.copy()
  sorted.sort_by(String::lexical_compare)
  assert_eq(keys, sorted)
  assert_eq(BaselineV2::parse(first.render()).unwrap().render(), first.render())
}

///|
test "baseline v2 JSON escaping preserves reason owner and nullable expiry metadata" {
  let baseline = BaselineV2::capture(
    [baseline_v2_test_finding()],
    "Quote \" and newline\n理由",
    "team\\platform 🦊",
    None,
  ).unwrap()
  let rendered = baseline.render()
  assert_true(rendered.contains("\"expires\": null"))
  let reparsed = BaselineV2::parse(rendered).unwrap()
  assert_eq(reparsed.entries[0].reason, "Quote \" and newline\n理由")
  assert_eq(reparsed.entries[0].owner, "team\\platform 🦊")
  assert_eq(reparsed.render(), rendered)
}

///|
test "baseline v2 explicit empty documents suppress nothing and audit cleanly" {
  let baseline = BaselineV2::parse(baseline_v2_test_document([])).unwrap()
  let (remaining, suppressed, audit) = baseline
    .partition([baseline_v2_test_finding()], "2026-11-04")
    .unwrap()
  assert_eq(remaining.length(), 1)
  assert_eq(suppressed.length(), 0)
  assert_eq(audit.mode, "baseline-audit")
  assert_eq(audit.counts.get("unused_entries"), Some(0))
  assert_eq(audit.counts.get("expired_entries"), Some(0))
  assert_eq(audit.counts.get("unused_occurrences"), Some(0))
  assert_eq(audit.metadata.get("fingerprint"), Some("moonlint-content-v2"))
  assert_eq(audit.metadata.get("today"), Some("2026-11-04"))
  assert_false(audit.has_errors())
}

///|
test "baseline v2 partition budgets reset each run without mutating stored counts" {
  let finding = baseline_v2_test_finding()
  let baseline = baseline_v2_test_capture([finding])
  let original = baseline.render()
  for _ in 0..<3 {
    let (_, suppressed, audit) = baseline
      .partition([finding, finding], "2026-11-04")
      .unwrap()
    assert_eq(suppressed.length(), 1)
    assert_eq(audit.counts.get("unused_occurrences"), Some(0))
    assert_eq(baseline.render(), original)
  }
}

///|
test "baseline v2 parser rejects legacy arrays bad JSON and unsupported versions" {
  for src in ["not json", "[]", "[\"0123456789abcdef\"]", "null", "true", "{}"] {
    assert_true(baseline_v2_test_parse_error(src) != "accepted", msg=src)
  }
  for
    version in [
      "1", "3", "-2", "2.5", "2.0", "2e0", "\"2\"", "null", "false", "2147483648",
    ] {
    let src = "{\"version\":\{version},\"fingerprint\":\"moonlint-content-v2\",\"entries\":[]}"
    assert_true(baseline_v2_test_parse_error(src).contains("version"), msg=src)
  }
  for
    fingerprint in ["legacy", "moonlint-content-v1", "moonlint-content-v3", ""] {
    let json : Json = {
      "version": 2,
      "fingerprint": Json::string(fingerprint),
      "entries": [],
    }
    assert_true(
      baseline_v2_test_parse_error(json.stringify()).contains("fingerprint"),
    )
  }
}

///|
test "baseline v2 parser requires root fields and rejects unknown root fields" {
  let root : Map[String, Json] = {
    "version": Json::number(2.0),
    "fingerprint": Json::string("moonlint-content-v2"),
    "entries": Json::array([]),
  }
  for field in ["version", "fingerprint", "entries"] {
    let changed = root.copy()
    changed.remove(field)
    assert_true(
      baseline_v2_test_parse_error(Json::object(changed).stringify()).contains(
        field,
      ),
    )
  }
  let changed = root.copy()
  changed["legacy"] = true
  assert_true(
    baseline_v2_test_parse_error(Json::object(changed).stringify()).contains(
      "unknown field",
    ),
  )
  for value in [Json::null(), Json::string("entries"), Json::boolean(false)] {
    let changed = root.copy()
    changed["entries"] = value
    assert_true(
      baseline_v2_test_parse_error(Json::object(changed).stringify()).contains(
        "entries",
      ),
    )
  }
  assert_true(
    baseline_v2_test_parse_error(
      baseline_v2_test_document([Json::boolean(true)]),
    ).contains("entries[0]"),
  )
}

///|
test "baseline v2 parser requires every entry field and rejects unknown entry fields" {
  for field in ["key", "rule_id", "file", "count", "reason", "owner", "expires"] {
    let entry = baseline_v2_test_entry()
    entry.remove(field)
    baseline_v2_test_assert_entry_error(entry, field)
  }
  let entry = baseline_v2_test_entry()
  entry["unknown"] = true
  baseline_v2_test_assert_entry_error(entry, "unknown field")
}

///|
test "baseline v2 parser rejects duplicate baseline keys and JSON fields" {
  let entry = Json::object(baseline_v2_test_entry())
  assert_true(
    baseline_v2_test_parse_error(baseline_v2_test_document([entry, entry])).contains(
      "duplicate baseline key",
    ),
  )
  for
    src in [
      "{\"version\":2,\"version\":2}", "{\"version\":2,\"fingerprint\":\"moonlint-content-v2\",\"entries\":[{\"key\":\"a\",\"key\":\"b\"}]}",
    ] {
    assert_true(
      baseline_v2_test_parse_error(src).contains("duplicate JSON field"),
    )
  }
}

///|
test "baseline v2 parser strictly validates positive integer counts" {
  for
    value in [
      Json::number(0.0),
      Json::number(-1.0),
      Json::number(0.5),
      Json::number(1.0, repr="1.0"),
      Json::number(1.0, repr="1e0"),
      Json::number(2147483648.0),
      Json::number(9007199254740992.0, repr="9007199254740993"),
      Json::string("1"),
      Json::null(),
      Json::boolean(true),
    ] {
    let entry = baseline_v2_test_entry()
    entry["count"] = value
    baseline_v2_test_assert_entry_error(entry, "count")
  }
  let entry = baseline_v2_test_entry()
  entry["count"] = Json::number(2147483647.0)
  assert_eq(
    BaselineV2::parse(baseline_v2_test_document([Json::object(entry)])).unwrap().entries[0].count,
    2147483647,
  )
}

///|
test "baseline v2 parser validates hex keys nonblank metadata and nullable dates" {
  for
    key in [
      "", "0123456789abcde", "0123456789abcdef0", "0123456789abcdeF", "g123456789abcdef",
      "0123456789abcde\u{0}",
    ] {
    let entry = baseline_v2_test_entry()
    entry["key"] = Json::string(key)
    baseline_v2_test_assert_entry_error(entry, "key")
  }
  for field in ["key", "rule_id", "file", "reason", "owner"] {
    for value in [Json::null(), Json::number(1.0), Json::boolean(false)] {
      let entry = baseline_v2_test_entry()
      entry[field] = value
      baseline_v2_test_assert_entry_error(entry, field)
    }
  }
  for field in ["rule_id", "file", "reason", "owner"] {
    for value in ["", " \t\n", "x\u{0}"] {
      let entry = baseline_v2_test_entry()
      entry[field] = Json::string(value)
      baseline_v2_test_assert_entry_error(entry, field)
    }
  }
  for value in [Json::number(1.0), Json::boolean(false), Json::array([])] {
    let entry = baseline_v2_test_entry()
    entry["expires"] = value
    baseline_v2_test_assert_entry_error(entry, "expires")
  }
}

///|
test "baseline v2 partition checks rule and file metadata before suppressing a key" {
  let finding = baseline_v2_test_finding()
  for field in ["rule_id", "file"] {
    let entry = baseline_v2_test_entry()
    entry["key"] = Json::string(baseline_v2_key(finding))
    entry[field] = Json::string("different")
    let baseline = BaselineV2::parse(
      baseline_v2_test_document([Json::object(entry)]),
    ).unwrap()
    let (remaining, suppressed, audit) = baseline
      .partition([finding], "2026-11-04")
      .unwrap()
    assert_eq(remaining.length(), 1)
    assert_eq(suppressed.length(), 0)
    assert_eq(audit.counts.get("unused_entries"), Some(1))
  }
}

///|
test "baseline v2 unused occurrence counter fails explicitly instead of overflowing" {
  let first = baseline_v2_test_entry()
  first["count"] = Json::number(2147483647.0)
  let second = baseline_v2_test_entry()
  second["key"] = "1123456789abcdef"
  second["count"] = Json::number(2147483647.0)
  let baseline = BaselineV2::parse(
    baseline_v2_test_document([Json::object(first), Json::object(second)]),
  ).unwrap()
  let message = match baseline.partition([], "2026-11-04") {
    Err(ConfigError(message)) => message
    Ok(_) => "accepted"
  }
  assert_true(message.contains("unused_occurrences"), msg=message)
}

///|
test "baseline v2 maximum budget supports exact partial unused counts" {
  let finding = baseline_v2_test_finding()
  let entry = baseline_v2_test_entry()
  entry["key"] = Json::string(baseline_v2_key(finding))
  entry["count"] = Json::number(2147483647.0)
  let baseline = BaselineV2::parse(
    baseline_v2_test_document([Json::object(entry)]),
  ).unwrap()
  let (_, suppressed, audit) = baseline
    .partition([finding], "2026-11-04")
    .unwrap()
  assert_eq(suppressed.length(), 1)
  assert_eq(audit.counts.get("unused_occurrences"), Some(2147483646))
  assert_eq(audit.issues[0].details.get("unused_count"), Some("2147483646"))
}

///|
test "baseline v2 audit errors do not implicitly gate normal suppression" {
  let current = baseline_v2_test_finding()
  let removed = baseline_v2_test_finding(file="removed.mbt")
  let (remaining, suppressed, audit) = baseline_v2_test_capture([
      current, removed,
    ])
    .partition([current], "2026-11-04")
    .unwrap()
  assert_eq(remaining.length(), 0)
  assert_eq(suppressed.length(), 1)
  assert_true(audit.has_errors())
}

///|
test "baseline v2 works from findings without reading any working tree files" {
  let blob_finding = baseline_v2_test_finding(
    file="not-present-in-worktree/snapshot.mbt",
  )
  let (_, suppressed, _) = baseline_v2_test_capture([blob_finding])
    .partition([blob_finding], "2026-11-04")
    .unwrap()
  assert_eq(suppressed.length(), 1)
}
