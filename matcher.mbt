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
    Equals(s) => line.trim().to_owned() == s
    Word(w) => word_matches(w, line)
  }
}

///|
/// Test whether `line` contains `word` as a whole word — bounded by
/// non-alphanumeric characters (or string boundaries) on both sides.
fn word_matches(word : String, line : String) -> Bool {
  if word == "" {
    return false
  }
  let line_chars = line.to_array()
  let word_chars = word.to_array()
  let wlen = word_chars.length()
  let llen = line_chars.length()
  if wlen > llen {
    return false
  }
  for start in 0..<=(llen - wlen) {
    // Check if word matches at this position
    let mut matches = true
    for i in 0..<wlen {
      if line_chars[start + i] != word_chars[i] {
        matches = false
        break
      }
    }
    if matches {
      // Check left boundary
      let left_ok = start == 0 || !is_word_char(line_chars[start - 1])
      // Check right boundary
      let right_ok = start + wlen == llen ||
        !is_word_char(line_chars[start + wlen])
      if left_ok && right_ok {
        return true
      }
    }
  }
  false
}

///|
/// Whether a character is a word character (alphanumeric or underscore).
fn is_word_char(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '_'
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
