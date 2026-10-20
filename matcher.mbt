///|
/// Matcher evaluation.
///
/// `MatchKind::matches` answers "does this line match?". The `Regex` variant
/// compiles the pattern on demand; an invalid pattern is treated as a
/// non-match rather than aborting the whole run (config validation reports
/// bad patterns up front — see `config.mbt`).

///|
/// Test whether a single line matches this matcher.
pub fn MatchKind::matches(self : MatchKind, line : String) -> Bool {
  match self {
    Contains(s) => line.contains(s)
    HasPrefix(s) => line.has_prefix(s)
    HasSuffix(s) => line.has_suffix(s)
    Regex(pattern) => regex_matches(pattern, line)
  }
}

///|
/// Compile-and-run a regex against a line, returning `false` on any compile
/// error. Used at match time; `validate` surfaces bad patterns before
/// scanning begins.
fn regex_matches(pattern : String, line : String) -> Bool {
  let re = Regex::Regex(pattern) catch { _ => return false }
  // `find` yields every match; a non-empty iterator means the line matched.
  re.find(line).next().is_some()
}

///|
/// Validate that a matcher's regex (if any) compiles. Returns an error
/// message string on failure, or `None` when the matcher is well-formed.
pub fn MatchKind::validate(self : MatchKind) -> String? {
  match self {
    Regex(pattern) =>
      try Regex::Regex(pattern) catch {
        _ => Some("invalid regex: \{pattern}")
      } noraise {
        _ => None
      }
    _ => None
  }
}
