#!/usr/bin/env bash
#
# 服务端 API 契约测试：不起浏览器，直接打 HTTP。
#
# 重点是两条容易悄悄坏掉的东西：
#   1. 请求体里带的 baseUrl / apiKey 真的生效（服务端环境里那两个是故意设坏的）
#   2. 密钥不落盘、不进响应
#
# 用法：bash scripts/server-api.sh
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
source scripts/lib.sh

# 本机 native 构建要显式指定 C 编译器，否则会去找 /usr/bin/lib.exe
export MOON_CC=${MOON_CC:-gcc}

tmp=$(mktemp -d -p .)
tmp=$(cd "$tmp" && pwd)
cleanup() {
  kill "${web_pid:-}" "${mock_pid:-}" 2>/dev/null
  sleep 0.3
  rm -rf "$tmp"
}
trap cleanup EXIT

pass=0
fail=0
ok() { echo "  ok: $1"; pass=$((pass + 1)); }
bad() {
  echo "  FAIL: $1"
  fail=$((fail + 1))
}

echo "==> 构建"
moon build --target native >"$tmp/build.log" 2>&1 || {  echo "bench 构建失败：" >&2
  tail -20 "$tmp/build.log" >&2
  exit 1
}
(
  cd web &&
    moon build cmd/server --target native >/dev/null 2>&1 &&
    moon build cmd/ssg --target native >/dev/null 2>&1
) || {
  echo "web 构建失败" >&2
  exit 1
}
build_mbtx scripts/mock_openai.mbtx "$MOCK_BIN" || {
  echo "mock 编译失败" >&2
  exit 1
}

# 每个用例都从干净的状态开始
rm -rf web/runs

echo "==> 起 mock 与服务端"
MOCK_STREAM_DELAY=0.02 "$MOCK_BIN" >"$tmp/mock.port" 2>/dev/null &
mock_pid=$!
for _ in $(seq 1 100); do [ -s "$tmp/mock.port" ] && break; sleep 0.2; done
mock_port=$(cat "$tmp/mock.port")

# 关键：服务端环境里的网关地址不可达、密钥是错的。
# 请求体里给的那份如果生效，运行就会成功——不生效就会失败。一眼可判。
(
  cd web && exec env \
    MOONLLM_BASE_URL="http://127.0.0.1:1/v1" \
    MOONLLM_API_KEY="env-key-that-would-fail" \
    LLM_WEB_MODELS="mock-a" \
    LLM_WEB_PORT=0 \
    ./_build/native/debug/build/cmd/server/server.exe \
    >"$tmp/web.port" 2>"$tmp/server.log"
) &
web_pid=$!
for _ in $(seq 1 100); do [ -s "$tmp/web.port" ] && break; sleep 0.2; done
port=$(tr -d '\n' <"$tmp/web.port")
[ -n "$port" ] || {
  fail "服务端没起来"
  echo "通过 $pass 项，失败 $fail 项"
  exit 1
}

echo "==> 请求体覆盖服务端配置，且模型不在菜单里"
body='{"models":["mock-a","not-in-the-menu"],"cases":["math-short"],"repeats":1,
"maxTokens":32,"paceMs":0,"retry":0,
"baseUrl":"http://127.0.0.1:'"$mock_port"'/v1","apiKey":"test-key"}'
id=$(curl -s -X POST "http://127.0.0.1:$port/api/runs" \
  -H 'Content-Type: application/json' -d "$body" |
  sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
[ -n "$id" ] || {
  fail "没拿到 run id"
  echo "通过 $pass 项，失败 $fail 项"
  exit 1
}

status=""
for _ in $(seq 1 150); do
  status=$(curl -s "http://127.0.0.1:$port/api/runs/$id")
  echo "$status" | grep -q '"status":"\(done\|failed\)"' && break
  sleep 0.4
done

[ -f "web/runs/$id/exit_code" ] && [ "$(cat "web/runs/$id/exit_code")" = "0" ] &&
  ok "运行成功 → 请求体的 baseUrl 与 apiKey 都生效了" ||
  bad "运行没成功：请求体的 baseUrl/apiKey 可能被忽略了"

grep -q 'not-in-the-menu' "web/runs/$id/request.json" &&
  ok "模型菜单之外 id 也能发起" ||
  bad "模型仍被菜单限制住"

grep -q 'apiKey' "web/runs/$id/request.json" &&
  bad "request.json 里出现了 apiKey 字段" ||
  ok "request.json 里没有 apiKey 字段"

leaked=$(grep -rl 'test-key' "web/runs/$id/" 2>/dev/null | tr '\n' ' ')
[ -z "$leaked" ] && ok "运行目录里没有任何文件含这把密钥" ||
  bad "密钥落盘了：$leaked"

echo "$status" | grep -q '"failures"' &&
  echo "$status" | grep -q '"retried"' &&
  echo "$status" | grep -q '"truncated"' &&
  ok "状态响应含 failures/retried/truncated" ||
  bad "状态响应缺实时计数"
echo "$status" | grep -q '"tail"' &&
  ok "状态响应含 tail" ||
  bad "状态响应缺 tail"

echo "==> 导出"
for name in runs.jsonl data.json; do
  headers=$(curl -s -D - -o "$tmp/$name" "http://127.0.0.1:$port/api/runs/$id/$name")
  echo "$headers" | grep -q '200' &&
    echo "$headers" | grep -qi 'content-disposition' &&
    [ -s "$tmp/$name" ] &&
    ok "GET .../$name → 200，带 Content-Disposition，有内容" ||
    bad "GET .../$name 异常"
done
cmp -s "$tmp/runs.jsonl" "web/runs/$id/runs.jsonl" &&
  ok "下载的 runs.jsonl 与磁盘一致" ||
  bad "runs.jsonl 内容不一致"

code=$(curl -s -o "$tmp/report.html" -w '%{http_code}' \
  "http://127.0.0.1:$port/api/runs/$id/report.html")
[ "$code" = "200" ] && [ -s "$tmp/report.html" ] &&
  ok "GET .../report.html → 200（按需调用 ssg）" ||
  bad "report.html 生成失败（code=$code）"
grep -q '<style>' "$tmp/report.html" &&
  ok "报告 HTML 内联了样式（单文件自包含）" ||
  bad "报告 HTML 没内联样式"
grep -q 'site-logo' "$tmp/report.html" &&
  ok "报告 HTML 里有真正渲染出来的内容" ||
  bad "报告 HTML 是空的"

echo "==> 越权与坏输入"
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/runs/$id/../../moon.mod")" != "200" ] &&
  ok "路径穿越被挡住" ||
  bad "路径穿越能读到文件！"
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/runs/$id/nope.txt")" = "404" ] &&
  ok "不在导出清单里的文件名 → 404" ||
  bad "未知导出名没返回 404"
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/runs/..%2f..%2fmoon.mod")" != "200" ] &&
  ok "编码过的穿越路径也挡住" ||
  bad "编码路径穿越能读到文件！"

echo
echo "server api: 通过 $pass 项，失败 $fail 项"
exit $((fail > 0))
