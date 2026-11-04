///|
/// Return the host's UTC calendar date for default exception-expiry checks.
/// The explicit CLI date override remains available for deterministic CI tests.
pub fn utc_date() -> String raise NativeError {
  let (bytes, _) = native_operation(10, b"", b"", 0)
  native_utf8(bytes, "UTC date")
}

///|
/// Read fix input strictly, preserving its BOM and rejecting unsafe paths.
pub fn read_fix_source(root : String, rel : String) -> String raise {
  validate_fix_path(root, rel)
  read_source(join_path(root, rel))
}
