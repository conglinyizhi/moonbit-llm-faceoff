#!/usr/bin/env bash
#
# 浏览器端到端测试：真的起服务、真的用 chromium 打开页面。
#
# 覆盖：
#   1. 页面加载 → /api/meta → 表单渲染（含手输模型 / 网关 / 密钥）
#   2. ?autorun 链接 → 真的跑一次评测 → 结果渲染出来
#   3. 导出区与复制（真的点按钮，真的读剪贴板）
#   4. 并发创建运行：8 个并发必须拿到 8 个不同 id
#   5. 服务端运行目录与静态资源
#
# 全程用 mock LLM 端点，不碰真实网关、不需要 key。

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

# shellcheck source=scripts/lib.sh
source scripts/lib.sh

export MOON_CC=${MOON_CC:-gcc}
export MOON_AR=${MOON_AR:-ar}
export MOON_LD=${MOON_LD:-gcc}

WEB_PORT=${LLM_WEB_PORT:-0}
# 本机 /usr/bin/chromium 可用（ungoogled-chromium-bin 152）。
# 沙箱环境下需要 --no-sandbox；--disable-extensions 避免顺带拉起 KDE 的
# plasma-browser-integration 宿主。用 CHROME=... 可换别的浏览器。
CHROME=${CHROME:-/usr/bin/chromium}
DEBUG_PORT=${DEBUG_PORT:-0}
CHROME_FLAGS=(--headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage
              --disable-extensions --no-first-run --disable-crash-reporter
              --remote-debugging-port="$DEBUG_PORT")

fail() {
  echo "FAIL: $1" >&2
  # 用 if 而不是 `[ -n ] && ...`：脚本开头是 set -e，测试不成立时那一句返回
  # 非零，会把函数就地打断（这里恰好是「不打印片段」，换成别处就是静默不执行）
  if [ -n "${2:-}" ]; then
    echo "--- 输出片段 ---" >&2
    head -c 2000 "$2" >&2
    echo >&2
  fi
  exit 1
}

echo "==> 构建"
moon build cmd/bench --target native >/dev/null
moon run --target native scripts/build-web.mbtx >/dev/null
(cd web && moon build cmd/server --target native >/dev/null)

# 临时目录放系统临时区，不放仓库根目录。
#
# 以前是 `mktemp -d -p .`，跑一次就在仓库里留一个 tmp.XXXX（浏览器 profile 十几
# MB 起步），只能靠 .gitignore 遮着。E2E_TMP_DIR 指定时用它——想把现场留在手边
# 就设它。
tmp=$(mktemp -d "${E2E_TMP_DIR:-${TMPDIR:-/tmp}}/faceoff-e2e.XXXXXXXX") ||
  {
    echo "e2e: 建不了临时目录" >&2
    exit 1
  }
tmp=$(cd "$tmp" && pwd)

# 收尾：先让进程真的退出，再删目录。
#
# 两处坑，都踩过：
#   1. 顺序反了会留下空壳：kill 只是发信号，浏览器还在退出流程里，而它收尾时会
#      重建自己的 profile 目录（mkdir -p 会把父目录一并建回来），于是 rm -rf
#      之后原地又长出一个 tmp.XXXX
#   2. `[ -n "$pid" ] && kill "$pid"` 在 pid 为空时返回非零，而脚本开头是
#      `set -e`——这一句会让 cleanup 自己中断，后面的 rm 一次都不执行
#      （表现就是仓库根目录下越堆越多的 tmp.XXXX）
cleanup() {
  local pid
  local pids=(
    "${webkit_pid:-}" "${chrome_pid:-}" "${web_pid:-}" "${web2_pid:-}"
    "${mock_pid:-}"
  )
  for pid in "${pids[@]}"; do
    if [ -n "$pid" ]; then
      kill_tree "$pid"
    fi
  done
  # wait 收尸：僵尸进程还在时 kill -0 依然为真，会让「退出了没有」判断失真
  wait 2>/dev/null || true

  if [ "${E2E_KEEP_TMP:-}" = "1" ]; then
    echo "e2e: 现场保留在 $tmp（E2E_KEEP_TMP=1）"
    return 0
  fi
  rm -rf "$tmp" 2>/dev/null || true
  # 极短的竞态：某个孙进程可能刚写完最后一个文件。再补一次，不留空壳。
  sleep 0.2
  rm -rf "$tmp" 2>/dev/null || true
  return 0
}

# 连子孙一起收：浏览器起的是进程树（zygote / renderer / gpu），只 kill 顶层
# 会留下一堆认不出主人的进程，它们还会继续往临时目录里写东西。
kill_tree() {
  local pid="$1" child
  if command -v pgrep >/dev/null 2>&1; then
    for child in $(pgrep -P "$pid" 2>/dev/null || true); do
      kill_tree "$child"
    done
  fi
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  kill -9 "$pid" 2>/dev/null || true
  return 0
}

trap cleanup EXIT

build_mbtx scripts/mock_openai.mbtx "$MOCK_BIN" || fail "mock 编译失败"

echo "==> 起 mock LLM 与评测服务"
exec env MOCK_STREAM_DELAY=0.08 "$MOCK_BIN" >"$tmp/mock.port" 2>/dev/null &
mock_pid=$!
for _ in $(seq 1 200); do [ -s "$tmp/mock.port" ] && break; sleep 0.05; done
mock_port=$(cat "$tmp/mock.port")
[ -n "$mock_port" ] || fail "mock LLM 没起来"

# exec：让子 shell 被服务端进程替换，$! 才是服务端本身的 pid。
# 不加 exec 时 $! 是子 shell，cleanup 里 kill 它杀不掉服务端，会留下孤儿监听端口。
# 端口用 0 让内核分配：共用机器上硬编码端口会撞车。
# 服务端把实际端口写在 stdout 第一行，和 mock 的握手方式一致。
(cd web && exec env \
  MOONLLM_BASE_URL="http://127.0.0.1:$mock_port/v1" \
  MOONLLM_API_KEY=test-key \
  LLM_WEB_MODELS="mock-a,mock-b" \
  LLM_WEB_PORT="$WEB_PORT" \
  LLM_WEB_WORK="$tmp/runs" \
  LLM_WEB_CASES_DIR="$tmp/cases" \
  LLM_WEB_PRESETS="$tmp/presets.json" \
  ./_build/native/debug/build/cmd/server/server.exe >"$tmp/web.port" 2>"$tmp/server.log") &
