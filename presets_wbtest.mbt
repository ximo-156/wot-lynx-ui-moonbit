///|
/// Tests for the built-in framework presets.

///|
test "preset_names lists all presets sorted" {
  let names = preset_names()
  assert_eq(names.length(), 10)
  assert_eq(names[0], "angular")
  assert_eq(names[1], "astro")
  assert_eq(names[2], "common")
  assert_eq(names[3], "file")
  assert_eq(names[4], "next")
  assert_eq(names[5], "nuxt")
  assert_eq(names[6], "react")
  assert_eq(names[7], "solid")
  assert_eq(names[8], "svelte")
  assert_eq(names[9], "vue")
}

///|
test "preset_by_name finds known presets" {
  assert_true(preset_by_name("react") is Some(_))
  assert_true(preset_by_name("vue") is Some(_))
  assert_true(preset_by_name("angular") is Some(_))
  assert_true(preset_by_name("svelte") is Some(_))
  assert_true(preset_by_name("next") is Some(_))
  assert_true(preset_by_name("common") is Some(_))
  assert_true(preset_by_name("file") is Some(_))
}

///|
test "preset_by_name returns None for unknown" {
  assert_true(preset_by_name("unknown") is None)
  assert_true(preset_by_name("") is None)
  assert_true(preset_by_name("React") is None)
}

///|
test "merge_presets rejects unknown preset" {
  let result = merge_presets(["nonexistent"])
  assert_true(result is Err(_))
}

///|
test "merge_presets with empty list yields empty config" {
  let config = merge_presets([]).unwrap()
  assert_eq(config.rules.length(), 0)
  assert_true(config.scope.is_empty())
}

///|
test "merge_presets single preset has rules" {
  let config = merge_presets(["react"]).unwrap()
  assert_true(config.rules.length() > 0)
  assert_true(config.scope.is_empty())
}

///|
test "merge_presets deduplicates by rule id" {
  let config = merge_presets(["react", "react"]).unwrap()
  let single = merge_presets(["react"]).unwrap()
  assert_eq(config.rules.length(), single.rules.length())
}

///|
test "merge_presets combines different presets" {
  let react = merge_presets(["react"]).unwrap()
  let common = merge_presets(["common"]).unwrap()
  let merged = merge_presets(["react", "common"]).unwrap()
  assert_eq(merged.rules.length(), react.rules.length() + common.rules.length())
}

///|
test "merge_presets first occurrence wins on id conflict" {
  let config = merge_presets(["react", "common", "vue"]).unwrap()
  let ids : Array[String] = config.rules.map(r => r.id)
  let unique : Set[String] = Set::from_iter(ids.iter())
  assert_eq(ids.length(), unique.length())
}

///|
test "all preset rules have valid regexes" {
  for name in preset_names() {
    let config = merge_presets([name]).unwrap()
    match validate_rules(config.rules) {
      Ok(_) => ()
      Err(ConfigError(message)) =>
        fail("preset \{name} has invalid regex: \{message}")
    }
  }
}

///|
test "all preset rules have non-empty id and message" {
  for name in preset_names() {
    let config = merge_presets([name]).unwrap()
    for r in config.rules {
      assert_true(r.id.length() > 0)
      assert_true(r.message.length() > 0)
    }
  }
}

///|
test "all preset rules have extensions" {
  for name in preset_names() {
    let config = merge_presets([name]).unwrap()
    for r in config.rules {
      assert_true(r.extensions.length() > 0)
    }
  }
}

///|
test "render_preset_list contains all preset names" {
  let text = render_preset_list()
  for name in preset_names() {
    assert_true(text.contains(name))
  }
}

///|
test "render_preset_list is sorted alphabetically" {
  let text = render_preset_list()
  let lines = text.split("\n").to_array()
  assert_eq(lines.length(), 10)
  assert_true(lines[0].has_prefix("angular"))
  assert_true(lines[1].has_prefix("astro"))
  assert_true(lines[2].has_prefix("common"))
  assert_true(lines[3].has_prefix("file"))
  assert_true(lines[4].has_prefix("next"))
  assert_true(lines[5].has_prefix("nuxt"))
  assert_true(lines[6].has_prefix("react"))
  assert_true(lines[7].has_prefix("solid"))
  assert_true(lines[8].has_prefix("svelte"))
  assert_true(lines[9].has_prefix("vue"))
}

