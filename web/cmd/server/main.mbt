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
///   LLM_WEB_CASES   用例文件（默认 ../bench/cases.example.jsonl）
///   LLM_BENCH_BIN   bench 可执行文件（默认 ../_build/native/debug/build/cmd/bench/bench.exe）
///   LLM_WEB_MODELS  允许的模型白名单，逗号分隔
///   MOONLLM_API_KEY / OPENAI_API_KEY   网关密钥（不下发给浏览器）
///   MOONLLM_BASE_URL / OPENAI_BASE_URL 网关地址
async fn main {
  let port = int_env("LLM_WEB_PORT", 8137)
  let static_dir = @env.get_env_var("LLM_WEB_STATIC").unwrap_or("out")
  let work_dir = @env.get_env_var("LLM_WEB_WORK").unwrap_or("runs")
  let cases_path = @env.get_env_var("LLM_WEB_CASES").unwrap_or(
    "../bench/cases.example.jsonl",
  )
  let bench_bin = @env.get_env_var("LLM_BENCH_BIN").unwrap_or(
    "../_build/native/debug/build/cmd/bench/bench.exe",
  )
  let config : ServerConfig = {
    static_dir,
    work_dir,
    cases_path,
    bench_bin,
    models: allowed_models(),
    base_url: first_env(["MOONLLM_BASE_URL", "OPENAI_BASE_URL"]).unwrap_or(
      "https://api.openai.com/v1",
    ),
    api_key: first_env(["MOONLLM_API_KEY", "OPENAI_API_KEY"]).unwrap_or(""),
  }
  @fs.mkdir(work_dir, recursive=true) catch {
    _ => ()
  }
  if config.api_key == "" {
    note("warning: no MOONLLM_API_KEY / OPENAI_API_KEY in the environment")
  }
  note(
    "static=\{config.static_dir}  runs=\{config.work_dir}  cases=\{config.cases_path}",
  )
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
  server.run_forever() <| async fn(request, body, conn) {
    handle(config, request, body, conn)
  }
}

// ---------------------------------------------------------------- 配置

