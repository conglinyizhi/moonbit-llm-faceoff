///|
fn test_settings() -> @llm_client.Settings {
  let settings = @llm_client.Settings::from_env({ "MOONLLM_API_KEY": "k" })
  settings.model = "test-model"
  settings
}

///|
test "request_body carries model and both messages" {
  let body = @llm_client.request_body(test_settings(), "hi").stringify()
  assert_true(body.contains("\"model\":\"test-model\""))
  assert_true(body.contains("\"role\":\"system\""))
  assert_true(body.contains("\"role\":\"user\""))
  assert_true(body.contains("\"content\":\"hi\""))
  assert_true(body.contains("\"stream\":false"))
}

///|
test "request_body omits unset sampling options" {
  let body = @llm_client.request_body(test_settings(), "hi").stringify()
  assert_false(body.contains("temperature"))
  assert_false(body.contains("max_tokens"))
}

///|
test "request_body includes set sampling options" {
  let settings = test_settings()
  settings.temperature = Some(0.5)
  settings.max_tokens = Some(128)
  let body = @llm_client.request_body(settings, "hi").stringify()
  assert_true(body.contains("\"temperature\":0.5"))
  assert_true(body.contains("\"max_tokens\":128"))
}

///|
test "request_body can ask for a stream" {
  let body = @llm_client.request_body(test_settings(), "hi", stream=true).stringify()
  assert_true(body.contains("\"stream\":true"))
}

///|
test "response_text decodes the first choice" {
  let json = @json.parse(
    "{\"id\":\"1\",\"object\":\"chat.completion\",\"created\":0,\"model\":\"m\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"hello\"},\"finish_reason\":\"stop\"}]}",
  )
  assert_eq(@llm_client.response_text(json), "hello")
}

///|
test "response_text reports a malformed body instead of guessing" {
  let not_an_object = Ok(@llm_client.response_text(@json.parse("[]"))) catch {
    err => Err(err)
  }
  match not_an_object {
    Err(@llm_client.ClientError::Decode(_)) => ()
    _ => fail("expected Decode")
  }
  let no_choices = Ok(@llm_client.response_text(@json.parse("{\"id\":\"1\"}"))) catch {
    err => Err(err)
  }
  match no_choices {
    Err(@llm_client.ClientError::Decode(_)) => ()
    _ => fail("expected Decode")
  }
}

///|
test "response_text tolerates a null content" {
  let json = @json.parse(
    "{\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":null}}]}",
  )
  assert_eq(@llm_client.response_text(json), "")
}

///|
test "parse_sse_line extracts deltas" {
  assert_eq(
    @llm_client.parse_sse_line(
      "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hel\"}}]}",
    ),
    Some(@llm_client.SseEvent::Content("Hel")),
  )
  assert_eq(
    @llm_client.parse_sse_line(
      "data:{\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}",
    ),
    Some(@llm_client.SseEvent::Content("lo")),
  )
}

///|
test "parse_sse_line handles sentinels and noise" {
  assert_eq(
    @llm_client.parse_sse_line("data: [DONE]"),
    Some(@llm_client.SseEvent::Done),
  )
  assert_eq(@llm_client.parse_sse_line(""), None)
  assert_eq(@llm_client.parse_sse_line("   "), None)
  assert_eq(@llm_client.parse_sse_line(": keep-alive"), None)
  assert_eq(
    @llm_client.parse_sse_line("event: message"),
    Some(@llm_client.SseEvent::Ignore),
  )
}

///|
test "parse_sse_line ignores chunks without text" {
  assert_eq(
    @llm_client.parse_sse_line(
      "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}",
    ),
    Some(@llm_client.SseEvent::Ignore),
  )
  assert_eq(
    @llm_client.parse_sse_line("data: {not json}"),
    Some(@llm_client.SseEvent::Ignore),
  )
  assert_eq(
    @llm_client.parse_sse_line(
      "data: {\"id\":\"x\",\"object\":\"chat.completion.chunk\"}",
    ),
    Some(@llm_client.SseEvent::Ignore),
  )
  assert_eq(
    @llm_client.parse_sse_line(
      "data: {\"choices\":[{\"delta\":{\"reasoning_content\":null,\"content\":\"\"}}]}",
    ),
    Some(@llm_client.SseEvent::Ignore),
  )
}

///|
test "parse_sse_line reports the stop reason" {
  assert_eq(
    @llm_client.parse_sse_line(
      "data: {\"choices\":[{\"delta\":{\"reasoning_content\":null},\"finish_reason\":\"stop\"}]}",
    ),
    Some(@llm_client.SseEvent::Finish("stop")),
  )
  assert_eq(
    @llm_client.parse_sse_line(
      "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}",
    ),
    Some(@llm_client.SseEvent::Finish("length")),
  )
}

///|
test "parse_sse_line separates reasoning from content" {
  assert_eq(
    @llm_client.parse_sse_line(
      "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"Thinking\"}}]}",
    ),
    Some(@llm_client.SseEvent::Reasoning("Thinking")),
  )
  // A chunk carrying both is timed as the answer.
  assert_eq(
    @llm_client.parse_sse_line(
      "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"x\",\"content\":\"5\"}}]}",
    ),
    Some(@llm_client.SseEvent::Content("5")),
  )
}

///|
test "parse_sse_line reads the usage block" {
  assert_eq(
    @llm_client.parse_sse_line(
      "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":17,\"completion_tokens\":68,\"reasoning_tokens\":65}}",
    ),
    Some(@llm_client.SseEvent::Usage(@llm_client.TokenUsage::new(17, 68, 65))),
  )
  // Missing fields default to zero rather than failing the run.
  assert_eq(
    @llm_client.parse_sse_line(
      "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":3}}",
    ),
    Some(@llm_client.SseEvent::Usage(@llm_client.TokenUsage::new(3, 0, 0))),
  )
}

///|
test "parse_sse_line tolerates carriage returns" {
  assert_eq(
    @llm_client.parse_sse_line("data: [DONE]\r"),
    Some(@llm_client.SseEvent::Done),
  )
  assert_eq(
    @llm_client.parse_sse_line(
      "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\r",
    ),
    Some(@llm_client.SseEvent::Content("x")),
  )
}
