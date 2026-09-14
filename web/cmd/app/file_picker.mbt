///|
/// 「从文本文件生成新测试集」那颗按钮背后的文件选择器。
///
/// 为什么不能直接用服务端路径：页面在浏览器里跑，用户在文件对话框里选的是**他本机**
/// 的文件——服务端根本看不到那个路径。所以文件必须由浏览器读出来、把内容送到服务端。
///
/// 读文件必然是异步的，而这里不碰 MoonBit ↔ JS 的回调 ABI（那条路在这个栈里不稳），
/// 改用一个更笨但更可靠的桥：JS 读完之后把结果写进一个由 Rabbita 渲染的隐藏字段，
/// 再派发一次 input 事件——MoonBit 侧就当成普通输入事件接住，走原有的 @cmd 去 POST。
///
/// 字段里放的是 JSON：{"name": 文件名, "text": 文件内容}。名字要一起带过来，因为
/// 新建的集合名字默认取文件名（用户没填「新集名字」的时候）。
extern "js" fn pick_text_file(field_id : String) -> Unit =
  #|(fieldId) => {
  #|  const field = document.getElementById(fieldId)
  #|  if (!field) return
  #|  const input = document.createElement("input")
  #|  input.type = "file"
  #|  // 不限制扩展名：只要是文本就行，用户手上多半是 .txt / .jsonl / .md
  #|  input.style.display = "none"
  #|  document.body.appendChild(input)
  #|  input.addEventListener("change", () => {
  #|    const file = input.files && input.files[0]
  #|    if (!file) { input.remove(); return }
  #|    const reader = new FileReader()
  #|    reader.onload = () => {
  #|      field.value = JSON.stringify({ name: file.name, text: String(reader.result) })
  #|      field.dispatchEvent(new Event("input", { bubbles: true }))
  #|      input.remove()
  #|    }
  #|    reader.onerror = () => {
  #|      field.value = JSON.stringify({ name: file.name, error: "这个文件读不出来" })
  #|      field.dispatchEvent(new Event("input", { bubbles: true }))
  #|      input.remove()
  #|    }
  #|    reader.readAsText(file)
  #|  })
  #|  input.click()
  #|}
