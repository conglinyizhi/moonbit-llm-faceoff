///|
/// 弹窗打开时锁住后面那页的滚动。
///
/// 不锁的话滚轮有两个落点：鼠标明明在弹窗上，滚的却是背后的页面；弹窗里的列表
/// 滚到底之后继续滚，滚动还会「传染」给 body（滚动链）。用户分不清自己在滚哪个
/// 界面，位置也会乱。
///
/// 盯的是 `.modal-backdrop` 的有无，而不是让 TEA 那边逐处去开关：以后多一个弹窗
/// 也自动适用，不会漏。锁的时候把滚动条让出来的宽度补回去，否则整页会横向跳一下。
extern "js" fn install_scroll_lock() -> Unit =
  #|() => {
  #|  const apply = () => {
  #|    const root = document.documentElement
  #|    const open = !!document.querySelector(".modal-backdrop")
  #|    if (open === root.classList.contains("modal-open")) return
  #|    if (open) {
  #|      // 滚动条消失后内容区会变宽，补回同样的宽度，页面不横跳
  #|      root.style.setProperty("--scrollbar-gap", window.innerWidth - root.clientWidth + "px")
  #|      root.classList.add("modal-open")
  #|    } else {
  #|      root.classList.remove("modal-open")
  #|      root.style.removeProperty("--scrollbar-gap")
  #|    }
  #|  }
  #|  apply()
  #|  // 弹窗由 vdom 加进来/摘掉，所以看 DOM 变化，不看模型状态
  #|  new MutationObserver(apply).observe(document.body, { childList: true, subtree: true })
  #|}
