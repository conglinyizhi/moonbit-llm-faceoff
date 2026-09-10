// llm_client 前端页：Rabbita SSG，样式由 precss 编译。
//
// 独立模块，刻意不依赖 conglinyizhi/llm_client：
//   - 库走 native + moonbitlang/async 0.20.1（被 moonllm 锁住）
//   - rabbita 需要 async 0.21.x
// 两者放进同一个 workspace 会强制统一 async 版本，进而打坏库。
// 所以页面只消费 bench CLI 导出的 data.json，统计仍只有一份实现。
name = "conglinyizhi/llm_client_web"

version = "0.1.0"

license = "Apache-2.0"

preferred_target = "native"

description = "Static page for the llm_client benchmark results (Rabbita SSG + precss)"

import {
  "moonbit-community/rabbita@0.15.7",
  "moonbitlang/async@0.21.2",
  "moonbitlang/x@0.5.1",
  "conglinyizhi/precss@0.1.0",
}
