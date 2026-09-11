///|
/// 一个指标的统计量。
pub(all) struct MetricStats {
  n : Int
  median : Double
  min : Double
  max : Double
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
  answers : Array[Answer]
} derive(Eq)

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
  {
    n: int_field(obj, "n", 0),
    median: number_field(obj, "median", 0.0),
    min: number_field(obj, "min", 0.0),
    max: number_field(obj, "max", 0.0),
  }
}

///|
fn parse_case(json : Json) -> CaseBlock {
  let obj = as_object(json)
  {
    id: string_field(obj, "id", ""),
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
