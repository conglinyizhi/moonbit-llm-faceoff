///|
/// 「开始前确认」里点「调整」时用的一小段 JS。
///
/// 做三件事：滚到那个目标、给它加一个 .spot 类、5 秒后摘掉。另外挂一个全局
/// input 监听——用户一动任何输入，所有 .spot 立刻摘掉，所以实际高亮时长取
/// 「5 秒」与「用户自己动手」里更短的那个。
///
/// 传的是 CSS 选择器（不只是 id）：一整组控件（运行方式的三个 radio、推理开关
/// 那几个勾）要亮的是它们的容器。早先只能传 id，于是那两处只能把 .spot 加在
/// 一个小控件上，再靠 :has() 把父容器点亮——浏览器不支持 :has() 时就完全没有
/// 反应。现在直接选容器，不依赖 :has()。
///
/// 这段状态只活在 DOM 上，没进 AppModel：它是一次性的视觉提示，不参与任何逻辑，
/// 也没必要让每次输入都触发一遍 vdom diff。
extern "js" fn spot_field(selector : String) -> Unit =
  #|(selector) => {
  #|  // 两种写法都收：裸 id（base-url）与 CSS 选择器（.parallel-row / #extra-models）。
  #|  // 早先这里只认 id，改成 querySelector 之后裸 id 会被当成标签名查——
  #|  // 于是十个「调整」静默失效
  #|  const el = document.getElementById(selector) || document.querySelector(selector)
  #|  if (!el) return
  #|  el.scrollIntoView({ block: "center", behavior: "smooth" })
  #|  el.classList.add("spot")
  #|  if (el.focus) { el.focus({ preventScroll: true }) }
  #|  clearTimeout(window.__spotTimer)
  #|  window.__spotTimer = setTimeout(() => el.classList.remove("spot"), 5000)
  #|  if (!window.__spotListener) {
  #|    window.__spotListener = true
  #|    document.addEventListener(
  #|      "input",
  #|      () => {
  #|        clearTimeout(window.__spotTimer)
  #|        document.querySelectorAll(".spot").forEach((n) => n.classList.remove("spot"))
  #|      },
  #|      true,
  #|    )
  #|  }
  #|}
