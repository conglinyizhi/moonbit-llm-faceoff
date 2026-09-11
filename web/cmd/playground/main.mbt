///| 试跑台：固定 system + 一组 user prompt × 两个（或更多）模型。
///
///   /playground.html
///
/// 与工作台（index.html）的关系：那边是「管理测试」（用例集、历史、预设、
/// 对比两次运行），这边是「随手试一下」——填一个 system、列几条 prompt、勾两个
/// 模型，跑完直接在一个等高等宽的矩阵里看两边分别答了什么。点一行上的按钮
/// 展开这一行的两个模型：左右并排看全文，或者切到差异视图看改哪儿了。
///
/// 运行走的是同一个 `POST /api/runs`（带 inlineCases + system），所以这些运行
/// 也会出现在工作台的运行记录里，可以重跑。

// ---------------------------------------------------------------- 数据

///|
struct Defaults {
  repeats : Int
  maxTokens : Int
  temperature : Double
  paceMs : Int
  retry : Int
} derive(Eq, FromJson)

///|
struct CaseSetInfo {
  name : String
  count : Int
} derive(Eq, FromJson)

///|
struct Meta {
  models : Array[String]
  caseSets : Array[CaseSetInfo]
  defaultCaseSet : String
  defaults : Defaults
  hasKey : Bool
  baseUrl : String
} derive(Eq, FromJson)

///|
struct StartResponse {
  id : String
  total : Int
} derive(Eq, FromJson)

///|
struct RunStatus {
  id : String
  status : String
  done : Int
  total : Int
  data : Json?
  error : String?
  tail : String?
  exitCode : String?
  failures : Int
  retried : Int
  truncated : Int
} derive(Eq, FromJson)

///|
/// 一次能一共带多少条 prompt。和服务端对用例集的上限一致。
let max_prompts : Int = 500

///|
/// 一条 prompt 的草稿。`system` 非空就覆盖顶上的全局 system（bench 的用例本来就
/// 支持 per-case system），空则跟着全局走。
struct PromptDraft {
  prompt : String
  system : String
} derive(Eq)

// ---------------------------------------------------------------- 模型

///|
struct AppModel {
  meta : Meta?
  meta_error : String?
  /// 整轮的 system prompt。
  system : String
  prompts : Array[PromptDraft]
  /// 勾上的菜单模型。
  selected_models : Array[String]
  /// 菜单之外手填的模型 id，逗号或换行分隔。
  extra_models : String
  max_tokens : Int
  temperature : Double
  run_id : String?
  status : String
  done : Int
  total : Int
  data : @shared.PageData?
  error : String?
  /// 展开的是哪一行（用例序号）；None = 全都收起。
  expanded : Int?
  /// 展开的那一行用差异视图，而不是左右并排。
  diff_mode : Bool
  /// 「按行导入」的文本框，以及导入后的反馈（导入了几条 / 为什么一条都没有）。
  import_text : String
  import_note : String?
  /// 这条运行的人工标注。
  annotations : Array[@shared.Annotation]
  /// 正在编辑哪条答案的备注（"case\u0000model"）与草稿。
  note_key : String?
  note_draft : String
  /// 「存成用例集」那一行的名字与反馈。
  save_name : String
  save_note : String?
  save_error : String?
} derive(Eq)

///|
fn initial_model() -> AppModel {
  {
    meta: None,
    meta_error: None,
    system: "你是一个简洁的助手，回答不超过两句话。",
    prompts: [
      { prompt: "用一句话说明什么是甲板风。", system: "", },
      { prompt: "用一句话说明什么是侧风。", system: "", },
    ],
    selected_models: [],
    extra_models: "",
    max_tokens: 1024,
    temperature: 0.0,
    run_id: None,
    status: "idle",
    done: 0,
    total: 0,
    data: None,
    error: None,
    expanded: None,
    diff_mode: false,
    import_text: "",
    import_note: None,
    annotations: [],
    note_key: None,
    note_draft: "",
    save_name: "",
    save_note: None,
    save_error: None,
  }
}

// ---------------------------------------------------------------- 消息与命令

///|
enum Msg {
  MetaLoaded(Result[Meta, Error])
  SystemChanged(String)
  PromptChanged(Int, String)
  PromptSystemChanged(Int, String)
  AddPrompt
  RemovePrompt(Int)
  ImportTextChanged(String)
  ImportLines(Bool)
  ToggleModel(String)
  ExtraModelsChanged(String)
  MaxTokensChanged(String)
  TemperatureChanged(String)
  StartRun
  RunStarted(Result[StartResponse, Error])
  RunProgress(Result[RunStatus, Error])
  ToggleRow(Int)
  ToggleDiffMode
  // 人工标注
  AnnotationsLoaded(String, Result[@shared.AnnotationResponse, Error])
  SetVerdict(String, String, String)
  NoteChanged(String, String, String)
  SaveNote(String)
  AnnotationsSaved(Result[Json, Error])
  SaveNameChanged(String)
  SaveCases
  CasesSaved(Result[Json, Error])
}

///|
fn fetch_meta(emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @http.get("/api/meta").expect_json(
    emit.map(fn(result) { MetaLoaded(result) }),
  )
}

