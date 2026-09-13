///|
/// 「开始前确认」里点「调整」时用的一小段 JS。
///
/// 做三件事：滚到那个输入框、给它加一个 .spot 类、5 秒后摘掉。另外挂一个全局
/// input 监听——用户一动任何输入，所有 .spot 立刻摘掉，所以实际高亮时长取
/// 「5 秒」与「用户自己动手」里更短的那个。
///
/// 这段状态只活在 DOM 上，没进 AppModel：它是一次性的视觉提示，不参与任何逻辑，
/// 也没必要让每次输入都触发一遍 vdom diff。
extern "js" fn spot_field(id : String) -> Unit =
  #|(id) => {
  #|  const el = document.getElementById(id)
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
