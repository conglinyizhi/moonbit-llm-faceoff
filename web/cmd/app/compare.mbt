///|
/// 两次运行的对比：参数差异、指标差值、逐用例答案并排。
///
/// 为什么单独一块界面而不是「看两次再自己比」：调参之后最常问的一句话是
/// 「比上次好了还是差了」，而这句话要三样东西才能回答——参数到底改了什么、
/// 中位数往哪边动了、同一道题的答案和思考变没变。分开看就只能靠记忆。

///|
/// 正在对比的两次运行。
struct CompareState {
  a : String
  b : String
  data_a : @shared.PageData?
  data_b : @shared.PageData?
  request_a : Json
  request_b : Json
  error : String?
} derive(Eq)

///|
/// 历史条目上那个「对比」勾选框最多选两个。选第三个时挤掉最早选的那个：
/// 比「默默忽略你这次点击」好。
let max_compare_picks : Int = 2

///|
fn toggle_pick(picks : Array[String], id : String) -> Array[String] {
  if picks.contains(id) {
    return picks.filter(fn(item) { item != id })
  }
  let next = picks.copy()
  if next.length() >= max_compare_picks {
    let trimmed = next[1:].to_owned()
    trimmed.push(id)
    trimmed
  } else {
    next.push(id)
    next
  }
}

// ---------------------------------------------------------------- 参数差异

///|
/// 会被拿出来比一比的请求字段。顺序就是展示顺序。
let compared_params : Array[(String, String)] = [
  ("models", "模型"),
  ("caseSet", "用例集"),
  ("cases", "用例"),
  ("prompt", "一次性指令"),
  ("repeats", "重复次数"),
  ("maxTokens", "max_tokens"),
  ("temperature", "temperature"),
  ("paceMs", "间隔"),
  ("retry", "重试次数"),
]

///|
/// 请求里的一个字段，渲染成一行字。缺失和空数组都算「—」：对比表上
/// 「这边没写」和「这边写了空」是同一件事。
fn brief(json : Json) -> String {
  match json {
    Null => "—"
    True => "true"
    False => "false"
    String(text) => if text == "" { "—" } else { text }
    Number(value, ..) =>
      if value == value.round() {
        value.to_int().to_string()
      } else {
        value.to_string()
      }
    Array(items) =>
      if items.length() == 0 {
        "—"
      } else {
        items.map(brief).join(", ")
      }
    Object(_) => "(对象)"
  }
}

///|
fn param_of(request : Json, key : String) -> String {
  brief(
    match @shared.as_object(request).get(key) {
      Some(value) => value
      None => Json::null()
    },
  )
}

///|
/// 两次请求不一样的地方。全都一样就明说「只是重跑」——那也是一种结论。
fn param_diff_rows(state : CompareState) -> Array[(String, String, String)] {
  let rows : Array[(String, String, String)] = []
  for entry in compared_params {
    let (key, label) = entry
    let left = param_of(state.request_a, key)
    let right = param_of(state.request_b, key)
    if left != right {
      rows.push((label, left, right))
    }
  }
  rows
}

///|
fn param_diff(state : CompareState) -> @html.Html {
  let rows = param_diff_rows(state)
  if rows.length() == 0 {
    return el("p", "muted", [
      txt(
        "两次的参数完全一样（就是把同一件事又跑了一遍）。",
      ),
    ])
  }
  el(
    "div",
    "diff-table",
    [
      el("div", "diff-row diff-head", [
        el("span", "", [txt("参数")]),
        el("span", "", [txt(state.a)]),
        el("span", "", [txt(state.b)]),
      ]),
      ..rows.map(fn(row) {
        let (label, left, right) = row
        el("div", "diff-row", [
          el("span", "diff-label", [txt(label)]),
          el("span", "diff-old", [txt(left)]),
          el("span", "diff-new", [txt(right)]),
        ])
      }),
    ],
  )
}

// ---------------------------------------------------------------- 指标差值

///|
/// 两次运行里出现过的所有模型，A 的先、B 的补在后面。
fn models_of(data : @shared.PageData?) -> Array[String] {
  match data {
    None => []
    Some(data) => data.models
  }
}

///|
fn union_models(a : @shared.PageData?, b : @shared.PageData?) -> Array[String] {
  let out = models_of(a)
  for model in models_of(b) {
    if !out.contains(model) {
      out.push(model)
    }
  }
  out
}

///|
fn summary_of(
  data : @shared.PageData?,
  model : String,
) -> @shared.ModelSummary? {
  match data {
    None => None
    Some(data) =>
      match data.summaries.filter(fn(item) { item.model == model }) {
        [first, ..] => Some(first)
        [] => None
      }
  }
}

///|
/// 相对变化。A 是 0 或者缺失就报「—」：0.0 当分母的百分比没有意义。
fn delta_text(left : Double?, right : Double?) -> String {
  match (left, right) {
    (Some(before), Some(after)) =>
      if before == 0.0 {
        if after == 0.0 {
          "±0%"
        } else {
          "—"
        }
      } else {
        let percent = (after - before) / before * 100.0
        let rounded = (percent * 10.0).round() / 10.0
        if rounded > 0.0 {
          "+" + rounded.to_string() + "%"
        } else {
          rounded.to_string() + "%"
        }
      }
    _ => "—"
  }
}

