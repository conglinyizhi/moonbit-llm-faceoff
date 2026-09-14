///|
/// 构建页面（交互页 + 静态报告），一步到位。
///
///   cd <模块根> && moon run --target native web/cmd/build
///
///   web/styles/site.scss  → web/cmd/ssg（precss + Rabbita SSR）→ web/out/site.css
///                                                              → web/out/report.html
///   web/cmd/app     (js)  → moon build                        → web/out/app.js
///   web/shell/index.html  → 复制                              → web/out/index.html
///
/// 构建入口放在包里而不是只放在仓库的 scripts/ 下：从 mooncakes 下载这个模块的人
/// 手上没有 scripts/build-web.mbtx，也应该能把页面构建出来、起服务端跑起来。
/// scripts/build-web.mbtx 只多做一件事：先用 bench 导出 data.json（那一步要用 CLI），
/// 页面构建本身只有这一份实现。
///
/// 路径都相对当前目录（模块根）。out/ 特意留在 web/ 下：服务端是从 web/ 起的，
/// 它按工作目录解析 out/、runs/、cases/、presets.json。
extern "c" fn c_exit(code : Int) -> Unit = "exit"

///|
fn text_of(data : &@io.Data) -> String {
  data.text() catch {
    _ => ""
  }
}

///|
async fn say(message : String) -> Unit {
  @stdio.stdout.write(message + "\n") catch {
    _ => ()
  }
}

///|
async fn note(message : String) -> Unit {
  @stdio.stderr.write(message + "\n") catch {
    _ => ()
  }
}

///|
async fn copy_file(from : String, to : String) -> Bool {
  let content = @fs.read_file(from) catch { _ => return false }
  @fs.write_file(to, content, create_mode=@fs.CreateOrTruncate) catch {
    _ => return false
  }
  true
}

///|
async fn exists(path : String) -> Bool {
  @fs.exists(path) catch {
    _ => false
  }
}

///|
/// 跑一个外部命令，拿到 (退出码, stdout, stderr)。
///
/// 可执行文件路径要**绝对**，即使同时给了 cwd：带 cwd 的相对路径在 POSIX 上没事
/// （fork 之后再 exec 才解析），而 Windows 的 CreateProcess 不是这么干的（踩过）。
async fn run(
  bin : String,
  args : Array[String],
  cwd : String,
) -> (Int, String, String) {
  let (code, out, err) = @process.collect_output(
    bin,
    args,
    inherit_env=true,
    cwd~,
  ) catch {
    err => return (-1, "", err.to_string())
  }
  (code, text_of(out), text_of(err))
}

///|
/// 同一个二进制的两种可能命名：这台机器上产物带 `.exe`，别处可能没有。
/// 两个都试，别猜平台——写死一种的代码在 CI 上把「构建成功」报成了失败。
async fn run_binary(
  cwd : String,
  path_without_suffix : String,
  args : Array[String],
) -> (Int, String, String) {
  let (code, out, err) = run(path_without_suffix + ".exe", args, cwd)
  if code >= 0 {
    return (code, out, err)
  }
  run(path_without_suffix, args, cwd)
}

///|
async fn main {
  let root = match @env.current_dir() {
    Some(dir) => dir
    None => {
      note("拿不到当前目录")
      c_exit(1)
      return
    }
  }
  let web = root + "/web"
  if !exists(web + "/styles/site.scss") {
    note(
      "这里看起来不是模块根：找不到 web/styles/site.scss。请在仓库根目录运行。",
    )
    c_exit(1)
    return
  }
  @fs.mkdir(web + "/out", recursive=true) catch {
    _ => ()
  }

  say("==> 编译样式与静态报告（web/cmd/ssg）")
  let (ssg_code, _, ssg_err) = run(
    "moon",
    ["build", "web/cmd/ssg", "--target", "native"],
    root,
  )
  if ssg_code != 0 {
    note(ssg_err)
    c_exit(1)
    return
  }
  // ssg 按工作目录找 data.json、把 out/ 写在脚下，所以它的 cwd 是 web/。
  let (report_code, report_out, report_err) = run_binary(
    web,
    root + "/_build/native/debug/build/web/cmd/ssg/ssg",
    [],
  )
  if report_code != 0 {
    note(report_err)
    c_exit(1)
    return
  }
  @stdio.stdout.write(report_out) catch {
    _ => ()
  }

  say("==> 编译交互页（js）")
  let (app_code, _, app_err) = run(
    "moon",
    ["build", "web/cmd/app", "--target", "js"],
    root,
  )
  if app_code != 0 {
    note(app_err)
    c_exit(1)
    return
  }
  if !copy_file(
      root + "/_build/js/debug/build/web/cmd/app/app.js",
      web + "/out/app.js",
    ) {
    note("拷贝 app.js 失败")
    c_exit(1)
    return
  }

  say("==> 外壳")
  if !copy_file(web + "/shell/index.html", web + "/out/index.html") {
    note("拷贝外壳失败")
    c_exit(1)
    return
  }

  say("")
  say("产物（web/out/ 下）：")
  for name in ["app.js", "index.html", "report.html", "site.css"] {
    if exists(web + "/out/" + name) {
      say("  " + name)
    }
  }
  say("")
  say(
    "启动（服务端要从 web/ 起，它按工作目录找 out/、runs/、cases/）：",
  )
  say("  cd web && moon run --target native web/cmd/server")
  say(
    "  端口打印在 stdout 第一行；换端口或数据目录：LLM_WEB_PORT / LLM_WEB_WORK / LLM_WEB_CASES_DIR …",
  )
}
