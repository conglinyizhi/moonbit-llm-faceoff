# The web page and its server

The page runs a case set against several OpenAI-compatible models, shows the answers side by side, and lets you annotate them and compare two runs. Its server is a local process; the static report generator renders the same results into a self-contained page.

## Build and run

```bash
moon run --target native scripts/build-web.mbtx    # the page into web/out/
moon build web/cmd/server --target native          # the server binary
cd web            # the server resolves out/, runs/ and the case file relative to its working directory, so run it here
MOONLLM_API_KEY=... MOONLLM_BASE_URL=https://api.modelbest.cn/v1 LLM_WEB_MODELS=MiniCPM5-1B,MiniCPM5-2B \
  ../_build/native/debug/build/web/cmd/server/server.exe   # → http://127.0.0.1:8137/
```

`make serve` does the build and that `cd` for you, `make dev` does the same while watching the sources (a page change rebuilds the page, a server change restarts it), and `make serve-demo` starts a mock endpoint plus demo data plus the page for a quick look. Started from the repository root instead, the server answers `/api/meta` and then 404s every page request, because `out/`, `runs/`, `cases/` and `presets.json` are all resolved relative to its working directory.

## What the page does

From the page you can:

- pick models from the server's menu **or type model ids directly**; set repeats / `max_tokens` / temperature / pacing / retries, type a one-off prompt, and start a run;
- set the **gateway address and API key** for that one run (they sit at the top of the form, above the model picker), so a local `ollama` or a second provider does not need a server restart; both fields are optional and fall back to the server's environment;
- write one **system prompt** for the run and let the cases be nothing but user prompts, with the fixed half and the varying half in separate places. A case that carries its own `system` overrides it, and 请求上下文 marks which ones did;
- choose what to run in one panel with two tabs: a **test set** (tick the cases) or a single **临时 First User Prompt**. Typing anything into the prompt box is what selects it, there is no checkbox to forget, and both tabs say the consequence out loud: "I filled in a prompt, so this run is that one question and the test set sits out";
- **keep your suites in the page**: the case panel switches between case sets (`web/cases/<name>.jsonl`), ticks the cases to run, and edits them in place, meaning prompt, id, and per-case `system` / `max_tokens` / `temperature` under a folded "more fields". Saving writes the file and does not touch fields it never showed. Its import box takes pasted text a line at a time, with blank lines and `#` skipped, and 追加导入 / 替换为这些行 decide whether the new lines follow the old ones or replace them; a whole set can also be **created from a plain text file** (a `.jsonl` case set works too), with the server reading the path you give it, since it is running on your machine anyway;
- use **presets**, which live in the sidebar next to the run history: a preset covers models, test set, system prompt, gateway and the parameters, and turns a combination you keep going back to (the usual two models, three repeats, 2048 tokens) into one click instead of a retyped form;
- watch progress, the live failure/retry/truncation counts, and a collapsible tail of the run's `stderr`. **Go back to any earlier run** from the left column, which lists every run with its time, models, scale and counters: open one to read its results (read-only, exports follow it), rerun it with exactly the parameters it ran with, or delete it;
- **compare two runs**: tick two entries in the history and the main area becomes a comparison, including what parameters actually differ (so "I changed one thing" is visible rather than remembered), the median of every metric side by side with a Δ column, and the two runs' answers for the same case next to each other, chain of thought included. The Δ column is deliberately not coloured: the same direction is good for throughput and bad for latency, and this layer has no per-metric polarity to colour by;
- compare the answers case by case, where every answer carries its model's chain of thought underneath, folded into a `<details>` (`思考过程 · N token · M 字`); comparing two reasoning models means comparing that text, and a token count cannot stand in for it. **Two long answers** also read side by side: the results section switches between one block per model, columns (one per model, equal width, each with its own scrollbar and a pinned header), and a diff that aligns lines, collapses the identical stretches, and pairs a line that only changed a little, highlighting the few characters that actually differ, which for Chinese prose is usually one comma;
- **judge an answer by hand**: ✅ 通过 / ❌ 不行 / 🤔 拿不准 plus a note saying what was wrong. The verdict is saved the moment you click it and the note when you press 存备注, and both live in that run's directory, so they show up in the Markdown copy and the static report too, while deleting a run takes its verdicts with it. A run that was judged keeps a small badge on its cell (`🤔 拿不准`);
- **see what was actually asked**: every case has a 请求上下文 button that opens the request as the model receives it, the parameters first and then the `system` and `user` messages that were in effect for that case. A `system` written into the case set overrides the global one, and when that happens the dialog says so; "why did it answer that" is usually answered here. The endpoint returns the scrubbed request document, so no key is ever in it;
- **read a distribution, not a single number**: the model cards put P50 next to P10 / P20 / P99 for every metric, and the comparison table has a percentile switch (P10 / P20 / P50 / P99). They answer different questions (P50 is "how fast is it usually", P99 is "does it occasionally hang", P10 is "how fast when things go well"), and a median alone answers only the first. Percentiles interpolate between order statistics, the same rule numpy and R's default use; with few samples the tails sit near the extremes, and the `n` beside them is what says whether to believe it;
- **watch a run while it happens**: the progress card carries a bar over the whole suite plus a live line, which is the model, which case, whether it is still waiting for the first token, how many characters have arrived, and the rate over the last fraction of a second (`≈ 61 tok/s`). It is derived from the arrival times of the stream fragments, so it moves at the speed of the model rather than at the speed of the suite, and two seconds without a fragment stops the pulse and says how long it has been quiet;
- **come back to a run at any address**: the run you are looking at is in the URL fragment (`#run=<id>`), so a refresh or a link sent to someone else lands on the same run. A run still in progress shows up in the sidebar with a 看进度 button, which is the only way back if you opened something else while it ran; deleting a run asks twice, and an id that does not exist says so instead of showing an empty page;
- export the result: copy the report as Markdown, copy a shareable URL, or download `runs.jsonl`, `data.json`, or a self-contained `report.html`.

