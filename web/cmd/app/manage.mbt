///|
/// 测试集与预设这两块的管理面：类型、命令、渲染。
///
/// 和 history.mbt 同一个理由分出来——main.mbt 是表单与结果，这两个是「我拿什么
/// 去测」和「我怎么老是重填同一组参数」，各自独立。

///|
/// 一次能有几条用例（导入、保存都按它卡）。和服务端的上限一致。
let max_cases_per_set : Int = 500

///|
/// 一条用例的编辑态。
///
/// `raw` 是原始对象，保存时把编辑框覆盖过的键合并回去：页面没展示的字段
/// （以后 bench 支持的、别人手写的）不会因为在页面上过了一遍就消失。
struct CaseDraft {
  raw : Json
  id : String
  prompt : String
  system : String
  max_tokens : String
  temperature : String
} derive(Eq)

///|
struct CaseSetResponse {
  name : String
  cases : Array[Json]
} derive(FromJson)

///|
/// 一组「模型 + 参数」。字段全可省：存的时候只写你填过的。
struct Preset {
  name : String
  models : Array[String]
  caseSet : String?
  /// 运行级 system prompt。老预设没有这个字段，读出来是 None——那种情况下
  /// 套用时保持页面上现有的值不动。
  system : String?
  repeats : Int?
  maxTokens : Int?
  temperature : Double?
  paceMs : Int?
  retry : Int?
} derive(Eq, FromJson, ToJson)

///|
struct PresetsResponse {
  presets : Array[Preset]
} derive(FromJson)

///|
/// derive(ToJson) 生成的方法在调用点会被隐式提升（已弃用），显式接一下，
/// 免得每次 `p.to_json()` 都跳一条警告。
pub extend Preset with ToJson::{to_json}

// ---------------------------------------------------------------- 草稿

///|
/// 把一条用例记录摊成可编辑的草稿。
fn CaseDraft::of(json : Json) -> CaseDraft {
  let obj = @shared.as_object(json)
  {
    raw: json,
    id: @shared.string_field(obj, "id", ""),
    prompt: @shared.string_field(obj, "prompt", ""),
    system: @shared.string_field(obj, "system", ""),
    max_tokens: number_text(obj, "max_tokens"),
    temperature: number_text(obj, "temperature"),
  }
}

///|
/// 数值字段的文本形态：缺失就是空串，空串表示「不写这个字段」。
fn number_text(obj : Map[String, Json], key : String) -> String {
  match obj.get(key) {
    Some(Number(value, ..)) =>
      // 整数不显示小数点：max_tokens 写成 512.0 会被当成另一个值
      if value == value.round() {
        value.to_int().to_string()
      } else {
        value.to_string()
      }
    _ => ""
  }
}

///|
/// 草稿 → 用例记录。空字段不写，其余键沿用 `raw`。
fn CaseDraft::to_json(self : CaseDraft) -> Json {
  let out : Map[String, Json] = Map([])
  @shared.as_object(self.raw).each(fn(key, value) {
    if !["id", "prompt", "system", "max_tokens", "temperature"].contains(key) {
      out[key] = value
    }
  })
  if self.id != "" {
    out["id"] = Json::string(self.id)
  }
  out["prompt"] = Json::string(self.prompt)
  if self.system != "" {
    out["system"] = Json::string(self.system)
  }
  if self.max_tokens != "" {
    let value = @string.parse_int(self.max_tokens) catch { _ => 0 }
    out["max_tokens"] = Json::number(value.to_double())
  }
  if self.temperature != "" {
    let value = @string.parse_double(self.temperature) catch { _ => 0.0 }
    out["temperature"] = Json::number(value)
  }
  Json::object(out)
}

///|
fn drafts_to_json(drafts : Array[CaseDraft]) -> Json {
  Json::object({
    "cases": Json::array(drafts.map(fn(draft) { draft.to_json() })),
  })
}

///|
/// 空草稿给「新增」用：id 让服务端补，prompt 得自己写。
fn blank_draft() -> CaseDraft {
  {
    raw: Json::object({}),
    id: "",
    prompt: "",
    system: "",
    max_tokens: "",
    temperature: "",
  }
}

