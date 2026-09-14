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
  /// 服务端配置里的默认 system（MOONLLM_SYSTEM）。页面打开时用它预填。
  system : String?
} derive(Eq, FromJson)

///|
struct Meta {
  models : Array[String]
  cases : Array[CaseInfo]
  /// 测试集列表（round 3 的切换器用它；现在只需要知道名字与条数）。
  caseSets : Array[CaseSetInfo]
  defaultCaseSet : String
  defaults : Defaults
  hasKey : Bool
  baseUrl : String
  /// 网关地址是配的还是没有。可选：服务端版本比页面旧时不至于让整个页面解不开
  baseUrlConfigured : Bool?
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
  /// 服务端转发的最后一条进度事件，以及它有多旧。
  live : Json?
  liveAgeMs : Double?
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

///|
/// 把「正在看的那次运行」写进地址栏的 query（`?run=<id>`），空串 = 清掉。
///
/// 用 query 而不是 hash：hash 的改动属于同文档导航，浏览器不会重新加载页面，
/// 于是「手动把地址栏里的 id 改成另一条」不会生效（页面还是原来那条）。query
/// 一改就是一次真正的导航，重载之后按新的 id 走；而这里写地址用
/// `history.replaceState`，所以自己点开一条运行不会触发重载
extern "js" fn set_run_param(id : String) -> Unit = "(id) => { try { const url = new URL(window.location.href); if (id) { url.searchParams.set('run', id) } else { url.searchParams.delete('run') } history.replaceState(null, '', url.toString()) } catch (e) {} }"

///|
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
  repeats : Int
  max_tokens : Int
  temperature : Double
  pace_ms : Int
  retry : Int
  /// 「打不开某次运行」的错误。和 runs_error 分开：列表拉取成功不能把
  /// 「这次运行不存在」这句话抹掉——它们同时发生（打开 + 刷新列表）
  viewed_error : String?
  /// 已经点过一次「删除」、正在等第二次确认的那条运行。
  confirm_delete : String?
  /// 打开页面时要从 hash 里恢复的那条运行（恢复过就清掉，只做一次）。
  pending_run : String?
  /// 「从文本文件建测试集」的路径输入（服务端上的路径，服务端去读）。
  /// 「这次跑什么」面板开在哪一页：set（测试集）/ prompt（临时提示词）。
  /// 只是视图状态——真正决定跑什么的是上面那个输入框里有没有内容。
  panel_tab : String
  /// 本次运行的 system prompt：所有用例共用。用例自带的会覆盖它。
  system : String
  /// 勾上就让上面那条 system 覆盖测试集里逐条写的 system
  system_override : Bool
  /// 这些模型带 enable_thinking: true
  cot_thinking : Array[String]
  /// 这些模型带 reasoning_effort: "high"
  cot_effort : Array[String]
  /// 并发方式：serial（默认）/ models（按模型并行）/ all（全部并发）
  parallel : String
  /// 刚套用过预设：把受影响的输入框框起来，直到用户自己改任意一个字段
  preset_applied : Bool
  /// 「查看更多」的历史弹窗开着没有
  history_open : Bool
  /// 弹窗里已经铺出多少条（第一步 50，之后每次 +30）
  history_shown : Int
  /// 「从文本文件生成新测试集」：桥接字段的原始 JSON（JS 写完派发 input）
  import_payload : String
  /// 刚从文件对话框里选中的文件名（用来给新集取默认名字）
  import_file_name : String
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
  /// 手输框里正在打的那串（还没按「识别」）
  extra_models : String
  /// 按过「识别」的候选模型：和菜单合并渲染成 checkbox，选不选看 selected_models
  custom_models : Array[String]
  /// 页面覆盖的网关地址。空串表示用服务端环境里的那份。
  base_url : String
  /// 页面覆盖的网关密钥。空串表示用服务端环境里的那份。
  /// 只活在页面内存里：不进 URL、不进 localStorage、也不写进请求的存档。
  api_key : String
  /// 上一次复制操作的反馈文字。
  copied : String?
  /// 当前选的测试集（来自 meta.defaultCaseSet 或 ?caseSet=）。
  case_set : String
  /// 运行历史（`GET /api/runs`）。None = 还没拉到。
  runs : Array[RunInfo]?
  runs_error : String?
  /// 当前测试集里的用例。选中集、编辑保存之后会变，所以不能每次去读 meta。
  available_cases : Array[CaseInfo]
  /// 用例编辑态：草稿 + 反馈。
  editing_cases : Bool
  // 用例勾选区默认只露两行（行数一多就是整页最吵的地方）
  cases_expanded : Bool
  drafts : Array[CaseDraft]
  cases_error : String?
  cases_saved : String?
  /// 「另存为新集」的输入框。
  new_set_name : String
  /// 「按行导入」的文本框与反馈。
  import_text : String
  import_note : String?
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
  /// 这条运行的人工标注（从 /api/runs/<id>/annotations 拿）。
  annotations : Array[@shared.Annotation]
  annotations_error : String?
  /// 正在编辑哪一条答案的备注（"case\u0000model"），以及草稿。
  note_key : String?
  note_draft : String
  /// 正在删/正在重跑的 id：同一条上重复点击直接忽略（按钮不用 disabled，
  /// VDOM 从忙到闲不会把那个属性摘掉——见 action_row）。
  busy_run : String?
  /// 运行中的实时信息：日志尾 + 失败/重试/截断计数。
  tail : String
  /// 当下这条请求的实时进度（哪条、多快、多久没有输出了）。
  live : @shared.LiveProgress?
  /// 请求上下文对话框：Some(用例 id) 时开着，带那次运行的上下文文档。
  context_case : String?
  context : @shared.RunContext?
  /// 缓存里的那份上下文属于哪次运行。只判断「有没有缓存」是不够的：它会在两次
  /// 运行之间串——看着 DeepSeek 的结果，弹出来的却是上一次 MiniCPM 的参数
  context_for : String
  context_error : String?
  /// 结果看哪个分位：p10 / p20 / p50 / p99。P50 是默认——「通常有多快」是多数
  /// 时候要问的问题，尾部（P99）是另一类问题（会不会偶发地卡住）。
  percentile : String
  /// 结果区怎么摆：stacked（每个模型一条）/ columns（并排）/ diff（差异）。
  /// 长回答竖着堆下来是没法比的——1B 写 1100 字、2B 写 700 字，读完第一段
  /// 就找不回第二段在哪。
  results_mode : String
  failures : Int
  retried : Int
  truncated : Int
} derive(Eq)

