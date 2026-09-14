///|
/// 运行历史这一块：类型、命令、渲染。
///
/// 和 main.mbt 同包（一个目录一个包），共用那套 `el` / `txt`。
/// 分出来的理由和 server 那边一样：main.mbt 已经不短了，而历史面板和表单
/// 没有关系，只是并排放在同一页上。

///|
/// 历史里的一次运行，对应 `GET /api/runs` 的一条。
///
/// `request` 原样留着磁盘上那份 `request.json`：重跑要的是「当时那些参数」，
/// 不是「现在表单里那些」。里面各字段用 `@shared` 那套 reader 手动取——历史
/// 记录来自磁盘，缺字段是常态（老的没有 temperature，新的才有 caseSet），
/// 而派生解码遇到缺字段会整条报错。
struct RunInfo {
  id : String
  startedAt : Double
  status : String
  exitCode : String
  request : Json
  total : Int
  done : Int
  failures : Int
  retried : Int
  truncated : Int
} derive(Eq, FromJson)

///|
struct RunsResponse {
  runs : Array[RunInfo]
} derive(FromJson)

///|
/// 正在看的那次历史运行。
///
/// 和「当前这次运行」分开两块状态：历史是只读的，重跑会另起一次新运行；
/// 混在一起就会出现「跑着跑着结果被历史的覆盖掉」。
struct ViewedRun {
  id : String
  status : String
  data : @shared.PageData?
  error : String?
  tail : String
  /// 打开的那次运行如果还在跑，这里就有实时进度；跑完的历史运行没有。
  live : @shared.LiveProgress?
} derive(Eq)

// ---------------------------------------------------------------- 读字段

///|
fn request_obj(info : RunInfo) -> Map[String, Json] {
  @shared.as_object(info.request)
}

///|
fn request_strings(info : RunInfo, key : String) -> Array[String] {
  @shared.array_field(request_obj(info), key).map(fn(item) {
    match item {
      String(text) => text
      _ => ""
    }
  })
}

///|
fn request_string(info : RunInfo, key : String) -> String? {
  let text = @shared.string_field(request_obj(info), key, "")
  if text == "" {
    None
  } else {
    Some(text)
  }
}

///|
fn request_int(info : RunInfo, key : String, fallback : Int) -> Int {
  @shared.int_field(request_obj(info), key, fallback)
}

///|
fn request_bool(info : RunInfo, key : String, fallback : Bool) -> Bool {
  @shared.bool_field(request_obj(info), key, fallback)
}

///|
fn request_number(info : RunInfo, key : String, fallback : Double) -> Double {
  @shared.number_field(request_obj(info), key, fallback)
}

// ---------------------------------------------------------------- 显示

///|
/// epoch 秒 → 本地时间。日期换算是浏览器的事：在 MoonBit 里手写一遍时区与
/// 闰年只会多一处会错的地方。
extern "js" fn format_time(seconds : Double) -> String = "(s) => { if (!s) return '—'; const d = new Date(s * 1000); const p = (n) => String(n).padStart(2, '0'); return `${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}` }"

///|
fn RunInfo::case_count(self : RunInfo) -> Int {
  if request_string(self, "prompt") is Some(_) {
    return 1
  }
  // 内联用例的运行把 prompt 写在请求里，没有 cases 字段
  let inline_cases = @shared.array_field(request_obj(self), "inlineCases")
  if inline_cases.length() > 0 {
    return inline_cases.length()
  }
  request_strings(self, "cases").length()
}

///|
fn RunInfo::summary(self : RunInfo) -> String {
  let model_count = request_strings(self, "models").length()
  let case_count = self.case_count()
  let repeats = request_int(self, "repeats", 1)
  let scale = "\{model_count} 模型 × \{case_count} 用例 × \{repeats} 次"
  match request_string(self, "caseSet") {
    Some(name) => scale + "  ·  " + name
    None => scale
  }
}

///|
fn RunInfo::models_label(self : RunInfo) -> String {
  let models = request_strings(self, "models")
  match models {
    [] => "（没有模型）"
    [only] => only
    [first, second] => first + ", " + second
    [first, ..] => first + " 等 \{models.length()} 个"
  }
}

