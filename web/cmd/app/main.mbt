///|
/// 交互式评测页（js / Rabbita TEA）。
///
/// 页面只跟同源的 /api 说话，网关密钥留在服务端进程里，不下发到浏览器。
///
///   启动    GET  /api/meta          取模型白名单、用例列表、默认参数
///   提交    POST /api/runs          建一次运行，返回 id
///   轮询    GET  /api/runs/<id>     进度 + 完成后的结果数据
///
/// 轮询由 update 自己在收到响应后重新排程（@rabbita.delay），不常驻心跳。

// ---------------------------------------------------------------- 接口类型

///|
struct CaseInfo {
  id : String
  prompt : String
} derive(Eq, FromJson)

///|
struct CaseSetInfo {
  name : String
  count : Int
} derive(Eq, FromJson)

///|
struct Defaults {
  repeats : Int
  maxTokens : Int
  temperature : Double
  paceMs : Int
  retry : Int
} derive(Eq, FromJson)

///|
struct Meta {
  models : Array[String]
  cases : Array[CaseInfo]
  /// 用例集列表（round 3 的切换器用它；现在只需要知道名字与条数）。
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
/// 当前页面的 query string。
///
/// 有了它就能把一次配置直接做成可分享的链接，例如
///   /?autorun=1&models=MiniCPM5-1B,MiniCPM5-2B&cases=math-short&repeats=1
extern "js" fn current_search() -> String = "() => window.location.search"

///|
/// 复制到剪贴板。优先用异步 Clipboard API（需要 secure context，127.0.0.1
/// 算），拿不到就退到 execCommand 的老路子。返回是否已经发出复制指令。
extern "js" fn copy_text(text : String) -> Bool = "(text) => { try { if (navigator.clipboard && window.isSecureContext) { navigator.clipboard.writeText(text); return true } const a = document.createElement('textarea'); a.value = text; a.style.position = 'fixed'; a.style.opacity = '0'; document.body.appendChild(a); a.select(); const ok = document.execCommand('copy'); document.body.removeChild(a); return ok } catch (e) { return false } }"

///|
/// 当前页面的 origin + path，用来拼分享链接。
extern "js" fn page_base() -> String = "() => window.location.origin + window.location.pathname"

// ---------------------------------------------------------------- 状态

///|
struct AppModel {
  meta : Meta?
  meta_error : String?
  selected_models : Array[String]
  selected_cases : Array[String]
  prompt : String
  use_prompt : Bool
  repeats : Int
  max_tokens : Int
  temperature : Double
  pace_ms : Int
  retry : Int
  run_id : String?
  status : String
  done : Int
  total : Int
  data : @shared.PageData?
  error : String?
  /// 打开页面就立刻跑一次（来自 ?autorun=1），触发后置回 false。
  autorun : Bool
  /// autorun 请求了、但当下没有可用的密钥，所以没跑。页面要解释一句。
  autorun_held : Bool
  /// 页面打开时的 query string（?autorun / models / cases / repeats / …）。
  /// meta 到齐后套用，让链接本身就能表达一次完整配置。
  query : Map[String, String]
  /// 服务端菜单之外的模型 id，逗号或换行分隔；与勾选结果合并后生效。
  extra_models : String
  /// 页面覆盖的网关地址。空串表示用服务端环境里的那份。
  base_url : String
  /// 页面覆盖的网关密钥。空串表示用服务端环境里的那份。
  /// 只活在页面内存里：不进 URL、不进 localStorage、也不写进请求的存档。
  api_key : String
  /// 上一次复制操作的反馈文字。
  copied : String?
  /// 当前选的用例集（来自 meta.defaultCaseSet 或 ?caseSet=）。
  case_set : String
  /// 运行历史（`GET /api/runs`）。None = 还没拉到。
  runs : Array[RunInfo]?
  runs_error : String?
  /// 当前用例集里的用例。选中集、编辑保存之后会变，所以不能每次去读 meta。
  available_cases : Array[CaseInfo]
  /// 用例编辑态：草稿 + 反馈。
  editing_cases : Bool
  drafts : Array[CaseDraft]
  cases_error : String?
  cases_saved : String?
  /// 「另存为新集」的输入框。
  new_set_name : String
  /// 预设。None = 还没拉到。
  presets : Array[Preset]?
  presets_error : String?
  preset_name : String
  /// 勾了要对比的运行 id（最多两个）。
  compare_picks : Array[String]
  /// 正在看的对比。Some 时结果区被对比视图接管。
  compare : CompareState?
  /// 正在看的那次历史运行。None 表示看当前这次。
  viewed : ViewedRun?
  /// 正在删/正在重跑的 id：同一条上重复点击直接忽略（按钮不用 disabled，
  /// VDOM 从忙到闲不会把那个属性摘掉——见 action_row）。
  busy_run : String?
  /// 运行中的实时信息：日志尾 + 失败/重试/截断计数。
  tail : String
  failures : Int
  retried : Int
  truncated : Int
} derive(Eq)

///|
fn initial_model() -> AppModel {
  let query = parse_query(current_search())
  {
    autorun: query.get("autorun") == Some("1"),
    autorun_held: false,
    query,
    meta: None,
    meta_error: None,
    selected_models: [],
    selected_cases: [],
    prompt: "",
    use_prompt: false,
    repeats: 3,
    max_tokens: 2048,
    temperature: 0.0,
    pace_ms: 3000,
    retry: 3,
    run_id: None,
    status: "idle",
    done: 0,
    total: 0,
    data: None,
    error: None,
    extra_models: "",
    base_url: query.get("baseUrl").unwrap_or(""),
    api_key: "",
    copied: None,
    case_set: query.get("caseSet").unwrap_or(""),
    available_cases: [],
    editing_cases: false,
    drafts: [],
    cases_error: None,
    cases_saved: None,
    new_set_name: "",
    presets: None,
    presets_error: None,
    preset_name: "",
    compare_picks: [],
    compare: None,
    tail: "",
    failures: 0,
    retried: 0,
    truncated: 0,
    runs: None,
    runs_error: None,
    viewed: None,
    busy_run: None,
  }
}

///|
/// 解析 query string（不做完整 URL 语义，只够取参数）。
fn parse_query(search : String) -> Map[String, String] {
  let out : Map[String, String] = Map([])
  let text = if search.has_prefix("?") { search[1:].to_owned() } else { search }
  for pair in text.split("&") {
    let item = pair.to_owned()
    if item.length() == 0 {
      continue
    }
    match item.find("=") {
      Some(index) => {
        let key = item[:index].to_owned()
        let value = item[index + 1:].to_owned()
        out[key] = percent_decode(value)
      }
      None => ()
    }
  }
  out
}

///|
fn int_param(query : Map[String, String], key : String, fallback : Int) -> Int {
  match query.get(key) {
    Some(raw) => clamp_int(raw, 0, 32768, fallback)
    None => fallback
  }
}

///|
fn double_param(
  query : Map[String, String],
  key : String,
  fallback : Double,
) -> Double {
  match query.get(key) {
    Some(raw) => clamp_double(raw, 0.0, 2.0, fallback)
    None => fallback
  }
}

///|
fn split_list(query : Map[String, String], key : String) -> Array[String] {
  match query.get(key) {
    None => []
    Some(raw) => {
      let out : Array[String] = []
      for part in raw.split(",") {
        let item = part.trim(chars=" \t").to_owned()
        if item.length() > 0 {
          out.push(item)
        }
      }
      out
    }
  }
}

///|
/// %XX 与 + 的最简解码。
fn percent_decode(text : String) -> String {
  let buf = StringBuilder()
  let mut i = 0
  let n = text.length()
  while i < n {
    let c = text[i]
    if c == 0x2B {
      buf.write_char(' ')
      i = i + 1
    } else if c == 0x25 && i + 2 < n {
      let hi = hex_digit(text[i + 1])
      let lo = hex_digit(text[i + 2])
      if hi < 0 || lo < 0 {
        buf.write_char(Int::unsafe_to_char(c.to_int()))
        i = i + 1
      } else {
        buf.write_char(Int::unsafe_to_char(hi * 16 + lo))
        i = i + 3
      }
    } else {
      buf.write_char(Int::unsafe_to_char(c.to_int()))
      i = i + 1
    }
  }
  buf.to_string()
}

///|
fn hex_digit(c : UInt16) -> Int {
  let value = c.to_int()
  if value >= 0x30 && value <= 0x39 {
    value - 0x30
  } else if value >= 0x61 && value <= 0x66 {
    value - 0x61 + 10
  } else if value >= 0x41 && value <= 0x46 {
    value - 0x41 + 10
  } else {
    -1
  }
}

///|
enum Msg {
  MetaLoaded(Result[Meta, Error])
  ToggleModel(String)
  ToggleCase(String)
  SelectAllCases
  UsePrompt(Bool)
  PromptChanged(String)
  RepeatsChanged(String)
  MaxTokensChanged(String)
  TemperatureChanged(String)
  PaceChanged(String)
  RetryChanged(String)
  StartRun
  RunStarted(Result[StartResponse, Error])
  RunProgress(Result[RunStatus, Error])
  ExtraModelsChanged(String)
  BaseUrlChanged(String)
  ApiKeyChanged(String)
  CopyMarkdown
  CopyShareLink
  RefreshRuns
  RunsLoaded(Result[RunsResponse, Error])
  OpenRun(String)
  ViewedLoaded(String, Result[RunStatus, Error])
  CloseRun
  DeleteRun(String)
  RunDeleted(String, Result[Json, Error])
  Rerun(String)
  // 用例集
  ToggleCaseEditor
  SelectCaseSet(String)
  CaseSetLoaded(String, Result[CaseSetResponse, Error])
  NewSetNameChanged(String)
  NewCaseSet
  DeleteCaseSet
  SelectNoCases
  AddDraft
  RemoveDraft(Int)
  DraftFieldChanged(Int, DraftField, String)
  SaveCases
  CaseSetSaved(String, Result[Json, Error])
  CaseSetDeleted(String, Result[Json, Error])
  // 预设
  PresetsLoaded(Result[PresetsResponse, Error])
  PresetsSaved(Result[PresetsResponse, Error])
  PresetNameChanged(String)
  SavePreset
  ApplyPreset(String)
  DeletePreset(String)
  // 两次运行对比
  ToggleComparePick(String)
  StartCompare
  CompareRunLoaded(String, Result[RunStatus, Error])
  CloseCompare
}

///|
/// 用例草稿里可以被编辑的字段。用一个枚举而不是四个 Msg：
/// 四个几乎一样的消息只会让 update 里多四份重复的样板。
enum DraftField {
  Id
  Prompt
  System
  MaxTokens
  Temperature
}

// ---------------------------------------------------------------- 命令

///|
fn fetch_meta(emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @http.get("/api/meta").expect_json(
    emit.map(fn(result) { MetaLoaded(result) }),
  )
}

///|
fn start_run(payload : RunPayload, emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @http.post("/api/runs")
  .with_json(payload)
  .expect_json(emit.map(fn(result) { RunStarted(result) }))
}

///|
fn poll_run(id : String, emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @http.get("/api/runs/" + id).expect_json(
    emit.map(fn(result) { RunProgress(result) }),
  )
}

// ---------------------------------------------------------------- 启动

///|
fn app() -> @rabbita.App {
  @rabbita.new(fn() {
    let (model, emit) = @rabbita.create_state_with_init(
      init=fn(emit) {
        (
          initial_model(),
          @cmd.batch([fetch_meta(emit), fetch_runs(emit), fetch_presets(emit)]),
        )
      },
      update~,
    )
    model.map(fn(model) { view(model, emit) })
  })
}

///|
fn main {
  // 注意：rabbita 的 mount 走的是 document.getElementById(id)，参数是裸 id，
  // 不是 CSS 选择器——传 "#app" 会查不到元素并在 unwrap 处 panic。
  app().mount("app")
}

// ---------------------------------------------------------------- update

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
          let all_cases = meta.cases.map(fn(case) { case.id })
          let wanted_models = split_list(model.query, "models")
          let wanted_cases = split_list(model.query, "cases")
          let models = if wanted_models.length() > 0 {
            meta.models.filter(fn(id) { wanted_models.contains(id) })
          } else {
            meta.models
          }
          let cases = if wanted_cases.length() > 0 {
            all_cases.filter(fn(id) { wanted_cases.contains(id) })
          } else {
            all_cases
          }
          // query 里的参数优先于 meta 的默认值
          let query_prompt = model.query.get("prompt")
          let next = {
            ..model,
            meta: Some(meta),
            meta_error: None,
            selected_models: models,
            selected_cases: cases,
            // meta 带的是默认集的用例，先当当前集用；切集时会重新拉。
            available_cases: meta.cases,
            repeats: int_param(model.query, "repeats", meta.defaults.repeats),
            max_tokens: int_param(
              model.query,
              "maxTokens",
              meta.defaults.maxTokens,
            ),
            temperature: double_param(
              model.query,
              "temperature",
              meta.defaults.temperature,
            ),
            pace_ms: int_param(model.query, "paceMs", meta.defaults.paceMs),
            retry: int_param(model.query, "retry", meta.defaults.retry),
            prompt: match query_prompt {
              Some(text) => text
              None => model.prompt
            },
            use_prompt: query_prompt is Some(_),
            // query 里能指定用例集；否则用服务端的默认集。
            case_set: if model.case_set == "" {
              meta.defaultCaseSet
            } else {
              model.case_set
            },
          }
          let has_key = meta.hasKey || next.api_key != ""
          if next.autorun &&
            !next.selected_models.is_empty() &&
            !next.selected_cases.is_empty() {
            if has_key {
              let payload = RunPayload::of(next)
              (
                { ..next, autorun: false, status: "starting", },
                start_run(payload, emit),
              )
            } else {
              // 没有可用密钥就不自动开跑：跑下去只会撞上鉴权失败，而看到那个
              // 错的人会以为是自己环境坏了。也不做成「填完就自动开跑」——
              // 那样每敲一个字符都会被当成一次触发。
              ({ ..next, autorun: false, autorun_held: true, }, @cmd.none)
            }
          } else {
            (next, @cmd.none)
          }
        }
        Err(error) =>
          ({ ..model, meta_error: Some(error.to_string()), }, @cmd.none)
      }
    ToggleModel(id) =>
      (
        { ..model, selected_models: toggle(model.selected_models, id), },
        @cmd.none,
      )
    ToggleCase(id) =>
      (
        { ..model, selected_cases: toggle(model.selected_cases, id), },
        @cmd.none,
      )
    SelectAllCases =>
      match model.meta {
        Some(meta) =>
          (
            { ..model, selected_cases: meta.cases.map(fn(c) { c.id }), },
            @cmd.none,
          )
        None => (model, @cmd.none)
      }
    UsePrompt(value) => ({ ..model, use_prompt: value, }, @cmd.none)
    PromptChanged(text) => ({ ..model, prompt: text, }, @cmd.none)
    ExtraModelsChanged(text) => ({ ..model, extra_models: text, }, @cmd.none)
    BaseUrlChanged(text) => ({ ..model, base_url: text, }, @cmd.none)
    ApiKeyChanged(text) => ({ ..model, api_key: text, }, @cmd.none)
    CopyMarkdown =>
      ({ ..model, copied: Some(copy_markdown(model)), }, @cmd.none)
    CopyShareLink =>
      ({ ..model, copied: Some(copy_share_link(model)), }, @cmd.none)
    RefreshRuns => (model, fetch_runs(emit))
    RunsLoaded(result) =>
      match result {
        Ok(response) =>
          ({ ..model, runs: Some(response.runs), runs_error: None, }, @cmd.none)
        Err(error) =>
          ({ ..model, runs_error: Some(error.to_string()), }, @cmd.none)
      }
    OpenRun(id) =>
      // 已经是这条就直接忽略，不要白跑一次请求
      match model.viewed {
        Some(viewed) =>
          if viewed.id == id {
            (model, @cmd.none)
          } else {
            (
              { ..model, busy_run: Some(id), runs_error: None, },
              fetch_viewed(id, emit),
            )
          }
        None =>
          (
            { ..model, busy_run: Some(id), runs_error: None, },
            fetch_viewed(id, emit),
          )
      }
    ViewedLoaded(id, result) =>
      match result {
        Ok(status) => {
          let data = match status.data {
            Some(json) =>
              match @shared.parse_page_data_json(json) {
                Ok(data) => Some(data)
                Err(_) => None
              }
            None => None
          }
          let viewed : ViewedRun = {
            id,
            status: status.status,
            data,
            error: status.error,
            tail: status.tail.unwrap_or(""),
          }
          ({ ..model, viewed: Some(viewed), busy_run: None, }, @cmd.none)
        }
        Err(error) =>
          (
            {
              ..model,
              busy_run: None,
              runs_error: Some("打不开 \{id}：" + error.to_string()),
            },
            @cmd.none,
          )
      }
    CloseRun => ({ ..model, viewed: None, }, @cmd.none)
    DeleteRun(id) =>
      if model.busy_run == Some(id) {
        (model, @cmd.none)
      } else {
        ({ ..model, busy_run: Some(id), }, delete_run_cmd(id, emit))
      }
    RunDeleted(id, result) =>
      match result {
        Ok(_) => {
          let viewed = match model.viewed {
            Some(viewed) => if viewed.id == id { None } else { Some(viewed) }
            None => None
          }
          // 删完重新拉一次列表，而不是自己从响应里拼：一份真相就够了，
          // 而这一次请求是本地回环。
          (
            { ..model, busy_run: None, viewed, runs_error: None, },
            fetch_runs(emit),
          )
        }
        Err(error) =>
          (
            { ..model, busy_run: None, runs_error: Some(error.to_string()), },
            @cmd.none,
          )
      }
    Rerun(id) =>
      if model.busy_run == Some(id) {
        (model, @cmd.none)
      } else {
        match find_run(model.runs, id) {
          None => (model, @cmd.none)
          Some(info) => {
            let has_key = match model.meta {
              Some(meta) => meta.hasKey || model.api_key != ""
              None => model.api_key != ""
            }
            if has_key {
              (
                {
                  ..model,
                  // 重跑就是新跑一次：把界面切回「当前这次」，
                  // 否则新运行的进度会顶在历史结果背后，看不到。
                  viewed: None,
                  busy_run: Some(id),
                  run_id: None,
                  status: "starting",
                  error: None,
                  data: None,
                  done: 0,
                  total: 0,
                },
                start_run(rerun_payload(model, info), emit),
              )
            } else {
              (
                {
                  ..model,
                  busy_run: None,
                  runs_error: Some(
                    "重跑需要密钥：服务端环境里没有，页面上也没填。",
                  ),
                },
                @cmd.none,
              )
            }
          }
        }
      }
    ToggleCaseEditor =>
      if model.editing_cases {
        ({ ..model, editing_cases: false, cases_error: None, }, @cmd.none)
      } else {
        // 进编辑态时从当前选中的集现拉一份：available_cases 可能是旧的快照，
        // 而编辑要改的是磁盘上那份。
        (
          {
            ..model,
            editing_cases: true,
            cases_error: None,
            cases_saved: None,
          },
          fetch_case_set(model.case_set, emit),
        )
      }
    SelectCaseSet(name) =>
      (
        { ..model, case_set: name, cases_error: None, cases_saved: None, },
        fetch_case_set(name, emit),
      )
    CaseSetLoaded(name, result) =>
      match result {
        Ok(response) => {
          // 用服务端回显的名字，不是请求里那个：
          // 它才是这份 cases 真正的归属。
          let name = response.name
          let cases = response.cases.map(fn(json) {
            let obj = @shared.as_object(json)
            {
              id: @shared.string_field(obj, "id", ""),
              prompt: @shared.string_field(obj, "prompt", ""),
            }
          })
          let ids = cases.map(fn(case) { case.id })
          let selected = if model.editing_cases {
            model.selected_cases.filter(fn(id) { ids.contains(id) })
          } else {
            // 从下拉切集时默认全选：选一套集的意图就是「跑这套」
            ids
          }
          (
            {
              ..model,
              case_set: name,
              available_cases: cases,
              selected_cases: selected,
              drafts: response.cases.map(fn(json) { CaseDraft::of(json) }),
              cases_error: None,
            },
            @cmd.none,
          )
        }
        Err(error) =>
          (
            {
              ..model,
              cases_error: Some(
                "读不到用例集 \{name}：" + error.to_string(),
              ),
            },
            @cmd.none,
          )
      }
    NewSetNameChanged(text) => ({ ..model, new_set_name: text, }, @cmd.none)
    NewCaseSet => {
      let name = model.new_set_name.trim(chars=" \t\r\n").to_owned()
      if name == "" {
        ({ ..model, cases_error: Some("先给新集起个名字"), }, @cmd.none)
      } else {
        // 另存为：用当前草稿；还没进编辑态就拿当前集的内容铺一份
        let drafts = if model.drafts.length() > 0 {
          model.drafts
        } else {
          model.available_cases.map(fn(case) {
            {
              raw: Json::object({
                "id": Json::string(case.id),
                "prompt": Json::string(case.prompt),
              }),
              id: case.id,
              prompt: case.prompt,
              system: "",
              max_tokens: "",
              temperature: "",
            }
          })
        }
        (
          {
            ..model,
            new_set_name: "",
            cases_error: None,
            cases_saved: Some("正在另存为 \{name}…"),
          },
          save_case_set(name, drafts, emit),
        )
      }
    }
    DeleteCaseSet =>
      if model.case_set == "" {
        (model, @cmd.none)
      } else {
        (
          { ..model, cases_saved: None, },
          delete_case_set_cmd(model.case_set, emit),
        )
      }
    CaseSetSaved(name, result) =>
      match result {
        Ok(_) =>
          (
            {
              ..model,
              case_set: name,
              cases_saved: Some("已保存 \{name}"),
              cases_error: None,
            },
            @cmd.batch([fetch_meta(emit), fetch_case_set(name, emit)]),
          )
        Err(error) =>
          (
            {
              ..model,
              cases_error: Some(error.to_string()),
              cases_saved: None,
            },
            @cmd.none,
          )
      }
    CaseSetDeleted(name, result) =>
      match result {
        Ok(_) =>
          (
            {
              ..model,
              case_set: "",
              drafts: [],
              available_cases: [],
              selected_cases: [],
              cases_saved: Some("已删除 \{name}"),
              cases_error: None,
            },
            fetch_meta(emit),
          )
        Err(error) =>
          ({ ..model, cases_error: Some(error.to_string()), }, @cmd.none)
      }
    SelectNoCases => ({ ..model, selected_cases: [], }, @cmd.none)
    AddDraft => {
      // 不在编辑态点它，就顺手打开：点了没反应比多点一下更难受
      let drafts = model.drafts.copy()
      drafts.push(blank_draft())
      ({ ..model, editing_cases: true, drafts, cases_saved: None, }, @cmd.none)
    }
    RemoveDraft(index) => {
      let kept : Array[CaseDraft] = []
      for i = 0; i < model.drafts.length(); i = i + 1 {
        if i != index {
          kept.push(model.drafts[i])
        }
      }
      ({ ..model, drafts: kept, cases_saved: None, }, @cmd.none)
    }
    DraftFieldChanged(index, field, text) => {
      let drafts = model.drafts.copy()
      if index >= 0 && index < drafts.length() {
        let draft = drafts[index]
        let updated = match field {
          Id => { ..draft, id: text, }
          Prompt => { ..draft, prompt: text, }
          System => { ..draft, system: text, }
          MaxTokens => { ..draft, max_tokens: text, }
          Temperature => { ..draft, temperature: text, }
        }
        drafts[index] = updated
      }
      ({ ..model, drafts, cases_saved: None, }, @cmd.none)
    }
    SaveCases =>
      if model.case_set == "" {
        (
          {
            ..model,
            cases_error: Some(
              "当前没有选中的用例集。先「另存为新集」。",
            ),
          },
          @cmd.none,
        )
      } else {
        match validate_drafts(model.drafts) {
          Some(message) => ({ ..model, cases_error: Some(message), }, @cmd.none)
          None =>
            (
              {
                ..model,
                cases_error: None,
                cases_saved: Some("正在保存…"),
              },
              save_case_set(model.case_set, model.drafts, emit),
            )
        }
      }
    PresetsLoaded(result) =>
      match result {
        Ok(response) =>
          (
            { ..model, presets: Some(response.presets), presets_error: None, },
            @cmd.none,
          )
        Err(error) =>
          ({ ..model, presets_error: Some(error.to_string()), }, @cmd.none)
      }
    PresetsSaved(result) =>
      match result {
        Ok(response) =>
          (
            {
              ..model,
              presets: Some(response.presets),
              presets_error: None,
              preset_name: "",
            },
            @cmd.none,
          )
        Err(error) =>
          ({ ..model, presets_error: Some(error.to_string()), }, @cmd.none)
      }
    PresetNameChanged(text) => ({ ..model, preset_name: text, }, @cmd.none)
    SavePreset => {
      let trimmed = model.preset_name.trim(chars=" \t\r\n").to_owned()
      // 没起名字就用「几个模型 · 哪套用例」拼一个：拒掉不如先存下来
      let name = if trimmed == "" {
        "\{effective_models(model).length()} 模型 · \{model.case_set}"
      } else {
        trimmed
      }
      let preset : Preset = {
        name,
        models: effective_models(model),
        caseSet: if model.case_set == "" {
          None
        } else {
          Some(model.case_set)
        },
        repeats: Some(model.repeats),
        maxTokens: Some(model.max_tokens),
        temperature: Some(model.temperature),
        paceMs: Some(model.pace_ms),
        retry: Some(model.retry),
      }
      // 同名就是覆盖：预设的名字就是它的键
      let kept = match model.presets {
        Some(presets) => presets.filter(fn(item) { item.name != preset.name })
        None => []
      }
      kept.push(preset)
      (
        { ..model, presets_error: None, preset_name: "", },
        save_presets(kept, emit),
      )
    }
    ApplyPreset(name) =>
      match model.presets {
        None => (model, @cmd.none)
        Some(presets) =>
          match presets.filter(fn(item) { item.name == name }) {
            [] => (model, @cmd.none)
            [preset, ..] => {
              // 菜单里的勾上，菜单外的写进手输框：两处都看得见，
              // 不然套用之后就找不到刚套进来的是哪个模型了。
              let known = match model.meta {
                Some(meta) => meta.models
                None => []
              }
              let selected = preset.models.filter(fn(id) { known.contains(id) })
              let extra = preset.models.filter(fn(id) { !known.contains(id) })
              let next = {
                ..model,
                selected_models: selected,
                extra_models: extra.join(","),
                repeats: preset.repeats.unwrap_or(model.repeats),
                max_tokens: preset.maxTokens.unwrap_or(model.max_tokens),
                temperature: preset.temperature.unwrap_or(model.temperature),
                pace_ms: preset.paceMs.unwrap_or(model.pace_ms),
                retry: preset.retry.unwrap_or(model.retry),
              }
              match preset.caseSet {
                Some(set) =>
                  (
                    {
                      ..next,
                      case_set: set,
                      cases_saved: Some("套用了预设 \{name}"),
                    },
                    fetch_case_set(set, emit),
                  )
                None =>
                  (
                    { ..next, cases_saved: Some("套用了预设 \{name}"), },
                    @cmd.none,
                  )
              }
            }
          }
      }
    DeletePreset(name) =>
      match model.presets {
        None => (model, @cmd.none)
        Some(presets) =>
          (
            { ..model, presets_error: None, },
            save_presets(presets.filter(fn(item) { item.name != name }), emit),
          )
      }
    ToggleComparePick(id) =>
      (
        { ..model, compare_picks: toggle_pick(model.compare_picks, id), },
        @cmd.none,
      )
    StartCompare => {
      let picks = model.compare_picks
      if picks.length() != 2 {
        (
          { ..model, runs_error: Some("先勾两次运行，再点对比"), },
          @cmd.none,
        )
      } else {
        match (find_run(model.runs, picks[0]), find_run(model.runs, picks[1])) {
          (Some(left), Some(right)) =>
            (
              {
                ..model,
                // 对比接管结果区：不接管的话，对比表和「当前运行的结果」
                // 会挤在一起，看上去像同一份数据。
                viewed: None,
                compare: Some({
                  a: left.id,
                  b: right.id,
                  data_a: None,
                  data_b: None,
                  request_a: left.request,
                  request_b: right.request,
                  error: None,
                }),
                runs_error: None,
              },
              @cmd.batch([
                fetch_compare_run(left.id, emit),
                fetch_compare_run(right.id, emit),
              ]),
            )
          _ =>
            (
              {
                ..model,
                runs_error: Some(
                  "勾选的那两次里有已经不在列表里的",
                ),
              },
              @cmd.none,
            )
        }
      }
    }
    CompareRunLoaded(id, result) =>
      match model.compare {
        None => (model, @cmd.none)
        Some(state) =>
          match result {
            Ok(status) => {
              let data = match status.data {
                Some(json) =>
                  match @shared.parse_page_data_json(json) {
                    Ok(data) => Some(data)
                    Err(_) => None
                  }
                None => None
              }
              // 失败的运行没有 data.json：不要占着「正在载入」不放，
              // 直接说清楚那一次没有可比的数据。
              let error = if data is None {
                Some(
                  "\{id} 没有结果数据（状态：\{status.status}），那一次比不了",
                )
              } else {
                state.error
              }
              let next = if id == state.a {
                { ..state, data_a: data, error, }
              } else if id == state.b {
                { ..state, data_b: data, error, }
              } else {
                state
              }
              ({ ..model, compare: Some(next), }, @cmd.none)
            }
            Err(error) =>
              (
                {
                  ..model,
                  compare: Some({ ..state, error: Some(error.to_string()), }),
                },
                @cmd.none,
              )
          }
      }
    CloseCompare => ({ ..model, compare: None, compare_picks: [], }, @cmd.none)
    RepeatsChanged(text) =>
      ({ ..model, repeats: clamp_int(text, 1, 20, model.repeats), }, @cmd.none)
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
    PaceChanged(text) =>
      (
        { ..model, pace_ms: clamp_int(text, 0, 60000, model.pace_ms), },
        @cmd.none,
      )
    RetryChanged(text) =>
      ({ ..model, retry: clamp_int(text, 0, 10, model.retry), }, @cmd.none)
    StartRun =>
      // 运行中重复点击直接忽略：按钮不再用 disabled 属性挡（见 action_row）
      if model.status == "running" || model.status == "starting" {
        (model, @cmd.none)
      } else {
        let payload = RunPayload::of(model)
        (
          {
            ..model,
            status: "starting",
            error: None,
            data: None,
            done: 0,
            total: 0,
          },
          start_run(payload, emit),
        )
      }
    RunStarted(result) =>
      match result {
        Ok(response) => {
          let next = {
            ..model,
            run_id: Some(response.id),
            status: "running",
            total: response.total,
            done: 0,
            busy_run: None,
          }
          (next, @rabbita.delay(poll_run(response.id, emit), 400))
        }
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
            tail: status.tail.unwrap_or(""),
            failures: status.failures,
            retried: status.retried,
            truncated: status.truncated,
          }
          let id = match model.run_id {
            Some(id) => id
            None => status.id
          }
          if status.status == "running" {
            (next, @rabbita.delay(poll_run(id, emit), 700))
          } else {
            // 跑完了刷新一次历史：新记录要立刻出现在侧栏里，
            // 而不是等下次打开页面。
            (next, fetch_runs(emit))
          }
        }
        Err(error) =>
          (
            { ..model, status: "failed", error: Some(error.to_string()), },
            @cmd.none,
          )
      }
  }
}