web_pid=$!
for _ in $(seq 1 200); do
  [ -s "$tmp/web.port" ] && break
  sleep 0.05
done
PORT=$(tr -d '\n' < "$tmp/web.port" 2>/dev/null)
[ -n "$PORT" ] || fail "评测服务没吐出端口" "$tmp/server.log"
curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/meta" || fail "评测服务没起来" "$tmp/server.log"

echo "==> 静态资源"
for f in / /index.html /app.js /site.css /report.html; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$f")
  [ "$code" = "200" ] || fail "$f 返回 $code"
done
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/nope.js")
[ "$code" = "404" ] || fail "不存在的文件应返回 404，实际 $code"
echo "ok: 静态资源与 404"

echo "==> 浏览器加载页面（表单渲染）"
start_browser() {
  # HOME 必须是绝对路径，浏览器会拒绝相对路径
  mkdir -p "$tmp/home"
  XDG_RUNTIME_DIR="$tmp" HOME="$tmp/home" "$CHROME" "${CHROME_FLAGS[@]}" \
    --user-data-dir="$tmp/home/profile" about:blank >"$tmp/chrome.log" 2>&1 &
  chrome_pid=$!
  # --remote-debugging-port=0：让浏览器自己挑端口，再把实际值写进
  # <user-data-dir>/DevToolsActivePort。共用机器上硬编码调试端口会撞车。
  local port_file="$tmp/home/profile/DevToolsActivePort"
  for _ in $(seq 1 200); do
    if [ -s "$port_file" ]; then
      DEBUG_PORT=$(head -1 "$port_file" | tr -d '\r\n')
      if [ -n "$DEBUG_PORT" ]; then
        return 0
      fi
    fi
    sleep 0.1
  done
  fail "浏览器调试端口没起来" "$tmp/chrome.log"
}

# CDP + 真实等待：虚拟时间会和页面里的 fetch 抢时钟，不可靠
# 第二个参数是**上限**，不是「必须等这么久」：第 4 个参数给了就绪条件时，
# 条件一满足就往下走。没给条件 = 保留原来的固定等待——每个段落在等的条件都不一样
# （等表单、等跑完、等历史出现），一刀切会把「采样运行中」这类断言等坏。
#
# 页面本地渲染 + 几个本地 fetch 通常几百毫秒就绪，而这里有近二十次转储：
# 每次硬等 6–8 秒，加起来就是全部时间的绝大部分。
DUMP_READY_FORM='document.querySelector("#case-math-short") !== null'
DUMP_READY_HISTORY='document.querySelector(".history-item") !== null'
# 「这次跑完了」还不够：跑完的那一下页面才去刷历史列表，而下面几段都要点开
# 历史里的某一条。所以要等两件事都有。
DUMP_READY_RUN_DONE='/已完成|失败/.test((document.querySelector(".progress-head") || {}).textContent || "") && document.querySelector(".history-item") !== null'

# 条件里通常带空格，所以要按数组传：写成 $ready 会被 shell 拆成多个参数，
# 条件本身只剩前半截（语法错 → 每次求值都失败 → 每次都等满上限，白等还不报错）
dump_page() {
  local args=()
  if [ -n "${4:-}" ]; then
    args=(--wait-for "$4")
  fi
  node scripts/cdp-dump.mjs "$DEBUG_PORT" "$1" "$2" "$3" "${args[@]}" \
    2>"$3.err" || true
}

# 转储前先跑一段 JS（cdp-dump.mjs 的 --script）。脚本的返回值与异常都打到
# $3.err，调用方 grep SCRIPT 那一行就能拿到结果。
dump_page_script() {
  local args=()
  if [ -n "${6:-}" ]; then
    args=(--wait-for "$6")
  fi
  node scripts/cdp-dump.mjs "$DEBUG_PORT" "$1" "$2" "$3" "${args[@]}" \
    --script "$4" --script-wait "${5:-1500}" 2>"$3.err" || true
}

start_browser
dump_page "http://127.0.0.1:$PORT/" 6000 "$tmp/form.html" "$DUMP_READY_FORM"

grep -q 'id="model-mock-a"' "$tmp/form.html" || fail "表单里没有模型选项" "$tmp/form.html"
grep -q 'id="model-mock-b"' "$tmp/form.html" || fail "表单里没有第二个模型" "$tmp/form.html"
grep -q 'id="case-math-short"' "$tmp/form.html" || fail "表单里没有用例选项" "$tmp/form.html"
grep -q '开始评测' "$tmp/form.html" || fail "表单里没有开始按钮" "$tmp/form.html"
grep -q 'id="repeats"' "$tmp/form.html" || fail "表单里没有参数输入" "$tmp/form.html"
# 新增的输入控件：能手填模型 id、网关地址与密钥
grep -q 'id="extra-models"' "$tmp/form.html" || fail "表单里没有手输模型 id 的输入框" "$tmp/form.html"
grep -q 'id="base-url"' "$tmp/form.html" || fail "表单里没有网关地址输入框" "$tmp/form.html"
grep -q 'id="api-key"' "$tmp/form.html" || fail "表单里没有 API key 输入框" "$tmp/form.html"
grep -q 'type="password"' "$tmp/form.html" || fail "API key 输入框不是 password 类型" "$tmp/form.html"
# system prompt 是运行级的：页面打开时预填（服务端 LLM_WEB_SYSTEM），能改
grep -q 'id="system"' "$tmp/form.html" || fail "工作台没有 system prompt 输入框" "$tmp/form.html"
# 网关与密钥应当排在「模型」之后、「预设」之前（原来在参数行下面）
python3 - "$tmp/form.html" <<'ORDER'
import sys
html = open(sys.argv[1], encoding="utf-8").read()
i_model = html.find('id="model-mock-a"')
i_gateway = html.find('id="base-url"')
i_key = html.find('id="api-key"')
i_system = html.find('id="system"')
i_preset = html.find("预设")
order = [i_model, i_gateway, i_key, i_system, i_preset]
sys.exit(0 if all(x >= 0 for x in order) and order == sorted(order) else 1)
ORDER
[ $? -eq 0 ] || fail "表单顺序不对（应为 模型 → 网关 → 密钥 → system → 预设）" "$tmp/form.html"
echo "ok: 浏览器里表单渲染出来了（含手输模型 / 网关 / 密钥，/api/meta 链路通）"