///|
fn RunInfo::status_label(self : RunInfo) -> String {
  match self.status {
    "ok" => "完成"
    "failed" => "失败"
    _ => "运行中"
  }
}

///|
fn status_class(status : String) -> String {
  match status {
    "ok" | "done" => "badge-ok"
    "failed" => "badge-bad"
    _ => "badge-warn"
  }
}

// ---------------------------------------------------------------- 命令

///|
fn fetch_runs(emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @http.get("/api/runs").expect_json(
    emit.map(fn(result) { RunsLoaded(result) }),
  )
}

///|
fn fetch_viewed(id : String, emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @http.get("/api/runs/" + id).expect_json(
    emit.map(fn(result) { ViewedLoaded(id, result) }),
  )
}

///|
fn delete_run_cmd(id : String, emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @http.delete("/api/runs/" + id).expect_json(
    emit.map(fn(result) { RunDeleted(id, result) }),
  )
}

///|
/// 用历史里那份 request 重跑一次。
///
/// 网关地址照用历史里的那份（那才是当时跑的那个），密钥用页面上当前的——
/// 密钥从来就不在 request.json 里，这是有意的。
fn rerun_payload(model : AppModel, info : RunInfo) -> RunPayload {
  {
    models: request_strings(info, "models"),
    cases: request_strings(info, "cases"),
    prompt: match request_string(info, "prompt") {
      Some(prompt) => prompt
      None => ""
    },
    caseSet: request_string(info, "caseSet"),
    // 重跑要重放的是「当时问的那一套」，system 也算：用页面上当前的会把
    // 一次运行悄悄变成另一次
    system: request_string(info, "system"),
    // 重跑也要重放「当时那条 system 是怎么生效的」：
    // 不带上，一次勾了覆盖的运行重跑后会变成用例级优先
    systemOverride: request_bool(info, "systemOverride", false),
    // 推理开关也要重放，否则重跑出来的参数和当时不是一回事
    cotThinking: request_strings(info, "cotThinking"),
    cotEffort: request_strings(info, "cotEffort"),
    // 运行方式也重放：勾过并行的运行重跑时不该悄悄变回串行
    parallel: request_string(info, "parallel").unwrap_or("serial"),
    repeats: request_int(info, "repeats", 1),
    maxTokens: request_int(info, "maxTokens", 1024),
    temperature: request_number(info, "temperature", 0.0),
    paceMs: request_int(info, "paceMs", 0),
    retry: request_int(info, "retry", 1),
    baseUrl: request_string(info, "baseUrl"),
    apiKey: if model.api_key == "" {
      None
    } else {
      Some(model.api_key)
    },
  }
}

// ---------------------------------------------------------------- 渲染

///|
/// 左侧的历史面板。放在表单旁边而不是折叠起来：管理测试的时候，
/// 「之前跑过什么」和「这次要跑什么」是同一个视线里的两件事。
fn history_panel(
  model : AppModel,
  emit : @cmd.Emit[Msg],
) -> @html.Html {
  let body = match model.runs {
    None => [el("p", "muted", [txt("正在载入…")])]
    Some(runs) =>
      if runs.length() == 0 {
        [
          el("p", "muted", [
            txt("还没有运行记录。跑一次就会出现在这里"),
          ]),
        ]
      } else {
        // 侧栏只铺前 10 条：它不是主角，全铺出来会把整页推得很长
        let items : Array[@html.Html] = []
        let limit = if runs.length() < history_panel_limit {
          runs.length()
        } else {
          history_panel_limit
        }
        for i = 0; i < limit; i = i + 1 {
          items.push(run_item(model, runs[i], emit))
        }
        if runs.length() > limit {
          items.push(
            // 「查看更多」本身就是一张卡片，和上面的记录长在一起
            el("article", "history-item history-more", [
              el("div", "history-more-line", [
                txt("还有 \{runs.length() - limit} 次没有显示"),
              ]),
              @html.button(class="link-btn", on_click=emit(Msg::OpenHistory), [
                txt("查看更多"),
              ]),
            ]),
          )
        }
        items
      }
  }
  let error = match model.runs_error {
    Some(message) => el("p", "failed", [txt(message)])
    None => txt("")
  }
  el("aside", "history", [
    el("div", "section-head", [
      el("h2", "", [txt("运行记录")]),
      // 勾满两个就把「刷新」换成「对比」——头部只有一格，而这两个动作
      // 不会同时被需要。
      if model.compare_picks.length() == max_compare_picks {
        @html.button(class="link-btn", on_click=emit(Msg::StartCompare), [
          txt("对比这两次"),
        ])
      } else {
        @html.button(class="link-btn", on_click=emit(Msg::RefreshRuns), [
          txt("刷新"),
        ])
      },
    ]),
    el("div", "history-list", body),
    error,
  ])
}

