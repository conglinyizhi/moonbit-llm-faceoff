///|
/// The shell exit code for a failed run.
let failure_exit_code : Int = 1

///|
/// Whether a chain of thought was streamed and left the line open.
///
/// Shared by the two callbacks below, so the progress line can start on a fresh
/// line instead of being glued to the end of the streamed reasoning.
struct CotLine {
  mut open : Bool
}

///|
/// C `exit`, so failures surface as a non-zero process status.
extern "c" fn c_exit(code : Int) -> Unit = "exit"

///|
/// Live progress, one JSON object per line.
///
/// The page needs something that moves *within* a request, not only between
/// requests: a suite of 66 cases takes minutes, and one stderr line per finished
/// case leaves the browser looking frozen for seconds at a time.
///
/// Everything here is best-effort. A run must not fail because nobody could
/// open the file it was supposed to narrate.
struct Progress {
  file : @fs.File?
  /// 当前这条的身份，写进每个 tick：一行就能自解释，页面不必记住上一条。
  mut model : String
  mut case_id : String
  mut repeat : Int
  mut max_tokens : Int
  /// Milliseconds between two `tick` lines. Cheap to lower, noisy to raise.
  throttle_ms : Int
  mut case_start_ms : UInt64
  mut last_tick_ms : UInt64
  /// Sliding window for the rate: fragments counted since `window_ms`.
  mut window_ms : UInt64
  mut window_frags : Int
  mut frags : Int
  mut chars : Int
  /// Whether any visible answer text has arrived yet. Until it has, the model is
  /// still in its chain of thought, and the page says so.
  mut answering : Bool
  mut last_rate : Double
}

///|
async fn progress_open(path : String?) -> Progress {
  let file = match path {
    None => None
    Some(path) => progress_open_file(path)
  }
  Progress::{
    file,
    model: "",
    case_id: "",
    repeat: 0,
    max_tokens: 0,
    throttle_ms: 120,
    case_start_ms: 0,
    last_tick_ms: 0,
    window_ms: 0,
    window_frags: 0,
    frags: 0,
    chars: 0,
    answering: false,
    last_rate: 0.0,
  }
}

///|
/// Open the progress file for appending, or nothing at all if it cannot be
/// opened. Failing to open a file must not take a run down with it.
async fn progress_open_file(path : String) -> @fs.File? {
  Some(@fs.open(path, mode=WriteOnly, create_mode=OpenOrCreate, append=true)) catch {
    _ => None
  }
}

///|
/// Write one event.
///
/// `File` writes are plain unbuffered writes, so a line is readable the moment
/// this returns — the server tails the file while the run is still going, and a
/// userspace buffer would hide exactly the seconds it is watching for.
async fn Progress::event(self : Progress, fields : Map[String, Json]) -> Unit {
  match self.file {
    None => ()
    Some(file) =>
      file.write(Json::object(fields).stringify() + "\n") catch {
        _ => ()
      }
  }
}

///|
/// A request started. Carries its position in the suite so the page can say
/// "12 / 66" before the first token arrives.
async fn Progress::case_started(
  self : Progress,
  model : String,
  case_id : String,
  repeat : Int,
  index : Int,
  total : Int,
  max_tokens : Int,
) -> Unit {
  let now = @env.now()
  self.model = model
  self.case_id = case_id
  self.repeat = repeat
  self.max_tokens = max_tokens
  self.case_start_ms = now
  self.last_tick_ms = now
  self.window_ms = now
  self.window_frags = 0
  self.frags = 0
  self.chars = 0
  self.answering = false
  self.last_rate = 0.0
  self.event({
    "event": Json::string("case_start"),
    "t": Json::number(now.to_double()),
    "model": Json::string(model),
    "case": Json::string(case_id),
    "repeat": Json::number(repeat.to_double()),
    "index": Json::number(index.to_double()),
    "total": Json::number(total.to_double()),
    "maxTokens": Json::number(max_tokens.to_double()),
  })
}