///|
fn toggle(values : Array[String], value : String) -> Array[String] {
  if values.contains(value) {
    values.filter(fn(item) { item != value })
  } else {
    values.push(value)
    values.copy()
  }
}

///|
fn clamp_int(text : String, low : Int, high : Int, fallback : Int) -> Int {
  let value = @string.parse_int(text.trim(chars=" \t").to_owned()) catch {
    _ => fallback
  }
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
  let value = @string.parse_double(text.trim(chars=" \t").to_owned()) catch {
    _ => fallback
  }
  if value < low {
    low
  } else if value > high {
    high
  } else {
    value
  }
}

///|
/// 请求体。字段名与 /api/runs 的约定一致。
struct RunPayload {
  models : Array[String]
  cases : Array[String]
  prompt : String
  /// 这些 case id 从哪套用例里读。空表示用服务端的默认集。
  caseSet : String?
  repeats : Int
  maxTokens : Int
  temperature : Double
  paceMs : Int
  retry : Int
  /// 空表示用服务端环境里的那份。不要发空串——那会把服务端的配置覆盖成空。
  baseUrl : String?
  apiKey : String?
} derive(ToJson)

///|
fn RunPayload::of(model : AppModel) -> RunPayload {
  {
    models: effective_models(model),
    cases: if model.use_prompt {
      []
    } else {
      model.selected_cases
    },
    prompt: if model.use_prompt {
      model.prompt
    } else {
      ""
    },
    caseSet: if model.case_set == "" {
      None
    } else {
      Some(model.case_set)
    },
    repeats: model.repeats,
    maxTokens: model.max_tokens,
    temperature: model.temperature,
    paceMs: model.pace_ms,
    retry: model.retry,
    baseUrl: if model.base_url == "" {
      None
    } else {
      Some(model.base_url)
    },
    apiKey: if model.api_key == "" {
      None
    } else {
      Some(model.api_key)
    },
  }
}

