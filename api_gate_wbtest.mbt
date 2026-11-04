///|
fn api_gate_test_snapshot(declarations : String, version : String) -> String {
  match
    make_api_snapshot(
      "package \"test/api\"\n" + declarations,
      "moon-0.9.1+exact",
      "native",
      version,
    ) {
    Ok(snapshot) => snapshot
    Err(ConfigError(message)) => abort("invalid API fixture: " + message)
  }
}

///|
fn api_gate_test_check(
  before : String,
  after : String,
  old_version : String,
  new_version : String,
  policy : String,
) -> PolicyReport {
  match
    check_api_snapshots(
      api_gate_test_snapshot(before, old_version),
      api_gate_test_snapshot(after, new_version),
      policy,
    ) {
    Ok(report) => report
    Err(ConfigError(message)) =>
      abort("unexpected inconclusive API fixture: " + message)
  }
}

///|
fn api_gate_test_mutate(
  snapshot : String,
  field : String,
  value : Json?,
) -> String {
  let json = @json.parse(snapshot) catch { _ => abort("invalid JSON fixture") }
  let fields = match json {
    Json::Object(fields) => fields
    _ => abort("invalid JSON root fixture")
  }
  match value {
    Some(value) => fields.set(field, value)
    None => fields.remove(field)
  }
  Json::object(fields).stringify(indent=2)
}

///|
test "api gate snapshot roundtrips exact metadata and interface text" {
  let text = "// generated header\npackage \"test/api\"\npub fn ping() -> Unit\n"
  let src = match
    make_api_snapshot(text, " moon-exact-build ", "wasm-gc", "release-tag") {
    Ok(snapshot) => snapshot
    Err(_) => abort("valid snapshot unexpectedly failed")
  }
  let parsed = api_gate_parse_snapshot(src).unwrap()
  assert_eq(parsed.package_name, "test/api")
  assert_eq(parsed.toolchain, " moon-exact-build ")
  assert_eq(parsed.backend, "wasm-gc")
  assert_eq(parsed.module_version, "release-tag")
  let report = check_api_snapshots(src, src, "none").unwrap()
  assert_eq(report.mode, "api-check")
  assert_eq(report.counts.get("exports_before"), Some(1))
  assert_eq(report.metadata.get("before_version"), Some("release-tag"))
  assert_true(report.metadata.get("coverage").unwrap().contains("ABI"))
  assert_eq(report.issues.length(), 0)
  for backend in ["native", "js", "wasm", "wasm-gc", "llvm"] {
    assert_true(make_api_snapshot(text, "moon", backend, "0.2.0") is Ok(_))
  }
  assert_true(make_api_snapshot(text, "", "native", "0.2.0") is Err(_))
  assert_true(make_api_snapshot(text, " \t ", "native", "0.2.0") is Err(_))
  assert_true(make_api_snapshot(text, "moon", "other", "0.2.0") is Err(_))
  assert_true(make_api_snapshot(text, "moon", "native", " ") is Err(_))
}

///|
test "api gate unchanged reorder whitespace header and derive display styles pass" {
  let before =
    #|import { "moonbitlang/core/debug", "moonbitlang/core/set", }
    #|pub struct Box[T] {
    #|  value : Array[(String, T)]
    #|} derive(@debug.Debug, Eq)
    #|pub fn[T] Box::get(Self[T]) -> T
    #|pub(all) enum Kind { One Two(Int32) } derive(Eq)
    #|pub(open) trait Readable {
    #|  fn read(Self) -> String
    #|  fn size(Self) -> Int32 = _
    #|}
    #|pub impl Readable for Box[String]
    #|pub type Alias = Box[String]
    #|pub let default_value : Alias
    #|pub const COUNT : Int32 = 7
    #|type Private derive(Eq)
  let after =
    #|// Generated using `moon info`, DON'T EDIT IT
    #|pub const COUNT:Int32=7
    #|pub let default_value:Alias
    #|pub type Alias=Box [ String ]
    #|pub impl Readable for Box[String]
    #|pub (open) trait Readable { fn size(Self)->Int32 = _; fn read(Self)->String }
    #|#derive(Eq)
    #|pub(all) enum Kind { Two(Int32), One, }
    #|pub fn [T] Box::get ( Self[T] )->T
    #|#derive(Eq)
    #|#derive(@debug.Debug)
    #|pub struct Box [T] { value:Array [ (String,T) ] }
    #|priv struct Private { different : @set.Set[String] }
    #|import { "moonbitlang/core/set", "moonbitlang/core/debug", }
  let report = api_gate_test_check(before, after, "0.2.0", "0.2.0", "none")
  assert_eq(report.issues.length(), 0)
  assert_eq(report.counts.get("exports_before"), Some(8))
  assert_eq(report.counts.get("changed"), Some(0))
  assert_eq(report.counts.get("added"), Some(0))
}

