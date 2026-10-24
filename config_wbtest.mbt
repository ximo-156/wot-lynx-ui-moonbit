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
  let exts = collect_extensions(rules, [], [])
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
  assert_eq(collect_extensions([], [], []), [])
}

///|
test "collect_extensions returns all files when any rule has no extension filter" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"extensions\":[\".ts\"],\"match\":{\"contains\":\"x\"}},{\"id\":\"r2\",\"message\":\"m\",\"match\":{\"contains\":\"y\"}}]}"
  assert_eq(collect_extensions(parse_config(json).unwrap().rules, [], []), [])
}

///|
test "collect_extensions deduplicates the union" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"extensions\":[\".ts\",\".ts\"],\"match\":{\"contains\":\"x\"}},{\"id\":\"r2\",\"message\":\"m\",\"extensions\":[\".ts\"],\"match\":{\"contains\":\"y\"}}]}"
  assert_eq(collect_extensions(parse_config(json).unwrap().rules, [], []), [
    ".ts",
  ])
}

///|
test "config parses equals matcher" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"equals\":\"export default\"}}]}"
  let rules = parse_config(json).unwrap().rules
  assert_eq(rules[0].match_, Equals("export default"))
}

///|
test "config parses word matcher" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"word\":\"foo\"}}]}"
  let rules = parse_config(json).unwrap().rules
  assert_eq(rules[0].match_, Word("foo"))
}

///|
test "config parses all matcher" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"all\":[{\"contains\":\"a\"},{\"contains\":\"b\"}]}}]}"
  let rules = parse_config(json).unwrap().rules
  assert_eq(rules[0].match_, All([Contains("a"), Contains("b")]))
}

///|
test "config parses any matcher" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"any\":[{\"regex\":\"TODO\"},{\"regex\":\"FIXME\"}]}}]}"
  let rules = parse_config(json).unwrap().rules
  assert_eq(rules[0].match_, Any([Regex("TODO"), Regex("FIXME")]))
}

///|
test "config parses not matcher" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"not\":{\"word\":\"allow\"}}}]}"
  let rules = parse_config(json).unwrap().rules
  assert_eq(rules[0].match_, Not(Word("allow")))
}

///|
test "config parses nested combinators" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"all\":[{\"contains\":\"console.\"},{\"not\":{\"any\":[{\"word\":\"allow\"},{\"contains\":\"//\"}]}}]}}]}"
  let rules = parse_config(json).unwrap().rules
  assert_eq(
    rules[0].match_,
    All([Contains("console."), Not(Any([Word("allow"), Contains("//")]))]),
  )
}

///|
test "config parses a combinator inside unless" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"contains\":\"x\"},\"unless\":{\"all\":[{\"contains\":\"a\"},{\"contains\":\"b\"}]}}]}"
  let rules = parse_config(json).unwrap().rules
  assert_eq(rules[0].unless, Some(All([Contains("a"), Contains("b")])))
}

///|
test "config: all must be an array of matchers" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"all\":\"nope\"}}]}"
  let message = match parse_config(json) {
    Ok(_) => "accepted"
    Err(ConfigError(message)) => message
  }
  assert_true(message.contains("\"all\""))
}

///|
test "config: a malformed sub-matcher reports its index" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"any\":[{\"contains\":\"ok\"},{\"nonsense\":1}]}}]}"
  let message = match parse_config(json) {
    Ok(_) => "accepted"
    Err(ConfigError(message)) => message
  }
  assert_true(message.contains("\"any\": #1"))
  assert_true(message.contains("matcher needs one of"))
}

///|
test "config: not must wrap a matcher object" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"not\":42}}]}"
  assert_true(parse_config(json) is Err(_))
}

///|
test "validate_rules catches a bad regex nested in a combinator" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"all\":[{\"contains\":\"a\"},{\"regex\":\"[bad\"}]}}]}"
  let rules = parse_config(json).unwrap().rules
  assert_true(validate_rules(rules) is Err(_))
}

///|
test "config: match_comments defaults to false and parses when present" {
  let off = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"word\":\"TODO\"}}]}"
  let on = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"word\":\"TODO\"},\"match_comments\":true}]}"
  assert_eq(parse_config(off).unwrap().rules[0].match_comments, false)
  assert_eq(parse_config(on).unwrap().rules[0].match_comments, true)
}

///|
test "config: match_comments must be a boolean" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"word\":\"TODO\"},\"match_comments\":\"yes\"}]}"
  let message = match parse_config(json) {
    Ok(_) => "accepted"
    Err(ConfigError(message)) => message
  }
  assert_true(message.contains("match_comments"))
  assert_true(message.contains("boolean"))
}

///|
test "config parses file_rules with max_lines" {
  let json = "{\"rules\":[],\"file_rules\":[{\"id\":\"file/max-lines\",\"message\":\"too long\",\"extensions\":[\".ts\"],\"check\":{\"max_lines\":100}}]}"
  let config = parse_config(json).unwrap()
  assert_eq(config.file_rules.length(), 1)
  assert_eq(config.file_rules[0].id, "file/max-lines")
}

///|
test "config parses file_rules with no_trailing_whitespace" {
  let json = "{\"rules\":[],\"file_rules\":[{\"id\":\"file/tws\",\"message\":\"tws\",\"extensions\":[],\"check\":{\"no_trailing_whitespace\":true}}]}"
  let config = parse_config(json).unwrap()
  assert_eq(config.file_rules.length(), 1)
  assert_eq(config.file_rules[0].check, NoTrailingWhitespace)
}

