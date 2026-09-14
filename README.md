# faceoff

**English** · [中文](README.zh.md)

A MoonBit client for OpenAI-compatible chat endpoints, plus a harness for comparing models on the same prompt suite.

| binary | what it does | source |
| --- | --- | --- |
| `faceoff` | ask one prompt, once or streamed | `cmd/faceoff` |
| `bench` | run a suite against several models and compare them | `cmd/bench` |
| `web server` | interactive page: pick models/params, run, watch results | `web/cmd/server` |

Every test in this repo runs offline against a bundled mock, **so no API key is needed to see it work**.

Three top-level pieces: `bench/` (case parsing, running, statistics, report, page data), `cmd/` (entry points for the two executables) and `web/` (the interactive page, its server and the static report). `scripts/` holds the offline mock endpoint, the demos and the test suites, and `docs/` holds the surveys and the notes.

## Quick start

**You do not need to know MoonBit to run this.** You need the MoonBit toolchain (step 1) and a C compiler: `gcc` or `clang`, usually already present. That is the whole list, because the fake endpoint the demo and the tests run against is itself a MoonBit script ([`scripts/mock_openai.mbtx`](scripts/mock_openai.mbtx)).

### 1. Install MoonBit

**Follow the official instructions, they are authoritative and stay current:** <https://www.moonbitlang.com/download/> · <https://www.moonbitlang.cn/download/>. For convenience, the three official methods are:

| platform | command |
| --- | --- |
| macOS / Linux | `curl -fsSL https://cli.moonbitlang.com/install/unix.sh \| bash` |
| Windows (PowerShell) | `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser; irm https://cli.moonbitlang.com/install/powershell.ps1 \| iex` |
| VS Code | command palette → `MoonBit:install latest moonbit toolchain` |

Then make sure `~/.moon/bin` is on your `PATH` and verify with `moon version`. If any of the above fails or has changed, use the official page rather than this table. New to MoonBit, or building on Linux? [`CONTRIBUTING.md`](CONTRIBUTING.md) has a five-line orientation to the file types here and the three usual build failures.

### 2. Build it and try it, no API key

```bash
git clone <this repo> && cd moonbit-llm-faceoff
moon run --target native scripts/demo.mbtx    # the same as make demo
```

It builds everything, starts a **local fake OpenAI-compatible endpoint**, and walks the three main paths: one-shot, streaming, and a two-model comparison. Entirely offline, and it starts like this:

```
==> 1/3 one-shot
航空母舰是一种以舰载机为主要作战武器的大型水面舰艇。
==> 2/3 streaming (fragments arrive one by one)
侧风掠过甲板，把雨线吹成斜的。
==> 3/3 comparing two models
  runs 1   failures 0   truncated 0   retried 0
```

### 3. Run the web page, also without a key

```bash
make serve          # builds the page, then serves it from web/ → http://127.0.0.1:8137/
make dev            # the same, but watching the sources: a page change rebuilds the page, a server change restarts it
make serve-demo     # mock endpoint + demo data + page: the quickest look at the whole thing
```

Either way, remember one thing: **the server must run with `web/` as its working directory.** It resolves `out/`, `runs/`, `cases/` and `presets.json` relative to it; started from the repository root it answers `/api/meta` and then 404s on every page request. `make serve` does that `cd` for you, and without make it is `moon run --target native scripts/build-web.mbtx`, `moon build web/cmd/server --target native`, then the server binary from inside `web/`. Against a real gateway, either export `MOONLLM_BASE_URL` / `MOONLLM_API_KEY` before starting it, or start it without a key and **type the key into the page**: it is used for that one run, and it is not written to disk.

### 4. Point it at a real endpoint, and run a comparison

Any OpenAI-compatible service works. One block covers the whole loop: a one-shot question, a streamed one, a suite of cases against two models, a report, and the one probe script here that talks to a real endpoint.

```bash
export MOONLLM_BASE_URL="https://api.deepseek.com/v1"   # or any compatible base URL
export MOONLLM_MODEL="deepseek-chat"
export MOONLLM_API_KEY="sk-..."
make deps && MOON_CC=gcc moon build --target native     # build once
faceoff=./_build/native/debug/build/cmd/faceoff/faceoff.exe
bench=./_build/native/debug/build/cmd/bench/bench.exe
$faceoff "用一句话说明什么是航空母舰"                    # one-shot
$faceoff --stream "写一首关于侧风的短诗"                 # streamed, printed as fragments arrive
echo "总结一下这段日志" | $faceoff --stream              # prompt from stdin
mkdir -p my-run && printf '%s\n' '{"id":"math-short","prompt":"计算 17 × 23。只输出数字。"}' > my-run/cases.jsonl
$bench --models <model-a>,<model-b> --cases my-run/cases.jsonl --repeats 3 --max-tokens 2048 \
  --temperature 0.0 --pace-ms 1000 --retry 2 --json my-run/runs.jsonl
moon run --target native scripts/build-web.mbtx my-run/runs.jsonl     # → web/out/report.html
moon run --target native scripts/real-gateway.mbtx                    # → docs/real-gateway-run.md
```

