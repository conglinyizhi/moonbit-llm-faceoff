///|
/// Create a moonllm client for a settings block.
///
/// Typical callers can ignore this and use `ask` / `stream_to_stdout`, which
/// build the client themselves.
pub fn make_client(settings : Settings) -> @llm.Client {
  @llm.Client::new(
    settings.api_key,
    base_url=settings.base_url,
    timeout_ms=settings.timeout_ms,
  )
}

///|
/// Errors raised by this client.
///
/// Both paths flatten their lower-level errors into this type so callers do
/// not need to import the transport packages.
pub(all) suberror ClientError {
  /// The connection or TLS handshake failed, or the body ended mid-stream.
  Transport(String)
  /// The endpoint answered with a non-2xx status.
  Status(code~ : Int, message~ : String)
  /// The response body did not match the expected shape.
  Decode(String)
}

///|
pub fn ClientError::to_string(self : ClientError) -> String {
  match self {
    Transport(message) => "transport error: " + message
    Status(code~, message~) => "http \{code}: \{message}"
    Decode(message) => "decode error: " + message
  }
}

///|
/// Flatten a moonllm error so callers only ever see `ClientError`.
fn map_llm_error(err : @llm.LLMError) -> ClientError {
  match err {
    @llm.LLMError::Transport(message) => Transport(message)
    @llm.LLMError::ApiError(code~, message~) => Status(code~, message~)
    @llm.LLMError::Decode(message) => Decode(message)
    @llm.LLMError::Stream(message) => Transport(message)
  }
}

///|
/// Decode a non-streaming chat response body and return its first choice text.
pub fn response_text(json : Json) -> String raise ClientError {
  let response : @llm.ChatResponse = @json.from_json(json) catch {
    err => raise Decode(err.to_string())
  }
  choice_text(response)
}

///|
/// Send `prompt` and return the complete reply, without streaming.
///
/// Uses moonllm's typed `Client::chat`, so the response is decoded into
/// `@llm.ChatResponse` before the text is extracted.
pub async fn ask(
  settings : Settings,
  prompt : String,
) -> String raise ClientError {
  let client = make_client(settings)
  let request = build_request(settings, prompt)
  let response = client.chat(request) catch { err => raise map_llm_error(err) }
  choice_text(response)
}

///|
/// One incremental piece of a streamed reply.
pub(all) enum StreamPart {
  /// A fragment of the model's chain of thought.
  Reasoning(String)
  /// A fragment of the visible answer.
  Content(String)
} derive(Eq, Debug)

///|
pub extend StreamPart with Eq::{equal, not_equal}

///|
pub extend StreamPart with @debug.Debug::{to_repr}

///|
/// Everything collected from one streamed reply.
pub(all) struct StreamOutcome {
  /// The visible answer, concatenated.
  content : String
  /// The chain of thought, concatenated. Empty when the model has none.
  reasoning : String
  /// Token accounting, when the endpoint sent a usage block.
  usage : TokenUsage?
  /// Why the model stopped, when the endpoint said so.
  finish_reason : String?
}

///|
/// Stream a chat completion, forwarding every fragment to `on_part` and
/// returning the assembled reply.
///
/// This is the low-level streaming entry point; it reports reasoning fragments
/// as well as answer fragments, which is what a benchmark needs. For a plain
/// text stream, use `stream_chat`.
///
/// It talks to the raw endpoint instead of going through moonllm's
/// `chat_stream`, because that entry point takes a synchronous callback and so
/// cannot write to async stdout as fragments arrive.
///
/// `Settings::timeout_ms` is not applied here: a total-duration timeout would
/// cut off legitimately long streams, and an idle timeout would need a timer
/// around each read. The one-shot path does honor it.
pub async fn stream_parts(
  settings : Settings,
  prompt : String,
  on_part : async (StreamPart) -> Unit,
) -> StreamOutcome raise ClientError {
  let request = build_request(settings, prompt)
  request.stream = true
  let headers : Map[String, String] = {
    "Content-Type": "application/json",
    "Accept": "text/event-stream",
  }
  if settings.api_key != "" {
    headers["Authorization"] = "Bearer " + settings.api_key
  }
  let body = request.to_json().stringify()
  let client = @http.post_stream(settings.chat_completions_url(), headers~) catch {
    err => raise Transport(err.to_string())
  }
  defer client.close()
  let response = try {
    client.write(body)
    client.end_request()
  } catch {
    err => raise Transport(err.to_string())
  }
  if response.code < 200 || response.code >= 300 {
    // `text()` decodes the body as UTF-8. Do not use
    // `binary().to_unchecked_string()` here: that reinterprets the raw bytes as
    // UTF-16 code units and turns any non-ASCII error body into mojibake.
    let rest = client.read_all().text() catch { _ => "" }
    raise Status(code=response.code, message=rest)
  }
  let content = StringBuilder()
  let reasoning = StringBuilder()
  let mut usage : TokenUsage? = None
  let mut finish_reason : String? = None
  let mut done = false
  while !done {
    let line = client.read_until("\n") catch {
      err => raise Transport(err.to_string())
    }
    match line {
      None => break
      Some(text) =>
        match parse_sse_line(text) {
          Some(Content(fragment)) => {
            content.write_string(fragment)
            on_part(Content(fragment)) catch {
              err => raise Transport(err.to_string())
            }
          }
          Some(Reasoning(fragment)) => {
            reasoning.write_string(fragment)
            on_part(Reasoning(fragment)) catch {
              err => raise Transport(err.to_string())
            }
          }
          Some(Usage(tokens)) => usage = Some(tokens)
          Some(Finish(reason)) => finish_reason = Some(reason)
          Some(Done) => done = true
          _ => ()
        }
    }
  }
  {
    content: content.to_string(),
    reasoning: reasoning.to_string(),
    usage,
    finish_reason,
  }
}

///|
/// Stream a reply, forwarding only the visible answer fragments.
pub async fn stream_chat(
  settings : Settings,
  prompt : String,
  on_delta : async (String) -> Unit,
) -> String raise ClientError {
  let outcome = stream_parts(settings, prompt, async fn(part) {
    match part {
      Content(text) =>
        on_delta(text) catch {
          err => raise Transport(err.to_string())
        }
      Reasoning(_) => ()
    }
  })
  outcome.content
}

///|
/// Stream a reply straight to standard output.
///
/// Write failures on stdout (a closed pipe, for example) are dropped: there is
/// nothing useful left to do with them, and the caller still gets the text.
pub async fn stream_to_stdout(
  settings : Settings,
  prompt : String,
) -> String raise ClientError {
  stream_chat(settings, prompt, async fn(delta) {
    @stdio.stdout.write(delta) catch {
      _ => ()
    }
  })
}

///|
/// Read the whole of standard input, trimmed, as a prompt.
pub async fn read_prompt_from_stdin() -> String {
  let data = @stdio.stdin.read_all() catch { _ => return "" }
  let text = data.text() catch { _ => "" }
  text.trim(chars=" \t\r\n").to_owned()
}
