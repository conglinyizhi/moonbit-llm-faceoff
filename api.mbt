///|
/// Build the chat request for `prompt` under `settings`.
pub fn build_request(settings : Settings, prompt : String) -> @llm.ChatRequest {
  let messages = [
    @llm.Message::system(settings.system),
    @llm.Message::user(prompt),
  ]
  let request = @llm.ChatRequest::new(settings.model, messages)
  if settings.temperature is Some(t) {
    request.temperature(t) |> ignore
  }
  if settings.max_tokens is Some(n) {
    request.max_tokens(n) |> ignore
  }
  request
}

///|
/// The text of the first choice in a chat completion response.
pub fn choice_text(response : @llm.ChatResponse) -> String {
  match response.choices {
    [choice, ..] => choice.message.content.to_text()
    [] => ""
  }
}

///|
/// Token accounting from a `usage` block.
///
/// Reasoning models report `reasoning_tokens` separately; on those, the
/// completion count is thinking plus answer, which is why it is tracked here
/// rather than collapsed into one number.
pub(all) struct TokenUsage {
  prompt_tokens : Int
  completion_tokens : Int
  reasoning_tokens : Int
} derive(Eq, Debug)

///|
pub extend TokenUsage with Eq::{equal, not_equal}

///|
pub extend TokenUsage with @debug.Debug::{to_repr}

///|
/// Build a token accounting record.
pub fn TokenUsage::new(
  prompt_tokens : Int,
  completion_tokens : Int,
  reasoning_tokens : Int,
) -> TokenUsage {
  { prompt_tokens, completion_tokens, reasoning_tokens, }
}

///|
/// The share of the completion budget spent thinking, in `[0, 1]`.
///
/// Returns 0 when the model reported no completion tokens at all.
pub fn TokenUsage::reasoning_ratio(self : TokenUsage) -> Double {
  if self.completion_tokens == 0 {
    0.0
  } else {
    self.reasoning_tokens.to_double() / self.completion_tokens.to_double()
  }
}

///|
/// A meaningful line of an OpenAI-compatible server-sent event stream.
pub(all) enum SseEvent {
  /// An incremental fragment of the visible answer.
  Content(String)
  /// An incremental fragment of the model's chain of thought.
  Reasoning(String)
  /// The final `usage` block, sent in a chunk whose `choices` array is empty.
  Usage(TokenUsage)
  /// The reason the model stopped (`stop`, `length`, `tool_calls`, ...).
  /// `length` means the reply was truncated by the token budget.
  Finish(String)
  /// The `[DONE]` sentinel. The stream is over.
  Done
  /// A line we understood but that carries nothing we track (role-only chunk,
  /// finish reason, tool-call delta, keep-alive comment, ...).
  Ignore
} derive(Eq, Debug)

///|
pub extend SseEvent with Eq::{equal, not_equal}

///|
pub extend SseEvent with @debug.Debug::{to_repr}

///|
/// Parse one SSE line from a chat completions stream.
///
/// `None` means "skip": a blank line, a comment, or a non-`data:` field.
pub fn parse_sse_line(line : String) -> SseEvent? {
  let text = line.trim(chars=" \t\r\n")
  if text.length() == 0 || text.has_prefix(":") {
    return None
  }
  if !text.has_prefix("data:") {
    return Some(Ignore)
  }
  let payload = text[5:].trim(chars=" \t\r\n").to_owned()
  if payload == "[DONE]" {
    return Some(Done)
  }
  let parsed = @json.parse(payload) catch { _ => return Some(Ignore) }
  Some(parse_stream_chunk(parsed))
}

///|
/// Turn one decoded stream chunk into an event.
///
/// Within a chunk the visible answer wins over the reasoning: if a chunk ever
/// carried both, the answer is what the caller is timing.
fn parse_stream_chunk(json : Json) -> SseEvent {
  guard json is Object(obj) else { return Ignore }
  let choices = match obj.get("choices") {
    Some(Array(choices)) => choices
    _ => []
  }
  if choices.length() > 0 {
    return parse_choice(choices)
  }
  match obj.get("usage") {
    Some(Object(usage)) => Usage(parse_usage(usage))
    _ => Ignore
  }
}

///|
fn parse_choice(choices : Array[Json]) -> SseEvent {
  let choice = match choices {
    [Object(choice), ..] => choice
    _ => return Ignore
  }
  let delta = match choice.get("delta") {
    Some(Object(delta)) => delta
    _ => return Ignore
  }
  match non_empty_string(delta.get("content")) {
    Some(text) => return Content(text)
    None => ()
  }
  match non_empty_string(delta.get("reasoning_content")) {
    Some(text) => return Reasoning(text)
    None => ()
  }
  match non_empty_string(choice.get("finish_reason")) {
    Some(reason) => Finish(reason)
    None => Ignore
  }
}

///|
fn parse_usage(usage : Map[String, Json]) -> TokenUsage {
  {
    prompt_tokens: int_field(usage, "prompt_tokens"),
    completion_tokens: int_field(usage, "completion_tokens"),
    reasoning_tokens: int_field(usage, "reasoning_tokens"),
  }
}

///|
/// The string value of a field, treating null and `""` as absent.
fn non_empty_string(value : Json?) -> String? {
  match value {
    Some(String(text)) => if text.length() == 0 { None } else { Some(text) }
    _ => None
  }
}

///|
fn int_field(obj : Map[String, Json], key : String) -> Int {
  match obj.get(key) {
    Some(Number(n, ..)) => n.to_int()
    _ => 0
  }
}