///|
/// 勾选的模型 + 手输的额外模型，去重后就是本次真正要跑的列表。
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

///|
/// 只转义会破坏 query 的字符。`:` `/` 这些在 query 里合法，转了反而难读。
fn percent_encode(text : String) -> String {
  let buf = StringBuilder()
  let n = text.length()
  let mut i = 0
  while i < n {
    let code = text[i].to_int()
    let escape = match code {
      0x20 => Some("%20")
      0x22 => Some("%22")
      0x23 => Some("%23")
      0x25 => Some("%25")
      0x26 => Some("%26")
      0x2B => Some("%2B")
      0x3D => Some("%3D")
      0x3C => Some("%3C")
      0x3E => Some("%3E")
      0x5C => Some("%5C")
      _ => None
    }
    match escape {
      Some(replacement) => buf.write_string(replacement)
      None => buf.write_char(Int::unsafe_to_char(code))
    }
    i = i + 1
  }
  buf.to_string()
}

///|
/// 把当前配置拼回一个可分享的链接。
/// **刻意不含 api_key**——链接是拿去贴的，里面不能带凭证。
fn share_url(model : AppModel) -> String {
  let parts : Array[String] = []
  let models = effective_models(model)
  if models.length() > 0 {
    parts.push("models=" + percent_encode(models.join(",")))
  }
  if model.use_prompt && model.prompt != "" {
    parts.push("prompt=" + percent_encode(model.prompt))
  } else if model.selected_cases.length() > 0 {
    parts.push("cases=" + percent_encode(model.selected_cases.join(",")))
  }
  parts.push("repeats=" + model.repeats.to_string())
  parts.push("maxTokens=" + model.max_tokens.to_string())
  parts.push("temperature=" + model.temperature.to_string())
  parts.push("paceMs=" + model.pace_ms.to_string())
  parts.push("retry=" + model.retry.to_string())
  if model.base_url != "" {
    parts.push("baseUrl=" + percent_encode(model.base_url))
  }
  page_base() + "?" + parts.join("&")
}

