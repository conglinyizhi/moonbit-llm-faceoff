#!/usr/bin/env bash
#
# 构建前端。
#
#   web/styles/site.scss   → precss        → web/out/site.css
#   web/cmd/app  (js)      → moon build    → web/out/app.js     交互页
#   web/shell/index.html   → 复制          → web/out/index.html 交互页外壳
#   web/cmd/ssg  (native)  → Rabbita SSR   → web/out/report.html 静态报告
#
# 用法：
#   bash web/build.sh                        # 复用已有的 results-example.jsonl
#   bash web/build.sh path/to/results.jsonl  # 换一份结果日志
#
# 只重新导出页面数据时不需要真的调用模型：bench --from-json 走 replay 路径。

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

# 本机 native 工具链需要显式指定 C 编译器（否则报 /usr/bin/lib.exe 缺失）
export MOON_CC=${MOON_CC:-gcc}
export MOON_AR=${MOON_AR:-ar}
export MOON_LD=${MOON_LD:-gcc}

results=${1:-bench/results-example.jsonl}

if [ ! -f "$results" ]; then
  echo "error: no results log at $results" >&2
  exit 1
fi

if [ ! -f web/data.json ] || [ "$results" -nt web/data.json ]; then
  echo "==> 从 $results 导出 web/data.json"
  moon build cmd/bench --target native >/dev/null
  ./_build/native/debug/build/cmd/bench/bench.exe \
    --from-json "$results" --no-key --web-data web/data.json
else
  # 静默用旧数据会让人以为「我明明传了这个文件，怎么报告还是上一轮的」——
  # 所以这里必须出声。
  echo "==> web/data.json 比 $results 新，跳过导出"
  echo "    报告用的是 web/data.json 里的数据。要强制从 $results 重建："
  echo "      rm web/data.json && bash web/build.sh $results"
fi

cd web
moon update >/dev/null
mkdir -p out

echo "==> 编译样式（precss）与页面"
moon build cmd/ssg --target native >/dev/null
./_build/native/debug/build/cmd/ssg/ssg.exe      # 写 out/site.css 与 out/report.html

echo "==> 编译交互页（js）"
moon build cmd/app --target js >/dev/null
cp _build/js/debug/build/cmd/app/app.js out/app.js

echo "==> 交互页外壳"
cp shell/index.html out/index.html

echo
echo "产物："
ls -la out/
echo
echo "启动："
echo "  MOONLLM_API_KEY=... LLM_WEB_MODELS=MiniCPM5-1B,MiniCPM5-2B \\"
echo "    ./_build/native/debug/build/cmd/server/server.exe"
echo "  然后打开 http://127.0.0.1:8137/"