///|
test "api gate balanced body and private implementation changes are ignored" {
  let before =
    #|pub fn f(x : Int32) -> String { "before // { }" }
    #|priv fn helper() -> Unit { ignore("escaped \" } ") }
    #|priv enum Internal { A B }
  let after =
    #|// Header can mention pub fn removed() and unmatched braces {
    #|priv enum Internal { C }
    #|pub fn f(y : Int32) -> String {
    #|  /* outer { /* nested */ } */
    #|  let a = [1, 2]
    #|  "after /* not a comment */"
    #|}
    #|priv fn helper() -> Unit { () }
  let report = api_gate_test_check(before, after, "0.2.0", "0.2.0", "none")
  assert_eq(report.issues.length(), 0)
  assert_eq(report.counts.get("exports_before"), Some(1))
}

///|
test "api gate standalone exported function and type additions do not block" {
  let report = api_gate_test_check(
    "pub fn old() -> Unit", "pub fn old() -> Unit\npub fn fresh() -> Int32\npub struct Fresh { x : Int32 }",
    "0.2.0", "0.2.0", "none",
  )
  assert_eq(report.issues.length(), 0)
  assert_eq(report.counts.get("added"), Some(2))
  assert_eq(report.counts.get("exports_after"), Some(3))
}

///|
test "api gate free function and receiver removal retain independent namespaces" {
  let before = "pub fn same() -> Unit\npub fn A::same(Self) -> Unit\npub fn B::same(Self) -> Unit\npub type A"
  let after = "pub fn B::same(Self) -> Unit\npub type A"
  let report = api_gate_test_check(before, after, "0.2.0", "0.2.0", "none")
  assert_eq(report.counts.get("removed"), Some(2))
  assert_eq(report.counts.get("changed"), Some(0))
  assert_eq(report.issues.map(issue => issue.details.get("symbol").unwrap()), [
    "fn:A::same", "fn:same",
  ])
  assert_true(
    report.issues.all(issue => {
      issue.rule_id == "api/removed" && issue.severity == Severity::Error
    }),
  )
  assert_eq(report.issues[0].details.get("package"), Some("test/api"))
  assert_eq(report.issues[0].details.get("change"), Some("removed"))
  assert_eq(report.issues[0].details.get("before_line"), Some("3"))
  assert_eq(report.issues[0].details.get("after"), Some(""))
  assert_eq(report.issues[0].details.get("after_line"), None)
}

