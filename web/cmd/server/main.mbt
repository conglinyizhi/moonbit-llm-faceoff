///|
/// 交互式评测服务：静态文件 + JSON API，评测以子进程方式调用 bench。
///
/// 为什么用子进程而不是直接调用 bench 包：bench 依赖库，库钉在
/// moonbitlang/async 0.20.1，本模块用 async 0.21.x + rabbita。放进同一个
/// workspace 会强制统一版本并打坏库，所以这里只通过 CLI 边界通信。
/// （库已不依赖任何第三方 LLM 包，这个分歧只剩 async 版本。）
///
/// 运行状态全部落在文件里（runs/<id>/），不做进程内共享状态：
///   请求参数写在 request.json，进度靠数 runs.jsonl 的行数，
///   退出码由外层 sh 追加到 exit_code，最终数据在 data.json。
///
/// 环境变量：
///   LLM_WEB_PORT    监听端口（默认 8137）
///   LLM_WEB_STATIC  静态目录（默认 out）
///   LLM_WEB_WORK    运行目录（默认 runs）
///   LLM_WEB_CASES   旧的单文件用例（默认 ../bench/cases.example.jsonl）；
///                   只在测试集目录为空时当种子读一次
///   LLM_WEB_CASES_DIR  测试集目录，每个集一个 <名字>.jsonl（默认 cases）
///   LLM_WEB_PRESETS    预设文件（默认 presets.json）
///   LLM_BENCH_BIN   bench 可执行文件（默认 ../_build/native/debug/build/cmd/bench/bench.exe）
///   LLM_WEB_SSG    静态报告生成器（默认 ../web/_build/.../ssg.exe）
///   LLM_WEB_MODELS  默认模型菜单，逗号分隔（请求也可使用其它模型）
///   LLM_WEB_SYSTEM  默认 system prompt（页面里预填，可以改；空 = 不带）
///   MOONLLM_API_KEY / OPENAI_API_KEY   网关密钥（不下发给浏览器）
///   MOONLLM_BASE_URL / OPENAI_BASE_URL 网关地址
async fn main {
  let port = int_env("LLM_WEB_PORT", 8137)
  let static_dir = @env.get_env_var("LLM_WEB_STATIC").unwrap_or("out")
  let work_dir = @env.get_env_var("LLM_WEB_WORK").unwrap_or("runs")
  let cases_path = @env.get_env_var("LLM_WEB_CASES").unwrap_or(
    "../bench/cases.example.jsonl",
  )
  let cases_dir = @env.get_env_var("LLM_WEB_CASES_DIR").unwrap_or("cases")
  let presets_path = @env.get_env_var("LLM_WEB_PRESETS").unwrap_or(
    "presets.json",
  )
  let bench_bin = @env.get_env_var("LLM_BENCH_BIN").unwrap_or(
    "../_build/native/debug/build/cmd/bench/bench.exe",
  )
  let ssg_bin = @env.get_env_var("LLM_WEB_SSG").unwrap_or(
    "_build/native/debug/build/cmd/ssg/ssg.exe",
  )
  // 空串 = 不带 system（和 bench 的 --system 默认一致）
  let default_system = @env.get_env_var("LLM_WEB_SYSTEM").unwrap_or("")
  let config : ServerConfig = {
    static_dir,
    work_dir,
    cases_path,
    cases_dir,
    presets_path,
    bench_bin,
    ssg_bin,
    models: allowed_models(),
    // 没有兜底地址：没配就是空，页面据此报红线。塞一个 api.openai.com 进去
    // 只会让人以为「能用」，实际按下去是一个谁都没配过的地址
    base_url: first_env(["MOONLLM_BASE_URL", "OPENAI_BASE_URL"]).unwrap_or(""),
    // 空字符串要当没配：set 成空是「取消」的常见写法，is_some() 会把它算成配了
    base_url_configured: first_env(["MOONLLM_BASE_URL", "OPENAI_BASE_URL"]).unwrap_or("") != "",
    models_configured: @env.get_env_var("LLM_WEB_MODELS").unwrap_or("") != "",
    api_key: first_env(["MOONLLM_API_KEY", "OPENAI_API_KEY"]).unwrap_or(""),
    default_system,
  }
  @fs.mkdir(work_dir, recursive=true) catch {
    _ => ()
  }
  seed_case_sets(config)
  if config.api_key == "" {
    note("warning: no MOONLLM_API_KEY / OPENAI_API_KEY in the environment")
  }
  note(
    "static=\{config.static_dir}  runs=\{config.work_dir}  cases=\{config.cases_dir}  presets=\{config.presets_path}",
  )
  // 静态目录是按当前工作目录解析的（默认 out，就在 web/ 里）。从别处启动
  // 时服务端本身跑得起来、/api 也通，只有页面一律 404，很难看出是为什么。
  // 与其让人去猜，不如直接说出来。
  if !(@fs.exists(config.static_dir) catch { _ => false }) {
    note("warning: static directory '\{config.static_dir}' does not exist.")
    note(
      "  /api will work but every page request will 404. Start the server from web/, or set LLM_WEB_STATIC.",
    )
  }
  let server = @http.Server(
    @socket.Addr::parse("127.0.0.1:\{port}"),
    reuse_addr=true,
  )
  // 端口写在 stdout 第一行，和 mock 端点的握手方式一致。
  // 用 LLM_WEB_PORT=0 时由内核分配，调用方读这一行就行——
  // 硬编码端口在共用机器上会撞车。
  //
  // 走 @stdio.stdout 而不是 println：stdout 被重定向到文件时 println 是
  // 块缓冲的，这一行会卡在缓冲区里出不来，调用方就永远等不到。
  @stdio.stdout.write(server.addr.port().to_string() + "\n") catch {
    _ => ()
  }
  note("listening on http://127.0.0.1:\{server.addr.port()}/")
  // 这个 group 活到进程结束。子进程的「等退出码」任务挂在它上面，而不是挂在
  // 请求任务上：请求发完 202 就结束了，而一次运行要跑几分钟。
  @async.with_task_group(async fn(group) {
    server.run_forever() <| async fn(request, body, conn) {
      handle(config, group, request, body, conn)
    }
  })
}

// ---------------------------------------------------------------- 配置

///|
struct ServerConfig {
  static_dir : String
  work_dir : String
  /// 旧的单文件用例路径：只在测试集目录为空时当种子读一次。
  cases_path : String
  /// 测试集目录，一个集一个 `<名字>.jsonl`。
  cases_dir : String
  /// 预设文件（模型 + 参数组合）。
  presets_path : String
  bench_bin : String
  ssg_bin : String
  models : Array[String]
  base_url : String
  /// 网关地址是配的还是没有。页面用它决定报警：字段空着 + 服务端也没配
  base_url_configured : Bool
  /// 同上：LLM_WEB_MODELS 没设时，模型表是编出来占位的 MiniCPM5-1B 之类
  models_configured : Bool
  api_key : String
  /// 默认 system prompt：页面打开时预填进那个框，跑的时候按页面上的值发。
  /// 「固定 system + 变动的 user prompt」时，把它写在启动服务端的地方，
  /// 就不用每次在页面上敲一遍。
  default_system : String
}

///|
/// 第一次启动时把 `LLM_WEB_CASES` 指向的那份用例播成 `default` 集。
///
/// 这样老的启动方式（只给 LLM_WEB_CASES）继续可用，而页面从此能切多套用例。
/// 逐字复制而不是重新序列化：注释、字段顺序、你没写的字段全都留着。
async fn seed_case_sets(config : ServerConfig) -> Unit {
  @fs.mkdir(config.cases_dir, recursive=true) catch {
    _ => ()
  }
  if list_case_sets(config.cases_dir).length() > 0 {
    return
  }
  let text = read_text(config.cases_path)
  if text == "" {
    return
  }
  let path = case_set_path(config.cases_dir, "default")
  write_text(path, text)
  note("seeded \{path} from \{config.cases_path}")
}

///|
fn first_env(keys : Array[String]) -> String? {
  for key in keys {
    match @env.get_env_var(key) {
      Some(value) => if value != "" { return Some(value) }
      None => ()
    }
  }
  None
}

