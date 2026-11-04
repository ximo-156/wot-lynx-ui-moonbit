///|
priv struct GitSnapshotEntry {
  kind : Int32
  oid : String
}

///|
priv struct GitSnapshot {
  revision : String
  entries : Map[String, GitSnapshotEntry]
}

///|
fn git_oid_valid(oid : String) -> Bool {
  let chars = oid.to_array()
  (chars.length() == 40 || chars.length() == 64) && chars.all(c =>
    (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

///|
/// Read one complete machine listing, retaining immutable object ids instead
/// of asking HEAD/index again for each selected or context source.
fn capture_git_snapshot(root : String, staged : Bool) -> GitSnapshot raise {
  let (bytes, _) = native_operation(8, native_os_string(root, "root"), b"", if staged { 1 } else { 0 })
  let records = native_paths(bytes)
  if records.is_empty() { raise Failure("Git snapshot has no revision record") }
  let revision = records[0]
  if (staged && revision != "index") || (!staged && !git_oid_valid(revision)) {
    raise Failure("Git snapshot revision is invalid")
  }
  let entries : Map[String, GitSnapshotEntry] = Map([])
  for i in 1..<records.length() {
    let chars = records[i].to_array()
    let mut tab = 0
    while tab < chars.length() && chars[tab] != '\t' { tab += 1 }
    if tab == chars.length() { raise Failure("Git snapshot record has no header delimiter") }
    let header = String::from_array(chars[:tab]).split(" ").to_array()
    if header.length() != 3 { raise Failure("Git snapshot header is invalid") }
    let mode = header[0].to_owned()
    let kind = match mode {
      "100644" | "100755" => 1
      "040000" => 2
      "120000" | "160000" => 3
      _ => raise Failure("Git snapshot has an unsupported file mode")
    }
    let oid = header[if staged { 1 } else { 2 }].to_owned()
    if !git_oid_valid(oid) || (staged && header[2] != "0") ||
      (!staged && header[1] != "blob" && header[1] != "commit" && header[1] != "tree") {
      raise Failure("Git snapshot object metadata is invalid")
    }
    let rel = String::from_array(chars[tab + 1:])
    let normalized = normalize_relative(rel)
    if normalized != rel || entries.contains(rel) { raise Failure("Git snapshot has an invalid or duplicate path") }
    entries.set(rel, { kind, oid })
  }
  { revision, entries }
}

///|
fn GitSnapshot::kind(self : GitSnapshot, rel : String) -> Int32 {
  match self.entries.get(rel) { Some(entry) => entry.kind; None => 0 }
}

///|
fn GitSnapshot::source(self : GitSnapshot, root : String, rel : String) -> String raise {
  let entry = match self.entries.get(rel) {
    Some(entry) => entry
    None => raise Failure("selected path is absent from captured Git snapshot: \{rel}")
  }
  if entry.kind != 1 { raise Failure("Git snapshot source is not a regular file: \{rel}") }
  let (bytes, _) = native_operation(9, native_os_string(root, "root"), native_os_string(entry.oid, "object id"), 0)
  let src = native_utf8(bytes, "Git snapshot blob")
  if src.contains("\u{0}") { raise Failure("binary source contains NUL bytes: \{rel}") }
  src
}

///|
/// Refuse fixes through symlink ancestors or on nonregular files.
pub fn validate_fix_path(root : String, rel : String) -> Unit raise {
  let normalized = normalize_relative(rel)
  if normalized != rel || rooted_source_kind(root, rel) != 1 {
    raise Failure("refusing to fix a nonregular or unsafe source path: \{rel}")
  }
}
