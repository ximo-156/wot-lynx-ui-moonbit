///|
/// Source scanning utilities.
///
/// Two responsibilities:
/// 1. `strip_comments` blanks out `//` and `/* */` comments while preserving
///    every character's position, so line numbers and column offsets reported
///    in findings still point at the real source.
/// 2. `walk_files` enumerates source files under a directory, skipping
///    noise directories (`.git`, `node_modules`, build output, ...).

///|
/// Directories skipped during a tree walk.
fn skip_dirs() -> Set[String] {
  Set::from_iter(
    [
      ".git", "node_modules", "dist", "target", "_build", ".mooncakes", "coverage",
    ].iter(),
  )
}

///|
/// Replace comment characters with spaces, preserving length and newlines.
///
/// Handles `//` line comments and `/* ... */` block comments (including
/// unterminated blocks, which run to end of input). String literals are not
/// tracked, matching the behaviour of the original JS implementation — a
/// `//` inside a string is treated as a comment, which is an accepted,
/// documented simplification.
fn strip_comments(src : String) -> String {
  let chars = src.to_array()
  let n = chars.length()
  let out : Array[Char] = Array::new()
  let mut i = 0
  while i < n {
    let c = chars.unsafe_get(i)
    let next = if i + 1 < n { Some(chars.unsafe_get(i + 1)) } else { None }
    match (c, next) {
      ('/', Some('/')) => {
        // Line comment: blank until end of line (keep the newline).
        out.push(' ')
        out.push(' ')
        i += 2
        while i < n && chars.unsafe_get(i) != '\n' {
          out.push(' ')
          i += 1
        }
      }
      ('/', Some('*')) => {
        // Block comment: blank until `*/` (or EOF).
        out.push(' ')
        out.push(' ')
        i += 2
        while i < n {
          if chars.unsafe_get(i) == '*' &&
            i + 1 < n &&
            chars.unsafe_get(i + 1) == '/' {
            out.push(' ')
            out.push(' ')
            i += 2
            break
          }
          let ch = chars.unsafe_get(i)
          out.push(if ch == '\n' { '\n' } else { ' ' })
          i += 1
        }
      }
      _ => {
        out.push(c)
        i += 1
      }
    }
  }
  String::from_array(out)
}

///|
/// Split source into lines, returning each line with its 1-based number.
/// Trailing `\r` is trimmed so Windows line endings do not corrupt matches.
fn split_lines(src : String) -> Array[(Int32, String)] {
  let result : Array[(Int32, String)] = []
  let mut lineno = 1
  for view in src.split("\n") {
    let line = view.to_owned()
    let cleaned = trim_end_char(line, '\r')
    result.push((lineno, cleaned))
    lineno += 1
  }
  // `split` yields a trailing empty element after a final newline; drop it
  // so an empty last line is not reported as a phantom line.
  if result.length() > 0 {
    let (_, last) = result.unsafe_get(result.length() - 1)
    if last == "" {
      ignore(result.pop())
    }
  }
  result
}

///|
/// Trim a single trailing character from a string.
fn trim_end_char(s : String, ch : Char) -> String {
  let chars = s.to_array()
  let mut end = chars.length()
  while end > 0 && chars.unsafe_get(end - 1) == ch {
    end -= 1
  }
  String::from_array(chars[:end])
}

///|
/// Recursively collect files under `root` whose extension is in `exts`.
/// `exts` is compared case-insensitively. Returns paths relative to `root`.
pub fn walk_files(root : String, exts : Array[String]) -> Array[String] raise {
  let wanted : Set[String] = Set::from_iter(exts.iter().map(e => e.to_lower()))
  let acc : Array[String] = []
  walk_dir(root, root, wanted, acc)
  acc
}

///|
/// Recursive worker for `walk_files`.
fn walk_dir(
  root : String,
  dir : String,
  wanted : Set[String],
  acc : Array[String],
) -> Unit raise {
  let entries = @fs.read_dir(dir)
  for name in entries {
    let full = join_path(dir, name)
    let is_dir = @fs.is_dir(full) catch { _ => false }
    if is_dir {
      if not(skip_dirs().contains(name)) {
        walk_dir(root, full, wanted, acc)
      }
    } else if has_wanted_ext(name, wanted) {
      acc.push(relative_path(root, full))
    }
  }
}

///|
/// Whether a file name has one of the wanted extensions.
/// Extensions may be specified with or without a leading dot.
fn has_wanted_ext(name : String, wanted : Set[String]) -> Bool {
  match name.rev_split_once(".") {
    None => false
    Some((_, ext)) => {
      let ext_lower = ext.to_owned().to_lower()
      // Normalize: check both "ts" and ".ts" forms.
      wanted.contains(ext_lower) || wanted.contains(".\{ext_lower}")
    }
  }
}

///|
/// Join two path segments with `/`. `moonbitlang/x/path` is avoided to keep
/// the dependency surface minimal; the linter only ever walks forward-slash
/// paths produced by `read_dir`.
fn join_path(dir : String, name : String) -> String {
  if dir.has_suffix("/") {
    "\{dir}\{name}"
  } else {
    "\{dir}/\{name}"
  }
}

///|
/// Strip the `root/` prefix to produce a path relative to the scan root.
fn relative_path(root : String, full : String) -> String {
  let prefix = if root.has_suffix("/") { root } else { "\{root}/" }
  if full.has_prefix(prefix) {
    full.substring(start=prefix.length())
  } else {
    full
  }
}

///|
/// Read a file and return its comment-stripped lines with line numbers.
/// Returns an empty array if the file cannot be read (binary / permission
/// errors are skipped rather than aborting the run).
pub fn read_lines(path : String) -> Array[(Int32, String)] {
  let src = @fs.read_file_to_string(path) catch { _ => return [] }
  split_lines(strip_comments(src))
}
