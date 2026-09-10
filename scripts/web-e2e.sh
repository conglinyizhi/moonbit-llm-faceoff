#!/usr/bin/env bash
#
# 浏览器端到端测试：真的起服务、真的用 chromium 打开页面。
#
# 覆盖：
#   1. 页面加载 → /api/meta → 表单渲染（证明静态服务 + js + API 通了）
#   2. ?autorun 链接 → 真的跑一次评测 → 结果渲染出来
#   3. 静态资源与 404
#
# 全程用 mock LLM 端点，不碰真实网关、不需要 key。

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

# shellcheck source=scripts/lib.sh
source scripts/lib.sh

export MOON_CC=${MOON_CC:-gcc}
export MOON_AR=${MOON_AR:-ar}
export MOON_LD=${MOON_LD:-gcc}

WEB_PORT=${LLM_WEB_PORT:-0}
# 本机 /usr/bin/chromium 可用（ungoogled-chromium-bin 152）。
# 沙箱环境下需要 --no-sandbox；--disable-extensions 避免顺带拉起 KDE 的
# plasma-browser-integration 宿主。用 CHROME=... 可换别的浏览器。
CHROME=${CHROME:-/usr/bin/chromium}
DEBUG_PORT=${DEBUG_PORT:-0}
CHROME_FLAGS=(--headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage
              --disable-extensions --no-first-run --disable-crash-reporter
              --remote-debugging-port="$DEBUG_PORT")

fail() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "--- 输出片段 ---" >&2; head -c 2000 "$2" >&2; echo >&2; }
  exit 1
}

echo "==> 构建"
moon build cmd/bench --target native >/dev/null
bash web/build.sh >/dev/null
(cd web && moon build cmd/server --target native >/dev/null)

tmp=$(mktemp -d -p .)
tmp=$(cd "$tmp" && pwd)
cleanup() {
  kill "${webkit_pid:-}" "${chrome_pid:-}" "${web_pid:-}" "${mock_pid:-}" 2>/dev/null || true
  rm -rf "$tmp" 2>/dev/null || true
}
trap cleanup EXIT

build_mbtx scripts/mock_openai.mbtx "$MOCK_BIN" || fail "mock 编译失败"

echo "==> 起 mock LLM 与评测服务"
exec env MOCK_STREAM_DELAY=0.02 "$MOCK_BIN" >"$tmp/mock.port" 2>/dev/null &
mock_pid=$!
for _ in $(seq 1 200); do [ -s "$tmp/mock.port" ] && break; sleep 0.05; done
mock_port=$(cat "$tmp/mock.port")
[ -n "$mock_port" ] || fail "mock LLM 没起来"

# exec：让子 shell 被服务端进程替换，$! 才是服务端本身的 pid。
# 不加 exec 时 $! 是子 shell，cleanup 里 kill 它杀不掉服务端，会留下孤儿监听端口。
# 端口用 0 让内核分配：共用机器上硬编码端口会撞车。
# 服务端把实际端口写在 stdout 第一行，和 mock 的握手方式一致。
(cd web && exec env \
  MOONLLM_BASE_URL="http://127.0.0.1:$mock_port/v1" \
  MOONLLM_API_KEY=test-key \
  LLM_WEB_MODELS="mock-a,mock-b" \
  LLM_WEB_PORT="$WEB_PORT" \
  ./_build/native/debug/build/cmd/server/server.exe >"$tmp/web.port" 2>"$tmp/server.log") &
web_pid=$!
for _ in $(seq 1 200); do
  [ -s "$tmp/web.port" ] && break
  sleep 0.05
done
PORT=$(tr -d '\n' < "$tmp/web.port" 2>/dev/null)
[ -n "$PORT" ] || fail "评测服务没吐出端口" "$tmp/server.log"
curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/meta" || fail "评测服务没起来" "$tmp/server.log"

echo "==> 静态资源"
for f in / /index.html /app.js /site.css /report.html; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$f")
  [ "$code" = "200" ] || fail "$f 返回 $code"
done
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/nope.js")
[ "$code" = "404" ] || fail "不存在的文件应返回 404，实际 $code"
echo "ok: 静态资源与 404"

echo "==> 浏览器加载页面（表单渲染）"
start_browser() {
  # HOME 必须是绝对路径，浏览器会拒绝相对路径
  mkdir -p "$tmp/home"
  XDG_RUNTIME_DIR="$tmp" HOME="$tmp/home" "$CHROME" "${CHROME_FLAGS[@]}" \
    --user-data-dir="$tmp/home/profile" about:blank >"$tmp/chrome.log" 2>&1 &
  chrome_pid=$!
  # --remote-debugging-port=0：让浏览器自己挑端口，再把实际值写进
  # <user-data-dir>/DevToolsActivePort。共用机器上硬编码调试端口会撞车。
  local port_file="$tmp/home/profile/DevToolsActivePort"
  for _ in $(seq 1 200); do
    if [ -s "$port_file" ]; then
      DEBUG_PORT=$(head -1 "$port_file" | tr -d '\r\n')
      [ -n "$DEBUG_PORT" ] && return 0
    fi
    sleep 0.1
  done
  fail "浏览器调试端口没起来" "$tmp/chrome.log"
}