///|
/// 保存前的本地检查。服务端还会再查一遍——这里只是为了不用往返一次就知道
/// 「第几条没写 prompt」。
fn validate_drafts(drafts : Array[CaseDraft]) -> String? {
  let seen : Array[String] = []
  for i = 0; i < drafts.length(); i = i + 1 {
    let draft = drafts[i]
    if draft.prompt.trim(chars=" \t\r\n") == "" {
      return Some("第 \{i + 1} 条没有 prompt")
    }
    if draft.id != "" {
      if seen.contains(draft.id) {
        return Some("id 重复：\{draft.id}")
      }
      seen.push(draft.id)
    }
    if draft.max_tokens != "" &&
      (@string.parse_int(draft.max_tokens) catch { _ => -1 }) < 1 {
      return Some("第 \{i + 1} 条的 max_tokens 不是正整数")
    }
    if draft.temperature != "" &&
      (@string.parse_double(draft.temperature) catch { _ => -1.0 }) < 0.0 {
      return Some("第 \{i + 1} 条的 temperature 不是非负数")
    }
  }
  None
}

// ---------------------------------------------------------------- 命令

///|
/// 让服务端从一个纯文本文件建测试集。
///
/// 走服务端读文件而不是浏览器选文件：这个服务端就跑在你自己的机器上，路径也是
/// 你自己填的；而浏览器读本地文件要先把内容读进页面、再 POST 传回来——多一道
/// 没有意义的搬运。文件里一行一条 prompt，空行与 `#` 开头跳过；JSONL 用例文件
/// 也能直接吃。
/// 把浏览器里选中的文件内容送到服务端建集。
///
/// 发的是 text 而不是 path：文件在用户机器上，服务端拿不到那个路径
fn import_case_text(name : String, text : String, emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @http.post("/api/cases/" + name + "/import")
  .with_json(Json::object({ "text": Json::string(text) }))
  .expect_json(emit.map(fn(result) { CaseFileImported(result) }))
}

///|
fn fetch_case_set(name : String, emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @http.get("/api/cases/" + name).expect_json(
    emit.map(fn(result) { CaseSetLoaded(name, result) }),
  )
}

///|
fn save_case_set(
  name : String,
  drafts : Array[CaseDraft],
  emit : @cmd.Emit[Msg],
) -> @cmd.Cmd {
  @http.put("/api/cases/" + name)
  .with_json(drafts_to_json(drafts))
  .expect_json(emit.map(fn(result) { CaseSetSaved(name, result) }))
}

///|
fn delete_case_set_cmd(name : String, emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @http.delete("/api/cases/" + name).expect_json(
    emit.map(fn(result) { CaseSetDeleted(name, result) }),
  )
}

///|
fn fetch_presets(emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @http.get("/api/presets").expect_json(
    emit.map(fn(result) { PresetsLoaded(result) }),
  )
}

///|
fn save_presets(presets : Array[Preset], emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @http.put("/api/presets")
  .with_json(
    Json::object({ "presets": Json::array(presets.map(fn(p) { p.to_json() })) }),
  )
  .expect_json(emit.map(fn(result) { PresetsSaved(result) }))
}

// ---------------------------------------------------------------- 渲染：测试集

///|
/// 「这次跑什么」：要么跑一套测试集，要么只跑一条临时提示词。
///
/// 两者做成同一个面板的两页，因为它们**互斥**——请求里只能二选一。以前是上下
/// 两个面板加一个「只用下面这一条指令」的勾选框：勾选框和输入框分开在屏幕两端，
/// 填了字却忘了勾，就会对着一整列结果发愣「我说的话怎么没生效」。
fn case_panel(
  meta : Meta,
  model : AppModel,
  emit : @cmd.Emit[Msg],
) -> @html.Html {
  let prompt_mode = model.uses_prompt()
  // 开在哪一页由用户说了算。之前这里被「prompt 有没有内容」强行决定，结果填了
  // 一条 prompt 之后就再也点不回测试集那一页——想改勾选都没法看。
  let tab = model.panel_tab
  let tab_button = fn(id : String, label : String) {
    @html.button(
      class=if tab == id { "view-btn active" } else { "view-btn" },
      on_click=emit(Msg::SetPanelTab(id)),
      [txt(label)],
    )
  }
  let head = el("div", "section-head", [
    el("h2", "", [txt("这次跑什么")]),
    el("span", "muted count-badge", [
      txt(
        if prompt_mode {
          "临时提示词 1 条"
        } else {
          "\{model.available_cases.length()} 条 · 已选 \{model.selected_cases.length()}"
        },
      ),
    ]),
    if tab == "set" {
      @html.button(class="link-btn", on_click=emit(Msg::ToggleCaseEditor), [
        txt(if model.editing_cases { "收起编辑" } else { "编辑用例" }),
      ])
    } else {
      @html.fragment([])
    },
  ])
  let tabs = el("div", "panel-tabs", [
    tab_button("set", "测试集"),
    tab_button("prompt", "临时提示词"),
  ])
  let body = if tab == "prompt" {
    prompt_tab(model, emit)
  } else {
    el("div", "", [
      set_row(meta, model, emit),
      if model.editing_cases {
        editor_view(model, emit)
      } else {
        browse_view(model, emit)
      },
      import_row(model, emit),
    ])
  }
  el("section", "case-panel core", [
    head,
    tabs,
    body,
    // 在测试集这一页也把后果说清楚：填了 prompt 就等于不看勾选
    if tab == "set" && prompt_mode {
      el("p", "notice", [
        txt(
          "下面那条临时提示词里有内容，所以这次只跑它，测试集不参与。清空它才会回到跑测试集",
        ),
      ])
    } else {
      @html.fragment([])
    },
    match model.cases_error {
      Some(message) => el("p", "failed", [txt(message)])
      None => txt("")
    },
  ])
}

