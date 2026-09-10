///|
/// A self-contained data document for the static page.
///
/// The page module deliberately does not link against this library: it is a
/// separate module with its own (heavier) dependency set, and coupling it to
/// `moonllm` through a workspace would force one `moonbitlang/async` version on
/// both. So the numbers are computed here, once, and handed over as JSON.
///
/// Shape:
///
/// ```json
/// {
///   "source": "bench/results-example.jsonl",
///   "models": ["A", "B"],
///   "summaries": [
///     { "model": "A", "runs": 18, "failures": 0, "truncated": 0, "retried": 0,
///       "metrics": { "ttft_ms": { "n": 18, "median": 138, "mean": 138.8,
///                                 "min": 85, "max": 213 }, ... } }
///   ],
///   "cases": [
///     { "id": "math-short",
///       "answers": [ { "model": "A", "ok": true, "total_ms": 620.1,
///                      "completion_tokens": 190, "reasoning_tokens": 165,
///                      "content": "...", "error": null } ] }
///   ]
/// }
/// ```
///
/// `metrics` keys are exactly the ones listed in `metric_names()`; the page
/// renders whatever is present.
pub fn page_data_json(
  source : String,
  models : Array[String],
  results : Array[RunResult],
) -> Json {
  let summaries = summarize_all(models, results)
  Json::object({
    "source": Json::string(source),
    "models": Json::array(models.map(Json::string)),
    "summaries": Json::array(summaries.map(summary_json)),
    "cases": Json::array(cases_json(models, results)),
  })
}

///|
/// The metric keys the page can expect in each summary.
pub fn metric_names() -> Array[String] {
  [
    "ttft_ms", "ttfc_ms", "total_ms", "prompt_tokens", "completion_tokens", "reasoning_tokens",
    "reasoning_ratio", "decode_tok_per_s", "e2e_tok_per_s",
  ]
}

///|
fn summary_json(summary : ModelSummary) -> Json {
  let metrics : Map[String, Json] = Map([])
  put_stats(metrics, "ttft_ms", summary.ttft_ms)
  put_stats(metrics, "ttfc_ms", summary.ttfc_ms)
  put_stats(metrics, "total_ms", summary.total_ms)
  put_stats(metrics, "prompt_tokens", summary.prompt_tokens)
  put_stats(metrics, "completion_tokens", summary.completion_tokens)
  put_stats(metrics, "reasoning_tokens", summary.reasoning_tokens)
  put_stats(metrics, "reasoning_ratio", summary.reasoning_ratio)
  put_stats(metrics, "decode_tok_per_s", summary.decode_tok_per_s)
  put_stats(metrics, "e2e_tok_per_s", summary.e2e_tok_per_s)
  Json::object({
    "model": Json::string(summary.model),
    "runs": Json::number(summary.runs.to_double()),
    "failures": Json::number(summary.failures.to_double()),
    "truncated": Json::number(summary.truncated.to_double()),
    "retried": Json::number(summary.retried.to_double()),
    "metrics": Json::object(metrics),
  })
}

///|
fn put_stats(metrics : Map[String, Json], key : String, stats : Stats?) -> Unit {
  match stats {
    None => ()
    Some(stats) =>
      metrics[key] = Json::object({
        "n": Json::number(stats.n.to_double()),
        "median": Json::number(stats.median),
        "mean": Json::number(stats.mean),
        "min": Json::number(stats.min),
        "max": Json::number(stats.max),
      })
  }
}

///|
fn cases_json(
  models : Array[String],
  results : Array[RunResult],
) -> Array[Json] {
  let order : Array[String] = []
  for result in results {
    if !order.contains(result.case_id) {
      order.push(result.case_id)
    }
  }
  order.map(fn(case_id) {
    Json::object({
      "id": Json::string(case_id),
      "answers": Json::array(
        models.map(fn(model) { answer_json(results, case_id, model) }),
      ),
    })
  })
}

///|
fn answer_json(
  results : Array[RunResult],
  case_id : String,
  model : String,
) -> Json {
  let mut fallback : RunResult? = None
  for result in results {
    if result.case_id != case_id || result.model != model {
      continue
    }
    if result.ok {
      return answer_of(result)
    }
    if fallback is None {
      fallback = Some(result)
    }
  }
  match fallback {
    Some(result) => answer_of(result)
    None => Json::null()
  }
}

///|
fn answer_of(result : RunResult) -> Json {
  Json::object({
    "model": Json::string(result.model),
    "ok": Json::boolean(result.ok),
    "total_ms": Json::number(result.total_ms),
    "ttft_ms": optional_number(result.ttft_ms),
    "completion_tokens": Json::number(result.completion_tokens.to_double()),
    "reasoning_tokens": Json::number(result.reasoning_tokens.to_double()),
    "content": Json::string(result.content),
    "error": optional_string(result.error),
  })
}
