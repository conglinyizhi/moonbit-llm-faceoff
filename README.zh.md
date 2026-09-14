# faceoff

[English](README.md) · **中文**

面向 OpenAI 兼容聊天接口的 MoonBit 客户端，外加一套在同一题集上对比多个模型的测试工具。

| 可执行文件 | 作用 | 源码 |
| --- | --- | --- |
| `faceoff` | 问一句，一次性或流式返回 | `cmd/faceoff` |
| `bench` | 同一套用例跑多个模型，出对比报告 | `cmd/bench` |
| `web server` | 网页版：勾模型/调参数/跑评测/看结果 | `web/cmd/server` |

仓库里所有测试都对着内置的假端点离线跑，**不需要任何 API key 就能看到它工作**。

顶层就三块：`bench/`（用例解析、跑批、统计、报告、页面数据）、`cmd/`（两个可执行文件的入口）、`web/`（交互页、服务端与静态报告）。`scripts/` 放离线假端点、演示和各套测试，`docs/` 放调查与笔记。

## 快速使用

**不需要懂 MoonBit 也能跑。** 你需要 MoonBit 工具链（第 1 步）和一个 C 编译器：`gcc` 或 `clang`，通常系统里已经有了。就这两样，演示和测试打的假端点本身就是个 MoonBit 脚本（[`scripts/mock_openai.mbtx`](scripts/mock_openai.mbtx)）。

### 1. 安装 MoonBit

**请以官方安装说明为准，那份是最新且权威的：** <https://www.moonbitlang.cn/download/> · <https://www.moonbitlang.com/download/>。官网给出的三种方式，便于照抄：

| 平台 | 命令 |
| --- | --- |
| macOS / Linux | `curl -fsSL https://cli.moonbitlang.com/install/unix.sh \| bash` |
| Windows（PowerShell） | `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser; irm https://cli.moonbitlang.com/install/powershell.ps1 \| iex` |
| VS Code | 命令面板 → `MoonBit:install latest moonbit toolchain` |

确认 `~/.moon/bin` 在 `PATH` 里，然后用 `moon version` 验证。上面这些如果失效或和官网不一致，以官网为准。没接触过 MoonBit，或者 Linux 上构建报错？[`CONTRIBUTING.md`](CONTRIBUTING.md) 里有五行文件类型速览和三种常见构建失败的修法。

### 2. 先跑起来，不需要 API key

```bash
git clone <本仓库> && cd moonbit-llm-faceoff
moon run --target native scripts/demo.mbtx    # 就是 make demo
```

它会把所有东西编译好，起一个**本地的假 OpenAI 兼容端点**，然后把三条主要路径各走一遍：单次问答、流式输出、两个「模型」的对比。全程离线，开头长这样：

```
==> 1/3 单次问答
航空母舰是一种以舰载机为主要作战武器的大型水面舰艇。
==> 2/3 流式输出（碎片逐个到达）
侧风掠过甲板，把雨线吹成斜的。
==> 3/3 两个「模型」的对比
  runs 1   failures 0   truncated 0   retried 0
```

### 3. 打开网页版，同样不需要 key

```bash
make serve          # 构建页面，然后从 web/ 起服务端 → http://127.0.0.1:8137/
make dev            # 一样，但盯着源码：页面改了重建页面，服务端改了重启
make serve-demo     # 假端点 + 演示数据 + 页面，最快的整体一瞥
```

两种方式都记住一条：**服务端必须以 `web/` 作为工作目录。** 它的 `out/`、`runs/`、`cases/`、`presets.json` 都按当前工作目录解析；从仓库根启动的话，`/api` 通、页面一律 404。`make serve` 替你做了那次 `cd`，不用 make 就是 `moon run --target native scripts/build-web.mbtx`、`moon build web/cmd/server --target native`，再在 `web/` 里跑服务端二进制。要连真实网关，要么启动前导出 `MOONLLM_BASE_URL` / `MOONLLM_API_KEY`，要么干脆不配 key、**在页面上填**：它只对这一次运行生效，也不会写到磁盘。

### 4. 换成真实网关，跑一次对比

