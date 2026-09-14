# CLI: faceoff and bench

`faceoff` asks one prompt, once or streamed; `bench` runs a suite of cases against several models and reports the comparison.

Both talk to any OpenAI-compatible `POST /chat/completions` endpoint, and both can be exercised offline against the mock endpoint in [`scripts/mock_openai.mbtx`](../scripts/mock_openai.mbtx).

## Install

`moon install ./cmd/...` (or `make install`) drops both CLIs into `~/.moon/bin`, which is already on your `PATH` once the toolchain works, so after that it really is plain `faceoff` and `bench`. That directory is the toolchain's own bin: a per-user location under your home, no `sudo`, nothing installed system-wide, and `make uninstall` takes the two binaries back out. The examples below name the build output instead, so they work in a fresh shell without installing anything.

```bash
# the build puts the binaries under _build/; name them once per shell
faceoff=./_build/native/debug/build/cmd/faceoff/faceoff.exe
bench=./_build/native/debug/build/cmd/bench/bench.exe
$faceoff "用一句话说明什么是航空母舰"           # one-shot
$faceoff --stream "写一首关于侧风的短诗"        # streamed, printed as fragments arrive
echo "总结一下这段日志" | $faceoff --stream     # prompt from stdin
```

## faceoff

### Flags

| flag | meaning |
| --- | --- |
| `-s`, `--stream` / `--show-cot` / `-q`, `--quiet` | stream the reply as it is generated / stream the chain of thought too, on stderr so a pipe stays clean / no status lines on stderr |
| `--no-key` / `--` / `-h`, `--help` | allow an empty API key (local endpoints) / treat every following argument as prompt text / print the usage |
| `--timeout-ms <n>` | per-request timeout (default 60000; **one-shot path only**) |
| `--model <id>` / `--base-url <url>` / `--api-key <key>` / `--system <text>` / `--temperature <t>` / `--max-tokens <n>` | override the matching setting: model id, API base URL, bearer token, system prompt, sampling temperature, maximum generated tokens |

### Status lines

On stderr, `faceoff` reports what it is doing: one line before the request and one summary after it, because a one-shot request is otherwise silent until it is finished, which for a reasoning model can look like a hung terminal.

```console
$ faceoff --max-tokens 64 "用一句话说明什么是甲板风。"
-> POST https://api.example.com/v1/chat/completions  model=some-model  max_tokens=64
<- 3.2s  content 41 chars  reasoning 512 chars  tokens 21+64(reasoning 64)  finish_reason=length
```

That summary line is the point: this reply spent the whole budget on thinking and hit the token limit, so there is no answer to print, and an empty reply is now reported as a warning on stderr **and exits non-zero** (`echo $?` gives 1). It used to be a blank line and exit 0, which a pipeline cannot tell apart from a model that said nothing. `--quiet` turns the status lines off (the empty-reply warning still fires: it is a diagnostic, not progress). `--stream --show-cot` prints the chain of thought to stderr as it arrives, which is how you watch a reasoning model think instead of staring at nothing.

### Environment variables

Each setting uses the first non-empty variable in its list. Flags override the environment, and errors go to stderr with a non-zero exit (`$faceoff --api-key wrong "hi"` gives `error: http 401: {"error":{"message":"invalid api key"}}`), so the CLI is safe in a pipeline.

| setting | variables | default |
| --- | --- | --- |
| API key | `MOONLLM_API_KEY`, `OPENAI_API_KEY`, `LLM_API_KEY` | none |
| base URL | `MOONLLM_BASE_URL`, `OPENAI_BASE_URL` | `https://api.openai.com/v1` |
| model | `MOONLLM_MODEL`, `OPENAI_MODEL` | `gpt-4o-mini` |
| system | `MOONLLM_SYSTEM` | `You are a helpful assistant.` |

## bench

`bench` runs the same suite against several models, serially, and reports the comparison. Serial on purpose: two models competing for one connection is not a comparison.

```bash
$bench --base-url https://api.modelbest.cn/v1 --api-key "$MB_KEY" \
  --models MiniCPM5-1B,MiniCPM5-2B --cases bench/cases.example.jsonl \
  --repeats 3 --max-tokens 2048 --temperature 0.0 --pace-ms 3000 --retry 3 --json my-run/runs.jsonl
$bench --model MiniCPM5-1B --prompt "用一句话说明什么是航空母舰" --show-cot   # a single ad-hoc prompt, no suite file
```

### Suite format

JSON Lines, one case per line, or a single JSON array; blank lines and lines starting with `#` are skipped. Only `prompt` is required, and `id`, `system`, `max_tokens` and `temperature` are per-case overrides, with anything absent falling back to the benchmark options (see `bench/cases.example.jsonl`):

```json
{"id": "math-short", "prompt": "计算 17 × 23。只输出数字。", "max_tokens": 512, "temperature": 0.0}
```

### What it measures

Every attempt is a streamed request, so the timings come from real chunk arrival rather than from a total wall time.

