///|
/// 用例集、预设、运行历史的文件层。
///
/// 只做文件和 JSON，不碰 HTTP：路由与响应在 main.mbt。
/// 分出来的理由很直接——main.mbt 快一千行，而「扫描 runs/」「读写 cases/」
/// 跟请求处理没有关系。

///|
/// 用例集和预设的名字会变成路径片段，所以必须严格：只允许
/// `[A-Za-z0-9._-]`，不许以点开头，不许出现 `..`。
fn is_safe_name(name : String) -> Bool {
  if name.length() == 0 || name.length() > 64 {
    return false
  }
  if name.has_prefix(".") || name.contains("..") {
    return false
  }
  for ch in name {
    let letter = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
    let digit = ch >= '0' && ch <= '9'
    if !(letter || digit || ch == '-' || ch == '_' || ch == '.') {
      return false
    }
  }
  true
}

///|
fn case_set_path(dir : String, name : String) -> String {
  dir + "/" + name + ".jsonl"
}

///|
/// 目录里所有用例集的名字，按名字排序。
async fn list_case_sets(dir : String) -> Array[String] {
  let names : Array[String] = []
  let files = @fs.readdir(dir, sort=true) catch { _ => [] }
  for file in files {
    if !file.has_suffix(".jsonl") {
      continue
    }
    let name = file[:file.length() - 6].to_owned()
    if is_safe_name(name) {
      names.push(name)
    }
  }
  names
}

///|
/// 读一个用例集，逐条原样返回。
///
/// 「原样」是有意的：页面上编辑要能往返，不能只认识 id 和 prompt 就把
/// system / max_tokens / temperature 丢掉。
async fn read_case_set(path : String) -> Array[Json] {
  let entries : Array[Json] = []
  for line in read_text(path).split("\n") {
    let content = line.trim(chars=" \t\r")
    if content.length() == 0 || content.has_prefix("#") {
      continue
    }
    let parsed = @json.parse(content.to_owned()) catch { _ => continue }
    guard parsed is Object(_) else { continue }
    entries.push(parsed)
  }
  entries
}

///|
/// 一个用例集的条数上限。本地工具，超过这个数说明用错地方了，
/// 而不是说明这里该支持更大的集合。
let max_cases_per_set : Int = 500

///|
/// 一条用例的上限，跟 20 万字符的 prompt 说拜拜。
let max_prompt_chars : Int = 20000

///|
/// 校验一条用例，返回它的 id。规则与 `bench --cases` 的解析一致：
/// `prompt` 必填且非空，`id` 可省（用序号兜底），其余字段原样保留。
fn case_id_of(json : Json, index : Int) -> Result[String, String] {
  guard json is Object(obj) else {
    return Err("case #\{index + 1}: must be a JSON object")
  }
  let prompt = match obj.get("prompt") {
    Some(String(text)) => text
    _ => return Err("case #\{index + 1}: needs a string `prompt`")
  }
  if prompt.trim(chars=" \t\r\n").length() == 0 {
    return Err("case #\{index + 1}: `prompt` is empty")
  }
  if prompt.length() > max_prompt_chars {
    return Err(
      "case #\{index + 1}: `prompt` is longer than \{max_prompt_chars} characters",
    )
  }
  let id = match obj.get("id") {
    Some(String(id)) => id
    None => "case-\{index + 1}"
    _ => return Err("case #\{index + 1}: `id` must be a string")
  }
  if id.trim(chars=" \t\r\n").length() == 0 {
    return Err("case #\{index + 1}: `id` is empty")
  }
  if id.length() > 128 {
    return Err("case #\{index + 1}: `id` is longer than 128 characters")
  }
  Ok(id)
}

///|
/// 把一个用例集序列化成 JSON Lines —— 和 `bench --cases` 读的、手写的
/// 文件是同一种东西，所以 CLI 和页面看到的是同一份数据。
fn serialize_case_set(entries : Array[Json]) -> String {
  let out = StringBuilder()
  for entry in entries {
    out.write_string(entry.stringify())
    out.write_char('\n')
  }
  out.to_string()
}

// ---------------------------------------------------------------- 预设

///|
fn preset_name(obj : Map[String, Json]) -> String {
  match obj.get("name") {
    Some(String(name)) => name
    _ => ""
  }
}

///|
/// 读预设。文件不在或者坏掉都当成「没有预设」：这只是便利功能，
/// 不该因为它整个页面起不来。
async fn read_presets(path : String) -> Array[Json] {
  if !(@fs.exists(path) catch { _ => false }) {
    return []
  }
  let parsed = @json.parse(read_text(path)) catch { _ => return [] }
  guard parsed is Object(obj) else { return [] }
  match obj.get("presets") {
    Some(Array(items)) =>
      items.filter(fn(item) {
        guard item is Object(item) else { return false }
        is_safe_name(preset_name(item))
      })
    _ => []
  }
}

