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

# web/out/ 是被 gitignore 的，新鲜 clone（和 CI）里并不存在，而下面「GET / 要
# 200」那条断言需要它。自己构建，不要指望调用方先跑过 make web——否则就成了
# 「在我机器上能过」。
if [ ! -f web/out/index.html ]; then
  echo "==> 构建页面（GET / 的断言需要它）"
  bash web/build.sh >/dev/null 2>&1 || {
    echo "页面构建失败" >&2
    exit 1
  }
fi

# 用例集、预设、运行目录全都指向临时目录：web/cases、web/presets.json 和
# web/runs 是你自己的数据，跑一次契约测试不该把它们清掉。
# 服务端默认会从 LLM_WEB_CASES 播一份种子集出来，下面就用它。

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
    LLM_WEB_WORK="$tmp/runs" \
    LLM_WEB_CASES_DIR="$tmp/cases" \
    LLM_WEB_PRESETS="$tmp/presets.json" \
    ./_build/native/debug/build/cmd/server/server.exe \
    >"$tmp/web.port" 2>"$tmp/server.log"
) &
web_pid=$!
for _ in $(seq 1 100); do [ -s "$tmp/web.port" ] && break; sleep 0.2; done
port=$(tr -d '\n' <"$tmp/web.port")
[ -n "$port" ] || {
  bad "服务端没起来"
  echo "通过 $pass 项，失败 $fail 项"
  exit 1
}

# 服务端的 out/ runs/ 都是按当前工作目录解析的，换句话说它必须从 web/ 启动。
# README 里那段命令一度是错的（写成从仓库根目录启动），结果 /api 通、页面全 404。
# 这条断言守住「文档里写的启动方式是健康的」。
if grep -q 'static directory' "$tmp/server.log"; then
  bad "按文档方式启动却报了静态目录缺失：$(grep 'static directory' "$tmp/server.log")"
else
  ok "从 web/ 启动，静态目录正常"
fi
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/")" = "200" ] &&
  ok "GET / → 200（页面真的能被服务出来）" ||
  bad "GET / 不是 200：从 web/ 启动没意义"

echo "==> 请求体覆盖服务端配置，且模型不在菜单里"
body='{"models":["mock-a","not-in-the-menu"],"cases":["math-short"],"repeats":1,
"maxTokens":32,"paceMs":0,"retry":0,
"baseUrl":"http://127.0.0.1:'"$mock_port"'/v1","apiKey":"test-key"}'
id=$(curl -s -X POST "http://127.0.0.1:$port/api/runs" \
  -H 'Content-Type: application/json' -d "$body" |
  sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
[ -n "$id" ] || {
  bad "没拿到 run id"
  echo "通过 $pass 项，失败 $fail 项"
  exit 1
}

status=""
for _ in $(seq 1 150); do
  status=$(curl -s "http://127.0.0.1:$port/api/runs/$id")
  echo "$status" | grep -q '"status":"\(done\|failed\)"' && break
  sleep 0.4
done

[ -f "$tmp/runs/$id/exit_code" ] && [ "$(cat "$tmp/runs/$id/exit_code")" = "0" ] &&
  ok "运行成功 → 请求体的 baseUrl 与 apiKey 都生效了" ||
  bad "运行没成功：请求体的 baseUrl/apiKey 可能被忽略了"

grep -q 'not-in-the-menu' "$tmp/runs/$id/request.json" &&
  ok "模型菜单之外 id 也能发起" ||
  bad "模型仍被菜单限制住"

grep -q 'apiKey' "$tmp/runs/$id/request.json" &&
  bad "request.json 里出现了 apiKey 字段" ||
  ok "request.json 里没有 apiKey 字段"

leaked=$(grep -rl 'test-key' "$tmp/runs/$id/" 2>/dev/null | tr '\n' ' ')
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
cmp -s "$tmp/runs.jsonl" "$tmp/runs/$id/runs.jsonl" &&
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

echo "==> 用例集"
curl -s "http://127.0.0.1:$port/api/cases" | grep -q '"name":"default"' &&
  ok "GET /api/cases 列出了从 LLM_WEB_CASES 播种的 default 集" ||
  bad "没看到播种出来的用例集：$(curl -s "http://127.0.0.1:$port/api/cases")"
curl -s "http://127.0.0.1:$port/api/meta" | grep -q '"defaultCaseSet":"default"' &&
  ok "GET /api/meta 带 caseSets / defaultCaseSet（同时保留旧的 cases 字段）" ||
  bad "meta 里没有 caseSets / defaultCaseSet"

code=$(curl -s -o "$tmp/newset.json" -w '%{http_code}' -X PUT \
  "http://127.0.0.1:$port/api/cases/math" \
  -d '{"cases":[{"prompt":"1+1=?"},{"id":"deck","prompt":"什么是甲板风？","max_tokens":512}]}')
[ "$code" = "200" ] && ok "PUT /api/cases/math 新建一套" ||
  bad "PUT /api/cases/math 返回 $code"
get_set=$(curl -s "http://127.0.0.1:$port/api/cases/math")
echo "$get_set" | grep -q '"id":"case-1"' &&
  ok "缺 id 的用例被补上 id（不然 bench 侧按 id 过滤会静默丢掉它）" ||
  bad "缺 id 的用例没被补：$get_set"
echo "$get_set" | grep -q '"max_tokens":512' &&
  ok "其余字段原样往返（编辑不会把 system / max_tokens 弄丢）" ||
  bad "字段没往返：$get_set"

[ "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "http://127.0.0.1:$port/api/cases/bad" \
  -d '{"cases":[{"id":"x"}]}')" = "400" ] &&
  ok "没有 prompt 的用例 → 400" || bad "缺 prompt 没被拒"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "http://127.0.0.1:$port/api/cases/dup" \
  -d '{"cases":[{"id":"a","prompt":"p"},{"id":"a","prompt":"q"}]}')" = "400" ] &&
  ok "重复 id → 400" || bad "重复 id 没被拒"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "http://127.0.0.1:$port/api/cases/..%2fescape" \
  -d '{"cases":[]}')" = "400" ] &&
  ok "用例集名字里的路径片段 → 400" || bad "危险名字没被拒"
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/cases/nope")" = "404" ] &&
  ok "不存在的用例集 → 404" || bad "不存在的集没返回 404"