///|
/// 这次要跑的东西：全局 system + 一堆 prompt，每条可以带自己的 system。
///
/// 手写 JSON 而不是 derive(ToJson)：没有覆盖 system 的那些用例**不能**带
/// `system: ""`——bench 会把它当成「这条的 system 就是空串」，而不是「跟着全局
/// 走」。字段要么是那条的覆盖，要么不出现。
fn run_payload(model : AppModel) -> Json {
  let cases = Json::array(
    model.prompts
    .filter(fn(draft) { draft.prompt.trim(chars=" \t\r\n") != "" })
    .map(fn(draft) {
      let entry : Map[String, Json] = { "prompt": Json::string(draft.prompt) }
      if draft.system != "" {
        entry["system"] = Json::string(draft.system)
      }
      Json::object(entry)
    }),
  )
  Json::object({
    "models": Json::array(effective_models(model).map(Json::string)),
    "system": Json::string(model.system),
    "inlineCases": cases,
    "repeats": Json::number(1.0),
    "maxTokens": Json::number(model.max_tokens.to_double()),
    "temperature": Json::number(model.temperature),
  })
}

///|
fn start_run(payload : Json, emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @http.post("/api/runs")
  .with_json(payload)
  .expect_json(emit.map(fn(result) { RunStarted(result) }))
}

///|
fn fetch_annotations(id : String, emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @http.get("/api/runs/" + id + "/annotations").expect_json(
    emit.map(fn(result) { AnnotationsLoaded(id, result) }),
  )
}

///|
fn save_annotations(
  id : String,
  annotations : Array[@shared.Annotation],
  emit : @cmd.Emit[Msg],
) -> @cmd.Cmd {
  @http.put("/api/runs/" + id + "/annotations")
  .with_json(annotations_json(annotations))
  .expect_json(emit.map(fn(result) { AnnotationsSaved(result) }))
}

///|
fn annotations_json(annotations : Array[@shared.Annotation]) -> Json {
  Json::object({
    "annotations": Json::array(
      annotations.map(fn(entry) {
        Json::object({
          "case_id": Json::string(entry.case_id),
          "model": Json::string(entry.model),
          "verdict": Json::string(entry.verdict),
          "note": Json::string(entry.note),
        })
      }),
    ),
  })
}

///|
/// 改一条标注：verdict / note 传 None 表示保持原样；两条都空就删掉这条。
fn set_annotation(
  annotations : Array[@shared.Annotation],
  case_id : String,
  answer_model : String,
  verdict : String,
  note : String?,
) -> Array[@shared.Annotation] {
  let out : Array[@shared.Annotation] = []
  let mut found = false
  for entry in annotations {
    if entry.case_id == case_id && entry.model == answer_model {
      found = true
      let next_verdict = if verdict != "" { verdict } else { entry.verdict }
      let next_note = match note {
        Some(text) => text
        None => entry.note
      }
      if next_verdict != "" || next_note != "" {
        out.push({ ..entry, verdict: next_verdict, note: next_note, })
      }
    } else {
      out.push(entry)
    }
  }
  if !found {
    let next_note = match note {
      Some(text) => text
      None => ""
    }
    if verdict != "" || next_note != "" {
      out.push({ case_id, model: answer_model, verdict, note: next_note, })
    }
  }
  out
}

///|
fn annotation_of(
  annotations : Array[@shared.Annotation],
  case_id : String,
  answer_model : String,
) -> @shared.Annotation? {
  match
    annotations.filter(fn(entry) {
      entry.case_id == case_id && entry.model == answer_model
    }) {
    [first, ..] => Some(first)
    [] => None
  }
}

///|
fn poll_run(id : String, emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @http.get("/api/runs/" + id).expect_json(
    emit.map(fn(result) { RunProgress(result) }),
  )
}

///|
/// 存成用例集：走的是工作台那套接口，所以存完在那边就能勾选重跑。
fn save_case_set(
  name : String,
  model : AppModel,
  emit : @cmd.Emit[Msg],
) -> @cmd.Cmd {
  @http.put("/api/cases/" + name)
  .with_json(save_body(model))
  .expect_json(emit.map(fn(result) { CasesSaved(result) }))
}

///|
fn save_body(model : AppModel) -> Json {
  Json::object({
    "cases": Json::array(
      model.prompts.map(fn(draft) {
        let entry : Map[String, Json] = { "prompt": Json::string(draft.prompt) }
        if draft.system != "" {
          entry["system"] = Json::string(draft.system)
        }
        // 全局 system 也写进每条：用例集里没有「全局 system」这个概念，
        // 不写就丢了
        if draft.system == "" && model.system != "" {
          entry["system"] = Json::string(model.system)
        }
        Json::object(entry)
      }),
    ),
  })
}

///|
fn effective_models(model : AppModel) -> Array[String] {
  let out : Array[String] = []
  for id in model.selected_models {
    out.push(id)
  }
  let normalized = model.extra_models.replace_all(old="\n", new=",")
  for piece in normalized.split(",") {
    let clean = piece.trim(chars=" \t\r").to_owned()
    if clean != "" && !out.contains(clean) {
      out.push(clean)
    }
  }
  out
}

// ---------------------------------------------------------------- 差异

///|
/// 差异视图里的一段：same = 两边一样，del = 只有左边有，ins = 只有右边有。
struct DiffPart {
  kind : String
  mut text : String
} derive(Eq)