///|
/// 临时提示词那一页：一条 user prompt，填了就算启用。
fn prompt_tab(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  // 「填了」指框里有字，不是指切到了这一页：空着就会去跑选中的测试集
  let filled = model.prompt.trim(chars=" \t\r\n") != ""
  el("div", "prompt-tab", [
    @html.textarea(
      class="prompt-input",
      id="prompt",
      value=model.prompt,
      rows=4,
      placeholder="例如：把下面这段口语文本整理成书面表达",
      on_input=emit.map(fn(text) { PromptChanged(text) }),
      ([] : Array[@html.Html]),
    ),
    // 只用一个类（.hint）：以前在 .hint / .notice 之间切类名，两边边距不同，块会跟着
    // 跳。空着时那段话上黄：它是「什么都不填就会去跑测试集」的提醒
    el("p", "hint", [
      if filled {
        txt("已经填写内容，测试集选项将被忽略；测试中将会发起这一条消息作为 Prompt 的请求")
      } else {
        el("span", "hint-warn", [
          txt(
            "当前文本框为空，将会运行选中的测试集；填写内容后会将这里的文本视为完整的一条 Prompt 发起测试",
          ),
        ])
      },
    ]),
  ])
}

///|
/// 从纯文本文件建测试集：一行一条 prompt。服务端读这个路径（它就在你机器上）。
fn import_row(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  el("div", "import-row", [
    @html.button(class="link-btn", on_click=emit(Msg::PickImportFile), [
      txt("从文本文件生成新测试集"),
    ]),
    el("span", "hint", [
      txt("选一个文本文件就行，一行一条 prompt，空行与 # 跳过；集名默认取文件名"),
    ]),
    // JS 读完文件后的着陆点：它把 {"name", "text"} 写进来再派发 input，
    // 这边当普通输入事件接住。平时它是隐藏的，用户看不到也不碰
    @html.textarea(
      class="import-bridge",
      id="import-bridge",
      value=model.import_payload,
      rows=1,
      on_input=emit.map(fn(text) { ImportFilePicked(text) }),
      ([] : Array[@html.Html]),
    ),
  ])
}

///|
/// 测试集选择行：下拉 + 新建 + 删除。
fn set_row(meta : Meta, model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  let options = meta.caseSets.map(fn(set) {
    @html.option(value=set.name, selected=set.name == model.case_set, [
      txt("\{set.name}（\{set.count}）"),
    ])
  })
  let options = if options.length() > 0 {
    options
  } else {
    [@html.option(value="", selected=true, [txt("（还没有测试集）")])]
  }
  el("div", "set-row", [
    @html.select(
      class="set-select",
      // 「开始前确认」那一行的「调整」要定位到这里
      id="case-set",
      on_change=emit.map(fn(name) { SelectCaseSet(name) }),
      options,
    ),
    @html.input(
      input_type=@html.InputType::Text,
      class="set-name",
      id="new-set-name",
      value=model.new_set_name,
      placeholder="新集名字",
      on_input=emit.map(fn(text) { NewSetNameChanged(text) }),
    ),
    @html.button(class="ghost", on_click=emit(Msg::NewCaseSet), [
      txt("另存为新集"),
    ]),
    @html.button(class="link-btn danger", on_click=emit(Msg::DeleteCaseSet), [
      txt("删除这套"),
    ]),
  ])
}