///|
fn run_item(
  model : AppModel,
  info : RunInfo,
  emit : @cmd.Emit[Msg],
) -> @html.Html {
  let active = match model.viewed {
    Some(viewed) => viewed.id == info.id
    None => false
  }
  let busy = model.busy_run == Some(info.id)
  let picked = model.compare_picks.contains(info.id)
  let classes = if active {
    "history-item active"
  } else if picked {
    "history-item picked"
  } else {
    "history-item"
  }
  let badges : Array[@html.Html] = [
    el("span", "badge " + status_class(info.status), [txt(info.status_label())]),
  ]
  if info.failures > 0 {
    badges.push(
      el("span", "badge badge-warn", [txt("失败 \{info.failures}")]),
    )
  }
  if info.truncated > 0 {
    badges.push(
      el("span", "badge badge-warn", [txt("截断 \{info.truncated}")]),
    )
  }
  if busy {
    badges.push(el("span", "badge", [txt("处理中…")]))
  }
  let running = info.status == "running"
  el("article", classes, [
    el("div", "history-row", [
      el("span", "history-time", [
        // 把内部 id 露出来：弹窗与侧栏的顺序要能对上，用户才能确认
        // 「我正在看的就是这一条」
        el("span", "run-id", [txt(info.id)]),
        txt(" " + format_time(info.startedAt)),
      ]),
      el("span", "badges", badges),
    ]),
    el("div", "history-models", [txt(info.models_label())]),
    el("div", "history-scale", [txt(info.summary())]),
    el("div", "history-actions", [
      @html.button(class="link-btn", on_click=emit(Msg::OpenRun(info.id)), [
        txt(
          if active {
            "正在看"
          } else if running {
            // 跑着的那条也能点回来：不然点了别的运行、或者刷新一下，就找不到它了
            "看进度"
          } else {
            "打开"
          },
        ),
      ]),
      @html.button(class="link-btn", on_click=emit(Msg::Rerun(info.id)), [
        txt("重跑"),
      ]),
      // 勾满两个之后头部会出现「对比这两次」
      @html.button(
        class="link-btn",
        on_click=emit(Msg::ToggleComparePick(info.id)),
        [txt(if picked { "✓对比" } else { "对比" })],
      ),
      if model.confirm_delete == Some(info.id) {
        // 第二次点击才真的删。删除是不可逆的，而这一列的按钮挨得很近
        @html.button(
          class="link-btn danger",
          on_click=emit(Msg::DeleteRun(info.id)),
          [txt("确认删除")],
        )
      } else {
        @html.button(
          class="link-btn danger",
          on_click=emit(Msg::DeleteRun(info.id)),
          [txt("删除")],
        )
      },
      if model.confirm_delete == Some(info.id) {
        @html.button(class="link-btn", on_click=emit(Msg::CancelDeleteRun), [
          txt("取消"),
        ])
      } else {
        @html.fragment([])
      },
    ]),
  ])
}

///|
/// 在看历史运行时，结果区顶上那条说明 + 回到当前运行的出口。
fn viewed_banner(viewed : ViewedRun, emit : @cmd.Emit[Msg]) -> @html.Html {
  el("div", "viewed-banner", [
    el("span", "", [txt("正在看历史运行 \{viewed.id}（只读）")]),
    @html.button(class="link-btn", on_click=emit(Msg::CloseRun), [
      txt("回到当前运行"),
    ]),
  ])
}

///|
/// 按 id 找一条历史记录。`Array::find` 在核心库里没有，而这里只需要它一次。
fn find_run(runs : Array[RunInfo]?, id : String) -> RunInfo? {
  match runs {
    None => None
    Some(runs) => {
      for info in runs {
        if info.id == id {
          return Some(info)
        }
      }
      None
    }
  }
}