任何 OpenAI 兼容的服务都行。下面这一段覆盖整个闭环：一次问答、一次流式、两个真实模型上的一套用例、一份报告，最后是这个仓库里唯一打真实端点的探针脚本。

```bash
export MOONLLM_BASE_URL="https://api.deepseek.com/v1"   # 任何 OpenAI 兼容地址
export MOONLLM_MODEL="deepseek-chat"
export MOONLLM_API_KEY="sk-..."
make deps && MOON_CC=gcc moon build --target native      # 先构建一次
faceoff=./_build/native/debug/build/cmd/faceoff/faceoff.exe
bench=./_build/native/debug/build/cmd/bench/bench.exe
$faceoff "用一句话说明什么是航空母舰"                     # 一次性
$faceoff --stream "写一首关于侧风的短诗"                  # 流式，碎片到达即打印
echo "总结一下这段日志" | $faceoff --stream               # 从 stdin 读 prompt
mkdir -p my-run && printf '%s\n' '{"id":"math-short","prompt":"计算 17 × 23。只输出数字。"}' > my-run/cases.jsonl
$bench --models <模型A>,<模型B> --cases my-run/cases.jsonl --repeats 3 --max-tokens 2048 \
  --temperature 0.0 --pace-ms 1000 --retry 2 --json my-run/runs.jsonl
moon run --target native scripts/build-web.mbtx my-run/runs.jsonl     # → web/out/report.html
moon run --target native scripts/real-gateway.mbtx                    # → docs/real-gateway-run.md
```

两件第一次就该做对的事：**`--json` 写到你自己的路径**（`bench/results-example.jsonl` 是提交进来的样例，不是草稿纸）；**先看计数，再看延迟**。网关限流的话，`--pace-ms` 拉开尝试间隔，`--retry` 对 429/5xx 指数退避重试。密钥只在环境变量里（或者一次运行内待在页面内存里），不会写进运行目录，也不会进提交，见 [`SECURITY.md`](SECURITY.md)。参数、环境变量、用例格式、指标，以及这两件事的完整版，都在 [`docs/cli.md`](docs/cli.md)。

### 5. 产生的文件都在哪

服务端按自己的工作目录（`web/`）解析这几个路径：

| 路径 | 内容 |
| --- | --- |
| `web/cases/default.jsonl` | 自动生成的测试集：服务端首次启动、用例目录为空时，从 `bench/cases.example.jsonl` 播种；你自己的集也放这里，gitignore |
| `web/presets.json` | 预设：模型加参数，gitignore |
| `web/runs/` | 运行记录，一次运行一个目录，gitignore |
| `web/data.json` | 从一次运行导出的页面数据，gitignore |
| `web/out/` | 页面产物与静态报告，由 `scripts/build-web.mbtx` 产出 |

### 已知边界

- **`--timeout-ms` 不作用于流式路径。** 总时长超时会砍掉合法的长回复，空闲超时又需要给每次 read 套定时器。一次性路径是生效的。
- **网页服务只绑 `127.0.0.1`，没有鉴权。** 它是本地开发工具，别对外暴露。
- **只实现了 OpenAI 兼容的线格式。** 没有 Anthropic / Gemini 转换；端点必须接受 `/chat/completions`。
- **target 声明**：库和两个命令行工具只声明 `native`；`web/` 下 `cmd/app` 是 `js`，`cmd/server` 和 `cmd/ssg` 是 `native`，`shared` 是 `js+native+wasm`。
- **间隔与重试的默认值是启发式。** 只对着一个网关的限流器调过。你自己的环境用 `--pace-ms 0` 试一下就知道。

## 使用用法索引

细节在四份文档里；这一节是地图，让本页继续只当门面。

