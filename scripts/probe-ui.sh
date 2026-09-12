#!/usr/bin/env bash
#
# 手工看页面用的探针台：起假端点 + 服务端 + 无头浏览器，跑一段 JS，打印结果，
# 然后收干净。
#
# 为什么要有这个脚本：这几步（挑端口、等端口、等 DevToolsActivePort、传
# --script、grep SCRIPT、收尾）每次手工验页面都要重打一遍，二十几行，而且
# 最容易错的就是收尾——忘了杀就是一堆孤儿进程，写错路径就在仓库里留垃圾。
#
# 用法：
#   scripts/probe-ui.sh probe.js [选项]
#
# 选项：
#   --url PATH        打开哪个页面，默认 /
#   --wait MS         导航后最多等多久（配合探针里的等待），默认 6000
#   --script-wait MS  探针跑完后再等多久才转储，默认 1500
#   --shot FILE       额外存一张截图
#   --seed            先 POST 一次小运行（1 用例 × 2 模型），让页面有历史记录
#   --seed-repeats N  预置运行重复几次，默认 1（想看分位数就设 3：n > 1 才显示）
#   --delay S         假端点每个分片之间的停顿，默认 0.05
#   --system TEXT     给服务端设 LLM_WEB_SYSTEM（页面上的 system 会预填它）
#   --keep            保留临时目录（默认删掉；失败时也保留）
#
# 探针是一个 async 函数体（可以是 `(async () => {...})()`），返回值打在一行
# `SCRIPT {...}` 里。用 jq 或 grep 取。
#
# 例：
#   scripts/probe-ui.sh /tmp/p.js --seed --url / --shot /tmp/a.png

set -euo pipefail

cd "$(dirname "$0")/.."
root=$(pwd)

# 原生构建需要一个 C 工具链：`make` 里也是这么设的。不设的话 moon 会去找
# /usr/bin/lib.exe 这种不存在的归档器，报一条看不懂的错
export MOON_CC="${MOON_CC:-gcc}"

script=""
url_path="/"
wait_ms=6000
script_wait=1500
shot=""
seed=0
seed_repeats=1
delay=0.05
system_text=""
keep=0

while [ $# -gt 0 ]; do
  case "$1" in
    --url) url_path="$2"; shift 2 ;;
    --wait) wait_ms="$2"; shift 2 ;;
    --script-wait) script_wait="$2"; shift 2 ;;
    --shot) shot="$2"; shift 2 ;;
    --seed) seed=1; shift ;;
    --seed-repeats) seed_repeats="$2"; shift 2 ;;
    --delay) delay="$2"; shift 2 ;;
    --system) system_text="$2"; shift 2 ;;
    --keep) keep=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) script="$1"; shift ;;
  esac
done

[ -n "$script" ] || { echo "用法：scripts/probe-ui.sh probe.js [--seed] [--shot out.png]" >&2; exit 2; }
[ -f "$script" ] || { echo "找不到探针：$script" >&2; exit 2; }

# 现场放系统临时区，不放仓库：见 web-e2e.sh 里同样的一段
tmp=$(mktemp -d "${TMPDIR:-/tmp}/faceoff-probe.XXXXXXXX")
tmp=$(cd "$tmp" && pwd)
pids=()

cleanup() {
  local pid
  for pid in "${pids[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${pids[@]:-}"; do
    [ -n "$pid" ] || continue
    for _ in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
    done
    kill -9 "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  if [ "$keep" -eq 1 ]; then
    echo "probe-ui: 现场保留在 $tmp" >&2
  else
    rm -rf "$tmp" 2>/dev/null || true
  fi
}
trap cleanup EXIT

server_bin="$root/web/_build/native/debug/build/cmd/server/server.exe"

# 假端点：复用 web-e2e 那套 build_mbtx（先 build 再复制成独立名字，否则 $! 拿到的是
# moon 包装进程，kill 不掉真正的服务）
# shellcheck source=lib.sh
. "$root/scripts/lib.sh"
if [ ! -x "$root/$MOCK_BIN" ]; then
  build_mbtx scripts/mock_openai.mbtx "$MOCK_BIN" ||
    { echo "假端点编译失败" >&2; exit 2; }
fi
mock_bin="$root/$MOCK_BIN"
[ -x "$server_bin" ] || { echo "先建服务端：cd web && moon build cmd/server --target native" >&2; exit 2; }

