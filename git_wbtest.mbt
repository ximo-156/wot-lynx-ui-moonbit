///|
test "Git paths are NUL-separated without trimming or unquoting" {
  let names = [
    " space .mbt",
    "中文.mbt",
    "a\nb.mbt",
    "a\tb.mbt",
    "\"quote'.mbt",
    "-dash.mbt",
    ":colon.mbt",
  ]
  let mut bytes = b""
  for name in names {
    bytes = bytes + @utf8.encode(name) + b"\x00"
  }
  assert_eq(native_paths(bytes), names)
  assert_eq(native_paths(b""), [])
}

///|
test "Git path parser rejects truncated or empty records" {
  let truncated = try native_paths(b"without-nul.mbt") catch {
    NativeError(_) => []
  }
  assert_eq(truncated, [])
  let empty_record = try native_paths(b"ok.mbt\x00\x00") catch {
    NativeError(_) => []
  }
  assert_eq(empty_record, [])
}

///|
test "native text preserves BOM NUL whitespace and final newlines" {
  let original = "\u{FEFF}  a\u{0}b\n\n tail \n"
  assert_eq(native_utf8(@utf8.encode(original), "text"), original)
  let invalid = try native_utf8(b"\xff", "text") catch {
    NativeError(message) => message
  }
  assert_eq(invalid, "text is not valid UTF-8")
}

///|
test "OS strings reject embedded NUL instead of silently truncating" {
  assert_eq(native_os_string("路径 with spaces", "path"), @utf8.encode("路径 with spaces") + b"\x00")
  let invalid = try native_os_string("a\u{0}b", "path") catch {
    NativeError(message) => @utf8.encode(message)
  }
  assert_eq(invalid, b"path must not contain NUL")
}

///|
#cfg(not(all(target="native", not(platform="windows"))))
test "non-POSIX native targets fail explicitly rather than using shell APIs" {
  let message = try canonical_root(".") catch {
    NativeError(message) => message
  }
  assert_eq(
    message,
    "native filesystem/Git bridge is unsupported: use the native backend on macOS or Linux",
  )
}
