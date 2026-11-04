///|
test "config rejects ignored scope and unknown fields at every level" {
  for
    source in [
      "{\"rules\":[],\"scope\":{\"exclude\":[\"src/**\"]}}", "{\"rules\":[],\"exlcude\":[\"src/**\"]}",
      "{\"rules\":[{\"id\":\"r\",\"message\":\"m\",\"scope\":{},\"match\":{\"contains\":\"x\"}}]}",
      "{\"structural_rules\":[{\"id\":\"r\",\"message\":\"m\",\"scope\":{},\"check\":{\"moonbit_naming\":true}}]}",
      "{\"file_rules\":[{\"id\":\"r\",\"message\":\"m\",\"extensons\":[\".mbt\"],\"check\":{\"no_tabs\":true}}]}",
    ] {
    assert_true(parse_config(source) is Err(_))
  }
}

///|
test "config rejects invalid severities extension types and duplicate JSON fields" {
  for
    source in [
      "{\"rules\":[{\"id\":\"r\",\"message\":\"m\",\"severity\":\"erorr\",\"match\":{\"contains\":\"x\"}}]}",
      "{\"rules\":[{\"id\":\"r\",\"message\":\"m\",\"severity\":false,\"match\":{\"contains\":\"x\"}}]}",
      "{\"rules\":[{\"id\":\"r\",\"message\":\"m\",\"extensions\":\".mbt\",\"match\":{\"contains\":\"x\"}}]}",
      "{\"rules\":[{\"id\":\"r\",\"message\":\"m\",\"extensions\":[3],\"match\":{\"contains\":\"x\"}}]}",
      "{\"rules\":[],\"rules\":[]}",
    ] {
    assert_true(parse_config(source) is Err(_))
  }
}

///|
test "config checks and matchers require one supported key with correct value" {
  for
    source in [
      "{\"rules\":[{\"id\":\"r\",\"message\":\"m\",\"match\":{\"contains\":\"x\",\"regex\":\"x\"}}]}",
      "{\"file_rules\":[{\"id\":\"r\",\"message\":\"m\",\"check\":{\"no_tabs\":false}}]}",
      "{\"file_rules\":[{\"id\":\"r\",\"message\":\"m\",\"check\":{\"max_lines\":1.2}}]}",
      "{\"file_rules\":[{\"id\":\"r\",\"message\":\"m\",\"check\":{\"max_lines\":-1}}]}",
      "{\"structural_rules\":[{\"id\":\"r\",\"message\":\"m\",\"check\":{\"moonbit_naming\":true,\"moonbit_require_public_doc\":true}}]}",
      "{\"structural_rules\":[{\"id\":\"r\",\"message\":\"m\",\"check\":{\"moonbit_naming\":false}}]}",
    ] {
    assert_true(parse_config(source) is Err(_))
  }
}
