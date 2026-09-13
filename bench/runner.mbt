///|
/// Options shared by every run in a benchmark.
pub(all) struct BenchOptions {
  /// How many times each case is run against each model.
  repeats : Int
  /// Token budget per reply; applies when a case does not override it.
  max_tokens : Int
  /// Sampling temperature; applies when a case does not override it.
  temperature : Double?
  /// System prompt; applies when a case does not override it.
  system : String
  /// 勾上就用运行级 system 覆盖用例自带的 system（默认：用例级优先）。
  system_override : Bool
  /// 这些模型往请求里带 enable_thinking: true。
  cot_thinking : Array[String]
  /// 这些模型往请求里带 reasoning_effort: "high"。
  cot_effort : Array[String]
  /// 串行 / 按模型并行 / 全部并发（见 parse_parallel）。
  parallel : String
  /// Extra attempts after a rate limit or server error. `0` fails fast.
  retry : Int
  /// First backoff delay; doubles on each further attempt.
  retry_backoff_ms : Int
  /// Idle time between attempts, to stay under a per-minute request cap.
  pace_ms : Int
}

///|
/// One attempt: one case, against one model, on one repeat.
pub(all) struct RunResult {
  model : String
  case_id : String
  /// 0-based repeat index.
  repeat : Int
  /// How many HTTP attempts this run needed. Above 1 means the gateway pushed
  /// back and the reported latency is the successful attempt only.
  attempts : Int
  ok : Bool
  error : String?
  /// Milliseconds until the first fragment of any kind.
  ttft_ms : Double?
  /// Milliseconds until the first fragment of the visible answer, i.e. after
  /// the chain of thought.
  ttfc_ms : Double?
  /// Milliseconds for the whole request.
  total_ms : Double
  prompt_tokens : Int
  completion_tokens : Int
  reasoning_tokens : Int
  content_chars : Int
  reasoning_chars : Int
  finish_reason : String?
  /// The visible answer.
  content : String
  /// The chain of thought, when the model produced one.
  reasoning : String
}

///|
/// Tokens per second across the whole request, including the wait for the
/// first token.
pub fn RunResult::e2e_tok_per_s(self : RunResult) -> Double? {
  if !self.ok || self.total_ms <= 0.0 {
    return None
  }
  Some(self.completion_tokens.to_double() / (self.total_ms / 1000.0))
}

///|
/// Tokens per second after the first token arrived — the closest thing to
/// decode speed a client can observe.
pub fn RunResult::decode_tok_per_s(self : RunResult) -> Double? {
  if !self.ok {
    return None
  }
  match self.ttft_ms {
    Some(ttft) => {
      let window = self.total_ms - ttft
      if window <= 0.0 {
        None
      } else {
        Some(self.completion_tokens.to_double() / (window / 1000.0))
      }
    }
    None => None
  }
}

///|
/// The share of the completion budget spent thinking.
pub fn RunResult::reasoning_ratio(self : RunResult) -> Double? {
  if !self.ok || self.completion_tokens == 0 {
    return None
  }
  Some(self.reasoning_tokens.to_double() / self.completion_tokens.to_double())
}

///|
/// A raw result as JSON, for archiving and later analysis.
pub fn RunResult::to_json(self : RunResult) -> Json {
  Json::object({
    "model": Json::string(self.model),
    "case_id": Json::string(self.case_id),
    "repeat": Json::number(self.repeat.to_double()),
    "attempts": Json::number(self.attempts.to_double()),
    "ok": Json::boolean(self.ok),
    "error": optional_string(self.error),
    "ttft_ms": optional_number(self.ttft_ms),
    "ttfc_ms": optional_number(self.ttfc_ms),
    "total_ms": Json::number(self.total_ms),
    "prompt_tokens": Json::number(self.prompt_tokens.to_double()),
    "completion_tokens": Json::number(self.completion_tokens.to_double()),
    "reasoning_tokens": Json::number(self.reasoning_tokens.to_double()),
    "content_chars": Json::number(self.content_chars.to_double()),
    "reasoning_chars": Json::number(self.reasoning_chars.to_double()),
    "finish_reason": optional_string(self.finish_reason),
    "content": Json::string(self.content),
    "reasoning": Json::string(self.reasoning),
  })
}

///|
fn optional_string(value : String?) -> Json {
  match value {
    Some(text) => Json::string(text)
    None => Json::null()
  }
}

///|
fn optional_number(value : Double?) -> Json {
  match value {
    Some(number) => Json::number(number)
    None => Json::null()
  }
}

