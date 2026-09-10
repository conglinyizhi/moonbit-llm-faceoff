// faceoff 前端页：Rabbita SSG，样式由 precss 编译。
//
// 独立模块，刻意不依赖 conglinyizhi/moonbit-llm-faceoff：
//   - 库钉在 moonbitlang/async 0.20.1
//   - rabbita 需要 async 0.21.x
// 两者放进同一个 workspace 会强制统一 async 版本，进而打坏库。
// 所以页面只消费 bench CLI 导出的 data.json，统计仍只有一份实现。
//
// 注：这个分歧只剩 async 版本了（库已不依赖任何第三方 LLM 包）。
// 如果把库升到 0.21.x，两边就能并进同一个 workspace、直接调 bench，
// 不再需要子进程边界和 data.json 中转——那是一次独立的改动，没做。
name = "conglinyizhi/moonbit-llm-faceoff-web"

version = "0.1.0"

license = "MIT"

preferred_target = "native"

description = "Static page for the faceoff benchmark results (Rabbita SSG + precss)"

import {
  "moonbit-community/rabbita@0.15.7",
  "moonbitlang/async@0.21.2",
  "moonbitlang/x@0.5.1",
  "conglinyizhi/precss@0.1.1",
}