///|
struct ServerConfig {
  static_dir : String
  work_dir : String
  cases_path : String
  bench_bin : String
  models : Array[String]
  base_url : String
  api_key : String
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
  let raw = @env.get_env_var("LLM_WEB_MODELS").unwrap_or(
    "MiniCPM5-1B,MiniCPM5-2B",
  )
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
    (Post, "/api/runs") => start_run(config, body, conn)
    (Get, _) if path.has_prefix("/api/runs/") =>
      get_run(config, path[10:].to_owned(), conn)
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

// ---------------------------------------------------------------- API

///|
async fn meta_json(config : ServerConfig) -> Json {
  let cases : Array[Json] = []
  for entry in load_cases(config.cases_path) {
    cases.push(
      Json::object({
        "id": Json::string(entry.id),
        "prompt": Json::string(entry.prompt),
      }),
    )
  }
  Json::object({
    "models": Json::array(config.models.map(Json::string)),
    "cases": Json::array(cases),
    "defaults": Json::object({
      "repeats": Json::number(3.0),
      "maxTokens": Json::number(2048.0),
      "temperature": Json::number(0.0),
      "paceMs": Json::number(3000.0),
      "retry": Json::number(3.0),
    }),
    "hasKey": Json::boolean(config.api_key != ""),
    "baseUrl": Json::string(config.base_url),
  })
}

///|
/// 用例文件里的一条记录。只取 id 和 prompt，够页面用。
struct CaseEntry {
  id : String
  prompt : String
}

///|
async fn load_cases(path : String) -> Array[CaseEntry] {
  let text = read_text(path)
  let entries : Array[CaseEntry] = []
  let mut index = 0
  for line in text.split("\n") {
    index = index + 1
    let content = line.trim(chars=" \t\r")
    if content.length() == 0 || content.has_prefix("#") {
      continue
    }
    let parsed = @json.parse(content.to_owned()) catch { _ => continue }
    guard parsed is Object(obj) else { continue }
    let prompt = match obj.get("prompt") {
      Some(String(text)) => text
      _ => continue
    }
    let id = match obj.get("id") {
      Some(String(id)) => id
      _ => "case-\{index}"
    }
    entries.push({ id, prompt, })
  }
  entries
}

///|
async fn start_run(
  config : ServerConfig,
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
  write_text(dir + "/request.json", json.stringify(indent=2) + "\n")
  let command = match build_command(config, request, dir) {
    Ok(command) => command
    Err(message) => {
      send_text(conn, 400, message)
      return
    }
  }
  let spawned = @process.spawn_orphan(
    "/bin/sh",
    ["-c", command],
    extra_env=run_env(config),
    inherit_env=true,
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
fn run_env(config : ServerConfig) -> Map[String, String] {
  { "MOONLLM_API_KEY": config.api_key, "MOONLLM_BASE_URL": config.base_url }
}

///|
/// 解析并校验一次运行请求。
///
/// 所有值都从解析结果重新序列化，模型名走白名单，因此不会把用户输入原样
/// 拼进 shell 命令。
struct RunRequest {
  models : Array[String]
  case_ids : Array[String]
  prompt : String?
  repeats : Int
  max_tokens : Int
  temperature : Double
  pace_ms : Int
  retry : Int
}

///|
fn RunRequest::total(self : RunRequest) -> Int {
  let case_count = if self.prompt is Some(_) {
    1
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
  let models = models.filter(fn(model) { config.models.contains(model) })
  if models.is_empty() {
    return Err("models: pick at least one of " + config.models.join(", "))
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
  if prompt is None && case_ids.is_empty() {
    return Err("pick at least one case, or type a prompt")
  }
  let known = load_cases(config.cases_path).map(fn(entry) { entry.id })
  let case_ids = case_ids.filter(fn(id) { known.contains(id) })
  let repeats = int_of(obj, "repeats", 3)
  let max_tokens = int_of(obj, "maxTokens", 2048)
  let pace_ms = int_of(obj, "paceMs", 0)
  let retry = int_of(obj, "retry", 1)
  let temperature = number_of(obj, "temperature", 0.0)
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
    case_ids,
    prompt,
    repeats,
    max_tokens,
    temperature,
    pace_ms,
    retry,
  })
}

///|
/// 拼 bench 命令行，末尾把退出码写进 exit_code，供状态轮询判断完成。
async fn build_command(
  config : ServerConfig,
  request : RunRequest,
  dir : String,
) -> Result[String, String] {
  let argv : Array[String] = [
    config.bench_bin,
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
  ]
  match request.prompt {
    Some(prompt) => {
      argv.push("--prompt")
      argv.push(prompt)
    }
    None => {
      let filtered = filter_cases(config.cases_path, request.case_ids)
      let path = dir + "/cases.jsonl"
      write_text(path, filtered)
      argv.push("--cases")
      argv.push(path)
    }
  }
  if request.pace_ms > 0 {
    argv.push("--pace-ms")
    argv.push(request.pace_ms.to_string())
  }
  if request.retry > 0 {
    argv.push("--retry")
    argv.push(request.retry.to_string())
  }
  let quoted = argv.map(quote).join(" ")
  Ok(
    quoted +
    " > " +
    quote(dir + "/stdout.log") +
    " 2>> " +
    quote(dir + "/stderr.log") +
    "; echo $? > " +
    quote(dir + "/exit_code"),
  )
}

///|
/// 单引号包裹，内部单引号按 shell 规则转义。
fn quote(value : String) -> String {
  let buf = StringBuilder()
  buf.write_char('\'')
  for ch in value {
    if ch == '\'' {
      buf.write_string("'\\''")
    } else {
      buf.write_char(ch)
    }
  }
  buf.write_char('\'')
  buf.to_string()
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
  let done = count_lines(dir + "/runs.jsonl")
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
    "exitCode": if exit_code.length() == 0 {
      Json::null()
    } else {
      Json::string(exit_code)
    },
  }
  if status == "running" {
    payload["tail"] = Json::string(tail_text(dir + "/stderr.log", 12))
  }
  if status == "done" {
    let data = read_text(dir + "/data.json")
    let parsed = @json.parse(data) catch { _ => Json::null() }
    payload["data"] = parsed
  }
  if status == "failed" {
    payload["error"] = Json::string(tail_text(dir + "/stderr.log", 20))
  }
  send_json(conn, 200, Json::object(payload))
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