///|
/// 一个模型的指标差值表。更快/更慢用颜色标一下——但只标方向，不下结论：
/// 快 3% 在两三个样本上什么也说明不了。
fn metric_diff(model : String, state : CompareState) -> @html.Html {
  let left = summary_of(state.data_a, model)
  let right = summary_of(state.data_b, model)
  let rows = @shared.metric_rows().map(fn(row) {
    let (label, key, unit) = row
    let before = match left {
      Some(summary) => summary.metric(key)
      None => None
    }
    let after = match right {
      Some(summary) => summary.metric(key)
      None => None
    }
    let delta = delta_text(before, after)
    // 不给 Δ 上颜色：同号的 Δ 在不同指标上好坏相反（首 token 变长是坏，
    // decode tok/s 变快是好），而这里手上没有每个指标的方向。
    // 红/绿一旦上色就是在下结论，而这层界面只能把数摆出来。
    el("div", "diff-row", [
      el("span", "diff-label", [txt(label)]),
      el("span", "", [txt(@shared.format_value(before, unit))]),
      el("span", "", [txt(@shared.format_value(after, unit))]),
      el("span", "diff-delta", [txt(delta)]),
    ])
  })
  let note = if left is None || right is None {
    [
      el("p", "muted", [
        txt("这个模型只在其中一次里跑过，差值没有意义。"),
      ]),
    ]
  } else {
    []
  }
  el(
    "div",
    "metric-block",
    [
      el("h3", "", [txt(model)]),
      ..note,
      el(
        "div",
        "diff-table",
        [
          el("div", "diff-row diff-head", [
            el("span", "", [txt("指标（中位数）")]),
            el("span", "", [txt(state.a)]),
            el("span", "", [txt(state.b)]),
            el("span", "", [txt("Δ")]),
          ]),
          ..rows,
        ],
      ),
    ],
  )
}

// ---------------------------------------------------------------- 逐用例

///|
fn case_of(data : @shared.PageData?, id : String) -> @shared.CaseBlock? {
  match data {
    None => None
    Some(data) =>
      match data.cases.filter(fn(block) { block.id == id }) {
        [first, ..] => Some(first)
        [] => None
      }
  }
}

///|
fn case_ids_union(
  a : @shared.PageData?,
  b : @shared.PageData?,
) -> Array[String] {
  let out : Array[String] = []
  for data in [a, b] {
    match data {
      None => ()
      Some(data) =>
        for block in data.cases {
          if !out.contains(block.id) {
            out.push(block.id)
          }
        }
    }
  }
  out
}

///|
/// 一列答案：某次运行在某道题上的全部模型输出。
fn answer_column(
  title : String,
  case_id : String,
  block : @shared.CaseBlock?,
) -> @html.Html {
  let body = match block {
    None => [el("p", "muted", [txt("这次没有这道题")])]
    Some(block) =>
      if block.answers.length() == 0 {
        [el("p", "muted", [txt("没有答案")])]
      } else {
        block.answers.map(fn(answer) { @shared.answer_block(case_id, answer) })
      }
  }
  el("div", "compare-col", [el("div", "compare-col-head", [txt(title)])] + body)
}

///|
fn cases_compare(state : CompareState) -> @html.Html {
  let ids = case_ids_union(state.data_a, state.data_b)
  if ids.length() == 0 {
    return el("p", "muted", [txt("两次都没有可比的用例输出。")])
  }
  el(
    "div",
    "compare-cases",
    ids.map(fn(id) {
      el("article", "compare-case", [
        el("h3", "", [txt(id)]),
        el("div", "compare-cols", [
          answer_column(state.a, id, case_of(state.data_a, id)),
          answer_column(state.b, id, case_of(state.data_b, id)),
        ]),
      ])
    }),
  )
}

// ---------------------------------------------------------------- 整体

///|
fn compare_view(state : CompareState, emit : @cmd.Emit[Msg]) -> @html.Html {
  let head = el("div", "viewed-banner", [
    el("span", "", [txt("\{state.a} ↔ \{state.b}")]),
    @html.button(class="link-btn", on_click=emit(Msg::CloseCompare), [
      txt("退出对比"),
    ]),
  ])
  let body = match state.error {
    Some(message) => [el("p", "failed", [txt(message)])]
    None =>
      match (state.data_a, state.data_b) {
        (Some(_), Some(_)) =>
          [
            el("section", "compare-block", [
              el("h2", "", [txt("参数差异")]),
              param_diff(state),
            ]),
            el(
              "section",
              "compare-block",
              [
                el("h2", "", [txt("指标差值")]),
                ..union_models(state.data_a, state.data_b).map(fn(model) {
                  metric_diff(model, state)
                }),
              ],
            ),
            el("section", "compare-block", [
              el("h2", "", [txt("逐用例答案")]),
              cases_compare(state),
            ]),
          ]
        _ => [el("p", "muted", [txt("正在载入两次运行的数据…")])]
      }
  }
  el("div", "compare", [head] + body)
}

///|
/// 拉一次历史运行的数据来对比（和「打开」用的是同一个接口，
/// 只是结果填到对比的那一格）。
fn fetch_compare_run(id : String, emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @http.get("/api/runs/" + id).expect_json(
    emit.map(fn(result) { CompareRunLoaded(id, result) }),
  )
}