///|
/// Rebuild a `RunResult` from the JSON written by `to_json`.
///
/// Missing or null fields fall back to a zero value, so a truncated record
/// degrades to "no data" instead of failing the whole page.
pub fn RunResult::from_json(json : Json) -> RunResult {
  let obj = match json {
    Object(obj) => obj
    _ => Map([])
  }
  {
    model: string_field_or(obj, "model", ""),
    case_id: string_field_or(obj, "case_id", ""),
    repeat: int_field_or(obj, "repeat", 0),
    attempts: int_field_or(obj, "attempts", 1),
    ok: match obj.get("ok") {
      Some(True) => true
      _ => false
    },
    error: string_field(obj, "error"),
    ttft_ms: number_field(obj, "ttft_ms"),
    ttfc_ms: number_field(obj, "ttfc_ms"),
    total_ms: number_field_or(obj, "total_ms", 0.0),
    prompt_tokens: int_field_or(obj, "prompt_tokens", 0),
    completion_tokens: int_field_or(obj, "completion_tokens", 0),
    reasoning_tokens: int_field_or(obj, "reasoning_tokens", 0),
    content_chars: int_field_or(obj, "content_chars", 0),
    reasoning_chars: int_field_or(obj, "reasoning_chars", 0),
    finish_reason: string_field(obj, "finish_reason"),
    content: string_field_or(obj, "content", ""),
    reasoning: string_field_or(obj, "reasoning", ""),
  }
}

///|
/// Parse a JSON Lines run log, as written by `bench --json`.
///
/// Blank lines are skipped, and a malformed line is dropped rather than
/// aborting: a half-written log should still render.
pub fn parse_results(text : String) -> Array[RunResult] {
  let results : Array[RunResult] = []
  for line in text.split("\n") {
    let content = line.trim(chars=" \t\r")
    if content.length() == 0 {
      continue
    }
    let parsed = @json.parse(content.to_owned()) catch { _ => continue }
    results.push(RunResult::from_json(parsed))
  }
  results
}

///|
fn string_field_or(
  obj : Map[String, Json],
  key : String,
  fallback : String,
) -> String {
  match string_field(obj, key) {
    Some(value) => value
    None => fallback
  }
}

///|
fn number_field_or(
  obj : Map[String, Json],
  key : String,
  fallback : Double,
) -> Double {
  match number_field(obj, key) {
    Some(value) => value
    None => fallback
  }
}

///|
fn int_field_or(obj : Map[String, Json], key : String, fallback : Int) -> Int {
  match number_field(obj, key) {
    Some(value) => value.to_int()
    None => fallback
  }
}

///|
/// Milliseconds since `start`.
fn elapsed_ms(start : UInt64) -> Double {
  (@env.now() - start).to_double()
}

///|
/// Timestamps and counters filled in by the stream callback.
priv struct Ticker {
  mut ttft_ms : Double?
  mut ttfc_ms : Double?
  mut content_chars : Int
  mut reasoning_chars : Int
}

///|
/// Whether a failed attempt is worth repeating. A rate limit or a server error
/// is; a bad request or an undecodable body is not.
fn is_retryable(err : @faceoff.ClientError) -> Bool {
  match err {
    @faceoff.ClientError::Status(code~, ..) => code == 429 || code >= 500
    @faceoff.ClientError::Transport(_) => true
    @faceoff.ClientError::Decode(_) => false
  }
}

///|
/// Settings for one attempt, with the case overriding the benchmark defaults.
fn settings_for(
  base : @faceoff.Settings,
  model : String,
  case : Case,
  options : BenchOptions,
) -> @faceoff.Settings {
  {
    api_key: base.api_key,
    base_url: base.base_url,
    model,
    system: if options.system_override {
      options.system
    } else {
      match case.system {
        Some(system) => system
        None => options.system
      }
    },
    temperature: match case.temperature {
      Some(temperature) => Some(temperature)
      None => options.temperature
    },
    max_tokens: Some(
      match case.max_tokens {
        Some(max_tokens) => max_tokens
        None => options.max_tokens
      },
    ),
    timeout_ms: base.timeout_ms,
    enable_thinking: options.cot_thinking.contains(model),
    reasoning_effort: if options.cot_effort.contains(model) {
      Some("high")
    } else {
      None
    },
  }
}