///|
test "react preset has expected rule count" {
  let config = merge_presets(["react"]).unwrap()
  assert_eq(config.rules.length(), 20)
}

///|
test "vue preset has expected rule count" {
  let config = merge_presets(["vue"]).unwrap()
  assert_eq(config.rules.length(), 11)
}

///|
test "common preset has expected rule count" {
  let config = merge_presets(["common"]).unwrap()
  assert_eq(config.rules.length(), 5)
}

///|
test "angular preset has expected rule count" {
  let config = merge_presets(["angular"]).unwrap()
  assert_eq(config.rules.length(), 9)
}

///|
test "svelte preset has expected rule count" {
  let config = merge_presets(["svelte"]).unwrap()
  assert_eq(config.rules.length(), 8)
}

///|
test "next preset has expected rule count" {
  let config = merge_presets(["next"]).unwrap()
  assert_eq(config.rules.length(), 7)
}

///|
test "preset rules use framework-prefixed ids" {
  for name in preset_names() {
    let config = merge_presets([name]).unwrap()
    for r in config.rules {
      assert_true(r.id.has_prefix("\{name}/"))
    }
  }
}

///|
test "merge_presets preserves rule order within each preset" {
  let config = merge_presets(["react"]).unwrap()
  assert_eq(config.rules[0].id, "react/no-danger")
  assert_eq(config.rules[config.rules.length() - 1].id, "react/jsx-no-bind")
}

///|
test "merge_presets concatenates in preset order" {
  let config = merge_presets(["common", "react"]).unwrap()
  assert_eq(config.rules[0].id, "common/no-console-log")
  assert_eq(config.rules[4].id, "common/no-var")
  assert_eq(config.rules[5].id, "react/no-danger")
}

///|
test "file preset has expected file rule count" {
  let config = merge_presets(["file"]).unwrap()
  assert_eq(config.file_rules.length(), 6)
  assert_eq(config.rules.length(), 0)
}

///|
test "file preset file rules have valid ids" {
  let config = merge_presets(["file"]).unwrap()
  assert_eq(config.file_rules[0].id, "file/max-lines")
  assert_eq(config.file_rules[1].id, "file/max-line-length")
  assert_eq(config.file_rules[2].id, "file/no-trailing-whitespace")
  assert_eq(config.file_rules[3].id, "file/no-tabs")
  assert_eq(config.file_rules[4].id, "file/final-newline")
  assert_eq(config.file_rules[5].id, "file/no-duplicate-lines")
}

///|
test "merge_presets merges file rules from multiple presets" {
  let config = merge_presets(["file", "react"]).unwrap()
  assert_eq(config.file_rules.length(), 6)
  assert_eq(config.rules.length(), 20)
}

///|
test "merge_presets deduplicates file rules by id" {
  let config = merge_presets(["file", "file"]).unwrap()
  assert_eq(config.file_rules.length(), 6)
}

///|
test "solid preset has expected rule count" {
  let config = merge_presets(["solid"]).unwrap()
  assert_eq(config.rules.length(), 6)
}

///|
test "astro preset has expected rule count" {
  let config = merge_presets(["astro"]).unwrap()
  assert_eq(config.rules.length(), 5)
}

///|
test "nuxt preset has expected rule count" {
  let config = merge_presets(["nuxt"]).unwrap()
  assert_eq(config.rules.length(), 5)
}

///|
test "all preset file rules have valid checks" {
  for name in preset_names() {
    let config = merge_presets([name]).unwrap()
    for fr in config.file_rules {
      assert_true(fr.id.length() > 0)
      assert_true(fr.message.length() > 0)
      assert_true(fr.extensions.length() > 0)
    }
  }
}
