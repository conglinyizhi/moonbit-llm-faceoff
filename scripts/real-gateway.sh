#!/usr/bin/env bash
#
# 对着**真实**网关跑一遍，把过程与结果留证到 docs/real-gateway-run.md。
#
#   export MOONLLM_BASE_URL="https://<你的网关>/v1"
#   export MOONLLM_API_KEY="sk-..."
#   export MOONLLM_MODEL="<模型名>"
#   bash scripts/real-gateway.sh
#
# 为什么单独一个脚本：仓库里其他测试全部跑在离线假端点上（demo.sh / smoke.mbtx
# / server-api.sh / web-e2e.sh），它们证明不了对真实网关的适配。离线全绿和
# 「真实 API 能跑」是两件事，这个脚本就是那条缺掉的证据。
#
# key 只从环境变量读：不上命令行（否则会进 ps）、不写进留证文件
# （落盘前会 grep 一遍确认它没出现，出现就把文件删掉并以非零退出）。
#
# 四个探针，各有独立结论：
#   1. one-shot     真实端点出真结果
#   2. streaming    分片是增量到达的，不是攒完再吐（量首字节 vs 进程退出时刻）
#   3. 错 key       退出非零、报 4xx、key 不回显
#   4. 截断         max_tokens 小于回复长度时，finish_reason=length 落进截断计数
#
# 可选（多用一次模型对比的额度）：
#   REAL_MODEL_B=<第二个模型> bash scripts/real-gateway.sh --compare
#   用例集默认 bench/cases.example.jsonl，跑 模型数 × 用例数 × repeats 次请求。
#
# 其他可调环境变量：
#   REAL_EVIDENCE=<路径>     留证文件，默认 docs/real-gateway-run.md
#   REAL_RUNS_OUT=<路径>     --compare 的原始 runs.jsonl，默认 docs/real-gateway-runs.jsonl
#   REAL_CASES=<路径>        --compare 的用例集
#   REAL_REPEATS=<n>         --compare 的 repeats，默认 1
#   REAL_SHOW_FULL_URL=1     留证里写完整端点（默认只写 scheme://host，
#                            有些网关把 token 拼在 URL 路径里）
#   REAL_TRUNCATE_MAX_TOKENS=8  截断探针用的 token 预算（网关对预算有最小值限制时调大）
#   REAL_ONE_SHOT_MAX_TOKENS=256  one-shot 探针的 token 预算（推理模型需要的多些）
#   STREAM_MIN_GAP_MS=300    流式判定的最小间隔，见 scripts/check_stream.mbtx
#   REAL_STREAM_MAX_TOKENS=2048  流式探针的 token 预算。推理模型会把预算全花在
#                            思考上、可见正文为空，那时 CLI 非零退出，看起来很像
#                            端点坏了——其实是预算不够

set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

# shellcheck source=scripts/lib.sh
source scripts/lib.sh

# 本机 native 工具链需要显式指定 C 编译器（否则报 /usr/bin/lib.exe 缺失）
export MOON_CC=${MOON_CC:-gcc}
export MOON_AR=${MOON_AR:-ar}
export MOON_LD=${MOON_LD:-gcc}

STREAM_BIN="scripts/_build/check-stream"
FACEOFF_BIN="_build/native/debug/build/cmd/faceoff/faceoff.exe"
BENCH_BIN="_build/native/debug/build/cmd/bench/bench.exe"

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' \
    "${BASH_SOURCE[0]}"
}

compare=0
while [ $# -gt 0 ]; do
  case "$1" in
    --compare) compare=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数：$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

# ---------------------------------------------------------------- 环境

base_url="${MOONLLM_BASE_URL:-${OPENAI_BASE_URL:-}}"
api_key="${MOONLLM_API_KEY:-${OPENAI_API_KEY:-${LLM_API_KEY:-}}}"
model="${MOONLLM_MODEL:-${OPENAI_MODEL:-}}"

missing=()
[ -n "$base_url" ] || missing+=("MOONLLM_BASE_URL")
[ -n "$api_key" ] || missing+=("MOONLLM_API_KEY")
[ -n "$model" ] || missing+=("MOONLLM_MODEL")
if [ "${#missing[@]}" -gt 0 ]; then
  echo "缺少环境变量：${missing[*]}" >&2
  echo "必须 export，子进程是从环境里读它们的：" >&2
  echo '  export MOONLLM_BASE_URL="https://<你的网关>/v1" MOONLLM_API_KEY="sk-..." MOONLLM_MODEL="<模型名>"' >&2
  exit 2
