///|
/// A small client for OpenAI-compatible chat completion endpoints.
///
/// Two paths are provided:
///
/// - `ask`: one-shot, decoded from the response JSON directly.
/// - `stream_chat` / `stream_to_stdout`: server-sent events, implemented
///   directly on `moonbitlang/async/http` so fragments can be written to
///   async stdout as they arrive.
///
/// Both paths talk to the endpoint themselves. The only dependency is the
/// standard library plus `moonbitlang/async` — no third-party LLM client sits
/// in between, so the wire format stays the visible contract (`request_body`
/// and `response_text` both deal in plain `Json`).
///
/// Configuration is resolved from environment variables and command-line
/// flags by `Settings::from_env` and `Cli::parse`.