///|
test "api gate parameter label optional raise generic and return changes need review" {
  for
    (before, after) in [
      ("pub fn f(value~ : Int32) -> Unit", "pub fn f(other~ : Int32) -> Unit"),
      ("pub fn f(value~ : Int32) -> Unit", "pub fn f(value? : Int32) -> Unit"),
      ("pub fn f(Int32) -> Unit", "pub fn f(String) -> Unit"),
      ("pub fn f() -> Unit raise", "pub fn f() -> Unit"),
      ("pub fn f() -> Unit raise E", "pub fn f() -> Unit raise Other"),
      ("pub fn[T : Eq] f(T) -> T", "pub fn[T : Compare] f(T) -> T"),
      ("pub fn[T] f(T) -> T", "pub fn[T, U] f(T) -> T"),
      ("pub fn f() -> String", "pub fn f() -> Unit"),
      (
        "pub fn f((Int32) -> Unit raise?) -> Unit", "pub fn f((Int32) -> Unit) -> Unit",
      ),
    ] {
    let report = api_gate_test_check(before, after, "0.2.0", "0.2.0", "none")
    assert_eq(report.counts.get("changed"), Some(1))
    assert_eq(report.counts.get("removed"), Some(0))
    assert_eq(report.issues.length(), 1)
    assert_eq(report.issues[0].rule_id, "api/changed")
    assert_eq(report.issues[0].severity, Severity::Error)
    assert_eq(report.issues[0].details.get("symbol"), Some("fn:f"))
    assert_true(
      report.issues[0].details.get("before").unwrap() !=
      report.issues[0].details.get("after").unwrap(),
    )
    assert_eq(report.issues[0].details.get("after_line"), Some("2"))
  }
}

///|
test "api gate enum trait member additions and existing type shapes are reviewed" {
  for
    (before, after, symbol) in [
      (
        "pub(all) enum Choice { A }", "pub(all) enum Choice { A B }", "type:Choice",
      ),
      (
        "pub(open) trait Read { fn read(Self) -> String }", "pub(open) trait Read { fn read(Self) -> String; fn size(Self) -> Int32 }",
        "trait:Read",
      ),
      (
        "pub struct Row { value : Int32 }", "pub struct Row { value : String }",
        "type:Row",
      ),
      ("pub type Alias = Int32", "pub type Alias = String", "type:Alias"),
      (
        "pub suberror Failure { Bad(Int32) }", "pub suberror Failure { Bad(String) }",
        "type:Failure",
      ),
      (
        "pub impl[T : Eq] Eq for Box[T]", "pub impl[T : Compare] Eq for Box[T]",
        "impl:Eq for Box [ T ]",
      ),
    ] {
    let report = api_gate_test_check(before, after, "0.2.0", "0.2.0", "none")
    assert_eq(report.counts.get("changed"), Some(1))
    assert_eq(report.counts.get("added"), Some(0))
    assert_eq(report.issues[0].details.get("symbol"), Some(symbol))
  }
}

///|
test "api gate known callability attributes are compared but deprecation is cosmetic" {
  let changed = api_gate_test_check(
    "#alias(old, deprecated)\npub fn f() -> Unit", "pub fn f() -> Unit", "0.2.0",
    "0.2.0", "none",
  )
  assert_eq(changed.counts.get("changed"), Some(1))
  let unchanged = api_gate_test_check(
    "#deprecated(\"use new\")\npub fn f() -> Unit", "#doc(\"different docs\")\npub fn f() -> Unit",
    "0.2.0", "0.2.0", "none",
  )
  assert_eq(unchanged.issues.length(), 0)
}

///|
test "api gate import aliases reexports and qualified receiver names are grounded" {
  let before =
    #|import { "moonbitlang/core/debug", "vendor/pkg" as dep, }
    #|#deprecated
    #|pub using @dep { type Original as Alias, trait Read }
    #|pub fn @dep.Original::read(Self) -> @dep.Original
    #|pub fn[T : @debug.Debug] f(Array[(T, @dep.Original)], value? : String) -> (T, String?) raise?
    #|pub impl @debug.Debug for Alias
    #|pub fn &Read::read(Self) -> String
  let reordered = before
    .replace_all(old="as dep", new="as other")
    .replace_all(old="@dep", new="@other")
  let unchanged = api_gate_test_check(
    before, reordered, "0.2.0", "0.2.0", "none",
  )
  assert_eq(unchanged.issues.length(), 0)
  assert_eq(unchanged.counts.get("exports_before"), Some(6))
  let equivalent_alias = api_gate_test_check(
    "import { \"vendor/pkg\", }\npub using @pkg { type Original as Alias }", "import { \"vendor/pkg\", }\npub type Alias = @pkg.Original",
    "0.2.0", "0.2.0", "none",
  )
  assert_eq(equivalent_alias.issues.length(), 0)
  let rebound = before.replace_all(old="vendor/pkg", new="different/pkg")
  let changed = api_gate_test_check(before, rebound, "0.2.0", "0.2.0", "none")
  assert_true(changed.issues.length() > 0)
  assert_true(changed.counts.get("removed").unwrap() > 0)
}

