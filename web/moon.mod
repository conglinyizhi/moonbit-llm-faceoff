// faceoff 前端页：Rabbita SSG，样式由 precss 编译。
//
// 独立模块，刻意不依赖 conglinyizhi/moonbit-llm-faceoff：
//   - rabbita 需要 async 0.21.x
//   - 库原来钉在 async 0.20.1，两边版本对不上，同一个 workspace 会强制统一
// 所以页面只消费 bench CLI 导出的 data.json，统计仍只有一份实现。
//
// 2025-09 更新：库也已经升到 0.21.3（当时是为了消掉 0.20.1 的 moon.mod 里
// `exclude` 的弃用警告），版本分歧没有了。理论上两边现在能并进同一个 workspace、
// 直接调 bench，不再需要子进程边界和 data.json 中转——那仍然是一次独立的改动，
// 没做。
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