echo "==> 浏览器触发一次评测（?autorun）"
run_url="http://127.0.0.1:$PORT/?autorun=1&models=mock-a,mock-b&cases=math-short&repeats=1&maxTokens=64&paceMs=0&retry=0"
dump_page "$run_url" 30000 "$tmp/run.html" "$DUMP_READY_RUN_DONE"

grep -q '已完成' "$tmp/run.html" || fail "页面没有进入已完成状态" "$tmp/run.html"
grep -q 'mock-a' "$tmp/run.html" || fail "结果里没有模型" "$tmp/run.html"
grep -q 'mock-b' "$tmp/run.html" || fail "结果里没有第二个模型" "$tmp/run.html"
grep -q '首 token' "$tmp/run.html" || fail "结果里没有指标卡" "$tmp/run.html"
grep -q '对比' "$tmp/run.html" || fail "结果里没有对比表" "$tmp/run.html"
grep -q 'Hello from the mock server' "$tmp/run.html" || fail "结果里没有模型输出" "$tmp/run.html"
# 每个答案下面是默认收起的思考过程：摘要里有 token 与字数，正文在 details 里。
# 两个模型各一份（用例只有一道）。
grep -q '<details class="cot">' "$tmp/run.html" || fail "答案里没有可折叠的思考过程" "$tmp/run.html"
grep -q '思考过程 · 4 token' "$tmp/run.html" || fail "思考过程的摘要没有 token 数" "$tmp/run.html"
grep -q 'weighing the question' "$tmp/run.html" || fail "思考全文没有渲染出来" "$tmp/run.html"
# 跑完之后按钮要回到可用态。之前用 disabled 属性，Rabbita 的 vdom diff 没把它
# 摘掉，跑完一次就永远点不动——这条断言就是为那个 bug 加的。
grep -q 'primary busy' "$tmp/run.html" && fail "跑完之后按钮仍是忙碌态" "$tmp/run.html"
grep -q '开始评测' "$tmp/run.html" || fail "跑完之后没有回到可点的开始按钮" "$tmp/run.html"
echo "ok: 浏览器里跑完一次评测并渲染出了结果（按钮已回到可用态）"

echo "==> 运行记录侧栏"
grep -q '运行记录' "$tmp/run.html" || fail "页面里没有运行记录侧栏" "$tmp/run.html"
grep -q 'history-item' "$tmp/run.html" || fail "侧栏里没有历史条目" "$tmp/run.html"
# 规模描述（N 模型 × M 用例 × K 次）不写死数字：web/runs 可能还有别的运行，
# 而且这个测试自己跑几次就会变。只要格式在就说明数据到位了。
grep -qE '[0-9]+ 模型 × [0-9]+ 用例 × [0-9]+ 次' "$tmp/run.html" ||
  fail "历史条目没描述这次跑的规模" "$tmp/run.html"
# 点「打开」应该切到只读的历史视图：顶上一条横幅，下面是那一次的答案
history_probe='(async () => {
  const item = document.querySelector(".history-item");
  if (!item) { return { error: "no history item" }; }
  const label = item.querySelector(".history-models").textContent;
  item.querySelectorAll(".history-actions button")[0].click();
  await new Promise((r) => setTimeout(r, 2000));
  const banner = document.querySelector(".viewed-banner");
  return { label: label, banner: banner && banner.textContent,
           answers: document.querySelectorAll(".answer").length };
})()'
dump_page_script "$run_url" 8000 "$tmp/history.html" "$history_probe" 2500 "$DUMP_READY_RUN_DONE"
probe=$(grep -o 'SCRIPT .*' "$tmp/history.html.err" | sed 's/^SCRIPT //')
echo "$probe" | grep -q '正在看历史运行' ||
  fail "点「打开」没切到历史视图：$probe"
echo "$probe" | grep -q '"answers":[1-9]' ||
  fail "历史视图里没渲染出那次的结果：$probe"
echo "ok: 侧栏列得出历史，点开能看历史结果（只读）"

