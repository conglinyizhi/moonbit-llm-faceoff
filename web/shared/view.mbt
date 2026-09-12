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
  el("div", "stat-list", rows)
}

///|

///|
/// 分位数那几格里单位跟在数字后面；有些指标没有单位（token 数），别留一堆空格
fn unit_suffix(unit : String) -> String {
  if unit == "" {
    ""
  } else {
    " " + unit
  }
}

///|
pub fn stat(label : String, stats : MetricStats?, unit : String) -> @html.Html {
  let cells : Array[@html.Html] = [el("span", "stat-label", [txt(label)])]
  match stats {
    None => cells.push(el("span", "stat-value", [txt("—")]))
    Some(stats) => {
      // 主值是 P50，副行把另外三个分位排出来：卡片不跟着对比表的分位切换走，
      // 一张卡上就能看全「顺的时候多快、通常多快、最差的那次多慢」。
      // 副行给分位数而不是 min~max：极值被一两次抖动就带跑了，P10–P99 这段
      // 才是「它平时在哪」。
      cells.push(
        el("span", "stat-value", [txt(format_value(Some(stats.p50), unit))]),
      )
      if stats.n > 1 {
        // 三格等宽：数字长短不一时，P10/P20/P99 在竖直方向仍然对齐；
        // 整行占满两列，所以标签和值始终在同一行，不会被挤下去
        cells.push(
          el("span", "stat-pcts", [
            el("span", "", [
              txt("P10 \{fmt_number(stats.p10)}\{unit_suffix(unit)}"),
            ]),
            el("span", "", [
              txt("P20 \{fmt_number(stats.p20)}\{unit_suffix(unit)}"),
            ]),
            el("span", "", [
              txt("P99 \{fmt_number(stats.p99)}\{unit_suffix(unit)}"),
            ]),
          ]),
        )
      }
    }
  }
  el("div", "stat", cells)
}

///|
pub fn model_cards(data : PageData) -> @html.Html {
  el("section", "cards", data.summaries.map(summary_card))
}

///|
/// 各模型中位数对比表；不足两个模型时不渲染。
pub fn comparison(
  data : PageData,
  which? : String = "p50",
  switch? : @html.Html,
) -> @html.Html {
  if data.summaries.length() < 2 {
    return @html.fragment([])
  }
  let head_cells = [
    @html.th([txt("指标")]),
    ..data.summaries.map(fn(summary) {
      @html.th([txt("\{summary.model}  \{percentile_label(which)}")])
    }),
  ]
  let rows = metric_rows().map(fn(row) {
    let (label, key, unit) = row
    let cells = [
      @html.td([txt(label)]),
      ..data.summaries.map(fn(summary) {
        @html.td([txt(format_value(summary.metric_at(key, which), unit))])
      }),
    ]
    @html.tr(cells)
  })
  el("section", "", [
    el("h2", "section-title", [
      txt("对比"),
      el("span", "", [txt(percentile_label(which))]),
      match switch {
        Some(control) => el("span", "view-switch", [control])
        None => @html.fragment([])
      },
    ]),
    @html.table([@html.thead([@html.tr(head_cells)]), @html.tbody(rows)]),
  ])
}

///|
/// 分位数的显示名。P50 就是中位数，但表头写「P50」比写「中位数」更能对上那排
/// 按钮，所以标题行这里统一用 P 名。
pub fn percentile_label(which : String) -> String {
  match which {
    "p10" => "P10"
    "p20" => "P20"
    "p99" => "P99"
    _ => "P50"
  }
}

///|
pub fn answers(
  data : PageData,
  mode? : String = "stacked",
  switch? : @html.Html,
  editor? : (String, String) -> @html.Html,
  context? : (String) -> @html.Html,
) -> @html.Html {
  if data.cases.length() == 0 {
    return @html.fragment([])
  }
  let hint = match mode {
    "columns" => "每个模型一列，各自滚动"
    "diff" => "以第一个模型为基准"
    _ => "每个模型一条"
  }
  el("section", "", [
    el("h2", "section-title", [
      txt("用例输出"),
      el("span", "", [txt(hint)]),
      match switch {
        Some(control) => el("span", "view-switch", [control])
        None => @html.fragment([])
      },
    ]),
    el(
      "div",
      "cases",
      data.cases.map(fn(block) { case_block(block, mode~, editor?, context?) }),
    ),
  ])
}

