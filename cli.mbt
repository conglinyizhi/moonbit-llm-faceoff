///|
/// A parsed command line.
pub(all) struct Cli {
  settings : Settings
  /// Prompt collected from positional arguments; `None` means "read stdin".
  prompt : String?
  /// Stream the reply token by token.
  stream : Bool
  /// Print usage and exit.
  show_help : Bool
}

///|
pub let usage : String =
  #|faceoff — ask an OpenAI-compatible chat completion endpoint
  #|
  #|usage:
  #|  faceoff [options] [prompt ...]
  #|  echo "a question" | faceoff [options]
  #|
  #|options:
  #|  -s, --stream          stream the reply as it is generated
  #|      --model <id>      model id        (env MOONLLM_MODEL / OPENAI_MODEL)
  #|      --base-url <url>  API base URL    (env MOONLLM_BASE_URL / OPENAI_BASE_URL)
  #|      --api-key <key>   API key         (env MOONLLM_API_KEY / OPENAI_API_KEY / LLM_API_KEY)
  #|      --system <text>   system prompt   (env MOONLLM_SYSTEM)
  #|      --temperature <t> sampling temperature
  #|      --max-tokens <n>  maximum generated tokens
  #|      --timeout-ms <n>  per-request timeout, defaults to 60000
  #|      --no-key          allow an empty API key (local endpoints)
  #|  -h, --help            show this help
  #|
  #|  --                    treat every following argument as prompt text

///|
/// Parse `argv` (without the program name) into a `Cli`.
pub fn Cli::parse(
  env : Map[String, String],
  argv : Array[String],
) -> Cli raise ConfigError {
  let settings = Settings::from_env(env)
  let prompt_parts : Array[String] = []
  let mut stream = false
  let mut show_help = false
  let mut no_key = false
  let mut literal = false
  let mut i = 0
  while i < argv.length() {
    let arg = argv[i]
    i = i + 1
    if literal {
      prompt_parts.push(arg)
      continue
    }
    match arg {
      "-s" | "--stream" => stream = true
      "-h" | "--help" => show_help = true
      "--no-key" => no_key = true
      "--" => literal = true
      "--model" => {
        settings.model = next_value(argv, i, "--model")
        i = i + 1
      }
      "--base-url" => {
        settings.base_url = next_value(argv, i, "--base-url")
        i = i + 1
      }
      "--api-key" => {
        settings.api_key = next_value(argv, i, "--api-key")
        i = i + 1
      }
      "--system" => {
        settings.system = next_value(argv, i, "--system")
        i = i + 1
      }
      "--temperature" => {
        let raw = next_value(argv, i, "--temperature")
        i = i + 1
        settings.temperature = Some(parse_double_flag("--temperature", raw))
      }
      "--max-tokens" => {
        let raw = next_value(argv, i, "--max-tokens")
        i = i + 1
        settings.max_tokens = Some(parse_int_flag("--max-tokens", raw))
      }
      "--timeout-ms" => {
        let raw = next_value(argv, i, "--timeout-ms")
        i = i + 1
        settings.timeout_ms = parse_int_flag("--timeout-ms", raw)
      }
      _ =>
        if arg.has_prefix("-") && arg.length() > 1 {
          raise UnknownFlag(flag=arg)
        } else {
          prompt_parts.push(arg)
        }
    }
  }
  if settings.base_url == "" {
    settings.base_url = default_base_url
  }
  if !show_help && settings.api_key == "" && !no_key {
    raise MissingApiKey
  }
  {
    settings,
    prompt: if prompt_parts.is_empty() {
      None
    } else {
      Some(prompt_parts.join(" "))
    },
    stream,
    show_help,
  }
}

///|
/// The value that must follow a flag, or a `MissingValue` error.
fn next_value(
  argv : Array[String],
  i : Int,
  flag : String,
) -> String raise ConfigError {
  if i >= argv.length() {
    raise MissingValue(flag~)
  }
  argv[i]
}

///|
fn parse_double_flag(flag : String, raw : String) -> Double raise ConfigError {
  @string.parse_double(raw) catch {
    _ => raise BadNumber(flag~, value=raw)
  }
}

///|
fn parse_int_flag(flag : String, raw : String) -> Int raise ConfigError {
  @string.parse_int(raw) catch {
    _ => raise BadNumber(flag~, value=raw)
  }
}
