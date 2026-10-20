///|
/// Native filesystem and Git operations use fixed argv, never a shell.
/// Source text is strict UTF-8 with BOMs and embedded NULs preserved.
pub(all) suberror NativeError {
  NativeError(String)
} derive(Debug)

///|
#deprecated
pub extend NativeError with Debug::{to_repr}

///|
#cfg(all(target="native", not(platform="windows")))
#external
priv type NativeResult

///|
#cfg(all(target="native", not(platform="windows")))
#borrow(first, second)
extern "C" fn native_request_ffi(
  operation : Int32,
  first : Bytes,
  second : Bytes,
  second_len : Int32,
  flag : Int32,
) -> NativeResult = "moonlint_native_request"

///|
#cfg(all(target="native", not(platform="windows")))
#borrow(result)
extern "C" fn native_result_is_null(result : NativeResult) -> Int32 = "moonlint_native_result_is_null"

///|
#cfg(all(target="native", not(platform="windows")))
#borrow(result)
extern "C" fn native_result_status(result : NativeResult) -> Int32 = "moonlint_native_result_status"

///|
#cfg(all(target="native", not(platform="windows")))
#borrow(result)
extern "C" fn native_result_value(result : NativeResult) -> Int32 = "moonlint_native_result_value"

///|
#cfg(all(target="native", not(platform="windows")))
#borrow(result)
extern "C" fn native_result_bytes(result : NativeResult) -> Bytes = "moonlint_native_result_bytes"

///|
#cfg(all(target="native", not(platform="windows")))
#borrow(result)
extern "C" fn native_result_error(result : NativeResult) -> Bytes = "moonlint_native_result_error"

///|
#cfg(all(target="native", not(platform="windows")))
#borrow(result)
extern "C" fn native_result_free(result : NativeResult) -> Unit = "moonlint_native_result_free"

///|
/// Private operations: root=0, lstat=1, stdin=2, changed=3, staged=4,
/// blob=5, Git kind=6, atomic write=7.
#cfg(all(target="native", not(platform="windows")))
fn native_operation(
  operation : Int32,
  first : Bytes,
  second : Bytes,
  flag : Int32,
) -> (Bytes, Int32) raise NativeError {
  let result = native_request_ffi(operation, first, second, second.length(), flag)
  guard native_result_is_null(result) == 0 else {
    raise NativeError("native bridge: out of memory")
  }
  if native_result_status(result) != 0 {
    let message = native_result_error(result)
    native_result_free(result)
    raise NativeError(@utf8.decode_lossy(message))
  }
  let bytes = native_result_bytes(result)
  let value = native_result_value(result)
  native_result_free(result)
  (bytes, value)
}

///|
#cfg(not(all(target="native", not(platform="windows"))))
fn native_operation(
  _operation : Int32,
  _first : Bytes,
  _second : Bytes,
  _flag : Int32,
) -> (Bytes, Int32) raise NativeError {
  raise NativeError(
    "native filesystem/Git bridge is unsupported: use the native backend on macOS or Linux",
  )
}

///|
fn native_os_string(value : String, label : String) -> Bytes raise NativeError {
  let bytes = @utf8.encode(value)
  for byte in bytes {
    guard byte != b'\x00' else {
      raise NativeError("\{label} must not contain NUL")
    }
  }
  bytes + b"\x00"
}

///|
fn native_utf8(bytes : Bytes, label : String) -> String raise NativeError {
  try @utf8.decode(bytes[:], ignore_bom=false) catch {
    _ => raise NativeError("\{label} is not valid UTF-8")
  }
}

///|
fn native_paths(bytes : Bytes) -> Array[String] raise NativeError {
  let paths : Array[String] = []
  let mut start = 0
  for i in 0..<bytes.length() {
    if bytes[i] == b'\x00' {
      guard i > start else { raise NativeError("Git returned an empty path") }
      paths.push(native_utf8(bytes[start:i].to_owned(), "Git path"))
      start = i + 1
    }
  }
  guard start == bytes.length() else {
    raise NativeError("Git returned a path without its NUL terminator")
  }
  paths
}

///|
/// Resolve an existing directory to its absolute realpath.
pub fn canonical_root(root : String) -> String raise NativeError {
  let (bytes, _) = native_operation(0, native_os_string(root, "root"), b"", 0)
  native_utf8(bytes, "canonical root")
}

///|
/// lstat: 0 missing, 1 regular, 2 directory, 3 symlink/other. Never follow the
/// final component; callers prohibiting ancestor symlinks must check them too.
pub fn source_path_kind(path : String) -> Int32 raise NativeError {
  let (_, kind) = native_operation(1, native_os_string(path, "path"), b"", 0)
  kind
}

///|
/// Read stdin incrementally until EOF, without seeking or closing stdin.
/// Preserve whitespace, newlines, UTF-8 BOMs and embedded NULs exactly.
pub fn read_stdin_text() -> String raise NativeError {
  let (bytes, _) = native_operation(2, b"", b"", 0)
  native_utf8(bytes, "stdin")
}

///|
/// ACMR paths from merge-base(ref, HEAD) to committed HEAD, not working tree.
/// Validate ref as a commit and reject failures. Names are relative to root,
/// including when root is a repository subdirectory.
pub fn git_changed_files(
  root : String,
  git_ref : String,
) -> Array[String] raise NativeError {
  let (bytes, _) = native_operation(
    3,
    native_os_string(root, "root"),
    native_os_string(git_ref, "Git reference"),
    0,
  )
  native_paths(bytes)
}

///|
/// Actual index changes: omit deletions, retain rename destinations, support
/// unborn HEAD, and reject an unmerged index anywhere in the repository.
pub fn git_staged_files(root : String) -> Array[String] raise NativeError {
  let (bytes, _) = native_operation(4, native_os_string(root, "root"), b"", 0)
  native_paths(bytes)
}

///|
/// Read regular source from the index (true) or HEAD (false), never working tree.
/// Missing and nonregular (including Git symlink) entries raise an error.
pub fn git_blob(
  root : String,
  rel : String,
  staged : Bool,
) -> String raise NativeError {
  let (bytes, _) = native_operation(
    5,
    native_os_string(root, "root"),
    native_os_string(rel, "relative Git path"),
    if staged { 1 } else { 0 },
  )
  native_utf8(bytes, "Git blob")
}

///|
/// Index/HEAD kind: 0 missing, 1 regular, 2 tree, 3 symlink/gitlink/other.
/// Never consult working tree; an unmerged index always raises an error.
pub fn git_source_kind(
  root : String,
  rel : String,
  staged : Bool,
) -> Int32 raise NativeError {
  let (_, kind) = native_operation(
    6,
    native_os_string(root, "root"),
    native_os_string(rel, "relative Git path"),
    if staged { 1 } else { 0 },
  )
  kind
}

///|
/// Same-directory mkstemp, complete write, fsync, close, then atomic rename.
/// Failure before rename preserves old file; refuse existing nonregulars.
pub fn write_atomic_text(path : String, content : String) -> Unit raise NativeError {
  let _ = native_operation(
    7, native_os_string(path, "atomic-write path"), @utf8.encode(content), 0,
  )
}