///|
pub fn case_block(
  block : CaseBlock,
  mode? : String = "stacked",
  editor? : (String, String) -> @html.Html,
  context? : (String) -> @html.Html,
) -> @html.Html {
  el("article", "case", [
    el("div", "case-head", [
      @html.h3([txt(block.id)]),
      match context {
        Some(button) => el("span", "case-head-actions", [button(block.id)])
        None => @html.fragment([])
      },
    ]),
    // 问题本身：报告里只给一个 id，读的人不知道这条到底问的是什么
    if block.prompt == "" {
      @html.fragment([])
    } else {
      el("p", "case-prompt", [txt(block.prompt)])
    },
    // system 可能很长，折起来；没有就不渲染（这个条件不会随轮询变化，不会跳）
    if block.system == "" {
      @html.fragment([])
    } else {
      el("details", "case-system", [
        el("summary", "", [txt("system prompt")]),
        @html.pre([txt(block.system)]),
      ])
    },
    match mode {
      "columns" => answer_columns(block, editor?)
      "diff" => answer_diffs(block)
      _ =>
        el(
          "div",
          "",
          block.answers.map(fn(answer) {
            answer_block(block.id, answer, editor?)
          }),
        )
    },
  ])
}

///|

///|
/// 正文的显示形式：去掉首尾空白（含换行），中间原样保留。
///
/// 只在显示层做：数据里那份不动，导出、比对用的还是原文
pub fn display_text(text : String) -> String {
  text.trim(chars=" \t\r\n").to_owned()
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
    // 模型常在正文前后带一串换行：`pre` 会把它原样渲染成一整块空白，
    // 看起来就是「答案上面有一片空的地方」
    @html.pre([txt(display_text(answer.content))])
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
/// 一条答案的简介：长回答对比时先看这一行就够判断值不值得读。
pub fn answer_digest(answer : Answer) -> String {
  if !answer.ok {
    return "失败"
  }
  let text = answer.content.trim(chars=" \t\r\n").to_owned()
  "\{text.length()} 字 / \{answer.completion_tokens} token"
}

///|
/// 同一道题、多个模型：并排一列一个。
///
/// 长回答的问题不是「有没有可比的地方」，而是「两边都摆出来之后页面谁也不
/// 认识谁」：竖着堆下来，1B 写了 1100 字、2B 写了 700 字，看完第一段就找不
/// 回第二段在哪。列里各自滚动、表头钉住，至少能一直知道自己在读哪个模型。
pub fn answer_columns(
  block : CaseBlock,
  editor? : (String, String) -> @html.Html,
) -> @html.Html {
  el(
    "div",
    "answer-cols",
    block.answers.map(fn(answer) {
      el("div", "answer-col", [
        el("div", "answer-col-head", [
          el("span", "answer-col-model", [txt(answer.model)]),
          el("span", "answer-col-meta", [txt(answer_digest(answer))]),
        ]),
        el("div", "answer-col-body", [answer_block(block.id, answer, editor?)]),
      ])
    }),
  )
}

///|
/// 一行差异：`change-*` 带行内高亮——整行只差一个标点时，标红的那几个字才是
/// 有用的信息。
fn diff_line_html(line : DiffLine) -> @html.Html {
  if line.kind == "gap" {
    return el("div", "diff-gap", [txt(line.text)])
  }
  let body = match line.parts {
    Some(parts) =>
      el(
        "span",
        "diff-text",
        parts.map(fn(part) {
          if part.kind == "same" {
            txt(part.text)
          } else {
            el("span", "diff-part-" + part.kind, [txt(part.text)])
          }
        }),
      )
    None => txt(line.text)
  }
  el("div", "diff-line diff-line-" + line.kind, [body])
}

///|
/// 以第一个模型为基准的差异视图：每个后续模型一块。
///
/// 行级而不是字符级：两个模型各写一段话时，字符级的公共子序列很短，整段都会
/// 标成「变了」，等于没有定位。行对齐之后，相同的行压掉，读者看到的是「从哪里
/// 开始分岔」。
pub fn answer_diffs(block : CaseBlock) -> @html.Html {
  match block.answers {
    [] => el("p", "muted", [txt("没有答案")])
    [base, ..] =>
      if block.answers.length() == 1 {
        el("p", "muted", [
          txt(
            "只有一个模型，没有可比的对象（勾两个模型再跑）。",
          ),
        ])
      } else {
        el(
          "div",
          "diffs",
          block.answers[1:].map(fn(answer) { diff_block(base, answer) }),
        )
      }
  }
}

///|
pub fn diff_block(left : Answer, right : Answer) -> @html.Html {
  el("article", "diff-block", [
    el("div", "diff-title", [
      txt(
        "\{left.model} → \{right.model}：\{answer_digest(left)} / \{answer_digest(right)}",
      ),
    ]),
    if !left.ok || !right.ok {
      el("p", "failed", [
        txt(
          if !left.ok {
            "基准那条失败了，比不了"
          } else {
            "这条失败了，比不了"
          },
        ),
      ])
    } else {
      let lines = collapse_same(diff_lines(left.content, right.content), 2)
      el("div", "diff-lines", lines.map(diff_line_html))
    },
  ])
}

///|
/// 一块浮起来的对话框（拟态）：柔和的双向阴影、和页面同一个底色。
///
/// 用 CSS 而不是 `<dialog>`：页面是 VDOM 渲染的，`<dialog>` 的 open/close 由
/// 浏览器命令式地管，两边状态很容易不同步——同一个毛病在 start 按钮那里已经
/// 踩过一次（`disabled` 属性不会被 diff 摘掉）。
///
/// 点背景关掉：背景本身是一个带 on_click 的元素，不做「点外面」的坐标判断。
pub fn modal(
  title : String,
  subtitle : String,
  body : @html.Html,
  on_close : @cmd.Cmd,
) -> @html.Html {
  el("div", "modal-backdrop", [
    el("div", "modal", [
      el("div", "modal-head", [
        el("div", "modal-title", [
          el("h3", "", [txt(title)]),
          if subtitle == "" {
            @html.fragment([])
          } else {
            el("span", "modal-subtitle", [txt(subtitle)])
          },
        ]),
        @html.button(class="ghost modal-close", on_click=on_close, [
          txt("关闭"),
        ]),
      ]),
      el("div", "modal-body", [body]),
    ]),
  ])
}

///|
/// 用例行右边那个「请求上下文」按钮。点开是一整个对话框，所以这里只负责发出
/// 一个意图，具体的内容由页面拼。
pub fn context_button(on_click : @cmd.Cmd) -> @html.Html {
  @html.button(class="context-btn", on_click~, [txt("请求上下文")])
}

///|
/// 一次运行的请求上下文：参数 + 每条用例实际生效的 system 与 user 消息。
///
/// 一条用例一块，按「模型会收到什么」的顺序写：system、user、然后是本条的
/// 采样参数。看的是「到底问了什么」，不是「配置表」。
pub fn run_context_body(context : RunContext, case_id : String) -> @html.Html {
  let wanted = context.cases.filter(fn(entry) { entry.id == case_id })
  let cases = if wanted.length() > 0 {
    wanted
  } else if context.cases.length() > 0 {
    context.cases
  } else {
    // inline prompt 的运行没有 cases.jsonl，那条 prompt 就在请求文档里
    inline_case(context)
  }
  el("div", "context", [
    context_params(context),
    el(
      "div",
      "context-cases",
      cases.map(fn(entry) {
        el("article", "context-case", [
          el("div", "context-case-head", [
            @html.h3([txt(entry.id)]),
            el("span", "context-meta", [
              txt(
                "max_tokens \{entry.max_tokens} · temperature \{temperature_text(entry.temperature)}",
              ),
            ]),
          ]),
          message_block("system", entry.system, entry.system_overridden),
          message_block("user", entry.prompt, false),
          el(
            "div",
            "context-models",
            context.models.map(fn(model) {
              el("span", "context-model", [txt(model)])
            }),
          ),
        ])
      }),
    ),
  ])
}

///|
/// 只有一条 inline prompt 的运行：把它当成唯一的一条用例。
fn inline_case(context : RunContext) -> Array[ContextCase] {
  let fields = as_object(context.request)
  let prompt = string_field(fields, "prompt", "")
  if prompt == "" {
    return []
  }
  let system = string_field(fields, "system", "")
  [
    {
      id: "inline prompt",
      prompt,
      system,
      system_overridden: false,
      max_tokens: int_field(fields, "maxTokens", 0),
      temperature: match fields.get("temperature") {
        Some(Number(value, ..)) => Some(value)
        _ => None
      },
    },
  ]
}

///|
fn temperature_text(value : Double?) -> String {
  match value {
    None => "未设置（用服务端默认）"
    Some(value) => fmt_number(value)
  }
}

///|
fn message_block(role : String, text : String, overridden : Bool) -> @html.Html {
  el("div", "context-message", [
    el("div", "context-role", [
      txt(role),
      if overridden {
        el("span", "context-tag", [txt("用例级覆盖")])
      } else {
        @html.fragment([])
      },
    ]),
    @html.pre([txt(if text == "" { "（没有）" } else { text })]),
  ])
}

///|
/// 运行级参数：这些是每条用例共用的底子。
fn context_params(context : RunContext) -> @html.Html {
  let request = context.request
  let fields = as_object(request)
  let rows : Array[(String, String)] = [
    ("模型", context.models.join(", ")),
    (
      "system（全局）",
      {
        let system = string_field(fields, "system", "")
        if system == "" {
          "（没有）"
        } else {
          system
        }
      },
    ),
    (
      "测试集",
      {
        let name = string_field(fields, "caseSet", "")
        if name == "" {
          "（inline prompt）"
        } else {
          name
        }
      },
    ),
    ("重复次数", int_field(fields, "repeats", 0).to_string()),
    ("max tokens", int_field(fields, "maxTokens", 0).to_string()),
    (
      "temperature",
      match fields.get("temperature") {
        Some(Number(value, ..)) => fmt_number(value)
        _ => "未设置"
      },
    ),
    ("间隔 ms", int_field(fields, "paceMs", 0).to_string()),
    ("重试次数", int_field(fields, "retry", 0).to_string()),
    (
      "网关",
      {
        let url = string_field(fields, "baseUrl", "")
        if url == "" {
          "服务端配置"
        } else {
          url
        }
      },
    ),
  ]
  el(
    "dl",
    "context-params",
    rows.map(fn(row) {
      let (label, value) = row
      @html.fragment([@html.dt([txt(label)]), @html.dd([txt(value)])])
    }),
  )
}

///|
/// The "what is happening right now" line of a running benchmark.
///
/// A suite of 66 cases takes minutes, and one stderr line per finished case
/// leaves the card looking dead for seconds at a time — which is exactly the
/// part a person stares at. This is the piece that moves: which model, which
/// case, whether it is still thinking, how fast, and how long since anything
/// came out of the gateway.
pub fn live_row(live : LiveProgress?) -> @html.Html {
  let live = match live {
    // 运行刚开始、第一个 tick 还没到：给一行空占位，别让卡片先矮一截再长回来
    None =>
      {
        event: "waiting",
        model: "",
        case_id: "",
        repeat: 0,
        phase: "",
        tok_per_s: 0.0,
        chars: 0,
        tokens: 0,
        elapsed_ms: 0.0,
        max_tokens: 0,
        index: 0,
        total: 0,
        age_ms: 0.0,
      }
    Some(live) => live
  }
  // 上一条已经返回、而它又不新鲜了：现在没有请求在飞（用例之间的间隔）。
  // 这时候不能整行收起来——下面的失败计数和日志尾会顶上来，下一条开始时又弹
  // 回去。改成进入「等待」状态：位置还在，只是不再有数字和动画
  let stalled = live.age_ms > 2000.0
  let waiting = live.event == "waiting" ||
    (live.event == "case_done" && live.age_ms > 1500.0)
  let quiet = stalled || waiting
  let who = if waiting {
    "下一条请求"
  } else if live.case_id == "" {
    "准备中"
  } else {
    "\{live.model} · \{live.case_id} #\{live.repeat + 1}"
  }
  let state = if waiting {
    "等待下一条"
  } else if live.event == "case_start" {
    "等首 token"
  } else if live.event == "case_done" {
    if live.age_ms > 3000.0 {
      ""
    } else {
      "刚返回"
    }
  } else if live.phase == "reasoning" {
    "思考中"
  } else {
    "生成中"
  }
  let clock = if waiting || live.event == "case_start" {
    ""
  } else {
    " \{fmt_number(live.elapsed_ms / 1000.0)}s"
  }
  // 空的时候不留空节点、也不隐藏：一律渲染，内容用占位。隐藏元素会让后面的
  // 元素顶上来，数字一变就来回跳——这跟「数字宽度在变」是同一类闪动
  let numbers = if waiting || live.chars == 0 {
    "0 字符"
  } else {
    "\{live.chars} 字符"
  }
  let rate = if waiting || live.tok_per_s < 0.5 {
    "≈—  tok/s"
  } else {
    "≈\{fmt_number(live.tok_per_s)} tok/s"
  }
  // 两行：上面是「在跑什么、什么状态」，下面是数字、进度与那句「多久没输出了」。
  // 挤在一行时最先被挤走的就是最后那句——它一出现就换行，整块长高又缩回去，
  // 就是之前那种闪烁。两行之后每一格都有固定位置，谁也不挤谁
  el("div", if quiet { "live-row stalled" } else { "live-row" }, [
    el("span", "pulse", []),
    el("span", "live-who", [txt(who)]),
    el("span", "live-state", [
      txt(if state == "" { "—" } else { state + clock }),
    ]),
    el("span", "live-nums", [txt(numbers)]),
    el("span", "live-rate", [txt(rate)]),
    live_bar(live, quiet),
    el("span", "live-extra", [
      txt(
        if stalled {
          "\{fmt_number(live.age_ms / 1000.0)}s 没有新输出"
        } else {
          ""
        },
      ),
    ]),
  ])
}

///|
/// 当前这条请求的 token 进度。
///
/// 分母是 `max_tokens`——那是**上限**不是目标，模型随时可能提前收尾，所以这条
/// 只能当参考看，标签上写 `≤`。它动的速度是真正的分片速度，页面上最活跃的
/// 就是它。
fn live_bar(live : LiveProgress, quiet : Bool) -> @html.Html {
  // 上限未知（等待、或刚启动）时也要给一条空条：这一格塌了整行就会跳
  if live.max_tokens <= 0 {
    return el("span", "live-bar", [el("span", "live-bar-fill", [])])
  }
  // 等待 / 停滞时把条清空：停在上一条的进度上会像是「卡在那儿了」
  let share = if quiet {
    0.0
  } else {
    live.tokens.to_double() / live.max_tokens.to_double()
  }
  let percent = if share > 1.0 { 100 } else { (share * 100.0).to_int() }
  // 分母是上限不是目标，所以宽度经常几乎为零（9 个 token 的短回答 vs 1024 的上限）。
  // 光靠宽度会像是坏掉了，于是里面再叠一层流动纹样：有分片在进来它就在动，
  // 停了它就停——「有没有数据在流」这件事不需要知道答案有多长。
  el("span", "live-bar", [
    @html.node(
      "span",
      @html.Attrs::build().class("live-bar-fill").style("width", "\{percent}%"),
      ([] : Array[@html.Html]),
    ),
    @html.node(
      "span",
      @html.Attrs::build().class("live-bar-flow"),
      ([] : Array[@html.Html]),
    ),
  ])
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
    @html.pre([txt(display_text(answer.reasoning))]),
  ])
}

///|
/// 结果区整体（卡片 + 对比 + 用例），供两个前端共用。
pub fn results_section(
  data : PageData,
  mode? : String = "stacked",
  switch? : @html.Html,
  which? : String = "p50",
  percentile_switch? : @html.Html,
  editor? : (String, String) -> @html.Html,
  context? : (String) -> @html.Html,
) -> @html.Html {
  // 名字对不上的可选参数只能自己拆开：`switch=<别的名字>?` 会把 Option 本身
  // 当成值传下去，而这里要的是「没有就不渲染任何东西」。
  let for_comparison = match percentile_switch {
    Some(control) => control
    None => @html.fragment([])
  }
  @html.fragment([
    model_cards(data),
    comparison(data, which~, switch=for_comparison),
    answers(data, mode~, switch?, editor?, context?),
  ])
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