///|
/// 导入文本文件时新建的那个集叫什么：优先用手填的「新集名字」，否则用文件名
/// （去掉目录与扩展名，把不适合出现在文件名里的字符换掉）。
/// 集名就是文件名，服务端只收 [A-Za-z0-9._-]，长度 1-64。这里先按同一套判一遍，
/// 好在页面上说清楚为什么不行（不然用户只会看到一个没头没脑的 400）
fn is_usable_set_name(name : String) -> Bool {
  if name.length() == 0 || name.length() > 64 {
    return false
  }
  for ch in name {
    let ok = (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '.' ||
      ch == '_' ||
      ch == '-'
    if !ok {
      return false
    }
  }
  true
}

///|
/// 同时最多对比几个模型。
///
/// 不是拍脑袋定的：勾到第三个的时候，那三列的并排对比已经读不动了，而这份页面的
/// 用处正是「同一道题，两个模型差在哪」。超出来的由 ToggleModel 自动挤掉最早的
/// 那个（手输的 extra_models 绕不过去，那条由 run_issues 拦）
let max_models : Int = 2

///|
fn toggle_model(model : AppModel, id : String) -> AppModel {
  let next = toggle(model.selected_models, id)
  if next.length() <= max_models {
    return { ..model, preset_applied: false, selected_models: next, }
  }
  // 勾满之后再勾一个新的：把最早那个摘掉（数组是按点击顺序追加的）。
  // 用户看到的是「勾第三个，第一个自己弹掉」——这比默默拒绝更好懂。
  //
  // 起点是「长度 - max_models」（保留最后 max_models 个），不是直接从下标
  // max_models 开始：后者在队列长 3 时只会留下 1 个（把最早两个一起弹掉）
  let kept : Array[String] = []
  let start = next.length() - max_models
  for i = start; i < next.length(); i = i + 1 {
    kept.push(next[i])
  }
  { ..model, preset_applied: false, selected_models: kept, }
}

///|
fn import_set_name(model : AppModel) -> String {
  let typed = model.new_set_name.trim(chars=" \t\r\n").to_owned()
  if typed != "" {
    return typed
  }
  // 名字来自文件对话框选中的那个文件名（原来读的是手填的路径，现在没有那个框了）
  let path = model.import_file_name.trim(chars=" \t\r\n").to_owned()
  if path == "" {
    return ""
  }
  // 只取文件名那一段：按 `/` 切开，最后一段是非空的
  let mut base = ""
  for part in path.split("/") {
    if part != "" {
      base = part.to_owned()
    }
  }
  // 去掉扩展名：点号切开，第一段就是主体
  let mut stem = base
  for part in base.split(".") {
    stem = part.to_owned()
    break
  }
  // 集名会变成文件名：只留字母数字、连字符、下划线和非 ASCII（中文等），
  // 其余换成连字符。服务端也会校验，但让用户在这里就得到个能用的名字更好。
  let out = StringBuilder()
  for ch in stem {
    let code = ch.to_int()
    let safe = code >= 0x80 ||
      (code >= 0x30 && code <= 0x39) ||
      (code >= 0x41 && code <= 0x5A) ||
      (code >= 0x61 && code <= 0x7A) ||
      ch == '-' ||
      ch == '_'
    out.write_char(if safe { ch } else { '-' })
  }
  out.to_string().trim(chars="-.\t\r\n").to_owned()
}

///|
/// 保存/导入接口返回里的集名。
fn json_name(json : Json) -> String {
  match json {
    Object(fields) =>
      match fields.get("name") {
        Some(String(name)) => name
        _ => ""
      }
    _ => ""
  }
}

///|
/// 地址栏 query 里的那次运行：`?run=<id>`。
fn query_run_id(query : Map[String, String]) -> String? {
  match query.get("run") {
    Some(id) => if id == "" { None } else { Some(id) }
    None => None
  }
}

///|
/// 这次跑「临时提示词」还是跑测试集。
///
/// 没有开关：输入框里填了非空内容就是前者。多一个勾选框的代价是——用户填了
/// 一条 prompt、忘了勾那个框，然后对着 33 道测试题的结果发愣。
fn AppModel::uses_prompt(self : AppModel) -> Bool {
  self.prompt.trim(chars=" \t\r\n") != ""
}

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
    repeats: 3,
    max_tokens: 2048,
    temperature: 0.0,
    pace_ms: 3000,
    retry: 3,
    system: query.get("system").unwrap_or(""),
    system_override: query.get("systemOverride") == Some("1"),
    cot_thinking: query_list(query, "cotThinking"),
    cot_effort: query_list(query, "cotEffort"),
    parallel: query.get("parallel").unwrap_or("serial"),
    preset_applied: false,
    history_open: false,
    history_shown: 0,
    import_payload: "",
    import_file_name: "",
    viewed_error: None,
    confirm_delete: None,
    pending_run: query_run_id(query),
    panel_tab: if query.get("prompt") is Some(_) {
      "prompt"
    } else {
      "set"
    },
    run_id: None,
    status: "idle",
    done: 0,
    total: 0,
    data: None,
    error: None,
    extra_models: "",
    custom_models: [],
    base_url: query.get("baseUrl").unwrap_or(""),
    api_key: "",
    copied: None,
    case_set: query.get("caseSet").unwrap_or(""),
    available_cases: [],
    editing_cases: false,
    cases_expanded: false,
    drafts: [],
    cases_error: None,
    cases_saved: None,
    new_set_name: "",
    import_text: "",
    import_note: None,
    presets: None,
    presets_error: None,
    preset_name: "",
    compare_picks: [],
    compare: None,
    tail: "",
    live: None,
    context_case: None,
    context: None,
    context_for: "",
    context_error: None,
    percentile: "p50",
    results_mode: "stacked",
    failures: 0,
    retried: 0,
    truncated: 0,
    runs: None,
    runs_error: None,
    viewed: None,
    annotations: [],
    annotations_error: None,
    note_key: None,
    note_draft: "",
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
  PromptChanged(String)
  RepeatsChanged(String)
  SystemChanged(String)
  ToggleSystemOverride
  ToggleCotThinking(String)
  ToggleCotEffort(String)
  // 整列操作：①（enable_thinking）全选 / ②（reasoning_effort）全选 / 全不选
  CotThinkingAll
  CotEffortAll
  CotClear
  SetParallel(String)
  SetPanelTab(String)
  PickImportFile
  ImportFilePicked(String)
  Spot(String)
  CaseFileImported(Result[Json, Error])
  MaxTokensChanged(String)
  TemperatureChanged(String)
  PaceChanged(String)
  RetryChanged(String)
  StartRun
  RunStarted(Result[StartResponse, Error])
  RunProgress(Result[RunStatus, Error])
  ExtraModelsChanged(String)
  AddExtraModels
  BaseUrlChanged(String)
  ApiKeyChanged(String)
  CopyMarkdown
  CopyShareLink
  RefreshRuns
  OpenHistory
  CloseHistory
  LoadMoreHistory
  RunsLoaded(Result[RunsResponse, Error])
  OpenRun(String)
  ViewedLoaded(String, Result[RunStatus, Error])
  CloseRun
  DeleteRun(String)
  CancelDeleteRun
  RunDeleted(String, Result[Json, Error])
  Rerun(String)
  // 测试集
  ToggleCaseEditor
  ToggleCaseList
  SelectCaseSet(String)
  CaseSetLoaded(String, Result[CaseSetResponse, Error])
  NewSetNameChanged(String)
  NewCaseSet
  DeleteCaseSet
  SelectNoCases
  AddDraft
  RemoveDraft(Int)
  SetResultsMode(String)
  SetPercentile(String)
  // 请求上下文
  OpenContext(String)
  CloseContext
  ContextLoaded(String, Result[Json, Error])
  ImportTextChanged(String)
  ImportLines(Bool)
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
  // 人工标注
  AnnotationsLoaded(String, Result[@shared.AnnotationResponse, Error])
  SetVerdict(String, String, String)
  NoteChanged(String, String, String)
  SaveNote(String)
  AnnotationsSaved(Result[Json, Error])
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
        let model = initial_model()
        // 地址栏 hash 里带着一条运行（#run=xxx）就直接打开它：刷新、把链接发给
        // 别人、或者从浏览器历史里退回来，都会走到这里。id 不存在时那次请求会
        // 404，页面按「找不到这次运行」处理。
        // meta 一定要拉：表单、测试集、预设都靠它。第一版这里按「有没有
        // #run=<id>」分了两条路，带 id 那条漏了 fetch_meta——于是地址栏里有
        // run id 时页面永远停在「正在载入配置…」，侧栏（那时还得靠 meta 才
        // 渲染）跟着不出现，两列网格塌成一列
        let commands : Array[@cmd.Cmd] = [
          fetch_meta(emit),
          fetch_runs(emit),
          fetch_presets(emit),
        ]
        match model.pending_run {
          Some(id) => commands.push(fetch_viewed(id, emit))
          None => ()
        }
        ({ ..model, pending_run: None, }, @cmd.batch(commands))
      },
      update~,
    )
    model.map(fn(model) { view(model, emit) })
  })
}

