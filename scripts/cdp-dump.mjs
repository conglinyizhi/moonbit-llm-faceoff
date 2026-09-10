#!/usr/bin/env node
//
// 用 CDP 打开一个页面，真实等待一段时间后把 DOM 打印出来。
//
// 为什么不用 chromium --dump-dom --virtual-time-budget：虚拟时间会和页面里
// 真实发生的 fetch 抢时钟，经常在 /api/meta 还没回来时就把 DOM 转储了，
// 结果是「页面永远停在正在载入」。这里改成真实等待。
//
// 用法：node scripts/cdp-dump.mjs <debugPort> <url> <waitMs> [outFile]

import { writeFileSync } from "node:fs"

const [port, url, waitMsRaw, outFile] = process.argv.slice(2)
const waitMs = Number(waitMsRaw || 8000)

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
await call("Page.navigate", { url })
await new Promise((resolve) => setTimeout(resolve, waitMs))

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
if (notes.length > 0) {
  process.stderr.write(notes.join("\n") + "\n")
}
ws.close()
process.exit(0)
