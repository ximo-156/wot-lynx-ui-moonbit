///|
/// Git integration via FFI.
///
/// MoonBit core has no subprocess API, so we shell out to `git` through
/// `popen` / `pclose` / `fgets` (declared in `git_native.c`). Only read-only
/// `git diff --name-only` style commands are used.

///|
/// Opaque handle for a `FILE*` stream.
priv type Pipe

///|
/// Open a pipe to a command (like `popen`).
#borrow(cmd, mode)
extern "C" fn popen_ffi(cmd : Bytes, mode : Bytes) -> Pipe = "moonlint_popen"

///|
/// Close a pipe and return the exit status.
#borrow(pipe)
extern "C" fn pclose_ffi(pipe : Pipe) -> Int32 = "moonlint_pclose"

///|
/// Whether a pipe pointer is null.
#borrow(ptr)
extern "C" fn pipe_is_null(ptr : Pipe) -> Int32 = "moonlint_pipe_is_null"

///|
/// Read one line from a pipe stream.
#borrow(buf, stream)
extern "C" fn fgets_ffi(
  buf : FixedArray[Byte],
  size : Int32,
  stream : Pipe,
) -> Pipe = "moonlint_fgets"

///|
/// Run a shell command and return its stdout as a string.
///
/// Returns `None` if `popen` failed. Each line is trimmed; empty lines
/// are dropped.
pub fn run_command(cmd : String) -> String? {
  let cmd_bytes = @utf8.encode(cmd) + Bytes::make(1, b'\x00')
  let mode_bytes = @utf8.encode("r") + Bytes::make(1, b'\x00')
  let pipe = popen_ffi(cmd_bytes, mode_bytes)
  if pipe_is_null(pipe) != 0 {
    return None
  }
  let buf : FixedArray[Byte] = FixedArray::make(4096, b'\x00')
  let lines : Array[String] = []
  let mut running = true
  while running {
    let result = fgets_ffi(buf, 4096, pipe)
    if pipe_is_null(result) != 0 {
      running = false
    } else {
      let mut len = 0
      while len < 4096 && buf.unsafe_get(len) != b'\x00' {
        len += 1
      }
      if len > 0 {
        let arr : Array[Byte] = Array::make(len, b'\x00')
        for k in 0..<len {
          arr[k] = buf.unsafe_get(k)
        }
        let bytes = Bytes::from_array(arr)
        let line = @utf8.decode_lossy(bytes)
        let trimmed = line.trim().to_owned()
        if trimmed.length() > 0 {
          lines.push(trimmed)
        }
      }
      for i in 0..<4096 {
        buf.unsafe_set(i, b'\x00')
      }
    }
  }
  let _ = pclose_ffi(pipe)
  Some(lines.join("\n"))
}

///|
/// Get the list of files changed since a git ref.
///
/// Runs `git diff --name-only <ref>` in the given directory.
/// Returns `None` if git is not available or the directory is not a repo.
pub fn git_changed_files(dir : String, git_ref : String) -> Array[String]? {
  let cmd = "cd \{dir} && git diff --name-only \{git_ref} 2>/dev/null"
  match run_command(cmd) {
    None => None
    Some(output) =>
      if output.length() == 0 {
        Some([])
      } else {
        Some(output.split("\n").map(v => v.to_owned()).to_array())
      }
  }
}

///|
/// Get the list of staged files (git diff --cached --name-only).
///
/// Returns `None` if git is not available or the directory is not a repo.
pub fn git_staged_files(dir : String) -> Array[String]? {
  let cmd = "cd \{dir} && git diff --cached --name-only 2>/dev/null"
  match run_command(cmd) {
    None => None
    Some(output) =>
      if output.length() == 0 {
        Some([])
      } else {
        Some(output.split("\n").map(v => v.to_owned()).to_array())
      }
  }
}

///|
/// Check whether a directory is inside a git repository.
pub fn git_is_repo(dir : String) -> Bool {
  let cmd = "cd \{dir} && git rev-parse --is-inside-work-tree 2>/dev/null"
  match run_command(cmd) {
    None => false
    Some(output) => output.trim() == "true"
  }
}
