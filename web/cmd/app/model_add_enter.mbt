///|
/// 模型输入框里按回车 = 按「识别」。
///
/// 为什么不在 MoonBit 侧挂 on_keydown：Rabbita 的 `@html.input` 没有 on_keydown
/// 参数（别的元素有），而 `Keyboard` 是抽象类型、取不到 key；绕过去要么自己拼
/// `Attrs`，要么改上游。
///
/// 这里换成「把回车翻译成点一下按钮」：按钮本来就在 DOM 里，点它走的是同一条
/// Msg 通道，效果与手点完全一致。事件挂在 document 上（委托），因为输入框会被
/// vdom 重建成新节点，挂在元素上会随重建失效。
///
/// isComposing 那道门是给输入法的：中文输入法里回车是「上屏」，此时不该把还没
/// 确定的候选名加进去。
extern "js" fn install_enter_to_identify() -> Unit =
  #|() => {
  #|  document.addEventListener("keydown", (event) => {
  #|    if (event.key !== "Enter") return
  #|    const input = event.target
  #|    if (!input || input.id !== "extra-models") return
  #|    if (event.isComposing) return
  #|    const button = document.querySelector(".model-add button")
  #|    if (!button) return
  #|    event.preventDefault()
  #|    button.click()
  #|  })
  #|}
