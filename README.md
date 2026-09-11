# faceoff

**English** · [中文](README.zh.md)

A MoonBit client for OpenAI-compatible chat endpoints, plus a harness for
comparing models on the same prompt suite.

Three things you can run:

| binary | what it does | source |
| --- | --- | --- |
| `faceoff` | ask one prompt, once or streamed | `cmd/faceoff` |
| `bench` | run a suite against several models and compare them | `cmd/bench` |
| `web server` | interactive page: pick models/params, run, watch results | `web/cmd/server` |

Every test in this repo runs offline against a bundled mock — no API key needed
to see it work.

---

## Get it running

You do **not** need to know MoonBit to run this. You need:

- the MoonBit toolchain (step 1)
- a C compiler — `gcc` or `clang`, usually already present

That is the whole list. The demo and the tests need nothing else: the fake
endpoint they run against is itself a MoonBit script
([`scripts/mock_openai.mbtx`](scripts/mock_openai.mbtx)).

### 1. Install MoonBit

**Follow the official instructions — they are authoritative and stay current:**

- English: <https://www.moonbitlang.com/download/>
- 中文: <https://www.moonbitlang.cn/download/>

For convenience, the three official methods are:

| platform | command |
| --- | --- |
| macOS / Linux | `curl -fsSL https://cli.moonbitlang.com/install/unix.sh \| bash` |
| Windows (PowerShell) | `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser; irm https://cli.moonbitlang.com/install/powershell.ps1 \| iex` |
| VS Code | command palette → `MoonBit:install latest moonbit toolchain` |

Then make sure `~/.moon/bin` is on your `PATH` and verify:

```bash
moon version
```

If any of the above fails or has changed, use the official page linked above
rather than this table — this is a copy, that is the source.

### 2. Build it and try it — without any API key

```bash
git clone <this repo> && cd moonbit-llm-faceoff
moon run --target native scripts/demo.mbtx
```

`scripts/demo.mbtx` builds everything, starts a **local fake OpenAI-compatible
endpoint**, and walks the three main paths: one-shot, streaming, and a two-model
comparison. Entirely offline.

```
==> 1/3 one-shot
航空母舰是一种以舰载机为主要作战武器的大型水面舰艇。

==> 2/3 streaming (fragments arrive one by one)
侧风掠过甲板，把雨线吹成斜的。

==> 3/3 comparing two models
model mock-a
  runs 1   failures 0   truncated 0   retried 0
    first token (ms)       1          0 ...
...
```

### 3. Run the web page — also without a key

```bash
make serve          # builds the page, then starts the server from web/
# → http://127.0.0.1:8137/
```

Or by hand, the same two steps:

```bash
moon run --target native scripts/build-web.mbtx
cd web
./_build/native/debug/build/cmd/server/server.exe
```

Either way: **the server must run with `web/` as its working directory.** It
resolves `out/`, `runs/`, `cases/` and `presets.json` relative to it; started
from the repository root it answers `/api/meta` and then 404s on every page
request. `make serve` does that `cd` for you.

Open <http://127.0.0.1:8137/> and work there: pick models and cases, adjust the
parameters, put your API key in (or export it before starting the server), and
press **开始评测**. The progress, the live counters and the exports are all on
that page.

**Start the server from inside `web/`.** It resolves `out/`, `runs/` and
`../bench/cases.example.jsonl` relative to its working directory; started from
the repository root it will answer `/api/meta` and then 404 on the page itself.

Against a real gateway, either export `MOONLLM_BASE_URL` / `MOONLLM_API_KEY`
before starting it, or start it without a key and **type the key into the page** —
it is used for that one run, and it is not written to disk.

### 4. Point it at a real endpoint

Any OpenAI-compatible service works. Copy your provider's base URL and key:

```bash
export MOONLLM_BASE_URL="https://api.deepseek.com/v1"   # or any compatible base URL
export MOONLLM_MODEL="deepseek-chat"
export MOONLLM_API_KEY="sk-..."

client=./_build/native/debug/build/cmd/faceoff/faceoff.exe
$client "用一句话说明什么是航空母舰"
$client --stream "写一首关于侧风的短诗"
```

