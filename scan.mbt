///|
/// File selection strategies for different scanning modes.
///
/// Each mode produces a list of file paths (relative to the scan root) to
/// lint. The default mode is `Tree`, which walks the directory recursively.
/// Other modes select a subset of files based on git state, glob patterns,
/// stdin input, or incremental caching.

///|
/// How to select files for scanning.
pub enum ScanMode {
  /// Walk the directory tree recursively (default).
  Tree
  /// Only files changed since a git ref.
  Changed(String)
  /// Only staged files (git diff --cached).
  Staged
  /// Files matching a glob pattern.
  Glob(String)
  /// File paths read from stdin, one per line.
  Stdin
  /// Tree walk, but skip files whose content hash matches the cache.
  Incremental
} derive(Debug, Eq)

///|
/// Convenience constructors (pub so external packages can build values).
pub fn ScanMode::tree() -> ScanMode {
  Tree
}

///|
pub fn ScanMode::changed(git_ref : String) -> ScanMode {
  Changed(git_ref)
}

///|
pub fn ScanMode::staged() -> ScanMode {
  Staged
}

///|
pub fn ScanMode::glob(pattern : String) -> ScanMode {
  Glob(pattern)
}

///|
pub fn ScanMode::stdin() -> ScanMode {
  Stdin
}

///|
pub fn ScanMode::incremental() -> ScanMode {
  Incremental
}

///|
/// Select files to scan based on the scan mode.
///
/// Returns paths relative to `root`. For `Tree` and `Incremental` modes,
/// `exts` filters by extension. For git-based modes, all returned files
/// are included regardless of extension (the caller filters).
pub fn select_files(
  mode : ScanMode,
  root : String,
  exts : Array[String],
) -> Array[String] raise {
  match mode {
    Tree => walk_files(root, exts)
    Changed(git_ref) =>
      match git_changed_files(root, git_ref) {
        Some(files) => files
        None => walk_files(root, exts)
      }
    Staged =>
      match git_staged_files(root) {
        Some(files) => files
        None => walk_files(root, exts)
      }
    Glob(pattern) => glob_files(root, pattern)
    Stdin => read_stdin_paths()
    Incremental => walk_files(root, exts)
  }
}

///|
/// Simple glob matching: supports `*` (any chars except `/`) and `**`
/// (any chars including `/`). Returns files under `root` matching the pattern.
fn glob_files(root : String, pattern : String) -> Array[String] raise {
  let all = walk_files(root, [])
  let matcher = GlobPattern::new(pattern)
  all.filter(f => matcher.matches(f))
}

///|
/// Read file paths from stdin, one per line.
fn read_stdin_paths() -> Array[String] {
  let paths : Array[String] = []
  let stdin_path = "/dev/stdin"
  let content = @fs.read_file_to_string(stdin_path) catch { _ => "" }
  for line in content.split("\n") {
    let trimmed = line.trim().to_owned()
    if trimmed.length() > 0 {
      paths.push(trimmed)
    }
  }
  paths
}

///|
/// A simple glob pattern matcher.
///
/// Supports:
/// - `*` — matches any sequence of characters except `/`
/// - `**` — matches any sequence of characters including `/`
/// - `?` — matches any single character except `/`
/// - Literal characters match themselves
struct GlobPattern {
  segments : Array[GlobSegment]
} derive(Debug)

///|
/// A segment of a glob pattern.
enum GlobSegment {
  Literal(String)
  Star
  DoubleStar
  AnyChar
} derive(Debug, Eq)

///|
/// Create a glob pattern from a string.
pub fn GlobPattern::new(pattern : String) -> GlobPattern {
  let segments : Array[GlobSegment] = []
  let chars = pattern.to_array()
  let mut i = 0
  let mut literal = ""
  while i < chars.length() {
    let c = chars.unsafe_get(i)
    match c {
      '*' =>
        if i + 1 < chars.length() && chars.unsafe_get(i + 1) == '*' {
          if literal.length() > 0 {
            segments.push(Literal(literal))
            literal = ""
          }
          segments.push(DoubleStar)
          i += 2
          if i < chars.length() && chars.unsafe_get(i) == '/' {
            i += 1
          }
        } else {
          if literal.length() > 0 {
            segments.push(Literal(literal))
            literal = ""
          }
          segments.push(Star)
          i += 1
        }
      _ if c == '?' => {
        if literal.length() > 0 {
          segments.push(Literal(literal))
          literal = ""
        }
        segments.push(AnyChar)
        i += 1
      }
      _ => {
        literal = literal + c.to_string()
        i += 1
      }
    }
  }
  if literal.length() > 0 {
    segments.push(Literal(literal))
  }
  { segments, }
}

///|
/// Match a path against this glob pattern.
pub fn GlobPattern::matches(self : GlobPattern, path : String) -> Bool {
  glob_match(self.segments, 0, path.to_array(), 0)
}

///|
/// Recursive glob matching helper operating on a char array.
fn glob_match(
  segments : Array[GlobSegment],
  seg_idx : Int32,
  path : Array[Char],
  pos : Int32,
) -> Bool {
  if seg_idx >= segments.length() {
    return pos >= path.length()
  }
  let seg = segments.unsafe_get(seg_idx)
  match seg {
    Literal(s) => {
      let s_chars = s.to_array()
      if pos + s_chars.length() <= path.length() {
        let mut ok = true
        for k in 0..<s_chars.length() {
          if path.unsafe_get(pos + k) != s_chars.unsafe_get(k) {
            ok = false
            break
          }
        }
        if ok {
          glob_match(segments, seg_idx + 1, path, pos + s_chars.length())
        } else {
          false
        }
      } else {
        false
      }
    }
    Star => {
      let mut end = pos
      while end < path.length() && path.unsafe_get(end) != '/' {
        end += 1
      }
      for len in 0..<=(end - pos) {
        if glob_match(segments, seg_idx + 1, path, pos + len) {
          return true
        }
      }
      false
    }
    DoubleStar => {
      for len in 0..<=(path.length() - pos) {
        if glob_match(segments, seg_idx + 1, path, pos + len) {
          return true
        }
      }
      false
    }
    AnyChar =>
      if pos < path.length() && path.unsafe_get(pos) != '/' {
        glob_match(segments, seg_idx + 1, path, pos + 1)
      } else {
        false
      }
  }
}
