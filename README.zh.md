# faceoff

[English](README.md) · **中文**

面向 OpenAI 兼容聊天接口的 MoonBit 客户端，外加一套在同一题集上对比多个模型的测试工具。

三个可以直接跑的东西：

| 可执行文件 | 作用 | 源码 |
| --- | --- | --- |
| `faceoff` | 问一句，一次性或流式返回 | `cmd/faceoff` |
| `bench` | 同一套用例跑多个模型，出对比报告 | `cmd/bench` |
| `web server` | 网页版：勾模型/调参数/跑评测/看结果 | `web/cmd/server` |

仓库里所有测试都对着内置的假端点离线跑——**不需要任何 API key 就能看到它工作**。

---

## 装起来、跑起来

**不需要懂 MoonBit 也能跑。** 你需要：

- MoonBit 工具链（第 1 步）
- 一个 C 编译器——`gcc` 或 `clang`，通常系统里已经有了

就这两样。离线演示和测试**不需要任何别的东西**——它们打的假端点本身就是个
MoonBit 脚本（[`scripts/mock_openai.mbtx`](scripts/mock_openai.mbtx)）。

### 1. 安装 MoonBit

**请以官方安装说明为准，那份是最新且权威的：**

- 中文：<https://www.moonbitlang.cn/download/>
- English: <https://www.moonbitlang.com/download/>

官网给出的三种方式，便于照抄：

| 平台 | 命令 |
| --- | --- |
| macOS / Linux | `curl -fsSL https://cli.moonbitlang.com/install/unix.sh \| bash` |
| Windows（PowerShell） | `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser; irm https://cli.moonbitlang.com/install/powershell.ps1 \| iex` |
| VS Code | 命令面板 → `MoonBit:install latest moonbit toolchain` |

然后确认 `~/.moon/bin` 在 `PATH` 里，验证一下：

```bash
moon version
```

上面这些如果失效或和官网不一致，**以上面的官网链接为准**——这里只是抄了一份，官网才是源头。

### 2. 先跑起来——不需要 API key

```bash
git clone <本仓库> && cd moonbit-llm-faceoff
bash scripts/demo.sh
```

`scripts/demo.sh` 会把所有东西编译好，起一个**本地的假 OpenAI 兼容端点**，然后把三条主要路径各走一遍：单次问答、流式输出、两个「模型」的对比。全程离线。

```
==> 1/3 单次问答
航空母舰是一种以舰载机为主要作战武器的大型水面舰艇。

==> 2/3 流式输出（碎片逐个到达）
侧风掠过甲板，把雨线吹成斜的。

==> 3/3 两个「模型」的对比
model mock-a
  runs 1   failures 0   truncated 0   retried 0
    first token (ms)       1          0 ...
...
```

### 3. 换成真实网关

任何 OpenAI 兼容的服务都行。把你的地址和密钥填进去：

```bash
export MOONLLM_BASE_URL="https://api.deepseek.com/v1"   # 任何 OpenAI 兼容地址
export MOONLLM_MODEL="deepseek-chat"
export MOONLLM_API_KEY="sk-..."

client=./_build/native/debug/build/cmd/faceoff/faceoff.exe
$client "用一句话说明什么是航空母舰"
$client --stream "写一首关于侧风的短诗"
```