///|
fn main {
  // 挂名字（data-name）供人 / 工具定位元素：Rabbita 没有公开的任意属性入口，
  // 所以这层名字在 DOM 上补，与渲染、状态都无关。放在 mount 之前与之后都行，
  // 它自己会等 body 就绪、并用 MutationObserver 跟上重渲染
  deploy_data_names()
  // 弹窗打开时锁住背后那页的滚动。同样用 MutationObserver 看 DOM，
  // 弹窗将来多一个也自动适用
  install_scroll_lock()
  // 模型输入框里按回车 = 点「识别」（Rabbita 的 input 没有 on_keydown，见该文件）
  install_enter_to_identify()
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
            // query 里的优先（分享链接），其次服务端的默认（LLM_WEB_SYSTEM），
            // 都没有就是空——空表示这次运行不带 system。
            system: match model.query.get("system") {
              Some(text) => text
              None =>
                match meta.defaults.system {
                  Some(text) => text
                  None => model.system
                }
            },
            retry: int_param(model.query, "retry", meta.defaults.retry),
            prompt: match query_prompt {
              Some(text) => text
              None => model.prompt
            },
            // query 里能指定测试集；否则用服务端的默认集。
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
    ToggleModel(id) => (toggle_model(model, id), @cmd.none)
    ToggleCase(id) =>
      (
        {
          ..model,
          preset_applied: false,
          selected_cases: toggle(model.selected_cases, id),
        },
        @cmd.none,
      )
    // 全选勾的是**当前这套**用例。以前取的是 meta.cases（默认那套），于是
    // 切到别的测试集之后，全选勾上一批别的集的 id——面板上什么都没变，
    // 跑起来还会「一道都没选中」
    SelectAllCases =>
      (
        {
          ..model,
          preset_applied: false,
          selected_cases: model.available_cases.map(fn(c) { c.id }),
        },
        @cmd.none,
      )
    // 只改文本，不动面板：跑什么是由「内容空不空」决定的（uses_prompt），
    // 而不是由用户在看哪一页决定的。以前这里会在清空时把面板切回测试集，
    // 于是编辑的一瞬间用户被拽到另一页去
    PromptChanged(text) => ({ ..model, prompt: text, }, @cmd.none)
    ExtraModelsChanged(text) =>
      ({ ..model, preset_applied: false, extra_models: text, }, @cmd.none)
    // 「识别」：把输入框里那串（逗号或换行分隔）变成候选，然后清空输入框。
    // 不自动勾选——跑哪两个由用户自己点，上限由 toggle_model 管
    AddExtraModels => {
      let known = match model.meta {
        Some(meta) => meta.models
        None => []
      }
      let next : Array[String] = []
      for id in model.custom_models {
        next.push(id)
      }
      let normalized = model.extra_models.replace_all(old="\n", new=",")
      for piece in normalized.split(",") {
        let clean = piece.trim(chars=" \t\r").to_owned()
        if clean != "" && !known.contains(clean) && !next.contains(clean) {
          next.push(clean)
        }
      }
      (
        {
          ..model,
          custom_models: next,
          extra_models: "",
          preset_applied: false,
        },
        @cmd.none,
      )
    }
    BaseUrlChanged(text) => ({ ..model, base_url: text, }, @cmd.none)
    ApiKeyChanged(text) => ({ ..model, api_key: text, }, @cmd.none)
    CopyMarkdown =>
      ({ ..model, copied: Some(copy_markdown(model)), }, @cmd.none)
    CopyShareLink =>
      ({ ..model, copied: Some(copy_share_link(model)), }, @cmd.none)
    OpenHistory => {
      // 打开时先铺第一步；并把「正在看的那条」滚到第 8 格附近，
      // 让用户能同时看到它上下的记录（纯视觉，交给 DOM 上的小脚本）
      let first = history_first_page
      // 目标 = 正在看的那条（没有就看最新的）：把它放到第 8 格附近
      let target = match (model.runs, model.viewed) {
        (Some(runs), Some(viewed)) => {
          let mut found = 0
          for i = 0; i < runs.length() && i < first; i = i + 1 {
            if runs[i].id == viewed.id {
              found = i
            }
          }
          found
        }
        _ => 0
      }
      pin_history_slot(target, history_slot)
      ({ ..model, history_open: true, history_shown: first, }, @cmd.none)
    }
    CloseHistory => ({ ..model, history_open: false, }, @cmd.none)
    LoadMoreHistory => {
      let next = model.history_shown + history_more_page
      let shown = match model.runs {
        Some(runs) => if next > runs.length() { runs.length() } else { next }
        None => next
      }
      ({ ..model, history_shown: shown, }, @cmd.none)
    }
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
        // 还在跑的那次运行**不是**「历史运行」：它就该是当前运行
        //
        // 不这么分辨的话，跑着的时候刷新一下，页面会把自己当成在看一份只读历史：
        // 进度卡不见（换成一大段原始日志尾），开始按钮也能再点一次——又开一炉
        Ok(status) if status.status == "running" =>
          (
            {
              ..model,
              run_id: Some(id),
              status: "running",
              done: status.done,
              total: status.total,
              failures: status.failures,
              retried: status.retried,
              truncated: status.truncated,
              viewed: None,
              viewed_error: None,
              busy_run: None,
            },
            @cmd.batch([
              // 写进地址栏：刷新之后还能回到这次运行
              @cmd.effect(fn() { set_run_param(id) }),
              // 接着用「当前运行」的轮询：跑完它会自己刷结果、解锁按钮
              @rabbita.delay(poll_run(id, emit), 400),
            ]),
          )
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
            live: @shared.parse_live(status.live, status.liveAgeMs),
          }
          // 换了一条运行才把上下文作废；同一条的重复加载（轮询、刷新列表）不动它
          let same = match model.viewed {
            Some(previous) => previous.id == id
            None => false
          }
          (
            {
              ..model,
              viewed: Some(viewed),
              busy_run: None,
              viewed_error: None,
              context: if same {
                model.context
              } else {
                None
              },
              context_case: if same {
                model.context_case
              } else {
                None
              },
              context_error: if same {
                model.context_error
              } else {
                None
              },
              // 缓存跟着运行走：换了一条就得忘掉，否则 OpenContext 会拿旧的用
              context_for: if same {
                model.context_for
              } else {
                ""
              },
            },
            @cmd.batch([
              // 历史运行的标注也要拉：它存在那次运行的目录里，不在当前这次里
              fetch_annotations(id, emit),
              // 写进 hash：刷新之后还能回到这一条，也能把链接发给别人
              @cmd.effect(fn() { set_run_param(id) }),
            ]),
          )
        }
        Err(_) =>
          (
            {
              ..model,
              busy_run: None,
              viewed: None,
              // 人话优先：浏览器给的 "Request error, HTTP 404 OK" 对用户没有意义
              viewed_error: Some(
                "找不到这次运行（\{id}），它可能已经被删掉了",
              ),
            },
            @cmd.none,
          )
      }
    CloseRun =>
      (
        { ..model, viewed: None, viewed_error: None, },
        @cmd.effect(fn() { set_run_param("") }),
      )
    // 删除要按两次：第一次只把按钮变成「确认删除」，第二次才真的删。
    DeleteRun(id) =>
      if model.busy_run == Some(id) {
        (model, @cmd.none)
      } else if model.confirm_delete == Some(id) {
        (
          { ..model, busy_run: Some(id), confirm_delete: None, },
          delete_run_cmd(id, emit),
        )
      } else {
        ({ ..model, confirm_delete: Some(id), runs_error: None, }, @cmd.none)
      }
    CancelDeleteRun => ({ ..model, confirm_delete: None, }, @cmd.none)
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
                    "重跑需要密钥：服务端环境里没有，页面上也没填",
                  ),
                },
                @cmd.none,
              )
            }
          }
        }
      }
    ToggleCaseList =>
      ({ ..model, cases_expanded: !model.cases_expanded, }, @cmd.none)
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
        {
          ..model,
          preset_applied: false,
          case_set: name,
          cases_error: None,
          cases_saved: None,
        },
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
                "读不到测试集 \{name}：" + error.to_string(),
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
    SelectNoCases =>
      ({ ..model, preset_applied: false, selected_cases: [], }, @cmd.none)
    AddDraft => {
      // 不在编辑态点它，就顺手打开：点了没反应比多点一下更难受
      let drafts = model.drafts.copy()
      drafts.push(blank_draft())
      ({ ..model, editing_cases: true, drafts, cases_saved: None, }, @cmd.none)
    }
    SetResultsMode(mode) => ({ ..model, results_mode: mode, }, @cmd.none)
    SetPercentile(which) => ({ ..model, percentile: which, }, @cmd.none)
    OpenContext(case_id) => {
      let run_id = model.context_run_id()
      (
        {
          ..model,
          context_case: Some(case_id),
          context_error: None,
          // 缓存只对同一次运行有效：换了一次运行还留着旧的，弹出来的就是
          // 上一次的参数与用例
          context: if model.context_for == run_id {
            model.context
          } else {
            None
          },
        },
        if model.context_for == run_id && model.context is Some(_) {
          @cmd.none
        } else {
          fetch_context(run_id, emit)
        },
      )
    }
    CloseContext => ({ ..model, context_case: None, }, @cmd.none)
    ContextLoaded(id, result) =>
      match result {
        Ok(json) =>
          match @shared.parse_run_context(json) {
            Ok(context) =>
              (
                {
                  ..model,
                  context: Some(context),
                  context_for: id,
                  context_error: None,
                },
                @cmd.none,
              )
            Err(message) =>
              ({ ..model, context_error: Some(message), }, @cmd.none)
          }
        Err(error) =>
          (
            {
              ..model,
              context_error: Some(
                "拿不到请求上下文：" + error.to_string(),
              ),
            },
            @cmd.none,
          )
      }
    ImportTextChanged(text) => ({ ..model, import_text: text, }, @cmd.none)
    ImportLines(replace) => {
      // 上限按「已有 + 新导入」算：测试集那边也有 500 的上限
      let existing = if replace {
        0
      } else {
        model.drafts
        .filter(fn(draft) { draft.prompt.trim(chars=" \t\r\n") != "" })
        .length()
      }
      let room = max_cases_per_set - existing
      let (imported, skipped) = drafts_from_lines(model.import_text, room)
      if imported.length() == 0 {
        (
          {
            ..model,
            import_note: Some(
              if skipped > 0 {
                "已经有 \{model.drafts.length()} 条，到上限了"
              } else {
                "没有可导入的行（空行与 # 注释会跳过）"
              },
            ),
          },
          @cmd.none,
        )
      } else {
        let drafts = if replace {
          []
        } else {
          model.drafts.filter(fn(draft) {
            draft.prompt.trim(chars=" \t\r\n") != ""
          })
        }
        for draft in imported {
          drafts.push(draft)
        }
        let note = if skipped > 0 {
          "导入了 \{imported.length()} 条（另有 \{skipped} 行超出上限被丢掉）"
        } else {
          "导入了 \{imported.length()} 条"
        }
        (
          {
            ..model,
            editing_cases: true,
            drafts,
            import_text: "",
            import_note: Some(note),
            cases_saved: None,
          },
          @cmd.none,
        )
      }
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
              "当前没有选中的测试集。先「另存为新集」",
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
        // system 一起存：它和「模型 + 参数」是同一层的东西，而它最容易忘
        system: if model.system == "" {
          None
        } else {
          Some(model.system)
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
                preset_applied: true,
                selected_models: selected,
                custom_models: extra,
                extra_models: "",
                system: preset.system.unwrap_or(model.system),
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
    AnnotationsLoaded(_id, result) =>
      match result {
        Ok(response) =>
          (
            {
              ..model,
              annotations: response.annotations,
              annotations_error: None,
            },
            @cmd.none,
          )
        Err(error) =>
          ({ ..model, annotations_error: Some(error.to_string()), }, @cmd.none)
      }
    SetVerdict(case_id, answer_model, verdict) => {
      // 这一轮运行的 id：优先看当前正在读的那次（历史），否则当前运行
      let run_id = match model.viewed {
        Some(viewed) => Some(viewed.id)
        None => model.run_id
      }
      match run_id {
        None => (model, @cmd.none)
        Some(id) => {
          let next = set_annotation(
            model.annotations,
            case_id,
            answer_model,
            verdict,
            None,
          )
          (
            { ..model, annotations: next, annotations_error: None, },
            save_annotations(id, next, emit),
          )
        }
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
      let run_id = match model.viewed {
        Some(viewed) => Some(viewed.id)
        None => model.run_id
      }
      match run_id {
        None => (model, @cmd.none)
        Some(id) => {
          // 草稿落在哪条答案上，由 note_key 说了算
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
          (
            { ..model, annotations: next, note_key: None, },
            save_annotations(id, next, emit),
          )
        }
      }
    }
    AnnotationsSaved(result) =>
      match result {
        Ok(_) => ({ ..model, annotations_error: None, }, @cmd.none)
        Err(error) =>
          ({ ..model, annotations_error: Some(error.to_string()), }, @cmd.none)
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
    SystemChanged(text) =>
      ({ ..model, preset_applied: false, system: text, }, @cmd.none)
    ToggleSystemOverride =>
      (
        {
          ..model,
          preset_applied: false,
          system_override: !model.system_override,
        },
        @cmd.none,
      )
    ToggleCotThinking(id) =>
      ({ ..model, cot_thinking: toggle(model.cot_thinking, id), }, @cmd.none)
    ToggleCotEffort(id) =>
      ({ ..model, cot_effort: toggle(model.cot_effort, id), }, @cmd.none)
    // 整列操作用「当前选中的模型」为准：勾选模型之后按一下，新加进来的那个也一起开
    CotThinkingAll =>
      ({ ..model, cot_thinking: effective_models(model), }, @cmd.none)
    CotEffortAll =>
      ({ ..model, cot_effort: effective_models(model), }, @cmd.none)
    CotClear => ({ ..model, cot_thinking: [], cot_effort: [], }, @cmd.none)
    SetParallel(mode) => ({ ..model, parallel: mode, }, @cmd.none)
    SetPanelTab(tab) => ({ ..model, panel_tab: tab, }, @cmd.none)
    PickImportFile => {
      // 只是把对话框打开；结果稍后经 #import-bridge 的 input 事件回来
      pick_text_file("import-bridge")
      (model, @cmd.none)
    }
    ImportFilePicked(raw) => {
      let parsed : Json = @json.parse(raw) catch { _ => Json::null() }
      guard parsed is Object(obj) else { (model, @cmd.none) }
      let name = match obj.get("name") {
        Some(String(text)) => text
        _ => ""
      }
      let text = match obj.get("text") {
        Some(String(text)) => text
        _ => ""
      }
      let failure = match obj.get("error") {
        Some(String(text)) => Some(text)
        _ => None
      }
      // 清掉桥接字段：不然同一份内容再来一次不会触发 input（值没变）
      let next = { ..model, import_payload: "", import_file_name: name, }
      match failure {
        Some(message) => ({ ..next, cases_error: Some(message), }, @cmd.none)
        None =>
          if text == "" {
            ({ ..next, cases_error: Some("这个文件是空的"), }, @cmd.none)
          } else {
            // 名字优先用「新集名字」，其次用文件名（import_set_name 里就是这么定的）
            let set_name = import_set_name(next)
            if set_name == "" {
              (
                {
                  ..next,
                  cases_error: Some(
                    "这个文件名没法当集名，先在左边填一个「新集名字」",
                  ),
                },
                @cmd.none,
              )
            } else if !is_usable_set_name(set_name) {
              // 服务端只收 [A-Za-z0-9._-]（集名就是文件名）。
              // 在这里先拦一道，否则用户拿到的是一句没头没脑的 400
              (
                {
                  ..next,
                  cases_error: Some(
                    "集名只能用字母、数字、点、下划线、短横。这个文件名叫「\{set_name}」，先在上面填一个「新集名字」",
                  ),
                },
                @cmd.none,
              )
            } else {
              (
                { ..next, cases_error: None, cases_saved: None, },
                import_case_text(set_name, text, emit),
              )
            }
          }
      }
    }
    Spot(id) => {
      spot_field(id)
      (model, @cmd.none)
    }
    CaseFileImported(result) =>
      match result {
        Ok(json) =>
          (
            {
              ..model,
              cases_saved: Some("已从文本文件建好测试集"),
              import_file_name: "",
              panel_tab: "set",
            },
            @cmd.batch([fetch_meta(emit), fetch_case_set(json_name(json), emit)]),
          )
        Err(error) =>
          ({ ..model, cases_error: Some(error.to_string()), }, @cmd.none)
      }
    RepeatsChanged(text) =>
      (
        {
          ..model,
          preset_applied: false,
          repeats: clamp_int(text, 1, 20, model.repeats),
        },
        @cmd.none,
      )
    MaxTokensChanged(text) =>
      (
        {
          ..model,
          preset_applied: false,
          max_tokens: clamp_int(text, 1, 32768, model.max_tokens),
        },
        @cmd.none,
      )
    TemperatureChanged(text) =>
      (
        {
          ..model,
          preset_applied: false,
          temperature: clamp_double(text, 0.0, 2.0, model.temperature),
        },
        @cmd.none,
      )
    PaceChanged(text) =>
      (
        {
          ..model,
          preset_applied: false,
          pace_ms: clamp_int(text, 0, 60000, model.pace_ms),
        },
        @cmd.none,
      )
    RetryChanged(text) =>
      (
        {
          ..model,
          preset_applied: false,
          retry: clamp_int(text, 0, 10, model.retry),
        },
        @cmd.none,
      )
    StartRun =>
      // 运行中重复点击直接忽略：按钮不再用 disabled 属性挡（见 action_row）
      if model.status == "running" || model.status == "starting" {
        (model, @cmd.none)
      } else {
        let (errors, _) = run_issues(model)
        if errors.length() > 0 {
          // 按钮看着已经灰了；这里再拦一道，免得键盘/脚本绕过去
          return (model, @cmd.none)
        }
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
          (
            next,
            @cmd.batch([
              @rabbita.delay(poll_run(response.id, emit), 400),
              // 立刻让侧栏出现这条「运行中」：不然跑 bench 的这几分钟里，侧栏里
              // 找不到它，点开别的运行之后也回不来
              fetch_runs(emit),
              // 地址栏记住它：刷新之后还能回到这次运行
              @cmd.effect(fn() { set_run_param(response.id) }),
            ]),
          )
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
            live: @shared.parse_live(status.live, status.liveAgeMs),
            failures: status.failures,
            retried: status.retried,
            truncated: status.truncated,
          }
          let id = match model.run_id {
            Some(id) => id
            None => status.id
          }
          if status.status == "running" {
            (next, @rabbita.delay(poll_run(id, emit), 250))
          } else {
            // 跑完了刷新一次历史：新记录要立刻出现在侧栏里，
            // 而不是等下次打开页面。顺带把这次运行的标注拿进来。
            (next, @cmd.batch([fetch_runs(emit), fetch_annotations(id, emit)]))
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

///|
/// 加进去 / 拿出来，返回一个新数组。
///
/// **不能原地 push**：`values` 就是 `model.selected_cases` 那个数组，push 之后
/// 改的是「旧模型」持有的同一块内存——于是新旧的 VDOM props 看起来一模一样，
/// 该刷新的派生文本（「已选 N」「约 N 次请求」）就不刷新：勾选框是自己原生点亮的，
/// 数字却停在 0
fn toggle(values : Array[String], value : String) -> Array[String] {
  let out = values.copy()
  if out.contains(value) {
    out.filter(fn(item) { item != value })
  } else {
    out.push(value)
    out
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
  /// 运行级 system prompt。空（None）就不发这个字段，服务端那边当作「不带」。
  system : String?
  /// 让上面那条覆盖测试集里逐条写的 system
  systemOverride : Bool
  /// 这些模型带 enable_thinking: true
  cotThinking : Array[String]
  /// 这些模型带 reasoning_effort: "high"
  cotEffort : Array[String]
  /// 串行 / 按模型并行 / 全部并发
  parallel : String
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
    cases: if model.uses_prompt() {
      []
    } else {
      model.selected_cases
    },
    prompt: if model.uses_prompt() {
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
    system: if model.system == "" {
      None
    } else {
      Some(model.system)
    },
    // 空文本框时这个开关不生效：别发出去，否则 request.json 与重跑重放都会
    // 记下一个当时并没有生效的设置
    systemOverride: model.system_override &&
    model.system.trim(chars=" \t\r\n") != "",
    cotThinking: model.cot_thinking,
    cotEffort: model.cot_effort,
    parallel: model.parallel,
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
/// 一个逗号分隔的查询参数 → 数组（分享链接里带「哪些模型开了推理开关」）
fn query_list(query : Map[String, String], key : String) -> Array[String] {
  let raw = match query.get(key) {
    Some(value) => value
    None => return []
  }
  let out : Array[String] = []
  for piece in raw.split(",") {
    let clean = piece.trim(chars=" \t").to_owned()
    if clean != "" && !out.contains(clean) {
      out.push(clean)
    }
  }
  out
}

///|
fn effective_models(model : AppModel) -> Array[String] {
  // 只看勾选。手输的名字不再直接入队：先按「识别」变成候选 checkbox，再由用户勾选。
  // 以前是「输入框里有什么就跑什么」，没打完的名字会被原样送进请求
  let out : Array[String] = []
  for id in model.selected_models {
    out.push(id)
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
  if model.uses_prompt() {
    parts.push("prompt=" + percent_encode(model.prompt))
  } else if model.selected_cases.length() > 0 {
    parts.push("cases=" + percent_encode(model.selected_cases.join(",")))
  }
  if model.system != "" {
    parts.push("system=" + percent_encode(model.system))
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
  // 正在看历史运行时，屏幕上是那次运行的数据——导出必须跟着屏幕走，
  // 否则「看着 A 复制出 B」，或者干脆说没有结果可复制（真的踩过）
  let source = match model.viewed {
    Some(viewed) => viewed.data
    None => model.data
  }
  match source {
    None => "还没有结果可复制"
    Some(data) => {
      // 带上人工判定：这份 Markdown 是留着以后翻的
      let text = @shared.results_markdown(
        @shared.with_annotations(data, model.annotations),
      )
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
      // 侧栏一直渲染，哪怕 meta 还没到：`.workbench` 是两列网格，少一个子元素
      // 主内容就会掉进第一列（那 270px 里）——加载中或加载失败时整个页面挤成
      // 一条。空着也得占住那一格
      history_panel(model, emit),
      el(
        "main",
        if model.preset_applied {
          "workbench-main preset-fresh"
        } else {
          "workbench-main"
        },
        [
          controls(model, emit),
          progress(model),
          result_section(model, emit),
          export_row(model, emit),
        ],
      ),
    ]),
    footer(model),
    history_dialog(model, emit),
    context_dialog(model, emit),
  ])
}

///|
/// 请求上下文对话框。
///
/// 开着但没有数据时也要有一块东西：空白对话框会让人以为是坏了，而「正在取」
/// 和「取不到、为什么取不到」都得说出来。
fn context_dialog(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  let case_id = match model.context_case {
    None => return @html.fragment([])
    Some(case_id) => case_id
  }
  let body = match model.context_error {
    Some(message) => el("p", "failed", [txt(message)])
    None =>
      match model.context {
        Some(context) => @shared.run_context_body(context, case_id)
        None => el("p", "muted", [txt("正在取请求上下文…")])
      }
  }
  @shared.modal(
    "请求上下文",
    if case_id == "" {
      ""
    } else {
      case_id
    },
    body,
    emit(Msg::CloseContext),
  )
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
  // 右上角放「现在什么状态 + 手上有什么」。
  //
  // 原来这里是「N 个模型可选 · N 道用例 · <网关地址>」。网关那串最占地方，
  // 信息量却是零：下面表单里就有一个一模一样的输入框，而且它长到把整行吃完了。
  // 换掉它的是两件在别处看不到（或者得数半天）的事：有没有在跑、跑过几次。
  let running = model.status == "running" || model.status == "starting"
  let counts = match model.meta {
    Some(meta) =>
      "\{meta.models.length()} 个模型 · \{meta.cases.length()} 条用例"
    None => "正在载入…"
  }
  let history = match model.runs {
    Some(runs) =>
      if runs.length() == 0 {
        ""
      } else {
        "已跑 \{runs.length()} 次 · 最近 \{format_time(runs[0].startedAt)}"
      }
    None => ""
  }
  let summary = if history == "" { counts } else { counts + " · " + history }
  let right = if running {
    [
      el("span", "site-live", [
        el("span", "dot", []),
        txt("运行中 \{model.done}/\{model.total}"),
      ]),
      el("span", "", [txt(summary)]),
    ]
  } else {
    [el("span", "", [txt(summary)])]
  }
  el("header", "site-header", [
    el("div", "wrap site-header-inner", [
      el("div", "site-logo", [txt("faceoff")]),
      el("div", "site-meta", right),
    ]),
  ])
}

///|
/// 运行级 system prompt：这次运行里所有用例共用。
///
/// 放在这里是因为它是「固定下来的那一半」——变的是每条用例的 user prompt。
/// 用例自己也能带 system（用例编辑器里逐条填），那条会盖掉这里填的；页面上的
/// 「请求上下文」会标出哪条被盖了。
fn system_field(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  el("fieldset", "picker picker-core", [
    el("legend", "", [txt("System Prompt")]),
    @html.textarea(
      class="prompt-input",
      id="system",
      value=model.system,
      rows=3,
      placeholder="例如：把下面的语音转写文本整理成通顺的书面表达，保留原意，不要解释",
      on_input=emit.map(fn(text) { SystemChanged(text) }),
      ([] : Array[@html.Html]),
    ),
    el("div", "hint", [
      txt(
        "测试集用例内，不包含 System Prompt 的测试条目，将使用这里填写的内容",
      ),
    ]),
    // 用例级 system 与运行级 system 到底谁赢：以前是写死「用例级优先」，
    // 现在交给用户勾
    el("label", "check system-override", [
      @html.input(
        input_type=@html.InputType::Checkbox,
        id="system-override",
        checked=model.system_override,
        on_change=emit.map(fn(_value) { ToggleSystemOverride }),
      ),
      el("span", "", [txt("覆盖测试集内的 System Prompt")]),
    ]),
    el("p", if model.system_override { "notice" } else { "hint" }, [
      if model.system_override {
        txt("勾选：测试集里逐条写的 System Prompt 将会被忽略")
      } else {
        txt(
          "不勾：测试集里逐条写的 System Prompt 优先，用例没写的才落到上面这条",
        )
      },
      // 勾了但没写：这句单独标红，因为它是「你得做点什么」而不是说明
      if model.system_override && model.system.trim(chars=" \t\r\n") == "" {
        el("span", "notice-bad", [
          txt(
            " 请输入一些文本作为 System Prompt 否则该功能无法生效",
          ),
        ])
      } else {
        @html.fragment([])
      },
    ]),
  ])
}

///|
fn controls(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  match model.meta {
    None =>
      el("section", "hero", [
        @html.h1([txt("LLM 模型对比")]),
        @html.p([
          txt(
            match model.meta_error {
              Some(error) =>
                // 字段对不上多半是服务端还在跑旧版本，光看 JsonDecodeError 没法自救
                "载入失败：" +
                error +
                "（若是 Missing field，服务端可能是旧版本，重启 make serve 即可）"
              None => "正在载入配置…"
            },
          ),
        ]),
      ])
    Some(meta) =>
      el("section", "hero", [
        @html.h1([txt("LLM 模型对比")]),
        @html.p([
          txt(
            "勾选或直接填模型、调好参数，点「开始评测」，进度实时回传；并发方式可选串行或并行",
          ),
        ]),
        @html.p([
          txt(
            "网关默认用服务端配置；下面填了地址或密钥就只对本次运行生效，密钥只经过本页内存，不落盘",
          ),
        ]),
        if !meta.hasKey {
          el("p", "failed", [
            txt(
              "服务端没有读到 API key。可以在启动服务端前设好 MOONLLM_API_KEY / OPENAI_API_KEY，也可以直接在下面的 API key 里填一把",
            ),
          ])
        } else {
          @html.fragment([])
        },
        // 网关与密钥放在模型上面：这是「对着谁说话」，看模型勾选之前先确定它。
        // 以前在参数行下面，和「重复几次」混在一起。
        gateway_row(model, emit),
        model_picker(meta, model, emit),
        system_field(model, emit),
        case_panel(meta, model, emit),
        preset_panel(meta, model, emit),
        param_row(model, emit),
        parallel_row(model, emit),
        confirm_summary(model, emit),
        issue_lists(model, emit),
        action_row(model, emit),
        if model.autorun_held {
          el("p", "notice", [
            txt(
              "链接里带了 autorun=1，但眼下没有可用的 API key，所以没有自动开跑：直接跑只会撞上鉴权失败。填好上面的 API key（或确认网关不需要 key）后点「开始评测」",
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
  // 候选 = 服务端/环境变量给的菜单 + 用户按「识别」加进来的，去重且保持顺序
  let candidates : Array[String] = []
  for id in meta.models {
    candidates.push(id)
  }
  for id in model.custom_models {
    if !candidates.contains(id) {
      candidates.push(id)
    }
  }
  let boxes = candidates.map(fn(id) {
    labelled_checkbox(
      "model-" + id,
      id,
      model.selected_models.contains(id),
      emit.map(fn(_value) { ToggleModel(id) }),
    )
  })
  el("fieldset", "picker", [
    el("legend", "", [txt("模型")]),
    el(
      "div",
      "picker-items",
      [
        // 环境变量没给任何模型时先说清楚该怎么配：否则这里一片空白，
        // 用户只会以为页面坏了。
        //
        // 「看起来是禁用的」靠 class（变淡 + pointer-events: none），不是 disabled
        // 属性——Rabbita 的 vdom diff 不会把 disabled 摘掉，开关一次就永久死掉
        if meta.models.length() == 0 {
          el("label", "check check-disabled", [
            @html.input(
              input_type=@html.InputType::Checkbox,
              id="env-models-hint",
              checked=false,
            ),
            el("span", "", [
              txt(
                "可以通过配置环境变量 LLM_WEB_MODELS 或 MOONLLM_MODEL 来配置最多 \{max_models} 个模型",
              ),
            ]),
          ])
        } else {
          @html.fragment([])
        },
        ..boxes,
      ],
    ),
    el("div", "field", [
      @html.label(for_="extra-models", [
        txt(
          "填模型 id（逗号分隔）后按「识别」加入候选，再由上面的勾选定这次跑哪几个",
        ),
      ]),
      el("div", "model-add", [
        @html.input(
          input_type=@html.InputType::Text,
          id="extra-models",
          value=model.extra_models,
          placeholder="例如 deepseek-chat,deepseek-reasoner",
          on_input=emit.map(fn(text) { ExtraModelsChanged(text) }),
        ),
        @html.button(class="ghost", on_click=emit(Msg::AddExtraModels), [
          txt("识别"),
        ]),
      ]),
    ]),
    // 推理开关：按模型勾（勾中的模型才生成一行）。
    //
    // 两家风格的字段名不一样，所以两个都在：勾哪个就往那个模型的请求体里带哪个。
    // 各端点认不认、认哪个，得看网关自己（页面不替你猜）
    cot_rows(model, emit),
  ])
}

///|
/// 每个选中的模型一行：「对 <模型> 启动 CoT 推理」+ 两种机制各一个勾。
fn cot_rows(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  let models = effective_models(model)
  if models.length() == 0 {
    return @html.fragment([])
  }
  let rows = models.map(fn(id) {
    el("div", "cot-row", [
      el("span", "cot-model", [txt(id)]),
      labelled_checkbox(
        "cot-thinking-" + id,
        "enable_thinking",
        model.cot_thinking.contains(id),
        emit.map(fn(_value) { ToggleCotThinking(id) }),
      ),
      labelled_checkbox(
        "cot-effort-" + id,
        "reasoning_effort",
        model.cot_effort.contains(id),
        emit.map(fn(_value) { ToggleCotEffort(id) }),
      ),
    ])
  })
  el(
    "div",
    "cot-box",
    [
      el("div", "cot-head", [
        el("span", "", [txt("推理开关（按模型选，可多选）")]),
        el("span", "cot-all", [
          @html.button(class="link-btn", on_click=emit(Msg::CotThinkingAll), [
            txt("全选 enable_thinking"),
          ]),
          @html.button(class="link-btn", on_click=emit(Msg::CotEffortAll), [
            txt("全选 reasoning_effort"),
          ]),
          @html.button(class="link-btn", on_click=emit(Msg::CotClear), [
            txt("全不选"),
          ]),
        ]),
      ]),
      ..rows,
    ],
  )
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
      "最大重试次数",
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

///|
/// 并发方式：串行是默认（延迟数字只有串行才干净），另外两个只为了快
fn parallel_row(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  let option = fn(mode : String, label : String, hint : String) {
    el("label", "check parallel-option", [
      @html.input(
        input_type=@html.InputType::Radio,
        id="parallel-" + mode,
        name="parallel-mode",
        value=mode,
        checked=model.parallel == mode,
        on_change=emit.map(fn(_value) { SetParallel(mode) }),
      ),
      el("span", "label", [txt(label)]),
      el("span", "hint", [txt(hint)]),
    ])
  }
  el("div", "parallel-row", [
    el("div", "parallel-head", [txt("并发方式")]),
    option(
      "serial", "串行", "延迟数字只有串行才干净，也是默认",
    ),
    option(
      "models", "按模型并行", "每个模型一条流，模型内仍串行",
    ),
    option(
      "all", "全部并发", "所有请求一起发，最快也最容易撞限流",
    ),
  ])
}

///|
/// 《开始前确认》：把这次会用到的东西只读列一遍，行尾「调整」跳到对应输入框并亮 5 秒。
///
/// 它不改变任何状态，也不参与提交——纯粹是「按开始之前再扫一眼」，以及
/// 「我想改哪一项」的快捷入口。
fn confirm_summary(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  let jump = fn(target : String) {
    @html.button(class="link-btn", on_click=emit(Msg::Spot(target)), [
      txt("调整"),
    ])
  }
  let row = fn(label : String, value : String, target : String) {
    el("div", "confirm-row", [
      el("span", "confirm-label", [txt(label)]),
      el("span", "confirm-value", [txt(value)]),
      jump(target),
    ])
  }
  let models = effective_models(model)
  let yes_no = fn(flag : Bool) { if flag { "是" } else { "否" } }
  let cot = {
    let parts : Array[String] = []
    if model.cot_thinking.length() > 0 {
      parts.push("enable_thinking: " + model.cot_thinking.join(", "))
    }
    if model.cot_effort.length() > 0 {
      parts.push("reasoning_effort: " + model.cot_effort.join(", "))
    }
    if parts.length() == 0 {
      "无"
    } else {
      parts.join(" · ")
    }
  }
  // 推理开关与并发方式亮的是整组容器（不是其中一个勾）：一组控件亮一个小勾，
  // 用户看不到；而且容器直接拿 .spot，不依赖 :has()
  let cot_target = if models.length() > 0 {
    ".cot-box"
  } else {
    "#extra-models"
  }
  let cases = if model.uses_prompt() {
    "临时提示词 1 条"
  } else {
    "\{model.case_set} · 已选 \{model.selected_cases.length()} 条"
  }
  let parallel_label = match model.parallel {
    "models" => "按模型并行"
    "all" => "全部并发"
    _ => "串行"
  }
  el("div", "confirm-box", [
    el("div", "confirm-head", [txt("开始前确认")]),
    el("div", "confirm-rows", [
      row(
        "网关",
        if model.base_url == "" {
          "服务端默认"
        } else {
          model.base_url
        },
        "base-url",
      ),
      row(
        "模型",
        if models.length() == 0 {
          "还没选"
        } else {
          models.join(", ")
        },
        "[data-name=models-fieldset]",
      ),
      row(
        "System Prompt",
        // 说的是「谁优先」而不是「填没填」：勾了覆盖且真填了内容，才是这里优先；
        // 其余情况（没勾，或者勾了但框里是空的）都是用例自己那条优先
        if model.system_override && model.system != "" {
          "SystemPrompt 栏目下填充的汉字优先"
        } else {
          "测试集条目包含的文本优先"
        },
        "system",
      ),
      row(
        "覆盖测试集 system",
        // 文本框空着的时候这个开关是不生效的（与后端一致），所以这里显示「否」
        yes_no(
          model.system_override && model.system.trim(chars=" \t\r\n") != "",
        ),
        if model.system.trim(chars=" \t\r\n") == "" {
          "system"
        } else {
          "system-override"
        },
      ),
      row("推理开关", cot, cot_target),
      row("测试集", cases, "case-set"),
      row("重复次数", model.repeats.to_string(), "repeats"),
      row("max tokens", model.max_tokens.to_string(), "max-tokens"),
      row("temperature", model.temperature.to_string(), "temperature"),
      row("间隔", "\{model.pace_ms} ms", "pace-ms"),
      row("最大重试次数", "\{model.retry} 次", "retry"),
      row("并发方式", parallel_label, ".parallel-row"),
    ]),
  ])
}

///|
/// 配置检查：红线拦住不让跑，橙线只提示、可以强行跑。
///
/// 分成两条总线（而不是散在各自的输入框旁边）是因为：用户按下开始之前要的是一份
/// 完整的清单——哪里错了、哪里只是提醒，一次看完；散着放就得自己扫全页去找。
/// 顺带把「值得挂上去的后续异常」留在这里加：往后有新的配置错误，往这两个数组里
/// 丢一条就行，渲染与拦截逻辑都不用动
///
/// 返回 (错误, 警告)。
struct Issue {
  text : String
  /// 点「去填」时滚过去并高亮的那个选择器
  target : String
} derive(Eq)

///|
fn run_issues(model : AppModel) -> (Array[Issue], Array[Issue]) {
  let errors : Array[Issue] = []
  let warnings : Array[Issue] = []
  // 服务端给的值分两种：配置的，和内置兜底。字段空着 + 只剩兜底 = 谁都没配过，
  // 按下去会去连一个根本没打算用的地址——这种要拦住，不能当「能用」放过去
  let (configured_base, server_has_key) = match model.meta {
    Some(meta) => (meta.baseUrlConfigured.unwrap_or(false), meta.hasKey)
    None => (false, false)
  }
  // 网关：填了就必须像个 http(s) 地址；空着看服务端配没配
  let base = model.base_url.trim(chars=" \t\r\n").to_owned()
  if base != "" {
    if !base.has_prefix("http://") && !base.has_prefix("https://") {
      errors.push({
        text: "网关地址要以 http:// 或 https:// 开头",
        target: "base-url",
      })
    }
  } else if !configured_base {
    errors.push({
      text: "网关地址没填，服务端也没配：先在上面填一个",
      target: "base-url",
    })
  }
  // 模型：至少一个
  let models = effective_models(model)
  if models.length() == 0 {
    errors.push({ text: "至少选一个模型", target: "extra-models", })
  } else if models.length() > max_models {
    errors.push({
      text: "最多同时对比 \{max_models} 个模型，现在有 \{models.length()} 个",
      target: "extra-models",
    })
  }

  // 密钥：本地网关常常不要填，但一个都没有时先说一句
  if model.api_key.trim(chars=" \t\r\n") == "" && !server_has_key {
    warnings.push({
      text: "没填 API key：需要鉴权的网关会回 401",
      target: "api-key",
    })
  }
  // 跑什么：勾了用例，或者填了临时提示词。
  //
  // 以前这里还有一条「停在临时提示词那页但文本框是空的」的红线，但它写成了
  // uses_prompt() && prompt 为空 —— uses_prompt() 本身就是「文本框非空」，
  // 两个条件不可能同时成立，是死代码。空文本框的意思就是「跑测试集」
  if !model.uses_prompt() && model.selected_cases.length() == 0 {
    errors.push({
      text: "测试集里一条用例都没勾，临时提示词也是空的",
      target: "case-set",
    })
  }
  // 橙线：勾了覆盖、但文本框空着——规则是空的就不发，这次什么都不会覆盖。
  // 不拦路：空着跑照样有意义，只是这条覆盖不生效
  if model.system_override && model.system.trim(chars=" \t\r\n") == "" {
    warnings.push({
      // 与字段里那行同一套说法：总线是纯文本，红字那不适用，所以拼在一起
      text: "勾选：测试集里逐条写的 System Prompt 将会被忽略 请输入一些文本作为 System Prompt 否则该功能无法生效",
      target: "system",
    })
  }
  (errors, warnings)
}

///|
/// 把两条总线渲染成两个无序列表：红的在上，橙的在下
fn issue_lists(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  let (errors, warnings) = run_issues(model)
  let items = fn(class_ : String, title : String, list : Array[Issue]) {
    if list.length() == 0 {
      return @html.fragment([])
    }
    el(
      "ul",
      class_,
      [
        el("li", "issue-title", [txt(title)]),
        ..list.map(fn(issue) {
          el("li", "issue-row", [
            el("span", "issue-text", [txt(issue.text)]),
            @html.button(
              class="link-btn issue-locate",
              on_click=emit(Msg::Spot(issue.target)),
              [txt("去填")],
            ),
          ])
        }),
      ],
    )
  }
  el("div", "issues", [
    items("issues errors", "还差这些才能开始", errors),
    items("issues warnings", "可以跑，但先看一眼", warnings),
  ])
}

///|
fn action_row(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  let running = model.status == "running" || model.status == "starting"
  // 有红线就不让跑：按钮看着是灰的，点击也会在 update 里被挡
  let (errors, _) = run_issues(model)
  let blocked = errors.length() > 0
  let total = effective_models(model).length() *
    (if model.uses_prompt() { 1 } else { model.selected_cases.length() }) *
    model.repeats
  el("div", "actions", [
    // 刻意不用 `disabled` 属性：从「忙」切回「闲」时 Rabbita 的 vdom diff
    // 没把 disabled 摘掉（实测跑完一次后 DOM 里仍是
    // `<button class="primary" disabled="">开始评测</button>`），
    // 结果不刷新页面就再也点不动。改由 class 表达忙闲，重复点击在 update 里挡。
    @html.button(
      class=if running {
        "primary busy"
      } else if blocked {
        "primary blocked"
      } else {
        "primary"
      },
      on_click=emit(Msg::StartRun),
      [txt(if running { "运行中…" } else { "开始评测" })],
    ),
    el("span", "hint", [txt("约 \{total} 次请求")]),
    cost_hint(model),
  ])
}

///|
/// 极限用量：输入按「system + 用例正文」字符数算，输出按每次把 max_tokens 跑满算。
///
/// 两个都是上界——真实请求的输入只多不少（思维链、工具说明之类都可能再加），
/// 输出通常远小于上限。但「最坏要花多少」正是按开始之前想知道的那个数：
/// 它决定要不要调小 max tokens、少勾几条、或者把并发降下来
fn cost_hint(model : AppModel) -> @html.Html {
  let models = effective_models(model).length()
  let case_count = if model.uses_prompt() {
    1
  } else {
    model.selected_cases.length()
  }
  let requests = models * case_count * model.repeats
  if requests == 0 {
    return @html.fragment([])
  }
  let system_chars = model.system.length()
  // 每条用例的输入 = system + 这条的正文；用例自带的 system 没算在内，
  // 所以这里是「至少这么多」
  let body_chars = if model.uses_prompt() {
    model.prompt.length()
  } else {
    let mut sum = 0
    for case in model.available_cases {
      if model.selected_cases.contains(case.id) {
        sum = sum + case.prompt.length()
      }
    }
    sum
  }
  let input_chars = (system_chars * case_count + body_chars) *
    models *
    model.repeats
  let output_tokens = requests * model.max_tokens
  el("span", "hint", [
    txt(
      "· 极限：输入 ≈ \{input_chars} 字，输出 ≤ \{output_tokens} token（每次请求跑满 \{model.max_tokens}）",
    ),
  ])
}

///|
/// 网关覆盖项。留空就用服务端环境里的那份；填了只对本次运行生效。
///
/// 占位文字只在服务端**真的**给了对应的东西时才写：服务端没配网关 / 没配密钥时
/// 就空着。不然那行灰字会写着一个并不存在的值，用户以为跑的就是它
fn gateway_row(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  let base_hint = match model.meta {
    Some(meta) =>
      if meta.baseUrl == "" {
        "例如 https://your-gateway.example/v1"
      } else {
        "留空用服务端的：" + meta.baseUrl
      }
    None => ""
  }
  let key_hint = match model.meta {
    Some(meta) =>
      if meta.hasKey {
        "留空用服务端已配置的密钥"
      } else {
        ""
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
        // 同一排里既有 button 又有 a：用同一个 class，否则两者的字体度量不一样，
        // 一排按钮会错开一两个像素（看着「没对齐」）
        @html.button(class="chip", on_click=emit(Msg::CopyMarkdown), [
          txt("复制 Markdown 报告"),
        ]),
        @html.button(class="chip", on_click=emit(Msg::CopyShareLink), [
          txt("复制分享链接"),
        ]),
        // escape=true：@html.a 默认渲染成 Rabbita 自己那个被「捕获」的链接，
        // 点击会被它拦下来（留给框架内部路由用），于是 download 根本不触发——
        // 表现就是「点了没反应，只有 Ctrl+点击开新标签才行」。这里要的就是
        // 浏览器原生的下载行为
        @html.a(
          href=base + "/runs.jsonl",
          download="runs.jsonl",
          class="chip",
          escape=true,
          [txt("下载 runs.jsonl")],
        ),
        @html.a(
          href=base + "/data.json",
          download="data.json",
          class="chip",
          escape=true,
          [txt("下载 data.json")],
        ),
        @html.a(
          href=base + "/report.html",
          download="report.html",
          class="chip",
          escape=true,
          [txt("下载静态报告")],
        ),
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
    if model.status == "running" {
      @shared.live_row(model.live)
    } else {
      // 跑完之后整行收起来：数字是旧的、动画还在跑，留着只会骗人
      @html.fragment([])
    },
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
/// 分位切换：P10 / P20 / P50 / P99。
///
/// 四个都要能看到，是因为它们回答的不是同一个问题：P50 是「通常多快」，P99 是
/// 「会不会偶发地卡一下」，而 P10 是「顺的时候能多快」。只给中位数等于只答了
/// 第一个。
fn percentile_switch(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  let button = fn(which : String) {
    @html.button(
      class=if model.percentile == which {
        "view-btn active"
      } else {
        "view-btn"
      },
      on_click=emit(Msg::SetPercentile(which)),
      [txt(@shared.percentile_label(which))],
    )
  }
  el("span", "view-buttons", [
    button("p10"),
    button("p20"),
    button("p50"),
    button("p99"),
  ])
}

///|
/// 结果区的视图切换：竖着堆 / 并排 / 差异。
///
/// 「这么长我没法对比」是这里的全部理由：66 条用例、每条上千 token 的回答竖着
/// 排下来，读的人只能靠记忆左右横跳。
fn results_switch(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  let button = fn(mode : String, label : String) {
    @html.button(
      class=if model.results_mode == mode {
        "view-btn active"
      } else {
        "view-btn"
      },
      on_click=emit(Msg::SetResultsMode(mode)),
      [txt(label)],
    )
  }
  el("span", "view-buttons", [
    button("stacked", "每个模型一条"),
    button("columns", "并排对比"),
    button("diff", "差异"),
  ])
}

///|
/// 当前正在看的那次运行：优先「打开的历史运行」，其次「刚跑完/在跑的这次」。
fn AppModel::context_run_id(self : AppModel) -> String {
  match self.viewed {
    Some(viewed) => viewed.id
    None =>
      match self.run_id {
        Some(id) => id
        None => ""
      }
  }
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
              // 历史运行也一样能标注（标注在那次运行的目录里）
              Some(data) => results_for(model, emit, data)
              // 失败的运行没有 data.json，只有 stderr 尾巴：把那个拿出来，
              // 总比一片空白强
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
          match model.viewed_error {
            // 地址栏里的 run id 打不开：说清楚，而不是给一个空页面
            Some(message) =>
              el("section", "progress-card", [
                el("p", "failed", [txt(message)]),
                el("p", "hint", [
                  txt(
                    "地址栏里那个 #run=… 指向的运行不存在；点侧栏里的任意一条可以打开别的运行",
                  ),
                ]),
              ])
            None =>
              match model.data {
                Some(data) => results_for(model, emit, data)
                None => @html.fragment([])
              }
          }
      }
  }
}

///|
/// 一份结果数据的渲染（当前运行与历史运行共用同一套）
fn results_for(
  model : AppModel,
  emit : @cmd.Emit[Msg],
  data : @shared.PageData,
) -> @html.Html {
  @shared.results_section(
    @shared.with_annotations(data, model.annotations),
    mode=model.results_mode,
    switch=results_switch(model, emit),
    which=model.percentile,
    percentile_switch=percentile_switch(model, emit),
    editor=fn(case_id, answer_model) {
      annotation_editor_for(model, case_id, answer_model, emit)
    },
    context=fn(case_id) {
      @shared.context_button(emit(Msg::OpenContext(case_id)))
    },
  )
}

///|
fn footer(model : AppModel) -> @html.Html {
  let source = match model.data {
    Some(data) => if data.source == "" { "本次运行" } else { data.source }
    // 没有数据时别写「数据来源 —」：那看着像标签后面拖了条破折号
    None => "暂无"
  }
  el("footer", "site-footer", [
    el("div", "wrap", [
      txt("数据来源：\{source}"),
      @html.br(),
      txt(
        "页面由 Rabbita 驱动，样式由 precss 从 styles/site.scss 编译",
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
