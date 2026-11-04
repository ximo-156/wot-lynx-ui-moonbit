///|
/// File selection. Git modes read immutable HEAD/index contents in the engine.
#derive(Debug, Eq)
pub enum ScanMode {
  Tree
  Changed(String)
  Staged
  Glob(String)
  Stdin
  Stdin0
}

///|
/// Select the working-tree directory recursively under the common path filters.
pub fn ScanMode::tree() -> ScanMode {
  Tree
}

///|
/// Select committed changes since merge-base(git_ref, HEAD); the engine reads captured HEAD blobs.
pub fn ScanMode::changed(git_ref : String) -> ScanMode {
  Changed(git_ref)
}

///|
/// Select index changes; the engine captures index blob ids and ignores unstaged source text.
pub fn ScanMode::staged() -> ScanMode {
  Staged
}

///|
/// Select working-tree paths matching one root-relative glob, validated during selection.
pub fn ScanMode::glob(pattern : String) -> ScanMode {
  Glob(pattern)
}

///|
/// Read newline-delimited working-tree paths from standard input.
pub fn ScanMode::stdin() -> ScanMode {
  Stdin
}

///|
/// Read NUL-delimited working-tree paths, including names containing newlines.
pub fn ScanMode::stdin0() -> ScanMode {
  Stdin0
}

///|
/// Return the stable lowercase scan-mode name used in machine reports.
pub fn ScanMode::tag(self : ScanMode) -> String {
  match self {
    Tree => "tree"
    Changed(_) => "changed"
    Staged => "staged"
    Glob(_) => "glob"
    Stdin => "stdin"
    Stdin0 => "stdin0"
  }
}

///|
/// One selection contract across all modes: root-relative, deduplicated,
/// sorted, with the same extension/noise filtering. Failures never fall back
/// to a successful empty scan. Empty extension filters select all candidates.
pub fn select_files(
  mode : ScanMode,
  root : String,
  exts : Array[String],
) -> Array[String] raise {
  let absolute = canonical_root(root)
  let files = match mode {
    Tree => walk_files(absolute, exts)
    Changed(ref_) => git_changed_files(absolute, ref_)
    Staged => git_staged_files(absolute)
    Glob(pattern) => {
      validate_glob(pattern)
      let matcher = GlobPattern::new(pattern)
      walk_files(absolute, exts).filter(f => matcher.matches(f))
    }
    Stdin => parse_stdin_paths(read_stdin_text(), false)
    Stdin0 => parse_stdin_paths(read_stdin_text(), true)
  }
  let wanted = Set::from_iter(exts.iter().map(e => e.to_lower()))
  let seen : Set[String] = Set::from_iter([].iter())
  let selected : Array[String] = []
  for path in files {
    let rel = normalize_relative(path)
    if !path_is_noise(rel) && has_wanted_ext(rel, wanted) && !seen.contains(rel) {
      seen.add(rel)
      selected.push(rel)
    }
  }
  selected.sort()
  selected
}

///|
/// Newlines delimit --stdin; NUL delimiters in --stdin0 preserve embedded
/// newlines. Only CRLF's terminal CR is removed; no filename is trim()ed.
fn parse_stdin_paths(content : String, nul : Bool) -> Array[String] raise {
  if !nul && content.contains("\u{0}") {
    raise Failure("NUL in --stdin input; use --stdin0 for NUL-separated paths")
  }
  let paths : Array[String] = []
  let delimiter = if nul { "\u{0}" } else { "\n" }
  for view in content.split(delimiter) {
    let path = if nul {
      view.to_owned()
    } else {
      trim_end_char(view.to_owned(), '\r')
    }
    if path != "" {
      paths.push(normalize_relative(path))
    }
  }
  paths
}

///|
/// The supported portable subset is literal segments, *, ?, and standalone **.
/// Reject unsupported syntax instead of silently interpreting it differently.
pub fn validate_glob(pattern : String) -> Unit raise {
  match glob_pattern_error(pattern) {
    Some(message) => raise Failure(message)
    None => ()
  }
}

