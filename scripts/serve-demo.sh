#!/usr/bin/env bash
#
# 一键演示：本地假端点 + 一套演示数据 + 页面。
#
# 不碰你自己的 runs / cases / presets.json —— 全落在临时目录里，退出就删。
#
# 起好之后先自己发起两次评测（一次两个模型并排、一次单个），这样打开页面就有历史、
# 有对比、有逐用例答案，不用先手动跑一轮。假端点故意留了点延迟，进度条才看得见。
#
# 用法：make serve:demo    （Ctrl-C 退出）

set -euo pipefail

cd "$(dirname "$0")/.."
root="$(pwd)"
. "$root/scripts/lib.sh"

demo_dir="$(mktemp -d)"
mock_pid=""
server_pid=""

cleanup() {
  for pid in "$server_pid" "$mock_pid"; do
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  wait 2>/dev/null || true
  rm -rf "$demo_dir"
}
trap cleanup EXIT INT TERM

echo "==> 构建页面与服务端"
MOON_CC="${MOON_CC:-gcc}" moon run --target native scripts/build-web.mbtx >/dev/null
(cd web && MOON_CC="${MOON_CC:-gcc}" moon build cmd/server --target native)

echo "==> 起本地假端点"
mkdir -p "$demo_dir/runs" "$demo_dir/cases"
build_mbtx "scripts/mock_openai.mbtx" "$demo_dir/mock-endpoint"
# 假端点默认会校验 Authorization；演示用它的「本地无鉴权端点」模式
MOCK_ALLOW_ANY_KEY=1 MOCK_STREAM_DELAY="${MOCK_STREAM_DELAY:-0.08}" "$demo_dir/mock-endpoint" \
  >"$demo_dir/mock.port" 2>/dev/null &
mock_pid=$!
for _ in $(seq 1 200); do
  [ -s "$demo_dir/mock.port" ] && break
  sleep 0.05
done
mock_port="$(head -1 "$demo_dir/mock.port" 2>/dev/null | tr -d '\r\n')"
if [ -z "$mock_port" ]; then
  echo "假端点没起来" >&2
  exit 1
fi

echo "==> 起页面（演示数据都在临时目录里）"
(cd web && exec env \
  MOONLLM_BASE_URL="http://127.0.0.1:$mock_port/v1" \
  MOONLLM_API_KEY="demo-key" \
  LLM_WEB_MODELS="mock-a,mock-b" \
  LLM_WEB_PORT=0 \
  LLM_WEB_WORK="$demo_dir/runs" \
  LLM_WEB_CASES_DIR="$demo_dir/cases" \
  LLM_WEB_PRESETS="$demo_dir/presets.json" \
  ./_build/native/debug/build/cmd/server/server.exe >"$demo_dir/web.port" 2>"$demo_dir/server.log") &
server_pid=$!
for _ in $(seq 1 200); do
  [ -s "$demo_dir/web.port" ] && break
  sleep 0.05
done
port="$(head -1 "$demo_dir/web.port" 2>/dev/null | tr -d '\r\n')"
if [ -z "$port" ]; then
  echo "页面服务端没起来，看 $demo_dir/server.log" >&2
  exit 1
fi

echo "==> 先跑两次，把演示数据喂出来"
curl -sS -X POST "http://127.0.0.1:$port/api/runs" \
  -H 'Content-Type: application/json' \
  -d '{"models":["mock-a","mock-b"],"cases":["math-short","fact-zh","writing-zh"],"caseSet":"default","repeats":1,"maxTokens":256,"paceMs":0,"retry":0,"temperature":0}' \
  >/dev/null
curl -sS -X POST "http://127.0.0.1:$port/api/runs" \
  -H 'Content-Type: application/json' \
  -d '{"models":["mock-a"],"cases":["math-short","code-python"],"caseSet":"default","repeats":1,"maxTokens":256,"paceMs":0,"retry":0,"temperature":0}' \
  >/dev/null

# 跑完再交给人：失败就把原因挖出来，别只丢几张 failed 卡片过去
for id in $(curl -s "http://127.0.0.1:$port/api/runs" | grep -oE '"id":"[^"]+"' | cut -d'"' -f4); do
  st="running"
  for _ in $(seq 1 60); do
    st=$(curl -s "http://127.0.0.1:$port/api/runs/$id" | grep -oE '"status":"[a-z]+"' | head -1 | cut -d'"' -f4)
    if [ "$st" != "running" ] && [ "$st" != "starting" ]; then
      break
    fi
    sleep 0.5
  done
  if [ "$st" = "failed" ]; then
    echo "==> 演示运行 $id 失败了，原因："
    curl -s "http://127.0.0.1:$port/api/runs/$id" | grep -oE '"error":"[^"]*"' | head -3
    echo "    服务端日志在 $demo_dir/server.log"
  fi
done

printf '\n  页面：http://127.0.0.1:%s/\n' "$port"
echo  "  已经跑过两次评测：上面那次两个模型并排，下面那次单个模型"
echo  "  历史、对比、请求上下文、标注、导出 都有东西可点"
echo
echo  "  演示数据在 $demo_dir（退出即删；你自己的 runs/ 与 cases/ 没被碰过）"
echo  "  Ctrl-C 退出"

wait "$server_pid"
