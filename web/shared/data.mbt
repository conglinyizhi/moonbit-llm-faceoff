///|
/// 一个指标的统计量。
pub(all) struct MetricStats {
  n : Int
  median : Double
  min : Double
  max : Double
  /// 分位数。老的结果文件里没有这几个字段——那时只存了中位数，所以解析时回退
  /// 到中位数，页面仍然照常显示（历史运行不该因为工具升级就打不开）。
  p10 : Double
  p20 : Double
  p50 : Double
  p99 : Double
} derive(Eq)

///|
/// 单个模型的汇总。
pub(all) struct ModelSummary {
  model : String
  runs : Int
  failures : Int
  truncated : Int
  retried : Int
  metrics : Map[String, MetricStats]
} derive(Eq)

///|
/// 一次用例输出。
///
/// `reasoning` 是思考全文（可能很长，页面上默认收起）；`reasoning_tokens` 只是
/// 它的长度，回答不了「两个模型想的有什么不一样」。
pub(all) struct Answer {
  model : String
  ok : Bool
  total_ms : Double
  completion_tokens : Int
  reasoning_tokens : Int
  content : String
  reasoning : String
  error : String?
  /// 人工判定：`pass` / `fail` / `unsure`。没有标注就是 None。
  /// 它来自运行目录里的 annotations.jsonl，由服务端合并进这份文档。
  verdict : String?
  /// 人工备注。
  note : String?
} derive(Eq)

///|
/// 一道用例及其各模型输出。
pub(all) struct CaseBlock {
  id : String
  /// 这道题问的是什么（user prompt）。老的结果文件里没有这个字段，读出来是空串
  prompt : String
  /// 这条用例实际生效的 system prompt（用例自带的优先于运行级的）
  system : String
  answers : Array[Answer]
} derive(Eq)

///|
/// 一条人工标注：这次运行 × 这道题 × 这个模型 → 判定 + 备注。
///
/// `verdict` 三档：`pass` / `fail` / `unsure`。存的是稳定的英文标识，显示层
/// （emoji、颜色）由 `verdict_label` 决定——以后换符号不该意味着改数据。
pub(all) struct Annotation {
  case_id : String
  model : String
  verdict : String
  note : String
} derive(Eq, FromJson)

///|
pub extend Annotation with Eq::{equal, not_equal}

///|
pub extend Annotation with FromJson::{from_json}

///|
pub(all) struct AnnotationResponse {
  id : String
  annotations : Array[Annotation]
} derive(FromJson)

///|
pub extend AnnotationResponse with FromJson::{from_json}

///|
/// 判定在界面上的说法。
pub fn verdict_label(verdict : String) -> String {
  match verdict {
    "pass" => "✅ 通过"
    "fail" => "❌ 不行"
    "unsure" => "🤔 拿不准"
    _ => verdict
  }
}

///|
/// 把标注贴回页面数据：命中 (case_id, model) 的答案带上 verdict / note。
///
/// 渲染与 Markdown 导出都读这一份，所以只要贴一次；贴完就是一个普通的 PageData，
/// 不需要在渲染层到处传标注表。
pub fn with_annotations(
  data : PageData,
  annotations : Array[Annotation],
) -> PageData {
  if annotations.length() == 0 {
    return data
  }
  let cases : Array[CaseBlock] = []
  for block in data.cases {
    let answers : Array[Answer] = []
    for answer in block.answers {
      let hit = annotations.filter(fn(entry) {
        entry.case_id == block.id && entry.model == answer.model
      })
      match hit {
        [] => answers.push(answer)
        [entry, ..] =>
          answers.push({
            ..answer,
            verdict: Some(entry.verdict),
            note: Some(entry.note),
          })
      }
    }
    cases.push({
      id: block.id,
      prompt: block.prompt,
      system: block.system,
      answers,
    })
  }
  { ..data, cases, }
}

///|
/// 一次评测的完整结果数据。
pub(all) struct PageData {
  source : String
  models : Array[String]
  summaries : Array[ModelSummary]
  cases : Array[CaseBlock]
} derive(Eq)

///|
pub fn empty_page_data() -> PageData {
  { source: "", models: [], summaries: [], cases: [], }
}

///|
pub fn parse_page_data(text : String) -> Result[PageData, String] {
  let json = @json.parse(text) catch {
    err => return Err("bad page data: " + err.to_string())
  }
  parse_page_data_json(json)
}

///|
pub fn parse_page_data_json(json : Json) -> Result[PageData, String] {
  let root = match json {
    Object(root) => root
    _ => return Err("page data must be a JSON object")
  }
  Ok({
    source: string_field(root, "source", ""),
    models: array_field(root, "models").map(fn(item) {
      match item {
        String(text) => text
        _ => ""
      }
    }),
    summaries: array_field(root, "summaries").map(parse_summary),
    cases: array_field(root, "cases").map(parse_case),
  })
}

