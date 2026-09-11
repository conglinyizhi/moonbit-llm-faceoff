///|
/// 判定在导出里的说法。三档是稳定的英文标识，显示（含 emoji）是这一层的事。
pub fn verdict_label(verdict : String) -> String {
  match verdict {
    "pass" => "✅ 通过"
    "fail" => "❌ 不行"
    "unsure" => "🤔 拿不准"
    _ => verdict
  }
}

///|
/// 把一次对比渲染成 Markdown，给页面上的「复制」按钮用。
///
/// 和 `view.mbt` 里的 `comparison` / `answers` 是同一批数据的第二种呈现方式：
/// 那边是给浏览器看的 HTML，这边是给文档、issue、聊天窗口的纯文本。数字都出自
/// 同一个 `PageData`，所以两种呈现不会对不上。
pub fn results_markdown(data : PageData) -> String {
  let out = StringBuilder()
  out.write_string("# 模型对比\n")
  if data.source != "" {
    out.write_string("\n数据来源：`\{data.source}`\n")
  }
  if data.summaries.length() == 0 {
    return out.to_string()
  }
  out.write_string("\n| 指标 |")
  for summary in data.summaries {
    out.write_string(" " + summary.model + " |")
  }
  out.write_string("\n| --- |")
  for _ in data.summaries {
    out.write_string(" --- |")
  }
  out.write_string("\n")
  for row in metric_rows() {
    let (label, key, unit) = row
    let heading = if unit == "" { label } else { "\{label} (\{unit})" }
    out.write_string("| \{heading} |")
    for summary in data.summaries {
      out.write_string(" " + format_value(summary.metric(key), unit) + " |")
    }
    out.write_string("\n")
  }
  // 运行次数与失败/截断/重试不在 metric_rows 里，但读报告的人需要它们。
  out.write_string("\n运行：")
  let counts = data.summaries.map(fn(summary) {
    "\{summary.model} \{summary.runs} 次（失败 \{summary.failures}，截断 \{summary.truncated}，重试 \{summary.retried}）"
  })
  out.write_string(counts.join("；"))
  out.write_string("\n")
  for block in data.cases {
    out.write_string("\n## 用例 `\{block.id}`\n")
    for answer in block.answers {
      out.write_string("\n### \{answer.model}\n")
      if answer.ok {
        let mut meta = "\{fmt_number(answer.total_ms)} ms · \{answer.completion_tokens} token"
        if answer.reasoning_tokens > 0 {
          meta += "（推理 \{answer.reasoning_tokens}）"
        }
        out.write_string("\n`\{meta}`\n\n```text\n\{answer.content}\n```\n")
      } else {
        let reason = answer.error.unwrap_or("未知错误")
        out.write_string("\n失败：\{reason}\n")
      }
      // 人工判定跟着导出走：这份 Markdown 是留着以后翻的，
      // 当时的结论必须一起带走
      match answer.verdict {
        Some(verdict) => {
          let note = match answer.note {
            Some(note) => if note == "" { "" } else { " — " + note }
            None => ""
          }
          out.write_string("\n> \{verdict_label(verdict)}\{note}\n")
        }
        None => ()
      }
    }
  }
  out.to_string()
}
