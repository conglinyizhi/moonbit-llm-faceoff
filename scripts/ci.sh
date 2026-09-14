#!/usr/bin/env bash
#
# make ci 的真身：把确定性的那套测试按「抢哪个构建目录」分成三条通道并行跑。
#
# 为什么要分通道，而不是无脑 `make -j`：
#   moon 的锁是目录级的（_build/、web/_build/、scripts/_build/ 各一把）。同一个
#   目录上的并发调用不会失败，而是**排队**——所以「把所有目标一起丢出去」不会更快，
#   只会把输出搅在一起。按目录分开之后，通道之间真的互不相干，通道内部保持串行。
#
#   .mbtx 那三个目标（smoke / api / web）之所以敢一起跑，是因为它们的单文件构建
#   产物已经按子脚本分了目录（见 scripts/lib.sh 与各 .mbtx 里的 mbtx_dir）。
#   在此之前它们共用同一个 single/single.exe，并发会互相顶掉、乃至挂死。
#
# 输出：每条通道带前缀流式打出来——这条链平时十几秒，但一旦卡住，「卡在哪一步」
# 得一眼看得出来。失败时把那一条通道的日志尾部再回放一遍。

# 'moon update' 不在这里跑：它走网络（实测 6-45s），而本地迭代的主要成本就是它。
# 缺依赖时 moon check 自己会报错，比每次默默等半分钟更好懂
set -euo pipefail

cd "$(dirname "$0")/.."

lane_dir="$(mktemp -d)"
trap 'rm -rf "$lane_dir"' EXIT

# run_lane <名字> <命令...>
#   前缀流式输出 + 留一份日志 + 单独记退出码
#   （走管道时 $? 是 sed 的，所以必须绕开管道去取）
#   顺带记下每条通道自己的耗时（总时长被锁排队拉长时，这个数字才说明问题）
run_lane() {
  local name="$1"; shift
  {
    local t0=$(date +%s)
    "$@" 2>&1
    local code=$?
    echo "$code" >"$lane_dir/$name.code"
    date +%s >"$lane_dir/$name.end"
    echo "t0=$t0" >"$lane_dir/$name.start"
  } | tee "$lane_dir/$name.log" | sed -u "s/^/[$name] /" &
}

start=$(date +%s)
echo "== 三段：模块检查/测试（root∥web）→ 端到端（smoke∥api∥web）"

# 模块检查/测试：两个模块的构建目录不同，真并行
run_lane root bash -c 'moon check --target native && moon test --target native'
run_lane web bash -c 'cd web && moon check --target native && moon check --target js && moon test --target native'
wait || true

# 端到端：这三个才是真正互不相干的（各自的 .mbtx 有自己的构建目录，
# 而且都不重建模块）。注意 web 这一条会构建根模块的 cmd/bench，所以它
# 不能和上面的 root 通道同时跑——实测那样会抢 _build 的锁，反而更慢
run_lane e2e bash -c 'make -s smoke & make -s api & make -s web & wait'
wait || true

failed=0
for lane in root web e2e; do
  code="$(cat "$lane_dir/$lane.code" 2>/dev/null || echo 1)"
  if [ "$code" = "0" ]; then
    printf '=== [%s] ok\n' "$lane"
  else
    printf '=== [%s] 失败（退出码 %s）\n' "$lane" "$code"
    tail -20 "$lane_dir/$lane.log" 2>/dev/null || true
    failed=1
  fi
done

printf '== 用时 %ss\n' "$(( $(date +%s) - start ))"

if [ "$failed" != "0" ]; then
  exit 1
fi
echo
echo "ci: ok"