///|
fn int_env(key : String, fallback : Int) -> Int {
  match @env.get_env_var(key) {
    Some(value) => @string.parse_int(value) catch { _ => fallback }
    None => fallback
  }
}

///|
fn allowed_models() -> Array[String] {
  // 没设就是空菜单。以前这里编两个 MiniCPM5 占位，菜单里于是始终躺着两个
  // 不存在的模型名——看着像「默认值」，其实是误导
  let raw = @env.get_env_var("LLM_WEB_MODELS").unwrap_or("")
  let models : Array[String] = []
  for part in raw.split(",") {
    let model = part.trim(chars=" \t").to_owned()
    if model.length() > 0 && !models.contains(model) {
      models.push(model)
    }
  }
  models
}

// ---------------------------------------------------------------- 路由

///|
async fn handle(
  config : ServerConfig,
  group : @async.TaskGroup[Unit],
  request : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  if request.path.has_prefix("/api/") {
    let label = match request.meth {
      Get => "GET"
      Post => "POST"
      _ => "OTHER"
    }
    note("api " + label + " " + request.path)
  }
  // request.path 带 query string（"\/?a=1"），路由前必须切掉，
  // 否则 /?autorun=1 会被当成一个不存在的静态文件。
  let raw = request.path
  let path = match raw.find("?") {
    Some(index) => raw[:index].to_owned()
    None => raw
  }
  match (request.meth, path) {
    (Get, "/api/meta") => send_json(conn, 200, meta_json(config))
    // 运行历史：扫 runs/ 目录，每条带磁盘上那份 request.json
    (Get, "/api/runs") =>
      send_json(
        conn,
        200,
        Json::object({ "runs": Json::array(scan_runs(config.work_dir)) }),
      )
    (Post, "/api/runs") => start_run(config, group, body, conn)
    (Put, _) if path.has_prefix("/api/runs/") =>
      put_annotations_route(config, path[10:].to_owned(), body, conn)
    (Delete, _) if path.has_prefix("/api/runs/") =>
      delete_run(config, path[10:].to_owned(), conn)
    (Get, _) if path.has_prefix("/api/runs/") =>
      get_run_route(config, path[10:].to_owned(), conn)
    // 测试集
    (Get, "/api/cases") =>
      send_json(
        conn,
        200,
        Json::object({ "sets": Json::array(case_sets(config)) }),
      )
    (Get, _) if path.has_prefix("/api/cases/") =>
      get_case_set(config, path[11:].to_owned(), conn)
    (Put, _) if path.has_prefix("/api/cases/") =>
      put_case_set(config, path[11:].to_owned(), body, conn)
    (Post, _) if path.has_prefix("/api/cases/") && path.has_suffix("/import") =>
      import_case_set(config, path[11:path.length() - 7].to_owned(), body, conn)
    (Delete, _) if path.has_prefix("/api/cases/") =>
      delete_case_set(config, path[11:].to_owned(), conn)
    // 预设
    (Get, "/api/presets") =>
      send_json(
        conn,
        200,
        Json::object({
          "presets": Json::array(read_presets(config.presets_path)),
        }),
      )
    (Put, "/api/presets") => put_presets(config, body, conn)
    (Get, _) => serve_static(config, path, conn)
    (Post, _) => send_text(conn, 404, "no such endpoint")
    _ => send_text(conn, 405, "method not allowed")
  }
}

///|
async fn serve_static(
  config : ServerConfig,
  path : String,
  conn : @http.ServerConnection,
) -> Unit {
  let relative = if path == "/" {
    "index.html"
  } else {
    strip_leading_slash(path)
  }
  // 只允许静态目录下的直接文件，挡掉 ../ 之类的路径穿越
  if relative.contains("..") || relative.contains("//") {
    send_text(conn, 400, "bad path")
    return
  }
  let full = config.static_dir + "/" + relative
  if !(@fs.exists(full) catch { _ => false }) {
    send_text(conn, 404, "not found: " + relative)
    return
  }
  let content = @fs.read_file(full) catch {
    _ => {
      send_text(conn, 500, "cannot read " + relative)
      return
    }
  }
  conn.send_response(200, "OK", extra_headers={
    "Content-Type": content_type(relative),
  })
  conn.write_string(content.text() catch { _ => "" })
  conn.end_response()
}

///|
fn strip_leading_slash(path : String) -> String {
  if path.has_prefix("/") {
    path[1:].to_owned()
  } else {
    path
  }
}

///|
fn content_type(path : String) -> String {
  match path {
    _ if path.has_suffix(".html") => "text/html; charset=utf-8"
    _ if path.has_suffix(".css") => "text/css; charset=utf-8"
    _ if path.has_suffix(".js") => "text/javascript; charset=utf-8"
    _ if path.has_suffix(".json") => "application/json; charset=utf-8"
    _ if path.has_suffix(".svg") => "image/svg+xml"
    _ if path.has_suffix(".ico") => "image/x-icon"
    _ => "application/octet-stream"
  }
}

///|
async fn meta_json(config : ServerConfig) -> Json {
  let default_set = default_case_set(config)
  let cases = read_case_set(case_set_path(config.cases_dir, default_set))
  Json::object({
    "models": Json::array(config.models.map(Json::string)),
    "caseSets": Json::array(case_sets(config)),
    "defaultCaseSet": Json::string(default_set),
    "cases": Json::array(cases),
    "defaults": Json::object({
      "repeats": Json::number(3.0),
      "maxTokens": Json::number(2048.0),
      "temperature": Json::number(0.0),
      "paceMs": Json::number(3000.0),
      "retry": Json::number(3.0),
      "system": Json::string(config.default_system),
    }),
    "hasKey": Json::boolean(config.api_key != ""),
    "baseUrl": Json::string(config.base_url),
    // 值是兜底的还是配的，页面得能分辨：空字段 + 兜底值 = 该拦的红线
    "baseUrlConfigured": Json::boolean(config.base_url_configured),
    "modelsConfigured": Json::boolean(config.models_configured),
  })
}

// ---------------------------------------------------------------- 测试集

///|
/// 测试集列表：[{name, count}]。
///
/// 直接返回数组而不是包好的 Json 对象：调用点都是把它塞进自己的响应里，
/// 包一层之后取出来还得再拆。
async fn case_sets(config : ServerConfig) -> Array[Json] {
  let sets : Array[Json] = []
  for name in list_case_sets(config.cases_dir) {
    let path = case_set_path(config.cases_dir, name)
    sets.push(
      Json::object({
        "name": Json::string(name),
        // 数解析出来的条数，不数行数：注释行和空行不是用例。
        "count": Json::number(read_case_set(path).length().to_double()),
      }),
    )
  }
  sets
}

///|
/// 默认测试集：有 `default` 就用它，否则第一个，一个都没有就是空串。
///
/// 不记住「上次选了哪个」：那是页面的状态（URL 参数），服务端不该有第二份。
async fn default_case_set(config : ServerConfig) -> String {
  let names = list_case_sets(config.cases_dir)
  if names.contains("default") {
    return "default"
  }
  match names {
    [first, ..] => first
    [] => ""
  }
}

///|
async fn get_case_set(
  config : ServerConfig,
  name : String,
  conn : @http.ServerConnection,
) -> Unit {
  if !is_safe_name(name) {
    send_text(conn, 400, bad_name_message())
    return
  }
  let path = case_set_path(config.cases_dir, name)
  if !(@fs.exists(path) catch { _ => false }) {
    send_text(conn, 404, "no such case set: " + name)
    return
  }
  send_json(
    conn,
    200,
    Json::object({
      "name": Json::string(name),
      "cases": Json::array(read_case_set(path)),
    }),
  )
}

