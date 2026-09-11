# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Breaking:** renamed from `llm_client` to `moonbit-llm-faceoff`. The old name
  described a client; the point of the project is comparing models. The module
  path is now `conglinyizhi/moonbit-llm-faceoff`.

  Because a hyphenated path segment cannot serve as a default package alias,
  dependents must now declare an explicit alias in their own `moon.pkg`:

  ```text
  import {
    "conglinyizhi/moonbit-llm-faceoff" @faceoff,
  }
  ```

- **Breaking:** `cmd/main` moved to `cmd/faceoff`, so the built binary is
  `faceoff` rather than `main.exe`.
- License changed from Apache-2.0 to MIT. The repository contains no third-party
  source, so the change applies cleanly.
- `web/` now depends on `conglinyizhi/precss` 0.1.1.
- `POST /api/runs` accepts `baseUrl` and `apiKey`, and `LLM_WEB_MODELS` became a
  default menu rather than a hard allowlist. Empty fields still mean "use the
  server's", which is why the payload sends them as absent rather than blank.
- `GET /api/runs/<id>` gained `failures`, `retried` and `truncated`, and now
  always returns `tail` instead of only while the run is going.
- The key reaches the child process through the **environment** rather than its
  command line, so it no longer appears in `ps`.

### Changed

- `autorun=1` no longer starts a run when no API key is available anywhere. The
  run could only fail with an authentication error, and that error reads like a
  broken setup. The page now says why it did not start and waits for you to fill
  the key in and press **开始评测**. Filling the key does not auto-start either —
  that would fire on every keystroke.
- The quick start no longer shows a long `?autorun=1&models=…&cases=…&repeats=…`
  URL. It just says to open the page and work there. The query parameters keep
  their own reference section, with a shorter example.

### Fixed

- **CI could not pass.** Two reasons, both the same shape: the state my machine
  had and a fresh clone does not. `web/out/` is gitignored, so on a runner the
  API test ran before the page had ever been built — and its `/` assertion needs
  the page. `scripts/server-api.sh` now builds the page itself when it is
  missing, and `make ci` builds the page before the API test. Separately, three
  assertions in that script called `fail` as a function, but `fail` is the
  integer counter there (the function is `bad`); they only ran on paths that a
  machine with `web/out/` present never took, so the mistake survived until CI
  hit it.
- **The documented way to start the web server was broken.** Both READMEs ran it
  from the repository root; the server resolves `out/`, `runs/` and the case file
  relative to its working directory, so it answered `/api/meta` and then 404'd on
  every page request. The command is corrected, the working directory is called
  out, and the server now warns at startup when its static directory is missing
  instead of leaving you with a bare 404. `scripts/server-api.sh` asserts that
  the documented invocation actually serves the page.
- The quick start gained a **"run the web page"** step. Previously the page only
  appeared as a link at the bottom of the CLI walkthrough, so there was no short
  path from a fresh clone to a running comparison in the browser.
- **Client, key redaction:** a non-2xx response body is surfaced verbatim as
  `http <status>: <body>` and then persisted — to the bench run log, to
  `web/runs/<id>/runs.jsonl` and `data.json`, and out to the browser. An endpoint
  that echoes the request headers in its error text (the bundled mock does, and
  some gateways do) therefore wrote the API key into all of those places. The
  configured key is now masked before it becomes part of an error — the first two
  and last two characters are kept, so the error still says *which* key was used
  without exposing it (`Bearer sk***3a`); keys shorter than 12 characters are
  masked whole. `scripts/smoke.sh` asserts it end to end.
- **Web server, run ids:** two concurrent `POST /api/runs` could be handed the
  same id, after which both wrote into the same directory. Ids are now allocated
  by an atomic `mkdir` — creating an existing directory fails, which is the
  test-and-set — instead of a read-modify-write counter file.