fi
# 统一成 MOONLLM_* 再交给子进程，免得 OPENAI_* 和 MOONLLM_* 同时存在时两边理解不同
export MOONLLM_BASE_URL="$base_url"
export MOONLLM_API_KEY="$api_key"
export MOONLLM_MODEL="$model"

evidence="${REAL_EVIDENCE:-docs/real-gateway-run.md}"
runs_out="${REAL_RUNS_OUT:-docs/real-gateway-runs.jsonl}"
model_b="${REAL_MODEL_B:-}"
cases="${REAL_CASES:-bench/cases.example.jsonl}"
repeats="${REAL_REPEATS:-1}"

# 留证里默认不写完整端点：有些网关把 token 拼在 URL 路径里。
masked_url() {
  if [ -n "${REAL_SHOW_FULL_URL:-}" ]; then
    printf '%s' "$base_url"
    return
  fi
  printf '%s/…' \
    "$(printf '%s' "$base_url" | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://[^/]+).*#\1#')"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

passed=0
warned=0
failed=0
summary=()

say() { printf '%s\n' "$*"; }
ok() {
  passed=$((passed + 1))
  summary+=("ok    $1")
  say "ok: $1"
}
skip() {
  warned=$((warned + 1))
  summary+=("warn  $1")
  say "warn: $1"
}
bad() {
  failed=$((failed + 1))
  summary+=("FAIL  $1")
  say "FAIL: $1"
}

# ---------------------------------------------------------------- 留证

mkdir -p "$(dirname "$evidence")"
ev="$evidence"
: >"$ev"

ev_head() {
  {
    echo "# 真实网关跑通记录"
    echo
    echo "> 由 \`bash scripts/real-gateway.sh\` 生成，随时可以重跑覆盖。"
    echo "> **不含密钥**：脚本只从环境变量读 key，写盘前会 grep 一遍确认它没出现。"
    echo
    echo "- 时间：$(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "- 端点：$(masked_url)"
    echo "- 模型：$model${model_b:+、$model_b}"
    echo "- 工具链：$(moon version 2>/dev/null | head -1)"
    echo "- 探针：one-shot / streaming / 错 key / 截断$(
      [ "$compare" = 1 ] && echo " / 双模型对比"
    )"
    echo
    echo "四个探针各自回答一个问题：真实端点能不能出结果、分片是不是真的增量到达、"
    echo "鉴权失败会不会被吞掉或把 key 吐出来、被 token 预算截断的回复会不会被当成功。"
    echo ""
    echo "下面的命令是实际跑的那一条，照抄能跑：二进制就在仓库里（构建产物不在 PATH 上），"
    echo "端点 / 模型 / 密钥来自上面那三个环境变量。"
  } >"$ev"
}

# ev_section <标题> <实际跑的命令行（不含 key）>
ev_section() {
  {
    echo
    echo "## $1"
    echo
    echo '```text'
    echo "\$ $2"
  } >>"$ev"
}

# excerpt <文件> [字符上限]
excerpt() {
  local file="$1" cap="${2:-2000}" text
  if [ ! -s "$file" ]; then
    echo "(无输出)"
    return
  fi
  text=$(cat "$file")
  if [ "${#text}" -gt "$cap" ]; then
    printf '%s\n…（已截断，共 %d 字符）\n' "${text:0:$cap}" "${#text}"
  else
    printf '%s\n' "$text"
  fi
}

ev_body() { excerpt "$1" >>"$ev"; }
ev_ok() {
  {
    echo
    echo "结果：ok${1:+ — $1}"
    echo '```'
  } >>"$ev"
}
ev_warn() {
  {
    echo
    echo "结果：warn — $1"
    echo '```'
  } >>"$ev"
}
ev_fail() {
  {
    echo
    echo "结果：FAIL — $1"
    echo '```'
  } >>"$ev"
}

# ---------------------------------------------------------------- 构建

say "==> 构建"
if ! moon build --target native >"$tmp/build.log" 2>&1; then
  say "构建失败："
  cat "$tmp/build.log" >&2
  exit 1
fi
build_mbtx scripts/check_stream.mbtx "$STREAM_BIN" || {
  echo "check_stream.mbtx 编译失败" >&2
  exit 1
}
for bin in "$FACEOFF_BIN" "$BENCH_BIN"; do
  [ -x "$bin" ] || {
    echo "缺少 $bin" >&2
    exit 1
  }
done

ev_head

calls=3
[ "$compare" = 1 ] && calls="3 + 对比（模型数 × 用例数 × repeats）"
say "==> 真实网关：$(masked_url)   模型：$model"
say "==> 本次会打 $calls 次模型请求（都限在很小的 token 数）"
say