| 文档 | 覆盖 |
| --- | --- |
| [`docs/cli.md`](docs/cli.md) | `faceoff` 与 `bench`：怎么装、每个参数、环境变量、用例格式、指标、限流与重放、输出、从零到报告的完整闭环，以及打真实网关的探针 |
| [`docs/web.md`](docs/web.md) | 网页版与服务端：每个面板做什么、URL 参数、HTTP API、服务端环境变量、静态报告，以及 `web/` 的目录 |
| [`docs/library.md`](docs/library.md) | 把 `bench` 和客户端当 MoonBit 包用：import 别名、一次性、流式、跑批，以及错误类型 |
| [`docs/testing.md`](docs/testing.md) | `make ci` 跑什么、五套测试（85 个单测加上各套端到端）各自覆盖什么、其中四套为什么写成那样，以及 CI 不跑的那两套 |

最可能用到的命令，以及解释它们的那份文档：

| 命令 | 作用 | 文档 |
| --- | --- | --- |
| `make demo` | 三条路径的零 API key 演示 | [`docs/cli.md`](docs/cli.md) |
| `make serve` / `make dev` | 构建页面并从 `web/` 起服务；`dev` 边改边重建 | [`docs/web.md`](docs/web.md) |
| `make serve-demo` | 假端点 + 演示数据 + 页面 | [`docs/web.md`](docs/web.md) |
| `make install` / `make uninstall` | 把两个命令行工具装进 `~/.moon/bin` / 再摘掉 | [`docs/cli.md`](docs/cli.md) |
| `make ci` / `make e2e` | CI 跑的确定性套件 / 再加浏览器测试 | [`docs/testing.md`](docs/testing.md) |
| `make real-gateway` | 对着真实端点跑四个探针；要密钥，不进 CI | [`docs/testing.md`](docs/testing.md) |
| `make web` | 把页面构建进 `web/out/`，外加静态报告 | [`docs/web.md`](docs/web.md) |

## 来源与依赖

faceoff 是原创项目，仓库里没有移植也没有 vendored 的第三方代码：HTTP 客户端、流式读取、统计、对比跑批和页面都写在这里。也没有 LLM 客户端依赖，[`docs/library-survey.md`](docs/library-survey.md) 记下了当时调查并试用过的那个 Mooncakes 包、它缺什么，以及后来为什么拿掉。

| 包 | 许可证 | 用在哪 |
| --- | --- | --- |
| `moonbitlang/async` | Apache-2.0 | HTTP 客户端、流式读取、网页背后的本地服务端，以及跑批用的并发 |
| `moonbit-community/rabbita` | Apache-2.0 | 页面应用与静态报告生成器 |
| `conglinyizhi/precss` | Apache-2.0 | 编译 `web/styles/site.scss` |

协议格式是 OpenAI 兼容的 `POST /v1/chat/completions`，参加对比的模型都得会说这一套接口，其中不涉及 OpenAI 的 SDK 或代码。除 [`bench/cases.example.jsonl`](bench/cases.example.jsonl) 这个示例外，仓库里不带任何用例集：prompt 属于写它的人。

MIT，见 [`LICENSE`](LICENSE)。

## 其他文献

想一起参与？这三份能让上手快不少：

- [`CONTRIBUTING.md`](CONTRIBUTING.md)：怎么把环境弄起来、几条硬规矩（不用 Python、网页为什么消费 `bench` 的 `data.json`），以及提 PR 前该跑什么。
- [`SECURITY.md`](SECURITY.md)：怎么报漏洞，以及你的 API key 会经过哪里、不会去哪里。
- [`CHANGELOG.md`](CHANGELOG.md)：各版本改了什么，包括从 `llm_client` 改名这一条。

延伸阅读：

- [`AGENTS.md`](AGENTS.md)：代码里看不出来的几条承重约束（`web/` 与库之间的数据交接、运行状态为什么落在文件里、`stderr` 为什么要串行化）。
- [`docs/library-survey.md`](docs/library-survey.md)：Mooncakes 生态调查、集成其中一个包时发现的坑，以及最后为什么把那个依赖拿掉了。
- [`docs/benchmark-notes.md`](docs/benchmark-notes.md)：MiniCPM5-1B 对 MiniCPM5-2B 的完整复盘，包括那个和吞吐率直觉相反的结论。
- MoonBit：<https://www.moonbitlang.cn/> · 文档 <https://docs.moonbitlang.com/> · 包生态 <https://mooncakes.io/>