- **Web server, process abort:** concurrent requests could kill the server.
  `@stdio.stderr` is a single global handle, and a per-request logger writing to
  it from several `spawn_bg` tasks tripped its internal guard (SIGABRT plus a
  core dump). Writes are now serialized with a semaphore.
- **Web server, ports:** the listening port and the browser's remote-debugging
  port were hardcoded, which collides on a shared machine. Both are now assigned
  by the kernel and reported back over a handshake (the server prints its bound
  port as the first line of stdout; the browser writes `DevToolsActivePort`).
  The server also sets `reuse_addr` so a restart is not blocked by `TIME_WAIT`.
- **Web page, start button:** after a run finished, the button stayed disabled.
  The VDOM diff did not remove the `disabled` attribute when the state went back
  to idle, so the page had to be reloaded before another run could start. The
  button now expresses busy/idle through a class, and `update` ignores repeat
  clicks while a run is in flight.
- **Web page, comparison table:** the header had `text-transform: uppercase`,
  which rewrote model names (`mock-a` → `MOCK-A`). Presentation should not alter
  data.
- `scripts/lib.sh`: rebuilding a `.mbtx` script while its binary was still
  running failed with "Text file busy"; the build now writes to a temporary name
  and renames it into place.

### Added

- `faceoff` says what it is doing. A one-shot request used to print nothing at all
  until it was finished — for a reasoning model that is a minute of a seemingly
  dead terminal, and there was no way to tell it apart from a hang. It now writes
  one line before the request and a summary after it to **stderr**, so stdout
  stays exactly the reply:
  `<- 3.2s  content 41 chars  reasoning 512 chars  tokens 21+64(reasoning 64)  finish_reason=length`.
  `--quiet` turns those off; `--show-cot` streams the chain of thought to stderr,
  which is the streaming counterpart of watching it think.
- **An empty reply is no longer a blank line and exit 0.** When the visible
  content is empty — the usual cause being a reasoning model that spent the whole
  `--max-tokens` budget thinking — `faceoff` now says so on stderr, with the stop
  reason and the token counts that explain it, and exits non-zero. A pipeline
  could not tell the old behaviour apart from a model that said nothing.
  `@faceoff.ask_outcome` is the library-level counterpart: the same request, but
  it returns `content`, `reasoning`, `usage` and `finish_reason` instead of only
  the text. `ask` is now a thin wrapper over it, and `response_outcome` should be
  used wherever an empty answer needs an explanation.
- The mock endpoint can simulate that shape: a prompt containing `THINK_ONLY`
  returns an empty visible answer with non-empty reasoning and
  `finish_reason: length`, so the empty-reply path is covered end to end instead
  of only in theory.

- `make install` (a thin wrapper over `moon install ./cmd/...`) puts `faceoff` and
  `bench` in `~/.moon/bin`. The README had been writing `faceoff` as a bare
  command without ever saying how it gets onto the PATH; it now covers both
  routes, and `scripts/real-gateway.sh` writes the command it actually ran into
  its evidence instead of a shortened shape nobody can copy.

- `scripts/real-gateway.sh` — the first thing in this repo that talks to a
  **real** endpoint, and the one that was missing: everything else runs against
  the bundled mock, which cannot tell you whether the client fits a real
  gateway. Four probes, each with its own verdict, and the whole run is written
  to `docs/real-gateway-run.md`: a real one-shot reply; whether fragments
  actually arrive incrementally (`scripts/check_stream.mbtx`, which measures the
  first byte against process exit the same way the offline test does, but takes
  the endpoint and the key from the environment instead of hardcoding them);
  that a bad key comes back as 4xx with the key kept out of the error; and that a
  reply cut off by `--max-tokens` lands in the truncation counter rather than
  passing as a success. `--compare` with `REAL_MODEL_B=<model>` also produces the
  two-model report. Not in CI — it needs a key and it costs money — and the key
  is read from the environment only: the script refuses to leave a file behind
  if the key turns up in it.