Two things to get right the first time: **send `--json` somewhere of your own** (`bench/results-example.jsonl` is a committed sample, not scratch space), and **read the counters before the latency**. If the gateway rate-limits you, `--pace-ms` spaces the attempts out and `--retry` re-sends 429/5xx with exponential backoff. The key lives in the environment (or in the page's memory for one run); it is never written to a run directory or a commit, see [`SECURITY.md`](SECURITY.md). [`docs/cli.md`](docs/cli.md) has the flags, the environment variables, the suite format, the metrics and the two things in full.

### 5. Where the files land

The server resolves these paths relative to its own working directory, which is `web/`:

| path | what |
| --- | --- |
| `web/cases/default.jsonl` | the generated case set: seeded from `bench/cases.example.jsonl` the first time the server starts with an empty cases directory. Your own sets live here too, gitignored |
| `web/presets.json` | presets: models plus parameters, gitignored |
| `web/runs/` | run history, one directory per run, gitignored |
| `web/data.json` | page data exported from a run, gitignored |
| `web/out/` | built page and static report, produced by `scripts/build-web.mbtx` |

### Known limits

- **`--timeout-ms` does not apply to the streaming path.** A total-duration timeout would cut off legitimately long replies, and an idle timeout would need a timer around each read. The one-shot path does honor it.
- **The web server binds `127.0.0.1` and has no authentication.** It is a local dev tool. Do not expose it.
- **Only the OpenAI-compatible wire format is implemented.** No Anthropic or Gemini translation; the endpoint must accept `/chat/completions`.
- **Targets.** The library and its two CLIs declare `native` only; in `web/`, `cmd/app` is `js`, `cmd/server` and `cmd/ssg` are `native`, and `shared` builds for `js+native+wasm`.
- **Pacing and retry defaults are heuristics.** They were tuned against one gateway's rate limiter. Check your own with `--pace-ms 0` and see what happens.

## Usage index

Four documents carry the detail; this section is the map, so the rest of this page stays a front page.

| document | covers |
| --- | --- |
| [`docs/cli.md`](docs/cli.md) | `faceoff` and `bench`: installing them, every flag, the environment variables, the suite format, the metrics, rate limits and replay, the outputs, the loop end to end, and the probes against a real gateway |
| [`docs/web.md`](docs/web.md) | the page and its server: what every panel does, the URL parameters, the HTTP API, the server environment, the static report, and the `web/` layout |
| [`docs/library.md`](docs/library.md) | using `bench` and the client as MoonBit packages: the import alias, one-shot, streaming, benchmarking, and the error type |
| [`docs/testing.md`](docs/testing.md) | what `make ci` runs, the five suites (85 unit tests plus the end-to-end ones) and what each covers, why four of them are shaped that way, and the two suites CI does not run |

The commands you are most likely to want, with the document that explains them:

| command | what it does | doc |
| --- | --- | --- |
| `make demo` | zero-API-key demo of all three paths | [`docs/cli.md`](docs/cli.md) |
| `make serve` / `make dev` | build the page, then serve it from `web/`; `dev` rebuilds on change | [`docs/web.md`](docs/web.md) |
| `make serve-demo` | mock endpoint + demo data + page | [`docs/web.md`](docs/web.md) |
| `make install` / `make uninstall` | install both CLIs into `~/.moon/bin` / remove them again | [`docs/cli.md`](docs/cli.md) |
| `make ci` / `make e2e` | the deterministic suite CI runs / that plus the browser test | [`docs/testing.md`](docs/testing.md) |
| `make real-gateway` | four probes against a real endpoint; needs a key, not in CI | [`docs/testing.md`](docs/testing.md) |
| `make web` | build the page into `web/out/` and the static report | [`docs/web.md`](docs/web.md) |

## Provenance and dependencies

faceoff is an original project, with no port and no vendored third-party code: the HTTP client, the streaming reader, the statistics, the comparison harness and the page are written here. There is no LLM client dependency either, and [`docs/library-survey.md`](docs/library-survey.md) records the Mooncakes library that was surveyed and tried, the gaps it had, and why it was removed again.

| package | license | used for |
| --- | --- | --- |
| `moonbitlang/async` | Apache-2.0 | HTTP client, streaming reads, the local server behind the page, and the concurrency the harness runs on |
| `moonbit-community/rabbita` | Apache-2.0 | the page app and the static report generator |
| `conglinyizhi/precss` | Apache-2.0 | compiling `web/styles/site.scss` |

The wire format is the OpenAI-compatible `POST /v1/chat/completions`, the one interface every model in a comparison has to speak, and no OpenAI SDK or code is involved. No case set ships with the repository beyond [`bench/cases.example.jsonl`](bench/cases.example.jsonl): prompts belong to whoever wrote them.

MIT. See [`LICENSE`](LICENSE).

## Further reading

Thinking of contributing? These three will get you up to speed:

- [`CONTRIBUTING.md`](CONTRIBUTING.md): getting set up, the house rules (no Python, why the page consumes `bench`'s `data.json`), and what to run before a pull request.
- [`SECURITY.md`](SECURITY.md): how to report a vulnerability, and what happens to your API key.
- [`CHANGELOG.md`](CHANGELOG.md): what changed between versions, including the rename from `llm_client`.

Further reading:

- [`AGENTS.md`](AGENTS.md): the load-bearing constraints that are not visible in the code (the data hand-off between `web/` and the library, why run state lives in files, why `stderr` writes are serialized).
- [`docs/library-survey.md`](docs/library-survey.md): the Mooncakes survey of LLM client libraries, the gaps found while integrating one of them, and why the dependency was eventually removed.
- [`docs/benchmark-notes.md`](docs/benchmark-notes.md): a worked MiniCPM5-1B vs MiniCPM5-2B comparison, including the result that contradicted the obvious reading of the throughput numbers.
- MoonBit: <https://www.moonbitlang.com/> · docs <https://docs.moonbitlang.com/> · packages <https://mooncakes.io/>
