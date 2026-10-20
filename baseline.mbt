///|
/// Baseline support: exempt known findings so an existing codebase can adopt
/// the linter incrementally.
///
/// A baseline is a JSON array of finding hashes. A finding is suppressed when
/// its hash is present. The hash covers the rule id, file, line, and snippet
/// — so editing the offending line re-arms the finding, but moving unrelated
/// code around does not.
///
/// This mirrors the `review-lint.baseline.json` mechanism in `wot-lynx-ui`.

///|
/// Compute the stable hash key for a finding.
///
/// The key is a hex digest of `rule_id|file|line|snippet`. We use a simple
/// FNV-1a hash rather than a cryptographic hash: the baseline only needs
/// collision resistance against accidental edits, not against adversaries,
/// and this keeps the dependency surface at zero.
pub fn finding_hash(f : Finding) -> String {
  let input = "\{f.rule_id}|\{f.file}|\{f.line}|\{f.snippet}"
  fnv1a_hex(input)
}

///|
/// FNV-1a 64-bit hash, rendered as 16 lowercase hex digits.
fn fnv1a_hex(input : String) -> String {
  let mut hash : UInt64 = 0xcbf29ce484222325
  let prime : UInt64 = 0x100000001b3
  for byte in input.iter().map(c => c.to_int().to_uint64()) {
    hash = hash ^ byte
    hash = hash * prime
  }
  hash.to_string(radix=16).pad_start(16, '0')
}

///|
/// A baseline: a set of exempted finding hashes.
pub struct Baseline {
  hashes : Set[String]
}

///|
/// Load a baseline from its JSON array text. An empty or invalid file yields
/// an empty baseline (adopting the linter should never hard-fail on a stale
/// baseline).
pub fn Baseline::load(src : String) -> Baseline {
  let hashes : Set[String] = Set::new()
  let json = @json.parse(src) catch { _ => return { hashes, } }
  let arr = match json.as_array() {
    Some(a) => a
    None => return { hashes, }
  }
  for item in arr {
    match item.as_string() {
      Some(s) => hashes.add(s)
      None => ()
    }
  }
  { hashes, }
}

///|
/// Whether a finding is exempted by this baseline.
pub fn Baseline::contains(self : Baseline, f : Finding) -> Bool {
  self.hashes.contains(finding_hash(f))
}

///|
/// Split findings into (kept, suppressed) using this baseline.
pub fn Baseline::partition(
  self : Baseline,
  findings : Array[Finding],
) -> (Array[Finding], Array[Finding]) {
  let kept : Array[Finding] = []
  let suppressed : Array[Finding] = []
  for f in findings {
    if self.contains(f) {
      suppressed.push(f)
    } else {
      kept.push(f)
    }
  }
  (kept, suppressed)
}

///|
/// Render a baseline file (sorted JSON array of hashes) from findings.
pub fn Baseline::render(findings : Array[Finding]) -> String {
  let hashes : Array[String] = []
  for f in findings {
    hashes.push(finding_hash(f))
  }
  hashes.sort()
  let items = hashes.map(h => "  \"\{h}\"").join(",\n")
  "[\n\{items}\n]"
}
