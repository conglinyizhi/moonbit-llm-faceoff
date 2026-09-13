///|
/// Errors raised while parsing benchmark arguments.
pub(all) suberror BenchConfigError {
  /// A client-level setting was bad; carries the original error.
  Client(@faceoff.ConfigError)
  /// No models were named.
  NoModels
  /// Neither `--cases` nor `--prompt` was given.
  NoSuite
  /// Both `--cases` and `--prompt` were given.
  ConflictingSuite
  /// A numeric flag could not be parsed.
  BadNumber(flag~ : String, value~ : String)
  /// A flag that needs a value was the last token.
  MissingValue(flag~ : String)
  /// An unrecognized flag.
  UnknownFlag(flag~ : String)
  /// --parallel 的取值不在 serial / models / all 里。
  BadParallel(value~ : String)
}

///|
pub fn BenchConfigError::to_string(self : BenchConfigError) -> String {
  match self {
    Client(err) => err.to_string()
    NoModels => "no models given: pass --models a,b or --model a"
    NoSuite => "no test cases: pass --cases <file> or --prompt \"...\""
    ConflictingSuite => "pass either --cases or --prompt, not both"
    BadNumber(flag~, value~) => "invalid number for \{flag}: \{value}"
    MissingValue(flag~) => "missing value for \{flag}"
    UnknownFlag(flag~) => "unknown flag: \{flag}"
    BadParallel(value~) => "invalid value for --parallel: \{value} (serial / models / all)"
  }
}

///|
pub let usage : String =
  #|bench — compare chat models on the same prompt suite
  #|
  #|usage:
  #|  bench --models a,b --cases tests.jsonl [options]
  #|  bench --model a --prompt "one question" [options]
  #|
  #|suite:
  #|      --models <a,b>    comma-separated model ids, repeatable
  #|      --model <id>      one model id, repeatable
  #|      --cases <file>    JSON array or JSON Lines of {"prompt", "id"?, "system"?,
  #|                        "max_tokens"?, "temperature"?}
  #|      --prompt <text>   run a single ad-hoc case instead of a file
  #|
  #|run:
  #|      --repeats <n>     attempts per case per model (default 3)
  #|      --max-tokens <n>  token budget per reply (default 1024)
  #|      --temperature <t> sampling temperature
  #|      --system <text>   system prompt
  #|      --system-override  the run-level system wins over per-case system
  #|      --cot-thinking <models>  comma-separated models to send enable_thinking: true
  #|      --cot-effort <models>    comma-separated models to send reasoning_effort: high
  #|      --parallel <mode>        serial (default) | models | all
  #|
  #|rate limits:
  #|      --retry <n>       extra attempts after 429/5xx (default 1)
  #|      --retry-backoff-ms <n>
  #|                        first backoff delay, doubling per retry (default 2000)
  #|      --pace-ms <n>     idle time between attempts (default 0)
  #|
  #|replay:
  #|      --from-json <f>   skip running and reload a previous run log (JSON Lines)
  #|
  #|output:
  #|      --show-cot        stream chain-of-thought text to stderr as it arrives
  #|      --show-output     print each answer to stderr when the run settles
  #|      --json <file>     write every raw attempt as JSON Lines
  #|      --web-data <f>    write the page data document (JSON) for the web module
  #|      --progress <f>    append live progress events (JSON Lines) while running
  #|
  #|endpoint (also read from the environment, see faceoff):
  #|      --base-url <url>  --api-key <key>  --timeout-ms <n>  --no-key
  #|  -h, --help            show this help

///|
/// A parsed benchmark command line.
pub(all) struct BenchCli {
  settings : @faceoff.Settings
  models : Array[String]
  cases_path : String?
  prompt : String?
  repeats : Int
  max_tokens : Int
  temperature : Double?
  system : String
  /// 运行级 system 是否覆盖用例自带的 system。默认否（用例级优先）。
  system_override : Bool
  /// 这些模型带 enable_thinking: true。
  cot_thinking : Array[String]
  /// 这些模型带 reasoning_effort: "high"。
  cot_effort : Array[String]
  /// 串行 / 按模型并行 / 全部并发。
  parallel : String
  show_cot : Bool
  show_output : Bool
  json_path : String?
  show_help : Bool
  from_json : String?
  web_data : String?
  /// Where live progress events go. Absent means nobody is watching.
  progress_path : String?
  retry : Int
  retry_backoff_ms : Int
  pace_ms : Int
}

