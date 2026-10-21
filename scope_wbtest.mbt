///|
/// Tests for scope matching and glob path semantics.

///|
test "scope: empty scope allows every path" {
  let scope = Scope::empty()
  assert_true(scope.is_empty())
  assert_true(scope.allows("src/app.ts"))
  assert_true(scope.allows("README.md"))
}

///|
test "scope: include restricts the allowed paths" {
  let scope = Scope::new(["src/**"], []).unwrap()
  assert_false(scope.is_empty())
  assert_true(scope.allows("src/app.ts"))
  assert_true(scope.allows("src/deep/app.ts"))
  assert_false(scope.allows("lib/app.ts"))
  assert_false(scope.allows("app.ts"))
}

///|
test "scope: include of a directory covers everything below it" {
  let scope = Scope::new(["src"], []).unwrap()
  assert_true(scope.allows("src/app.ts"))
  assert_true(scope.allows("src/deep/app.ts"))
  // A sibling whose name merely starts with the pattern is not covered.
  assert_false(scope.allows("src2/app.ts"))
  assert_false(scope.allows("lib/app.ts"))
}

///|
test "scope: exclude removes paths below a directory" {
  let scope = Scope::new([], ["vendor"]).unwrap()
  assert_true(scope.allows("src/app.ts"))
  assert_false(scope.allows("vendor/app.ts"))
  assert_false(scope.allows("vendor/pkg/index.ts"))
  // A sibling with the same prefix is untouched.
  assert_true(scope.allows("vendorless/app.ts"))
}

///|
test "scope: exclude matches files by pattern as well as directories" {
  let scope = Scope::new([], ["**/*.md"]).unwrap()
  assert_true(scope.allows("src/app.ts"))
  assert_false(scope.allows("docs/guide.md"))
  assert_false(scope.allows("README.md"))
  let generated = Scope::new([], ["*.gen.ts"]).unwrap()
  assert_false(generated.allows("models.gen.ts"))
  assert_true(generated.allows("src/models.ts"))
}

///|
test "scope: exclude wins over include" {
  let scope = Scope::new(["src/**"], ["src/legacy/**"]).unwrap()
  assert_true(scope.allows("src/app.ts"))
  assert_false(scope.allows("src/legacy/app.ts"))
}

///|
test "scope: a leading ./ is accepted" {
  let scope = Scope::new(["./src/**"], []).unwrap()
  assert_true(scope.allows("src/app.ts"))
  assert_false(scope.allows("lib/app.ts"))
}

///|
test "scope: an empty pattern is rejected" {
  assert_true(Scope::new([""], []) is Err(_))
}

///|
test "scope: an unsupported pattern is rejected with a reason" {
  assert_true(Scope::new(["src/{a,b}"], []) is Err(_))
  assert_true(Scope::new([], ["../outside"]) is Err(_))
  let reason = match Scope::new(["src/[ab].ts"], []) {
    Ok(_) => "accepted"
    Err(message) => message
  }
  assert_true(reason.contains("invalid scope pattern"))
}

///|
test "scope: both lists combine into one exclusion-wins predicate" {
  let scope = Scope::new(["src/**", "lib/**"], [
    "src/legacy", "lib/generated/**",
  ])
  let scope = scope.unwrap()
  assert_true(scope.allows("src/app.ts"))
  assert_true(scope.allows("lib/util.ts"))
  assert_false(scope.allows("src/legacy/app.ts"))
  assert_false(scope.allows("lib/generated/schema.ts"))
  assert_false(scope.allows("docs/readme.md"))
}

///|
test "glob: matches_path covers a matched directory" {
  let pattern = GlobPattern::new("vendor")
  assert_true(pattern.matches_path("vendor"))
  assert_true(pattern.matches_path("vendor/pkg/index.ts"))
  assert_false(pattern.matches_path("vendorless/pkg/index.ts"))
}

///|
test "glob: matches_path does not treat a file as a directory" {
  let pattern = GlobPattern::new("src/app.ts")
  assert_true(pattern.matches_path("src/app.ts"))
  assert_false(pattern.matches_path("src/app.ts.map"))
}

///|
test "glob: matches_path with a double star pattern" {
  let pattern = GlobPattern::new("**/*.gen.ts")
  assert_true(pattern.matches_path("a.gen.ts"))
  assert_true(pattern.matches_path("deep/nested/a.gen.ts"))
  assert_false(pattern.matches_path("deep/nested/a.ts"))
}

///|
test "glob: an invalid pattern reports a reason" {
  assert_true(glob_pattern_error("") is Some(_))
  assert_true(glob_pattern_error("/abs/path") is Some(_))
  assert_true(glob_pattern_error("src/../etc") is Some(_))
  assert_true(glob_pattern_error("src/a**b") is Some(_))
  assert_true(glob_pattern_error("src/app.ts") is None)
}