echo "==> 用例集与预设"
# 页面改一条用例 + 存一条预设，然后回到磁盘上确认——页面说「已保存」不等于
# 真的写进去了，这一条断言就是奔着那道口子去的。
manage_probe='(async () => {
  const out = {};
  const setValue = (sel, value) => {
    const el = document.querySelector(sel);
    if (!el) { return false; }
    el.value = value;
    el.dispatchEvent(new Event("input", { bubbles: true }));
    return true;
  };
  const byText = (tag, text) =>
    Array.from(document.querySelectorAll(tag)).find((el) => el.textContent === text);
  out.hasSetSelect = !!document.querySelector(".set-select");
  const edit = Array.from(document.querySelectorAll(".link-btn")).find((b) => b.textContent === "编辑用例");
  if (edit) { edit.click(); }
  await new Promise((r) => setTimeout(r, 1500));
  out.drafts = document.querySelectorAll(".draft").length;
  const prompt = document.querySelector(".draft-prompt");
  if (prompt) {
    prompt.value = "e2e 改过的 prompt：用一句话说明什么是甲板风。";
    prompt.dispatchEvent(new Event("input", { bubbles: true }));
  }
  await new Promise((r) => setTimeout(r, 400));
  const save = byText("button", "保存用例集");
  if (save) { save.click(); }
  await new Promise((r) => setTimeout(r, 1800));
  out.saved = document.querySelector(".editor-actions .copied")
    ? document.querySelector(".editor-actions .copied").textContent : null;
  // system 也要跟着预设走：填一段 → 存预设 → 改成别的 → 套用回来必须还原
  const sysBox = document.querySelector("#system");
  if (sysBox) {
    const setSystem = (text) => {
      sysBox.value = text;
      sysBox.dispatchEvent(new Event("input", { bubbles: true }));
    };
    setSystem("E2E 预设里的 system。");
    await new Promise((r) => setTimeout(r, 300));
    const nameBox = document.querySelector("#preset-name") || document.querySelector("input[placeholder='预设名字']");
    nameBox.value = "e2e-system-preset";
    nameBox.dispatchEvent(new Event("input", { bubbles: true }));
    await new Promise((r) => setTimeout(r, 200));
    Array.from(document.querySelectorAll("button")).find((b) => b.textContent === "保存当前配置").click();
    await new Promise((r) => setTimeout(r, 1500));
    setSystem("改掉了以后不该留下。");
    await new Promise((r) => setTimeout(r, 300));
    const card = Array.from(document.querySelectorAll(".preset-list *")).find((el) => el.textContent === "e2e-system-preset");
    const applyBtn = card ? card.parentElement.querySelector("button") : null;
    if (applyBtn) { applyBtn.click(); }
    await new Promise((r) => setTimeout(r, 1200));
    out.systemAfterApply = document.querySelector("#system").value;
  }
  // 按行导入也接在用例编辑里
  const importBox = document.querySelector("#import-lines");
  out.hasImport = !!importBox;
  if (importBox) {
    const before = document.querySelectorAll(".draft").length;
    importBox.value = "导入的用例甲\n导入的用例乙\n";
    importBox.dispatchEvent(new Event("input", { bubbles: true }));
    await new Promise((r) => setTimeout(r, 300));
    Array.from(document.querySelectorAll("button")).find((b) => b.textContent === "追加导入").click();
    await new Promise((r) => setTimeout(r, 600));
    out.draftsAfterImport = document.querySelectorAll(".draft").length - before;
  }
  out.presetNameFilled = setValue("#preset-name", "e2e-preset");
  await new Promise((r) => setTimeout(r, 400));
  const savePreset = byText("button", "保存当前配置");
  if (savePreset) { savePreset.click(); }
  await new Promise((r) => setTimeout(r, 1800));
  out.presets = Array.from(document.querySelectorAll(".preset-name")).map((e) => e.textContent);
  return out;
})()'
dump_page_script "$run_url" 8000 "$tmp/manage.html" "$manage_probe" 2500 "$DUMP_READY_RUN_DONE"
probe=$(grep -o 'SCRIPT .*' "$tmp/manage.html.err" | sed 's/^SCRIPT //')
echo "$probe" | grep -q '"hasSetSelect":true' ||
  fail "用例集的下拉没渲染出来：$probe"
echo "$probe" | grep -qE '"drafts":[1-9]' ||
  fail "编辑态里没有草稿：$probe"
echo "$probe" | grep -q '已保存' ||
  fail "保存用例集没有成功反馈：$probe"
echo "$probe" | grep -q 'e2e-preset' ||
  fail "预设没有出现在列表里：$probe"
echo "$probe" | grep -q '"systemAfterApply":"E2E 预设里的 system。"' ||
  fail "套用预设没有把 system 还原回来：$probe"
echo "$probe" | grep -q '"hasImport":true' ||
  fail "用例编辑里没有按行导入：$probe"
echo "$probe" | grep -qE '"draftsAfterImport":2' ||
  fail "按行导入没加进用例草稿：$probe"
grep -q 'e2e 改过的 prompt' "$tmp/cases/default.jsonl" ||
  fail "页面说保存了，但磁盘上的用例没变"
grep -q 'e2e-preset' "$tmp/presets.json" ||
  fail "页面说存了预设，但磁盘上没有"
echo "ok: 页面上能用例集（编辑→保存落到磁盘）与预设（保存→出现在列表）"

echo "==> 两次运行对比"
# 勾两次运行 → 头部换成「对比这两次」→ 点下去应该出来三块：参数差异、指标
# 差值、逐用例答案并排。
compare_probe='(async () => {
  const out = {};
  const pickBtn = (item) =>
    Array.from(item.querySelectorAll(".history-actions button")).find((b) => b.textContent.includes("对比"));
  const items = Array.from(document.querySelectorAll(".history-item"));
  out.items = items.length;
  if (items.length < 2) { return out; }
  pickBtn(items[0]).click();
  await new Promise((r) => setTimeout(r, 300));
  pickBtn(items[1]).click();
  await new Promise((r) => setTimeout(r, 600));
  out.picked = document.querySelectorAll(".history-item.picked").length;
  const head = Array.from(document.querySelectorAll(".history .section-head button"));
  const cmp = head.find((b) => b.textContent === "对比这两次");
  out.hasButton = !!cmp;
  if (cmp) { cmp.click(); }
  await new Promise((r) => setTimeout(r, 2500));
  out.banner = document.querySelector(".viewed-banner") ? document.querySelector(".viewed-banner").textContent : null;
  out.blocks = Array.from(document.querySelectorAll(".compare-block h2")).map((h) => h.textContent);
  out.cases = document.querySelectorAll(".compare-case").length;
  out.cols = document.querySelectorAll(".compare-col").length;
  out.deltaCells = document.querySelectorAll(".diff-delta").length;
  return out;
})()'
dump_page_script "$run_url" 8000 "$tmp/compare.html" "$compare_probe" 2500 "$DUMP_READY_RUN_DONE"
probe=$(grep -o 'SCRIPT .*' "$tmp/compare.html.err" | sed 's/^SCRIPT //')
echo "$probe" | grep -q '"picked":2' ||
  fail "勾两次运行没有把两条都选上：$probe"