# CDP + 真实等待：虚拟时间会和页面里的 fetch 抢时钟，不可靠
dump_page() {
  node scripts/cdp-dump.mjs "$DEBUG_PORT" "$1" "$2" "$3" 2>"$3.err" || true
}

start_browser
dump_page "http://127.0.0.1:$PORT/" 6000 "$tmp/form.html"

grep -q 'id="model-mock-a"' "$tmp/form.html" || fail "表单里没有模型选项" "$tmp/form.html"
grep -q 'id="model-mock-b"' "$tmp/form.html" || fail "表单里没有第二个模型" "$tmp/form.html"
grep -q 'id="case-math-short"' "$tmp/form.html" || fail "表单里没有用例选项" "$tmp/form.html"
grep -q '开始评测' "$tmp/form.html" || fail "表单里没有开始按钮" "$tmp/form.html"
grep -q 'id="repeats"' "$tmp/form.html" || fail "表单里没有参数输入" "$tmp/form.html"
echo "ok: 浏览器里表单渲染出来了（/api/meta 链路通）"

echo "==> 浏览器触发一次评测（?autorun）"
run_url="http://127.0.0.1:$PORT/?autorun=1&models=mock-a,mock-b&cases=math-short&repeats=1&maxTokens=64&paceMs=0&retry=0"
dump_page "$run_url" 30000 "$tmp/run.html"

grep -q '已完成' "$tmp/run.html" || fail "页面没有进入已完成状态" "$tmp/run.html"
grep -q 'mock-a' "$tmp/run.html" || fail "结果里没有模型" "$tmp/run.html"
grep -q 'mock-b' "$tmp/run.html" || fail "结果里没有第二个模型" "$tmp/run.html"
grep -q '首 token' "$tmp/run.html" || fail "结果里没有指标卡" "$tmp/run.html"
grep -q '对比' "$tmp/run.html" || fail "结果里没有对比表" "$tmp/run.html"
grep -q 'Hello from the mock server' "$tmp/run.html" || fail "结果里没有模型输出" "$tmp/run.html"
# 跑完之后按钮要回到可用态。之前用 disabled 属性，Rabbita 的 vdom diff 没把它
# 摘掉，跑完一次就永远点不动——这条断言就是为那个 bug 加的。
grep -q 'primary busy' "$tmp/run.html" && fail "跑完之后按钮仍是忙碌态" "$tmp/run.html"
grep -q '开始评测' "$tmp/run.html" || fail "跑完之后没有回到可点的开始按钮" "$tmp/run.html"
echo "ok: 浏览器里跑完一次评测并渲染出了结果（按钮已回到可用态）"

echo "==> 并发创建运行：id 必须互不重复"
# 每个请求各写各的文件：8 个进程并发 >> 同一个文件不可靠，也不好诊断
curl_pids=""
for i in $(seq 1 8); do
  curl -sS -X POST "http://127.0.0.1:$PORT/api/runs" \
    -H 'Content-Type: application/json' \
    -d '{"models":["mock-a"],"cases":["math-short"],"repeats":1,"maxTokens":32,"paceMs":0,"retry":0}' \
    >"$tmp/c$i.txt" 2>&1 &
  curl_pids="$curl_pids $!"
done
# 只等这些 curl：裸 wait 会连 mock 和服务端一起等，它们永不退出
for pid in $curl_pids; do wait "$pid" 2>/dev/null || true; done

created=0
ids=""
for i in $(seq 1 8); do
  id=$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "$tmp/c$i.txt" | head -1)
  if [ -n "$id" ]; then
    created=$((created + 1))
    ids="$ids $id"
  fi
done
[ "$created" = "8" ] || {
  echo "--- 各请求响应 ---" >&2
  for i in $(seq 1 8); do echo "  #$i $(head -c 120 "$tmp/c$i.txt")" >&2; done
  fail "并发建了 $created 个运行，期望 8 个"
}
unique=$(printf '%s\n' $ids | sort -u | grep -c . || true)
[ "$unique" = "8" ] || fail "并发下出现重复 id：$ids"
echo "ok: 8 个并发运行拿到 8 个不同 id"

echo "==> 服务端运行目录"
runs=$(find web/runs -maxdepth 1 -type d -name 'run-*' | wc -l)
[ "$runs" -ge 1 ] || fail "服务端没有留下运行记录"
echo "ok: 运行记录 $runs 份"

echo
echo "web e2e: 全部通过"
