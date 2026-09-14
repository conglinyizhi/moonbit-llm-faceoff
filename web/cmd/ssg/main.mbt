///|
/// 静态报告导出：读 data.json → Rabbita SSR → out/report.html，样式由 precss 编译。
///
/// 结果区的组件来自 shared 包，和交互页（cmd/app）共用同一套，
/// 保证两边看到的结构一致。
///
/// 环境变量：
///   LLM_WEB_DATA  数据文件路径（默认 data.json）
///   LLM_WEB_OUT   输出目录（默认 out）
///
#warnings("-alert_experimental")
async fn main {
  let data_path = @env.get_env_var("LLM_WEB_DATA").unwrap_or("data.json")
  let out_dir = @env.get_env_var("LLM_WEB_OUT").unwrap_or("out")

  let raw = read_text(data_path)
  let data = if raw == "" {
    note("warning: cannot read \{data_path}; rendering an empty report")
    @shared.empty_page_data()
  } else {
    match @shared.parse_page_data(raw) {
      Ok(data) => data
      Err(message) => {
        note("error: " + message)
        @shared.empty_page_data()
      }
    }
  }

  // 1) SCSS → CSS（precss）
  let scss = read_text("styles/site.scss")
  if scss == "" {
    note("warning: styles/site.scss is empty or missing")
  }
  let css = @css.compile_scss(scss) catch {
    err => {
      note("error: precss failed on styles/site.scss: " + err.to_string())
      ""
    }
  }
  @fs.mkdir(out_dir, recursive=true) catch {
    _ => ()
  }
  write_file(out_dir + "/site.css", css)

  // 2) 渲染
  let app = @rabbita.new(fn() { page(data) })
  let rendered = app.render(url="http://127.0.0.1/report.html", timeout=5000) catch {
    _ => "<!DOCTYPE html><html><body>render error</body></html>"
  }
  // Rabbita SSR 的 <head> 默认不带 charset，补上避免中文乱码
  let with_charset = rendered.replace(
    old="<head>",
    new="<head><meta charset=\"utf-8\">",
  )
  write_file(out_dir + "/report.html", with_charset)
  note(
    "wrote \{out_dir}/report.html (\{data.models.length()} model(s), \{data.cases.length()} case(s))",
  )
}

///|
fn page(data : @shared.PageData) -> @rabbita.Val[@html.Html] {
  let (state, _emit) : (@rabbita.Val[Unit], @rabbita.Emit[Unit]) = @rabbita.create_pure_state(
    (),
    update=(model, _msg) => model,
  )
  state.view(_model => shell(data))
}

///|
fn shell(data : @shared.PageData) -> @html.Html {
  @html.html([
    @html.head([
      @html.meta(charset="utf-8"),
      @html.meta(name="viewport", content="width=device-width, initial-scale=1"),
      @html.node("title", @html.Attrs::build(), [txt("模型对比 - faceoff")]),
      @html.link(href="site.css", rel="stylesheet"),
    ]),
    @html.body(class="page", [
      @shared.el("header", "site-header", [
        @shared.el("div", "wrap site-header-inner", [
          @shared.el("div", "site-logo", [txt("faceoff")]),
          @shared.el("div", "site-meta", [
            txt(
              "\{data.models.length()} 个模型 · \{data.cases.length()} 条用例",
            ),
          ]),
        ]),
      ]),
      @shared.el("main", "wrap", [
        @shared.el("section", "hero", [
          @html.h1([txt("LLM 模型对比")]),
          @html.p([
            txt(
              "同一套用例、串行执行、流式计时得到的结果。指标取中位数；decode tok/s 只统计首 token 之后的生成窗口",
            ),
          ]),
        ]),
        @shared.results_section(data),
      ]),
      @shared.el("footer", "site-footer", [
        @shared.el("div", "wrap", [
          txt("数据来源：\{data.source}"),
          @html.br(),
          txt(
            "静态报告由 Rabbita SSR 生成；样式由 precss 从 styles/site.scss 编译。交互版见同一服务的首页",
          ),
        ]),
      ]),
    ]),
  ])
}

///|
fn txt(value : String) -> @html.Html {
  @html.text(value)
}

///|
async fn read_text(path : String) -> String {
  let data = @fs.read_file(path) catch { _ => return "" }
  data.text() catch {
    _ => ""
  }
}

///|
async fn write_file(path : String, content : String) -> Unit {
  @fs.write_file(path, content, create_mode=@fs.CreateOrTruncate) catch {
    err => note("error: cannot write \{path}: " + err.to_string())
  }
}

///|
async fn note(message : String) -> Unit {
  @stdio.stderr.write(message + "\n") catch {
    _ => ()
  }
}