# ---------------------------------------------------------------- 1. one-shot

say "==> 1/4 one-shot"
prompt_one="用一句话说明什么是甲板风。"
# 256 而不是 64：小 max_tokens 下推理模型会把预算全花在思考上，可见正文为空，
# 探针会把失败的原因归到端点上。真想知道那个形态长什么样，看 smoke 的 THINK_ONLY。
one_shot_tokens=${REAL_ONE_SHOT_MAX_TOKENS:-256}
ev_section "1. one-shot" "$FACEOFF_BIN --max-tokens $one_shot_tokens \"$prompt_one\""
"$FACEOFF_BIN" --max-tokens "$one_shot_tokens" "$prompt_one" >"$tmp/one.out" 2>"$tmp/one.err"
code=$?
if [ $code -ne 0 ]; then
  ev_body "$tmp/one.err"
  ev_fail "退出码 $code"
  bad "1/4 one-shot：退出码 $code（stderr 见留证文件）"
elif [ ! -s "$tmp/one.out" ]; then
  ev_body "$tmp/one.err"
  ev_fail "退出码 0，但 stdout 是空的"
  bad "1/4 one-shot：退出码 0 但没输出"
else
  ev_body "$tmp/one.out"
  ev_ok "$(wc -c <"$tmp/one.out" | tr -d ' ') 字节"
  ok "1/4 one-shot：真实端点出结果"
fi

# ---------------------------------------------------------------- 2. streaming

say "==> 2/4 streaming"
prompt_stream="用大约 150 个字说明为什么流式输出对交互体验重要，不要用列表。"
# 预算给推理模型留够：想不完就开不了口，而那时失败的样子很像端点坏了。
# 第一次对着 MiniCPM5-1B 跑就是撞在这个上面（写死 256）。
stream_tokens="${REAL_STREAM_MAX_TOKENS:-2048}"
export STREAM_MAX_TOKENS="$stream_tokens"
ev_section "2. streaming" "STREAM_MAX_TOKENS=$stream_tokens $STREAM_BIN $FACEOFF_BIN \"$prompt_stream\""
if "$STREAM_BIN" "$FACEOFF_BIN" "$prompt_stream" >"$tmp/stream.out" 2>"$tmp/stream.err"; then
  ev_body "$tmp/stream.out"
  ev_ok
  ok "2/4 streaming：$(cat "$tmp/stream.out")"
else
  ev_body "$tmp/stream.err"
  ev_fail "见上面的输出"
  bad "2/4 streaming：$(tail -n 1 "$tmp/stream.err")"
fi

# ---------------------------------------------------------------- 3. 错 key

say "==> 3/4 错 key"
# 故意无效的 key。这里必须走命令行：要的就是「绕过环境里那把真 key」，
# 而且它不是任何人的凭证。
bad_key="sk-invalid-key-for-faceoff-check-0000"
ev_section "3. 错 key" "$FACEOFF_BIN --api-key <故意无效的 key> --max-tokens 16 \"hi\""
"$FACEOFF_BIN" --api-key "$bad_key" --max-tokens 16 "hi" >"$tmp/bad.out" 2>"$tmp/bad.err"
code=$?
ev_body "$tmp/bad.err"
if [ $code -eq 0 ]; then
  ev_warn "端点用一把无效 key 也返回了 200"
  skip "3/4 错 key：这个端点不校验密钥（本地端点常见），这一项测不出结论"
elif ! grep -qE 'http 4[0-9][0-9]' "$tmp/bad.err"; then
  ev_fail "退出码 $code，但没看到 4xx（网关自己出错了？）"
  bad "3/4 错 key：退出码 $code，但错误里没有 4xx"
elif grep -qF -- "$bad_key" "$tmp/bad.err"; then
  ev_fail "无效 key 被原样回显"
  bad "3/4 错 key：无效 key 被原样回显，遮蔽没生效"
elif grep -qF -- "$api_key" "$tmp/bad.err" "$tmp/bad.out"; then
  ev_fail "真 key 出现在错误输出里"
  bad "3/4 错 key：真 key 出现在错误输出里"
else
  ev_ok "退出码 $code，报 4xx，key 没回显"
  ok "3/4 错 key：退出非零、报 4xx、key 没回显"
fi

# ---------------------------------------------------------------- 4. 截断

