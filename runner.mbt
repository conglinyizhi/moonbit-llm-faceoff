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
/// Mask a key so it is still recognisable in a log without being usable.
///
/// The first two and the last two characters stay. That is enough for whoever
/// reads the error to tell *which* key was used, which is the reason for logging
/// it at all, and it matches what provider dashboards do (`sk-...ef`).
///
/// Anything shorter than 12 characters is masked whole: showing four characters
/// of an eight-character secret gives away half of it.
fn mask_key(key : String) -> String {
  let len = key.length()
  if len < 12 {
    "***"
  } else {
    key[:2].to_owned() + "***" + key[len - 2:].to_owned()
  }
}

///|
/// Strip the configured key out of text that came from upstream.
///
/// A non-2xx body is surfaced verbatim as `http <code>: <body>`, and that
/// string is then persisted — written to the bench run log, rendered on the web
/// page and served by `/api/runs`. A gateway that echoes the request headers in
/// its error text would therefore put the key in those places. Redacting where
/// the body enters our error type keeps every downstream consumer clean.
fn redact_key(text : String, key : String) -> String {
  if key == "" {
    text
  } else {
    text.replace_all(old=key, new=mask_key(key))
  }
}

///|
/// Decode a non-streaming chat response body and return its first choice text.
pub fn response_text(json : Json) -> String raise ClientError {
  let obj = match json {
    Object(obj) => obj
    _ => raise Decode("response is not a JSON object")
  }
  let choices = match obj.get("choices") {
    Some(Array(choices)) => choices
    _ => raise Decode("response has no choices")
  }
  let choice = match choices {
    [Object(choice), ..] => choice
    _ => raise Decode("response has no choices")
  }
  let message = match choice.get("message") {
    Some(Object(message)) => message
    _ => raise Decode("response choice has no message")
  }
  match message.get("content") {
    Some(String(text)) => text
    _ => ""
  }
}

///|
/// Send `prompt` and return the complete reply, without streaming.
///
/// Talks to the endpoint directly, same as the streaming path, so this module
/// depends on nothing but the standard library and the async runtime.
/// `Settings::timeout_ms` is honored here (the streaming path deliberately
/// leaves it to the OS).
pub async fn ask(
  settings : Settings,
  prompt : String,
) -> String raise ClientError {
  let headers : Map[String, String] = { "Content-Type": "application/json" }
  if settings.api_key != "" {
    headers["Authorization"] = "Bearer " + settings.api_key
  }
  let body = request_body(settings, prompt).stringify()
  let url = settings.chat_completions_url()
  let (response, data) = @async.with_timeout(settings.timeout_ms, async fn() {
    @http.post(url, body, headers~)
  }) catch {
    err => raise Transport("request failed or timed out: " + err.to_string())
  }
  // 错误体也要按 UTF-8 解码；用 to_unchecked_string() 会出乱码
  let text = data.text() catch { _ => "" }
  if response.code < 200 || response.code >= 300 {
    raise Status(code=response.code, message=redact_key(text, settings.api_key))
  }
  let json = @json.parse(text) catch { err => raise Decode(err.to_string()) }
  response_text(json)
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
/// Talk to the endpoint directly and frame the SSE stream here. Delegating
/// this to a client library would mean handing fragments to a *synchronous*
/// callback, and a synchronous callback cannot write to async stdout as they
/// arrive — which is exactly what streaming is for.
///
/// `Settings::timeout_ms` is not applied here: a total-duration timeout would
/// cut off legitimately long streams, and an idle timeout would need a timer
/// around each read. The one-shot path does honor it.
pub async fn stream_parts(
  settings : Settings,
  prompt : String,
  on_part : async (StreamPart) -> Unit,
) -> StreamOutcome raise ClientError {
  let body = request_body(settings, prompt, stream=true).stringify()
  let headers : Map[String, String] = {
    "Content-Type": "application/json",
    "Accept": "text/event-stream",
  }
  if settings.api_key != "" {
    headers["Authorization"] = "Bearer " + settings.api_key
  }
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
    raise Status(code=response.code, message=redact_key(rest, settings.api_key))
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