///|
test "api gate historical 2891f1f same 0.2.0 removal regression uses fixtures" {
  // Reproduce the public surface removed by 2891f1f, not a git read at runtime.
  let before =
    #|pub enum ScanMode {
    #|  Tree
    #|  Incremental(String)
    #|  Staged
    #|} derive(Eq)
    #|#deprecated
    #|pub fn ScanMode::incremental(String) -> Self
    #|pub fn ScanMode::tree() -> Self
  let after =
    #|#derive(Eq)
    #|pub enum ScanMode { Tree Staged }
    #|pub fn ScanMode::tree() -> Self
  let report = api_gate_test_check(before, after, "0.2.0", "0.2.0", "none")
  assert_eq(report.counts.get("changed"), Some(1))
  assert_eq(report.counts.get("removed"), Some(1))
  assert_eq(report.issues.length(), 2)
  assert_eq(report.issues[0].details.get("symbol"), Some("type:ScanMode"))
  assert_eq(
    report.issues[1].details.get("symbol"),
    Some("fn:ScanMode::incremental"),
  )
  let semver = api_gate_test_check(before, after, "0.2.0", "0.2.0", "semver")
  assert_eq(semver.issues.length(), 3)
  assert_true(semver.issues.any(issue => issue.rule_id == "api/version-policy"))
}

///|
test "api gate metadata identity mismatch is inconclusive not clean" {
  let good = api_gate_test_snapshot("pub fn f() -> Unit", "0.2.0")
  for
    (field, value) in [
      ("toolchain", "another-build"),
      ("backend", "js"),
      ("package", "another/pkg"),
    ] {
    let bad = api_gate_test_mutate(good, field, Some(Json::string(value)))
    assert_true(check_api_snapshots(good, bad, "none") is Err(_))
  }
  let different_package = make_api_snapshot(
    "package \"different/pkg\"\npub fn f() -> Unit", "moon-0.9.1+exact", "native",
    "0.2.0",
  ).unwrap()
  assert_true(check_api_snapshots(good, different_package, "none") is Err(_))
}

///|
test "api gate snapshot unknown fields missing fields types versions duplicate keys fail" {
  let good = api_gate_test_snapshot("pub fn f() -> Unit", "0.2.0")
  assert_true(check_api_snapshots("not JSON", good, "none") is Err(_))
  assert_true(check_api_snapshots("[]", good, "none") is Err(_))
  for
    field in [
      "version", "package", "toolchain", "backend", "module_version", "interface",
    ] {
    assert_true(
      check_api_snapshots(good, api_gate_test_mutate(good, field, None), "none")
      is Err(_),
    )
    assert_true(
      check_api_snapshots(
        good,
        api_gate_test_mutate(good, field, Some(Json::array([]))),
        "none",
      )
      is Err(_),
    )
  }
  for
    version in [
      Json::number(2.0),
      Json::number(1.9),
      Json::number(1.0, repr="1.0"),
      Json::number(1.0, repr="1e0"),
      Json::string("1"),
    ] {
    assert_true(
      check_api_snapshots(
        good,
        api_gate_test_mutate(good, "version", Some(version)),
        "none",
      )
      is Err(_),
    )
  }
  assert_true(
    check_api_snapshots(
      good,
      api_gate_test_mutate(good, "extra", Some(Json::null())),
      "none",
    )
    is Err(_),
  )
  let duplicate = good.replace_all(
    old="\"version\": 1",
    new="\"version\": 1, \"version\": 1",
  )
  assert_true(check_api_snapshots(good, duplicate, "none") is Err(_))
  assert_true(
    check_api_snapshots(
      good,
      api_gate_test_mutate(good, "backend", Some(Json::string("unknown"))),
      "none",
    )
    is Err(_),
  )
}