mkdir -p "$tmp/home" "$tmp/cases"
cp -n "$root"/web/cases/*.jsonl "$tmp/cases/" 2>/dev/null || true

MOCK_STREAM_DELAY="$delay" "$mock_bin" >"$tmp/mock.port" 2>/dev/null &
pids+=($!)
for _ in $(seq 1 200); do [ -s "$tmp/mock.port" ] && break; sleep 0.05; done
mock_port=$(cat "$tmp/mock.port")
[ -n "$mock_port" ] || { echo "假端点没起来" >&2; exit 1; }

(
  cd "$root/web" && exec env \
    MOONLLM_BASE_URL="http://127.0.0.1:$mock_port/v1" \
    MOONLLM_API_KEY="test-key" \
    LLM_WEB_MODELS="mock-a,mock-b" \
    LLM_WEB_PORT=0 \
    LLM_WEB_WORK="$tmp/runs" \
    LLM_WEB_CASES_DIR="$tmp/cases" \
    LLM_WEB_PRESETS="$tmp/presets.json" \
    LLM_WEB_SYSTEM="$system_text" \
    "$server_bin"
) >"$tmp/web.port" 2>"$tmp/server.log" &
pids+=($!)
for _ in $(seq 1 200); do [ -s "$tmp/web.port" ] && break; sleep 0.05; done
port=$(head -1 "$tmp/web.port")
[ -n "$port" ] || { echo "服务端没起来（见 $tmp/server.log）" >&2; exit 1; }

if [ "$seed" -eq 1 ]; then
  # node 而不是 python：本地本来就有 node（cdp-dump.mjs 也用它），少一个依赖
  node -e '
const [port, mock, repeats, system] = process.argv.slice(1)
const body = {
  models: ["mock-a", "mock-b"],
  caseSet: "default",
  cases: ["math-short"],
  repeats: Number(repeats),
  maxTokens: 64,
  temperature: 0,
  paceMs: 0,
  retry: 0,
  baseUrl: `http://127.0.0.1:${mock}/v1`,
  apiKey: "test-key",
}
// --system 给了就让这次预置运行也用它（看「system 有没有进报告」时需要）
if (system) body.system = system
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const post = await fetch(`http://127.0.0.1:${port}/api/runs`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(body),
})
const { id } = await post.json()
let status = ""
for (let i = 0; i < 200; i++) {
  status = (await (await fetch(`http://127.0.0.1:${port}/api/runs/${id}`)).json()).status
  if (status === "done" || status === "failed") break
  await sleep(200)
}
console.error(`probe-ui: 预置运行 ${id} → ${status}`)
' "$port" "$mock_port" "$seed_repeats" "$system_text"
fi

chrome=${CHROME:-/usr/bin/chromium}
XDG_RUNTIME_DIR="$tmp" HOME="$tmp/home" "$chrome" \
  --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
  --disable-extensions --no-first-run --disable-crash-reporter \
  --remote-debugging-port=0 --user-data-dir="$tmp/home/profile" \
  about:blank >"$tmp/chrome.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 300); do [ -s "$tmp/home/profile/DevToolsActivePort" ] && break; sleep 0.1; done
debug_port=$(head -1 "$tmp/home/profile/DevToolsActivePort" 2>/dev/null | tr -d '\r\n')
[ -n "$debug_port" ] || { echo "浏览器没起来（见 $tmp/chrome.log）" >&2; exit 1; }

url="http://127.0.0.1:$port$url_path"
out="$tmp/page.html"
shot_args=()
[ -n "$shot" ] && shot_args=("$shot")

cd "$root"
if ! node scripts/cdp-dump.mjs "$debug_port" "$url" "$wait_ms" "$out" "${shot_args[@]:-}" \
  --script "$(cat "$script")" --script-wait "$script_wait" 2>"$tmp/dump.err" >/dev/null; then
  echo "probe-ui: cdp-dump 失败" >&2
  cat "$tmp/dump.err" >&2
  exit 1
fi

# 探针的返回值与异常都在 stderr 里的 SCRIPT / SCRIPT ERROR 行
if grep -q 'SCRIPT ERROR' "$tmp/dump.err"; then
  cat "$tmp/dump.err" >&2
  exit 1
fi
grep -o 'SCRIPT .*' "$tmp/dump.err" | head -1

if [ -f "$out" ] && [ "$keep" -eq 1 ]; then
  cp "$out" "$tmp/../" 2>/dev/null || true
fi
