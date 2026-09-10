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
} derive(Eq, FromJson)

///|
/// 当前页面的 query string。
///
/// 有了它就能把一次配置直接做成可分享的链接，例如
///   /?autorun=1&models=MiniCPM5-1B,MiniCPM5-2B&cases=math-short&repeats=1
extern "js" fn current_search() -> String = "() => window.location.search"

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
  /// 页面打开时的 query string（?autorun / models / cases / repeats / …）。
  /// meta 到齐后套用，让链接本身就能表达一次完整配置。
  query : Map[String, String]
} derive(Eq)

///|
fn initial_model() -> AppModel {
  let query = parse_query(current_search())
  {
    autorun: query.get("autorun") == Some("1"),
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
      init=fn(emit) { (initial_model(), fetch_meta(emit)) },
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
          }
          if next.autorun &&
            !next.selected_models.is_empty() &&
            !next.selected_cases.is_empty() {
            let payload = RunPayload::of(next)
            (
              { ..next, autorun: false, status: "starting", },
              start_run(payload, emit),
            )
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
          }
          let id = match model.run_id {
            Some(id) => id
            None => status.id
          }
          if status.status == "running" {
            (next, @rabbita.delay(poll_run(id, emit), 700))
          } else {
            (next, @cmd.none)
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
  repeats : Int
  maxTokens : Int
  temperature : Double
  paceMs : Int
  retry : Int
} derive(ToJson)

///|
fn RunPayload::of(model : AppModel) -> RunPayload {
  {
    models: model.selected_models,
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
    repeats: model.repeats,
    maxTokens: model.max_tokens,
    temperature: model.temperature,
    paceMs: model.pace_ms,
    retry: model.retry,
  }
}

// ---------------------------------------------------------------- view

///|
fn view(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  el("div", "app", [
    header(model),
    el("main", "wrap", [
      controls(model, emit),
      progress(model),
      result_section(model),
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
      el("div", "site-logo", [txt("llm_client")]),
      el("div", "site-meta", [txt(meta_line)]),
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
            "勾选模型与用例、调好参数，点开始。运行在服务端串行执行，进度实时回传；网关密钥不下发到浏览器。",
          ),
        ]),
        if !meta.hasKey {
          el("p", "failed", [
            txt(
              "服务端没有读到 API key（MOONLLM_API_KEY / OPENAI_API_KEY），运行会失败。",
            ),
          ])
        } else {
          @html.fragment([])
        },
        model_picker(meta, model, emit),
        case_picker(meta, model, emit),
        prompt_picker(model, emit),
        param_row(model, emit),
        action_row(model, emit),
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
  ])
}

///|
fn case_picker(
  meta : Meta,
  model : AppModel,
  emit : @cmd.Emit[Msg],
) -> @html.Html {
  let boxes = meta.cases.map(fn(case) {
    labelled_checkbox(
      "case-" + case.id,
      case.id,
      model.selected_cases.contains(case.id),
      emit.map(fn(_value) { ToggleCase(case.id) }),
    )
  })
  el("fieldset", "picker", [
    el("legend", "", [
      txt("用例"),
      @html.button(class="link-btn", on_click=emit(Msg::SelectAllCases), [
        txt("全选"),
      ]),
    ]),
    el("div", "picker-items", boxes),
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
  let total = model.selected_models.length() *
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
fn result_section(model : AppModel) -> @html.Html {
  match model.data {
    Some(data) => @shared.results_section(data)
    None => @html.fragment([])
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