///|
fn parse_summary(json : Json) -> ModelSummary {
  let obj = as_object(json)
  {
    model: string_field(obj, "model", ""),
    runs: int_field(obj, "runs", 0),
    failures: int_field(obj, "failures", 0),
    truncated: int_field(obj, "truncated", 0),
    retried: int_field(obj, "retried", 0),
    metrics: match obj.get("metrics") {
      Some(Object(metrics)) =>
        metrics.map(fn(_key, value) { parse_metric(value) })
      _ => Map([])
    },
  }
}

///|
fn parse_metric(json : Json) -> MetricStats {
  let obj = as_object(json)
  let median = number_field(obj, "median", 0.0)
  {
    n: int_field(obj, "n", 0),
    median,
    min: number_field(obj, "min", 0.0),
    max: number_field(obj, "max", 0.0),
    p10: number_field(obj, "p10", median),
    p20: number_field(obj, "p20", median),
    p50: number_field(obj, "p50", median),
    p99: number_field(obj, "p99", median),
  }
}

///|
fn parse_case(json : Json) -> CaseBlock {
  let obj = as_object(json)
  {
    id: string_field(obj, "id", ""),
    prompt: string_field(obj, "prompt", ""),
    system: string_field(obj, "system", ""),
    answers: array_field(obj, "answers").map(parse_answer),
  }
}

///|
fn parse_answer(json : Json) -> Answer {
  let obj = as_object(json)
  {
    model: string_field(obj, "model", ""),
    ok: match obj.get("ok") {
      Some(True) => true
      _ => false
    },
    total_ms: number_field(obj, "total_ms", 0.0),
    completion_tokens: int_field(obj, "completion_tokens", 0),
    reasoning_tokens: int_field(obj, "reasoning_tokens", 0),
    content: string_field(obj, "content", ""),
    reasoning: string_field(obj, "reasoning", ""),
    verdict: optional_field(obj, "verdict"),
    note: optional_field(obj, "note"),
    error: match obj.get("error") {
      Some(String(text)) => Some(text)
      _ => None
    },
  }
}

///|
/// What a run actually sent: the request document plus one entry per case with the
/// values that were in effect for it.
///
/// The point is answering "why did it answer that" without leaving the page: a
/// system prompt overridden per case, a temperature you forgot you set, a
/// `max_tokens` that cut the answer off — all of it is in the run directory, and
/// none of it was visible.
pub(all) struct RunContext {
  id : String
  /// The sanitized request document (`apiKey` is never in it).
  request : Json
  models : Array[String]
  cases : Array[ContextCase]
} derive(Eq)

///|
pub extend RunContext with Eq::{equal, not_equal}

///|
pub(all) struct ContextCase {
  id : String
  prompt : String
  /// The system prompt that was actually in effect for this case.
  system : String
  /// True when the case set carried its own system prompt (and the global one
  /// never applied). The page says so, because that is usually the surprise.
  system_overridden : Bool
  max_tokens : Int
  temperature : Double?
} derive(Eq)

///|
pub extend ContextCase with Eq::{equal, not_equal}

///|
pub fn parse_run_context(json : Json) -> Result[RunContext, String] {
  match json {
    Object(fields) => {
      let models = array_field(fields, "models").filter_map(fn(item) {
        match item {
          String(text) => Some(text)
          _ => None
        }
      })
      let cases = array_field(fields, "cases").map(fn(item) {
        let entry = as_object(item)
        {
          id: string_field(entry, "id", ""),
          prompt: string_field(entry, "prompt", ""),
          system: string_field(entry, "system", ""),
          system_overridden: match entry.get("systemOverridden") {
            Some(True) => true
            _ => false
          },
          max_tokens: int_field(entry, "maxTokens", 0),
          temperature: match entry.get("temperature") {
            Some(Number(value, ..)) => Some(value)
            _ => None
          },
        }
      })
      Ok({
        id: string_field(fields, "id", ""),
        request: match fields.get("request") {
          Some(value) => value
          None => Json::object({})
        },
        models,
        cases,
      })
    }
    _ => Err("上下文不是一个对象")
  }
}

///|
/// The request that is in flight right now.
///
/// The server forwards bench's last progress event verbatim (`live`) together
/// with how old it is (`liveAgeMs`). That age is the only thing that tells
/// "the model is producing tokens" apart from "the model has gone quiet":
/// between two polls nothing on screen moves by itself, so without it a stalled
/// gateway and a working one look identical.
pub(all) struct LiveProgress {
  /// `case_start`, `tick` or `case_done`.
  event : String
  model : String
  case_id : String
  repeat : Int
  /// `reasoning` until the first visible fragment arrives, `content` after.
  phase : String
  /// Stream fragments per second, over a sliding window inside the request.
  /// Fragments, not tokens — an OpenAI-compatible stream is normally one token
  /// per fragment, but nothing guarantees it, so the page shows it as `≈`.
  tok_per_s : Double
  chars : Int
  /// Fragments seen so far. The same caveat as `tok_per_s` applies.
  tokens : Int
  elapsed_ms : Double
  max_tokens : Int
  /// Position in the suite: 1-based, out of `total`.
  index : Int
  total : Int
  /// Milliseconds since the server saw that line written.
  age_ms : Double
} derive(Eq)

