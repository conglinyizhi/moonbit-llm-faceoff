///|
/// A small client for OpenAI-compatible chat completion endpoints.
///
/// Two paths are provided:
///
/// - `ask`: one-shot, uses `DC-Z-lab/moonllm`'s typed `Client::chat`.
/// - `stream_chat` / `stream_to_stdout`: server-sent events, implemented
///   directly on `moonbitlang/async/http` so fragments can be written to
///   async stdout as they arrive.
///
/// Configuration is resolved from environment variables and command-line
/// flags by `Settings::from_env` and `Cli::parse`.
