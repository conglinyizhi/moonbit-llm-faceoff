#!/usr/bin/env bash
#
# 零 API key、零注册的本地演示。
#
# 起一个假的 OpenAI 兼容端点（scripts/mock_openai.py），然后把三条主要路径
# 各走一遍：单次问答、流式输出、两个"模型"的对比。全程离线。
#
# 第一次接触这个项目的话，从这里开始最省事：
#
#   bash scripts/demo.sh
#
# 想换成真实网关，见 README 的 Quick start。

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

# shellcheck source=scripts/lib.sh
source scripts/lib.sh

# 本机 native 工具链需要显式指定 C 编译器（否则报 /usr/bin/lib.exe 缺失）
export MOON_CC=${MOON_CC:-gcc}
export MOON_AR=${MOON_AR:-ar}
export MOON_LD=${MOON_LD:-gcc}

for tool in moon; do
  command -v "$tool" >/dev/null || {
    echo "缺少 $tool。MoonBit 安装方式见 https://www.moonbitlang.com/download/" >&2
    exit 1
  }
done

port_file=$(mktemp)
mock_log=$(mktemp)
cleanup() {
  kill "${mock_pid:-}" 2>/dev/null || true
  rm -f "$port_file" "$mock_log"
}
trap cleanup EXIT

echo "==> 构建（第一次会编译依赖，稍慢）"
moon build --target native

echo
echo "==> 编译本地假端点与检查器"
build_mbtx scripts/mock_openai.mbtx "$MOCK_BIN" || {
  echo "假端点编译失败" >&2
  exit 1
}
build_mbtx scripts/check_incremental.mbtx "$CHECKER_BIN" || {
  echo "检查器编译失败" >&2
  exit 1
}

echo
echo "==> 启动本地假端点"
MOCK_STREAM_DELAY=0.05 "$MOCK_BIN" >"$port_file" 2>"$mock_log" &
mock_pid=$!
for _ in $(seq 1 200); do
  [ -s "$port_file" ] && break
  sleep 0.05
done
port=$(cat "$port_file")
[ -n "$port" ] || {
  echo "假端点没起来：" >&2
  cat "$mock_log" >&2
  exit 1
}
base_url="http://127.0.0.1:$port/v1"
echo "    $base_url"

client="./_build/native/debug/build/cmd/faceoff/faceoff.exe"
bench="./_build/native/debug/build/cmd/bench/bench.exe"

echo
echo "==> 1/3 单次问答"
"$client" --api-key test-key --base-url "$base_url" "用一句话说明什么是航空母舰"

echo
echo "==> 2/3 流式输出（碎片逐个到达）"
"$client" --stream --api-key test-key --base-url "$base_url" "写一句关于侧风的话"

echo
echo '==> 3/3 两个「模型」的对比（各 1 次）'
"$bench" --api-key test-key --base-url "$base_url" \
  --models mock-a,mock-b --prompt "用一句话说明什么是航空母舰" \
  --repeats 1 --max-tokens 64 --pace-ms 0 --retry 0

echo
echo "演示结束。换成真实网关："
echo
echo "  export MOONLLM_BASE_URL=https://api.deepseek.com/v1   # 任何 OpenAI 兼容地址"
echo "  export MOONLLM_MODEL=deepseek-chat"
echo "  export MOONLLM_API_KEY=sk-..."
echo "  $client --stream \"你好\""