///|
/// Run one case against one model and time it.
///
/// Never raises: a failed attempt comes back as a `RunResult` with
/// `ok = false`, so one bad case does not abort a whole benchmark. The timer
/// restarts on each retry, so a run that had to back off still reports the
/// latency of the attempt that actually produced tokens rather than the time
/// spent sleeping.
pub async fn run_case(
  base : @faceoff.Settings,
  model : String,
  case : Case,
  options : BenchOptions,
  repeat : Int,
  on_part : async (@faceoff.StreamPart) -> Unit,
) -> RunResult {
  let settings = settings_for(base, model, case, options)
  let mut attempts = 0
  let mut backoff = options.retry_backoff_ms
  while attempts <= options.retry {
    attempts = attempts + 1
    let ticker : Ticker = {
      ttft_ms: None,
      ttfc_ms: None,
      content_chars: 0,
      reasoning_chars: 0,
    }
    let start = @env.now()
    let outcome = @faceoff.stream_parts(settings, case.prompt, async fn(part) {
      let elapsed = elapsed_ms(start)
      match part {
        Reasoning(text) => {
          ticker.reasoning_chars = ticker.reasoning_chars + text.length()
          if ticker.ttft_ms is None {
            ticker.ttft_ms = Some(elapsed)
          }
        }
        Content(text) => {
          ticker.content_chars = ticker.content_chars + text.length()
          if ticker.ttft_ms is None {
            ticker.ttft_ms = Some(elapsed)
          }
          if ticker.ttfc_ms is None {
            ticker.ttfc_ms = Some(elapsed)
          }
        }
      }
      on_part(part) catch {
        _ => ()
      }
    }) catch {
      err => {
        if attempts > options.retry || !is_retryable(err) {
          return failure_result(
            model,
            case.id,
            repeat,
            attempts,
            err.to_string(),
            ticker.ttft_ms,
            ticker.ttfc_ms,
            elapsed_ms(start),
            ticker.content_chars,
            ticker.reasoning_chars,
          )
        }
        @async.sleep(backoff) catch {
          _ => ()
        }
        backoff = backoff * 2
        continue
      }
    }
    let usage = match outcome.usage {
      Some(usage) => usage
      None => @faceoff.TokenUsage::new(0, 0, 0)
    }
    return {
      model,
      case_id: case.id,
      repeat,
      attempts,
      ok: true,
      error: None,
      ttft_ms: ticker.ttft_ms,
      ttfc_ms: ticker.ttfc_ms,
      total_ms: elapsed_ms(start),
      prompt_tokens: usage.prompt_tokens,
      completion_tokens: usage.completion_tokens,
      reasoning_tokens: usage.reasoning_tokens,
      content_chars: ticker.content_chars,
      reasoning_chars: ticker.reasoning_chars,
      finish_reason: outcome.finish_reason,
      content: outcome.content,
      reasoning: outcome.reasoning,
    }
  }
  failure_result(
    model,
    case.id,
    repeat,
    attempts,
    "no attempt produced a result",
    None,
    None,
    0.0,
    0,
    0,
  )
}

///|
fn failure_result(
  model : String,
  case_id : String,
  repeat : Int,
  attempts : Int,
  message : String,
  ttft_ms : Double?,
  ttfc_ms : Double?,
  total_ms : Double,
  content_chars : Int,
  reasoning_chars : Int,
) -> RunResult {
  {
    model,
    case_id,
    repeat,
    attempts,
    ok: false,
    error: Some(message),
    ttft_ms,
    ttfc_ms,
    total_ms,
    prompt_tokens: 0,
    completion_tokens: 0,
    reasoning_tokens: 0,
    content_chars,
    reasoning_chars,
    finish_reason: None,
    content: "",
    reasoning: "",
  }
}

///|
/// 并行方式。
///
/// 串行是默认：比两个模型只有在它们不抢同一条连接时才说明问题。后两种是给
/// 「我就想快点看到全部结果」用的，代价是延迟数字不再干净（同一模型内仍然串行
/// 的 `models` 比 `all` 干净一点）。
pub fn parse_parallel(raw : String) -> Result[String, String] {
  match raw {
    "" | "serial" => Ok("serial")
    "models" => Ok("models")
    "all" => Ok("all")
    _ => Err("parallel must be one of: serial, models, all")
  }
}

///|
/// 一次尝试：`on_start` → 跑 → `on_result`。三种并行方式共用的那一截。
async fn run_one(
  base : @faceoff.Settings,
  model : String,
  case : Case,
  options : BenchOptions,
  repeat : Int,
  on_start : async (String, String, Int) -> Unit,
  on_part : async (@faceoff.StreamPart) -> Unit,
  on_result : async (RunResult) -> Unit,
) -> RunResult {
  on_start(model, case.id, repeat) catch {
    _ => ()
  }
  let result = run_case(base, model, case, options, repeat, on_part)
  on_result(result) catch {
    _ => ()
  }
  result
}

