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
    match_literals: false,
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
  let by_match_literals = config_fingerprint(
    [
      Rule::{
        ..cache_test_rule("no-foo", Contains("foo"), None),
        match_literals: true,
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
  assert_true(base != by_match_literals)
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

///|
test "structural models round-trip through the cache" {
  let model = parse_source(
    "import type { A } from './a';\nimport b from 'b';\nexport const c: C = b(usedName);\n",
  )
  let cache = Cache::new("fp")
  let hash = content_hash("source-1")
  cache.put_model("src/x.ts", hash, model)
  let reparsed = Cache::parse(cache.render()).unwrap()
  let entry = reparsed.get_model("src/x.ts").unwrap()
  assert_eq(entry.hash, hash)
  assert_eq(entry.model.imports.length(), 2)
  assert_eq(entry.model.imports[0].source, "'./a'")
  assert_true(entry.model.imports[0].type_only)
  assert_eq(entry.model.exports.length(), 1)
  assert_eq(entry.model.exports[0].names[0], "c")
  // Used identifiers survive (deduplicated). A type name referenced in an
  // annotation is still an identifier read; only export names must exclude it.
  assert_true(entry.model.used.map(u => u.name).contains("usedName"))
  assert_eq(entry.model.exports[0].names.length(), 1)
  assert_eq(entry.model.exports[0].names[0], "c")
}

///|
test "an outdated model version drops models but keeps findings" {
  let cache_json =
    #|{
    #|  "version": 3,
    #|  "fingerprint": "fp",
    #|  "files": {"a.ts": {"hash": "h", "findings": []}},
    #|  "model_version": 999,
    #|  "models": {"a.ts": {"hash": "h", "model": {"imports": [], "exports": [], "used": []}}}
    #|}
  let parsed = Cache::parse(cache_json).unwrap()
  assert_true(parsed.get_model("a.ts") is None)
  assert_true(parsed.get("a.ts") is Some(_))
}

///|
test "a corrupt model entry is dropped without discarding findings" {
  let cache_json =
    #|{
    #|  "version": 3,
    #|  "fingerprint": "fp",
    #|  "files": {"a.ts": {"hash": "h", "findings": []}},
    #|  "model_version": 1,
    #|  "models": {"a.ts": {"hash": "h", "model": {"imports": "nope"}},
    #|             "b.ts": {"hash": "h2", "model": {"imports": [], "exports": [], "used": ["x"]}}}
    #|}
  let parsed = Cache::parse(cache_json).unwrap()
  assert_true(parsed.get_model("a.ts") is None)
  assert_true(parsed.get_model("b.ts") is Some(_))
  assert_true(parsed.get("a.ts") is Some(_))
}

///|
test "structural key is order-independent and content-sensitive" {
  let a = structural_key("fp", [("b.ts", "h2"), ("a.ts", "h1")])
  let b = structural_key("fp", [("a.ts", "h1"), ("b.ts", "h2")])
  assert_eq(a, b)
  // A different file hash, a different file set or a different rule
  // fingerprint must all produce a different identity.
  assert_true(a != structural_key("fp", [("a.ts", "h1"), ("b.ts", "h3")]))
  assert_true(a != structural_key("fp", [("a.ts", "h1")]))
  assert_true(a != structural_key("fp2", [("a.ts", "h1"), ("b.ts", "h2")]))
}

///|
test "structural verdict round-trips through the cache" {
  let cache = Cache::new("fp")
  cache.put_structural("key-1", [
    {
      rule_id: "imports/no-unused-exports",
      severity: Severity::error(),
      message: "m",
      file: "a.ts",
      line: 2,
      column: 1,
      snippet: "",
    },
  ])
  let parsed = Cache::parse(cache.render()).unwrap()
  let entry = parsed.get_structural().unwrap()
  assert_eq(entry.key, "key-1")
  assert_eq(entry.findings.length(), 1)
  assert_eq(entry.findings[0].file, "a.ts")
}

///|
test "a malformed structural verdict is dropped without discarding the rest" {
  let cache_json =
    #|{
    #|  "version": 3,
    #|  "fingerprint": "fp",
    #|  "files": {"a.ts": {"hash": "h", "findings": []}},
    #|  "model_version": 1,
    #|  "models": {},
    #|  "structural": {"key": "k", "findings": "nope"}
    #|}
  let parsed = Cache::parse(cache_json).unwrap()
  assert_true(parsed.get_structural() is None)
  assert_true(parsed.get("a.ts") is Some(_))
}
