///|
/// 结果区的共享渲染组件：模型卡片、对比表、逐用例输出。
///
/// 静态导出页和交互页共用同一套，保证两边看到的结果结构一致。

///|
pub fn txt(value : String) -> @html.Html {
  @html.text(value)
}

///|
pub fn el(
  tag : String,
  class_ : String,
  children : Array[@html.Html],
) -> @html.Html {
  let attrs = if class_ == "" {
    @html.Attrs::build()
  } else {
    @html.Attrs::build().class(class_)
  }
  @html.node(tag, attrs, children)
}

///|
pub fn plain(tag : String, children : Array[@html.Html]) -> @html.Html {
  el(tag, "", children)
}

///|
/// 保留一位小数，整数则不显示小数点。
pub fn fmt_number(value : Double) -> String {
  ((value * 10.0).round() / 10.0).to_string()
}

///|
pub fn format_value(value : Double?, unit : String) -> String {
  match value {
    None => "—"
    Some(value) =>
      if unit == "" {
        fmt_number(value)
      } else {
        fmt_number(value) + " " + unit
      }
  }
}

///|
/// 模型摘要卡片。
pub fn summary_card(summary : ModelSummary) -> @html.Html {
  let badges : Array[@html.Html] = [
    el("span", "badge", [txt("\{summary.runs} 次")]),
  ]
  if summary.failures > 0 {
    badges.push(
      el("span", "badge badge-warn", [txt("失败 \{summary.failures}")]),
    )
  }
  if summary.truncated > 0 {
    badges.push(
      el("span", "badge badge-warn", [txt("截断 \{summary.truncated}")]),
    )
  }
  if summary.retried > 0 {
    badges.push(
      el("span", "badge badge-warn", [txt("重试 \{summary.retried}")]),
    )
  }
  if summary.failures == 0 && summary.truncated == 0 && summary.retried == 0 {
    badges.push(el("span", "badge badge-ok", [txt("全部成功")]))
  }
  el("div", "card", [
    el("div", "card-head", [@html.h2([txt(summary.model)])]),
    el("div", "badges", badges),
    stat_list(summary),
  ])
}

///|
pub fn stat_list(summary : ModelSummary) -> @html.Html {
  let rows = metric_rows().map(fn(row) {
    let (label, key, unit) = row
    stat(label, summary.metric_stats(key), unit)
  })
  el("dl", "stat-list", rows)
}

///|
pub fn stat(label : String, stats : MetricStats?, unit : String) -> @html.Html {
  let values : Array[@html.Html] = []
  match stats {
    None => values.push(txt("—"))
    Some(stats) => {
      values.push(txt(format_value(Some(stats.median), unit)))
      if stats.n > 1 {
        values.push(
          el("span", "stat-range", [
            txt("  \{fmt_number(stats.min)}–\{fmt_number(stats.max)}"),
          ]),
        )
      }
    }
  }
  @html.fragment([@html.dt([txt(label)]), @html.dd(values)])
}

///|
pub fn model_cards(data : PageData) -> @html.Html {
  el("section", "cards", data.summaries.map(summary_card))
}

///|
/// 各模型中位数对比表；不足两个模型时不渲染。
pub fn comparison(data : PageData) -> @html.Html {
  if data.summaries.length() < 2 {
    return @html.fragment([])
  }
  let head_cells = [
    @html.th([txt("指标")]),
    ..data.summaries.map(fn(summary) { @html.th([txt(summary.model)]) }),
  ]
  let rows = metric_rows().map(fn(row) {
    let (label, key, unit) = row
    let cells = [
      @html.td([txt(label)]),
      ..data.summaries.map(fn(summary) {
        @html.td([txt(format_value(summary.metric(key), unit))])
      }),
    ]
    @html.tr(cells)
  })
  el("section", "", [
    el("h2", "section-title", [
      txt("对比"),
      el("span", "", [txt("中位数")]),
    ]),
    @html.table([@html.thead([@html.tr(head_cells)]), @html.tbody(rows)]),
  ])
}

///|
pub fn answers(
  data : PageData,
  editor? : (String, String) -> @html.Html,
) -> @html.Html {
  if data.cases.length() == 0 {
    return @html.fragment([])
  }
  el("section", "", [
    el("h2", "section-title", [
      txt("用例输出"),
      el("span", "", [txt("每个模型一条")]),
    ]),
    el("div", "cases", data.cases.map(fn(block) { case_block(block, editor?) })),
  ])
}