///|
/// 复制 Markdown 报告，返回一句给用户看的反馈。
fn copy_markdown(model : AppModel) -> String {
  match model.data {
    None => "还没有结果可复制"
    Some(data) => {
      let text = @shared.results_markdown(data)
      if text == "" {
        "还没有结果可复制"
      } else if copy_text(text) {
        "已复制 Markdown 报告"
      } else {
        "复制失败：浏览器不允许访问剪贴板"
      }
    }
  }
}

///|
fn copy_share_link(model : AppModel) -> String {
  if copy_text(share_url(model)) {
    "已复制分享链接"
  } else {
    "复制失败：浏览器不允许访问剪贴板"
  }
}

// ---------------------------------------------------------------- view

///|
fn view(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  el("div", "app", [
    header(model),
    el("div", "wrap workbench", [
      history_panel(model, emit),
      el("main", "workbench-main", [
        controls(model, emit),
        progress(model),
        result_section(model, emit),
        export_row(model, emit),
      ]),
    ]),
    footer(model),
  ])
}

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
fn header(model : AppModel) -> @html.Html {
  let meta_line = match model.meta {
    Some(meta) =>
      "\{meta.models.length()} 个模型可选 · \{meta.cases.length()} 道用例 · \{meta.baseUrl}"
    None => "正在载入…"
  }
  el("header", "site-header", [
    el("div", "wrap site-header-inner", [
      el("div", "site-logo", [txt("faceoff")]),
      el("div", "site-meta", [txt(meta_line)]),
      // 试跑台是另一页：这边管「管理测试」，那边管「随手试一下」
      @html.a(href="playground.html", class="link-btn", [txt("试跑台 →")]),
    ]),
  ])
}