echo "$probe" | grep -q '"hasButton":true' ||
  fail "勾满两条之后没出现「对比这两次」：$probe"
echo "$probe" | grep -q '指标差值' ||
  fail "对比视图里没有指标差值：$probe"
echo "$probe" | grep -q '逐用例答案' ||
  fail "对比视图里没有逐用例答案：$probe"
echo "$probe" | grep -qE '"cases":[1-9]' ||
  fail "对比视图里没有可比用例：$probe"
echo "$probe" | grep -qE '"deltaCells":[1-9]' ||
  fail "指标表里没有 Δ 列：$probe"
echo "ok: 勾两次运行能进对比视图（参数差异 / 指标差值 / 逐用例答案）"

# 结果区的三种摆法：长回答竖着堆下来没法比，所以要能换成并排，也得能只留下
# 分岔的地方（差异视图）。
echo "==> 结果区：每个模型一条 / 并排对比 / 差异"
views_probe='(async () => {
  const out = {};
  const byText = (t) => Array.from(document.querySelectorAll("button")).find((b) => b.textContent === t);
  const item = document.querySelector(".history-item");
  item.querySelectorAll(".history-actions button")[0].click();
  await new Promise((r) => setTimeout(r, 2500));
  out.modes = Array.from(document.querySelectorAll(".view-btn")).map((b) => b.textContent);
  out.stacked = document.querySelectorAll(".answer-col").length;
  byText("并排对比").click();
  await new Promise((r) => setTimeout(r, 700));
  const cols = Array.from(document.querySelectorAll(".answer-col"));
  out.columns = cols.length;
  out.colHeads = cols.slice(0, 2).map((c) => c.querySelector(".answer-col-head").textContent);
  const widths = cols.map((c) => Math.round(c.getBoundingClientRect().width));
  out.uniformWidth = widths.length > 1 && Math.min.apply(null, widths) === Math.max.apply(null, widths);
  const bodies = cols.map((c) => getComputedStyle(c.querySelector(".answer-col-body")).overflowY);
  out.scrollPerColumn = bodies.slice(0, 2).every((v) => v === "auto");
  byText("差异").click();
  await new Promise((r) => setTimeout(r, 700));
  out.diffBlocks = document.querySelectorAll(".diff-block").length;
  out.diffTitles = Array.from(document.querySelectorAll(".diff-title")).slice(0, 1).map((t) => t.textContent);
  out.noColumnsInDiff = document.querySelectorAll(".answer-col").length;
  byText("每个模型一条").click();
  await new Promise((r) => setTimeout(r, 500));
  out.backToStacked = document.querySelectorAll(".answer-col").length;
  return out;
})()'
dump_page_script "http://127.0.0.1:$PORT/" 8000 "$tmp/views.html" "$views_probe" 2500 "$DUMP_READY_HISTORY"
probe=$(grep -o 'SCRIPT .*' "$tmp/views.html.err" | sed 's/^SCRIPT //')
# 选择器同时匹配到分位按钮（P10…P99）与视图按钮，所以按包含关系断言
echo "$probe" | grep -q '"每个模型一条","并排对比","差异"' ||
  fail "结果区没有三种摆法的切换：$probe"
echo "$probe" | grep -q '"P10","P20","P50","P99"' ||
  fail "结果区没有分位切换：$probe"
echo "$probe" | grep -qE '"columns":([2-9]|[1-9][0-9])' ||
  fail "并排对比没渲染出多列：$probe"
# 表头是两个 span（模型名 + 规模），拼起来没有分隔符，所以分别断言
echo "$probe" | grep -qE '"colHeads":\["[^"]*mock-[a-z][^"]*[0-9]+ 字' ||
  fail "并排列上没有模型名与规模：$probe"
echo "$probe" | grep -q '"uniformWidth":true' ||
  fail "并排列宽度不相等（没法对齐着看）：$probe"
echo "$probe" | grep -q '"scrollPerColumn":true' ||
  fail "并排列没有各自的滚动条：$probe"
echo "$probe" | grep -qE '"diffBlocks":[1-9]' ||
  fail "差异视图没有逐用例的对比块：$probe"
echo "$probe" | grep -qE '"noColumnsInDiff":0' ||
  fail "差异视图里还叠着并排的列：$probe"
echo "$probe" | grep -qE '"backToStacked":0' ||
  fail "切回「每个模型一条」之后并排列还在：$probe"
echo "ok: 结果区三视图（并排列等宽各自滚动、差异视图、切回去）"

# 请求上下文：问了什么得能就地看见，而不是去翻 cases.jsonl
echo "==> 工作台的 system prompt（运行级）"
# 填一段 system、跑一次，再去「请求上下文」里核对：页面填的东西必须真的进了请求
system_probe='(async () => {
  const out = {};
  const byText = (t) => Array.from(document.querySelectorAll("button")).find((b) => b.textContent === t);
  const box = document.querySelector("#system");
  box.value = "E2E：把口语文本整理成书面表达。";
  box.dispatchEvent(new Event("input", { bubbles: true }));
  // 一条用例、一个模型、不重复：两次请求就结束
  // 不用 [id^=...]：属性选择器里的引号会和这层 JS 字符串的引号打架
  const checkboxes = [...document.querySelectorAll("input[type=checkbox]")];
  checkboxes.filter((c) => c.id.startsWith("case-")).forEach((c) => {
    const want = c.id === "case-math-short";
    if (c.checked !== want) c.click();
  });
  checkboxes.filter((c) => c.id.startsWith("model-")).forEach((c, i) => {
    if (c.checked !== (i === 0)) c.click();
  });
  const setField = (id, value) => {
    const el = document.querySelector("#" + id);
    el.value = value;
    el.dispatchEvent(new Event("input", { bubbles: true }));
  };
  setField("repeats", "1");
  setField("pace-ms", "0");
  await new Promise((r) => setTimeout(r, 400));
  byText("开始评测").click();
  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 250));
    const head = document.querySelector(".progress-head")?.textContent || "";
    if (/已完成|失败/.test(head)) break;
  }
  out.head = (document.querySelector(".progress-head")?.textContent || "").replace(/\s+/g, " ");
  // 打开第一道用例的请求上下文
  const btn = document.querySelector(".context-btn");
  btn.click();
  await new Promise((r) => setTimeout(r, 1500));
  const modal = document.querySelector(".modal");
  out.systemInDialog = (modal?.querySelector(".context-message pre")?.textContent || "").slice(0, 40);
  out.params = [...(modal?.querySelectorAll(".context-params dt") || [])].map((d) => d.textContent);
  return out;
})()'
dump_page_script "http://127.0.0.1:$PORT/" 8000 "$tmp/system.html" "$system_probe" 2000 "$DUMP_READY_FORM"
probe=$(grep -o 'SCRIPT .*' "$tmp/system.html.err" | sed 's/^SCRIPT //')
echo "$probe" | grep -q 'E2E：把口语文本整理成书面表达' ||
  fail "页面填的 system 没有进到请求里（请求上下文里看不到）：$probe"