///|
pub fn case_block(
  block : CaseBlock,
  editor? : (String, String) -> @html.Html,
) -> @html.Html {
  el("article", "case", [
    el("div", "case-head", [@html.h3([txt(block.id)])]),
    el(
      "div",
      "",
      block.answers.map(fn(answer) { answer_block(block.id, answer, editor?) }),
    ),
  ])
}

///|
pub fn answer_block(
  case_id : String,
  answer : Answer,
  editor? : (String, String) -> @html.Html,
) -> @html.Html {
  let head = if answer.ok {
    "\{answer.model} · \{format_value(Some(answer.total_ms), "ms")} · \{answer.completion_tokens} token（推理 \{answer.reasoning_tokens}）"
  } else {
    answer.model
  }
  let body = if answer.ok {
    @html.pre([txt(answer.content)])
  } else {
    let message = match answer.error {
      Some(error) => error
      None => "failed"
    }
    el("p", "failed", [txt(message)])
  }
  let parts : Array[@html.Html] = [
    el("div", "answer-head", [txt(head)]),
    body,
    // 人工判定跟着答案走：以后翻回来时，当时的结论就在旁边
    verdict_badge(answer),
  ]
  // 可编辑的地方才长编辑器：静态报告只读，没有 editor 钩子
  match editor {
    Some(build) => parts.push(build(case_id, answer.model))
    None => ()
  }
  // 失败的那些没有思考可看
  if answer.ok && answer.reasoning.length() > 0 {
    parts.push(cot_block(answer))
  }
  el("div", "answer", parts)
}

///|
/// 人工判定与备注。没有标注就什么都不渲染，不占位。
pub fn verdict_badge(answer : Answer) -> @html.Html {
  match answer.verdict {
    None => @html.fragment([])
    Some(verdict) => {
      let note = match answer.note {
        Some(note) => if note == "" { "" } else { note }
        None => ""
      }
      el("div", "verdict", [
        el("span", "verdict-badge verdict-" + verdict, [
          txt(verdict_label(verdict)),
        ]),
        if note == "" {
          @html.fragment([])
        } else {
          el("span", "verdict-note", [txt(note)])
        },
      ])
    }
  }
}

///|
/// 答案背后的思考过程。
///
/// 默认收起：它往往比答案长好几倍，拿到答案之后是第二个才想看的东西。但对比两个
/// 推理模型时，它正是要比的那部分——所以放在同一个答案块里，不用去翻日志。
fn cot_block(answer : Answer) -> @html.Html {
  el("details", "cot", [
    el("summary", "", [
      txt(
        "思考过程 · \{answer.reasoning_tokens} token · \{answer.reasoning.length()} 字",
      ),
    ]),
    @html.pre([txt(answer.reasoning)]),
  ])
}

///|
/// 结果区整体（卡片 + 对比 + 用例），供两个前端共用。
pub fn results_section(
  data : PageData,
  editor? : (String, String) -> @html.Html,
) -> @html.Html {
  @html.fragment([model_cards(data), comparison(data), answers(data, editor?)])
}

///|
/// 一条答案的标注编辑器：三档按钮 + 备注。
///
/// 两个页面共用；回调由调用方给（shared 不知道各页面的 Msg 类型）。
/// 「再点一次同一个判定」= 清除，不用额外做一个「撤销」按钮。
pub fn annotation_editor(
  annotation : Annotation?,
  note : String,
  // 按钮收 Cmd（和 @html.button 的 on_click 一致），文本框收 Emit[String]
  on_pass : @cmd.Cmd,
  on_fail : @cmd.Cmd,
  on_unsure : @cmd.Cmd,
  on_clear : @cmd.Cmd,
  on_note : @cmd.Emit[String],
  on_save : @cmd.Cmd,
) -> @html.Html {
  let current = match annotation {
    Some(entry) => entry.verdict
    None => ""
  }
  let button = fn(verdict : String, label : String, handler : @cmd.Cmd) {
    let class_ = if current == verdict {
      "verdict-btn active"
    } else {
      "verdict-btn"
    }
    @html.button(class=class_, on_click=handler, [txt(label)])
  }
  el("div", "annotate", [
    el("div", "annotate-row", [
      button("pass", "✅ 通过", on_pass),
      button("fail", "❌ 不行", on_fail),
      button("unsure", "🤔 拿不准", on_unsure),
      if current == "" {
        @html.fragment([])
      } else {
        @html.button(class="link-btn", on_click=on_clear, [txt("清除")])
      },
    ]),
    el("div", "annotate-note", [
      @html.input(
        input_type=@html.InputType::Text,
        class="note-input",
        value=note,
        placeholder="备注：这里出现了什么问题？",
        on_input=on_note,
      ),
      @html.button(class="ghost", on_click=on_save, [txt("存备注")]),
    ]),
  ])
}
