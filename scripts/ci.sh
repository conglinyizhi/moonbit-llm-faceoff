#!/usr/bin/env bash
#
# make ci 的真身：把确定性的那套测试按「抢哪个构建目录」分成两段跑。
#
# 为什么要分通道，而不是无脑 `make -j`：
#   moon 的锁是目录级的（_build/、scripts/_build/ 各一把）。同一个目录上的并发调用
#   不会失败，而是**排队**——所以「把所有目标一起丢出去」不会更快，只会把输出搅在
#   一起。按目录分开之后，通道之间真的互不相干，通道内部保持串行。
#
#   页面和 CLI 现在是同一个模块了，模块本身的检查/测试/页面构建都抢 _build，
#   所以它们分在两段、不互相抢；真正能并行的是第二段那三个 .mbtx 目标。
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
echo "== 前级：格式检查；之后两段：模块检查/测试（native + js）→ 端到端（smoke∥api∥web）"

# 前级：格式检查。它最便宜（两三秒），失败原因也最直白，所以放在最前面：
# 格式没过就不必再花时间编译和跑测试。修法就是跑一次 make fmt
if ! moon fmt --check; then
  printf '=== 格式检查未通过：跑一次 make fmt\n'
  exit 1
fi

# 一个模块，一条通道：check 两种目标 + 单测都写在同一把 _build 锁上，
# 拆开并行只会排队，还会把输出搅在一起
run_lane module bash -c 'moon check --target native && moon check --target js && moon test --target native'
wait || true

# 端到端：这三个才是真正互不相干的（各自的 .mbtx 有自己的构建目录）。
# 注意 web 这一条会构建根模块的 cmd/bench 与 web/cmd/*，所以它留在这一段、
# 不和上面的 module 通道同时跑——实测同时跑会抢 _build 的锁，反而更慢
#
# 三个目标的退出码必须逐个收：无参 wait 返回 0，会把失败吞掉。CI 上因此
# 报过假绿（一个套件实际 5 项失败，lane 却写 ok），然后再去查为何绿
run_lane e2e bash -c '
  pids=()
  for t in smoke api web; do
    make -s "$t" &
    pids+=($!)
  done
  rc=0
  for p in "${pids[@]}"; do
    wait "$p" || rc=1
  done
  exit $rc
'
wait || true

failed=0
for lane in module e2e; do
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
