///|
/// Tests for the incremental scan cache.

///|
fn cache_test_rule(
  id : String,
  match_ : MatchKind,
  unless : MatchKind?,
) -> Rule {
  Rule::{
    id,
    severity: Severity::error(),
    message: "test rule",
    extensions: [".ts"],
    match_,
    unless,
    scope: Scope::empty(),
    match_comments: false,
  }
}

///|
test "content_hash is stable, 16 hex digits, and content-sensitive" {
  let a = content_hash("let x = 1")
  let b = content_hash("let x = 1")
  let c = content_hash("let x = 2")
  assert_eq(a, b)
  assert_true(a != c)
  assert_eq(a.length(), 16)
  assert_true(
    a.iter().all(ch => (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')),
  )
}

///|
test "config fingerprint is stable for identical configs" {
  let rules = [cache_test_rule("no-foo", Contains("foo"), None)]
  let fp1 = config_fingerprint(rules, [], [], Scope::empty())
  let fp2 = config_fingerprint(rules, [], [], Scope::empty())
  assert_eq(fp1, fp2)
}

///|
test "config fingerprint changes when any rule input changes" {
  let base = config_fingerprint(
    [cache_test_rule("no-foo", Contains("foo"), None)],
    [],
    [],
    Scope::empty(),
  )
  let by_message = config_fingerprint(
    [
      Rule::{
        ..cache_test_rule("no-foo", Contains("foo"), None),
        message: "other",
      },
    ],
    [],
    [],
    Scope::empty(),
  )
  let by_severity = config_fingerprint(
    [
      Rule::{
        ..cache_test_rule("no-foo", Contains("foo"), None),
        severity: Warning,
      },
    ],
    [],
    [],
    Scope::empty(),
  )
  let by_match = config_fingerprint(
    [cache_test_rule("no-foo", Contains("bar"), None)],
    [],
    [],
    Scope::empty(),
  )
  let by_unless = config_fingerprint(
    [cache_test_rule("no-foo", Contains("foo"), Some(Contains("foo")))],
    [],
    [],
    Scope::empty(),
  )
  let by_ext = config_fingerprint(
    [
      Rule::{
        ..cache_test_rule("no-foo", Contains("foo"), None),
        extensions: [".js"],
      },
    ],
    [],
    [],
    Scope::empty(),
  )
  let by_global_scope = config_fingerprint(
    [cache_test_rule("no-foo", Contains("foo"), None)],
    [],
    [],
    Scope::new(["src/**"], []).unwrap(),
  )
  let by_match_comments = config_fingerprint(
    [
      Rule::{
        ..cache_test_rule("no-foo", Contains("foo"), None),
        match_comments: true,
      },
    ],
    [],
    [],
    Scope::empty(),
  )
  let by_structural = config_fingerprint(
    [cache_test_rule("no-foo", Contains("foo"), None)],
    [],
    [
      {
        id: "imports/no-import-cycles",
        severity: Severity::error(),
        message: "m",
        extensions: [".ts"],
        check: NoImportCycles,
        scope: Scope::empty(),
      },
    ],
    Scope::empty(),
  )
  assert_true(base != by_message)
  assert_true(base != by_severity)
  assert_true(base != by_match)
  assert_true(base != by_unless)
  assert_true(base != by_ext)
  assert_true(base != by_global_scope)
  assert_true(base != by_structural)
  assert_true(base != by_match_comments)
}

///|
test "cache render and parse round-trip" {
  let cache = Cache::new("fingerprint-1")
  cache.put("src/a.ts", content_hash("let x = 1"), [
    {
      rule_id: "no-foo",
      severity: Severity::error(),
      message: "test rule (foo)",
      file: "src/a.ts",
      line: 2,
      column: 5,
      snippet: "let x = foo",
    },
  ])
  let text = cache.render()
  let loaded = Cache::parse(text).unwrap()
  assert_true(loaded.is_current("fingerprint-1"))
  assert_false(loaded.is_current("fingerprint-2"))
  let entry = loaded.get("src/a.ts").unwrap()
  assert_eq(entry.hash, content_hash("let x = 1"))
  assert_eq(entry.findings.length(), 1)
  assert_eq(entry.findings[0].rule_id, "no-foo")
  assert_eq(entry.findings[0].severity, Error)
  assert_eq(entry.findings[0].line, 2)
  assert_eq(entry.findings[0].column, 5)
  assert_eq(entry.findings[0].snippet, "let x = foo")
}

///|
test "cache parse rejects malformed input" {
  assert_true(Cache::parse("not json") is None)
  assert_true(Cache::parse("[]") is None)
  assert_true(
    Cache::parse("{\"version\": 99, \"fingerprint\": \"x\", \"files\": {}}")
    is None,
  )
  assert_true(Cache::parse("{\"version\": 1, \"files\": {}}") is None)
  assert_true(Cache::parse("{\"version\": 1, \"fingerprint\": \"x\"}") is None)
  // A malformed finding entry fails the whole load.
  let bad = "{\"version\": 1, \"fingerprint\": \"x\", \"files\": {\"a.ts\": {\"hash\": \"h\", \"findings\": [{\"rule_id\": \"r\"}]}}}"
  assert_true(Cache::parse(bad) is None)
}

///|
test "cache put replaces an existing entry" {
  let cache = Cache::new("fp")
  cache.put("a.ts", "hash-1", [])
  cache.put("a.ts", "hash-2", [])
  assert_eq(cache.get("a.ts").unwrap().hash, "hash-2")
}

///|
test "config fingerprint tracks combinator structure" {
  let base = config_fingerprint(
    [cache_test_rule("r", All([Contains("a"), Contains("b")]), None)],
    [],
    [],
    Scope::empty(),
  )
  let reordered = config_fingerprint(
    [cache_test_rule("r", All([Contains("b"), Contains("a")]), None)],
    [],
    [],
    Scope::empty(),
  )
  let widened = config_fingerprint(
    [cache_test_rule("r", Any([Contains("a"), Contains("b")]), None)],
    [],
    [],
    Scope::empty(),
  )
  let nested = config_fingerprint(
    [cache_test_rule("r", All([Contains("a"), Not(Contains("b"))]), None)],
    [],
    [],
    Scope::empty(),
  )
  let deeper = config_fingerprint(
    [cache_test_rule("r", All([All([Contains("a"), Contains("b")])]), None)],
    [],
    [],
    Scope::empty(),
  )
  assert_true(base != reordered)
  assert_true(base != widened)
  assert_true(base != nested)
  assert_true(base != deeper)
}
