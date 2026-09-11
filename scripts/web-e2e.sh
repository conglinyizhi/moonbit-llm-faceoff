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
  [ -n "${2:-}" ] && { echo "--- 输出片段 ---" >&2; head -c 2000 "$2" >&2; echo >&2; }
  exit 1
}

echo "==> 构建"
moon build cmd/bench --target native >/dev/null
moon run --target native scripts/build-web.mbtx >/dev/null
(cd web && moon build cmd/server --target native >/dev/null)

tmp=$(mktemp -d -p .)
tmp=$(cd "$tmp" && pwd)
cleanup() {
  kill "${webkit_pid:-}" "${chrome_pid:-}" "${web_pid:-}" "${web2_pid:-}" \
    "${mock_pid:-}" 2>/dev/null || true
  rm -rf "$tmp" 2>/dev/null || true
}
trap cleanup EXIT

build_mbtx scripts/mock_openai.mbtx "$MOCK_BIN" || fail "mock 编译失败"

echo "==> 起 mock LLM 与评测服务"
exec env MOCK_STREAM_DELAY=0.02 "$MOCK_BIN" >"$tmp/mock.port" 2>/dev/null &
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
      [ -n "$DEBUG_PORT" ] && return 0
    fi
    sleep 0.1
  done
  fail "浏览器调试端口没起来" "$tmp/chrome.log"
}

# CDP + 真实等待：虚拟时间会和页面里的 fetch 抢时钟，不可靠
dump_page() {
  node scripts/cdp-dump.mjs "$DEBUG_PORT" "$1" "$2" "$3" 2>"$3.err" || true
}

# 转储前先跑一段 JS（cdp-dump.mjs 的 --script）。脚本的返回值与异常都打到
# $3.err，调用方 grep SCRIPT 那一行就能拿到结果。
dump_page_script() {
  node scripts/cdp-dump.mjs "$DEBUG_PORT" "$1" "$2" "$3" \
    --script "$4" --script-wait "${5:-1500}" 2>"$3.err" || true
}

start_browser
dump_page "http://127.0.0.1:$PORT/" 6000 "$tmp/form.html"

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
echo "ok: 浏览器里表单渲染出来了（含手输模型 / 网关 / 密钥，/api/meta 链路通）"

echo "==> 浏览器触发一次评测（?autorun）"
run_url="http://127.0.0.1:$PORT/?autorun=1&models=mock-a,mock-b&cases=math-short&repeats=1&maxTokens=64&paceMs=0&retry=0"
dump_page "$run_url" 30000 "$tmp/run.html"

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
dump_page_script "$run_url" 8000 "$tmp/history.html" "$history_probe" 2500
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
  out.presetNameFilled = setValue("#preset-name", "e2e-preset");
  await new Promise((r) => setTimeout(r, 400));
  const savePreset = byText("button", "保存当前配置");
  if (savePreset) { savePreset.click(); }
  await new Promise((r) => setTimeout(r, 1800));
  out.presets = Array.from(document.querySelectorAll(".preset-name")).map((e) => e.textContent);
  return out;
})()'
dump_page_script "$run_url" 8000 "$tmp/manage.html" "$manage_probe" 2500
probe=$(grep -o 'SCRIPT .*' "$tmp/manage.html.err" | sed 's/^SCRIPT //')
echo "$probe" | grep -q '"hasSetSelect":true' ||
  fail "用例集的下拉没渲染出来：$probe"
echo "$probe" | grep -qE '"drafts":[1-9]' ||
  fail "编辑态里没有草稿：$probe"
echo "$probe" | grep -q '已保存' ||
  fail "保存用例集没有成功反馈：$probe"
echo "$probe" | grep -q 'e2e-preset' ||
  fail "预设没有出现在列表里：$probe"
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
dump_page_script "$run_url" 8000 "$tmp/compare.html" "$compare_probe" 2500
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
dump_page_script "http://127.0.0.1:$PORT/" 8000 "$tmp/annotate.html" "$annotate_probe" 2500
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
dump_page_script "http://127.0.0.1:$PORT/" 8000 "$tmp/annotate2.html" "$reload_probe" 1500
probe=$(grep -o 'SCRIPT .*' "$tmp/annotate2.html.err" | sed 's/^SCRIPT //')
echo "$probe" | grep -q '不行' || fail "重新打开后判定丢了：$probe"
echo "$probe" | grep -q 'e2e 备注' || fail "重新打开后备注丢了：$probe"
echo "ok: 标注（判定 + 备注落盘、重开还在、导出带着走）"