- The mock endpoint got faithful enough for that script to be tried locally
  first: it honours `max_tokens` now (a budget smaller than the reply it is
  about to send comes back as `finish_reason: length`, the same way a real
  gateway reports it), and `MOCK_ALLOW_ANY_KEY=1` makes it stop checking
  `Authorization` — that is what exercises the "this endpoint does not require a
  key" branch instead of leaving it as untested code.

- `scripts/smoke.sh` now proves the retry and truncation counters are wired up
  rather than decorative. The mock endpoint grew two switches to make that
  observable: a prompt containing `RATE_LIMIT_ONCE` is 429'd exactly once and
  then served — the only shape in which a *successful* retry can be asserted, so
  the test looks for `attempts: 2` in the run log and `retried 1` in the
  summary — and `TRUNCATE` produces a normal reply whose `finish_reason` is
  `length`, which has to land in the truncation counter instead of passing as an
  ordinary success. A third case pins `--retry n` to exactly n extra HTTP
  attempts, and asserts that a run which only ever saw 429s is counted as both
  retried and failed.

- **The web page is a workbench now.** Model ids can be typed instead of only
  picked from the server's menu, the gateway address and API key can be
  overridden for a single run, the run's live failure/retry/truncation counts and
  its `stderr` tail are visible while it runs, and the result can be exported
  five ways: copy the report as Markdown, copy a shareable URL, or download
  `runs.jsonl`, `data.json`, or a self-contained `report.html`.
- `scripts/server-api.sh`: the server's HTTP contract, asserted — a run whose
  `baseUrl` and `apiKey` come from the request body while the server's own are
  deliberately broken, model ids outside the menu, the live counters, all three
  exports, that the key never reaches the run directory or a response, and that
  path traversal is refused.
- `web/` has unit tests now (`web/shared/markdown_test.mbt`), and `make test`
  runs both modules rather than only the root.
- `scripts/cdp-dump.mjs` grew `--script` / `--script-wait`, so a browser test can
  drive the page before dumping it.
- `Makefile`: `make ci` is the definition of passing — deps, type check, unit
  tests, smoke, page build — and it is the same command locally as in CI, so
  there is one definition rather than two. `make` lists the targets, and the
  Makefile sets `MOON_CC` so native builds work without exporting it by hand.
- `.github/workflows/ci.yml`: runs `make ci` on pushes to `main` and on pull
  requests. The browser end-to-end test is deliberately not included — it drives
  a real Chromium and waits in real time, and a timing hiccup failing unrelated
  pull requests costs more than the coverage is worth. `make e2e` runs it
  locally.
- `scripts/web-e2e.sh` now covers two regressions it did not before: eight
  parallel `POST /api/runs` must produce eight distinct ids, and the start
  button must return to a usable state after a run completes.
- `scripts/cdp-dump.mjs` can capture a full-page screenshot, for checking what
  the page actually looks like rather than only what its DOM says.

## [0.1.0] - unreleased

First working version. Not published to Mooncakes, and not tagged.

### Added

- An OpenAI-compatible chat client with two paths: one-shot (`ask`) and
  streaming (`stream_chat`, `stream_parts`, `stream_to_stdout`). Both talk to
  the endpoint directly over `moonbitlang/async` — no third-party LLM client in
  between, so the wire format stays the visible contract (`request_body` and
  `response_text` both deal in plain `Json`).
- `bench`: run one case suite against several models and compare them on
  first-token latency, first-content latency, total time, token counts
  (including reasoning tokens and their share of the output), decode and
  end-to-end throughput, plus failure, truncation and retry counts. Each metric
  is reported as a median with a min–max range across repeats.
- `web/`: an interactive page (Rabbita, compiled to JS from MoonBit) with a
  native server that runs the harness in a subprocess and streams progress back,
  plus a static report generator for publishing a result set.
- An offline mock endpoint (`scripts/mock_openai.mbtx`) so the demo, the smoke
  test and the browser end-to-end test all run with no API key and no network.