///|
/// 整集覆盖写。名字不存在就是新建——「另存为一套」因此不需要单独的接口。
async fn put_case_set(
  config : ServerConfig,
  name : String,
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  if !is_safe_name(name) {
    send_text(conn, 400, bad_name_message())
    return
  }
  let obj = match read_json_body(body, conn) {
    Some(obj) => obj
    None => return
  }
  let items = match obj.get("cases") {
    Some(Array(items)) => items
    _ => {
      send_text(conn, 400, "body needs a `cases` array")
      return
    }
  }
  if items.length() > max_cases_per_set {
    send_text(conn, 400, "at most \{max_cases_per_set} cases per set")
    return
  }
  let normalized : Array[Json] = []
  let seen : Array[String] = []
  for i = 0; i < items.length(); i = i + 1 {
    let id = match case_id_of(items[i], i) {
      Ok(id) => id
      Err(message) => {
        send_text(conn, 400, message)
        return
      }
    }
    if seen.contains(id) {
      send_text(conn, 400, "duplicate case id: " + id)
      return
    }
    seen.push(id)
    // 缺 id 的补上：bench 侧按 id 过滤用例，缺 id 的条目会被静默丢掉，
    // 而页面上又看得见它——「勾了却没跑」是最难查的那种。
    normalized.push(with_id(items[i], id))
  }
  write_text(
    case_set_path(config.cases_dir, name),
    serialize_case_set(normalized),
  )
  note("case set '\{name}' saved (\{normalized.length()} case(s))")
  send_json(
    conn,
    200,
    Json::object({
      "name": Json::string(name),
      "count": Json::number(normalized.length().to_double()),
      "sets": Json::array(case_sets(config)),
      "defaultCaseSet": Json::string(default_case_set(config)),
    }),
  )
}

///|
/// 从一个纯文本文件建测试集（`POST /api/cases/<name>/import`，body: `{"path"}`）。
///
/// 这个服务端跑在你自己的机器上，路径也是你自己填的，所以由它去读文件，而不是
/// 让浏览器把文件内容读进来再传一遍。风险边界没有变化——能连上这个服务端的人
/// 本来就能让它跑任意 benchmark，见 SECURITY.md。
///
/// 一行一条 prompt，空行与 `#` 开头跳过；如果某一行本身是个带 `prompt` 的 JSON
/// 对象（也就是测试集文件），就按那条用例收，system / maxTokens 一起带上。
async fn import_case_set(
  config : ServerConfig,
  name : String,
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  if !is_safe_name(name) {
    send_text(conn, 400, bad_name_message())
    return
  }
  let obj = match read_json_body(body, conn) {
    Some(obj) => obj
    None => return
  }
  // 两种来路：path 是「服务端自己去读某个路径」（命令行式用法），text 是页面把
  // 文件内容直接送上来（浏览器里选的文件，服务端看不到它）。页面走后者
  let path = str_field(obj, "path").trim(chars=" \t\r\n").to_owned()
  let inline = str_field(obj, "text")
  let source = if path != "" {
    path
  } else if inline != "" {
    "（浏览器里选的文件）"
  } else {
    ""
  }
  let text = if path != "" {
    if !(@fs.exists(path) catch { _ => false }) {
      send_text(conn, 404, "no such file: " + path)
      return
    }
    // 别拿它当通用文件读取器：只收文本文件，且有大小上限
    let size = @fs.file_size(path) catch { _ => -1L }
    if size < 0L {
      send_text(conn, 500, "cannot stat: " + path)
      return
    }
    if size > max_import_bytes {
      send_text(
        conn,
        400,
        "file is too large (\{size} bytes, limit \{max_import_bytes})",
      )
      return
    }
    read_text(path)
  } else if inline != "" {
    if inline.length().to_int64() > max_import_bytes {
      send_text(
        conn,
        400,
        "text is too large (\{inline.length()} chars, limit \{max_import_bytes})",
      )
      return
    }
    inline
  } else {
    ""
  }
  if source == "" {
    send_text(conn, 400, "body needs a path or text")
    return
  }
  if text == "" {
    send_text(conn, 400, "file is empty or not readable as UTF-8 text")
    return
  }
  let cases : Array[Json] = []
  let mut counter = 0
  for raw in text.split("\n") {
    let line = raw.trim(chars=" \t\r").to_owned()
    if line == "" || line.has_prefix("#") {
      continue
    }
    if cases.length() >= max_cases_per_set {
      send_text(conn, 400, "at most \{max_cases_per_set} cases per set")
      return
    }
    counter = counter + 1
    // 测试集文件本身就长这样：能直接吃（system / maxTokens 一起带过来）
    match parse_json(line) {
      Some(json) =>
        match json {
          Object(entry) =>
            if entry.get("prompt") is Some(String(_)) {
              cases.push(json)
              continue
            }
          _ => ()
        }
      None => ()
    }
    cases.push(
      Json::object({
        "id": Json::string("\{name}-\{counter}"),
        "prompt": Json::string(line),
      }),
    )
  }
  if cases.length() == 0 {
    send_text(conn, 400, "no usable lines in the file")
    return
  }
  write_text(case_set_path(config.cases_dir, name), serialize_case_set(cases))
  note(
    "case set '\{name}' imported from \{source} (\{cases.length()} case(s))",
  )
  send_json(
    conn,
    200,
    Json::object({
      "name": Json::string(name),
      "count": Json::number(cases.length().to_double()),
      "source": Json::string(source),
      "sets": Json::array(case_sets(config)),
      "defaultCaseSet": Json::string(default_case_set(config)),
    }),
  )
}

///|
async fn delete_case_set(
  config : ServerConfig,
  name : String,
  conn : @http.ServerConnection,
) -> Unit {
  if !is_safe_name(name) {
    send_text(conn, 400, bad_name_message())
    return
  }
  let path = case_set_path(config.cases_dir, name)
  if !(@fs.exists(path) catch { _ => false }) {
    send_text(conn, 404, "no such case set: " + name)
    return
  }
  @fs.remove(path) catch {
    _ => {
      send_text(conn, 500, "cannot remove " + name)
      return
    }
  }
  note("case set '\{name}' deleted")
  send_json(
    conn,
    200,
    Json::object({
      "name": Json::string(name),
      "sets": Json::array(case_sets(config)),
      "defaultCaseSet": Json::string(default_case_set(config)),
    }),
  )
}

///|
fn bad_name_message() -> String {
  "bad name: 1–64 characters of [A-Za-z0-9._-], not starting with a dot"
}

///|
/// 保证一条用例带 id：缺了就补一个，其余字段原样保留。
fn with_id(json : Json, id : String) -> Json {
  guard json is Object(obj) else { return json }
  if obj.get("id") is Some(_) {
    return json
  }
  let copy : Map[String, Json] = Map([])
  obj.each(fn(key, value) { copy[key] = value })
  copy["id"] = Json::string(id)
  Json::object(copy)
}

// ---------------------------------------------------------------- 预设

///|
/// 预设的最大条数。超了说明该改测试集或分几次跑，而不是往这里堆。
let max_presets : Int = 50

///|
async fn put_presets(
  config : ServerConfig,
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  let obj = match read_json_body(body, conn) {
    Some(obj) => obj
    None => return
  }
  let items = match obj.get("presets") {
    Some(Array(items)) => items
    _ => {
      send_text(conn, 400, "body needs a `presets` array")
      return
    }
  }
  if items.length() > max_presets {
    send_text(conn, 400, "at most \{max_presets} presets")
    return
  }
  let names : Array[String] = []
  for i = 0; i < items.length(); i = i + 1 {
    match validate_preset(items[i], i) {
      Ok(_) => ()
      Err(message) => {
        send_text(conn, 400, message)
        return
      }
    }
    let name = match items[i] {
      Object(item) =>
        match item.get("name") {
          Some(String(name)) => name
          _ => ""
        }
      _ => ""
    }
    // 重名报错而不是「最后一个赢」：预设是按名字取的，留两份同名就是留个坑
    if names.contains(name) {
      send_text(conn, 400, "duplicate preset name: " + name)
      return
    }
    names.push(name)
  }
  write_text(config.presets_path, serialize_presets(items))
  note("presets saved (\{items.length()})")
  send_json(conn, 200, Json::object({ "presets": Json::array(items) }))
}

// ---------------------------------------------------------------- 运行历史

///|
/// 读一次运行的标注。运行不存在是 404，没有标注就是空表。
async fn get_annotations(
  config : ServerConfig,
  id : String,
  conn : @http.ServerConnection,
) -> Unit {
  if id.contains("/") || id.contains("..") || id.length() == 0 {
    send_text(conn, 400, "bad run id")
    return
  }
  let dir = config.work_dir + "/" + id
  if !(@fs.exists(dir) catch { _ => false }) {
    send_text(conn, 404, "no such run: " + id)
    return
  }
  let annotations = read_annotations(dir)
  send_json(
    conn,
    200,
    Json::object({
      "id": Json::string(id),
      "annotations": Json::array(annotations.map(fn(entry) { entry.to_json() })),
    }),
  )
}