Next steps: [compare models](#2-comparing-models), or [run the web page](#3-the-web-page).

### 5. Zero to a real comparison

Steps 2–4 stop at one prompt. This is the whole loop — a suite, two real models,
a report — and it is the one path that needs a gateway. Step 2 stays as it is:
the offline demo is still how you check a change without spending anything.

```bash
# 1. build once (the demo in step 2 builds as well)
make deps
MOON_CC=gcc moon build --target native

# 2. point at your gateway — export it, never commit it
#    any OpenAI-compatible service will do
bench=./_build/native/debug/build/cmd/bench/bench.exe
export MOONLLM_BASE_URL="https://<your-gateway>/v1"
export MOONLLM_API_KEY="sk-..."

# 3. write the suite: JSON Lines, one case per line, `prompt` is the only
#    required field (bench/cases.example.jsonl is a fuller example)
mkdir -p my-run
cat > my-run/cases.jsonl <<'JSONL'
{"id": "math-short", "prompt": "计算 17 × 23。只输出数字。", "max_tokens": 512, "temperature": 0.0}
{"id": "fact-zh", "prompt": "用一句话说明什么是航空母舰。"}
JSONL

# 4. compare — the same suite, one model at a time
$bench \
  --models <model-a>,<model-b> \
  --cases my-run/cases.jsonl \
  --repeats 3 --max-tokens 2048 --temperature 0.0 \
  --pace-ms 1000 --retry 2 \
  --json my-run/runs.jsonl

# 5. render it as a self-contained page — no server, no key
moon run --target native scripts/build-web.mbtx my-run/runs.jsonl        # → web/out/report.html

# 6. the same loop again, with assertions and a written record
moon run --target native scripts/real-gateway.mbtx   # → docs/real-gateway-run.md
```

Two things to get right the first time:

- **Send `--json` somewhere of your own.** `bench/results-example.jsonl` is a
  committed sample of a real run, not scratch space.
- **Read the counters before the latency.** `failures`, `retried` and
  `truncated` head each model's block. A reply cut off by `--max-tokens` is not
  a slow model, it is a model that ran out of budget: raise the budget and run
  again before comparing `tok/s`. The `[truncated]` marker on the progress line
  and `attempts > 1` in `runs.jsonl` are the same information one layer down.

If the gateway rate-limits you, `--pace-ms` spaces the attempts out and
`--retry` re-sends 429/5xx with exponential backoff — see
[Rate limits](#rate-limits). The key lives in the environment (or in the page's
memory for one run); it is never written to a run directory or a commit, see
[`SECURITY.md`](SECURITY.md).

`scripts/real-gateway.mbtx` (step 6 above, or `make real-gateway`) is the one
script here that talks to a real endpoint. It runs four probes and writes down
what it saw:

| probe | question it answers |
| --- | --- |
| one-shot | does the endpoint return a real answer at all |
| streaming | do fragments really arrive incrementally — first byte vs process exit, the same measurement the offline tests use |
| bad key | is an auth failure reported as 4xx, and is the key kept out of the error |
| truncation | does a reply cut off by `--max-tokens` land in the truncation counter instead of passing as a success |

Each probe gets its own verdict, so a failure tells you which part of the
contract the gateway does not honour. The key is read from the environment only,
never from the command line, and the script deletes its own output rather than
leave a file behind if the key turns up in it. Add `--compare` with
`REAL_MODEL_B=<second model>` and it also runs the step-4 comparison and keeps
`docs/real-gateway-runs.jsonl` — the whole loop, with evidence.

### New to MoonBit?

A five-line orientation for reading this repo:

| you see | it is |
| --- | --- |
| `moon.mod` | the module manifest — one per repository, like `package.json` or `Cargo.toml` |
| `moon.pkg` | the package manifest — **one directory = one package**, listing that package's imports |
| `*.mbt` | source files; `foo_test.mbt` / `foo_wbtest.mbt` are blackbox / whitebox tests |
| `*.mbtx` | a **single-file script** — `moon run --target native file.mbtx`, no module or package manifest needed. Used here for the test utilities under `scripts/` |
| `_build/` | build output (`_build/native/debug/build/.../main.exe`) |
| `moon build` / `run` / `test` / `check` | build, run, test, type-check |

Everything else in the language — see <https://docs.moonbitlang.com/> and the
package registry <https://mooncakes.io/>.

This repo is two modules: the library + CLIs at the root, and the web frontends
under `web/` (which has its own `moon.mod`). Build the root for the CLIs, or
`cd web` for the page.

### If the build fails

| symptom | fix |
| --- | --- |
| `failed to resolve native archiver executable /usr/bin/lib.exe`, or `new native backend requires a C compiler/linker driver` | a C compiler exists but wasn't picked up. Set it explicitly: `MOON_CC=gcc moon build --target native`. All scripts here already default to `MOON_CC=gcc`. |
| `Cannot find import '...'` | stale registry index: run `moon update` |
| browser tests fail with `cannot open shared object file` | the browser binary is older than the system libraries it links against. Check with `ldd $(command -v chromium)`, or point the tests elsewhere with `CHROME=/path/to/chrome` |

---

## Contents

- [1. One-shot and streaming](#1-one-shot-and-streaming)
- [2. Comparing models](#2-comparing-models)
- [3. The web page](#3-the-web-page)
- [4. Using the library](#4-using-the-library)
- [5. Architecture notes](#5-architecture-notes)
- [6. Testing](#6-testing)
- [7. Known limits](#7-known-limits)
- [8. Layout](#8-layout)
- [9. Further reading](#9-further-reading)
- [10. Contributing](#10-contributing)

---

## 1. One-shot and streaming

`moon install ./cmd/...` (or `make install`) drops both CLIs into `~/.moon/bin`,
which is already on your `PATH` once the toolchain works — after that it really is
plain `faceoff` and `bench`. That directory is the toolchain's own bin directory:
a per-user location under your home, no `sudo`, nothing installed system-wide,
and `make uninstall` takes the two binaries back out. The examples below name the
build output instead, so they work in a fresh shell without installing anything.

```bash
# the build puts the binaries under _build/; name them once per shell
faceoff=./_build/native/debug/build/cmd/faceoff/faceoff.exe
bench=./_build/native/debug/build/cmd/bench/bench.exe

# one-shot
$faceoff "用一句话说明什么是航空母舰"

# streamed, printed as fragments arrive
$faceoff --stream "写一首关于侧风的短诗"

# prompt from stdin
echo "总结一下这段日志" | $faceoff --stream
```

### Flags

| flag | meaning |
| --- | --- |
| `-s`, `--stream` | stream the reply as it is generated |
| `--show-cot` | stream the chain of thought too — on stderr, so a pipe stays clean |
| `-q`, `--quiet` | no status lines on stderr |
| `--model <id>` | model id |
| `--base-url <url>` | API base URL |
| `--api-key <key>` | bearer token |
| `--system <text>` | system prompt |
| `--temperature <t>` | sampling temperature |
| `--max-tokens <n>` | maximum generated tokens |
| `--timeout-ms <n>` | per-request timeout (default 60000; **one-shot path only**) |
| `--no-key` | allow an empty API key (local endpoints) |
| `--` | treat every following argument as prompt text |
| `-h`, `--help` | print the usage above |

On stderr, `faceoff` reports what it is doing: one line before the request and one
summary after it, because a one-shot request is otherwise silent until it is
finished — which for a reasoning model can look like a hung terminal.

```console
$ faceoff --max-tokens 64 "用一句话说明什么是甲板风。"
-> POST https://api.example.com/v1/chat/completions  model=some-model  max_tokens=64
<- 3.2s  content 41 chars  reasoning 512 chars  tokens 21+64(reasoning 64)  finish_reason=length
```

That last line is the point: this reply hit the token budget with the budget
spent on thinking, so there is no answer to print. An empty reply is reported as
a warning on stderr **and exits non-zero** — it used to be a blank line and exit
0, which a pipeline cannot tell apart from a model that said nothing.

```console
$ faceoff --max-tokens 64 "..." >answer.txt
$ echo $?
1
```

`--quiet` turns the status lines off (the empty-reply warning still fires: it is
a diagnostic, not progress). `--stream --show-cot` prints the chain of thought to
stderr as it arrives, which is how you watch a reasoning model think instead of
staring at nothing.

### Environment variables

Each setting uses the first non-empty variable in its list.

| setting | variables | default |
| --- | --- | --- |
| API key | `MOONLLM_API_KEY`, `OPENAI_API_KEY`, `LLM_API_KEY` | — |
| base URL | `MOONLLM_BASE_URL`, `OPENAI_BASE_URL` | `https://api.openai.com/v1` |
| model | `MOONLLM_MODEL`, `OPENAI_MODEL` | `gpt-4o-mini` |
| system | `MOONLLM_SYSTEM` | `You are a helpful assistant.` |

Flags override the environment. Errors go to stderr and exit non-zero, so the
CLI is safe to use in a pipeline:

```
$ $faceoff --api-key wrong "hi"
error: http 401: {"error":{"message":"invalid api key"}}
```

---

## 2. Comparing models

`bench` runs the same suite against several models, serially, and reports the
comparison. Serial on purpose: two models competing for one connection is not a
comparison.

```bash
$bench \
  --base-url https://api.modelbest.cn/v1 --api-key "$MB_KEY" \
  --models MiniCPM5-1B,MiniCPM5-2B \
  --cases bench/cases.example.jsonl \
  --repeats 3 --max-tokens 2048 --temperature 0.0 \
  --pace-ms 3000 --retry 3 \
  --json my-run/runs.jsonl
```

A single ad-hoc prompt works without a suite file:

```bash
$bench --model MiniCPM5-1B --prompt "用一句话说明什么是航空母舰" --show-cot
```

### Suite format

JSON Lines, one case per line — or a single JSON array. Blank lines and lines
starting with `#` are skipped. Only `prompt` is required.

```json
{"id": "math-short", "prompt": "计算 17 × 23。只输出数字。", "max_tokens": 512, "temperature": 0.0}
```

`id`, `system`, `max_tokens` and `temperature` are per-case overrides; anything
absent falls back to the benchmark options. See `bench/cases.example.jsonl`.

### What it measures

Every attempt is a streamed request, so the timings come from real chunk
arrival rather than from a total wall time.

| metric | meaning |
| --- | --- |
| `first token` | until the first fragment of anything, reasoning included |
| `first answer` | until the first fragment of the visible answer, i.e. after the chain of thought |
| `total` | until the stream ends |
| `decode tok/s` | `completion_tokens` over the window *after* the first token — the closest thing to decode speed a client can observe |
| `end-to-end tok/s` | `completion_tokens` over the whole request |
| `reasoning tokens` / `reasoning share` | how much of the budget went into thinking |
| `failures` / `retried` / `truncated` | rate limits, server errors, replies cut off by `max_tokens` |

Reasoning models make the last group matter: a model that is twice as fast per
token but emits five times as many thinking tokens can lose on total time. See
[`docs/benchmark-notes.md`](docs/benchmark-notes.md) for a worked example where
exactly that happened.

The report gives median / mean / min / max per model plus a side-by-side table,
with a ratio column when exactly two models are given.

### Rate limits

A fast model can trip a per-minute request cap. `--pace-ms` spaces attempts
out; `--retry` repeats 429/5xx with exponential backoff. The timer restarts on
each retry, so a run that backed off still reports the latency of the attempt
that produced tokens, and `attempts > 1` in the output records that it happened.

### Replaying a run

`--from-json` skips the model calls entirely and rebuilds the report and page
data from a previous run log:

```bash
# no network, no API key needed
$bench --from-json bench/results-example.jsonl --no-key --web-data web/data.json
```

Useful for re-rendering after changing the report, or for re-scoring later
without paying for the calls again.

### Outputs

| flag | what |
| --- | --- |
| `--json <file>` | every raw attempt as JSON Lines, including the full answer and reasoning text |
| `--web-data <file>` | the page-data document the web module renders (schema in `bench/pagedata.mbt`) |
| `--show-cot` | stream chain-of-thought text to stderr as it arrives |
| `--show-output` | print each answer to stderr when the run settles |

Progress goes to stderr, the report to stdout.

```bash
jq -r 'select(.case_id=="code-python") | "\(.model)\t\(.completion_tokens)\t\(.content)"' \
  bench/results-example.jsonl
```

---

## 3. The web page

```bash
moon run --target native scripts/build-web.mbtx   # from the repository root

cd web                     # the server resolves out/, runs/ and the case file
                           # relative to its working directory — run it here,
                           # not from the repository root
MOONLLM_API_KEY=... \
MOONLLM_BASE_URL=https://api.modelbest.cn/v1 \
LLM_WEB_MODELS=MiniCPM5-1B,MiniCPM5-2B \
  ./_build/native/debug/build/cmd/server/server.exe
# → http://127.0.0.1:8137/
```

From the page you can:

- pick models from the server's menu **or type model ids directly**, set repeats /
  `max_tokens` / temperature / pacing / retries, type a one-off prompt, and start
  a run;
- override the **gateway address and API key** for that one run, so a local
  `ollama` or a second provider does not need a server restart. Both fields are
  optional and fall back to the server's environment;
- watch progress, the live failure/retry/truncation counts, and a collapsible
  tail of the run's `stderr`;
- **go back to any earlier run**: the left column lists every run with its time,
  models, scale and counters. Open one to read its results (read-only, exports
  follow it), rerun it with exactly the parameters it ran with, or delete it;
- **keep your suites in the page**: the case panel switches between case sets
  (`web/cases/<name>.jsonl`), ticks the cases to run, and edits them in place —
  prompt, id, and per-case `system` / `max_tokens` / `temperature` under a folded
  "more fields". Saving writes the file and does not touch fields it never showed;
- **save a model + parameter combination as a preset** and apply it with one
  click, so "the usual two models, three repeats, 2048 tokens" stops being four
  form fields you retype;
- **compare two runs**: tick two entries in the history and the main area becomes a
  comparison — what parameters actually differ (so "I changed one thing" is
  visible rather than remembered), the median of every metric side by side with a
  Δ column, and the two runs' answers for the same case next to each other, chain
  of thought included. The Δ column is deliberately not coloured: the same
  direction is good for throughput and bad for latency, and this layer has no
  per-metric polarity to colour by;
- compare the answers case by case — every answer carries its model's chain of
  thought underneath, folded into a `<details>` (`思考过程 · N token · M 字`).
  Comparing two reasoning models means comparing that text, and a token count
  cannot stand in for it;
- export the result — copy the report as Markdown, copy a shareable URL, or
  download `runs.jsonl`, `data.json`, or a self-contained `report.html`.

A key typed into the page stays in the tab's memory, is passed to the child
process through the environment rather than its command line, and is stripped
out of the run's `request.json` before it is written. A key the *server* holds is
never handed to the browser. Either way, if an upstream error echoes the key
back the body is masked before it reaches the page or the disk — see
[`SECURITY.md`](SECURITY.md).

### The URL is the configuration

Query parameters override the defaults, so a link can carry a whole comparison —
handy for bookmarking a setup or sending it to someone:

```
http://127.0.0.1:8137/?models=mock-a,mock-b&cases=math-short,fact-zh&repeats=3
```

Supported: `models`, `cases`, `prompt`, `repeats`, `maxTokens`, `temperature`,
`paceMs`, `retry`, `baseUrl`. There is deliberately no `apiKey` parameter — a key
does not belong in a URL.

`autorun=1` starts the run as soon as the page loads. It will not fire when no
API key is available anywhere, because the run could only fail: the page says so
and waits for you to fill the key in and press **开始评测**.

### API

| endpoint | purpose |
| --- | --- |
| `GET /api/meta` | `{models, caseSets, defaultCaseSet, cases, defaults, hasKey, baseUrl}`. `cases` is the default set's list, kept because the URL-config path reads it |
| `GET /api/runs` | the run history, newest first: `{runs: [{id, startedAt, status, exitCode, request, total, done, failures, retried, truncated}]}` |
| `POST /api/runs` | start a run → `{id, total}`. Three mutually exclusive ways to say what to run: `caseSet` + `cases` (ids from a set on disk), a single `prompt`, or `inlineCases` (an array of case objects, written into that run's `cases.jsonl`). `system` sets the system prompt for the whole run; a case may override it with its own |
| `GET /api/runs/<id>` | `{status, done, total, exitCode?, tail, failures, retried, truncated, data?, error?}` |
| `DELETE /api/runs/<id>` | remove that run's directory |
| `GET /api/runs/<id>/runs.jsonl` | the raw per-attempt log, as a download |
| `GET /api/runs/<id>/data.json` | the page-data document, as a download |
| `GET /api/runs/<id>/report.html` | a self-contained static report, generated on first request |
| `GET /api/cases` | `{sets: [{name, count}]}` |
| `GET /api/cases/<name>` | `{name, cases: [...]}` — the raw case records, all fields |
| `PUT /api/cases/<name>` | whole-set write (`{cases: [...]}`); an unknown name creates the set |
| `DELETE /api/cases/<name>` | remove a set |
| `GET /api/presets` | `{presets: [...]}` |
| `PUT /api/presets` | whole-list write (`{presets: [...]}`) |

A **case set** is one `<name>.jsonl` under `LLM_WEB_CASES_DIR`; names are
`[A-Za-z0-9._-]` and nothing else, because the name is a path segment. A
**preset** is a name plus a model list and the run parameters, so a combination
you keep going back to is one click instead of a retyped form. Both live in
files the server reads and writes directly — `web/cases/` and
`web/presets.json`, both gitignored, because they are your data and prompts can
be private. `LLM_WEB_CASES` is only a seed: the first time the server starts
with an empty case-set directory it copies that file to `cases/default.jsonl`.

`data` is the same document the static report consumes. A run is a
**subprocess** (`bench --json … --web-data …`), and its whole state lives in
files under `web/runs/<id>/`:

```
web/runs/<id>/
  request.json     what was asked for
  cases.jsonl      the filtered suite (when cases were selected)
  runs.jsonl       bench's raw output, grows as it runs — progress is its line count
  stdout.log       bench's stdout (the rendered report)
  stderr.log       bench's progress log
  exit_code        written when the bench process is reaped; its presence means "finished"
  data.json        the final page-data document
```

### Server environment

| variable | default |
| --- | --- |
| `LLM_WEB_PORT` | `8137` |
| `LLM_WEB_STATIC` | `out` |
| `LLM_WEB_WORK` | `runs` |
| `LLM_WEB_CASES_DIR` | `cases` — one `<name>.jsonl` per case set |
| `LLM_WEB_CASES` | `../bench/cases.example.jsonl` — only a seed for `cases/default.jsonl` |
| `LLM_WEB_PRESETS` | `presets.json` |
| `LLM_WEB_MODELS` | `MiniCPM5-1B,MiniCPM5-2B` — the default menu; a run may name any model |
| `LLM_BENCH_BIN` | `../_build/native/debug/build/cmd/bench/bench.exe` |
| `LLM_WEB_SSG` | `_build/native/debug/build/cmd/ssg/ssg.exe` |
| `MOONLLM_API_KEY` / `OPENAI_API_KEY` | — |
| `MOONLLM_BASE_URL` / `OPENAI_BASE_URL` | `https://api.openai.com/v1` |

### Static report

`web/cmd/ssg` renders the same result components into a self-contained page —
no JavaScript, no server, chain of thought included:

```bash
moon run --target native scripts/build-web.mbtx path/to/other-runs.jsonl   # → web/out/report.html
```

### Styling

`web/styles/site.scss` is compiled by [`conglinyizhi/precss`](https://mooncakes.io/docs/conglinyizhi/precss)
at build time. It uses variables, nesting, `&`, `@mixin`/`@include` and
`@media`; the compiled `out/site.css` has all of it resolved, with no leftover
`$`, `@mixin` or `@include`. No CSS framework is involved.

---

## 4. Using the library

The `bench` package is usable on its own; so is the client.

Declare it with an explicit alias in your own `moon.pkg` — the module path ends
in `faceoff`, and a hyphenated segment can't serve as a default alias:

```text
import {
  "conglinyizhi/moonbit-llm-faceoff" @faceoff,
}
```

```moonbit
// one-shot
let settings = @faceoff.Settings::from_env(env)
let reply = @faceoff.ask(settings, "用一句话说明什么是航空母舰")

// the same request, keeping what the reply says about itself: an empty answer
// is not a bug report, and the stop reason and token counts explain it
let outcome = @faceoff.ask_outcome(settings, prompt)
// outcome.content, outcome.reasoning, outcome.usage, outcome.finish_reason

// streaming, with reasoning fragments separated from the answer
let outcome = @faceoff.stream_parts(settings, prompt, async fn(part) {
  match part {
    Content(text) => handle_answer(text)
    Reasoning(thought) => handle_thought(thought)
  }
})
// outcome.content, outcome.reasoning, outcome.usage, outcome.finish_reason
```

```moonbit
// benchmarking
let cases = @bench.parse_cases(text)
let results = @bench.run_bench(settings, models, cases, options, on_start, on_part, on_result)
let summaries = @bench.summarize_all(models, results)
println(@bench.format_summaries(summaries))
```

`@bench.parse_results` reads a run log back, `RunResult::to_json` /
`RunResult::from_json` round-trip a single attempt, and `page_data_json` builds
the document the web module renders.

Errors are flattened into `ClientError` (`Transport` / `Status` / `Decode`) so
callers do not need to import the transport packages.

---

## 5. Architecture notes

Three decisions that are not obvious from the code.

**Both paths talk to the endpoint directly.**
There is no client library in between: the request body is built as `Json`
(`request_body`) and the reply is read back out of `Json` (`response_text`), so
the wire format — not some library's types — is what this module exposes.
Streaming frames SSE itself, and `parse_sse_line` is a pure function so the
framing logic stays unit-testable. The package's only dependency is
`moonbitlang/async`.

Delegating the stream to a library was tried and dropped: that entry point took
a *synchronous* callback, and a synchronous callback cannot call
`@stdio.stdout.write`, so fragments could not be written out as they arrived.
The dependency was then removed outright rather than kept for the one-shot path.

**`web/` is a separate module that does not depend on the library.**
`rabbita` needs `moonbitlang/async` 0.21.x while the library pins 0.20.1. Putting
both in one workspace forces a single async version, and that breaks the
library. So the numbers are computed once, in `bench`, and handed over as JSON —
across a process boundary for live runs, and as a file for the static report.

That pin no longer has an external cause. With no client library left, the
library could move to 0.21.x, the two modules could share a workspace, and the
subprocess boundary and the JSON hand-off would become unnecessary. That is a
separate change and has not been made.

**Run state lives in files, not in server memory.**
The server keeps no per-run state in memory: the bench process is spawned directly
(no shell, so nothing POSIX-specific and nothing to quote), and a task attached to
the server's own lifetime waits for it to be reaped and writes its exit code to a
file. That file's presence is the completion signal, and counting lines in
`runs.jsonl` gives progress. Run ids are handed out by *creating* the directory —
`mkdir` fails when the directory already exists, and that failure is the
test-and-set — so two simultaneous requests cannot pick the same id. The one lock
in the server is a semaphore serializing `stderr` writes, because
`@stdio.stderr` is a single global handle and concurrent writes to it abort the
process.

---

## 6. Testing

`make ci` is the definition of passing: it is what the GitHub workflow runs,
and it is the same single command you can run locally. The targets are thin
wrappers over the scripts, so the two cannot drift.

```bash
make ci        # deps, check, unit tests, smoke, server API, build the page
make e2e       # the browser test as well — needs chromium, and it is slow
make           # list every target
```

Underneath:

```bash
moon test --target native      # 58 unit tests, no network (54 + 4 in web/)
moon run --target native scripts/smoke.mbtx   # CLI end-to-end against a local mock endpoint
moon run --target native scripts/server-api.mbtx   # server HTTP contract, incl. key handling
bash scripts/web-e2e.sh        # browser end-to-end (headless chromium)
```

| suite | covers |
| --- | --- |
| `moon test` | settings resolution and precedence, flag parsing and error cases, request JSON shape, response decoding (one-shot outcome: content / reasoning / usage / stop reason), SSE framing (content / reasoning / usage / finish / `[DONE]` / CRLF / malformed), case-file parsing, statistics, throughput derivation, run round-trip, page-data contract, key masking in an upstream error body |
| `scripts/smoke.mbtx` | one-shot via env and via flags, streaming, stdin prompts, **incremental delivery**, non-ASCII error-body decoding, auth failures, that a failing auth does not echo the key, **status lines on stderr with stdout left alone**, `--quiet`, `--show-cot`, **an empty reply warned about and non-zero instead of a blank line**, and the bench harness against the same mock: **a 429 that clears is retried for real** (`attempts: 2`), `--retry n` means n extra HTTP attempts, and a `finish_reason: length` reply lands in the truncation counter instead of passing as a success |
| `scripts/server-api.mbtx` | a run whose `baseUrl`/`apiKey` come from the request body while the server's own are deliberately broken, model ids outside the menu, the live counters, all three exports, **that the key never lands in the run directory or the response**, and that path traversal is refused |
| `scripts/web-e2e.sh` | a real headless browser: the form renders from `/api/meta` (including the model / gateway / key inputs), an `?autorun` link actually completes a run and renders its results (including the chain of thought folded under every answer), **the run-history rail lists that run and opening it switches to the read-only view**, **editing a case in the page reaches the file on disk and a preset saved in the page shows up in the list**, **ticking two runs opens the comparison (parameter diff, metric deltas, per-case answers)**, **deleting a run drops it from the list**, eight parallel `POST /api/runs` come back with eight distinct ids, the start button is usable again once the run finishes, and the export row yields a Markdown report and a share link that carries no key |
| `scripts/real-gateway.mbtx` | **the one suite that is not offline and not in CI.** Four probes against a real endpoint: one-shot, incremental streaming, a bad key reported as 4xx without echoing it, and a reply cut off by `--max-tokens` counted as truncated. Writes `docs/real-gateway-run.md`. Needs `MOONLLM_BASE_URL` / `MOONLLM_API_KEY` exported |

Four of these exist because the obvious version would pass on a broken
implementation:

- **Incremental delivery.** The mock sleeps between fragments, and the test
  measures *when the first byte arrived relative to process exit*. Comparing
  final output alone cannot tell a streaming client from a buffering one.
- **Non-ASCII error bodies.** The mock sends a Chinese 429 body; the test
  asserts it decodes. Reinterpreting the bytes as UTF-16 instead of decoding
  UTF-8 is a mistake that produces mojibake only on non-ASCII payloads.
- **Concurrent run creation.** Eight parallel `POST /api/runs` must come back
  with eight distinct ids. A single-request test passes even while the id
  allocation is a read-modify-write counter — it only breaks when two requests
  arrive together, which is exactly what a hand-run test never does.
- **Retry and truncation counters.** The mock can turn a 429 off after the
  first request (`RATE_LIMIT_ONCE`), which is the only shape in which a
  *successful* retry is observable: the test asserts `attempts: 2` and
  `retried: 1` in the same run. A client that never actually retried fails
  outright instead. And a reply whose `finish_reason` is `length` has to land
  in the truncation counter — counting it as a plain success would quietly
  average a cut-off answer into the speed numbers.

`scripts/web-e2e.sh` drives Chromium over the DevTools protocol and waits in
real time. It deliberately does **not** use `--virtual-time-budget`: virtual
time races the page's own `fetch`, and dumps a half-loaded page. Set
`CHROME=/path/to/chrome` to use another browser binary.

It is also the one browser suite CI does **not** run. Driving a real browser and
waiting in real time makes it the flakiest thing here, and a timing hiccup
failing unrelated pull requests is worse than the coverage is worth. Run it with
`make e2e` before touching the page.

The other thing CI does not run is `scripts/real-gateway.sh`, for a different
reason: it needs a key and it costs money. Run it by hand when you want evidence
that the client works against a real endpoint, and commit what it writes.

---

## 7. Known limits

- **`--timeout-ms` does not apply to the streaming path.** A total-duration
  timeout would cut off legitimately long replies, and an idle timeout would
  need a timer around each read. The one-shot path does honor it.
- **The web server binds `127.0.0.1` and has no authentication.** It is a local
  dev tool. Do not expose it.
- **Only the OpenAI-compatible wire format is implemented.** No Anthropic or
  Gemini translation; the endpoint must accept `/chat/completions`.
- **Targets.** The library and its two CLIs declare `native` only; in `web/`,
  `cmd/app` is `js`, `cmd/server` and `cmd/ssg` are `native`, and `shared`
  builds for `js+native+wasm`.
- **Pacing and retry defaults are heuristics.** They were tuned against one
  gateway's rate limiter. Check your own with `--pace-ms 0` and see what
  happens.

---

## 8. Layout

```text
moon.pkg            library package imports (native only)
faceoff.mbt         package documentation
settings.mbt        Settings + ConfigError, environment resolution
cli.mbt             Cli::parse, usage text
api.mbt             request building, response/SSE decoding
runner.mbt          ask / stream_chat / stream_parts / stream_to_stdout
*_test.mbt          blackbox unit tests
*_wbtest.mbt        whitebox unit tests (internal helpers)

bench/              the measurement harness
  bench.mbt         entry point
  case.mbt          suite parsing
  runner.mbt        run_case / run_bench, retry, JSON round-trip
  metrics.mbt       Stats, summarize
  report.mbt        the human-readable report
  pagedata.mbt      the document the web module consumes
  cli.mbt           bench flag parsing

cmd/faceoff/        the faceoff executable
cmd/bench/          the bench executable

web/                the frontends (own module: Rabbita + precss)
  shared/           data model + result components (js + native)
  cmd/app/          interactive page (js, Rabbita TEA)
    main.mbt        the form, the run in progress, the results
    history.mbt     the run-history rail
    manage.mbt      case sets and presets
    compare.mbt     two runs side by side
  cmd/server/       static + API server (native)
    main.mbt        routing and handlers
    store.mbt       case sets, presets, run history — files and JSON
  cmd/ssg/          static report (native)
  styles/           site.scss → precss → site.css

web/cases/          your case sets (one <name>.jsonl each) — gitignored
web/presets.json    your model + parameter combinations — gitignored
web/runs/           one directory per run — gitignored
  shell/            index.html shell for the interactive page
  build-web.mbtx    one-command build (run from the repository root)

scripts/
  demo.mbtx             offline, no-API-key demo of all three paths
  mock_openai.mbtx      offline OpenAI-compatible endpoint, as a MoonBit script
  check_incremental.mbtx  measures that --stream really streams
  smoke.mbtx            CLI end-to-end
  web-e2e.sh            browser end-to-end
  cdp-dump.mjs          drives headless chromium over the DevTools protocol
  lib.sh                helpers shared by the scripts above
  cdp-dump.mjs          DevTools-protocol DOM dump helper

docs/               library survey, benchmark notes
```

---

## 9. Further reading

- [`docs/library-survey.md`](docs/library-survey.md) — the Mooncakes survey of
  LLM client libraries, the gaps found while integrating one of them, and why
  the dependency was eventually removed.
- [`docs/benchmark-notes.md`](docs/benchmark-notes.md) — a worked
  MiniCPM5-1B vs MiniCPM5-2B comparison, including the result that
  contradicted the obvious reading of the throughput numbers.
- MoonBit: <https://www.moonbitlang.com/> ·
  docs <https://docs.moonbitlang.com/> ·
  packages <https://mooncakes.io/>

## 10. Contributing

- [`CONTRIBUTING.md`](CONTRIBUTING.md) — build requirements, the house rules
  (no Python, why there are two modules), and what to run before a pull request.
- [`SECURITY.md`](SECURITY.md) — how to report a vulnerability, and what happens
  to your API key.
- [`CHANGELOG.md`](CHANGELOG.md) — what changed between versions, including the
  rename from `llm_client`.

## License

MIT. See [`LICENSE`](LICENSE).