///|
/// 字符级差异。先剥掉公共前后缀，只对中间那段做 LCS——两个模型答同一道题时，
/// 开头结尾往往是一样的，剥完剩下的通常很短。中间太长就整段标成「变了」，
/// 不为一个 demo 页面把 O(n·m) 的表撑到几十兆。
fn diff_chars(left : String, right : String) -> Array[DiffPart] {
  let a = left
  let b = right
  let mut prefix = 0
  let limit = min_int(a.length(), b.length())
  while prefix < limit && a[prefix] == b[prefix] {
    prefix = prefix + 1
  }
  let mut suffix = 0
  while suffix < limit - prefix &&
        a[a.length() - 1 - suffix] == b[b.length() - 1 - suffix] {
    suffix = suffix + 1
  }
  let parts : Array[DiffPart] = []
  if prefix > 0 {
    parts.push({ kind: "same", text: a[:prefix].to_owned(), })
  }
  let mid_a = a[prefix:a.length() - suffix].to_owned()
  let mid_b = b[prefix:b.length() - suffix].to_owned()
  if mid_a != "" || mid_b != "" {
    if mid_a.length() * mid_b.length() > 200000 {
      // 两边几乎没有公共部分：直接说清楚，别假装算过
      if mid_a != "" {
        parts.push({ kind: "del", text: mid_a, })
      }
      if mid_b != "" {
        parts.push({ kind: "ins", text: mid_b, })
      }
    } else {
      for part in lcs_blocks(mid_a, mid_b) {
        parts.push(part)
      }
    }
  }
  if suffix > 0 {
    parts.push({ kind: "same", text: a[a.length() - suffix:].to_owned(), })
  }
  parts
}

///|
/// 中间那段的 LCS 差异，返回按顺序的分段（相邻同类合并）。
fn lcs_blocks(a : String, b : String) -> Array[DiffPart] {
  let n = a.length()
  let m = b.length()
  // dp[i][j]：a[i:] 与 b[j:] 的最长公共子序列长度
  let rows : Array[Array[Int]] = []
  for i = 0; i <= n; i = i + 1 {
    rows.push(Array::make(m + 1, 0))
  }
  for i = n - 1; i >= 0; i = i - 1 {
    for j = m - 1; j >= 0; j = j - 1 {
      rows[i][j] = if a[i] == b[j] {
        rows[i + 1][j + 1] + 1
      } else {
        max_int(rows[i + 1][j], rows[i][j + 1])
      }
    }
  }
  let parts : Array[DiffPart] = []
  let mut i = 0
  let mut j = 0
  while i < n && j < m {
    if a[i] == b[j] {
      push_part(parts, "same", a[i].to_string())
      i = i + 1
      j = j + 1
    } else if rows[i + 1][j] >= rows[i][j + 1] {
      push_part(parts, "del", a[i].to_string())
      i = i + 1
    } else {
      push_part(parts, "ins", b[j].to_string())
      j = j + 1
    }
  }
  while i < n {
    push_part(parts, "del", a[i].to_string())
    i = i + 1
  }
  while j < m {
    push_part(parts, "ins", b[j].to_string())
    j = j + 1
  }
  parts
}

///|
/// 相邻同类合并，不然差异视图是逐字符的节点，又慢又长。
fn push_part(parts : Array[DiffPart], kind : String, text : String) -> Unit {
  match parts {
    [.., last] =>
      if last.kind == kind {
        last.text = last.text + text
        return
      }
    [] => ()
  }
  parts.push({ kind, text, })
}