Those runs go through the same `POST /api/runs` as the workbench (with `inlineCases` + `system`), so they land in the history and can be rerun. 存成测试集 writes the current system + prompts into `web/cases/`, which is how a prompt that turned out to be interesting becomes a repeatable test.

A key typed into the page stays in the tab's memory, is passed to the child process through the environment rather than its command line, and is stripped out of the run's `request.json` before it is written. A key the *server* holds is never handed to the browser. Either way, if an upstream error echoes the key back, the body is masked before it reaches the page or the disk, see [`SECURITY.md`](../SECURITY.md).

## The URL is the configuration

Query parameters override the defaults, so a link can carry a whole comparison, which is handy for bookmarking a setup or sending it to someone:

```
http://127.0.0.1:8137/?models=mock-a,mock-b&cases=math-short,fact-zh&repeats=3
```

Supported: `models`, `cases`, `prompt`, `repeats`, `maxTokens`, `temperature`, `paceMs`, `retry`, `baseUrl`. There is deliberately no `apiKey` parameter, because a key does not belong in a URL. `autorun=1` starts the run as soon as the page loads, and it will not fire when no API key is available anywhere, since the run could only fail: the page says so and waits for you to fill the key in and press **开始评测**.

## API

| endpoint | purpose |
| --- | --- |
| `GET /api/meta` | `{models, caseSets, defaultCaseSet, cases, defaults, hasKey, baseUrl}`. `cases` is the default set's list, kept because the URL-config path reads it |
| `GET /api/runs` · `POST /api/runs` · `GET`/`DELETE /api/runs/<id>` | the run history, newest first (fields `id, startedAt, status, exitCode, request, total, done, failures, retried, truncated`) / start a run → `{id, total}`, with three mutually exclusive ways to say what to run: `caseSet` + `cases`, a single `prompt`, or `inlineCases` (an array of case objects, written into that run's `cases.jsonl`), while `system` sets the system prompt for the whole run and a case may override it / one run's status `{status, done, total, exitCode?, tail, failures, retried, truncated, data?, error?}` / remove that run's directory (its annotations go with it) |
| `GET /api/runs/<id>/context` | what the run actually sent: the request document plus each case's effective `system` / `maxTokens` / `temperature` (`systemOverridden` marks a case-set prompt that beat the global one) |
| `GET` · `PUT /api/runs/<id>/annotations` | the human verdicts `{id, annotations: [{case_id, model, verdict, note}]}`, `verdict` being `pass` / `fail` / `unsure`; the PUT writes the whole list, one entry per answer, and duplicates are a 400 |
| `GET /api/runs/<id>/runs.jsonl` · `/data.json` · `/report.html` | the raw per-attempt log; the page-data document; a self-contained static report (generated on first request). All three download directly |
| `GET /api/cases` · `GET`/`PUT`/`DELETE /api/cases/<name>` · `POST /api/cases/<name>/import` | `{sets: [{name, count}]}`; the raw case records with all fields / whole-set write (`{cases: [...]}`, and an unknown name creates the set) / remove a set; create a set from a text file with `{"path": "..."}`, one prompt per line (a `.jsonl` case set is accepted as-is) |
| `GET` · `PUT /api/presets` | `{presets: [...]}` / whole-list write; a preset is a name plus a model list and the run parameters |

A **case set** is one `<name>.jsonl` under `LLM_WEB_CASES_DIR`, and names are `[A-Za-z0-9._-]` and nothing else, because the name is a path segment. Case sets and presets both live in files the server reads and writes directly (`web/cases/` and `web/presets.json`, both gitignored, because they are your data and prompts can be private).

`data` is the same document the static report consumes. A run is a **subprocess** (`bench --json … --web-data …`), and its whole state lives in files under `web/runs/<id>/`: `request.json` (what was asked for), `cases.jsonl` (the filtered suite), `runs.jsonl` (bench's raw output, growing as it runs, which is why progress is its line count), `stdout.log` / `stderr.log`, `exit_code` (written when the bench process is reaped, and its presence means "finished"), and `data.json` (the final page-data document).

## Server environment

| variable | default |
| --- | --- |
| `LLM_WEB_PORT` / `LLM_WEB_STATIC` / `LLM_WEB_WORK` | `8137` / `out` / `runs` |
| `LLM_WEB_CASES_DIR` / `LLM_WEB_CASES` | `cases` (one `<name>.jsonl` per case set) / `../bench/cases.example.jsonl`, only a seed for `cases/default.jsonl` |
| `LLM_WEB_PRESETS` / `LLM_WEB_MODELS` | `presets.json` / none, so there is no menu and you type model ids in the box |
| `LLM_WEB_SYSTEM` | a system prompt to prefill the run-level box with. Set it once and every run starts from it (the page shows it, so you can still change it per run) |
| `LLM_BENCH_BIN` / `LLM_WEB_SSG` | `../_build/native/debug/build/cmd/bench/bench.exe` / `../_build/native/debug/build/web/cmd/ssg/ssg.exe` |
| `MOONLLM_API_KEY` / `OPENAI_API_KEY` / `MOONLLM_BASE_URL` / `OPENAI_BASE_URL` | none (the page asks for a gateway) |

## Static report and styling

`web/cmd/ssg` renders the same result components into a self-contained page: no JavaScript, no server, chain of thought included, and `moon run --target native scripts/build-web.mbtx path/to/other-runs.jsonl` produces another `report.html`. `web/styles/site.scss` is compiled by [`conglinyizhi/precss`](https://mooncakes.io/docs/conglinyizhi/precss) at build time; it uses variables, nesting, `&`, `@mixin`/`@include` and `@media`, and the compiled `out/site.css` has all of it resolved, with no leftover `$`, `@mixin` or `@include` and no CSS framework involved.

## Layout

| path | contents |
| --- | --- |
| `web/cases/default.jsonl` | an automatically generated case set: on the server's first start with an empty case directory it is seeded from `bench/cases.example.jsonl`. Your own sets live here too, gitignored |
| `web/presets.json` | presets: models + parameters, gitignored |
| `web/runs/` | run records, one directory per run, gitignored |
| `web/data.json` | page data exported from a run, gitignored |
| `web/out/` | built page and static reports, produced by `scripts/build-web.mbtx` |

## See also

- [`docs/cli.md`](cli.md): `bench`, which produces the run log every one of these views is built from.
- [`docs/library.md`](library.md): the packages behind the page.
- [`docs/testing.md`](testing.md): the server's HTTP contract test and the browser end-to-end test.