///|
/// Validate a glob pattern and return the reason it is invalid, or `None`
/// when the pattern is well-formed.
pub fn glob_pattern_error(pattern : String) -> String? {
  if pattern == "" || pattern.has_prefix("/") || pattern.contains("\u{0}") {
    return Some("glob must be non-empty and relative to the scan root")
  }
  for c in pattern.iter() {
    if c == '[' || c == ']' || c == '{' || c == '}' || c == '\\' || c == '!' {
      return Some(
        "unsupported glob syntax; supported: literals, *, ?, and ** path segments",
      )
    }
  }
  for segment in pattern.split("/") {
    if segment == ".." || segment == "." || segment == "" {
      return Some("glob may not contain empty, . or .. path segments")
    }
    if segment.contains("**") && segment != "**" {
      return Some("** must occupy an entire glob path segment")
    }
  }
  None
}

///|
/// Match path segments separately: ** means zero or more complete segments,
/// never part of a filename. Dynamic programming avoids exponential backtracking.
#derive(Debug, Eq)
pub struct GlobPattern {
  segments : Array[String]
}

///|
/// Split an already validated root-relative glob into path segments; call validate_glob for untrusted input.
pub fn GlobPattern::new(pattern : String) -> GlobPattern {
  { segments: pattern.split("/").map(v => v.to_owned()).to_array(), }
}

///|
/// Match a root-relative path, treating a matched directory as covering
/// everything below it. `vendor` therefore matches `vendor/pkg/index.ts`
/// while still not matching `vendorless/index.ts`.
pub fn GlobPattern::matches_path(self : GlobPattern, path : String) -> Bool {
  if self.matches(path) {
    return true
  }
  let parts = path.split("/").map(v => v.to_owned()).to_array()
  let mut prefix = ""
  for i in 0..<(parts.length() - 1) {
    prefix = if prefix == "" { parts[i] } else { "\{prefix}/\{parts[i]}" }
    if self.matches(prefix) {
      return true
    }
  }
  false
}

///|
/// Match the entire relative path; unlike matches_path, a directory match does not cover descendants.
pub fn GlobPattern::matches(self : GlobPattern, path : String) -> Bool {
  let parts = path.split("/").map(v => v.to_owned()).to_array()
  let mut previous : Array[Bool] = Array::make(parts.length() + 1, false)
  previous[0] = true
  for segment in self.segments {
    let current : Array[Bool] = Array::make(parts.length() + 1, false)
    if segment == "**" {
      current[0] = previous[0]
      for j in 1..<=parts.length() {
        current[j] = previous[j] || current[j - 1]
      }
    } else {
      for j in 1..<=parts.length() {
        current[j] = previous[j - 1] &&
          glob_segment_matches(segment, parts[j - 1])
      }
    }
    previous = current
  }
  previous[parts.length()]
}

///|
fn glob_segment_matches(pattern : String, value : String) -> Bool {
  let chars = value.to_array()
  let mut previous : Array[Bool] = Array::make(chars.length() + 1, false)
  previous[0] = true
  for c in pattern.iter() {
    let current : Array[Bool] = Array::make(chars.length() + 1, false)
    if c == '*' {
      current[0] = previous[0]
      for j in 1..<=chars.length() {
        current[j] = previous[j] || current[j - 1]
      }
    } else {
      for j in 1..<=chars.length() {
        current[j] = previous[j - 1] && (c == '?' || c == chars[j - 1])
      }
    }
    previous = current
  }
  previous[chars.length()]
}

///|
/// Expose derived impls as regular methods for external callers.

///|
pub extend ScanMode with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend ScanMode with Eq::{equal, not_equal}

///|
pub extend GlobPattern with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend GlobPattern with Eq::{equal, not_equal}