///|
pub extend LiveProgress with Eq::{equal, not_equal}

///|
/// Decode the `live` + `liveAgeMs` pair from a run status.
///
/// Either piece missing means "nothing live to show": a replayed run, a run
/// from before this existed, or a directory whose progress file went away.
pub fn parse_live(json : Json?, age_ms : Double?) -> LiveProgress? {
  let live = match json {
    Some(value) => as_object(value)
    None => return None
  }
  if live.is_empty() {
    return None
  }
  Some(LiveProgress::{
    event: string_field(live, "event", ""),
    model: string_field(live, "model", ""),
    case_id: string_field(live, "case", ""),
    repeat: int_field(live, "repeat", 0),
    phase: string_field(live, "phase", ""),
    tok_per_s: number_field(live, "tokPerS", 0.0),
    chars: int_field(live, "chars", 0),
    tokens: int_field(live, "frags", int_field(live, "completionTokens", 0)),
    elapsed_ms: number_field(live, "elapsedMs", 0.0),
    max_tokens: int_field(live, "maxTokens", 0),
    index: int_field(live, "index", 0),
    total: int_field(live, "total", 0),
    age_ms: match age_ms {
      Some(value) => value
      None => 0.0
    },
  })
}

///|
/// 字段缺失或不是字符串都算「没有」，与 null 一视同仁。
pub fn optional_field(obj : Map[String, Json], key : String) -> String? {
  match obj.get(key) {
    Some(String(text)) => if text == "" { None } else { Some(text) }
    _ => None
  }
}

///|
pub fn as_object(json : Json) -> Map[String, Json] {
  match json {
    Object(obj) => obj
    _ => Map([])
  }
}

///|
pub fn string_field(
  obj : Map[String, Json],
  key : String,
  fallback : String,
) -> String {
  match obj.get(key) {
    Some(String(text)) => text
    _ => fallback
  }
}

///|
pub fn int_field(obj : Map[String, Json], key : String, fallback : Int) -> Int {
  match obj.get(key) {
    Some(Number(value, ..)) => value.to_int()
    _ => fallback
  }
}

///|
pub fn bool_field(
  obj : Map[String, Json],
  key : String,
  fallback : Bool,
) -> Bool {
  match obj.get(key) {
    Some(True) => true
    Some(False) => false
    _ => fallback
  }
}

///|
pub fn number_field(
  obj : Map[String, Json],
  key : String,
  fallback : Double,
) -> Double {
  match obj.get(key) {
    Some(Number(value, ..)) => value
    _ => fallback
  }
}

///|
pub fn array_field(obj : Map[String, Json], key : String) -> Array[Json] {
  match obj.get(key) {
    Some(Array(items)) => items
    _ => []
  }
}

///|
/// 某指标的全部统计量，缺失时返回 None。
pub fn ModelSummary::metric_stats(
  self : ModelSummary,
  key : String,
) -> MetricStats? {
  self.metrics.get(key)
}

///|
/// 分位数取值：`p10` / `p20` / `p50` / `p99`，认不出来的当 p50。
///
/// 用字符串而不是枚举，是因为它一路从页面状态（按钮点击）传进来，中间还要过
/// 一层 shared 的渲染件；多一个类型只为了转一次。
pub fn MetricStats::percentile(self : MetricStats, which : String) -> Double {
  match which {
    "p10" => self.p10
    "p20" => self.p20
    "p99" => self.p99
    _ => self.p50
  }
}

///|
/// 某指标在某个分位上的取值。
pub fn ModelSummary::metric_at(
  self : ModelSummary,
  key : String,
  which : String,
) -> Double? {
  match self.metric_stats(key) {
    Some(stats) => Some(stats.percentile(which))
    None => None
  }
}

///|
/// 某指标的中位数。
pub fn ModelSummary::metric(self : ModelSummary, key : String) -> Double? {
  match self.metric_stats(key) {
    Some(stats) => Some(stats.median)
    None => None
  }
}

///|
/// 对比表用到的指标行：(显示名, data.json 里的键, 单位)。
pub fn metric_rows() -> Array[(String, String, String)] {
  [
    ("首 token", "ttft_ms", "ms"),
    ("首正文", "ttfc_ms", "ms"),
    ("总耗时", "total_ms", "ms"),
    ("输出 token", "completion_tokens", ""),
    ("推理 token", "reasoning_tokens", ""),
    ("推理占比", "reasoning_ratio", ""),
    ("decode", "decode_tok_per_s", "tok/s"),
    ("端到端", "e2e_tok_per_s", "tok/s"),
  ]
}

///|
pub extend MetricStats with Eq::{equal, not_equal}

///|
pub extend ModelSummary with Eq::{equal, not_equal}

///|
pub extend Answer with Eq::{equal, not_equal}

///|
pub extend CaseBlock with Eq::{equal, not_equal}

///|
pub extend PageData with Eq::{equal, not_equal}
