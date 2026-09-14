# 被 web-e2e.sh source 的公共函数。
# （smoke 已经换成 smoke.mbtx，不再用这里的东西。）

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
  # 每个子脚本用**自己的** target-dir：默认所有 .mbtx 的单文件产物都落在同一个
  # single/single.exe 上，两个脚本同时构建就会互相顶掉。按子脚本名分家之后，
  # 并发的目标才敢同时跑（与 scripts/*.mbtx 里 mbtx_dir 的做法一致）
  local dir="scripts/_build/mbtx/$(basename "$src")"
  moon build --target native --target-dir "$dir" "$src" >/dev/null || return 1
  # moon 在 target-dir 之下又会拼一层源文件名
  local leaf; leaf="$(basename "$src")"
  local single="$dir/$leaf/native/debug/build/single/single.exe"
  [ -f "$single" ] || single="$dir/$leaf/native/debug/build/single/single"
  # 先复制到临时名再 mv：直接 cp 覆盖一个正在运行的可执行文件会
  # "Text file busy"（上一次测试的进程还没退干净时就会撞上）。
  # rename 是原子的，运行中的进程继续用旧 inode，互不影响。
  cp "$single" "$out.tmp" || return 1
  chmod +x "$out.tmp"
  mv -f "$out.tmp" "$out"
}

# 假端点与检查器的固定落点（都在已被 gitignore 的 scripts/_build/ 下）
MOCK_BIN="scripts/_build/mock-endpoint"
CHECKER_BIN="scripts/_build/check-incremental"