# 用刚建的集跑一次：请求里的 caseSet 要真的决定读哪个文件
set_body='{"models":["mock-a"],"caseSet":"math","cases":["deck"],"repeats":1,"maxTokens":32,"paceMs":0,"retry":0,"baseUrl":"http://127.0.0.1:'"$mock_port"'/v1","apiKey":"test-key"}'
set_id=$(curl -s -X POST "http://127.0.0.1:$port/api/runs" -d "$set_body" |
  sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
for _ in $(seq 1 100); do
  [ -f "$tmp/runs/$set_id/exit_code" ] && break
  sleep 0.3
done
if grep -q '"id":"deck"' "$tmp/runs/$set_id/cases.jsonl" 2>/dev/null &&
  ! grep -q '1+1' "$tmp/runs/$set_id/cases.jsonl" 2>/dev/null; then
  ok "caseSet 决定读哪套用例（跑的是 math 集里勾中的那条，而不是默认集）"
else
  bad "运行没有用 math 集：$(cat "$tmp/runs/$set_id/cases.jsonl" 2>/dev/null)"
fi
grep -q '"caseSet": "math"' "$tmp/runs/$set_id/request.json" &&
  ok "request.json 记下解析后的 caseSet（历史重跑重放的是实际那一套）" ||
  bad "request.json 里没记 caseSet"

[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/api/runs" \
  -d '{"models":["mock-a"],"caseSet":"math","cases":["not-a-case"]}')" = "400" ] &&
  ok "勾选的 id 一个都不在集里 → 400（不再静默跑 0 条）" ||
  bad "选错 id 没被拒"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/api/runs" \
  -d '{"models":["mock-a"],"caseSet":"nope","cases":["deck"]}')" = "400" ] &&
  ok "不存在的 caseSet → 400" || bad "不存在的 caseSet 没被拒"

[ "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "http://127.0.0.1:$port/api/cases/math")" = "200" ] &&
  [ ! -f "$tmp/cases/math.jsonl" ] &&
  ok "DELETE /api/cases/math 删掉一个集" ||
  bad "删用例集失败"


echo "==> 预设"
code=$(curl -s -o "$tmp/presets.json" -w '%{http_code}' -X PUT \
  "http://127.0.0.1:$port/api/presets" \
  -d '{"presets":[{"name":"quick","models":["mock-a","mock-b"],"repeats":1,"maxTokens":256,"caseSet":"default"}]}')
[ "$code" = "200" ] && ok "PUT /api/presets 存下一条预设" || bad "PUT /api/presets 返回 $code"
[ -f "$tmp/presets.json" ] && curl -s "http://127.0.0.1:$port/api/presets" | grep -q '"name":"quick"' &&
  ok "预设落盘且能读回" || bad "预设没落盘或读不回"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "http://127.0.0.1:$port/api/presets" \
  -d '{"presets":[{"name":"x","models":[]}]}')" = "400" ] &&
  ok "没模型的预设 → 400" || bad "空模型预设没被拒"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "http://127.0.0.1:$port/api/presets" \
  -d '{"presets":[{"name":"a/b","models":["m"]}]}')" = "400" ] &&
  ok "名字带路径片段的预设 → 400" || bad "危险预设名没被拒"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "http://127.0.0.1:$port/api/presets" \
  -d '{"presets":[{"name":"x","models":["m"]},{"name":"x","models":["n"]}]}')" = "400" ] &&
  ok "重名预设 → 400（预设按名字取，留两份同名就是留个坑）" || bad "重名预设没被拒"


echo "==> 运行历史"
runs_json=$(curl -s "http://127.0.0.1:$port/api/runs")
echo "$runs_json" | grep -q "\"id\":\"$id\"" &&
  ok "GET /api/runs 列出了跑过的运行" || bad "历史里没有刚才那次运行"
echo "$runs_json" | grep -q '"request":{' &&
  ok "历史条目带磁盘上那份 request（重跑不用另造格式）" || bad "历史条目缺 request"
echo "$runs_json" | grep -q '"status":"ok"' &&
  ok "历史条目带状态与计数" || bad "历史条目缺状态"
echo "$runs_json" | grep -q 'apiKey' &&
  bad "历史里的 request 带了 apiKey" || ok "历史里的 request 没有 apiKey"


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

echo "==> 删除运行"
# 放在最后：它会把上面那些导出断言用的目录删掉
if [ "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "http://127.0.0.1:$port/api/runs/$id")" = "200" ] &&
  [ ! -d "$tmp/runs/$id" ] &&
  ! curl -s "http://127.0.0.1:$port/api/runs" | grep -q "\"id\":\"$id\""; then
  ok "DELETE /api/runs/<id> 删掉运行目录，历史里也没了"
else
  bad "删除运行失败"
fi
[ "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "http://127.0.0.1:$port/api/runs/..%2f..")" = "400" ] &&
  ok "坏的 run id → 400" || bad "坏 run id 没被拒"

echo
echo "server api: 通过 $pass 项，失败 $fail 项"
exit $((fail > 0))