echo "$probe" | grep -q 'system（全局）' ||
  fail "请求上下文里没有全局 system 那一行：$probe"
echo "ok: 工作台的 system prompt 进请求、且在请求上下文里可见"

echo "==> 请求上下文对话框"
context_probe='(async () => {
  const out = {};
  const byText = (t) => Array.from(document.querySelectorAll("button")).find((b) => b.textContent === t);
  const item = document.querySelector(".history-item");
  item.querySelectorAll(".history-actions button")[0].click();
  await new Promise((r) => setTimeout(r, 2500));
  const buttons = Array.from(document.querySelectorAll(".context-btn"));
  out.buttons = buttons.length;
  if (buttons.length === 0) { return out; }
  out.firstLabel = buttons[0].textContent;
  buttons[0].click();
  await new Promise((r) => setTimeout(r, 1500));
  const modal = document.querySelector(".modal");
  out.modal = !!modal;
  if (!modal) { return out; }
  out.params = Array.from(modal.querySelectorAll(".context-params dt")).map((d) => d.textContent);
  out.roles = Array.from(modal.querySelectorAll(".context-role")).map((r) => r.textContent);
  out.systemText = modal.querySelector(".context-message pre")?.textContent || "";
  out.userText = modal.querySelectorAll(".context-message pre")[1]?.textContent || "";
  out.backdrop = getComputedStyle(document.querySelector(".modal-backdrop")).position;
  out.radius = getComputedStyle(modal).borderRadius;
  byText("关闭").click();
  await new Promise((r) => setTimeout(r, 500));
  out.closed = document.querySelector(".modal") === null;
  return out;
})()'
dump_page_script "http://127.0.0.1:$PORT/" 8000 "$tmp/context.html" "$context_probe" 2500 "$DUMP_READY_HISTORY"
probe=$(grep -o 'SCRIPT .*' "$tmp/context.html.err" | sed 's/^SCRIPT //')
echo "$probe" | grep -qE '"buttons":[1-9]' ||
  fail "用例行上没有「请求上下文」按钮：$probe"
echo "$probe" | grep -q '"modal":true' ||
  fail "点了按钮没有弹出对话框：$probe"
echo "$probe" | grep -q '用例集' ||
  fail "对话框里没有运行级参数：$probe"
echo "$probe" | grep -qE '"roles":\["system","user"\]' ||
  fail "对话框里没有 system / user 两条消息：$probe"
echo "$probe" | grep -qE '"systemText":"[^"]{2,}"' ||
  fail "对话框里的 system 是空的：$probe"
echo "$probe" | grep -qE '"userText":"[^"]{2,}"' ||
  fail "对话框里的 user 是空的：$probe"
echo "$probe" | grep -q '"radius":"[1-9]' ||
  fail "对话框没有圆角（拟态的浮起感全在阴影和圆角上）：$probe"
echo "$probe" | grep -q '"closed":true' ||
  fail "点关闭之后对话框还在：$probe"
echo "ok: 请求上下文（按钮 → 拟态对话框 → system/user → 关闭）"