///|
fn controls(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  match model.meta {
    None =>
      el("section", "hero", [
        @html.h1([txt("模型对比")]),
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
        @html.h1([txt("模型对比")]),
        @html.p([
          txt(
            "勾选或直接填模型、调好参数，点开始。运行在服务端串行执行，进度实时回传。",
          ),
        ]),
        @html.p([
          txt(
            "网关默认用服务端配置；下面填了地址或密钥就只对本次运行生效，密钥只经过本页内存，不落盘。",
          ),
        ]),
        if !meta.hasKey {
          el("p", "failed", [
            txt(
              "服务端没有读到 API key。可以在启动服务端前设好 MOONLLM_API_KEY / OPENAI_API_KEY，也可以直接在下面的 API key 里填一把。",
            ),
          ])
        } else {
          @html.fragment([])
        },
        model_picker(meta, model, emit),
        preset_panel(meta, model, emit),
        case_panel(meta, model, emit),
        prompt_picker(model, emit),
        param_row(model, emit),
        gateway_row(model, emit),
        action_row(model, emit),
        if model.autorun_held {
          el("p", "notice", [
            txt(
              "链接里带了 autorun=1，但眼下没有可用的 API key，所以没有自动开跑——直接跑只会撞上鉴权失败。填好上面的 API key（或确认网关不需要 key）后点「开始评测」。",
            ),
          ])
        } else {
          @html.fragment([])
        },
      ])
  }
}

