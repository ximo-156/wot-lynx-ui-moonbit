///|
/// Tests for the baseline module.

///|
fn make_finding(rule_id : String, file : String, line : Int32) -> Finding {
  Finding::{
    rule_id,
    severity: Severity::error(),
    message: "test message",
    file,
    line,
    snippet: "some code",
  }
}

///|
test "finding_hash is stable" {
  let f = make_finding("r1", "a.ts", 10)
  let h1 = finding_hash(f)
  let h2 = finding_hash(make_finding("r1", "a.ts", 10))
  assert_eq(h1, h2)
}

///|
test "finding_hash differs for different findings" {
  let h1 = finding_hash(make_finding("r1", "a.ts", 10))
  let h2 = finding_hash(make_finding("r1", "a.ts", 11))
  assert_true(h1 != h2)
}

///|
test "baseline load and contains" {
  let f = make_finding("r1", "a.ts", 10)
  let hash = finding_hash(f)
  let json = "[\"\{hash}\"]"
  let bl = Baseline::load(json)
  assert_true(bl.contains(f))
}

///|
test "baseline partition splits findings" {
  let f1 = make_finding("r1", "a.ts", 10)
  let f2 = make_finding("r2", "b.ts", 20)
  let hash = finding_hash(f1)
  let json = "[\"\{hash}\"]"
  let bl = Baseline::load(json)
  let (kept, suppressed) = bl.partition([f1, f2])
  assert_eq(kept.length(), 1)
  assert_eq(suppressed.length(), 1)
  assert_eq(kept[0].rule_id, "r2")
}

///|
test "baseline render produces sorted json" {
  let f1 = make_finding("r1", "a.ts", 10)
  let f2 = make_finding("r2", "b.ts", 20)
  let rendered = Baseline::render([f2, f1])
  assert_true(rendered.starts_with("["))
  assert_true(rendered.ends_with("]"))
}

///|
test "empty baseline suppresses nothing" {
  let bl = Baseline::load("[]")
  let f = make_finding("r1", "a.ts", 10)
  assert_false(bl.contains(f))
}

///|
test "invalid baseline json yields empty baseline" {
  let bl = Baseline::load("not json")
  let f = make_finding("r1", "a.ts", 10)
  assert_false(bl.contains(f))
}
