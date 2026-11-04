///|
fn needs_project_context(check : StructuralCheck) -> Bool {
  match check { NoUnresolvedRelativeImports | NoImportCycles | NoUnusedExports => true; _ => false }
}

///|
/// Add unselected/excluded dependencies as context, without reporting findings
/// on them. Git modes read the exact same captured blob map as selected files.
fn add_project_context(root : String, sources : Array[(String, String)],
  frozen : GitSnapshot?) -> (Int32, Int32, Array[Diagnostic]) raise {
  let known : Set[String] = Set::from_iter(sources.iter().map(pair => pair.0))
  let extensions = resolution_extensions()
  let candidates = match frozen {
    Some(snapshot) => snapshot.entries.keys().to_array().filter(rel =>
      !path_is_noise(rel) && extensions.any(ext => rel.has_suffix(ext)))
    None => select_files(ScanMode::Tree, root, extensions)
  }
  candidates.sort()
  let mut scanned = 0
  let mut failed = 0
  let diagnostics : Array[Diagnostic] = []
  for rel in candidates {
    if known.contains(rel) { continue }
    try {
      let kind = match frozen { Some(snapshot) => snapshot.kind(rel); None => rooted_source_kind(root, rel) }
      if kind != 1 { continue }
      let source = match frozen {
        Some(snapshot) => snapshot.source(root, rel)
        None => read_source(join_path(root, rel))
      }
      sources.push((rel, source))
      known.add(rel)
      scanned += 1
    } catch { error => {
      failed += 1
      diagnostics.push({ file: rel, message: "project context: \{error_message(error)}" })
    } }
  }
  (scanned, failed, diagnostics)
}