echo "==> 人工标注"
# 打开历史里的一次运行 → 给第一条答案打「不行」+ 备注 → 徽章出现、写进磁盘、
# 重新打开还在（这是「标注到底存没存下来」的分界线）。
annotate_probe='(async () => {
  const out = {};
  const byText = (t) => Array.from(document.querySelectorAll("button")).find((b) => b.textContent === t);
  let captured = null;
  try {
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText: (text) => { captured = text; return Promise.resolve(); } },
    });
  } catch (e) { out.clipboardError = String(e); }
  const item = document.querySelector(".history-item");
  item.querySelectorAll(".history-actions button")[0].click();
  await new Promise((r) => setTimeout(r, 2500));
  out.editors = document.querySelectorAll(".annotate").length;
  const ed = document.querySelector(".annotate");
  if (!ed) { return out; }
  Array.from(ed.querySelectorAll(".verdict-btn")).find((b) => b.textContent.includes("不行")).click();
  await new Promise((r) => setTimeout(r, 1200));
  const note = ed.querySelector(".note-input");
  note.value = "e2e 备注：这条算错了";
  note.dispatchEvent(new Event("input", { bubbles: true }));
  await new Promise((r) => setTimeout(r, 300));
  Array.from(ed.querySelectorAll("button")).find((b) => b.textContent === "存备注").click();
  await new Promise((r) => setTimeout(r, 1500));
  out.badges = Array.from(document.querySelectorAll(".verdict-badge")).map((b) => b.textContent);
  out.notes = Array.from(document.querySelectorAll(".verdict-note")).map((b) => b.textContent);
  const copy = byText("复制 Markdown 报告");
  if (copy) { copy.click(); await new Promise((r) => setTimeout(r, 800)); }
  out.markdownHasVerdict = captured ? captured.includes("不行") : null;
  out.markdownHasNote = captured ? captured.includes("e2e 备注") : null;
  return out;
})()'
dump_page_script "http://127.0.0.1:$PORT/" 8000 "$tmp/annotate.html" "$annotate_probe" 2500 "$DUMP_READY_HISTORY"
probe=$(grep -o 'SCRIPT .*' "$tmp/annotate.html.err" | sed 's/^SCRIPT //')
echo "$probe" | grep -qE '"editors":[1-9]' || fail "答案下面没有标注编辑器：$probe"
echo "$probe" | grep -q '不行' || fail "打了判定但徽章没出现：$probe"
echo "$probe" | grep -q 'e2e 备注' || fail "备注没显示出来：$probe"
echo "$probe" | grep -q '"markdownHasVerdict":true' || fail "复制的 Markdown 里没带判定：$probe"
echo "$probe" | grep -q '"markdownHasNote":true' || fail "复制的 Markdown 里没带备注：$probe"
grep -q 'e2e 备注' "$tmp/runs"/*/annotations.jsonl 2>/dev/null ||
  fail "标注没落到运行目录里"

# 重新打开一次：标注是存在磁盘上的，不是页面状态
reload_probe='(async () => {
  const item = document.querySelector(".history-item");
  item.querySelectorAll(".history-actions button")[0].click();
  await new Promise((r) => setTimeout(r, 2500));
  return {
    badges: Array.from(document.querySelectorAll(".verdict-badge")).map((b) => b.textContent),
    notes: Array.from(document.querySelectorAll(".verdict-note")).map((b) => b.textContent),
  };
})()'
dump_page_script "http://127.0.0.1:$PORT/" 8000 "$tmp/annotate2.html" "$reload_probe" 1500 "$DUMP_READY_HISTORY"
probe=$(grep -o 'SCRIPT .*' "$tmp/annotate2.html.err" | sed 's/^SCRIPT //')
echo "$probe" | grep -q '不行' || fail "重新打开后判定丢了：$probe"
echo "$probe" | grep -q 'e2e 备注' || fail "重新打开后备注丢了：$probe"
echo "ok: 标注（判定 + 备注落盘、重开还在、导出带着走）"

echo "==> 导出区与复制"
# 把 navigator.clipboard 换成一个记录器，再点两个复制按钮。
# 这样拿到的正是应用要写进剪贴板的内容，且不依赖无头浏览器是否允许读剪贴板。
# 这段 JS 刻意只用双引号，好安全地裹在 shell 的单引号里。
export_probe='(async () => {
  const row = document.querySelector(".export-row");
  if (!row) { return { error: "no export row" }; }
  const buttons = Array.from(row.querySelectorAll("button"));
  const links = Array.from(row.querySelectorAll("a")).map((a) => a.getAttribute("href"));
  let captured = null;
  try {
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText: (text) => { captured = text; return Promise.resolve(); } },
    });
  } catch (e) {}
  const grabs = {};
  for (const pair of [["markdown", 0], ["share", 1]]) {
    captured = null;
    buttons[pair[1]].click();
    await new Promise((r) => setTimeout(r, 350));
    grabs[pair[0]] = captured;
  }
  const copied = row.querySelector(".copied");
  return {
    labels: buttons.map((b) => b.textContent),
    links: links,
    feedback: copied ? copied.textContent : "",
    markdown: grabs.markdown,
    share: grabs.share,
  };
})()'
dump_page_script "$run_url" 30000 "$tmp/export.html" "$export_probe" 2000 "$DUMP_READY_RUN_DONE"

probe=$(grep -o 'SCRIPT {.*' "$tmp/export.html.err" | head -1)
[ -n "$probe" ] || fail "导出探针没返回结果" "$tmp/export.html.err"
echo "$probe" | grep -q '复制 Markdown 报告' || fail "没有「复制 Markdown 报告」按钮：$probe"
echo "$probe" | grep -q '复制分享链接' || fail "没有「复制分享链接」按钮：$probe"
echo "$probe" | grep -q '/runs.jsonl' || fail "没有 runs.jsonl 下载链接：$probe"
echo "$probe" | grep -q '/data.json' || fail "没有 data.json 下载链接：$probe"
echo "$probe" | grep -q '/report.html' || fail "没有静态报告下载链接：$probe"
grep -q '已复制' "$tmp/export.html" ||
  fail "点了复制之后页面上没有反馈文字" "$tmp/export.html"

# 复制出来的 Markdown 要是真报告：表头、指标名、逐例输出
echo "$probe" | grep -q '指标' || fail "复制的 Markdown 里没有对比表：$probe"
echo "$probe" | grep -q 'math-short' || fail "复制的 Markdown 里没有用例：$probe"
echo "$probe" | grep -q 'Hello from the mock server' ||
  fail "复制的 Markdown 里没有模型输出：$probe"

# 分享链接要能重建配置，且绝不能带密钥
echo "$probe" | grep -q 'models=' || fail "分享链接里没有 models 参数：$probe"
echo "$probe" | grep -q 'repeats=' || fail "分享链接里没有 repeats 参数：$probe"
if echo "$probe" | grep -qE 'apiKey|test-key'; then
  fail "分享链接里带了密钥：$probe"
fi
echo "ok: 导出区五项齐全，Markdown 与分享链接内容正确"

echo "==> autorun 在拿不到 key 时不该开跑"
# autorun 本来会在第一次轮询就撞鉴权失败，而看到那个错的人会以为是自己环境坏了。
# 所以现在没有可用密钥时干脆不跑，改为在页面上说明。
# 起第二个服务端：不配 key，独立工作目录，其余一样。
(cd web && exec env \
  MOONLLM_BASE_URL="http://127.0.0.1:$mock_port/v1" \
  LLM_WEB_MODELS="mock-a" \
  LLM_WEB_WORK="$tmp/runs-nokey" \
  LLM_WEB_PORT=0 \
  ./_build/native/debug/build/cmd/server/server.exe >"$tmp/web2.port" 2>/dev/null) &
web2_pid=$!
for _ in $(seq 1 200); do [ -s "$tmp/web2.port" ] && break; sleep 0.05; done
PORT2=$(tr -d '\n' <"$tmp/web2.port" 2>/dev/null)
[ -n "$PORT2" ] || fail "第二个服务端（无 key）没起来"

dump_page "http://127.0.0.1:$PORT2/?autorun=1&models=mock-a&cases=math-short&repeats=1&maxTokens=32&paceMs=0&retry=0" 8000 "$tmp/nokey.html" 'document.body.textContent.includes("没有自动开跑")'

grep -q '没有自动开跑' "$tmp/nokey.html" ||
  fail "无 key 时 autorun 被拦下了，但页面没说明原因" "$tmp/nokey.html"
if [ -d "$tmp/runs-nokey/run-1" ]; then
  fail "无 key 却仍然开跑了（建出了运行目录）"
fi
grep -q '运行中\|已完成' "$tmp/nokey.html" &&
  fail "无 key 却仍然开跑了（页面出现了运行状态）" "$tmp/nokey.html"
echo "ok: 无 key 时 autorun 不开跑，并在页面上说明了原因"

echo "==> 运行中就要能读到状态"
# 这一条是为一个真实 bug 加的：服务端曾经在运行中发 "exitCode": null，
# 而 MoonBit 派生的 Option 解码只认「键缺失」不认 null —— 页面在第一次轮询
# 就整个解析失败，把运行标成失败并停止轮询。只测「跑完之后」是抓不到的，
# 因为那时候 exitCode 已经是真字符串了。
# 这里让一次运行持续几秒（3 次 x 700ms 间隔），在 1.2 秒时采样。
mid_url="http://127.0.0.1:$PORT/?autorun=1&models=mock-a&cases=math-short&repeats=3&maxTokens=32&paceMs=700&retry=0"
# 条件要同时覆盖这一段断言的两件事：「运行中」状态，以及已经收到的日志尾。
# 只等「运行中」会太快——那一刻 bench 的第一行 stderr 可能还没写出来。
dump_page "$mid_url" 8000 "$tmp/mid.html" \
  'document.body.textContent.includes("实时日志尾部") && /运行中/.test((document.querySelector(".progress-head") || {}).textContent || "")'

grep -q 'JsonDecodeError' "$tmp/mid.html" &&
  fail "运行中响应解析失败了（页面会把运行误判成失败）" "$tmp/mid.html"
grep -q '运行中' "$tmp/mid.html" ||
  fail "运行中页面没有「运行中」状态" "$tmp/mid.html"
grep -q '失败 0 · 重试 0 · 截断 0' "$tmp/mid.html" ||
  fail "运行中看不到实时失败/重试/截断计数" "$tmp/mid.html"
grep -q '实时日志尾部' "$tmp/mid.html" ||
  fail "运行中看不到日志尾" "$tmp/mid.html"
echo "ok: 运行中状态可读（进行中 / 实时计数 / 日志尾）"

echo "==> 并发创建运行：id 必须互不重复"
# 每个请求各写各的文件：8 个进程并发 >> 同一个文件不可靠，也不好诊断
curl_pids=""
for i in $(seq 1 8); do
  curl -sS -X POST "http://127.0.0.1:$PORT/api/runs" \
    -H 'Content-Type: application/json' \
    -d '{"models":["mock-a"],"cases":["math-short"],"repeats":1,"maxTokens":32,"paceMs":0,"retry":0}' \
    >"$tmp/c$i.txt" 2>&1 &
  curl_pids="$curl_pids $!"
done
# 只等这些 curl：裸 wait 会连 mock 和服务端一起等，它们永不退出
for pid in $curl_pids; do wait "$pid" 2>/dev/null || true; done

created=0
ids=""
for i in $(seq 1 8); do
  id=$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "$tmp/c$i.txt" | head -1)
  if [ -n "$id" ]; then
    created=$((created + 1))
    ids="$ids $id"
  fi
done
[ "$created" = "8" ] || {
  echo "--- 各请求响应 ---" >&2
  for i in $(seq 1 8); do echo "  #$i $(head -c 120 "$tmp/c$i.txt")" >&2; done
  fail "并发建了 $created 个运行，期望 8 个"
}
unique=$(printf '%s\n' $ids | sort -u | grep -c . || true)
[ "$unique" = "8" ] || fail "并发下出现重复 id：$ids"
echo "ok: 8 个并发运行拿到 8 个不同 id"

echo "==> 服务端运行目录"
runs=$(find "$tmp/runs" -maxdepth 1 -type d -name 'run-*' 2>/dev/null | wc -l)
[ "$runs" -ge 1 ] || fail "服务端没有留下运行记录"
echo "ok: 运行记录 $runs 份"

# 删除放在最后：它会真的删掉一条历史，前面那些断言还要用这些运行。
echo "==> 删除一条历史"
delete_probe='(async () => {
  const before = document.querySelectorAll(".history-item").length;
  const item = document.querySelector(".history-item");
  if (!item) { return { error: "no history item" }; }
  const del = Array.from(item.querySelectorAll(".history-actions button"))
    .find((b) => b.textContent === "删除");
  if (!del) { return { error: "no delete button" }; }
  del.click();
  await new Promise((r) => setTimeout(r, 1500));
  return { before: before, after: document.querySelectorAll(".history-item").length };
})()'
dump_page_script "http://127.0.0.1:$PORT/" 8000 "$tmp/delete.html" "$delete_probe" 2000 "$DUMP_READY_HISTORY"
probe=$(grep -o 'SCRIPT .*' "$tmp/delete.html.err" | sed 's/^SCRIPT //')
echo "$probe" | grep -q '"after":' || fail "删除探针没跑起来：$probe"
before=$(echo "$probe" | sed -n 's/.*"before":\([0-9]*\).*/\1/p')
after=$(echo "$probe" | sed -n 's/.*"after":\([0-9]*\).*/\1/p')
[ -n "$before" ] && [ -n "$after" ] && [ "$after" -lt "$before" ] ||
  fail "点「删除」之后列表没变短（$before → $after）：$probe"
echo "ok: 点「删除」之后那条从列表里消失（$before → $after）"

echo
echo "web e2e: 全部通过"
