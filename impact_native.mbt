///|
/// Fixed-argv MoonImpact process bridge. The planner never invokes it unless
/// the caller explicitly requests Git change input or test execution.
#cfg(all(target="native", not(platform="windows")))
#external
priv type ImpactNativeResult

///|
#cfg(all(target="native", not(platform="windows")))
#borrow(first, second)
extern "C" fn impact_request_ffi(
  operation : Int32,
  first : Bytes,
  second : Bytes,
  length : Int32,
  flag : Int32,
) -> ImpactNativeResult = "moonimpact_native_request"

///|
#cfg(all(target="native", not(platform="windows")))
#borrow(result)
extern "C" fn impact_result_null(result : ImpactNativeResult) -> Int32 = "moonimpact_native_result_is_null"

///|
#cfg(all(target="native", not(platform="windows")))
#borrow(result)
extern "C" fn impact_result_status(result : ImpactNativeResult) -> Int32 = "moonimpact_native_result_status"

///|
#cfg(all(target="native", not(platform="windows")))
#borrow(result)
extern "C" fn impact_result_value(result : ImpactNativeResult) -> Int32 = "moonimpact_native_result_value"

///|
#cfg(all(target="native", not(platform="windows")))
#borrow(result)
extern "C" fn impact_result_bytes(result : ImpactNativeResult) -> Bytes = "moonimpact_native_result_bytes"

///|
#cfg(all(target="native", not(platform="windows")))
#borrow(result)
extern "C" fn impact_result_error(result : ImpactNativeResult) -> Bytes = "moonimpact_native_result_error"

///|
#cfg(all(target="native", not(platform="windows")))
#borrow(result)
extern "C" fn impact_result_free(result : ImpactNativeResult) -> Unit = "moonimpact_native_result_free"

///|
/// Operations: 0 Git changes; 1 selected Vitest tests; 2 all Vitest tests;
/// 3 publish a report without overwriting any existing path.
#cfg(all(target="native", not(platform="windows")))
fn impact_native_operation(
  operation : Int32,
  first : Bytes,
  second : Bytes,
  flag : Int32,
) -> (Bytes, Int32) raise NativeError {
  let result = impact_request_ffi(
    operation,
    first,
    second,
    second.length(),
    flag,
  )
  guard impact_result_null(result) == 0 else {
    raise NativeError("MoonImpact native bridge: out of memory")
  }
  if impact_result_status(result) != 0 {
    let message = impact_result_error(result)
    impact_result_free(result)
    raise NativeError(@utf8.decode_lossy(message))
  }
  let bytes = impact_result_bytes(result)
  let value = impact_result_value(result)
  impact_result_free(result)
  (bytes, value)
}

///|
#cfg(not(all(target="native", not(platform="windows"))))
fn impact_native_operation(
  _operation : Int32,
  _first : Bytes,
  _second : Bytes,
  _flag : Int32,
) -> (Bytes, Int32) raise NativeError {
  raise NativeError("MoonImpact native operations require macOS or Linux")
}

///|
/// Files changed from `base` (HEAD when absent) to the live working tree,
/// including staged, unstaged and non-ignored untracked files. Deletions and
/// both rename endpoints are retained. `root` must be the repository root;
/// this is not an immutable HEAD snapshot and callers must avoid concurrent
/// Git/worktree edits during selection.
pub fn impact_git_changes(root : String, base : String?) -> Array[String] raise {
  let reference = base.unwrap_or("HEAD")
  if reference.is_empty() || reference.has_prefix("-") {
    raise Failure("base must be a nonempty Git commit reference, not an option")
  }
  let (bytes, _) = impact_native_operation(
    0,
    native_os_string(root, "Git root"),
    native_os_string(reference, "Git base"),
    0,
  )
  let paths : Array[String] = []
  let seen : Set[String] = Set([])
  for raw in native_paths(bytes) {
    let path = normalize_relative(raw)
    if !seen.contains(path) {
      seen.add(path)
      paths.push(path)
    }
  }
  paths.sort()
  paths
}

///|
/// Explicitly run `pnpm exec vitest run` in `root`. Related mode requires a
/// nonempty selection; full mode intentionally omits filters. Each test path
/// is root-relative and passed as its own `./path` argv element, never shell
/// text. Child stdout and stderr both go to this process's stderr. Startup
/// errors and timeout raise; a normal child exit status is returned unchanged.
pub fn impact_run_vitest(
  root : String,
  tests : Array[String],
  full : Bool,
  timeout_ms : Int32,
) -> Int32 raise {
  if timeout_ms <= 0 {
    raise Failure("test timeout must be positive")
  }
  if !full && tests.is_empty() {
    raise Failure("related test execution requires a nonempty test selection")
  }
  let paths : Array[String] = []
  if !full {
    for path in tests {
      let normalized = normalize_relative(path)
      paths.push(normalized)
    }
  }
  let payload = if full {
    b""
  } else {
    @utf8.encode(paths.join("\u{0}") + "\u{0}")
  }
  let (_, code) = impact_native_operation(
    if full {
      2
    } else {
      1
    },
    native_os_string(root, "test root"),
    payload,
    timeout_ms,
  )
  code
}

///|
/// Atomically create a new UTF-8 report. Existing files, directories and
/// symlinks are never replaced, including a target created concurrently.
/// Parent directories must already exist. The temporary file is kept in the
/// destination directory and linked into place with create-only semantics.
pub fn impact_write_report_new(path : String, content : String) -> Unit raise {
  let _ = impact_native_operation(
    3,
    native_os_string(path, "report path"),
    @utf8.encode(content),
    0,
  )
}
