///|
fn test_settings() -> Settings {
  let settings = Settings::from_env({ "MOONLLM_API_KEY": "k" })
  settings.model = "test-model"
  settings
}

///|
test "request_body carries model and both messages" {
  let body = request_body(test_settings(), "hi").stringify()
  assert_true(body.contains("\"model\":\"test-model\""))
  assert_true(body.contains("\"role\":\"system\""))
  assert_true(body.contains("\"role\":\"user\""))
  assert_true(body.contains("\"content\":\"hi\""))
  assert_true(body.contains("\"stream\":false"))
}

///|
test "request_body omits unset sampling options" {
  let body = request_body(test_settings(), "hi").stringify()
  assert_false(body.contains("temperature"))
  assert_false(body.contains("max_tokens"))
}

///|
test "request_body includes set sampling options" {
  let settings = test_settings()
  settings.temperature = Some(0.5)
  settings.max_tokens = Some(128)
  let body = request_body(settings, "hi").stringify()
  assert_true(body.contains("\"temperature\":0.5"))
  assert_true(body.contains("\"max_tokens\":128"))
}

///|
test "request_body can ask for a stream" {
  let body = request_body(test_settings(), "hi", stream=true).stringify()
  assert_true(body.contains("\"stream\":true"))
}

///|
test "response_text decodes the first choice" {
  let json = @json.parse(
    "{\"id\":\"1\",\"object\":\"chat.completion\",\"created\":0,\"model\":\"m\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"hello\"},\"finish_reason\":\"stop\"}]}",
  )
  assert_eq(response_text(json), "hello")
}

///|
test "response_text reports a malformed body instead of guessing" {
  let not_an_object = Ok(response_text(@json.parse("[]"))) catch {
    err => Err(err)
  }
  match not_an_object {
    Err(ClientError::Decode(_)) => ()
    _ => fail("expected Decode")
  }
  let no_choices = Ok(response_text(@json.parse("{\"id\":\"1\"}"))) catch {
    err => Err(err)
  }
  match no_choices {
    Err(ClientError::Decode(_)) => ()
    _ => fail("expected Decode")
  }
}

///|
test "response_text tolerates a null content" {
  let json = @json.parse(
    "{\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":null}}]}",
  )
  assert_eq(response_text(json), "")
}

///|
test "parse_sse_line extracts deltas" {
  assert_eq(
    parse_sse_line(
      "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hel\"}}]}",
    ),
    Some(SseEvent::Content("Hel")),
  )
  assert_eq(
    parse_sse_line("data:{\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}"),
    Some(SseEvent::Content("lo")),
  )
}

///|
test "parse_sse_line handles sentinels and noise" {
  assert_eq(parse_sse_line("data: [DONE]"), Some(SseEvent::Done))
  assert_eq(parse_sse_line(""), None)
  assert_eq(parse_sse_line("   "), None)
  assert_eq(parse_sse_line(": keep-alive"), None)
  assert_eq(parse_sse_line("event: message"), Some(SseEvent::Ignore))
}

///|
test "parse_sse_line ignores chunks without text" {
  assert_eq(
    parse_sse_line("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}"),
    Some(SseEvent::Ignore),
  )
  assert_eq(parse_sse_line("data: {not json}"), Some(SseEvent::Ignore))
  assert_eq(
    parse_sse_line("data: {\"id\":\"x\",\"object\":\"chat.completion.chunk\"}"),
    Some(SseEvent::Ignore),
  )
  assert_eq(
    parse_sse_line(
      "data: {\"choices\":[{\"delta\":{\"reasoning_content\":null,\"content\":\"\"}}]}",
    ),
    Some(SseEvent::Ignore),
  )
}

///|
test "parse_sse_line reports the stop reason" {
  assert_eq(
    parse_sse_line(
      "data: {\"choices\":[{\"delta\":{\"reasoning_content\":null},\"finish_reason\":\"stop\"}]}",
    ),
    Some(SseEvent::Finish("stop")),
  )
  assert_eq(
    parse_sse_line(
      "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}",
    ),
    Some(SseEvent::Finish("length")),
  )
}