///|
fn min_int(a : Int, b : Int) -> Int {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn max_int(a : Int, b : Int) -> Int {
  if a > b {
    a
  } else {
    b
  }
}

// ---------------------------------------------------------------- 更新

///|
fn update(
  model : AppModel,
  msg : Msg,
  emit : @cmd.Emit[Msg],
) -> (AppModel, @cmd.Cmd) {
  match msg {
    MetaLoaded(result) =>
      match result {
        Ok(meta) => {
          // 默认勾前两个模型：这一页的常态就是「两个模型并排看」
          let picked = meta.models[:min_int(2, meta.models.length())].to_owned()
          (
            {
              ..model,
              meta: Some(meta),
              meta_error: None,
              selected_models: if model.selected_models.length() > 0 {
                model.selected_models
              } else {
                picked
              },
              max_tokens: model.max_tokens,
              temperature: model.temperature,
            },
            @cmd.none,
          )
        }
        Err(error) =>
          ({ ..model, meta_error: Some(error.to_string()), }, @cmd.none)
      }
    SystemChanged(text) => ({ ..model, system: text, }, @cmd.none)
    PromptChanged(index, text) =>
      (
        {
          ..model,
          prompts: replace_prompt(model.prompts, index, prompt_text=text),
        },
        @cmd.none,
      )
    PromptSystemChanged(index, text) =>
      (
        {
          ..model,
          prompts: replace_prompt(model.prompts, index, system_text=text),
        },
        @cmd.none,
      )
    AddPrompt => {
      let prompts = model.prompts.copy()
      prompts.push({ prompt: "", system: "", })
      ({ ..model, prompts, }, @cmd.none)
    }
    ImportTextChanged(text) => ({ ..model, import_text: text, }, @cmd.none)
    ImportLines(replace) => {
      let (lines, skipped) = split_import_lines(model.import_text, max_prompts)
      if lines.length() == 0 {
        (
          {
            ..model,
            import_note: Some(
              "没有可导入的行（空行与 # 注释会跳过）",
            ),
          },
          @cmd.none,
        )
      } else {
        // 追加时把「点了再加一条但还没填内容」的空行摘掉：留着只会变成空 prompt
        let prompts = if replace {
          []
        } else {
          model.prompts.filter(fn(draft) {
            draft.prompt.trim(chars=" \t\r\n") != ""
          })
        }
        for line in lines {
          prompts.push({ prompt: line, system: "", })
        }
        let note = if skipped > 0 {
          "导入了 \{lines.length()} 条（另有 \{skipped} 行超出上限被丢掉）"
        } else {
          "导入了 \{lines.length()} 条"
        }
        (
          { ..model, prompts, import_text: "", import_note: Some(note), },
          @cmd.none,
        )
      }
    }
    RemovePrompt(index) => {
      let kept : Array[PromptDraft] = []
      for i = 0; i < model.prompts.length(); i = i + 1 {
        if i != index {
          kept.push(model.prompts[i])
        }
      }
      ({ ..model, prompts: kept, expanded: None, }, @cmd.none)
    }
    ToggleModel(id) =>
      (
        { ..model, selected_models: toggle(model.selected_models, id), },
        @cmd.none,
      )
    ExtraModelsChanged(text) => ({ ..model, extra_models: text, }, @cmd.none)
    MaxTokensChanged(text) =>
      (
        { ..model, max_tokens: clamp_int(text, 1, 32768, model.max_tokens), },
        @cmd.none,
      )
    TemperatureChanged(text) =>
      (
        {
          ..model,
          temperature: clamp_double(text, 0.0, 2.0, model.temperature),
        },
        @cmd.none,
      )
    StartRun =>
      if model.status == "running" || model.status == "starting" {
        (model, @cmd.none)
      } else {
        (
          {
            ..model,
            status: "starting",
            error: None,
            data: None,
            done: 0,
            total: 0,
            expanded: None,
          },
          start_run(run_payload(model), emit),
        )
      }
    RunStarted(result) =>
      match result {
        Ok(response) =>
          (
            {
              ..model,
              run_id: Some(response.id),
              status: "running",
              total: response.total,
              done: 0,
            },
            @rabbita.delay(poll_run(response.id, emit), 400),
          )
        Err(error) =>
          (
            { ..model, status: "failed", error: Some(error.to_string()), },
            @cmd.none,
          )
      }
    RunProgress(result) =>
      match result {
        Ok(status) => {
          let data = match status.data {
            Some(json) =>
              match @shared.parse_page_data_json(json) {
                Ok(data) => Some(data)
                Err(_) => model.data
              }
            None => model.data
          }
          let next = {
            ..model,
            status: status.status,
            done: status.done,
            total: status.total,
            data,
            error: status.error,
            run_id: Some(status.id),
          }
          if status.status == "running" {
            (next, @rabbita.delay(poll_run(status.id, emit), 700))
          } else {
            // 跑完把这次运行的标注拿进来（重跑同一条时可能已经有标注）
            (next, fetch_annotations(status.id, emit))
          }
        }
        Err(error) =>
          (
            { ..model, status: "failed", error: Some(error.to_string()), },
            @cmd.none,
          )
      }
    ToggleRow(index) =>
      (
        {
          ..model,
          expanded: if model.expanded == Some(index) {
            None
          } else {
            Some(index)
          },
        },
        @cmd.none,
      )
    ToggleDiffMode => ({ ..model, diff_mode: !model.diff_mode, }, @cmd.none)
    AnnotationsLoaded(_id, result) =>
      match result {
        Ok(response) =>
          ({ ..model, annotations: response.annotations, }, @cmd.none)
        Err(_) => (model, @cmd.none)
      }
    SetVerdict(case_id, answer_model, verdict) => {
      let next = set_annotation(
        model.annotations,
        case_id,
        answer_model,
        verdict,
        None,
      )
      match model.run_id {
        None => ({ ..model, annotations: next, }, @cmd.none)
        Some(id) =>
          ({ ..model, annotations: next, }, save_annotations(id, next, emit))
      }
    }
    NoteChanged(case_id, answer_model, text) =>
      (
        {
          ..model,
          note_key: Some(case_id + "\u0000" + answer_model),
          note_draft: text,
        },
        @cmd.none,
      )
    SaveNote(case_id) => {
      let answer_model = match model.note_key {
        Some(key) =>
          match key.find("\u0000") {
            Some(index) => key[index + 1:].to_owned()
            None => ""
          }
        None => ""
      }
      let next = set_annotation(
        model.annotations,
        case_id,
        answer_model,
        "",
        Some(model.note_draft),
      )
      match model.run_id {
        None => ({ ..model, annotations: next, note_key: None, }, @cmd.none)
        Some(id) =>
          (
            { ..model, annotations: next, note_key: None, },
            save_annotations(id, next, emit),
          )
      }
    }
    AnnotationsSaved(_result) => (model, @cmd.none)
    SaveNameChanged(text) => ({ ..model, save_name: text, }, @cmd.none)
    SaveCases => {
      let name = model.save_name.trim(chars=" \t\r\n").to_owned()
      if name == "" {
        (
          { ..model, save_error: Some("先给这套用例起个名字"), },
          @cmd.none,
        )
      } else {
        (
          { ..model, save_error: None, save_note: Some("正在保存…"), },
          save_case_set(name, model, emit),
        )
      }
    }
    CasesSaved(result) =>
      match result {
        Ok(_) =>
          (
            {
              ..model,
              save_note: Some("已存成用例集"),
              save_error: None,
            },
            fetch_meta(emit),
          )
        Err(error) =>
          (
            { ..model, save_error: Some(error.to_string()), save_note: None, },
            @cmd.none,
          )
      }
  }
}

///|
/// 改一条 prompt 的某个字段。prompt 与 system 走同一套替换逻辑。
fn replace_prompt(
  prompts : Array[PromptDraft],
  index : Int,
  prompt_text? : String,
  system_text? : String,
) -> Array[PromptDraft] {
  let out = prompts.copy()
  if index >= 0 && index < out.length() {
    let draft = out[index]
    let next = {
      prompt: match prompt_text {
        Some(text) => text
        None => draft.prompt
      },
      system: match system_text {
        Some(text) => text
        None => draft.system
      },
    }
    out[index] = next
  }
  out
}

///|
fn toggle(values : Array[String], value : String) -> Array[String] {
  if values.contains(value) {
    values.filter(fn(item) { item != value })
  } else {
    values.push(value)
    values
  }
}

///|
fn clamp_int(text : String, low : Int, high : Int, fallback : Int) -> Int {
  let value = @string.parse_int(text) catch { _ => return fallback }
  if value < low {
    low
  } else if value > high {
    high
  } else {
    value
  }
}

///|
fn clamp_double(
  text : String,
  low : Double,
  high : Double,
  fallback : Double,
) -> Double {
  let value = @string.parse_double(text) catch { _ => return fallback }
  if value < low {
    low
  } else if value > high {
    high
  } else {
    value
  }
}

// ---------------------------------------------------------------- 启动

///|
fn app() -> @rabbita.App {
  @rabbita.new(fn() {
    let (model, emit) = @rabbita.create_state_with_init(
      init=fn(emit) { (initial_model(), fetch_meta(emit)) },
      update~,
    )
    model.map(fn(model) { view(model, emit) })
  })
}

///|
fn main {
  app().mount("app")
}

// ---------------------------------------------------------------- 视图

///|
fn txt(value : String) -> @html.Html {
  @html.text(value)
}

///|
fn el(
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
fn view(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  el("div", "app", [
    header(model),
    el("div", "wrap playground", [
      form(model, emit),
      progress(model),
      matrix(model, emit),
      save_row(model, emit),
    ]),
    footer(),
  ])
}

///|
fn header(model : AppModel) -> @html.Html {
  let meta_line = match model.meta {
    Some(meta) => "\{meta.models.length()} 个模型可选 · \{meta.baseUrl}"
    None => "正在载入…"
  }
  el("header", "site-header", [
    el("div", "wrap site-header-inner", [
      el("div", "site-logo", [txt("试跑台")]),
      el("div", "site-meta", [txt(meta_line)]),
      @html.a(href="index.html", class="link-btn", [txt("← 回工作台")]),
    ]),
  ])
}

///|
fn form(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  match model.meta {
    None =>
      el("section", "hero", [
        @html.h1([txt("试跑台")]),
        @html.p([
          txt(
            match model.meta_error {
              Some(error) => "载入失败：" + error
              None => "正在载入配置…"
            },
          ),
        ]),
      ])
    Some(meta) =>
      el("section", "hero", [
        @html.h1([txt("固定 system，一组 prompt，两个模型")]),
        @html.p([
          txt(
            "同一个 system prompt 喂给每条 user prompt，右侧按行给出每个模型的输出。点某一行的「对比」看全文与差异。",
          ),
        ]),
        if !meta.hasKey {
          el("p", "failed", [
            txt(
              "服务端没有读到 API key。启动服务端前设好 MOONLLM_API_KEY / OPENAI_API_KEY 即可。",
            ),
          ])
        } else {
          @html.fragment([])
        },
        system_field(model, emit),
        prompts_field(model, emit),
        models_field(meta, model, emit),
        params_row(model, emit),
        action_row(model, emit),
      ])
  }
}

///|
fn system_field(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  el("fieldset", "picker", [
    el("legend", "", [txt("System prompt（所有 prompt 共用）")]),
    @html.textarea(
      class="prompt-input",
      id="system",
      value=model.system,
      rows=2,
      on_input=emit.map(fn(text) { SystemChanged(text) }),
      ([] : Array[@html.Html]),
    ),
  ])
}

///|
fn prompts_field(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  let rows = []
  for i = 0; i < model.prompts.length(); i = i + 1 {
    rows.push(prompt_row(i, model.prompts[i], emit))
  }
  el("fieldset", "picker", [
    el("legend", "", [txt("User prompt（每条一行）")]),
    el("div", "prompt-rows", rows),
    el("div", "editor-actions", [
      @html.button(class="ghost", on_click=emit(Msg::AddPrompt), [
        txt("＋ 再加一条"),
      ]),
      el("span", "hint", [txt("\{model.prompts.length()} 条")]),
    ]),
    import_box(model, emit),
  ])
}

///|
/// 按行导入：一行一条 prompt。这是给「手上已经有一堆文本」的人准备的入口——
/// 一行行手敲是最不必要的劳动。
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
          "一行一条；空行与 # 开头的行跳过（导入会替换掉当前所有空行）",
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
/// 把多行文本切成 prompt 列表：去空白、丢空行、丢 `#` 注释行，最多留 `limit` 条。
/// 返回 (留下的行, 因为超限被丢掉的条数)。
fn split_import_lines(text : String, limit : Int) -> (Array[String], Int) {
  let out : Array[String] = []
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
    out.push(line)
  }
  (out, skipped)
}

///|
fn prompt_row(
  index : Int,
  draft : PromptDraft,
  emit : @cmd.Emit[Msg],
) -> @html.Html {
  el("div", "prompt-row", [
    el("div", "prompt-row-head", [
      el("span", "draft-index", [txt("#\{index + 1}")]),
      @html.button(
        class="link-btn danger",
        on_click=emit(Msg::RemovePrompt(index)),
        [txt("删除")],
      ),
    ]),
    @html.textarea(
      class="prompt-input",
      id="prompt-" + index.to_string(),
      value=draft.prompt,
      rows=2,
      on_input=emit.map(fn(text) { PromptChanged(index, text) }),
      ([] : Array[@html.Html]),
    ),
    // 每条自己的 system 收起来：多数时候用全局那个，需要时才覆盖
    el("details", "draft-more", [
      el("summary", "", [
        txt(
          if draft.system == "" {
            "单独的 system（可选）"
          } else {
            "单独的 system：\{draft.system}"
          },
        ),
      ]),
      @html.input(
        input_type=@html.InputType::Text,
        class="set-name",
        id="prompt-system-" + index.to_string(),
        value=draft.system,
        placeholder="留空 = 用上面的全局 system",
        on_input=emit.map(fn(text) { PromptSystemChanged(index, text) }),
      ),
    ]),
  ])
}

///|
fn models_field(
  meta : Meta,
  model : AppModel,
  emit : @cmd.Emit[Msg],
) -> @html.Html {
  let boxes = meta.models.map(fn(id) {
    labelled_checkbox(
      "model-" + id,
      id,
      model.selected_models.contains(id),
      emit.map(fn(_value) { ToggleModel(id) }),
    )
  })
  el("fieldset", "picker", [
    el("legend", "", [txt("模型（勾几个就并排几列）")]),
    el("div", "picker-items", boxes),
    @html.input(
      input_type=@html.InputType::Text,
      class="prompt-input",
      id="extra-models",
      value=model.extra_models,
      placeholder="菜单之外也可以：直接填 id，逗号分隔",
      on_input=emit.map(fn(text) { ExtraModelsChanged(text) }),
    ),
  ])
}

///|
fn params_row(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  el("div", "params", [
    number_field(
      "max-tokens",
      "max tokens",
      model.max_tokens.to_string(),
      emit.map(fn(text) { MaxTokensChanged(text) }),
    ),
    number_field(
      "temperature",
      "temperature",
      model.temperature.to_string(),
      emit.map(fn(text) { TemperatureChanged(text) }),
    ),
  ])
}

///|
fn number_field(
  id_ : String,
  label : String,
  value : String,
  on_input : @cmd.Emit[String],
) -> @html.Html {
  el("label", "field", [
    el("span", "", [txt(label)]),
    @html.input(input_type=@html.InputType::Text, id=id_, value~, on_input~),
  ])
}

///|
fn labelled_checkbox(
  id_ : String,
  label : String,
  checked : Bool,
  on_change : @cmd.Emit[String],
) -> @html.Html {
  // 和工作台那套一样：复选框的回调给的是 value 字符串，不是 Bool
  @html.label(for_=id_, class="check", [
    @html.input(
      input_type=@html.InputType::Checkbox,
      id=id_,
      value=id_,
      checked~,
      on_change~,
    ),
    txt(label),
  ])
}

///|
fn action_row(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  let models = effective_models(model)
  let cases = model.prompts.filter(fn(draft) {
    draft.prompt.trim(chars=" \t\r\n") != ""
  })
  let total = models.length() * cases.length()
  let busy = model.status == "running" || model.status == "starting"
  el("div", "actions", [
    @html.button(
      class=if busy { "primary busy" } else { "primary" },
      on_click=emit(Msg::StartRun),
      [txt(if busy { "运行中…" } else { "开始试跑" })],
    ),
    el("span", "hint", [
      txt(
        "\{models.length()} 个模型 × \{cases.length()} 条 prompt = \{total} 次请求",
      ),
    ]),
  ])
}

///|
fn progress(model : AppModel) -> @html.Html {
  if model.status == "idle" {
    return @html.fragment([])
  }
  let percent = if model.total > 0 {
    (model.done.to_double() / model.total.to_double() * 100.0).to_int()
  } else {
    0
  }
  el("section", "progress-card", [
    el("div", "progress-head", [
      txt(
        "\{status_label(model.status)}  \{model.done}/\{model.total}（\{percent}%）",
      ),
    ]),
    match model.error {
      Some(error) => @html.pre([txt(error)])
      None => @html.fragment([])
    },
  ])
}

///|
fn status_label(status : String) -> String {
  match status {
    "idle" => "待命"
    "starting" => "正在发起"
    "running" => "运行中"
    "done" => "已完成"
    "failed" => "失败了"
    _ => status
  }
}

// ---------------------------------------------------------------- 结果矩阵

///|
fn matrix(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  match model.data {
    None => @html.fragment([])
    // 标注贴回数据再渲染：答案块上的判定徽章读的是 answer.verdict，
    // 编辑器读的是标注表——两处都得有，否则「判过了但徽章不出现」
    Some(data) => {
      let data = @shared.with_annotations(data, model.annotations)
      matrix_body(data, model, emit)
    }
  }
}

///|
fn matrix_body(
  data : @shared.PageData,
  model : AppModel,
  emit : @cmd.Emit[Msg],
) -> @html.Html {
  if data.cases.length() == 0 {
    @html.fragment([])
  } else {
    el(
      "section",
      "matrix",
      [
        el("div", "matrix-head", [
          @html.h2([txt("各模型输出")]),
          el("span", "hint", [
            txt(
              "点某一行的「对比」展开全文与差异；同一行的列宽高一致",
            ),
          ]),
        ]),
        ..rows_view(data, model, emit),
      ],
    )
  }
}

///|
fn rows_view(
  data : @shared.PageData,
  model : AppModel,
  emit : @cmd.Emit[Msg],
) -> Array[@html.Html] {
  let rows = []
  for i = 0; i < data.cases.length(); i = i + 1 {
    rows.push(case_row(model, i, data.cases[i], emit))
  }
  rows
}

///|
fn case_row(
  model : AppModel,
  index : Int,
  block : @shared.CaseBlock,
  emit : @cmd.Emit[Msg],
) -> @html.Html {
  let expanded = model.expanded == Some(index)
  let prompt = prompt_of(model, index)
  let head = el("div", "matrix-row-head", [
    el("span", "draft-index", [txt("#\{index + 1}")]),
    el("span", "matrix-prompt", [txt(prompt)]),
    @html.button(class="link-btn", on_click=emit(Msg::ToggleRow(index)), [
      txt(if expanded { "收起" } else { "对比" }),
    ]),
  ])
  let cells = el(
    "div",
    "matrix-cells",
    block.answers.map(fn(answer) { cell(block.id, answer, model.annotations) }),
  )
  if expanded {
    el("article", "matrix-row expanded", [
      head,
      cells,
      compare_view(model, block, emit),
    ])
  } else {
    el("article", "matrix-row", [head, cells])
  }
}

///|
/// 行标题用当前草稿里的 prompt（改了输入之后立刻反映出来）；找不到就退回
/// 结果里那份。
fn prompt_of(model : AppModel, index : Int) -> String {
  if index < model.prompts.length() {
    let draft = model.prompts[index]
    if draft.prompt.trim(chars=" \t\r\n") != "" {
      return draft.prompt
    }
  }
  ""
}

///|
/// 一个单元格：等高等宽，正文截断，带 token 与耗时。要读全文就点这一行的「对比」。
fn cell(
  case_id : String,
  answer : @shared.Answer,
  annotations : Array[@shared.Annotation],
) -> @html.Html {
  // 判定直接在格子上显示成一个小角标：矩阵是用来扫的，扫得出「哪些判过」很重要
  let mark = match annotation_of(annotations, case_id, answer.model) {
    Some(entry) => " " + @shared.verdict_label(entry.verdict)
    None => ""
  }
  let head = el("div", "cell-head", [
    el("span", "cell-model", [txt(answer.model)]),
    el("span", "cell-stats", [
      txt(
        if answer.ok {
          "\{format_ms(answer.total_ms)} · \{answer.completion_tokens} tok\{mark}"
        } else {
          "失败"
        },
      ),
    ]),
  ])
  let body = if answer.ok {
    el("div", "cell-body", [txt(clamp_text(answer.content, 320))])
  } else {
    el("div", "cell-body failed", [
      txt(
        match answer.error {
          Some(message) => message
          None => "failed"
        },
      ),
    ])
  }
  let foot = if answer.reasoning_tokens > 0 {
    el("div", "cell-foot", [txt("思考 \{answer.reasoning_tokens} token")])
  } else {
    @html.fragment([])
  }
  el("div", "cell", [head, body, foot])
}

///|
fn format_ms(value : Double) -> String {
  let rounded = (value * 10.0).round() / 10.0
  rounded.to_string() + " ms"
}

///|
/// 单元格里的简介：太长就截断。留一格省略号，让人知道被截了。
fn clamp_text(text : String, cap : Int) -> String {
  let trimmed = text.trim(chars=" \t\r\n").to_owned()
  if trimmed.length() <= cap {
    trimmed
  } else {
    trimmed[:cap].to_owned() + "…"
  }
}

// ---------------------------------------------------------------- 对比视图

///|
/// 展开的那一行：左右并排（或差异视图）看这几个模型的全文与思考。
fn compare_view(
  model : AppModel,
  block : @shared.CaseBlock,
  emit : @cmd.Emit[Msg],
) -> @html.Html {
  let toggle = el("div", "compare-toolbar", [
    @html.button(
      class=if model.diff_mode { "ghost" } else { "primary" },
      on_click=emit(Msg::ToggleDiffMode),
      [txt(if model.diff_mode { "左右并排" } else { "差异视图" })],
    ),
    el("span", "hint", [
      txt(
        if model.diff_mode {
          "绿 = 右边多了，红 = 左边多了"
        } else {
          "同一行的答案左右并排，思考过程默认收起"
        },
      ),
    ]),
  ])
  let body = if model.diff_mode {
    diff_view(block)
  } else {
    side_by_side(block.id, block, model, emit)
  }
  el("div", "compare", [toggle, body])
}

///|
fn side_by_side(
  case_id : String,
  block : @shared.CaseBlock,
  model : AppModel,
  emit : @cmd.Emit[Msg],
) -> @html.Html {
  el(
    "div",
    "compare-cols",
    block.answers.map(fn(answer) {
      el("div", "compare-col", [
        el("div", "compare-col-head", [
          txt(
            "\{answer.model} · \{format_ms(answer.total_ms)} · \{answer.completion_tokens} token（推理 \{answer.reasoning_tokens}）",
          ),
        ]),
        @shared.answer_block(case_id, answer, editor=fn(_case, answer_model) {
          playground_editor(model, case_id, answer_model, emit)
        }),
      ])
    }),
  )
}

///|
/// 差异视图：第一个模型作基准，其余每个与它逐字比一遍。
fn diff_view(block : @shared.CaseBlock) -> @html.Html {
  match block.answers {
    [] => el("p", "muted", [txt("没有答案")])
    [only, ..] =>
      if block.answers.length() == 1 {
        el("p", "muted", [
          txt(
            "只有一个模型，没有可比的对象（勾两个模型再跑）。",
          ),
        ])
      } else {
        let base = only
        el(
          "div",
          "diffs",
          block.answers[1:].map(fn(answer) { diff_block(base, answer) }),
        )
      }
  }
}

///|
fn diff_block(left : @shared.Answer, right : @shared.Answer) -> @html.Html {
  let parts = diff_chars(left.content, right.content)
  el("article", "diff-block", [
    el("div", "diff-title", [
      txt(
        "\{left.model} → \{right.model}：\{summary_of(left)} / \{summary_of(right)}",
      ),
    ]),
    @html.pre([
      el(
        "span",
        "diff-text",
        parts.map(fn(part) { el("span", "diff-" + part.kind, [txt(part.text)]) }),
      ),
    ]),
  ])
}

///|
fn summary_of(answer : @shared.Answer) -> String {
  if !answer.ok {
    return "失败"
  }
  let text = answer.content.trim(chars=" \t\r\n").to_owned()
  "\{text.length()} 字 / \{answer.completion_tokens} token"
}

///|
/// 一条答案的标注编辑器（和工作台那边同一套组件，回调映射成这页的 Msg）。
fn playground_editor(
  model : AppModel,
  case_id : String,
  answer_model : String,
  emit : @cmd.Emit[Msg],
) -> @html.Html {
  let entry = annotation_of(model.annotations, case_id, answer_model)
  let key = case_id + "\u0000" + answer_model
  let note = if model.note_key == Some(key) {
    model.note_draft
  } else {
    match entry {
      Some(entry) => entry.note
      None => ""
    }
  }
  @shared.annotation_editor(
    entry,
    note,
    emit(SetVerdict(case_id, answer_model, "pass")),
    emit(SetVerdict(case_id, answer_model, "fail")),
    emit(SetVerdict(case_id, answer_model, "unsure")),
    emit(SetVerdict(case_id, answer_model, "")),
    emit.map(fn(text) { NoteChanged(case_id, answer_model, text) }),
    emit(SaveNote(case_id)),
  )
}

// ---------------------------------------------------------------- 存成用例集

///|
fn save_row(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  match model.data {
    None => @html.fragment([])
    Some(_) =>
      el("section", "preset-panel", [
        el("div", "section-head", [
          @html.h2([txt("存成用例集")]),
          el("span", "muted", [
            txt(
              "存进 web/cases/，工作台里就能勾选重跑（全局 system 会写进每一条）",
            ),
          ]),
        ]),
        el("div", "preset-actions", [
          @html.input(
            input_type=@html.InputType::Text,
            class="set-name",
            id="save-name",
            value=model.save_name,
            placeholder="用例集名字",
            on_input=emit.map(fn(text) { SaveNameChanged(text) }),
          ),
          @html.button(class="ghost", on_click=emit(Msg::SaveCases), [
            txt("保存"),
          ]),
          match model.save_note {
            Some(note) => el("span", "hint copied", [txt(note)])
            None => @html.fragment([])
          },
        ]),
        match model.save_error {
          Some(message) => el("p", "failed", [txt(message)])
          None => @html.fragment([])
        },
      ])
  }
}

///|
fn footer() -> @html.Html {
  el("footer", "site-footer", [
    el("div", "wrap", [
      txt(
        "试跑台走的是和工作台同一个接口，所以这里的运行也会出现在运行记录里。",
      ),
    ]),
  ])
}