///|
/// 校验一个预设：名字要安全（它是键），模型 1–8 个，数值走和运行请求同一套
/// 范围——页面存下来的东西必须能被 POST /api/runs 原样吃回去。
fn validate_preset(json : Json, index : Int) -> Result[Unit, String] {
  guard json is Object(obj) else {
    return Err("preset #\{index + 1}: must be a JSON object")
  }
  let name = preset_name(obj)
  if !is_safe_name(name) {
    return Err(
      "preset #\{index + 1}: `name` must be 1–64 characters of [A-Za-z0-9._-]",
    )
  }
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
    clean.length() > 0 && clean.length() <= 128
  })
  if models.is_empty() {
    return Err("preset `\{name}`: needs at least one model id")
  }
  if models.length() > 8 {
    return Err("preset `\{name}`: at most 8 model ids")
  }
  for key in ["repeats", "maxTokens", "paceMs", "retry"] {
    match obj.get(key) {
      None => ()
      Some(Number(value, ..)) =>
        if value < 0.0 || value > 32768.0 {
          return Err("preset `\{name}`: `\{key}` is out of range")
        }
      Some(_) => return Err("preset `\{name}`: `\{key}` must be a number")
    }
  }
  match obj.get("temperature") {
    None => ()
    Some(Number(value, ..)) =>
      if value < 0.0 || value > 2.0 {
        return Err("preset `\{name}`: `temperature` must be between 0 and 2")
      }
    Some(_) => return Err("preset `\{name}`: `temperature` must be a number")
  }
  match obj.get("baseUrl") {
    None => ()
    Some(String(url)) =>
      if url.length() > 2048 {
        return Err("preset `\{name}`: `baseUrl` is too long")
      }
    Some(_) => return Err("preset `\{name}`: `baseUrl` must be a string")
  }
  Ok(())
}

///|
fn serialize_presets(presets : Array[Json]) -> String {
  Json::object({ "presets": Json::array(presets) }).stringify(indent=2) + "\n"
}

// ---------------------------------------------------------------- 运行历史

///|
/// 从 data.json 的汇总里数出失败 / 重试 / 截断。
///
/// 不自己数 runs.jsonl：汇总的口径只有一处实现（`summarize`），这里再做一遍
/// 就是第二份真相。data.json 是运行结束时才写的，所以没跑完的运行报 0。
async fn run_counters(dir : String) -> (Int, Int, Int) {
  let data_path = dir + "/data.json"
  if !(@fs.exists(data_path) catch { _ => false }) {
    return (0, 0, 0)
  }
  let parsed = @json.parse(read_text(data_path)) catch { _ => return (0, 0, 0) }
  guard parsed is Object(obj) else { return (0, 0, 0) }
  let summaries = match obj.get("summaries") {
    Some(Array(items)) => items
    _ => []
  }
  let mut failures = 0
  let mut retried = 0
  let mut truncated = 0
  for item in summaries {
    guard item is Object(summary) else { continue }
    failures = failures + int_of(summary, "failures", 0)
    retried = retried + int_of(summary, "retried", 0)
    truncated = truncated + int_of(summary, "truncated", 0)
  }
  (failures, retried, truncated)
}

///|
/// 数 runs.jsonl 里非空行的行数，当进度用（每完成一次尝试追加一行）。
/// main.mbt 里已经有一个同名的旧实现，等它退休后这个名字再收回来。
async fn count_result_lines(path : String) -> Int {
  let mut count = 0
  for line in read_text(path).split("\n") {
    if line.trim(chars=" \t\r").length() > 0 {
      count = count + 1
    }
  }
  count
}

///|
/// 扫一遍运行目录，返回按开始时间倒序的历史。
///
/// 每条带上原始的 `request`（磁盘上那份，本来就没有 apiKey），页面据此就能
/// 原样重跑，不用再造一套「历史里存什么」的格式。
async fn scan_runs(work_dir : String) -> Array[Json] {
  let runs : Array[Json] = []
  let entries = @fs.readdir(work_dir, sort=false) catch { _ => [] }
  for entry in entries {
    if !is_safe_name(entry) {
      continue
    }
    let dir = work_dir + "/" + entry
    let request_path = dir + "/request.json"
    if !(@fs.exists(request_path) catch { _ => false }) {
      continue
    }
    let parsed_request = @json.parse(read_text(request_path)) catch {
      _ => Json::null()
    }
    let request = match parsed_request {
      Object(obj) => obj
      _ => Map([])
    }
    let models = string_array_of(request, "models")
    let cases = string_array_of(request, "cases")
    let repeats = int_of(request, "repeats", 1)
    let case_count = if request.get("prompt") is Some(_) {
      1
    } else {
      cases.length()
    }
    let total = models.length() * case_count * repeats
    // 外层 sh 最后写 exit_code，所以「文件在不在」就是跑完没跑完，
    // 「内容是不是 0」就是成功没成功。
    let exit_code = read_text(dir + "/exit_code")
      .trim(chars=" \t\r\n")
      .to_owned()
    let status = if exit_code.length() == 0 {
      "running"
    } else if exit_code == "0" {
      "ok"
    } else {
      "failed"
    }
    let (failures, retried, truncated) = run_counters(dir)
    let mtime = @fs.mtime(request_path) catch { _ => (0L, 0) }
    let started_at = mtime.0.to_double()
    runs.push(
      Json::object({
        "id": Json::string(entry),
        "startedAt": Json::number(started_at),
        "status": Json::string(status),
        "exitCode": Json::string(exit_code),
        "request": Json::object(request),
        "total": Json::number(total.to_double()),
        "done": Json::number(
          count_result_lines(dir + "/runs.jsonl").to_double(),
        ),
        "failures": Json::number(failures.to_double()),
        "retried": Json::number(retried.to_double()),
        "truncated": Json::number(truncated.to_double()),
      }),
    )
  }
  runs.sort_by(fn(a, b) {
    let left = started_at_of(b)
    let right = started_at_of(a)
    if left < right {
      -1
    } else if left > right {
      1
    } else {
      0
    }
  })
  runs
}

///|
fn started_at_of(json : Json) -> Double {
  guard json is Object(obj) else { return 0.0 }
  number_of(obj, "startedAt", 0.0)
}

///|
fn string_array_of(obj : Map[String, Json], key : String) -> Array[String] {
  match obj.get(key) {
    Some(Array(items)) =>
      items.map(fn(item) {
        match item {
          String(text) => text
          _ => ""
        }
      })
    _ => []
  }
}
