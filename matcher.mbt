///|
/// Matcher evaluation.
///
/// `MatchKind::matches` answers "does this line match?". The `Regex` variant
/// compiles the pattern on demand; an invalid pattern is treated as a
/// non-match rather than aborting the whole run (config validation reports
/// bad patterns up front — see `config.mbt`).

///|
/// A matcher prepared for repeated evaluation against many lines.
///
/// `Regex` compiles its pattern once here instead of once per line: a single
/// rule evaluated over an N-line file previously cost N regex compilations,
/// which dominates scan time. A pattern that fails to compile becomes
/// `Prep::NeverMatch`, so a bad pattern yields no findings rather than
/// aborting (config validation reports bad patterns up front).
///
/// The combinator variants (`AllOf` / `AnyOf` / `NotOf`) hold their
/// sub-matchers in prepared form too, so a nested `Regex` is likewise
/// compiled once and shared across every line.
pub enum Prepared {
  NeverMatch
  Plain(MatchKind)
  Compiled(Regex)
  AllOf(Array[Prepared])
  AnyOf(Array[Prepared])
  NotOf(Prepared)
}

///|
/// Compile this matcher once for reuse across all lines of a file.
pub fn MatchKind::prepare(self : MatchKind) -> Prepared {
  match self {
    Regex(pattern) =>
      match compile_regex(pattern) {
        Some(re) => Compiled(re)
        None => NeverMatch
      }
    All(subs) => {
      let prepared = subs.map(s => s.prepare())
      // An `all` with any never-matching child can never fire.
      if prepared.any(p => p is NeverMatch) {
        NeverMatch
      } else {
        AllOf(prepared)
      }
    }
    Any(subs) =>
      // An empty `any` matches nothing; keep the prepared children otherwise.
      if subs.is_empty() {
        NeverMatch
      } else {
        AnyOf(subs.map(s => s.prepare()))
      }
    Not(sub) => NotOf(sub.prepare())
    other => Plain(other)
  }
}

///|
/// Test a prepared matcher against one line.
pub fn Prepared::matches(self : Prepared, line : StringView) -> Bool {
  match self {
    NeverMatch => false
    Plain(kind) => kind.matches(line.to_owned())
    Compiled(re) => re.find(line).next().is_some()
    AllOf(subs) => subs.all(p => p.matches(line))
    AnyOf(subs) => subs.any(p => p.matches(line))
    NotOf(p) => not(p.matches(line))
  }
}

///|
/// Compile a pattern, returning `None` instead of raising on a bad pattern.
fn compile_regex(pattern : String) -> Regex? {
  try Regex::Regex(pattern) catch {
    _ => None
  } noraise {
    re => Some(re)
  }
}

///|
/// Test whether a single line matches this matcher. Combinators evaluate
/// recursively: `All` is conjunction, `Any` disjunction, `Not` negation.
pub fn MatchKind::matches(self : MatchKind, line : String) -> Bool {
  match self {
    Contains(s) => line.contains(s)
    HasPrefix(s) => line.has_prefix(s)
    HasSuffix(s) => line.has_suffix(s)
    Regex(pattern) => regex_matches(pattern, line)
    Equals(s) => line.trim().to_owned() == s
    Word(w) => word_matches(w, line)
    All(subs) => subs.all(m => m.matches(line))
    Any(subs) => subs.any(m => m.matches(line))
    Not(sub) => not(sub.matches(line))
  }
}

///|
/// 1-based column of the first match of this matcher on `line`.
///
/// A matcher only reports "this line matches", so the column is the position
/// of the first occurrence of the pattern text the matcher was built from.
/// `Regex` and `Word` fall back to the first non-space character, because
/// their match position is not recoverable from the pattern alone. The
/// combinators report the column of the first sub-matcher that actually
/// matches on the line (`Not` has no positive pattern, so it always falls
/// back to the first non-space character).
pub fn MatchKind::column_of(self : MatchKind, line : String) -> Int32 {
  match self {
    Contains(s) => first_column_of(line, s)
    HasPrefix(s) => first_column_of(line, s)
    HasSuffix(s) => trailing_column_of(line, s)
    Equals(s) => {
      ignore(s)
      first_column_of(line, "")
    }
    Regex(_) => first_column_of(line, "")
    Word(w) => first_column_of(line, w)
    All(subs) | Any(subs) => {
      for sub in subs {
        if sub.matches(line) {
          return sub.column_of(line)
        }
      }
      first_column_of(line, "")
    }
    Not(_) => first_column_of(line, "")
  }
}

///|
/// Convert a 0-based array index into a 1-based column number.
fn col_after(index : Int32) -> Int32 {
  let mut col : Int32 = 1
  let mut k = 0
  while k < index {
    col += 1
    k += 1
  }
  col
}

///|
/// 1-based column where `needle` first appears in `line`, counting characters
/// rather than bytes. An empty or absent needle reports the first non-space
/// character, so a line-only matcher still points somewhere useful.
fn first_column_of(line : String, needle : String) -> Int32 {
  let chars = line.to_array()
  let n = needle.to_array()
  let hlen = chars.length()
  let nlen = n.length()
  if nlen > 0 && nlen <= hlen {
    for start in 0..<=(hlen - nlen) {
      let mut hit = true
      for i in 0..<nlen {
        if chars[start + i] != n[i] {
          hit = false
          break
        }
      }
      if hit {
        return col_after(start)
      }
    }
  }
  let mut col = 0
  while col < hlen && (chars[col] == ' ' || chars[col] == '\u{9}') {
    col += 1
  }
  col_after(col)
}

///|
/// 1-based column where `suffix` starts in `line`, or the first non-space
/// character when the suffix is not a strict ending of the line.
fn trailing_column_of(line : String, suffix : String) -> Int32 {
  let chars = line.to_array()
  let n = suffix.to_array()
  if n.length() > 0 && n.length() <= chars.length() {
    let start = chars.length() - n.length()
    let mut hit = true
    for i in 0..<n.length() {
      if chars[start + i] != n[i] {
        hit = false
        break
      }
    }
    if hit {
      return col_after(start)
    }
  }
  first_column_of(line, "")
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
/// Combinators are validated depth-first, so a bad pattern nested inside
/// `all` / `any` / `not` is still reported before scanning begins.
pub fn MatchKind::validate(self : MatchKind) -> String? {
  match self {
    Regex(pattern) =>
      try Regex::Regex(pattern) catch {
        _ => Some("invalid regex: \{pattern}")
      } noraise {
        _ => None
      }
    All(subs) | Any(subs) => first_invalid(subs)
    Not(sub) => sub.validate()
    _ => None
  }
}

///|
/// First validation error among `subs`, or `None` when all are well-formed.
fn first_invalid(subs : Array[MatchKind]) -> String? {
  for sub in subs {
    match sub.validate() {
      Some(err) => return Some(err)
      None => ()
    }
  }
  None
}