///|
/// 写标注：整表覆盖。一个人用，一次一格的增量接口只会多一种对不上的可能。
async fn put_annotations_route(
  config : ServerConfig,
  suffix : String,
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  let slash = suffix.find("/")
  let id = match slash {
    Some(index) => suffix[:index].to_owned()
    None => suffix
  }
  let wanted = match slash {
    Some(index) => suffix[index + 1:].to_owned()
    None => ""
  }
  if wanted != "annotations" {
    send_text(conn, 404, "no such run endpoint")
    return
  }
  if id.contains("/") || id.contains("..") || id.length() == 0 {
    send_text(conn, 400, "bad run id")
    return
  }
  let dir = config.work_dir + "/" + id
  if !(@fs.exists(dir) catch { _ => false }) {
    send_text(conn, 404, "no such run: " + id)
    return
  }
  let obj = match read_json_body(body, conn) {
    Some(obj) => obj
    None => return
  }
  let items = match obj.get("annotations") {
    Some(Array(items)) => items
    _ => {
      send_text(conn, 400, "body needs an `annotations` array")
      return
    }
  }
  if items.length() > max_annotations {
    send_text(conn, 400, "at most \{max_annotations} annotations")
    return
  }
  let entries : Array[Annotation] = []
  let seen : Array[String] = []
  for i = 0; i < items.length(); i = i + 1 {
    let entry = match validate_annotation(items[i], i) {
      Ok(entry) => entry
      Err(message) => {
        send_text(conn, 400, message)
        return
      }
    }
    // 「这次运行 × 这道题 × 这个模型」只能有一条：两条的话，读的人不知道该信哪条
    let key = entry.case_id + "\u0000" + entry.model
    if seen.contains(key) {
      send_text(
        conn,
        400,
        "duplicate annotation for \{entry.case_id} / \{entry.model}",
      )
      return
    }
    seen.push(key)
    entries.push(entry)
  }
  match write_annotations(dir, entries) {
    Ok(_) => ()
    Err(message) => {
      send_text(conn, 500, message)
      return
    }
  }
  note("annotations for \{id}: \{entries.length()}")
  send_json(
    conn,
    200,
    Json::object({
      "id": Json::string(id),
      "count": Json::number(entries.length().to_double()),
    }),
  )
}

///|
async fn delete_run(
  config : ServerConfig,
  id : String,
  conn : @http.ServerConnection,
) -> Unit {
  if id.contains("/") || id.contains("..") || id.length() == 0 {
    send_text(conn, 400, "bad run id")
    return
  }
  let dir = config.work_dir + "/" + id
  if !(@fs.exists(dir) catch { _ => false }) {
    send_text(conn, 404, "no such run: " + id)
    return
  }
  @fs.rmdir(dir, recursive=true) catch {
    _ => {
      send_text(conn, 500, "cannot remove " + id)
      return
    }
  }
  note("run \{id} deleted")
  send_json(
    conn,
    200,
    Json::object({
      "id": Json::string(id),
      "runs": Json::array(scan_runs(config.work_dir)),
    }),
  )
}

