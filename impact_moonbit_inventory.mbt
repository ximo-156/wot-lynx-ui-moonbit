///|
/// Inventory is conservative: executable documentation fences and ordinary
/// top-level test blocks count, independent of the source file's basename.
/// Unknown lexical input counts as a possible test rather than an empty package.
fn impact_mbt_source_contains_tests(path : String, source : String) -> Bool {
  if !path.has_suffix(".mbt") && !path.has_suffix(".mbt.md") {
    return false
  }
  let view = moonbit_lex(source)
  if path.has_suffix(".mbt") {
    if !view.issues.is_empty() {
      return true
    }
    if scan_moonbit_decls_view(view).any(decl => decl.kind == MTest) {
      return true
    }
  }
  let docs = if path.has_suffix(".mbt.md") { source } else { view.comments }
  // Counting a displayed/unsupported fence conservatively only adds a package;
  // it cannot suppress real tests. Fence execution remains the runner's job.
  for line in docs.split("\n") {
    let mut text = line.trim().to_owned()
    if text.has_prefix("///") {
      text = text[3:].trim().to_owned()
    }
    if text.has_prefix("```") || text.has_prefix("~~~") {
      let info = text[3:].trim().to_owned()
      if (info.has_prefix("mbt ") || info.has_prefix("moonbit ")) &&
        info.split(" ").any(word => word == "test" || word == "check") {
        return true
      }
    }
  }
  false
}