///|
/// 浏览态：勾选用例。跑一次要选的就是这里。
fn browse_view(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  if model.available_cases.length() == 0 {
    return el("p", "muted", [
      txt("这套里还没有用例。点「编辑用例」加几条"),
    ])
  }
  let boxes = model.available_cases.map(fn(case) {
    labelled_checkbox(
      "case-" + case.id,
      case.id,
      model.selected_cases.contains(case.id),
      emit.map(fn(_value) { ToggleCase(case.id) }),
    )
  })
  // 条数一多，这块就是整页最吵的地方。默认只露两行，其余收起来——
  // 勾选本身不受影响（收起来的框还在 DOM 里，全选/全不选也照旧按全集算）。
  let collapsible = model.available_cases.length() > 8
  let collapsed = collapsible && !model.cases_expanded
  let list_class = if collapsed { "picker-items collapsed" } else { "picker-items" }
  let more = if collapsible {
    el("div", "picker-more", [
      @html.button(class="link-btn", on_click=emit(Msg::ToggleCaseList), [
        txt(
          if model.cases_expanded {
            "收起"
          } else {
            "展开全部（\{model.available_cases.length()} 条）"
          },
        ),
      ]),
    ])
  } else {
    @html.fragment([])
  }
  el("div", "", [
    el(
      "div",
      list_class,
      [
        el("div", "picker-all", [
          @html.button(class="link-btn", on_click=emit(Msg::SelectAllCases), [
            txt("全选"),
          ]),
          @html.button(class="link-btn", on_click=emit(Msg::SelectNoCases), [
            txt("全不选"),
          ]),
        ]),
        ..boxes,
      ],
    ),
    more,
  ])
}

///|
/// 按行导入：一行一条用例。给「手上已经有一堆 prompt」的人一个入口——
/// 在页面上一条条手敲是最不必要的劳动。
fn import_box(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  el("div", "import-box", [
    @html.textarea(
      class="prompt-input",
      id="import-lines",
      value=model.import_text,
      rows=4,
      on_input=emit.map(fn(text) { ImportTextChanged(text) }),
      ([] : Array[@html.Html]),
    ),
    el("div", "editor-actions", [
      @html.button(class="ghost", on_click=emit(Msg::ImportLines(false)), [
        txt("追加导入"),
      ]),
      @html.button(class="ghost", on_click=emit(Msg::ImportLines(true)), [
        txt("替换为这些行"),
      ]),
      el("span", "hint", [
        txt(
          "一行一条；空行与 # 开头的行跳过，追加到当前用例后面",
        ),
      ]),
      match model.import_note {
        Some(note) => el("span", "hint copied", [txt(note)])
        None => @html.fragment([])
      },
    ]),
  ])
}

///|
/// 把多行文本变成用例草稿：去空白、丢空行与 `#` 注释行，最多留 `limit` 条。
/// 返回 (草稿, 因为超限被丢掉的条数)。
fn drafts_from_lines(text : String, limit : Int) -> (Array[CaseDraft], Int) {
  let out : Array[CaseDraft] = []
  let mut skipped = 0
  for raw in text.split("\n") {
    let line = raw.trim(chars=" \t\r").to_owned()
    if line == "" || line.has_prefix("#") {
      continue
    }
    if out.length() >= limit {
      skipped = skipped + 1
      continue
    }
    out.push({
      raw: Json::object({}),
      id: "",
      prompt: line,
      system: "",
      max_tokens: "",
      temperature: "",
    })
  }
  (out, skipped)
}

///|
/// 编辑态：每条一行，prompt 是主输入，其余字段收在「更多」里。
fn editor_view(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  let rows = []
  for i = 0; i < model.drafts.length(); i = i + 1 {
    rows.push(draft_row(i, model.drafts[i], emit))
  }
  el(
    "div",
    "case-editor",
    [
      ..rows,
      el("div", "editor-actions", [
        @html.button(class="ghost", on_click=emit(Msg::AddDraft), [
          txt("＋ 新增一条"),
        ]),
        @html.button(class="primary", on_click=emit(Msg::SaveCases), [
          txt("保存测试集"),
        ]),
        match model.cases_saved {
          Some(message) => el("span", "hint copied", [txt(message)])
          None => txt("")
        },
      ]),
      import_box(model, emit),
    ],
  )
}