///|
/// 读请求体并解析成 JSON 对象；失败时自己回响应并返回 None。
async fn read_json_body(
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Map[String, Json]? {
  let raw = body.read_all() catch {
    _ => {
      send_text(conn, 400, "cannot read request body")
      return None
    }
  }
  let json = @json.parse(raw.text() catch { _ => "" }) catch {
    _ => {
      send_text(conn, 400, "request body must be JSON")
      return None
    }
  }
  match json {
    Object(obj) => Some(obj)
    _ => {
      send_text(conn, 400, "request body must be a JSON object")
      None
    }
  }
}

///|
async fn start_run(
  config : ServerConfig,
  group : @async.TaskGroup[Unit],
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  let raw = body.read_all() catch {
    _ => {
      send_text(conn, 400, "cannot read request body")
      return
    }
  }
  let json = @json.parse(raw.text() catch { _ => "" }) catch {
    _ => {
      send_text(conn, 400, "request body must be JSON")
      return
    }
  }
  guard json is Object(obj) else {
    send_text(conn, 400, "request body must be a JSON object")
    return
  }
  let request = match parse_run_request(config, obj) {
    Ok(request) => request
    Err(message) => {
      send_text(conn, 400, message)
      return
    }
  }
  let (id, dir) = match allocate_run_dir(config.work_dir) {
    Ok(pair) => pair
    Err(message) => {
      send_text(conn, 500, message)
      return
    }
  }
  // apiKey is deliberately omitted from the on-disk request document. It is
  // only carried in the child environment below.
  let safe_json = sanitized_request_json(obj, request.case_set)
  write_text(dir + "/request.json", safe_json.stringify(indent=2) + "\n")
  let argv = match build_argv(config, request, dir) {
    Ok(argv) => argv
    Err(message) => {
      send_text(conn, 400, message)
      return
    }
  }
  let spawned = @process.spawn_orphan(
    config.bench_bin,
    argv,
    extra_env=run_env(config, request),
    inherit_env=true,
    stdout=@process.redirect_to_file(
      dir + "/stdout.log",
      create_mode=@fs.CreateOrTruncate,
    ),
    stderr=@process.redirect_to_file(
      dir + "/stderr.log",
      create_mode=@fs.CreateOrTruncate,
    ),
  ) catch {
    err => {
      send_text(conn, 500, "cannot start bench: " + err.to_string())
      return
    }
  }
  // 退出码在这里等出来写，而不是让 shell 写（Windows 上没有 sh 可写）。
  // 挂在服务器级别的 group 上：它比这次请求活得久，而请求已经把 202 发出去了。
  group.spawn_bg(async fn() {
    let code = @process.wait_pid(spawned) catch { _ => -1 }
    write_text(dir + "/exit_code", code.to_string() + "\n")
  })
  note("run \{id} started (pid \{spawned})")
  send_json(
    conn,
    202,
    Json::object({
      "id": Json::string(id),
      "total": Json::number(request.total().to_double()),
    }),
  )
}

///|
/// 网关密钥只在服务端；bench 从环境读它，不进命令行参数。
fn run_env(config : ServerConfig, request : RunRequest) -> Map[String, String] {
  {
    "MOONLLM_API_KEY": request.api_key.unwrap_or(config.api_key),
    "MOONLLM_BASE_URL": request.base_url.unwrap_or(config.base_url),
  }
}

///|
/// 解析并校验一次运行请求。
///
/// 所有值都从解析结果重新序列化，模型名走白名单，因此不会把用户输入原样
/// 拼进 shell 命令。
struct RunRequest {
  models : Array[String]
  /// 解析后的测试集名字（不是请求里那个可选的字符串）。
  case_set : String
  case_ids : Array[String]
  /// 请求里内联带过来的用例（一组临时 prompt，不走测试集文件）。非空时优先于 `case_ids`：
  /// 它们不进测试集文件，直接写进这次运行目录的 cases.jsonl。
  inline_cases : Array[Json]
  /// 这次运行的全局 system prompt。默认每条用例自己的 system 仍然可以覆盖它；
  /// system_override 为真时反过来：全局的覆盖掉用例自带的。
  system : String?
  system_override : Bool
  /// 这些模型带 enable_thinking: true。
  cot_thinking : Array[String]
  /// 这些模型带 reasoning_effort: "high"。
  cot_effort : Array[String]
  /// 串行 / 按模型并行 / 全部并发。
  parallel : String
  prompt : String?
  repeats : Int
  max_tokens : Int
  temperature : Double
  pace_ms : Int
  retry : Int
  base_url : String?
  api_key : String?
}

///|
fn RunRequest::total(self : RunRequest) -> Int {
  let case_count = if self.prompt is Some(_) {
    1
  } else if self.inline_cases.length() > 0 {
    self.inline_cases.length()
  } else {
    self.case_ids.length()
  }
  self.models.length() * case_count * self.repeats
}

///|
async fn parse_run_request(
  config : ServerConfig,
  obj : Map[String, Json],
) -> Result[RunRequest, String] {
  let models = match obj.get("models") {
    Some(Array(items)) =>
      items.map(fn(item) {
        match item {
          String(text) => text
          _ => ""
        }
      })
    _ => []
  }
  let models = models.filter(fn(model) {
    let clean = model.trim(chars=" \t\r\n")
    clean.length() > 0 &&
    clean.length() <= 128 &&
    !clean.contains("\n") &&
    !clean.contains("\r")
  })
  if models.is_empty() {
    return Err("models: pick at least one non-empty model id")
  }
  if models.length() > 8 {
    return Err("models: at most 8 model ids")
  }
  let case_ids = match obj.get("cases") {
    Some(Array(items)) =>
      items.map(fn(item) {
        match item {
          String(text) => text
          _ => ""
        }
      })
    _ => []
  }
  let prompt = match obj.get("prompt") {
    Some(String(text)) =>
      if text.trim(chars=" \t\r\n").length() > 0 {
        Some(text)
      } else {
        None
      }
    _ => None
  }
  // 内联用例先取出来：下面「至少给一样东西」的判断要把它算进去。
  let raw_inline = match obj.get("inlineCases") {
    Some(Array(items)) => items
    _ => []
  }
  if prompt is None && case_ids.is_empty() && raw_inline.length() == 0 {
    return Err("pick at least one case, or type a prompt")
  }
  // 测试集：请求里给了就用它，没给就用默认集。
  let case_set = match optional_string(obj, "caseSet") {
    Some(name) =>
      if is_safe_name(name) {
        name
      } else {
        return Err("caseSet: " + bad_name_message())
      }
    None => default_case_set(config)
  }
  // 内联用例：跟测试集 / 单条 prompt 三者互斥，
  // 同时给两个只会让人不确定到底跑了什么。
  if raw_inline.length() > 0 {
    if prompt is Some(_) || !case_ids.is_empty() {
      return Err(
        "inlineCases: pass either inline cases, or case ids, or a prompt",
      )
    }
    if raw_inline.length() > max_cases_per_set {
      return Err("inlineCases: at most \{max_cases_per_set} cases")
    }
    let normalized : Array[Json] = []
    let seen : Array[String] = []
    for i = 0; i < raw_inline.length(); i = i + 1 {
      let id = match case_id_of(raw_inline[i], i) {
        Ok(id) => id
        Err(message) => return Err("inlineCases: " + message)
      }
      if seen.contains(id) {
        return Err("inlineCases: duplicate case id: " + id)
      }
      seen.push(id)
      // 缺 id 的补上：bench 侧按 id 过滤，缺 id 的会被静默丢掉
      normalized.push(with_id(raw_inline[i], id))
    }
    let system = match optional_string(obj, "system") {
      Some(text) => {
        if text.length() > max_prompt_chars {
          return Err("system is too long")
        }
        Some(text)
      }
      None => None
    }
    return finish_run_request(
      obj,
      models,
      case_set,
      [],
      normalized,
      None,
      system,
    )
  }
  let set_path = case_set_path(config.cases_dir, case_set)
  if prompt is None && !(@fs.exists(set_path) catch { _ => false }) {
    return Err("caseSet: no such case set: " + case_set)
  }
  let known = read_case_set(set_path).map(fn(entry) {
    match entry {
      Object(item) =>
        match item.get("id") {
          Some(String(id)) => id
          _ => ""
        }
      _ => ""
    }
  })
  let case_ids = case_ids.filter(fn(id) { known.contains(id) })
  // 过滤之后是空的，就是「勾了但一个都不认得」——静默跑 0 条用例比报错难查得多
  if prompt is None && case_ids.is_empty() {
    return Err(
      "cases: none of the selected ids are in case set '" + case_set + "'",
    )
  }
  let system = match optional_string(obj, "system") {
    Some(text) => {
      if text.length() > max_prompt_chars {
        return Err("system is too long")
      }
      Some(text)
    }
    None => None
  }
  finish_run_request(obj, models, case_set, case_ids, [], prompt, system)
}

///|
/// 请求的公共部分（数值范围、网关覆盖）只写一遍：内联用例与测试集两条路径
/// 走同一套校验，不然它们会慢慢长歪。
fn finish_run_request(
  obj : Map[String, Json],
  models : Array[String],
  case_set : String,
  case_ids : Array[String],
  inline_cases : Array[Json],
  prompt : String?,
  system : String?,
) -> Result[RunRequest, String] {
  let repeats = int_of(obj, "repeats", 3)
  let max_tokens = int_of(obj, "maxTokens", 2048)
  let pace_ms = int_of(obj, "paceMs", 0)
  let retry = int_of(obj, "retry", 1)
  let temperature = number_of(obj, "temperature", 0.0)
  let base_url = optional_string(obj, "baseUrl")
  let api_key = optional_string(obj, "apiKey")
  let system_override = bool_of(obj, "systemOverride", false)
  let cot_thinking = model_list(obj, "cotThinking")
  let cot_effort = model_list(obj, "cotEffort")
  let parallel = match optional_string(obj, "parallel") {
    // 服务端只是把 bench 二进制 spawn 起来，不认它的包，所以这里是同一套取值的
    // 第二份校验（bench 侧 parse_parallel 那份是权威）
    Some(raw) =>
      match raw {
        "serial" | "models" | "all" => raw
        _ => return Err("parallel must be one of: serial, models, all")
      }
    None => "serial"
  }
  if base_url is Some(url) && url.length() > 2048 {
    return Err("baseUrl is too long")
  }
  if api_key is Some(key) && key.length() > 4096 {
    return Err("apiKey is too long")
  }
  if repeats < 1 || repeats > 20 {
    return Err("repeats must be between 1 and 20")
  }
  if max_tokens < 1 || max_tokens > 32768 {
    return Err("maxTokens must be between 1 and 32768")
  }
  if temperature < 0.0 || temperature > 2.0 {
    return Err("temperature must be between 0 and 2")
  }
  Ok({
    models,
    case_set,
    case_ids,
    inline_cases,
    prompt,
    system,
    system_override,
    cot_thinking,
    cot_effort,
    parallel,
    repeats,
    max_tokens,
    temperature,
    pace_ms,
    retry,
    base_url,
    api_key,
  })
}

///|
fn optional_string(obj : Map[String, Json], key : String) -> String? {
  match obj.get(key) {
    Some(String(value)) => Some(value)
    _ => None
  }
}

///|
/// Make the persisted request safe: credentials never enter request.json.
///
/// `caseSet` 写上**解析后**的名字：请求里没给时它是默认集，而历史重跑要重放
/// 的是「实际跑的那一套」，不是「当时的默认那一套」。
fn sanitized_request_json(obj : Map[String, Json], case_set : String) -> Json {
  let safe : Map[String, Json] = Map([])
  obj.each(fn(key, value) { if key != "apiKey" { safe[key] = value } })
  if case_set != "" {
    safe["caseSet"] = Json::string(case_set)
  }
  Json::object(safe)
}

///|
/// 拼 bench 的参数表。
///
/// 只返回**参数**（argv[0] 由 spawn 自己填成可执行文件路径）。以前这是一条 shell
/// 命令行，所以数组以二进制路径开头——现在它不再是 argv[0]，否则 bench 会把
/// 自己的路径当成一个flag（真的报过 `unknown flag: .../bench.exe`）。
///
/// 改成参数表的理由：以前这里是 `"/bin/sh", ["-c", ...]`，而 Windows 上没有
/// /bin/sh——整个工作台在那边第一下就死在起子进程上。附带两个好处：不用自己写
/// shell 转义（`quote` 已删），也不再有一条能被注入的命令串。
async fn build_argv(
  config : ServerConfig,
  request : RunRequest,
  dir : String,
) -> Result[Array[String], String] {
  let argv : Array[String] = [
    "--models",
    request.models.join(","),
    "--repeats",
    request.repeats.to_string(),
    "--max-tokens",
    request.max_tokens.to_string(),
    "--temperature",
    request.temperature.to_string(),
    "--json",
    dir + "/runs.jsonl",
    "--web-data",
    dir + "/data.json",
    // 页面靠这个文件里的 tick 行显示「正在生成、约 N tok/s」——没有它，
    // 一次运行在两次 case 之间就什么都不动，看上去像卡住了。
    "--progress",
    dir + "/progress.jsonl",
  ]
  match request.prompt {
    Some(prompt) => {
      argv.push("--prompt")
      argv.push(prompt)
    }
    None => {
      let path = dir + "/cases.jsonl"
      if request.inline_cases.length() > 0 {
        // 内联用例：不进测试集文件，直接落进这次运行目录。
        // bench 侧只认文件，所以这里就是把它们写成文件。
        let lines = StringBuilder()
        for entry in request.inline_cases {
          lines.write_string(entry.stringify())
          lines.write_char('\n')
        }
        write_text(path, lines.to_string())
      } else {
        let filtered = filter_cases(
          case_set_path(config.cases_dir, request.case_set),
          request.case_ids,
        )
        write_text(path, filtered)
      }
      argv.push("--cases")
      argv.push(path)
    }
  }
  // 全局 system：空的不发——bench 那边空值会覆盖成空串，而缺省才是它自己的默认值
  match request.system {
    Some(system) =>
      if system.trim(chars=" \t\r\n") != "" {
        argv.push("--system")
        argv.push(system)
        // 只有真的带了 system 才有「覆盖」这回事
        if request.system_override {
          argv.push("--system-override")
        }
      }
    None => ()
  }
  if request.parallel != "serial" {
    argv.push("--parallel")
    argv.push(request.parallel)
  }
  if request.cot_thinking.length() > 0 {
    argv.push("--cot-thinking")
    argv.push(request.cot_thinking.join(","))
  }
  if request.cot_effort.length() > 0 {
    argv.push("--cot-effort")
    argv.push(request.cot_effort.join(","))
  }
  if request.pace_ms > 0 {
    argv.push("--pace-ms")
    argv.push(request.pace_ms.to_string())
  }
  if request.retry > 0 {
    argv.push("--retry")
    argv.push(request.retry.to_string())
  }
  if request.api_key.unwrap_or(config.api_key) == "" {
    argv.push("--no-key")
  }
  Ok(argv)
}

///|
/// 按 id 过滤用例文件，保留原始行。
async fn filter_cases(path : String, ids : Array[String]) -> String {
  let out = StringBuilder()
  let text = read_text(path)
  for line in text.split("\n") {
    let content = line.trim(chars=" \t\r")
    if content.length() == 0 || content.has_prefix("#") {
      continue
    }
    let parsed = @json.parse(content.to_owned()) catch { _ => continue }
    guard parsed is Object(obj) else { continue }
    let id = match obj.get("id") {
      Some(String(id)) => id
      _ => continue
    }
    if ids.contains(id) {
      out.write_string(content.to_owned())
      out.write_char('\n')
    }
  }
  out.to_string()
}

///|
/// 原子地分配一个运行目录，返回 `(id, 目录路径)`。
///
/// **分配动作就是 `mkdir` 本身**：建已存在的目录会失败（`File exists`），
/// 所以两个并发请求不可能拿到同一个 id。.counter 只是个起点提示，
/// 免得每次都从 1 开始扫。
///
/// 之前是「读 .counter → 加一 → 写回 → mkdir recursive」，并发 POST 会同时
/// 读到同一个值、拿到同一个 id，然后双方往同一目录里写，互相覆盖。
async fn allocate_run_dir(
  work_dir : String,
) -> Result[(String, String), String] {
  let counter_path = work_dir + "/.counter"
  let mut n = @string.parse_int(
    read_text(counter_path).trim(chars=" \t\r\n").to_owned(),
  ) catch {
    _ => 0
  }
  for attempt = 0; attempt < 1000; attempt = attempt + 1 {
    n = n + 1
    let id = "run-\{n}"
    let dir = work_dir + "/" + id
    // 非 recursive：目录已存在时抛错，这就是我们要的原子性
    let created = try {
      @fs.mkdir(dir)
      true
    } catch {
      _ => false
    }
    if created {
      write_text(counter_path, n.to_string())
      return Ok((id, dir))
    }
  }
  Err("could not allocate a run directory under " + work_dir)
}

///|
/// Route the status document and the five result export forms.
async fn get_run_route(
  config : ServerConfig,
  suffix : String,
  conn : @http.ServerConnection,
) -> Unit {
  let slash = suffix.find("/")
  let id = match slash {
    Some(index) => suffix[:index].to_owned()
    None => suffix
  }
  let wanted = match slash {
    Some(index) => Some(suffix[index + 1:].to_owned())
    None => None
  }
  match wanted {
    Some("runs.jsonl") => send_run_file(config, id, "runs.jsonl", conn)
    Some("data.json") => send_run_file(config, id, "data.json", conn)
    Some("annotations") => get_annotations(config, id, conn)
    Some("context") => get_run_context(config, id, conn)
    Some("report.html") => send_report(config, id, conn)
    Some(_) => send_text(conn, 404, "no such run export")
    None => get_run(config, id, conn)
  }
}

///|
/// 这次运行到底发了什么：参数 + 每条用例实际生效的上下文。
///
/// 「模型答得不对」有相当一部分其实是「问得不对」——system 被用例级覆盖了、
/// 温度不一样、maxTokens 卡住了。这些都在运行目录里躺着，但页面看不到；把它们
/// 原样端出来，比让人去翻 cases.jsonl 靠谱。
///
/// 每条用例给的是**生效值**：用例自己的 system 优先，没有才用全局的——和
/// bench 里 `settings_for` 的规则逐字一致。前端要是自己合，迟早会合出两套规则。
async fn get_run_context(
  config : ServerConfig,
  id : String,
  conn : @http.ServerConnection,
) -> Unit {
  if id.contains("/") || id.contains("..") || id.length() == 0 {
    send_text(conn, 400, "bad run id")
    return
  }
  let dir = config.work_dir + "/" + id
  let request_text = read_text(dir + "/request.json")
  if request_text == "" {
    send_text(conn, 404, "run has no request document")
    return
  }
  let request = match parse_json(request_text) {
    Some(json) => json
    None => {
      send_text(conn, 500, "request document is unreadable")
      return
    }
  }
  let fields = obj_of(request)
  let global_system = str_field(fields, "system")
  let global_max_tokens = int_of(fields, "maxTokens", 0)
  let global_temperature = fields.get("temperature")
  // 勾了「覆盖测试集内的 system prompt」的话，上面那条赢，用例自带的只当作被盖掉
  let system_override = bool_of(fields, "systemOverride", false)
  // 用例文件可能不在：inline prompt 的运行只有一条、没有 cases.jsonl
  let cases : Array[Json] = []
  let cases_text = read_text(dir + "/cases.jsonl")
  for raw in cases_text.split("\n") {
    let line = raw.trim(chars=" \t\r").to_owned()
    if line == "" {
      continue
    }
    let entry = match parse_json(line) {
      None => continue
      Some(json) => obj_of(json)
    }
    let own_system = str_field(entry, "system")
    cases.push(
      context_case(
        entry,
        own_system,
        global_system,
        system_override,
        global_max_tokens,
        global_temperature,
      ),
    )
  }
  send_json(
    conn,
    200,
    Json::object({
      "id": Json::string(id),
      "request": request,
      "models": array_field(fields, "models"),
      "cases": Json::array(cases),
    }),
  )
}

///|
/// 一条用例的生效上下文：用例自己的值优先，没有才落到全局——和 bench 里
/// `settings_for` 的规则逐字一致。
fn context_case(
  entry : Map[String, Json],
  own_system : String,
  global_system : String,
  system_override : Bool,
  global_max_tokens : Int,
  global_temperature : Json?,
) -> Json {
  // 生效的 system 与「有没有被盖掉」两件事都要跟 override 走
  let effective = if system_override {
    global_system
  } else if own_system != "" {
    own_system
  } else {
    global_system
  }
  let overridden = if system_override {
    global_system != ""
  } else {
    own_system != ""
  }
  Json::object({
    "id": Json::string(str_field(entry, "id")),
    "prompt": Json::string(str_field(entry, "prompt")),
    "system": Json::string(effective),
    "systemOverridden": Json::boolean(overridden),
    "maxTokens": Json::number(
      int_of(entry, "maxTokens", global_max_tokens).to_double(),
    ),
    "temperature": match entry.get("temperature") {
      Some(value) => value
      None =>
        match global_temperature {
          Some(value) => value
          None => Json::null()
        }
    },
  })
}

///|
/// 从 Json 里取一个对象。

///|
/// 取一个字符串字段，缺失或类型不对都算空串。
fn str_field(fields : Map[String, Json], key : String) -> String {
  match fields.get(key) {
    Some(String(text)) => text
    _ => ""
  }
}

///|
/// 取一个数组字段，缺失就算空。
/// 一串模型名：和 models 走同一套清洗（去空白、限长、不许换行），顺带去重
fn model_list(obj : Map[String, Json], key : String) -> Array[String] {
  let raw = match obj.get(key) {
    Some(Array(items)) =>
      items.map(fn(item) {
        match item {
          String(text) => text
          _ => ""
        }
      })
    _ => []
  }
  let clean : Array[String] = []
  for model in raw {
    let name = model.trim(chars=" \t\r\n").to_owned()
    if name.length() > 0 &&
      name.length() <= 128 &&
      !name.contains("\n") &&
      !name.contains("\r") &&
      !clean.contains(name) {
      clean.push(name)
    }
  }
  clean
}

///|
fn array_field(fields : Map[String, Json], key : String) -> Array[Json] {
  match fields.get(key) {
    Some(Array(items)) => items
    _ => []
  }
}

///|
fn obj_of(json : Json) -> Map[String, Json] {
  match json {
    Object(fields) => fields
    _ => Map([])
  }
}

///|
async fn send_run_file(
  config : ServerConfig,
  id : String,
  name : String,
  conn : @http.ServerConnection,
) -> Unit {
  if id.contains("/") || id.contains("..") || id.length() == 0 {
    send_text(conn, 400, "bad run id")
    return
  }
  let path = config.work_dir + "/" + id + "/" + name
  if !(@fs.exists(path) catch { _ => false }) {
    send_text(conn, 404, "export is not ready")
    return
  }
  let content = @fs.read_file(path) catch {
    _ => {
      send_text(conn, 500, "cannot read export")
      return
    }
  }
  conn.send_response(200, "OK", extra_headers={
    "Content-Type": content_type(name),
    // 文件名都是简单 token（runs.jsonl / data.json），RFC 6266 不要求引号，
    // 而不引号就不用往字符串里塞双引号
    "Content-Disposition": "attachment; filename=" + name,
  })
  conn.write_string(content.text() catch { _ => "" })
  conn.end_response()
}

///|
async fn send_report(
  config : ServerConfig,
  id : String,
  conn : @http.ServerConnection,
) -> Unit {
  if id.contains("/") || id.contains("..") || id.length() == 0 {
    send_text(conn, 400, "bad run id")
    return
  }
  let dir = config.work_dir + "/" + id
  let report = dir + "/report/report.html"
  // 报告是打算存下来的东西，不能带着旧的判定——所以每次都把「当前标注合并后的
  // 数据」重新算一遍，和上次构建用的比**内容**：比 mtime 在同秒内不可靠
  // （真的踩过：标注改了、报告没重出）。
  let merged = merge_annotations(
    read_text(dir + "/data.json"),
    read_annotations(dir),
  )
  let merged_path = dir + "/report/data.json"
  let rebuild = !(@fs.exists(report) catch { _ => false }) ||
    read_text(merged_path) != merged
  if rebuild {
    let data = dir + "/data.json"
    if !(@fs.exists(data) catch { _ => false }) {
      send_text(conn, 409, "report is not ready")
      return
    }
    // 标注合并进喂给 ssg 的那份数据：报告里因此带着当时的判定与备注。
    // 合并写在 report/ 下面，不动 bench 产出的 data.json。
    @fs.mkdir(dir + "/report", recursive=true) catch {
      _ => ()
    }
    write_text(merged_path, merged)
    let pid = @process.spawn_orphan(
      config.ssg_bin,
      [],
      extra_env={
        "LLM_WEB_DATA": dir + "/report/data.json",
        "LLM_WEB_OUT": dir + "/report",
      },
      inherit_env=true,
    ) catch {
      _ => {
        send_text(conn, 500, "cannot start report generator")
        return
      }
    }
    ignore(@process.wait_pid(pid))
  }
  let html = read_text(report)
  let css = read_text(dir + "/report/site.css")
  // 下载是单文件，不能指望旁边的 site.css 跟着走：把样式内联进去，
  // 保存到本地或者贴给别人都是自包含的。
  let html = if css == "" { html } else { inline_css(html, css) }
  conn.send_response(200, "OK", extra_headers={
    "Content-Type": "text/html; charset=utf-8",
    "Content-Disposition": "attachment; filename=report.html",
  })
  conn.write_string(html)
  conn.end_response()
}

///|
/// 把样式表插到 `</head>` 前面。ssg 生成的 HTML 会引用同目录的 site.css，
/// 而下载下来的是单个文件，那个引用会悬空。
fn inline_css(html : String, css : String) -> String {
  match html.find("</head>") {
    Some(index) =>
      html[:index].to_owned() +
      "<style>\n" +
      css +
      "</style>\n" +
      html[index:].to_owned()
    None => html + "<style>\n" + css + "</style>\n"
  }
}

///|
async fn get_run(
  config : ServerConfig,
  id : String,
  conn : @http.ServerConnection,
) -> Unit {
  if id.contains("/") || id.contains("..") || id.length() == 0 {
    send_text(conn, 400, "bad run id")
    return
  }
  let dir = config.work_dir + "/" + id
  if !(@fs.exists(dir) catch { _ => false }) {
    send_text(conn, 404, "no such run")
    return
  }
  let exit_code = read_text(dir + "/exit_code").trim(chars=" \t\r\n").to_owned()
  // 运行中的计数只能来自进度事件：`runs.jsonl` 是 bench 跑完才一次性写出来的，
  // 整个运行期间它都是空的——照它数，进度条就会一直停在 0，直到结束才跳到 100%。
  let live_counts = progress_counts(dir + "/progress.jsonl")
  let file_done = count_lines(dir + "/runs.jsonl")
  let done = if file_done > live_counts.0 { file_done } else { live_counts.0 }
  let total = total_of(dir + "/request.json")
  let status = if exit_code.length() == 0 {
    "running"
  } else if exit_code == "0" {
    "done"
  } else {
    "failed"
  }
  let payload : Map[String, Json] = {
    "id": Json::string(id),
    "status": Json::string(status),
    "done": Json::number(done.to_double()),
    "total": Json::number(total.to_double()),
  }
  // 可选字段一律「有就加、没有就不加」。别发 null：MoonBit 派生的 Option 解码
  // 只认「键缺失」，遇到 null 会报 String::from_json: expected string，
  // 而客户端一旦整个响应解析失败就会把运行当成失败并停掉轮询。
  // （曾经就这么错过一次：运行中 exitCode 发 null，页面直接死在第一次轮询。）
  if exit_code.length() > 0 {
    payload["exitCode"] = Json::string(exit_code)
  }
  payload["tail"] = Json::string(tail_text(dir + "/stderr.log", 12))
  // 实时进度：文件最后一行的原样转发，外加「它有多旧」。页面据此区分
  // 「正在吐字」和「模型卡住了」——只有服务端知道这两个时钟的差。
  match last_progress(dir + "/progress.jsonl") {
    Some((line, age_ms)) => {
      payload["live"] = line
      payload["liveAgeMs"] = Json::number(age_ms)
    }
    None => ()
  }
  // 三个计数同样取两边的大者：文件里有就是最终的，没有就用事件里数出来的
  let counts = run_counts(dir + "/runs.jsonl")
  payload["failures"] = Json::number(
    @cmp.maximum(counts.0, live_counts.1).to_double(),
  )
  payload["retried"] = Json::number(
    @cmp.maximum(counts.1, live_counts.2).to_double(),
  )
  payload["truncated"] = Json::number(
    @cmp.maximum(counts.2, live_counts.3).to_double(),
  )
  if status == "done" {
    match parse_json(read_text(dir + "/data.json")) {
      Some(parsed) => payload["data"] = parsed
      None => ()
    }
  }
  if status == "failed" {
    payload["error"] = Json::string(tail_text(dir + "/stderr.log", 20))
  }
  send_json(conn, 200, Json::object(payload))
}

///|
/// 解析 JSON，解析不出来就返回 None——而不是一个 Json::null() 值。
/// 这两种在派生解码面前不是一回事：键缺失会被 Option 接受，null 会报错。
fn parse_json(text : String) -> Json? {
  if text == "" {
    return None
  }
  Some(@json.parse(text) catch { _ => return None })
}

///|
/// 从进度事件里数「跑完了几条 / 失败几条 / 重试几条 / 截断几条」。
///
/// 只认 `case_done` 行：`tick` 是过程，`case_start` 是「开始了但还没有结果」。
/// 文件不存在（旧运行）或读不出来都算全 0，页面照旧能看。
///
/// 返回 (完成, 失败, 重试, 截断)。
async fn progress_counts(path : String) -> (Int, Int, Int, Int) {
  let mut done = 0
  let mut failures = 0
  let mut retried = 0
  let mut truncated = 0
  for line in read_text(path).split("\n") {
    if !line.contains("\"event\":\"case_done\"") {
      continue
    }
    let json = @json.parse(line.trim(chars=" \t\r").to_owned()) catch {
      _ => continue
    }
    guard json is Object(obj) else { continue }
    done = done + 1
    match obj.get("ok") {
      Some(True) => ()
      _ => failures = failures + 1
    }
    match obj.get("attempts") {
      Some(Number(value, ..)) => if value > 1.0 { retried = retried + 1 }
      _ => ()
    }
    match obj.get("truncated") {
      Some(True) => truncated = truncated + 1
      _ => ()
    }
  }
  (done, failures, retried, truncated)
}

///|
/// Count live raw records, including retry and truncation counters.
async fn run_counts(path : String) -> (Int, Int, Int) {
  let mut failures = 0
  let mut retried = 0
  let mut truncated = 0
  for line in read_text(path).split("\n") {
    let json = @json.parse(line.trim(chars=" \t\r").to_owned()) catch {
      _ => continue
    }
    guard json is Object(obj) else { continue }
    if obj.get("ok") != Some(Json::boolean(true)) {
      failures += 1
    }
    match obj.get("attempts") {
      Some(Number(value, ..)) => if value.to_int() > 1 { retried += 1 }
      _ => ()
    }
    match obj.get("finish_reason") {
      Some(String(reason)) => if reason == "length" { truncated += 1 }
      _ => ()
    }
  }
  (failures, retried, truncated)
}

///|
/// 从 request.json 重算总次数（models × cases × repeats）。
async fn total_of(request_path : String) -> Int {
  let text = read_text(request_path)
  let json = @json.parse(text) catch { _ => return 0 }
  guard json is Object(obj) else { return 0 }
  let models = match obj.get("models") {
    Some(Array(items)) => items.length()
    _ => 0
  }
  let repeats = int_of(obj, "repeats", 1)
  let cases = match obj.get("prompt") {
    Some(String(prompt)) =>
      if prompt.trim(chars=" \t\r\n").length() > 0 {
        1
      } else {
        case_count(obj)
      }
    _ => case_count(obj)
  }
  models * cases * repeats
}

///|
fn case_count(obj : Map[String, Json]) -> Int {
  // 「一组临时 prompt」走 inlineCases，没有 cases 字段
  match obj.get("inlineCases") {
    Some(Array(items)) => if items.length() > 0 { return items.length() }
    _ => ()
  }
  match obj.get("cases") {
    Some(Array(items)) => items.length()
    _ => 0
  }
}

///|
async fn count_lines(path : String) -> Int {
  let text = read_text(path)
  let mut count = 0
  for line in text.split("\n") {
    if line.trim(chars=" \t\r").length() > 0 {
      count = count + 1
    }
  }
  count
}

///|
/// 末尾 N 行，给页面显示进度和错误。

///|
/// 进度文件的最后一行，以及它是多久以前写的（毫秒）。
///
/// 只认最后一行：它是关于**当下**的唯一陈述，前面那些都属于已经过去的请求。
/// 解析不出来就当没有——写入方可能正好写到一半，下一次轮询会补上。
async fn last_progress(path : String) -> (Json, Double)? {
  let text = @fs.read_file(path) catch { _ => return None }
  let body = text.text() catch { _ => return None }
  let mut last : String? = None
  for line in body.split("\n") {
    if line.trim(chars=" \t\r") != "" {
      last = Some(line.to_owned())
    }
  }
  match last {
    None => None
    Some(line) =>
      match parse_json(line) {
        None => None
        Some(json) => {
          // `t` 是 bench 侧写的 epoch 毫秒。两个进程同一台机器，可以直接比。
          let written = number_field(json, "t")
          let age = if written > 0.0 {
            @env.now().to_double() - written
          } else {
            0.0
          }
          Some((json, if age < 0.0 { 0.0 } else { age }))
        }
      }
  }
}

///|
/// 从 Json 里取一个数字字段，缺失或类型不对都算 0。
fn number_field(json : Json, key : String) -> Double {
  match json {
    Json::Object(obj) =>
      match obj.get(key) {
        Some(Json::Number(value, ..)) => value
        _ => 0.0
      }
    _ => 0.0
  }
}

///|
async fn tail_text(path : String, lines : Int) -> String {
  let text = read_text(path)
  let all : Array[String] = []
  for line in text.split("\n") {
    let content = line.trim(chars=" \t\r").to_owned()
    if content.length() > 0 {
      all.push(content)
    }
  }
  let start = if all.length() > lines { all.length() - lines } else { 0 }
  let out = StringBuilder()
  for i = start; i < all.length(); i = i + 1 {
    out.write_string(all[i])
    out.write_char('\n')
  }
  out.to_string()
}

// ---------------------------------------------------------------- 工具

///|
async fn send_json(
  conn : @http.ServerConnection,
  code : Int,
  payload : Json,
) -> Unit {
  send_text(conn, code, payload.stringify())
}

///|
async fn send_text(
  conn : @http.ServerConnection,
  code : Int,
  message : String,
) -> Unit {
  conn.send_response(code, "OK", extra_headers={
    "Content-Type": "application/json; charset=utf-8",
  })
  conn.write_string(message)
  conn.end_response()
}

///|
async fn read_text(path : String) -> String {
  let data = @fs.read_file(path) catch { _ => return "" }
  data.text() catch {
    _ => ""
  }
}

///|
async fn write_text(path : String, content : String) -> Unit {
  @fs.write_file(path, content, create_mode=@fs.CreateOrTruncate) catch {
    _ => ()
  }
}

///|
fn bool_of(obj : Map[String, Json], key : String, fallback : Bool) -> Bool {
  match obj.get(key) {
    Some(True) => true
    Some(False) => false
    _ => fallback
  }
}

///|
fn int_of(obj : Map[String, Json], key : String, fallback : Int) -> Int {
  match obj.get(key) {
    Some(Number(value, ..)) => value.to_int()
    _ => fallback
  }
}

///|
fn number_of(
  obj : Map[String, Json],
  key : String,
  fallback : Double,
) -> Double {
  match obj.get(key) {
    Some(Number(value, ..)) => value
    _ => fallback
  }
}

///|
/// stderr 写入必须串行化。
///
/// `@stdio.stderr` 是全局唯一的 `IoHandle`，而 `Server::run_forever` 给每个
/// 连接 `spawn_bg`：两个请求同时写一行日志，第二个会命中内部 guard 直接
/// abort（SIGABRT / 核心转储）。并发 POST 一压就复现，栈顶是
/// `Writer for stdio.Output::write_once` → 本函数。
let log_lock : @semaphore.Semaphore = @semaphore.Semaphore(1)

///|
/// 诊断与启动信息走 stderr：stdout 被重定向到文件时是块缓冲的，
/// 进程被 kill 会整块丢掉，排查时看不到任何东西。
async fn note(message : String) -> Unit {
  log_lock.acquire()
  defer log_lock.release()
  @stdio.stderr.write(message + "\n") catch {
    _ => ()
  }
}
