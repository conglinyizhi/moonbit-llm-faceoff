///|
/// Summary statistics over a set of comparable numbers.
pub(all) struct Stats {
  /// How many values went in.
  n : Int
  mean : Double
  median : Double
  min : Double
  max : Double
}

///|
/// Build statistics for `values`, or `None` when there is nothing to summarize.
pub fn Stats::of(values : Array[Double]) -> Stats? {
  if values.is_empty() {
    return None
  }
  let sorted = values.copy()
  sorted.sort()
  let n = sorted.length()
  let mut sum = 0.0
  for value in sorted {
    sum = sum + value
  }
  let median = if n % 2 == 1 {
    sorted[n / 2]
  } else {
    (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
  }
  Some({
    n,
    mean: sum / n.to_double(),
    median,
    min: sorted[0],
    max: sorted[n - 1],
  })
}

///|
/// Per-model roll-up of every attempt in a benchmark.
///
/// Only successful runs feed the statistics; failures and truncations are
/// counted separately, because a model that fails or gets cut off cannot be
/// compared on speed.
pub(all) struct ModelSummary {
  model : String
  /// Attempts seen for this model.
  runs : Int
  /// Attempts that errored out.
  failures : Int
  /// Successful attempts that hit the token budget (`finish_reason: length`).
  truncated : Int
  /// Attempts that needed more than one HTTP attempt, i.e. the gateway
  /// rate-limited or errored first. Counted whether or not the retry succeeded.
  retried : Int
  ttft_ms : Stats?
  ttfc_ms : Stats?
  total_ms : Stats?
  prompt_tokens : Stats?
  completion_tokens : Stats?
  reasoning_tokens : Stats?
  reasoning_ratio : Stats?
  decode_tok_per_s : Stats?
  e2e_tok_per_s : Stats?
}

///|
/// Roll up the attempts belonging to one model.
pub fn summarize(model : String, results : Array[RunResult]) -> ModelSummary {
  let ttft : Array[Double] = []
  let ttfc : Array[Double] = []
  let total : Array[Double] = []
  let prompt_tokens : Array[Double] = []
  let completion_tokens : Array[Double] = []
  let reasoning_tokens : Array[Double] = []
  let reasoning_ratio : Array[Double] = []
  let decode : Array[Double] = []
  let e2e : Array[Double] = []
  let mut runs = 0
  let mut failures = 0
  let mut truncated = 0
  let mut retried = 0
  for result in results {
    if result.model != model {
      continue
    }
    runs = runs + 1
    if result.attempts > 1 {
      retried = retried + 1
    }
    if !result.ok {
      failures = failures + 1
      continue
    }
    if result.finish_reason is Some("length") {
      truncated = truncated + 1
    }
    if result.ttft_ms is Some(value) {
      ttft.push(value)
    }
    if result.ttfc_ms is Some(value) {
      ttfc.push(value)
    }
    total.push(result.total_ms)
    prompt_tokens.push(result.prompt_tokens.to_double())
    completion_tokens.push(result.completion_tokens.to_double())
    reasoning_tokens.push(result.reasoning_tokens.to_double())
    if result.reasoning_ratio() is Some(value) {
      reasoning_ratio.push(value)
    }
    if result.decode_tok_per_s() is Some(value) {
      decode.push(value)
    }
    if result.e2e_tok_per_s() is Some(value) {
      e2e.push(value)
    }
  }
  {
    model,
    runs,
    failures,
    truncated,
    retried,
    ttft_ms: Stats::of(ttft),
    ttfc_ms: Stats::of(ttfc),
    total_ms: Stats::of(total),
    prompt_tokens: Stats::of(prompt_tokens),
    completion_tokens: Stats::of(completion_tokens),
    reasoning_tokens: Stats::of(reasoning_tokens),
    reasoning_ratio: Stats::of(reasoning_ratio),
    decode_tok_per_s: Stats::of(decode),
    e2e_tok_per_s: Stats::of(e2e),
  }
}

///|
/// Roll up every model present in `results`, preserving first-seen order.
pub fn summarize_all(
  models : Array[String],
  results : Array[RunResult],
) -> Array[ModelSummary] {
  let summaries : Array[ModelSummary] = []
  for model in models {
    summaries.push(summarize(model, results))
  }
  summaries
}