///|
fn draft_row(
  index : Int,
  draft : CaseDraft,
  emit : @cmd.Emit[Msg],
) -> @html.Html {
  let more = el("details", "draft-more", [
    el("summary", "", [txt("更多字段")]),
    el("div", "draft-extra", [
      text_input(
        "draft-system-" + index.to_string(),
        draft.system,
        "system（留空 = 用默认）",
        emit.map(fn(text) { DraftFieldChanged(index, DraftField::System, text) }),
      ),
      text_input(
        "draft-max-" + index.to_string(),
        draft.max_tokens,
        "max_tokens",
        emit.map(fn(text) {
          DraftFieldChanged(index, DraftField::MaxTokens, text)
        }),
      ),
      text_input(
        "draft-temp-" + index.to_string(),
        draft.temperature,
        "temperature",
        emit.map(fn(text) {
          DraftFieldChanged(index, DraftField::Temperature, text)
        }),
      ),
    ]),
  ])
  el("article", "draft", [
    el("div", "draft-head", [
      el("span", "draft-index", [txt("#\{index + 1}")]),
      text_input(
        "draft-id-" + index.to_string(),
        draft.id,
        "id（留空则自动编号）",
        emit.map(fn(text) { DraftFieldChanged(index, DraftField::Id, text) }),
      ),
      @html.button(
        class="link-btn danger",
        on_click=emit(Msg::RemoveDraft(index)),
        [txt("删除")],
      ),
    ]),
    @html.textarea(
      class="draft-prompt",
      id="draft-prompt-" + index.to_string(),
      value=draft.prompt,
      rows=3,
      on_input=emit.map(fn(text) {
        DraftFieldChanged(index, DraftField::Prompt, text)
      }),
      ([] : Array[@html.Html]),
    ),
    more,
  ])
}

///|
/// 表单里的小文本框。main.mbt 里有同名的东西但绑死了具体字段，这里要的是
/// 「哪个草稿的哪个字段」，所以单独写一个薄的。
fn text_input(
  id_ : String,
  value : String,
  placeholder : String,
  on_input : @cmd.Emit[String],
) -> @html.Html {
  @html.input(
    input_type=@html.InputType::Text,
    id=id_,
    value~,
    placeholder~,
    on_input~,
  )
}

// ---------------------------------------------------------------- 渲染：预设

///|
/// 预设面板：把「模型 + 参数」这组东西存下来，下次一键套用。
fn preset_panel(
  meta : Meta,
  model : AppModel,
  emit : @cmd.Emit[Msg],
) -> @html.Html {
  let body = match model.presets {
    None => [el("p", "muted", [txt("正在载入…")])]
    Some(presets) =>
      if presets.length() == 0 {
        [
          el("p", "muted", [
            txt(
              "还没有预设。填好参数后存一条，下次一键套用",
            ),
          ]),
        ]
      } else {
        presets.map(fn(preset) { preset_chip(meta, preset, emit) })
      }
  }
  el("div", "preset-panel", [
    el("div", "section-head", [el("h2", "", [txt("预设")])]),
    // 说明它到底动哪些东西：用户点「套用」之前得知道会覆盖什么
    el("p", "hint", [
      txt(
        "一条预设 = 模型 + 测试集 + System Prompt + 网关地址 + 参数（重复次数 / max tokens / temperature / 间隔 / 重试）。套用它＝把这些一次性写回表单；API key 不在里面，也不会被动",
      ),
    ]),
    el("div", "preset-list", body),
    el("div", "preset-actions", [
      @html.input(
        input_type=@html.InputType::Text,
        class="set-name",
        id="preset-name",
        value=model.preset_name,
        placeholder="预设名字",
        on_input=emit.map(fn(text) { PresetNameChanged(text) }),
      ),
      @html.button(class="ghost", on_click=emit(Msg::SavePreset), [
        txt("保存当前配置"),
      ]),
    ]),
    match model.presets_error {
      Some(message) => el("p", "failed", [txt(message)])
      None => txt("")
    },
  ])
}

///|
fn preset_chip(
  meta : Meta,
  preset : Preset,
  emit : @cmd.Emit[Msg],
) -> @html.Html {
  let parts : Array[String] = [preset.models.length().to_string() + " 模型"]
  match preset.caseSet {
    Some(name) => parts.push(name)
    None => ()
  }
  match preset.maxTokens {
    Some(tokens) => parts.push("max \{tokens}")
    None => ()
  }
  match preset.repeats {
    Some(repeats) => parts.push("× \{repeats}")
    None => ()
  }
  ignore(meta)
  el("div", "preset", [
    el("span", "preset-name", [txt(preset.name)]),
    el("span", "preset-meta", [txt(parts.join(" · "))]),
    @html.button(
      class="link-btn",
      on_click=emit(Msg::ApplyPreset(preset.name)),
      [txt("套用")],
    ),
    @html.button(
      class="link-btn danger",
      on_click=emit(Msg::DeletePreset(preset.name)),
      [txt("删除")],
    ),
  ])
}