///|
test "api gate unknown public syntax duplicates and malformed text are inconclusive" {
  let good = api_gate_test_snapshot("pub fn f() -> Unit", "0.2.0")
  for
    text in [
      "", "// only comments", "pub fn f() -> Unit", "package \"\"", "package test/api",
      "package \"test/api\"\npub extern fn f() -> Unit", "package \"test/api\"\n#doc(hidden)\npub extend X with Eq::{equal}",
      "package \"test/api\"\n#unknown\npub fn f() -> Unit", "package \"test/api\"\npub type Alias = Int32 | String",
      "package \"test/api\"\npub fn f(Int32) ->", "package \"test/api\"\npub fn f(Int32 -> Unit",
      "package \"test/api\"\npub fn f([Int32)) -> Unit", "package \"test/api\"\npub fn f() -> Unit {",
      "package \"test/api\"\npub fn f() -> Unit /* unclosed", "package \"test/api\"\npub const X : String = \"unclosed",
      "package \"test/api\"\npub fn f() -> Unit }", "package \"test/api\"\npub fn f() -> Unit\npub fn f(Int32) -> Unit",
      "package \"test/api\"\npub enum Choice { A A }", "package \"test/api\"\npub struct Row { x : Int32 x : String }",
      "package \"test/api\"\npub fn f(Array[]) -> Unit", "package \"test/api\"\npub fn[T,T] f(T) -> T",
      "package \"test/api\"\npub fn f(x~ : Int32, x? : Int32) -> Unit", "package \"test/api\"\npub fn f(@missing.T) -> Unit",
      "package \"test/api\"\npub let X : Int32 = make()", "package \"test/api\"\n#alias()\npub fn f() -> Unit",
      "package \"test/api\"\n#derive(Eq)",
    ] {
    assert_true(make_api_snapshot(text, "moon", "native", "0.2.0") is Err(_))
    let bad = api_gate_test_mutate(good, "interface", Some(Json::string(text)))
    assert_true(check_api_snapshots(good, bad, "none") is Err(_))
  }
}

///|
test "api gate semver stable and zero major sufficient versus insufficient bumps" {
  for
    (before, after, sufficient) in [
      ("1.2.3", "2.0.0", true),
      ("1.2.3", "1.3.0", false),
      ("1.2.3", "1.2.4", false),
      ("1.2.3", "1.2.3", false),
      ("1.2.3", "0.9.0", false),
      ("0.2.0", "0.3.0", true),
      ("0.2.0", "1.0.0", true),
      ("0.2.0", "0.2.1", false),
      ("0.2.0", "0.2.0", false),
      ("0.2.0", "0.1.9", false),
    ] {
    let report = api_gate_test_check(
      "pub fn gone() -> Unit", "", before, after, "semver",
    )
    assert_eq(report.counts.get("removed"), Some(1))
    assert_eq(
      report.issues[0].severity,
      if sufficient {
        Severity::Warning
      } else {
        Severity::Error
      },
    )
    assert_eq(
      report.issues.any(issue => issue.rule_id == "api/version-policy"),
      !sufficient,
    )
    assert_eq(report.has_errors(), !sufficient)
  }
  let no_inference = api_gate_test_check(
    "pub fn gone() -> Unit", "", "1.0.0", "2.0.0", "none",
  )
  assert_eq(no_inference.issues[0].severity, Severity::Error)
}

