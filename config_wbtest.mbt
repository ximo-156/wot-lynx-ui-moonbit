///|
/// Tests for the config parser.

///|
test "parse minimal config" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"msg\",\"match\":{\"contains\":\"foo\"}}]}"
  let rules = parse_config(json)
  assert_eq(rules is Ok(_), true)
  let rs = rules.unwrap()
  assert_eq(rs.length(), 1)
  assert_eq(rs[0].id, "r1")
  assert_eq(rs[0].message, "msg")
}

///|
test "parse config with regex and unless" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"severity\":\"error\",\"message\":\"m\",\"extensions\":[\".vue\"],\"match\":{\"regex\":\"foo\"},\"unless\":{\"regex\":\"bar\"}}]}"
  let rules = parse_config(json).unwrap()
  assert_eq(rules.length(), 1)
  assert_eq(rules[0].severity, Severity::error())
  assert_eq(rules[0].extensions, [".vue"])
}

///|
test "parse config with prefix and suffix" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"prefix\":\"import\"}}]}"
  let rules = parse_config(json).unwrap()
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
  let rules = parse_config(json).unwrap()
  assert_eq(validate_rules(rules) is Ok(_), true)
}

///|
test "validate_rules rejects invalid regex" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"regex\":\"[bad\"}}]}"
  let rules = parse_config(json).unwrap()
  assert_true(validate_rules(rules) is Err(_))
}

///|
test "collect_extensions unions all rule extensions" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"extensions\":[\".vue\",\".ts\"],\"match\":{\"contains\":\"x\"}},{\"id\":\"r2\",\"message\":\"m\",\"extensions\":[\".ts\",\".js\"],\"match\":{\"contains\":\"y\"}}]}"
  let rules = parse_config(json).unwrap()
  let exts = collect_extensions(rules)
  assert_eq(exts.length(), 3)
  assert_true(exts.contains(".vue"))
  assert_true(exts.contains(".ts"))
  assert_true(exts.contains(".js"))
}
