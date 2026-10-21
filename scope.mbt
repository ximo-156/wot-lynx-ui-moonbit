///|
/// Scope configuration.
///
/// A scope restricts which paths a run or a single rule may look at. It is
/// built from two lists of root-relative glob patterns:
///
/// - `includes` — when non-empty, only paths matching one of them are in
///   scope. An empty list means "every path is in scope".
/// - `excludes` — paths matching one of them are never in scope.
///
/// A pattern covers everything below a directory it matches, so `vendor`
/// excludes `vendor/pkg/index.ts` without spelling out `vendor/**`. The
/// supported pattern syntax is the portable glob subset: literals, `*`, `?`
/// and standalone `**` path segments (see `glob_pattern_error`).

///|
pub struct Scope {
  /// Patterns a path must match to be in scope. Empty means "no restriction".
  includes : Array[GlobPattern]
  /// Patterns that take a path out of scope.
  excludes : Array[GlobPattern]
} derive(Debug, Eq)

///|
/// A scope that places no restriction on paths.
pub fn Scope::empty() -> Scope {
  { includes: [], excludes: [], }
}

///|
/// Compile a scope from raw patterns. The first invalid pattern is reported
/// with a human-readable reason; no scope is applied until compilation
/// succeeds.
pub fn Scope::new(
  includes : Array[String],
  excludes : Array[String],
) -> Result[Scope, String] {
  let included = match compile_patterns(includes) {
    Ok(patterns) => patterns
    Err(message) => return Err(message)
  }
  let excluded = match compile_patterns(excludes) {
    Ok(patterns) => patterns
    Err(message) => return Err(message)
  }
  Ok({ includes: included, excludes: excluded, })
}

///|
fn compile_patterns(
  patterns : Array[String],
) -> Result[Array[GlobPattern], String] {
  let compiled : Array[GlobPattern] = []
  for raw in patterns {
    if raw == "" {
      return Err("scope patterns must not be empty")
    }
    // A leading "./" is a common way to write a root-relative pattern.
    let normalized = if raw.has_prefix("./") { raw[2:].to_owned() } else { raw }
    match glob_pattern_error(normalized) {
      Some(message) =>
        return Err("invalid scope pattern \"\{raw}\": \{message}")
      None => ()
    }
    compiled.push(GlobPattern::new(normalized))
  }
  Ok(compiled)
}

///|
/// Whether a root-relative path is inside this scope. Exclusion wins over
/// inclusion, so an excluded path is out of scope even when an include
/// pattern matches it.
pub fn Scope::allows(self : Scope, rel : String) -> Bool {
  if self.excludes.any(pattern => pattern.matches_path(rel)) {
    return false
  }
  if self.includes.is_empty() {
    return true
  }
  self.includes.any(pattern => pattern.matches_path(rel))
}

///|
/// Whether the scope restricts paths at all.
pub fn Scope::is_empty(self : Scope) -> Bool {
  self.includes.is_empty() && self.excludes.is_empty()
}
