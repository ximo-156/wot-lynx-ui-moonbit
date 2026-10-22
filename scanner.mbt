///|
/// Source views and rooted file walking. Symbolic links are never followed.

///|
fn skip_dirs() -> Set[String] {
  Set::from_iter(
    [
      ".git", "node_modules", "dist", "target", "_build", ".mooncakes", "coverage",
      ".rspeedy", ".vitepress", ".preview",
    ].iter(),
  )
}

///|
fn split_lines(src : String) -> Array[(Int32, String)] {
  let result : Array[(Int32, String)] = []
  let mut lineno = 1
  for view in src.split("\n") {
    result.push((lineno, trim_end_char(view.to_owned(), '\r')))
    lineno += 1
  }
  if result.length() > 0 && result[result.length() - 1].1 == "" {
    ignore(result.pop())
  }
  result
}

///|
fn trim_end_char(s : String, ch : Char) -> String {
  let chars = s.to_array()
  let mut end = chars.length()
  while end > 0 && chars[end - 1] == ch {
    end -= 1
  }
  String::from_array(chars[:end])
}

///|
/// Collect root-relative candidates in stable order. Empty `exts` means all
/// files, including extensionless files. Links/other non-directories are kept
/// as candidates so the engine can report them as skipped, never read them.
pub fn walk_files(root : String, exts : Array[String]) -> Array[String] raise {
  let absolute = canonical_root(root)
  let wanted = Set::from_iter(exts.iter().map(e => e.to_lower()))
  let files : Array[String] = []
  walk_dir(absolute, absolute, wanted, files)
  files.sort()
  files
}

///|
fn walk_dir(
  root : String,
  dir : String,
  wanted : Set[String],
  files : Array[String],
) -> Unit raise {
  let entries = @fs.read_dir(dir)
  for name in entries {
    if skip_dirs().contains(name) {
      continue
    }
    let full = join_path(dir, name)
    let kind = source_path_kind(full)
    if kind == 2 {
      walk_dir(root, full, wanted, files)
    } else if has_wanted_ext(name, wanted) {
      files.push(relative_path(root, full))
    }
  }
}

///|
fn has_wanted_ext(name : String, wanted : Set[String]) -> Bool {
  if wanted.is_empty() {
    return true
  }
  match name.rev_split_once(".") {
    None => false
    Some((_, ext)) => {
      let lower = ext.to_owned().to_lower()
      wanted.contains(lower) || wanted.contains(".\{lower}")
    }
  }
}

///|
fn path_is_noise(rel : String) -> Bool {
  rel.split("/").any(part => skip_dirs().contains(part.to_owned()))
}

///|
fn join_path(dir : String, name : String) -> String {
  if dir.has_suffix("/") {
    "\{dir}\{name}"
  } else {
    "\{dir}/\{name}"
  }
}

///|
fn relative_path(root : String, full : String) -> String {
  let prefix = if root.has_suffix("/") { root } else { "\{root}/" }
  if full.has_prefix(prefix) {
    full[prefix.length():].to_owned()
  } else {
    full
  }
}

///|
/// Reject absolute/traversing paths, normalize ./ and duplicate separators.
/// Whitespace, Unicode, quotes and newlines are significant filename data.
fn normalize_relative(path : String) -> String raise {
  if path == "" || path.has_prefix("/") || path.contains("\x00") {
    raise Failure("file path must be non-empty and relative to the scan root")
  }
  let parts : Array[String] = []
  for part in path.split("/") {
    if part == ".." {
      raise Failure("file path may not traverse outside the scan root: \{path}")
    }
    if part != "." && part != "" {
      parts.push(part.to_owned())
    }
  }
  if parts.is_empty() {
    raise Failure("file path must name a file: \{path}")
  }
  parts.join("/")
}

///|
/// Validate every directory component with lstat. This also prevents a stdin
/// path such as linked-directory/source.ts from escaping through a parent link.
fn rooted_source_kind(root : String, rel : String) -> Int32 raise {
  let parts = rel.split("/").map(v => v.to_owned()).to_array()
  let mut current = root
  for i in 0..<parts.length() {
    current = join_path(current, parts[i])
    let kind = source_path_kind(current)
    if i == parts.length() - 1 {
      return kind
    }
    if kind == 3 {
      return 3
    }
    if kind != 2 {
      raise Failure("cannot resolve source directory: \{current}")
    }
  }
  0
}

///|
/// Decode strictly. Binary NULs and invalid UTF-8 are read failures, not clean
/// files. The engine records the diagnostic and returns exit code 2 in the CLI.
fn read_source(path : String) -> String raise {
  let bytes = @fs.read_file_to_bytes(path)
  let src = @utf8.decode(bytes) catch {
    _ => raise Failure("source is not valid UTF-8: \{path}")
  }
  if src.contains("\x00") {
    raise Failure("binary source contains NUL bytes: \{path}")
  }
  src
}

///|
pub fn read_lines(path : String) -> Array[(Int32, String)] raise {
  split_lines(strip_comments(read_source(path), comment_mode_for(path)))
}

///|
/// Expose derived impls as regular methods for external callers.

///|
pub extend CommentMode with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend CommentMode with Eq::{equal, not_equal}
