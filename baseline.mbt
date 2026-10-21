///|
/// Baseline support. Legacy array keys are line-sensitive: moving a finding
/// changes its key. This format is retained for backwards compatibility; a
/// future line-stable fingerprint must use an explicit version and migration.

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
  let hashes : Set[String] = Set([])
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
/// Strict loader used by the CLI. A corrupt or misspecified baseline is an
/// operational error, not an empty exemption list.
pub fn Baseline::parse(src : String) -> Baseline raise {
  let json = @json.parse(src) catch {
    _ => raise Failure("baseline is not valid JSON")
  }
  let values = match json {
    Array(values) => values
    _ => raise Failure("baseline must be a JSON array of finding hashes")
  }
  let hashes : Set[String] = Set::from_iter([].iter())
  for value in values {
    match value {
      String(hash) => {
        if hash.length() != 16 ||
          !hash
          .iter()
          .all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
          raise Failure("baseline hashes must be 16 lowercase hex characters")
        }
        hashes.add(hash)
      }
      _ => raise Failure("baseline entries must be hash strings")
    }
  }
  { hashes, }
}

///|
/// Render a stable, deduplicated legacy baseline from all raw findings.
pub fn Baseline::render(findings : Array[Finding]) -> String {
  let unique : Set[String] = Set::from_iter(
    findings.iter().map(f => finding_hash(f)),
  )
  let hashes = unique.iter().to_array()
  hashes.sort()
  let items = hashes.map(h => "  \"\{h}\"").join(",\n")
  "[\n\{items}\n]\n"
}