| metric | meaning |
| --- | --- |
| `first token` / `first answer` / `total` | until the first fragment of anything (**reasoning included**) / until the first fragment of the visible answer, i.e. after the chain of thought / until the stream ends |
| `decode tok/s` / `end-to-end tok/s` | `completion_tokens` over the window *after* the first token (the closest thing to decode speed a client can observe) / `completion_tokens` over the whole request |
| `reasoning tokens` / `reasoning share` | how much of the budget went into thinking |
| `failures` / `retried` / `truncated` | rate limits, server errors, replies cut off by `max_tokens` |

Reasoning models make the last group matter: a model that is twice as fast per token but emits five times as many thinking tokens can lose on total time. [`docs/benchmark-notes.md`](benchmark-notes.md) has a worked example where exactly that happened. The report gives median / mean / min / max per model plus a side-by-side table, with a ratio column when exactly two models are given.

### Rate limits and replay

A fast model can trip a per-minute request cap. `--pace-ms` spaces attempts out and `--retry` repeats 429/5xx with exponential backoff. The timer restarts on each retry, so a run that backed off still reports the latency of the attempt that produced tokens, and `attempts > 1` in the output records that it happened. `--from-json` skips the model calls entirely and rebuilds the report and page data from a previous run log: `$bench --from-json bench/results-example.jsonl --no-key --web-data web/data.json` (no network, no key), which is useful for re-rendering after changing the report or for re-scoring later without paying for the calls again.

### Outputs

Progress goes to stderr, the report to stdout.

| flag | what |
| --- | --- |
| `--json <file>` / `--web-data <file>` | every raw attempt as JSON Lines, including the full answer and reasoning text / the page-data document the page renders (schema in `bench/pagedata.mbt`) |
| `--show-cot` / `--show-output` | stream chain-of-thought text to stderr as it arrives / print each answer to stderr when the run settles |
| `--progress <file>` | append live progress events (JSON Lines) while running, which is what the page reads to show a run in flight |

```bash
jq -r 'select(.case_id=="code-python") | "\(.model)\t\(.completion_tokens)\t\(.content)"' bench/results-example.jsonl
```

## The whole loop, from zero

A suite is JSON Lines, one case per line, and `prompt` is the only required field (a fuller example is `bench/cases.example.jsonl`). This is the path from a fresh clone to a report, and it is also the one path here that needs a gateway; to check a change without spending anything, use the offline demo (`make demo`).

```bash
make deps && MOON_CC=gcc moon build --target native     # build once
bench=./_build/native/debug/build/cmd/bench/bench.exe
export MOONLLM_BASE_URL="https://<your-gateway>/v1" MOONLLM_API_KEY="sk-..."
mkdir -p my-run && printf '%s\n' '{"id":"math-short","prompt":"计算 17 × 23。只输出数字。"}' > my-run/cases.jsonl
$bench --models <model-a>,<model-b> --cases my-run/cases.jsonl --repeats 3 --max-tokens 2048 \
  --temperature 0.0 --pace-ms 1000 --retry 2 --json my-run/runs.jsonl
moon run --target native scripts/build-web.mbtx my-run/runs.jsonl     # → web/out/report.html
moon run --target native scripts/real-gateway.mbtx                    # → docs/real-gateway-run.md
```

Two things to get right the first time: **send `--json` somewhere of your own** (`bench/results-example.jsonl` is a committed sample of a real run, not scratch space), and **read the counters before the latency**, because `failures`, `retried` and `truncated` head each model's block, and a reply cut off by `--max-tokens` means the budget ran out, so raise it and run again before comparing `tok/s`. The `[truncated]` marker on the progress line and `attempts > 1` in `runs.jsonl` are the same information one layer down.

If the gateway rate-limits you, `--pace-ms` spaces the attempts out and `--retry` re-sends 429/5xx with exponential backoff. The key lives in the environment, and it is never written to a run directory or a commit, see [`SECURITY.md`](../SECURITY.md).

## Probes against a real gateway

`scripts/real-gateway.mbtx` (the last line of the block above, or `make real-gateway`) is the one script here that talks to a real endpoint. It runs four probes and writes down what it saw: whether the endpoint returns a real answer at all, whether fragments really arrive incrementally (first byte vs process exit, the same measurement the offline tests use), whether an auth failure is reported as 4xx with the key kept out of the error, and whether a reply cut off by `--max-tokens` lands in the truncation counter or passes as a success. Each probe gets its own verdict, so a failure tells you which part of the contract the gateway does not honour. The key is read from the environment only, never from the command line, and the script deletes its own output rather than leave a file behind if the key turns up in it. Add `--compare` with `REAL_MODEL_B=<second model>` and it also runs the two-model comparison and keeps `docs/real-gateway-runs.jsonl`: the whole loop, with evidence.

## See also

- [`docs/web.md`](web.md): the page and its server, which is how the same results are read and annotated.
- [`docs/library.md`](library.md): the two CLIs are thin wrappers over the same packages, and those packages are usable on their own.
- [`docs/testing.md`](testing.md): what `make ci` runs, and what each of the five suites covers.
