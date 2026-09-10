///|
/// Connection and generation settings for an OpenAI-compatible endpoint.
pub(all) struct Settings {
  /// Bearer token. Empty means no `Authorization` header is sent.
  mut api_key : String
  /// API base URL, without a trailing slash. Defaults to the OpenAI endpoint.
  mut base_url : String
  /// Model id sent in the request body.
  mut model : String
  /// System prompt prepended to every request.
  mut system : String
  /// Sampling temperature, when set.
  mut temperature : Double?
  /// Cap on generated tokens, when set.
  mut max_tokens : Int?
  /// Per-request timeout in milliseconds.
  mut timeout_ms : Int
} derive(Eq)

///|
pub extend Settings with Eq::{equal, not_equal}

///|
pub let default_base_url : String = "https://api.openai.com/v1"

///|
pub let default_model : String = "gpt-4o-mini"

///|
pub let default_system : String = "You are a helpful assistant."

///|
pub let default_timeout_ms : Int = 60000

///|
/// Errors raised while resolving settings or parsing arguments.
pub(all) suberror ConfigError {
  /// No API key was found and `--no-key` was not given.
  MissingApiKey
  /// A flag that needs a value was the last token on the command line.
  MissingValue(flag~ : String)
  /// A numeric flag could not be parsed.
  BadNumber(flag~ : String, value~ : String)
  /// An unrecognized `-`/`--` flag.
  UnknownFlag(flag~ : String)
}

///|
pub fn ConfigError::to_string(self : ConfigError) -> String {
  match self {
    MissingApiKey =>
      "missing API key: set MOONLLM_API_KEY or OPENAI_API_KEY, pass --api-key, or use --no-key for local endpoints"
    MissingValue(flag~) => "missing value for \{flag}"
    BadNumber(flag~, value~) => "invalid number for \{flag}: \{value}"
    UnknownFlag(flag~) => "unknown flag: \{flag}"
  }
}

///|
/// The first non-empty value among `keys`, in order.
fn first_env(env : Map[String, String], keys : Array[String]) -> String? {
  for key in keys {
    match env.get(key) {
      Some(value) => if value != "" { return Some(value) }
      None => ()
    }
  }
  None
}

///|
/// Resolve settings from environment variables, applying defaults.
///
/// Per-field lookup order:
///
/// - API key: `MOONLLM_API_KEY`, `OPENAI_API_KEY`, `LLM_API_KEY`
/// - base URL: `MOONLLM_BASE_URL`, `OPENAI_BASE_URL`
/// - model: `MOONLLM_MODEL`, `OPENAI_MODEL`
/// - system: `MOONLLM_SYSTEM`
pub fn Settings::from_env(env : Map[String, String]) -> Settings {
  {
    api_key: first_env(env, ["MOONLLM_API_KEY", "OPENAI_API_KEY", "LLM_API_KEY"]).unwrap_or(
      "",
    ),
    base_url: first_env(env, ["MOONLLM_BASE_URL", "OPENAI_BASE_URL"]).unwrap_or(
      default_base_url,
    ),
    model: first_env(env, ["MOONLLM_MODEL", "OPENAI_MODEL"]).unwrap_or(
      default_model,
    ),
    system: first_env(env, ["MOONLLM_SYSTEM"]).unwrap_or(default_system),
    temperature: None,
    max_tokens: None,
    timeout_ms: default_timeout_ms,
  }
}

///|
/// The `chat/completions` URL for this base URL.
pub fn Settings::chat_completions_url(self : Settings) -> String {
  if self.base_url.has_suffix("/") {
    self.base_url + "chat/completions"
  } else {
    self.base_url + "/chat/completions"
  }
}
