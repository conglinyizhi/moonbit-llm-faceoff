# 被 demo.sh / smoke.sh / web-e2e.sh source 的公共函数。

# build_mbtx <src.mbtx> <out-binary>
#
# 为什么先 build 再复制，而不是直接 `moon run foo.mbtx &`：
#
#   `moon run foo.mbtx &` 的 $! 是 **moon 包装进程**，真正的服务是它 spawn
#   出来的 scripts/_build/native/debug/build/single/single.exe。包装进程忽略
#   SIGTERM，杀掉它也带不走那个子进程——结果是每跑一次测试，后台就漏一个
#   监听着端口的 mock 服务，越跑越多。
#
#   先 `moon build` 再用独立的文件名复制出来，`$!` 就是服务进程本身，
#   kill 一次就干净。顺带也省掉了每次调用都重新解析 .mbtx 的开销。
build_mbtx() {
  local src="$1" out="$2"
  moon build --target native "$src" >/dev/null || return 1
  # 先复制到临时名再 mv：直接 cp 覆盖一个正在运行的可执行文件会
  # "Text file busy"（上一次测试的进程还没退干净时就会撞上）。
  # rename 是原子的，运行中的进程继续用旧 inode，互不影响。
  cp scripts/_build/native/debug/build/single/single.exe "$out.tmp" || return 1
  chmod +x "$out.tmp"
  mv -f "$out.tmp" "$out"
}

# 假端点与检查器的固定落点（都在已被 gitignore 的 scripts/_build/ 下）
MOCK_BIN="scripts/_build/mock-endpoint"
CHECKER_BIN="scripts/_build/check-incremental"