///|
/// 一个模型的全部尝试（模型内串行），并把自己的结果收集到 `out` 里。
///
/// `out` 由每个任务各占一格写：并发写同一个数组的代价是两边的 push 会撞上，
/// 所以调用方先按模型数铺好空数组，任务只写自己那一格。
async fn run_model_serial(
  base : @faceoff.Settings,
  model : String,
  cases : Array[Case],
  options : BenchOptions,
  on_start : async (String, String, Int) -> Unit,
  on_part : async (@faceoff.StreamPart) -> Unit,
  on_result : async (RunResult) -> Unit,
) -> Array[RunResult] {
  let results : Array[RunResult] = []
  let mut first = true
  for case in cases {
    for repeat = 0; repeat < options.repeats; repeat = repeat + 1 {
      if !first && options.pace_ms > 0 {
        @async.sleep(options.pace_ms) catch {
          _ => ()
        }
      }
      first = false
      results.push(
        run_one(
          base, model, case, options, repeat, on_start, on_part, on_result,
        ),
      )
    }
  }
  results
}

///|
/// 结果按（模型、用例、第几次）排好再交出去。
///
/// 并发跑完的顺序是随机的，而写进 JSONL 与 data.json 的顺序会被人（和 diff）
/// 看见：同一批参数跑两次应该得到同一份文件。排序只在收尾做一次。
fn sorted_results(
  models : Array[String],
  cases : Array[Case],
  results : Array[RunResult],
) -> Array[RunResult] {
  let case_order : Map[String, Int] = Map([])
  for i = 0; i < cases.length(); i = i + 1 {
    case_order[cases[i].id] = i
  }
  let model_order : Map[String, Int] = Map([])
  for i = 0; i < models.length(); i = i + 1 {
    model_order[models[i]] = i
  }
  let key = fn(result : RunResult) {
    (
      match model_order.get(result.model) {
        Some(index) => index
        None => models.length()
      },
      match case_order.get(result.case_id) {
        Some(index) => index
        None => cases.length()
      },
      result.repeat,
    )
  }
  let out = results.copy()
  out.sort_by(fn(a, b) {
    let x = key(a)
    let y = key(b)
    if x.0 != y.0 {
      if x.0 < y.0 { -1 } else { 1 }
    } else if x.1 != y.1 {
      if x.1 < y.1 { -1 } else { 1 }
    } else if x.2 != y.2 {
      if x.2 < y.2 { -1 } else { 1 }
    } else {
      0
    }
  })
  out
}

///|
/// Run the whole suite and collect every attempt.
///
/// `on_start` fires before each attempt, `on_part` receives stream fragments
/// while it runs, and `on_result` fires once it settles.
///
/// 串行是默认（也是唯一能让延迟数字干净的做法）；`options.parallel` 可以改成
/// 「按模型并行」或「全部并发」，那两种下面三个回调会被并发调用——调用方得
/// 自己把共享的进度文件与输出串起来（`cmd/bench` 就是这么做的）。
pub async fn run_bench(
  base : @faceoff.Settings,
  models : Array[String],
  cases : Array[Case],
  options : BenchOptions,
  on_start : async (String, String, Int) -> Unit,
  on_part : async (@faceoff.StreamPart) -> Unit,
  on_result : async (RunResult) -> Unit,
) -> Array[RunResult] {
  let collected = match options.parallel {
    "models" => {
      // 每个模型一个任务，各写自己那格
      let per_model : Array[Array[RunResult]] = []
      for _i = 0; _i < models.length(); _i = _i + 1 {
        per_model.push([])
      }
      @async.with_task_group(fn(group) {
        for i = 0; i < models.length(); i = i + 1 {
          let slot = per_model[i]
          let model = models[i]
          group.spawn(async fn() {
            let got = run_model_serial(
              base, model, cases, options, on_start, on_part, on_result,
            )
            for result in got {
              slot.push(result)
            }
          })
          |> ignore
        }
      })
      let flat : Array[RunResult] = []
      for slot in per_model {
        for result in slot {
          flat.push(result)
        }
      }
      flat
    }
    "all" => {
      // 每条请求一个任务，模型内也不串行
      let slots : Array[Array[RunResult]] = []
      let plan : Array[(String, Case, Int)] = []
      for model in models {
        for case in cases {
          for repeat = 0; repeat < options.repeats; repeat = repeat + 1 {
            slots.push([])
            plan.push((model, case, repeat))
          }
        }
      }
      @async.with_task_group(fn(group) {
        for i = 0; i < plan.length(); i = i + 1 {
          let slot = slots[i]
          let (model, case, repeat) = plan[i]
          group.spawn(async fn() {
            slot.push(
              run_one(
                base, model, case, options, repeat, on_start, on_part, on_result,
              ),
            )
          })
          |> ignore
        }
      })
      let flat : Array[RunResult] = []
      for slot in slots {
        for result in slot {
          flat.push(result)
        }
      }
      flat
    }
    _ => {
      let results : Array[RunResult] = []
      for model in models {
        let got = run_model_serial(
          base, model, cases, options, on_start, on_part, on_result,
        )
        for result in got {
          results.push(result)
        }
      }
      results
    }
  }
  sorted_results(models, cases, collected)
}
