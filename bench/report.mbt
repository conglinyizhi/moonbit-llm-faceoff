///|
/// One decimal place, without a trailing `.0`.
fn fmt(value : Double) -> String {
  let rounded = (value * 10.0).round() / 10.0
  rounded.to_string()
}

///|
fn cell(label : String, width : Int) -> String {
  label.pad_end(width, ' ')
}

///|
fn num(value : String, width : Int) -> String {
  value.pad_start(width, ' ')
}

///|
/// A latency/token row: label, n, median, mean, min, max.
fn stats_row(label : String, stats : Stats?) -> String {
  match stats {
    None => "    " + cell(label, 18) + num("-", 6) + "\n"
    Some(stats) =>
      "    " +
      cell(label, 18) +
      num(stats.n.to_string(), 6) +
      num(fmt(stats.median), 11) +
      num(fmt(stats.mean), 11) +
      num(fmt(stats.min), 11) +
      num(fmt(stats.max), 11) +
      "\n"
  }
}

///|
/// One live progress line for a finished attempt.
pub fn format_run_line(result : RunResult) -> String {
  let head = "[\{result.model}] \{result.case_id} #\{result.repeat + 1}"
  if !result.ok {
    let message = match result.error {
      Some(error) => error
      None => "failed"
    }
    return head + "  FAILED: " + message
  }
  let parts : Array[String] = [
    "ttft=" + fmt_opt(result.ttft_ms) + "ms",
    "ttfc=" + fmt_opt(result.ttfc_ms) + "ms",
    "total=" + fmt(result.total_ms / 1000.0) + "s",
    "out=" +
    result.completion_tokens.to_string() +
    "(reasoning " +
    result.reasoning_tokens.to_string() +
    ")",
  ]
  let speed = match result.decode_tok_per_s() {
    Some(speed) => "  " + fmt(speed) + " tok/s"
    None => ""
  }
  let finish = match result.finish_reason {
    Some("length") => "  [truncated]"
    _ => ""
  }
  let retries = if result.attempts > 1 {
    "  [attempts " + result.attempts.to_string() + "]"
  } else {
    ""
  }
  head + "  " + parts.join("  ") + speed + finish + retries
}

///|
fn fmt_opt(value : Double?) -> String {
  match value {
    Some(value) => fmt(value)
    None => "-"
  }
}

///|
/// The full human-readable report: one block per model, then a comparison.
pub fn format_summaries(summaries : Array[ModelSummary]) -> String {
  let out = StringBuilder()
  for summary in summaries {
    out.write_string("model \{summary.model}\n")
    out.write_string(
      "  runs \{summary.runs}   failures \{summary.failures}   truncated \{summary.truncated}   retried \{summary.retried}\n",
    )
    out.write_string(
      "    " +
      cell("", 18) +
      num("n", 6) +
      num("median", 11) +
      num("mean", 11) +
      num("min", 11) +
      num("max", 11) +
      "\n",
    )
    out.write_string(stats_row("first token (ms)", summary.ttft_ms))
    out.write_string(stats_row("first answer (ms)", summary.ttfc_ms))
    out.write_string(stats_row("total (ms)", summary.total_ms))
    out.write_string(stats_row("prompt tokens", summary.prompt_tokens))
    out.write_string(stats_row("completion tokens", summary.completion_tokens))
    out.write_string(stats_row("reasoning tokens", summary.reasoning_tokens))
    out.write_string(stats_row("reasoning share", summary.reasoning_ratio))
    out.write_string(stats_row("decode tok/s", summary.decode_tok_per_s))
    out.write_string(stats_row("end-to-end tok/s", summary.e2e_tok_per_s))
    out.write_string("\n")
  }
  out.write_string(comparison_table(summaries))
  out.to_string()
}

///|
/// Median-per-model table. With exactly two models a ratio column is added,
/// which is the usual "is the bigger one worth it" question.
fn comparison_table(summaries : Array[ModelSummary]) -> String {
  if summaries.length() == 0 {
    return ""
  }
  let label_width = 22
  let value_width = 16
  let metrics : Array[(String, (ModelSummary) -> Double?)] = [
    (
      "first token (ms)",
      fn(s) {
        match s.ttft_ms {
          Some(v) => Some(v.median)
          None => None
        }
      },
    ),
    (
      "first answer (ms)",
      fn(s) {
        match s.ttfc_ms {
          Some(v) => Some(v.median)
          None => None
        }
      },
    ),
    (
      "total (ms)",
      fn(s) {
        match s.total_ms {
          Some(v) => Some(v.median)
          None => None
        }
      },
    ),
    (
      "completion tokens",
      fn(s) {
        match s.completion_tokens {
          Some(v) => Some(v.median)
          None => None
        }
      },
    ),
    (
      "reasoning tokens",
      fn(s) {
        match s.reasoning_tokens {
          Some(v) => Some(v.median)
          None => None
        }
      },
    ),
    (
      "reasoning share",
      fn(s) {
        match s.reasoning_ratio {
          Some(v) => Some(v.median)
          None => None
        }
      },
    ),
    (
      "decode tok/s",
      fn(s) {
        match s.decode_tok_per_s {
          Some(v) => Some(v.median)
          None => None
        }
      },
    ),
    (
      "end-to-end tok/s",
      fn(s) {
        match s.e2e_tok_per_s {
          Some(v) => Some(v.median)
          None => None
        }
      },
    ),
  ]
  let out = StringBuilder()
  out.write_string("comparison (median per model)\n")
  out.write_string("  " + cell("metric", label_width))
  for summary in summaries {
    out.write_string(num(summary.model, value_width))
  }
  let show_ratio = summaries.length() == 2
  if show_ratio {
    out.write_string(num("ratio", 10))
  }
  out.write_string("\n")
  for metric in metrics {
    let (label, pick) = metric
    out.write_string("  " + cell(label, label_width))
    let values : Array[Double?] = []
    for summary in summaries {
      let value = pick(summary)
      values.push(value)
      out.write_string(num(fmt_opt(value), value_width))
    }
    if show_ratio {
      let ratio = match (values[0], values[1]) {
        (Some(a), Some(b)) => if a == 0.0 { "-" } else { fmt(b / a) + "x" }
        _ => "-"
      }
      out.write_string(num(ratio, 10))
    }
    out.write_string("\n")
  }
  out.to_string()
}