///|
fn model_picker(
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
    el("legend", "", [txt("模型")]),
    el("div", "picker-items", boxes),
    el("div", "field", [
      @html.label(for_="extra-models", [
        txt(
          "也可以直接填模型 id（逗号分隔，与服务端菜单合并）",
        ),
      ]),
      @html.input(
        input_type=@html.InputType::Text,
        id="extra-models",
        value=model.extra_models,
        placeholder="例如 deepseek-chat,deepseek-reasoner",
        on_input=emit.map(fn(text) { ExtraModelsChanged(text) }),
      ),
    ]),
  ])
}

///|
fn labelled_checkbox(
  id_ : String,
  label : String,
  checked : Bool,
  on_change : @cmd.Emit[String],
) -> @html.Html {
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
/// 临时指令：勾上就只跑这一条，忽略上面的用例勾选。
fn prompt_picker(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  el("fieldset", "picker", [
    el("legend", "", [txt("临时指令")]),
    @html.label(for_="use-prompt", class="check", [
      @html.input(
        input_type=@html.InputType::Checkbox,
        id="use-prompt",
        checked=model.use_prompt,
        on_change=emit.map(fn(_value) { UsePrompt(!model.use_prompt) }),
      ),
      txt("只用下面这一条指令"),
    ]),
    @html.input(
      input_type=@html.InputType::Text,
      id="prompt",
      class="prompt-input",
      value=model.prompt,
      placeholder="例如：用一句话说明什么是航空母舰",
      on_input=emit.map(fn(text) { PromptChanged(text) }),
    ),
  ])
}

///|
fn param_row(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  el("div", "params", [
    number_field(
      "repeats",
      "重复次数",
      model.repeats.to_string(),
      emit.map(fn(text) { RepeatsChanged(text) }),
    ),
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
    number_field(
      "pace-ms",
      "间隔 ms",
      model.pace_ms.to_string(),
      emit.map(fn(text) { PaceChanged(text) }),
    ),
    number_field(
      "retry",
      "重试次数",
      model.retry.to_string(),
      emit.map(fn(text) { RetryChanged(text) }),
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
  el("div", "field", [
    @html.label(for_=id_, [txt(label)]),
    @html.input(input_type=@html.InputType::Text, id=id_, value~, on_input~),
  ])
}

///|
fn action_row(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  let running = model.status == "running" || model.status == "starting"
  let total = effective_models(model).length() *
    (if model.use_prompt { 1 } else { model.selected_cases.length() }) *
    model.repeats
  el("div", "actions", [
    // 刻意不用 `disabled` 属性：从「忙」切回「闲」时 Rabbita 的 vdom diff
    // 没把 disabled 摘掉（实测跑完一次后 DOM 里仍是
    // `<button class="primary" disabled="">开始评测</button>`），
    // 结果不刷新页面就再也点不动。改由 class 表达忙闲，重复点击在 update 里挡。
    @html.button(
      class=if running { "primary busy" } else { "primary" },
      on_click=emit(Msg::StartRun),
      [txt(if running { "运行中…" } else { "开始评测" })],
    ),
    el("span", "hint", [txt("约 \{total} 次请求")]),
  ])
}

///|
/// 网关覆盖项。留空就用服务端环境里的那份；填了只对本次运行生效。
fn gateway_row(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  let base_hint = match model.meta {
    Some(meta) => "留空用服务端的：" + meta.baseUrl
    None => ""
  }
  let key_hint = match model.meta {
    Some(meta) =>
      if meta.hasKey {
        "留空用服务端已配置的密钥"
      } else {
        "服务端没配密钥；留空表示不带 key"
      }
    None => ""
  }
  el("div", "params gateway-row", [
    el("div", "field", [
      @html.label(for_="base-url", [txt("网关地址")]),
      @html.input(
        input_type=@html.InputType::Text,
        id="base-url",
        value=model.base_url,
        placeholder=base_hint,
        on_input=emit.map(fn(text) { BaseUrlChanged(text) }),
      ),
    ]),
    el("div", "field", [
      @html.label(for_="api-key", [txt("API key")]),
      // type=password：不让人从截屏里读走；也不回显服务端已有的那把。
      @html.input(
        input_type=@html.InputType::Password,
        id="api-key",
        value=model.api_key,
        placeholder=key_hint,
        on_input=emit.map(fn(text) { ApiKeyChanged(text) }),
      ),
    ]),
  ])
}

///|
/// 结果导出。前三个是纯下载链接（交给浏览器），后两个要写剪贴板。
fn export_row(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  // 在看历史运行的时候，导出跟着历史走：那才是屏幕上这份数据的来源。
  let target = match model.viewed {
    Some(viewed) => Some(viewed.id)
    None => model.run_id
  }
  match target {
    None => @html.fragment([])
    Some(id) => {
      let base = "/api/runs/" + id
      el("div", "actions export-row", [
        el("span", "hint", [txt("导出：")]),
        @html.button(class="ghost", on_click=emit(Msg::CopyMarkdown), [
          txt("复制 Markdown 报告"),
        ]),
        @html.button(class="ghost", on_click=emit(Msg::CopyShareLink), [
          txt("复制分享链接"),
        ]),
        @html.a(href=base + "/runs.jsonl", download="runs.jsonl", [
          txt("下载 runs.jsonl"),
        ]),
        @html.a(href=base + "/data.json", download="data.json", [
          txt("下载 data.json"),
        ]),
        @html.a(href=base + "/report.html", download="report.html", [
          txt("下载静态报告"),
        ]),
        match model.copied {
          Some(text) => el("span", "hint copied", [txt(text)])
          None => @html.fragment([])
        },
      ])
    }
  }
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
    @html.node("div", @html.Attrs::build().class("progress-bar"), [
      @html.node(
        "div",
        @html.Attrs::build()
        .class("progress-fill")
        .style("width", "\{percent}%"),
        ([] : Array[@html.Html]),
      ),
    ]),
    el("div", "progress-counts", [
      txt(
        "失败 \{model.failures} · 重试 \{model.retried} · 截断 \{model.truncated}",
      ),
    ]),
    if model.tail == "" {
      @html.fragment([])
    } else {
      el("details", "log-tail", [
        el("summary", "", [txt("实时日志尾部（stderr）")]),
        @html.pre([txt(model.tail)]),
      ])
    },
    match model.error {
      Some(error) => @html.pre([txt(error)])
      None => @html.fragment([])
    },
  ])
}

///|
fn status_label(status : String) -> String {
  match status {
    "starting" => "提交中"
    "running" => "运行中"
    "done" => "已完成"
    "failed" => "失败"
    _ => status
  }
}

///|
fn result_section(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  match model.compare {
    // 对比接管结果区：两份数据并排，而不是和当前运行的结果叠在一起
    Some(state) => compare_view(state, emit)
    None =>
      match model.viewed {
        Some(viewed) =>
          @html.fragment([
            viewed_banner(viewed, emit),
            match viewed.data {
              Some(data) => @shared.results_section(data)
              // 失败的运行没有 data.json，只有 stderr 尾巴：把那个拿出来，
              // 总比一片空白强。
              None =>
                el("section", "progress-card", [
                  el("div", "progress-head", [
                    txt(
                      "这次运行没有结果数据（状态：\{viewed.status}）",
                    ),
                  ]),
                  match viewed.error {
                    Some(message) => @html.pre([txt(message)])
                    None =>
                      if viewed.tail == "" {
                        @html.fragment([])
                      } else {
                        @html.pre([txt(viewed.tail)])
                      }
                  },
                ])
            },
          ])
        None =>
          match model.data {
            Some(data) => @shared.results_section(data)
            None => @html.fragment([])
          }
      }
  }
}

///|
fn footer(model : AppModel) -> @html.Html {
  let source = match model.data {
    Some(data) => if data.source == "" { "本次运行" } else { data.source }
    None => "—"
  }
  el("footer", "site-footer", [
    el("div", "wrap", [
      txt("数据来源 \{source}"),
      @html.br(),
      txt(
        "页面由 Rabbita 驱动，样式由 precss 从 styles/site.scss 编译。",
      ),
    ]),
  ])
}

///|
pub extend CaseInfo with Eq::{equal, not_equal}

///|
pub extend Defaults with Eq::{equal, not_equal}

///|
pub extend Meta with Eq::{equal, not_equal}

///|
pub extend RunStatus with Eq::{equal, not_equal}

///|
pub extend AppModel with Eq::{equal, not_equal}