///|
/// A stream fragment arrived.
///
/// Throttled: a 500-token answer arrives in hundreds of fragments, and a line
/// per fragment would be a megabyte of file for something the page samples a
/// few times a second.
///
/// The rate is measured over a sliding window of fragments rather than over the
/// whole request, which is the point — a cumulative average barely moves once
/// the answer is under way, and this is the number meant to move.
async fn Progress::part(self : Progress, chars : Int, visible : Bool) -> Unit {
  let now = @env.now()
  if visible {
    self.answering = true
  }
  self.frags = self.frags + 1
  self.chars = self.chars + chars
  self.window_frags = self.window_frags + 1
  let span = (now - self.window_ms).to_double()
  if span >= 500.0 {
    // 窗口关掉，下一段重新起算：速率要跟着模型当下的速度走，不是整段的平均
    self.last_rate = self.window_frags.to_double() / (span / 1000.0)
    self.window_ms = now
    self.window_frags = 0
  } else if span >= 120.0 && self.window_frags >= 2 {
    // 还没到 500ms，但够算一个数了。不重置窗口：重置会让下一行也只看得见一小段
    self.last_rate = self.window_frags.to_double() / (span / 1000.0)
  }
  if now < self.last_tick_ms ||
    now - self.last_tick_ms < self.throttle_ms.to_uint64() {
    return
  }
  self.last_tick_ms = now
  self.event({
    "event": Json::string("tick"),
    "t": Json::number(now.to_double()),
    "model": Json::string(self.model),
    "case": Json::string(self.case_id),
    "repeat": Json::number(self.repeat.to_double()),
    "maxTokens": Json::number(self.max_tokens.to_double()),
    "elapsedMs": Json::number((now - self.case_start_ms).to_double()),
    "phase": Json::string(if self.answering { "content" } else { "reasoning" }),
    "tokPerS": Json::number(self.last_rate),
    "frags": Json::number(self.frags.to_double()),
    "chars": Json::number(self.chars.to_double()),
  })
}

///|
/// A request settled: the page can move its counter and show the final rate
/// before the next one starts.
async fn Progress::case_done(
  self : Progress,
  result : @harness.RunResult,
) -> Unit {
  // decode 速度：首正文之后的 token 除以首正文之后的时间。整段 e2e 速率把等
  // 首 token 的时间也算进去，在「模型刚醒来」和「模型在吐字」这两种状态需要
  // 分开看的时候就不够用了。
  let rate = match result.ttfc_ms {
    Some(ttfc) =>
      if result.ok && result.total_ms > ttfc && result.completion_tokens > 0 {
        result.completion_tokens.to_double() /
        ((result.total_ms - ttfc) / 1000.0)
      } else {
        0.0
      }
    None => 0.0
  }
  self.event({
    "event": Json::string("case_done"),
    "t": Json::number(@env.now().to_double()),
    "model": Json::string(result.model),
    "case": Json::string(result.case_id),
    "repeat": Json::number(result.repeat.to_double()),
    "ok": Json::boolean(result.ok),
    // 失败/重试/截断也随事件走：runs.jsonl 是整次跑完才写的，页面在运行期间
    // 只看得到这个文件，不从这儿数就永远是 0
    "attempts": Json::number(result.attempts.to_double()),
    "truncated": Json::boolean(result.finish_reason == Some("length")),
    // 每条事件都自带身份与上限：页面不必记住上一条，也不会在 case 边界上
    // 把进度条抖没了
    "maxTokens": Json::number(self.max_tokens.to_double()),
    "chars": Json::number(self.chars.to_double()),
    "frags": Json::number(self.frags.to_double()),
    "totalMs": Json::number(result.total_ms),
    "completionTokens": Json::number(result.completion_tokens.to_double()),
    "tokPerS": Json::number(rate),
  })
}