///|
test "api gate explicit semver rejects leading zeros overflow prerelease and build ambiguity" {
  let good = api_gate_test_snapshot("pub fn f() -> Unit", "0.2.0")
  for
    version in [
      "01.2.3", "1.02.3", "1.2.03", "1.2", "1..2", "1.2.3.4", " 1.2.3", "v1.2.3",
      "2147483648.0.0", "1.999999999999999999999999.0", "1.2.3-alpha.1", "1.2.3+build",
    ] {
    let bad = api_gate_test_snapshot("pub fn f() -> Unit", version)
    assert_true(check_api_snapshots(good, bad, "semver") is Err(_))
    assert_true(check_api_snapshots(bad, good, "semver") is Err(_))
    assert_true(check_api_snapshots(good, bad, "none") is Ok(_))
  }
  assert_true(check_api_snapshots(good, good, "unknown") is Err(_))
  assert_true(
    api_gate_parse_semver("2147483647.2147483647.2147483647") is Ok(_),
  )
  match api_gate_parse_semver("1.2.3-alpha") {
    Err(ConfigError(message)) =>
      assert_true(message.contains("cannot judge prerelease policy"))
    Ok(_) => abort("prerelease policy falsely accepted")
  }
}

///|
test "api gate compiler literal spellings and escaped delimiters are supported" {
  for
    literal in [
      "7", "1_000", "0xffUL", "0b1010", "0o17", "0x3.243F6A8885A308CA8A54", "1.5e-2F",
      "-3L",
    ] {
    let src = api_gate_test_snapshot(
      "pub const VALUE : Double = " + literal,
      "0.2.0",
    )
    assert_true(check_api_snapshots(src, src, "none") is Ok(_))
  }
  let escaped =
    #|pub const TEXT : String = "quote \" slash \\ unicode \u{1F600} byte \x41 /* } */"
    #|pub const LETTER : Char = '\u{41}'
  let src = api_gate_test_snapshot(escaped, "0.2.0")
  assert_true(check_api_snapshots(src, src, "none") is Ok(_))
}

///|
test "api gate malformed balanced literals and unsupported visibility fail closed" {
  for
    declaration in [
      "pub const VALUE : Int32 = 123bad", "pub const VALUE : Int32 = 0xg", "pub const VALUE : Double = 1.2.3",
      "pub const VALUE : Int32 = 1__2", "pub const VALUE : Int32 = 1_", "pub const VALUE : Double = 1e+",
      "pub const VALUE : String = -\"x\"", "pub const VALUE : Char = 'abc'", "pub const VALUE : String = \"bad\\q\"",
      "pub const VALUE : String = \"bad\\u{}\"", "pub const VALUE : String = \"bad\\u{110000}\"",
      "pub const VALUE : String = \"bad\\\nnewline\"", "pub(all) fn f() -> Unit",
      "pub(open) type Bad", "pub(open) trait Read { fn read(Self) -> Unit; fn read(Self) -> String }",
      "import { \"one/pkg\", \"two/pkg\", }\npub fn f() -> Unit",
    ] {
    assert_true(
      make_api_snapshot(
        "package \"test/api\"\n" + declaration,
        "moon",
        "native",
        "0.2.0",
      )
      is Err(_),
    )
  }
}

///|
test "api gate findings are deterministic across declaration ordering" {
  let before = "pub fn z() -> Unit\npub fn b(Int32) -> Unit\npub fn a() -> Unit"
  let after = "pub fn b(String) -> Unit"
  let first = api_gate_test_check(before, after, "0.2.0", "0.2.0", "none")
  let second = api_gate_test_check(
    "pub fn a() -> Unit\npub fn b(Int32) -> Unit\npub fn z() -> Unit", after, "0.2.0",
    "0.2.0", "none",
  )
  let keys = first.issues.map(issue => {
    issue.rule_id + ":" + issue.details.get("symbol").unwrap()
  })
  assert_eq(keys, ["api/changed:fn:b", "api/removed:fn:a", "api/removed:fn:z"])
  assert_eq(
    keys,
    second.issues.map(issue => {
      issue.rule_id + ":" + issue.details.get("symbol").unwrap()
    }),
  )
}
