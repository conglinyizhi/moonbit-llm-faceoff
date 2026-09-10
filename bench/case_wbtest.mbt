///|
test "jsonl suite skips blanks and comments" {
  let text =
    #|# a comment
    #|{"id": "a", "prompt": "first"}
    #|
    #|{"id": "b", "prompt": "second", "max_tokens": 64, "temperature": 0.2}
  let cases = parse_cases(text)
  assert_eq(cases.length(), 2)
  assert_eq(cases[0].id, "a")
  assert_eq(cases[0].prompt, "first")
  assert_eq(cases[0].max_tokens, None)
  assert_eq(cases[1].max_tokens, Some(64))
  assert_eq(cases[1].temperature, Some(0.2))
}

///|
test "json array suite is accepted too" {
  let cases = parse_cases(
    "[{\"prompt\": \"one\"}, {\"id\": \"two\", \"prompt\": \"two\"}]",
  )
  assert_eq(cases.length(), 2)
  assert_eq(cases[0].id, "case-1")
  assert_eq(cases[1].id, "two")
}

///|
test "suite errors are reported with a position" {
  let missing = Ok(parse_cases("{\"id\": \"a\"}")) catch { err => Err(err) }
  match missing {
    Err(CaseError::MissingPrompt(line~)) => assert_eq(line, 1)
    _ => fail("expected MissingPrompt")
  }
  let not_object = Ok(parse_cases("[1, 2]")) catch { err => Err(err) }
  match not_object {
    Err(CaseError::BadCase(line~, ..)) => assert_eq(line, 1)
    _ => fail("expected BadCase")
  }
}

///|
test "an empty suite is rejected" {
  let empty = Ok(parse_cases("   \n  ")) catch { err => Err(err) }
  match empty {
    Err(CaseError::EmptySuite) => ()
    _ => fail("expected EmptySuite")
  }
}

///|
test "case defaults get filled in" {
  let case = Case::new("x", "prompt")
  assert_eq(case.system, None)
  assert_eq(case.max_tokens, None)
  assert_eq(case.temperature, None)
}
