///|
/// File selection. Git modes read immutable HEAD/index contents in the engine.
pub enum ScanMode {
  Tree
  Changed(String)
  Staged
  Glob(String)
  Stdin
  Stdin0
  /// Kept for source compatibility; selecting it raises an explicit error.
  Incremental
} derive(Debug, Eq)

///|
pub fn ScanMode::tree() -> ScanMode { Tree }

///|
pub fn ScanMode::changed(git_ref : String) -> ScanMode { Changed(git_ref) }

///|
pub fn ScanMode::staged() -> ScanMode { Staged }

///|
pub fn ScanMode::glob(pattern : String) -> ScanMode { Glob(pattern) }

///|
pub fn ScanMode::stdin() -> ScanMode { Stdin }

///|
pub fn ScanMode::stdin0() -> ScanMode { Stdin0 }

///|
#deprecated("incremental caching is not implemented; this mode now raises an error")
pub fn ScanMode::incremental() -> ScanMode { Incremental }

///|
pub fn ScanMode::tag(self : ScanMode) -> String {
  match self {
    Tree => "tree"
    Changed(_) => "changed"
    Staged => "staged"
    Glob(_) => "glob"
    Stdin => "stdin"
    Stdin0 => "stdin0"
    Incremental => "incremental"
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
    Incremental => raise Failure("incremental caching is not implemented")
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
  if !nul && content.contains("\x00") {
    raise Failure("NUL in --stdin input; use --stdin0 for NUL-separated paths")
  }
  let paths : Array[String] = []
  let delimiter = if nul { "\x00" } else { "\n" }
  for view in content.split(delimiter) {
    let path = if nul { view.to_owned() } else { trim_end_char(view.to_owned(), '\r') }
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
  if pattern == "" || pattern.has_prefix("/") || pattern.contains("\x00") {
    raise Failure("glob must be non-empty and relative to the scan root")
  }
  for c in pattern.iter() {
    if c == '[' || c == ']' || c == '{' || c == '}' || c == '\\' || c == '!' {
      raise Failure("unsupported glob syntax; supported: literals, *, ?, and ** path segments")
    }
  }
  for segment in pattern.split("/") {
    if segment == ".." || segment == "." || segment == "" {
      raise Failure("glob may not contain empty, . or .. path segments")
    }
    if segment.contains("**") && segment != "**" {
      raise Failure("** must occupy an entire glob path segment")
    }
  }
}

///|
/// Match path segments separately: ** means zero or more complete segments,
/// never part of a filename. Dynamic programming avoids exponential backtracking.
struct GlobPattern {
  segments : Array[String]
}

///|
pub fn GlobPattern::new(pattern : String) -> GlobPattern {
  { segments: pattern.split("/").map(v => v.to_owned()).to_array() }
}

///|
pub fn GlobPattern::matches(self : GlobPattern, path : String) -> Bool {
  let parts = path.split("/").map(v => v.to_owned()).to_array()
  let mut previous : Array[Bool] = Array::make(parts.length() + 1, false)
  previous[0] = true
  for segment in self.segments {
    let current : Array[Bool] = Array::make(parts.length() + 1, false)
    if segment == "**" {
      current[0] = previous[0]
      for j in 1..=parts.length() {
        current[j] = previous[j] || current[j - 1]
      }
    } else {
      for j in 1..=parts.length() {
        current[j] = previous[j - 1] && glob_segment_matches(segment, parts[j - 1])
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
      for j in 1..=chars.length() {
        current[j] = previous[j] || current[j - 1]
      }
    } else {
      for j in 1..=chars.length() {
        current[j] = previous[j - 1] && (c == '?' || c == chars[j - 1])
      }
    }
    previous = current
  }
  previous[chars.length()]
}