///|
test "config parses file_rules with file_naming" {
  let json = "{\"rules\":[],\"file_rules\":[{\"id\":\"file/naming\",\"message\":\"naming\",\"extensions\":[\".ts\"],\"check\":{\"file_naming\":\"kebab-case\"}}]}"
  let config = parse_config(json).unwrap()
  assert_eq(config.file_rules.length(), 1)
  assert_eq(config.file_rules[0].check, FileNaming(KebabCase))
}

///|
test "config rejects invalid file_naming style" {
  let json = "{\"rules\":[],\"file_rules\":[{\"id\":\"file/naming\",\"message\":\"naming\",\"extensions\":[\".ts\"],\"check\":{\"file_naming\":\"invalid\"}}]}"
  assert_true(parse_config(json) is Err(_))
}

///|
test "config rejects file_rule without check" {
  let json = "{\"rules\":[],\"file_rules\":[{\"id\":\"file/x\",\"message\":\"m\",\"extensions\":[\".ts\"]}]}"
  assert_true(parse_config(json) is Err(_))
}

///|
test "config with no file_rules yields empty array" {
  let json = "{\"rules\":[{\"id\":\"r1\",\"message\":\"m\",\"match\":{\"contains\":\"x\"}}]}"
  let config = parse_config(json).unwrap()
  assert_eq(config.file_rules.length(), 0)
}

///|
test "config parses max_file_size check" {
  let json = "{\"rules\":[],\"file_rules\":[{\"id\":\"file/size\",\"message\":\"too big\",\"extensions\":[\".ts\"],\"check\":{\"max_file_size\":1000}}]}"
  let config = parse_config(json).unwrap()
  assert_eq(config.file_rules[0].check, MaxFileSize(1000))
}

///|
test "config parses no_empty_files check" {
  let json = "{\"rules\":[],\"file_rules\":[{\"id\":\"file/empty\",\"message\":\"empty\",\"extensions\":[],\"check\":{\"no_empty_files\":true}}]}"
  let config = parse_config(json).unwrap()
  assert_eq(config.file_rules[0].check, NoEmptyFiles)
}

///|
test "config parses line_ending check" {
  let json = "{\"rules\":[],\"file_rules\":[{\"id\":\"file/le\",\"message\":\"le\",\"extensions\":[\".ts\"],\"check\":{\"line_ending\":\"lf\"}}]}"
  let config = parse_config(json).unwrap()
  assert_eq(config.file_rules[0].check, LineEnding(Lf))
}

///|
test "config parses no_bom check" {
  let json = "{\"rules\":[],\"file_rules\":[{\"id\":\"file/bom\",\"message\":\"bom\",\"extensions\":[\".ts\"],\"check\":{\"no_bom\":true}}]}"
  let config = parse_config(json).unwrap()
  assert_eq(config.file_rules[0].check, NoBom)
}

///|
test "config rejects invalid line_ending style" {
  let json = "{\"rules\":[],\"file_rules\":[{\"id\":\"file/le\",\"message\":\"le\",\"extensions\":[\".ts\"],\"check\":{\"line_ending\":\"invalid\"}}]}"
  assert_true(parse_config(json) is Err(_))
}

///|
test "config parses structural_rules" {
  let json = "{\"structural_rules\":[{\"id\":\"imports/no-unused-imports\",\"severity\":\"error\",\"message\":\"m\",\"extensions\":[\".ts\"],\"check\":{\"no_unused_imports\":true}},{\"id\":\"imports/no-deep\",\"message\":\"m\",\"extensions\":[\".ts\"],\"check\":{\"no_deep_relative_imports\":2}}]}"
  let config = parse_config(json).unwrap()
  assert_eq(config.structural_rules.length(), 2)
  assert_eq(config.structural_rules[0].check, NoUnusedImports)
  assert_eq(config.structural_rules[0].severity, Error)
  assert_eq(config.structural_rules[1].check, NoDeepRelativeImports(2))
  assert_eq(config.structural_rules[1].severity, Warning)
}

///|
test "config: structural_rules alone satisfy the rules requirement" {
  let json = "{\"structural_rules\":[{\"id\":\"imports/no-import-cycles\",\"message\":\"m\",\"check\":{\"no_import_cycles\":true}}]}"
  assert_true(parse_config(json) is Ok(_))
}

///|
test "config: a duplicate structural rule id is rejected" {
  let json = "{\"structural_rules\":[{\"id\":\"imports/x\",\"message\":\"m\",\"check\":{\"no_import_cycles\":true}},{\"id\":\"imports/x\",\"message\":\"m\",\"check\":{\"no_default_export\":true}}]}"
  let message = match parse_config(json) {
    Ok(_) => "accepted"
    Err(ConfigError(m)) => m
  }
  assert_true(message.contains("duplicate structural_rule id"))
}

///|
test "config: an unknown structural check is rejected" {
  let json = "{\"structural_rules\":[{\"id\":\"imports/x\",\"message\":\"m\",\"check\":{\"no_such_check\":true}}]}"
  let message = match parse_config(json) {
    Ok(_) => "accepted"
    Err(ConfigError(m)) => m
  }
  assert_true(message.contains("check needs one of"))
}

///|
test "collect_extensions unions structural rule extensions" {
  let json = "{\"structural_rules\":[{\"id\":\"imports/x\",\"message\":\"m\",\"extensions\":[\".ts\",\".vue\"],\"check\":{\"no_import_cycles\":true}}]}"
  assert_eq(
    collect_extensions([], [], parse_config(json).unwrap().structural_rules),
    [".ts", ".vue"],
  )
}
