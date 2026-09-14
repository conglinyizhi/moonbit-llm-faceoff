# Testing

`make ci` is the definition of passing: it is what the GitHub workflow runs, and it is the same single command you can run locally. The targets are thin wrappers over the scripts, so the two cannot drift.

```bash
make ci        # fmt first, then check + unit tests, then smoke ∥ api ∥ web
make e2e       # the browser test as well, which needs chromium and is slow
make           # list every target

moon fmt --check               # formatting, as the toolchain defines it
moon test --target native      # 85 unit tests, no network
moon run --target native scripts/smoke.mbtx          # CLI end-to-end against a local mock endpoint
moon run --target native scripts/server-api.mbtx     # server HTTP contract, incl. key handling
bash scripts/web-e2e.sh        # browser end-to-end (headless chromium)
```

`make demo` runs the offline walkthrough rather than a test: it asks a question, then benchmarks two mock models, and needs no API key.

## The suites

| suite | covers |
| --- | --- |
| `moon test` | settings resolution and precedence, flag parsing and error cases, request JSON shape, response decoding (one-shot outcome: content / reasoning / usage / stop reason), SSE framing (content / reasoning / usage / finish / `[DONE]` / CRLF / malformed), case-file parsing, statistics, throughput derivation, run round-trip, page-data contract, key masking in an upstream error body |
| `scripts/smoke.mbtx` | one-shot via env and via flags, streaming, stdin prompts, **incremental delivery**, non-ASCII error-body decoding, auth failures, that a failing auth does not echo the key, **status lines on stderr with stdout left alone**, `--quiet`, `--show-cot`, **an empty reply warned about and non-zero** instead of a blank line, and the bench harness against the same mock: **a 429 that clears is retried for real** (`attempts: 2`), `--retry n` means n extra HTTP attempts, and a `finish_reason: length` reply lands in the truncation counter instead of passing as a success |
| `scripts/server-api.mbtx` | a run whose `baseUrl`/`apiKey` come from the request body while the server's own are deliberately broken, model ids outside the menu, the live counters, all three exports, **that the key never lands in the run directory or the response**, and that path traversal is refused |
| `scripts/web-e2e.sh` | a real headless browser: the form renders from `/api/meta` (including the model / gateway / key inputs), an `?autorun` link actually completes a run and renders its results (including the chain of thought folded under every answer), **the run-history rail lists that run and opening it switches to the read-only view**, **editing a case in the page reaches the file on disk and a preset saved in the page shows up in the list**, **ticking two runs opens the comparison (parameter diff, metric deltas, per-case answers)**, **deleting a run drops it from the list**, eight parallel `POST /api/runs` come back with eight distinct ids, the start button is usable again once the run finishes, and the export row yields a Markdown report and a share link that carries no key |
| `scripts/real-gateway.mbtx` | **the one suite that is not offline and not in CI.** Four probes against a real endpoint: one-shot, incremental streaming, a bad key reported as 4xx without echoing it, and a reply cut off by `--max-tokens` counted as truncated. Writes `docs/real-gateway-run.md`. Needs `MOONLLM_BASE_URL` / `MOONLLM_API_KEY` exported |

## Why four of them are shaped that way

Four of these exist because the obvious version would pass on a broken implementation.

**Incremental delivery**: the mock sleeps between fragments, and the test measures when the first byte arrived relative to process exit, since comparing final output alone cannot tell a streaming client from a buffering one.

**Non-ASCII error bodies**: the mock sends a Chinese 429 body and the test asserts it decodes, because reinterpreting the bytes as UTF-16 instead of decoding UTF-8 produces mojibake only on non-ASCII payloads.

**Concurrent run creation**: eight parallel `POST /api/runs` must come back with eight distinct ids, and a single-request test passes even while the id allocation is a read-modify-write counter, because it only breaks when two requests arrive together, which is exactly what a hand-run test never does.

**Retry and truncation counters**: the mock can turn a 429 off after the first request (`RATE_LIMIT_ONCE`), which is the only shape in which a *successful* retry is observable, and the test asserts `attempts: 2` and `retried: 1` in the same run, so a client that never actually retried fails outright; a reply whose `finish_reason` is `length` has to land in the truncation counter, because counting it as a plain success would quietly average a cut-off answer into the speed numbers.

## What CI does not run

`scripts/web-e2e.sh` drives Chromium over the DevTools protocol and waits in real time. It deliberately does **not** use `--virtual-time-budget`, since virtual time races the page's own `fetch` and dumps a half-loaded page; set `CHROME=/path/to/chrome` to use another browser binary. It is also the one browser suite CI does **not** run: driving a real browser and waiting in real time makes it the flakiest thing here, and a timing hiccup failing unrelated pull requests is worse than the coverage is worth, so run it with `make e2e` before touching the page.

The other thing CI does not run is `scripts/real-gateway.mbtx`, for a different reason: it needs a key and it costs money, so run it by hand when you want evidence that the client works against a real endpoint, and commit what it writes. Its four probes are described in [`docs/cli.md`](cli.md).

## See also

- [`CONTRIBUTING.md`](../CONTRIBUTING.md): what to run before a pull request, and the house rules.
- [`docs/cli.md`](cli.md): the flags the smoke suite exercises.
- [`docs/web.md`](web.md): the server and page the API and browser suites drive.