///|
/// Entry point.
///
/// Either runs the suite, or — with `--from-json` — reloads a previous run log
/// and only regenerates the report and page data. The replay path exists so a
/// page can be rebuilt without paying for the model calls again.
async fn main {
  let env = @env.get_env_vars()
  let all_args : Array[String] = @env.args()
  let argv : Array[String] = []
  for i = 1; i < all_args.length(); i = i + 1 {
    argv.push(all_args[i])
  }
  let cli = @harness.BenchCli::parse(env, argv) catch {
    err => {
      note("error: " + err.to_string())
      note("try `bench --help`")
      c_exit(failure_exit_code)
      return
    }
  }
  if cli.show_help {
    println(@harness.usage)
    return
  }
  let mut models = cli.models
  let mut results : Array[@harness.RunResult] = []
  let mut source = ""
  /// 这次跑用的用例（重放时没有，页面数据里那几格就是空的）
  let mut cli_cases : Array[@harness.Case] = []
  match cli.from_json {
    Some(path) => {
      let text = match read_text(path) {
        Ok(text) => text
        Err(message) => {
          note("error: " + message)
          c_exit(failure_exit_code)
          return
        }
      }
      results = @harness.parse_results(text)
      source = path
      if models.is_empty() {
        models = unique_models(results)
      }
      note(
        "replaying \{results.length()} run(s) from \{path}, \{models.length()} model(s)",
      )
    }
    None => {
      let cases = match load_cases(cli) {
        Ok(cases) => cases
        Err(message) => {
          note("error: " + message)
          c_exit(failure_exit_code)
          return
        }
      }
      cli_cases = cases
      let options : @harness.BenchOptions = {
        repeats: cli.repeats,
        max_tokens: cli.max_tokens,
        temperature: cli.temperature,
        system: cli.system,
        retry: cli.retry,
        retry_backoff_ms: cli.retry_backoff_ms,
        pace_ms: cli.pace_ms,
      }
      let cot : CotLine = { open: false, }
      let progress = progress_open(cli.progress_path)
      let planned = models.length() * cases.length() * cli.repeats
      progress.event({
        "event": Json::string("start"),
        "t": Json::number(@env.now().to_double()),
        "models": Json::array(models.map(fn(model) { Json::string(model) })),
        "cases": Json::number(cases.length().to_double()),
        "repeats": Json::number(cli.repeats.to_double()),
        "total": Json::number(planned.to_double()),
      })
      let mut index = 0
      note(
        "\{models.length()} model(s) x \{cases.length()} case(s) x \{cli.repeats} repeat(s)",
      )
      results = @harness.run_bench(
        cli.settings,
        models,
        cases,
        options,
        async fn(model, case_id, repeat) {
          index = index + 1
          progress.case_started(
            model,
            case_id,
            repeat,
            index,
            planned,
            cli.max_tokens,
          )
          note("")
          note("> \{model}  \{case_id} #\{repeat + 1}")
        },
        async fn(part) {
          match part {
            @faceoff.Reasoning(text) => progress.part(text.length(), false)
            @faceoff.Content(text) => progress.part(text.length(), true)
          }
          if cli.show_cot {
            match part {
              @faceoff.Reasoning(text) =>
                @stdio.stderr.write(text) catch {
                  _ => ()
                }
              @faceoff.Content(_) => ()
            }
            cot.open = true
          }
        },
        async fn(result) {
          progress.case_done(result)
          // 思考碎片是连续写出去的，没带换行。不先结掉这一行，进度行就会粘在
          // 思考的尾巴上（"weighing the question[mock-a] ..."）。
          if cot.open {
            note("")
            cot.open = false
          }
          note(@harness.format_run_line(result))
          if cli.show_output && result.ok {
            note("  --- answer ---")
            note(result.content)
            note("  --- end ---")
          }
        },
      )
      source = match (cli.cases_path, cli.prompt) {
        (Some(path), _) => path
        (None, Some(_)) => "inline prompt"
        (None, None) => ""
      }
    }
  }
  match cli.json_path {
    Some(path) => {
      let out = StringBuilder()
      for result in results {
        out.write_string(result.to_json().stringify())
        out.write_string("\n")
      }
      write_text(path, out.to_string())
    }
    None => ()
  }
  match cli.web_data {
    Some(path) => {
      let document = @harness.page_data_json(
        source,
        models,
        results,
        cases=cli_cases,
        system=cli.system,
      )
      write_text(path, document.stringify(indent=2) + "\n")
    }
    None => ()
  }
  println(@harness.format_summaries(@harness.summarize_all(models, results)))
  let mut failures = 0
  for result in results {
    if !result.ok {
      failures = failures + 1
    }
  }
  if results.length() > 0 && failures == results.length() {
    c_exit(failure_exit_code)
  }
}

///|
/// Models in first-seen order, for replaying a log whose model list was not
/// given on the command line.
fn unique_models(results : Array[@harness.RunResult]) -> Array[String] {
  let seen : Array[String] = []
  for result in results {
    if !seen.contains(result.model) {
      seen.push(result.model)
    }
  }
  seen
}

///|
/// Read the suite from `--prompt` or `--cases`, as a message string on
/// failure so the caller can report it without importing the error types.
async fn load_cases(
  cli : @harness.BenchCli,
) -> Result[Array[@harness.Case], String] {
  match cli.prompt {
    Some(text) => Ok([@harness.Case::new("inline", text)])
    None =>
      match cli.cases_path {
        None => Err("no test cases given")
        Some(path) => {
          let text = match read_text(path) {
            Ok(text) => text
            Err(message) => return Err(message)
          }
          let cases = @harness.parse_cases(text) catch {
            err => return Err("\{path}: " + err.to_string())
          }
          Ok(cases)
        }
      }
  }
}

///|
async fn read_text(path : String) -> Result[String, String] {
  let data = @fs.read_file(path) catch {
    err => return Err("cannot read \{path}: " + err.to_string())
  }
  let text = data.text() catch {
    err => return Err("cannot decode \{path}: " + err.to_string())
  }
  Ok(text)
}

///|
async fn write_text(path : String, content : String) -> Unit {
  @fs.write_file(path, content, create_mode=@fs.CreateOrTruncate) catch {
    err => note("warning: could not write \{path}: " + err.to_string())
  }
}

///|
/// Write a progress or diagnostic line to stderr, keeping stdout for the report.
async fn note(message : String) -> Unit {
  @stdio.stderr.write(message + "\n") catch {
    _ => ()
  }
}