///|
/// Parse benchmark arguments, resolving endpoint settings from `env` first.
pub fn BenchCli::parse(
  env : Map[String, String],
  argv : Array[String],
) -> BenchCli raise BenchConfigError {
  let settings = @faceoff.Settings::from_env(env)
  let models : Array[String] = []
  let mut cases_path : String? = None
  let mut prompt : String? = None
  let mut repeats = 3
  let mut max_tokens = 1024
  let mut temperature : Double? = None
  let mut system = ""
  let mut system_override = false
  let cot_thinking : Array[String] = []
  let cot_effort : Array[String] = []
  let mut parallel = "serial"
  let mut show_cot = false
  let mut show_output = false
  let mut json_path : String? = None
  let mut show_help = false
  let mut no_key = false
  let mut from_json : String? = None
  let mut web_data : String? = None
  let mut progress_path : String? = None
  let mut retry = 1
  let mut retry_backoff_ms = 2000
  let mut pace_ms = 0
  let mut i = 0
  while i < argv.length() {
    let arg = argv[i]
    i = i + 1
    match arg {
      "-h" | "--help" => show_help = true
      "--show-cot" => show_cot = true
      "--system-override" => system_override = true
      "--cot-thinking" => {
        push_models(cot_thinking, next_value(argv, i, "--cot-thinking"))
        i = i + 1
      }
      "--cot-effort" => {
        push_models(cot_effort, next_value(argv, i, "--cot-effort"))
        i = i + 1
      }
      "--parallel" => {
        let raw = next_value(argv, i, "--parallel")
        parallel = match parse_parallel(raw) {
          Ok(mode) => mode
          Err(_) => raise BenchConfigError::BadParallel(value=raw)
        }
        i = i + 1
      }
      "--show-output" => show_output = true
      "--no-key" => no_key = true
      "--models" => {
        push_models(models, next_value(argv, i, "--models"))
        i = i + 1
      }
      "--model" => {
        models.push(next_value(argv, i, "--model"))
        i = i + 1
      }
      "--cases" => {
        cases_path = Some(next_value(argv, i, "--cases"))
        i = i + 1
      }
      "--prompt" => {
        prompt = Some(next_value(argv, i, "--prompt"))
        i = i + 1
      }
      "--repeats" => {
        repeats = parse_int_flag("--repeats", next_value(argv, i, "--repeats"))
        i = i + 1
      }
      "--max-tokens" => {
        max_tokens = parse_int_flag(
          "--max-tokens",
          next_value(argv, i, "--max-tokens"),
        )
        i = i + 1
      }
      "--temperature" => {
        temperature = Some(
          parse_double_flag(
            "--temperature",
            next_value(argv, i, "--temperature"),
          ),
        )
        i = i + 1
      }
      "--system" => {
        system = next_value(argv, i, "--system")
        i = i + 1
      }
      "--json" => {
        json_path = Some(next_value(argv, i, "--json"))
        i = i + 1
      }
      "--from-json" => {
        from_json = Some(next_value(argv, i, "--from-json"))
        i = i + 1
      }
      "--web-data" => {
        web_data = Some(next_value(argv, i, "--web-data"))
        i = i + 1
      }
      "--progress" => {
        progress_path = Some(next_value(argv, i, "--progress"))
        i = i + 1
      }
      "--retry" => {
        retry = parse_int_flag("--retry", next_value(argv, i, "--retry"))
        i = i + 1
      }
      "--retry-backoff-ms" => {
        retry_backoff_ms = parse_int_flag(
          "--retry-backoff-ms",
          next_value(argv, i, "--retry-backoff-ms"),
        )
        i = i + 1
      }
      "--pace-ms" => {
        pace_ms = parse_int_flag("--pace-ms", next_value(argv, i, "--pace-ms"))
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
      "--timeout-ms" => {
        settings.timeout_ms = parse_int_flag(
          "--timeout-ms",
          next_value(argv, i, "--timeout-ms"),
        )
        i = i + 1
      }
      _ => raise UnknownFlag(flag=arg)
    }
  }
  if !show_help {
    if from_json is None {
      if models.is_empty() {
        raise NoModels
      }
      if cases_path is Some(_) && prompt is Some(_) {
        raise ConflictingSuite
      }
      if cases_path is None && prompt is None {
        raise NoSuite
      }
    }
    if repeats < 1 {
      raise BadNumber(flag="--repeats", value=repeats.to_string())
    }
    if max_tokens < 1 {
      raise BadNumber(flag="--max-tokens", value=max_tokens.to_string())
    }
    if retry < 0 {
      raise BadNumber(flag="--retry", value=retry.to_string())
    }
    if settings.api_key == "" && !no_key {
      raise Client(@faceoff.ConfigError::MissingApiKey)
    }
  }
  if settings.base_url == "" {
    settings.base_url = @faceoff.default_base_url
  }
  {
    settings,
    models,
    cases_path,
    prompt,
    repeats,
    max_tokens,
    temperature,
    system,
    system_override,
    cot_thinking,
    cot_effort,
    parallel,
    show_cot,
    show_output,
    json_path,
    show_help,
    from_json,
    web_data,
    progress_path,
    retry,
    retry_backoff_ms,
    pace_ms,
  }
}

///|
fn push_models(models : Array[String], raw : String) -> Unit {
  for part in raw.split(",") {
    let model = part.trim(chars=" \t").to_owned()
    if model.length() > 0 && !models.contains(model) {
      models.push(model)
    }
  }
}

///|
fn next_value(
  argv : Array[String],
  i : Int,
  flag : String,
) -> String raise BenchConfigError {
  if i >= argv.length() {
    raise MissingValue(flag~)
  }
  argv[i]
}

///|
fn parse_int_flag(flag : String, raw : String) -> Int raise BenchConfigError {
  @string.parse_int(raw) catch {
    _ => raise BadNumber(flag~, value=raw)
  }
}

///|
fn parse_double_flag(
  flag : String,
  raw : String,
) -> Double raise BenchConfigError {
  @string.parse_double(raw) catch {
    _ => raise BadNumber(flag~, value=raw)
  }
}
