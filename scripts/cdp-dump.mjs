#!/usr/bin/env node
//
// 用 CDP 打开一个页面，真实等待一段时间后把 DOM 打印出来。
//
// 为什么不用 chromium --dump-dom --virtual-time-budget：虚拟时间会和页面里
// 真实发生的 fetch 抢时钟，经常在 /api/meta 还没回来时就把 DOM 转储了，
// 结果是「页面永远停在正在载入」。这里改成真实等待。
//
// 用法：node scripts/cdp-dump.mjs <debugPort> <url> <waitMs> [outFile] [shotPng]
//                      [--script <js>] [--script-wait <ms>]
//
// shotPng 给定时额外存一张整页截图（captureBeyondViewport），
// 用来做视觉检查——DOM 对了不代表页面长得对。
//
// --script 在初次等待之后执行（awaitPromise=true，所以可以是 async 函数），
// 然后再等 --script-wait 毫秒才转储。返回值与抛出的异常都打到 stderr，
// 调用方可以 grep —— 想验证「点一下按钮到底发生了什么」就用它。

import { writeFileSync } from "node:fs"

const argv = process.argv.slice(2)
const flags = {}
const positional = []
for (let i = 0; i < argv.length; i++) {
  if (argv[i].startsWith("--")) {
    flags[argv[i].slice(2)] = argv[i + 1] ?? true
    i++
  } else {
    positional.push(argv[i])
  }
}

const [port, url, waitMsRaw, outFile, shotFile] = positional
const waitMs = Number(waitMsRaw || 8000)
const scriptWait = Number(flags["script-wait"] || 1200)

const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()
const page = list.find((target) => target.type === "page")
if (!page) {
  console.error("no page target on the debugging port")
  process.exit(2)
}

const ws = new WebSocket(page.webSocketDebuggerUrl)
let seq = 0
const pending = new Map()
const notes = []

ws.onmessage = (message) => {
  const msg = JSON.parse(message.data)
  if (msg.id && pending.has(msg.id)) {
    pending.get(msg.id)(msg)
    pending.delete(msg.id)
    return
  }
  if (msg.method === "Runtime.exceptionThrown") {
    const details = msg.params.exceptionDetails
    notes.push("EXCEPTION " + (details.exception?.description || details.text || ""))
  }
  if (msg.method === "Runtime.consoleAPICalled" && msg.params.type === "error") {
    notes.push(
      "CONSOLE.error " +
        msg.params.args.map((a) => a.value ?? a.description ?? "").join(" "),
    )
  }
}

const call = (method, params = {}) =>
  new Promise((resolve) => {
    const id = ++seq
    pending.set(id, resolve)
    ws.send(JSON.stringify({ id, method, params }))
  })

await new Promise((resolve) => (ws.onopen = resolve))
await call("Runtime.enable")
await call("Page.enable")
// 固定视口宽度，否则 headless 默认 800×600，截图会很窄
await call("Emulation.setDeviceMetricsOverride", {
  width: 1200,
  height: 900,
  deviceScaleFactor: 1,
  mobile: false,
})
await call("Page.navigate", { url })

const evaluate = async (expression) => {
  const outcome = await call("Runtime.evaluate", {
    expression,
    returnByValue: true,
  })
  return outcome.result?.result?.value
}

// 等条件满足，而不是死等。
//
// waitMs 从「必须等这么久」变成「最多等这么久」：页面本地渲染 + 三个本地 fetch
// 通常几百毫秒就绪，而 e2e 里有近二十次转储，每次都硬等 6–8 秒，加起来就是全部
// 时间的绝大部分。等不到就照旧往下走（让上层断言去报错，而不是在这里假装成功），
// 所以最坏情况与改动前一样。
if (flags["wait-for"]) {
  const started = Date.now()
  const deadline = started + waitMs
  let satisfied = false
  for (;;) {
    if (await evaluate(String(flags["wait-for"]))) {
      satisfied = true
      break
    }
    if (Date.now() >= deadline) {
      break
    }
    await new Promise((resolve) => setTimeout(resolve, 80))
  }
  // 等到了多久、还是等满了上限，都记一笔：前者是这次提速的依据，后者说明
  // 条件写错了或者页面真的没进那个状态（后面的断言多半会跟着报错）
  notes.push(
    (satisfied ? "WAIT-FOR ok " : "WAIT-FOR timeout ") +
      (Date.now() - started) +
      "ms " +
      flags["wait-for"],
  )
} else {
  await new Promise((resolve) => setTimeout(resolve, waitMs))
}

// 剪贴板读取要显式授权，否则 navigator.clipboard.readText() 直接抛。
if (flags.script) {
  await call("Browser.grantPermissions", {
    origin: new URL(url).origin,
    permissions: ["clipboardReadWrite", "clipboardSanitizedWrite"],
  })
  const outcome = await call("Runtime.evaluate", {
    expression: String(flags.script),
    returnByValue: true,
    awaitPromise: true,
  })
  const details = outcome.result?.exceptionDetails
  if (details) {
    notes.push(
      "SCRIPT ERROR " +
        (details.exception?.description || details.text || "unknown"),
    )
  }
  const value = outcome.result?.result?.value
  if (value !== undefined) {
    notes.push("SCRIPT " + JSON.stringify(value))
  }
  // 脚本之后的等待同样改成「等 DOM 稳定」：脚本自己 await 过的那部分已经过去了，
  // 这里只需要等它引发的重渲染落地。最少 200ms，最多 scriptWait。
  const drainDeadline = Date.now() + scriptWait
  let previous = ""
  let stableSince = 0
  for (;;) {
    const now = Date.now()
    const current = await evaluate("document.documentElement.outerHTML")
    if (current === previous) {
      if (stableSince === 0) {
        stableSince = now
      } else if (now - stableSince >= 200) {
        break
      }
    } else {
      previous = current
      stableSince = 0
    }
    if (now >= drainDeadline) {
      break
    }
    await new Promise((resolve) => setTimeout(resolve, 80))
  }
}

const result = await call("Runtime.evaluate", {
  expression: "document.documentElement.outerHTML",
  returnByValue: true,
})
const html = result.result?.result?.value ?? ""

if (outFile) {
  writeFileSync(outFile, html)
} else {
  process.stdout.write(html)
}
if (shotFile) {
  const shot = await call("Page.captureScreenshot", {
    format: "png",
    captureBeyondViewport: true,
  })
  if (shot.result?.data) {
    writeFileSync(shotFile, Buffer.from(shot.result.data, "base64"))
  } else {
    process.stderr.write("screenshot failed\n")
  }
}
if (notes.length > 0) {
  process.stderr.write(notes.join("\n") + "\n")
}
ws.close()
process.exit(0)