接下来：[模型对比](#2-模型对比)，或者[网页版](#3-网页版)。

### 没接触过 MoonBit？

读这个仓库前，五行速览：

| 你会看到 | 它是什么 |
| --- | --- |
| `moon.mod` | 模块清单——一个仓库一份，相当于 `package.json` / `Cargo.toml` |
| `moon.pkg` | 包清单——**一个目录就是一个包**，里面列这个包的 import |
| `*.mbt` | 源码；`foo_test.mbt` / `foo_wbtest.mbt` 分别是黑盒/白盒测试 |
| `*.mbtx` | **单文件脚本**——`moon run --target native file.mbtx`，不需要模块和包清单。本仓库 `scripts/` 下的测试工具就是这种 |
| `_build/` | 构建产物（`_build/native/debug/build/.../main.exe`） |
| `moon build` / `run` / `test` / `check` | 构建 / 运行 / 测试 / 类型检查 |

语言本身看 <https://docs.moonbitlang.com/>，包生态看 <https://mooncakes.io/>。

本仓库是两个模块：根目录是库和命令行工具，`web/` 是前端（它有自己的 `moon.mod`）。要命令行就构建根目录，要网页就 `cd web`。

### 构建失败怎么办

| 现象 | 处理 |
| --- | --- |
| `failed to resolve native archiver executable /usr/bin/lib.exe`，或 `new native backend requires a C compiler/linker driver` | 系统里有 C 编译器但没被识别。显式指定：`MOON_CC=gcc moon build --target native`。本仓库所有脚本都默认带上 `MOON_CC=gcc` |
| `Cannot find import '...'` | registry 索引过期，跑 `moon update` |
| 浏览器测试报 `cannot open shared object file` | 浏览器二进制比它链接的系统库旧。用 `ldd $(command -v chromium)` 看缺哪个，或者用 `CHROME=/path/to/chrome` 换一个 |

---

## 目录

- [1. 单次问答与流式输出](#1-单次问答与流式输出)
- [2. 模型对比](#2-模型对比)
- [3. 网页版](#3-网页版)
- [4. 当作库使用](#4-当作库使用)
- [5. 架构说明](#5-架构说明)
- [6. 测试](#6-测试)
- [7. 已知边界](#7-已知边界)
- [8. 目录结构](#8-目录结构)
- [9. 延伸阅读](#9-延伸阅读)
- [10. 参与贡献](#10-参与贡献)

---

## 1. 单次问答与流式输出

```bash
# 一次性
faceoff "用一句话说明什么是航空母舰"

# 流式，碎片到达即打印
faceoff --stream "写一首关于侧风的短诗"

# 从 stdin 读 prompt
echo "总结一下这段日志" | faceoff --stream
```

### 参数

| 参数 | 含义 |
| --- | --- |
| `-s`, `--stream` | 流式输出 |
| `--model <id>` | 模型 id |
| `--base-url <url>` | 接口地址 |
| `--api-key <key>` | bearer token |
| `--system <text>` | 系统提示词 |
| `--temperature <t>` | 采样温度 |
| `--max-tokens <n>` | 最大生成 token 数 |
| `--timeout-ms <n>` | 单请求超时（默认 60000；**只作用于一次性路径**） |
| `--no-key` | 允许空 key（本地端点） |
| `--` | 后面的全部当作 prompt 文本 |
| `-h`, `--help` | 打印上面的用法 |

### 环境变量

每项取列表里第一个非空变量。

| 配置 | 变量 | 默认值 |
| --- | --- | --- |
| API key | `MOONLLM_API_KEY`, `OPENAI_API_KEY`, `LLM_API_KEY` | — |
| 接口地址 | `MOONLLM_BASE_URL`, `OPENAI_BASE_URL` | `https://api.openai.com/v1` |
| 模型 | `MOONLLM_MODEL`, `OPENAI_MODEL` | `gpt-4o-mini` |
| 系统提示词 | `MOONLLM_SYSTEM` | `You are a helpful assistant.` |

命令行参数优先于环境变量。错误写 stderr 并以非零码退出，可以放心放进管道：

```
$ faceoff --api-key wrong "hi"
error: http 401: {"error":{"message":"invalid api key"}}
```

---

## 2. 模型对比

`bench` 把同一套用例串行跑在多个模型上，然后出对比报告。**串行是刻意的**——两个模型抢同一条连接，那就不叫对比了。

```bash
bench \
  --base-url https://api.modelbest.cn/v1 --api-key "$MB_KEY" \
  --models MiniCPM5-1B,MiniCPM5-2B \
  --cases bench/cases.example.jsonl \
  --repeats 3 --max-tokens 2048 --temperature 0.0 \
  --pace-ms 3000 --retry 3 \
  --json bench/results-example.jsonl
```

也可以不写用例文件，直接问一句：

```bash
bench --model MiniCPM5-1B --prompt "用一句话说明什么是航空母舰" --show-cot
```

### 用例格式

JSON Lines，一行一题——或者一个 JSON 数组。空行和以 `#` 开头的行会跳过。只有 `prompt` 是必填。

```json
{"id": "math-short", "prompt": "计算 17 × 23。只输出数字。", "max_tokens": 512, "temperature": 0.0}
```

`id`、`system`、`max_tokens`、`temperature` 是用例级覆盖，没写的回落到 benchmark 参数。示例见 `bench/cases.example.jsonl`。

### 测的是什么

每一次尝试都是流式请求，所以计时来自真实的 chunk 到达，而不是总墙钟时间。

| 指标 | 含义 |
| --- | --- |
| `首 token` | 到第一个碎片为止，**包含**思考内容 |
| `首正文` | 到可见回答的第一个碎片为止，即思考之后 |
| `总耗时` | 到流结束 |
| `decode tok/s` | 首 token **之后**那个窗口的 `completion_tokens`——客户端能观测到的最接近解码速度的量 |
| `端到端 tok/s` | 整个请求的 `completion_tokens` |
| `推理 token` / `推理占比` | 多少预算花在思考上 |
| `failures` / `retried` / `truncated` | 限流、服务端错误、被 `max_tokens` 截断 |

推理型模型让最后一组指标变得关键：每 token 快一倍、但思考 token 多五倍的模型，总耗时可能反而更高。[`docs/benchmark-notes.md`](docs/benchmark-notes.md) 里有一个正好撞上这种情况的实测。

报告给出每个模型的中位数 / 均值 / 最小 / 最大，外加一张并排对比表；**正好两个模型时会多一列倍率**。

### 限流

跑得快的模型更容易撞到每分钟请求数上限。`--pace-ms` 拉开间隔，`--retry` 对 429/5xx 做指数退避。**每次重试都会重置计时器**，所以退避过的运行报的仍然是真正产出 token 那一次的延迟，输出里 `attempts > 1` 会记录下这件事。

### 重放一次运行

`--from-json` 完全跳过模型调用，从已有的运行日志重建报告和页面数据：

```bash
# 无网络、不需要 key
bench --from-json bench/results-example.jsonl --no-key --web-data web/data.json
```

改了报告想重渲染、或者想事后重新评分而不想再花钱调模型时很有用。

### 输出

| 参数 | 内容 |
| --- | --- |
| `--json <file>` | 每次尝试一行 JSON Lines，含完整回答与思考文本 |
| `--web-data <file>` | 网页模块渲染用的页面数据文档（schema 见 `bench/pagedata.mbt`） |
| `--show-cot` | 思考文本实时刷到 stderr |
| `--show-output` | 每次运行结束后把回答打到 stderr |

进度走 stderr，报告走 stdout。

```bash
jq -r 'select(.case_id=="code-python") | "\(.model)\t\(.completion_tokens)\t\(.content)"' \
  bench/results-example.jsonl
```

---

## 3. 网页版

```bash
bash web/build.sh

MOONLLM_API_KEY=... \
MOONLLM_BASE_URL=https://api.modelbest.cn/v1 \
LLM_WEB_MODELS=MiniCPM5-1B,MiniCPM5-2B \
  ./web/_build/native/debug/build/cmd/server/server.exe
# → http://127.0.0.1:8137/
```

页面上可以勾模型、选用例、调重复次数 / `max_tokens` / 温度 / 间隔 / 重试、填一次性指令，然后点开始。进度和结果实时回传。

**网关密钥由服务端读取，不会作为页面的一部分下发给浏览器**——页面只知道「配了 key 没有」。万一上游错误把密钥回显回来，正文在到达页面或磁盘之前就已经遮蔽了，见 [`SECURITY.md`](SECURITY.md)。

### URL 本身就是配置

query 参数覆盖默认值，`autorun=1` 表示打开即跑——所以一条链接就能携带整套对比配置：

```
http://127.0.0.1:8137/?autorun=1&models=MiniCPM5-1B,MiniCPM5-2B&cases=math-short,fact-zh&repeats=1
```

支持：`autorun`、`models`、`cases`、`prompt`、`repeats`、`maxTokens`、`temperature`、`paceMs`、`retry`。

### API

| 端点 | 作用 |
| --- | --- |
| `GET /api/meta` | `{models, cases, defaults, hasKey, baseUrl}` |
| `POST /api/runs` | 建一次运行 → `{id, total}` |
| `GET /api/runs/<id>` | `{status, done, total, exitCode?, tail?, data?, error?}` |

`data` 和静态报告消费的是同一份文档。一次运行是一个**子进程**（`bench --json … --web-data …`），全部状态落在 `web/runs/<id>/` 里的文件：

```
web/runs/<id>/
  request.json     这次请求的参数
  cases.jsonl      过滤后的用例集（选了具体用例时）
  runs.jsonl       bench 的原始输出，运行中不断增长——进度就是它的行数
  stdout.log       bench 的 stdout（渲染出的报告）
  stderr.log       bench 的进度日志
  exit_code        由外层 shell 最后写入；它出现就代表"跑完了"
  data.json        最终的页面数据文档
```

### 服务端环境变量

| 变量 | 默认值 |
| --- | --- |
| `LLM_WEB_PORT` | `8137` |
| `LLM_WEB_STATIC` | `out` |
| `LLM_WEB_WORK` | `runs` |
| `LLM_WEB_CASES` | `../bench/cases.example.jsonl` |
| `LLM_WEB_MODELS` | `MiniCPM5-1B,MiniCPM5-2B` |
| `LLM_BENCH_BIN` | `../_build/native/debug/build/cmd/bench/bench.exe` |
| `MOONLLM_API_KEY` / `OPENAI_API_KEY` | — |
| `MOONLLM_BASE_URL` / `OPENAI_BASE_URL` | `https://api.openai.com/v1` |

### 静态报告

`web/cmd/ssg` 把同一套结果组件渲染成一个自包含页面——没有 JavaScript，不需要服务端：

```bash
bash web/build.sh path/to/other-runs.jsonl   # → web/out/report.html
```

### 样式

`web/styles/site.scss` 在构建时由 [`conglinyizhi/precss`](https://mooncakes.io/docs/conglinyizhi/precss) 编译。用到了变量、嵌套、`&`、`@mixin`/`@include` 和 `@media`；编译产物 `out/site.css` 里这些全部展开完毕，不留 `$`、`@mixin`、`@include`。没有引入任何 CSS 框架。

---

## 4. 当作库使用

`bench` 包可以单独用，客户端也是。

在自己的 `moon.pkg` 里要写显式别名——模块路径末段是 `faceoff`，但带连字符的末段不能当默认别名用：

```text
import {
  "conglinyizhi/moonbit-llm-faceoff" @faceoff,
}
```

```moonbit
// 一次性
let settings = @faceoff.Settings::from_env(env)
let reply = @faceoff.ask(settings, "用一句话说明什么是航空母舰")

// 流式，思考碎片和正文碎片分开
let outcome = @faceoff.stream_parts(settings, prompt, async fn(part) {
  match part {
    Content(text) => handle_answer(text)
    Reasoning(thought) => handle_thought(thought)
  }
})
// outcome.content / outcome.reasoning / outcome.usage / outcome.finish_reason
```

```moonbit
// 跑 benchmark
let cases = @bench.parse_cases(text)
let results = @bench.run_bench(settings, models, cases, options, on_start, on_part, on_result)
let summaries = @bench.summarize_all(models, results)
println(@bench.format_summaries(summaries))
```

`@bench.parse_results` 把运行日志读回来，`RunResult::to_json` / `RunResult::from_json` 做单次尝试的往返，`page_data_json` 生成网页模块渲染的那份文档。

错误统一收敛成 `ClientError`（`Transport` / `Status` / `Decode`），调用方不需要 import 传输层包。

---

## 5. 架构说明

三个从代码里看不出来的决定。

**两条路径都直接对接端点，中间没有客户端库。**
请求体用 `Json` 拼（`request_body`），回复从 `Json` 里读回来（`response_text`）——对外暴露的是**线格式**，不是某个库的类型。流式自己分帧，`parse_sse_line` 是纯函数，分帧逻辑照旧可单测。整个包只依赖 `moonbitlang/async`。

当初试过把流式交给一个库，后来拆了：那个入口收的是**同步**回调，而同步回调里调不了 `@stdio.stdout.write`，碎片没法实时写出去。之后就干脆把依赖整个拿掉，没有只为了保留一次性路径而留着它。

**`web/` 是独立模块，不依赖本库。**
`rabbita` 需要 `moonbitlang/async` 0.21.x，而本库钉在 0.20.1。放进同一个 workspace 会强制统一 async 版本，**进而把库编译打坏**。所以统计只在 `bench` 里算一次，然后用 JSON 交出去——实时运行走进程边界，静态报告走文件。

这个版本钉子现在已经没有外部原因了。第三方 LLM 包拿掉之后，库完全可以升到 0.21.x，两个模块就能并进同一个 workspace，子进程边界和 JSON 中转也就不再必要。那是一次独立的改动，还没做。

**运行状态落在文件里，不在服务端内存里。**
服务端不在内存里保存任何一次运行的状态：bench 进程通过 `/bin/sh` 启动，结束时由它把退出码追加到一个文件；**这个文件出现就是完成信号**，而 `runs.jsonl` 的行数就是进度。运行 id 靠**建目录**来分配——目录已存在时 `mkdir` 会失败，这个失败本身就是原子的 test-and-set——所以两个并发请求不可能选到同一个 id。服务端里唯一的锁是一把信号量，用来串行化 `stderr` 写入：`@stdio.stderr` 是全局单句柄，并发写会让进程直接 abort。

---

## 6. 测试

```bash
moon test --target native      # 54 个单测，不联网
bash scripts/smoke.sh          # 命令行端到端，对着本地假端点
bash scripts/web-e2e.sh        # 浏览器端到端（无头 chromium）
```

| 套件 | 覆盖 |
| --- | --- |
| `moon test` | 配置解析与优先级、参数解析与错误分支、请求 JSON 结构、响应解码、SSE 分帧（正文/思考/usage/finish/`[DONE]`/CRLF/畸形输入）、用例文件解析、统计量、吞吐推导、运行记录往返、页面数据契约、上游错误体里的密钥遮蔽 |
| `scripts/smoke.sh` | 环境变量与命令行两种方式的一次性请求、流式、stdin、**增量投递**、非 ASCII 错误体解码、鉴权失败、鉴权失败时不得回显密钥，以及 bench 打同一个假端点 |
| `scripts/web-e2e.sh` | 真实无头浏览器：表单能从 `/api/meta` 渲染出来，`?autorun` 链接确实能跑完一次评测并渲染结果，八个并发 `POST /api/runs` 拿到八个不同 id，且跑完之后开始按钮回到可用状态 |

其中三条是刻意写成这样的——**用「显而易见的写法」会在实现坏了的情况下照样通过**：

- **增量投递**：假端点每片之间 sleep，测试测量的是「首字节到达时刻相对于进程退出时刻」。只比对最终输出的话，缓冲式实现和流式实现的结果一模一样。
- **非 ASCII 错误体**：假端点返回中文 429 正文，测试断言它能被解码。把字节当 UTF-16 重新解释而不是按 UTF-8 解码，这个错**只在非 ASCII 载荷上**才会暴露成乱码。
- **并发建运行**：八个并发 `POST /api/runs` 必须拿到八个不同 id。单请求测试在 id 分配还是「读改写计数器」的时候照样能通过——只有两个请求同时到达才会崩，而手动测试恰恰永远不会那么干。

`scripts/web-e2e.sh` 通过 DevTools 协议驱动 Chromium，按真实时间等待。它**刻意不用** `--virtual-time-budget`：虚拟时间会和页面自己的 `fetch` 抢时钟，转储出半加载的页面。用 `CHROME=/path/to/chrome` 可以换别的浏览器。

---

## 7. 已知边界

- **`--timeout-ms` 不作用于流式路径。** 总时长超时会砍掉合法的长回复，空闲超时又需要给每次 read 套定时器。一次性路径是生效的。
- **网页服务只绑 `127.0.0.1`，没有鉴权。** 它是本地开发工具，别对外暴露。
- **只实现了 OpenAI 兼容的线格式。** 没有 Anthropic / Gemini 转换；端点必须接受 `/chat/completions`。
- **target 声明**：库和两个命令行工具只声明 `native`；`web/` 下 `cmd/app` 是 `js`，`cmd/server` 和 `cmd/ssg` 是 `native`，`shared` 是 `js+native+wasm`。
- **间隔与重试的默认值是启发式。** 只对着一个网关的限流器调过。你自己的环境用 `--pace-ms 0` 试一下就知道。

---

## 8. 目录结构

```text
moon.pkg            库包的 import 声明（仅 native）
faceoff.mbt         包文档
settings.mbt        Settings + ConfigError，环境变量解析
cli.mbt             Cli::parse，用法文本
api.mbt             请求构造、响应/SSE 解析
runner.mbt          ask / stream_chat / stream_parts / stream_to_stdout
*_test.mbt          黑盒单测
*_wbtest.mbt        白盒单测（内部辅助函数）

bench/              测试工具
  bench.mbt         入口
  case.mbt          用例解析
  runner.mbt        run_case / run_bench、重试、JSON 往返
  metrics.mbt       Stats、summarize
  report.mbt        人类可读报告
  pagedata.mbt      网页模块消费的数据文档
  cli.mbt           bench 参数解析

cmd/faceoff/        faceoff 可执行文件
cmd/bench/          bench 可执行文件

web/                前端（独立模块：Rabbita + precss）
  shared/           数据模型 + 结果组件（js + native 共用）
  cmd/app/          交互页（js，Rabbita TEA）
  cmd/server/       静态文件 + API 服务（native）
  cmd/ssg/          静态报告（native）
  styles/           site.scss → precss → site.css
  shell/            交互页的 index.html 外壳
  build.sh          一条命令构建

scripts/
  demo.sh               离线、免 API key 的三路径演示
  mock_openai.mbtx      离线 OpenAI 兼容端点，MoonBit 脚本
  check_incremental.mbtx  量 --stream 是否真的在流式
  smoke.sh              命令行端到端
  web-e2e.sh            浏览器端到端
  cdp-dump.mjs          DevTools 协议 DOM 转储 / 整页截图
  lib.sh                上面几个脚本共用的辅助函数

docs/               选型调查、基准复盘
```

---

## 9. 延伸阅读

- [`docs/library-survey.md`](docs/library-survey.md)——Mooncakes 生态调查、集成其中一个包时发现的坑，以及最后为什么把那个依赖拿掉了。
- [`docs/benchmark-notes.md`](docs/benchmark-notes.md)——MiniCPM5-1B 对 MiniCPM5-2B 的完整复盘，包括那个**和吞吐率直觉相反**的结论。
- MoonBit：<https://www.moonbitlang.cn/> ·
  文档 <https://docs.moonbitlang.com/> ·
  包生态 <https://mooncakes.io/>

## 10. 参与贡献

- [`CONTRIBUTING.md`](CONTRIBUTING.md) —— 构建要求、几条硬规矩（不用 Python、为什么分成两个模块），以及提 PR 前该跑什么。
- [`SECURITY.md`](SECURITY.md) —— 怎么报漏洞，以及你的 API key 会经过哪里、不会去哪里。
- [`CHANGELOG.md`](CHANGELOG.md) —— 各版本改了什么，包括从 `llm_client` 改名这一条。

## 许可证

MIT，见 [`LICENSE`](LICENSE)。