say "==> 4/4 截断"
prompt_trunc="写一段大约 200 字的说明。"
trunc_tokens="${REAL_TRUNCATE_MAX_TOKENS:-8}"
bench_common=(--models "$model" --repeats 1)
ev_section "4. 截断" "$BENCH_BIN --models $model --prompt \"$prompt_trunc\" --repeats 1 --max-tokens $trunc_tokens"
"$BENCH_BIN" "${bench_common[@]}" --prompt "$prompt_trunc" --max-tokens "$trunc_tokens" \
  --json "$tmp/trunc.jsonl" >"$tmp/trunc.report" 2>"$tmp/trunc.err"
code=$?
ev_body "$tmp/trunc.report"
if [ $code -ne 0 ]; then
  ev_fail "退出码 $code（被截断的运行不该算失败，除非这一次请求本身失败了）"
  bad "4/4 截断：bench 退出码 $code"
elif ! grep -q '"finish_reason":"length"' "$tmp/trunc.jsonl"; then
  reason=$(grep -o '"finish_reason":"[a-z_]*"' "$tmp/trunc.jsonl" | head -n 1)
  tokens=$(grep -o '"completion_tokens":[0-9]*' "$tmp/trunc.jsonl" | head -n 1)
  ev_fail "拿到的是 ${reason:-没有 finish_reason}（$tokens）——网关没按 max_tokens 报截断，或者这次回复短到 8 个 token 都用不完"
  bad "4/4 截断：没有 finish_reason=length"
elif ! grep -qE 'failures 0 +truncated 1' "$tmp/trunc.report"; then
  ev_fail "finish_reason 是 length，但摘要里没计进截断数"
  bad "4/4 截断：截断没被计数"
else
  ev_ok "finish_reason=length，摘要计进 truncated 1"
  ok "4/4 截断：被预算截断的回复计进截断数，没当成功"
fi

# ---------------------------------------------------------------- 5. 对比（可选）

if [ "$compare" = 1 ]; then
  say "==> 5/5 双模型对比"
  if [ -z "$model_b" ]; then
    echo "REAL_MODEL_B 没设，--compare 跑不了" >&2
    exit 2
  fi
  if [ ! -f "$cases" ]; then
    echo "找不到用例集 $cases（REAL_CASES 可以指定别的）" >&2
    exit 2
  fi
  ev_section "5. 双模型对比" "$BENCH_BIN --models $model,$model_b --cases $cases --repeats $repeats"
  "$BENCH_BIN" --models "$model,$model_b" --cases "$cases" --repeats "$repeats" \
    --max-tokens 512 --json "$runs_out" >"$tmp/compare.report" 2>"$tmp/compare.err"
  code=$?
  ev_body "$tmp/compare.report"
  if [ $code -ne 0 ] && [ ! -s "$tmp/compare.report" ]; then
    ev_fail "退出码 $code"
    bad "5/5 对比：bench 退出码 $code"
  elif ! grep -q 'comparison (median per model)' "$tmp/compare.report"; then
    ev_fail "报告里没有对比表"
    bad "5/5 对比：报告里没有对比表"
  else
    {
      echo
      echo "原始逐条记录：\`$runs_out\`（$(
        wc -l <"$runs_out" | tr -d ' '
      ) 行）"
    } >>"$ev"
    ev_ok "两模型跑完，报告见上"
    ok "5/5 对比：$(wc -l <"$runs_out" | tr -d ' ') 条运行记录"
  fi
fi

# ---------------------------------------------------------------- 收尾

{
  echo
  echo "## 结论"
  echo
  echo "- ok $passed / warn $warned / FAIL $failed"
  for line in "${summary[@]}"; do
    echo "  - $line"
  done
  echo
  echo "原始日志留在本次运行的临时目录里，脚本退出时清掉；留证就是上面这些。"
} >>"$ev"

# key 到底有没有混进去：证据文件是准备提交的，这一步不能省。
leaked=0
for file in "$ev" "$runs_out"; do
  [ -f "$file" ] || continue
  if grep -qF -- "$api_key" "$file"; then
    echo "!! 密钥出现在 $file 里" >&2
    leaked=1
  fi
done
if [ $leaked -ne 0 ]; then
  rm -f "$ev" "$runs_out"
  echo "已删除含密钥的文件。这是脚本的 bug，不是你的操作问题。" >&2
  exit 1
fi

say
say "留证：$ev"
if [ "$compare" = 1 ] && [ -s "$runs_out" ]; then
  say "原始记录：$runs_out"
fi
say "真实网关：ok $passed / warn $warned / FAIL $failed"
if [ $failed -gt 0 ]; then
  say "有 $failed 项失败，逐条看上去（留证文件里有完整输出）。"
  exit 1
fi
say "四个探针都过了：真实端点能出结果、流式是增量到达、鉴权失败被正确报出、"
say "被截断的回复进的是截断计数。"
