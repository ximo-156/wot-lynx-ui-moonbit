///|
/// Tests for the config parser.

///|
test "parse minimal config" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"msg\",\"match\":{\"contains\":\"foo\"}}]}"
  let config = parse_config(json)
  assert_eq(config is Ok(_), true)
  let rules = config.unwrap().rules
  assert_eq(rules.length(), 1)
  assert_eq(rules[0].id, "r1")
  assert_eq(rules[0].message, "msg")
}

///|
test "parse config with regex and unless" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"severity\":\"error\",\"message\":\"m\",\"extensions\":[\".vue\"],\"match\":{\"regex\":\"foo\"},\"unless\":{\"regex\":\"bar\"}}]}"
  let rules = parse_config(json).unwrap().rules
  assert_eq(rules.length(), 1)
  assert_eq(rules[0].severity, Severity::error())
  assert_eq(rules[0].extensions, [".vue"])
}

///|
test "parse config with prefix and suffix" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"prefix\":\"import\"}}]}"
  let rules = parse_config(json).unwrap().rules
  assert_eq(rules[0].match_, HasPrefix("import"))
}

///|
test "invalid json returns error" {
  let result = parse_config("not json")
  assert_true(result is Err(_))
}

///|
test "missing rules array returns error" {
  let result = parse_config("{}")
  assert_true(result is Err(_))
}

///|
test "validate_rules accepts valid regex" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"regex\":\"[0-9]+\"}}]}"
  let rules = parse_config(json).unwrap().rules
  assert_eq(validate_rules(rules) is Ok(_), true)
}

///|
test "validate_rules rejects invalid regex" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"regex\":\"[bad\"}}]}"
  let rules = parse_config(json).unwrap().rules
  assert_true(validate_rules(rules) is Err(_))
}

///|
test "collect_extensions unions all rule extensions" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"extensions\":[\".vue\",\".ts\"],\"match\":{\"contains\":\"x\"}},{\"id\":\"r2\",\"message\":\"m\",\"extensions\":[\".ts\",\".js\"],\"match\":{\"contains\":\"y\"}}]}"
  let rules = parse_config(json).unwrap().rules
  let exts = collect_extensions(rules)
  assert_eq(exts.length(), 3)
  assert_true(exts.contains(".vue"))
  assert_true(exts.contains(".ts"))
  assert_true(exts.contains(".js"))
}

///|
test "config parses the global scope" {
  let json = "{\"include\":[\"src/**\"],\"exclude\":[\"vendor\"],\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"contains\":\"x\"}}]}"
  let config = parse_config(json).unwrap()
  assert_true(config.scope.allows("src/app.ts"))
  assert_false(config.scope.allows("lib/app.ts"))
  assert_false(config.scope.allows("vendor/pkg/index.ts"))
}

///|
test "config parses a rule-level scope" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"include\":[\"src/**\"],\"exclude\":[\"src/legacy/**\"],\"match\":{\"contains\":\"x\"}}]}"
  let rules = parse_config(json).unwrap().rules
  assert_true(rules[0].scope.allows("src/app.ts"))
  assert_false(rules[0].scope.allows("lib/app.ts"))
  assert_false(rules[0].scope.allows("src/legacy/app.ts"))
}

///|
test "config rejects a malformed scope list" {
  let json = "{\"include\":\"src/**\",\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"contains\":\"x\"}}]}"
  assert_true(parse_config(json) is Err(_))
}

///|
test "config rejects an invalid scope pattern" {
  let json = "{\"include\":[\"src/{a,b}\"],\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"contains\":\"x\"}}]}"
  assert_true(parse_config(json) is Err(_))
}

///|
test "config: rules without scope keys accept every path" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"contains\":\"x\"}}]}"
  let config = parse_config(json).unwrap()
  assert_true(config.scope.is_empty())
  assert_true(config.rules[0].scope.is_empty())
}

///|
test "config: an empty scope list means no restriction" {
  let json = "{\"include\":[],\"exclude\":[],\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"contains\":\"x\"}}]}"
  let config = parse_config(json).unwrap()
  assert_true(config.scope.allows("anything/at/all.ts"))
}

///|
test "config: rule-level and global scopes are independent" {
  let json = "{\"include\":[\"src/**\"],\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"exclude\":[\"src/vendor/**\"],\"match\":{\"contains\":\"x\"}}]}"
  let config = parse_config(json).unwrap()
  // Global include keeps lib/ out of the scan.
  assert_false(config.scope.allows("lib/app.ts"))
  // The rule scope does not inherit the global include, so lib/ still passes
  // the rule predicate; the engine already excluded it before matching.
  assert_true(config.rules[0].scope.allows("lib/app.ts"))
  assert_false(config.rules[0].scope.allows("src/vendor/app.ts"))
  assert_true(config.rules[0].scope.allows("src/app.ts"))
}

///|
test "config: rule-level scope errors name the rule" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"include\":[\"src/../etc\"],\"match\":{\"contains\":\"x\"}}]}"
  let message = match parse_config(json) {
    Ok(_) => "accepted"
    Err(ConfigError(message)) => message
  }
  assert_true(message.contains("rule \"r1\""))
}

///|
test "config: a malformed rule scope list is rejected" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"exclude\":\"src/**\",\"match\":{\"contains\":\"x\"}}]}"
  assert_true(parse_config(json) is Err(_))
}

///|
test "collect_extensions keeps the scan set empty for no rules" {
  assert_eq(collect_extensions([]), [])
}

///|
test "collect_extensions returns all files when any rule has no extension filter" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"extensions\":[\".ts\"],\"match\":{\"contains\":\"x\"}},{\"id\":\"r2\",\"message\":\"m\",\"match\":{\"contains\":\"y\"}}]}"
  assert_eq(collect_extensions(parse_config(json).unwrap().rules), [])
}

///|
test "collect_extensions deduplicates the union" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"extensions\":[\".ts\",\".ts\"],\"match\":{\"contains\":\"x\"}},{\"id\":\"r2\",\"message\":\"m\",\"extensions\":[\".ts\"],\"match\":{\"contains\":\"y\"}}]}"
  assert_eq(collect_extensions(parse_config(json).unwrap().rules), [".ts"])
}