echo "==> 试跑台（单独的页面）"
# 固定 system + 一组 prompt × 两个模型：跑完看矩阵、点开看对比与差异。
dump_page "http://127.0.0.1:$PORT/playground.html" 6000 "$tmp/playground.html"
grep -q 'id="system"' "$tmp/playground.html" || fail "试跑台没有 system 输入框" "$tmp/playground.html"
grep -q 'id="prompt-0"' "$tmp/playground.html" || fail "试跑台没有 prompt 行" "$tmp/playground.html"
grep -q '开始试跑' "$tmp/playground.html" || fail "试跑台没有开始按钮" "$tmp/playground.html"
grep -q 'playground.html' "$tmp/form.html" || fail "工作台里没有去试跑台的入口" "$tmp/form.html"

playground_probe='(async () => {
  const out = {};
  const byText = (t) => Array.from(document.querySelectorAll("button")).find((b) => b.textContent === t);
  const boxes = Array.from(document.querySelectorAll(".picker-items input[type=checkbox]"));
  out.modelBoxes = boxes.length;
  out.checked = boxes.filter((b) => b.checked).length;
  if (out.checked < 2) { return out; }
  byText("开始试跑").click();
  await new Promise((r) => setTimeout(r, 8000));
  out.rows = document.querySelectorAll(".matrix-row").length;
  out.cells = document.querySelectorAll(".cell").length;
  const heights = Array.from(document.querySelectorAll(".cell")).map((c) => Math.round(c.getBoundingClientRect().height));
  out.uniformHeights = heights.length > 1 && Math.min.apply(null, heights) === Math.max.apply(null, heights);
  const row = document.querySelector(".matrix-row");
  row.querySelector(".matrix-row-head button").click();
  await new Promise((r) => setTimeout(r, 400));
  out.expandedCols = document.querySelectorAll(".matrix-row.expanded .compare-col").length;
  out.cotFolded = document.querySelectorAll(".matrix-row.expanded details.cot").length;
  byText("差异视图").click();
  await new Promise((r) => setTimeout(r, 400));
  out.diffBlocks = document.querySelectorAll(".diff-block").length;
  return out;
})()'
dump_page_script "http://127.0.0.1:$PORT/playground.html" 6000 "$tmp/playground-run.html" "$playground_probe" 2000
probe=$(grep -o 'SCRIPT .*' "$tmp/playground-run.html.err" | sed 's/^SCRIPT //')
echo "$probe" | grep -qE '"checked":2' || fail "试跑台默认没勾上两个模型：$probe"
echo "$probe" | grep -qE '"rows":2' || fail "试跑台没渲染出两行（两条 prompt）：$probe"
echo "$probe" | grep -qE '"cells":4' || fail "试跑台没渲染出 2×2 个单元格：$probe"
echo "$probe" | grep -q '"uniformHeights":true' || fail "单元格高度不一致：$probe"
echo "$probe" | grep -qE '"expandedCols":2' || fail "点开对比没出现左右两列：$probe"
echo "$probe" | grep -qE '"diffBlocks":[1-9]' || fail "差异视图没有内容：$probe"
echo "ok: 试跑台（矩阵等高等宽、点开左右对比、差异视图）"

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
dump_page_script "$run_url" 30000 "$tmp/export.html" "$export_probe" 2000

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

dump_page "http://127.0.0.1:$PORT2/?autorun=1&models=mock-a&cases=math-short&repeats=1&maxTokens=32&paceMs=0&retry=0" 8000 "$tmp/nokey.html"

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
dump_page "$mid_url" 1200 "$tmp/mid.html"

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
dump_page_script "http://127.0.0.1:$PORT/" 8000 "$tmp/delete.html" "$delete_probe" 2000
probe=$(grep -o 'SCRIPT .*' "$tmp/delete.html.err" | sed 's/^SCRIPT //')
echo "$probe" | grep -q '"after":' || fail "删除探针没跑起来：$probe"
before=$(echo "$probe" | sed -n 's/.*"before":\([0-9]*\).*/\1/p')
after=$(echo "$probe" | sed -n 's/.*"after":\([0-9]*\).*/\1/p')
[ -n "$before" ] && [ -n "$after" ] && [ "$after" -lt "$before" ] ||
  fail "点「删除」之后列表没变短（$before → $after）：$probe"
echo "ok: 点「删除」之后那条从列表里消失（$before → $after）"

echo
echo "web e2e: 全部通过"
