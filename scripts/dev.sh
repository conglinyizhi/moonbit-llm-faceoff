#!/usr/bin/env bash
#
# 开发服务器：构建 → 起服务端 → 盯着源码改。
#
# 为什么不是「一个轻量的静态服务器」：
#   页面一打开就要 /api/meta，跑起来要 /api/runs、/api/cases——静态那半是
#   cmd/server 里最不费事的部分。再写一个静态服务器等于把已有的 API 服务端
#   抄一遍，还得两处同步。所以这里复用的就是 cmd/server 本身。
#
# 它解决的是另一个更疼的问题：服务端常驻、页面重建了而它还是旧的二进制，
# 新页面去解旧 JSON 就报 Missing field 白屏（踩过）。这里每次启动都先构建，
# 源码一变就重建：页面改动只重建页面（刷新即可），服务端改动才重启，并尽量
# 沿用原端口，免得浏览器标签失效。
#
# 用法：make dev    （Ctrl-C 退出）

set -euo pipefail

cd "$(dirname "$0")/.."
root="$(pwd)"
moon_cc="${MOON_CC:-gcc}"
port_file="$(mktemp)"
trap 'rm -f "$port_file"' EXIT

# 注意 find 的收尾都带 || true：路径写错（比如曾经的 web/moon.pkg）会让 find 非零，
# 而 pipefail + set -e 会因此**静默**退出整个脚本——日志里什么都不留，极难查
page_files() {
  find web/cmd/app web/cmd/ssg web/cmd/build web/shared web/styles web/shell \
    scripts/build-web.mbtx -type f 2>/dev/null || true
}
server_files() {
  find web/cmd/server web/shared -type f 2>/dev/null || true
}

# 一组文件里最新的 mtime。变了就重建：够用，且不依赖 inotifywait 这类额外命令
stamp() {
  local newest=0 t
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    t=$(stat -c %Y "$f")
    if [ "$t" -gt "$newest" ]; then newest="$t"; fi
  done
  echo "$newest"
}

build_page() { MOON_CC="$moon_cc" moon run --target native scripts/build-web.mbtx >/dev/null; }
build_server() { MOON_CC="$moon_cc" moon build web/cmd/server --target native; }

server_pid=""
port=""

stop_server() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
  fi
}
trap 'stop_server; exit 0' INT TERM

# start_server <想用的端口，0 = 让内核挑>
#   端口要沿用上一次的，浏览器标签才不会失效；但那个端口可能刚被占住，
#   所以起不来就退回去让内核挑
start_server() {
  local want="$1"
  : >"$port_file"
  (cd web && exec env LLM_WEB_PORT="$want" ../_build/native/debug/build/web/cmd/server/server.exe) \
    >"$port_file" 2>&1 &
  server_pid=$!
  local bound=""
  for _ in $(seq 1 100); do
    bound=$(grep -E '^[0-9]+$' "$port_file" 2>/dev/null | head -1 || true)
    [ -n "$bound" ] && break
    sleep 0.05
  done
  if [ -z "$bound" ]; then
    if [ "$want" != "0" ]; then
      echo "==> 端口 $want 没起来，退回去让内核挑"
      start_server 0
      return
    fi
    echo "服务端没起来，看 $port_file" >&2
    exit 1
  fi
  if [ "$bound" != "$port" ]; then
    port="$bound"
    printf '\n  页面：http://127.0.0.1:%s/\n\n' "$port"
  fi
}

echo "==> 构建服务端与页面"
build_server
build_page
start_server 0

page_stamp=$(page_files | stamp)
server_stamp=$(server_files | stamp)
echo "==> 盯着源码（Ctrl-C 退出）"

while true; do
  sleep 0.7
  new_server=$(server_files | stamp)
  new_page=$(page_files | stamp)
  if [ "$new_server" != "$server_stamp" ]; then
    server_stamp="$new_server"
    echo "==> 服务端源码变了：重建并重启（尽量沿用端口 $port）"
    build_server || continue
    stop_server
    start_server "$port"
    page_stamp=$(page_files | stamp)
  elif [ "$new_page" != "$page_stamp" ]; then
    page_stamp="$new_page"
    echo "==> 页面变了：重建（刷一下浏览器）"
    build_page || continue
  fi
done