///|
test "parse_sse_line separates reasoning from content" {
  assert_eq(
    parse_sse_line(
      "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"Thinking\"}}]}",
    ),
    Some(SseEvent::Reasoning("Thinking")),
  )
  // A chunk carrying both is timed as the answer.
  assert_eq(
    parse_sse_line(
      "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"x\",\"content\":\"5\"}}]}",
    ),
    Some(SseEvent::Content("5")),
  )
}

///|
test "parse_sse_line reads the usage block" {
  assert_eq(
    parse_sse_line(
      "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":17,\"completion_tokens\":68,\"reasoning_tokens\":65}}",
    ),
    Some(SseEvent::Usage(TokenUsage::new(17, 68, 65))),
  )
  // Missing fields default to zero rather than failing the run.
  assert_eq(
    parse_sse_line("data: {\"choices\":[],\"usage\":{\"prompt_tokens\":3}}"),
    Some(SseEvent::Usage(TokenUsage::new(3, 0, 0))),
  )
}

///|
test "parse_sse_line tolerates carriage returns" {
  assert_eq(parse_sse_line("data: [DONE]\r"), Some(SseEvent::Done))
  assert_eq(
    parse_sse_line("data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\r"),
    Some(SseEvent::Content("x")),
  )
}

///|
test "response_outcome keeps the stop reason and the token accounting" {
  let json = @json.parse(
    "{\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"hi\",\"reasoning_content\":\"thinking\"},\"finish_reason\":\"length\"}],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":4,\"reasoning_tokens\":4}}",
  )
  let outcome = response_outcome(json)
  assert_eq(outcome.content, "hi")
  assert_eq(outcome.reasoning, "thinking")
  assert_eq(outcome.finish_reason, Some("length"))
  assert_eq(outcome.usage, Some(TokenUsage::new(11, 4, 4)))
}

///|
test "response_outcome reports an empty answer as empty, not as an error" {
  let json = @json.parse(
    "{\"choices\":[{\"index\":0,\"message\":{\"content\":\"\",\"reasoning_content\":\"spent the whole budget\"},\"finish_reason\":\"length\"}],\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":4,\"reasoning_tokens\":4}}",
  )
  let outcome = response_outcome(json)
  assert_eq(outcome.content, "")
  assert_eq(outcome.reasoning, "spent the whole budget")
  assert_eq(outcome.finish_reason, Some("length"))
}

///|
test "response_outcome tolerates a missing usage block and stop reason" {
  let json = @json.parse("{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}")
  let outcome = response_outcome(json)
  assert_eq(outcome.content, "ok")
  assert_eq(outcome.reasoning, "")
  assert_true(outcome.usage is None)
  assert_true(outcome.finish_reason is None)
}

///|
test "response_outcome rejects a body with no choices" {
  let result = Ok(response_outcome(@json.parse("{\"id\":\"1\"}"))) catch {
    err => Err(err)
  }
  match result {
    Err(ClientError::Decode(_)) => ()
    _ => fail("expected Decode")
  }
}

///|
test "request_body：推理开关按开关走，不勾就不发" {
  let plain = request_body(test_settings(), "hi").stringify()
  assert_false(plain.contains("enable_thinking"))
  assert_false(plain.contains("reasoning_effort"))

  let thinking = test_settings()
  thinking.enable_thinking = true
  let body = request_body(thinking, "hi").stringify()
  assert_true(body.contains("\"enable_thinking\":true"))
  assert_false(body.contains("reasoning_effort"))

  // 两种风格可以同时带（不同端点认不同的名字）
  let effort = test_settings()
  effort.reasoning_effort = Some("high")
  let body2 = request_body(effort, "hi").stringify()
  assert_true(body2.contains("\"reasoning_effort\":\"high\""))
  assert_false(body2.contains("enable_thinking"))
}
