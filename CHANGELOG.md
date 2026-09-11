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

- **The verdicts are editable in the page, and they are on both pages.** Under every
  answer in the workbench: ✅ 通过 / ❌ 不行 / 🤔 拿不准 and a note box. The verdict
  saves on click (clicking the same one again clears it — no separate undo), the note
  saves on 存备注, and the answer shows the badge and the note next to it afterwards.
  The playground shows the verdict as a mark in the cell (`🤔 拿不准`) and the same
  editor in the expanded comparison.

  Writing the browser test for this found two real bugs, both about *which* data the
  screen is showing: the Markdown copy read the current run's data even while a
  historical run was on screen ("还没有结果可复制" for a run whose results were right
  there), and opening a historical run did not load its annotations, so an annotated
  run looked unannotated until you reloaded. The export row already followed the
  viewed run; the copy button and the annotation fetch now do too.

- **Human verdicts on results.** Every answer — one run × one case × one model — can
  carry a verdict (`pass` / `fail` / `unsure`, `✅ 通过` / `❌ 不行` / `🤔 拿不准` on
  screen) and a free-text note saying what was wrong. They live in
  `web/runs/<id>/annotations.jsonl`, so deleting a run takes its verdicts with it
  rather than leaving notes pointing at nothing.

  The verdict is a stable English token in the file and an emoji in the UI on
  purpose: swapping the symbol later should not mean rewriting the data.

  They travel with the exports. `/api/runs/<id>/report.html` merges the annotations
  into the data it hands the generator, and the Markdown copy includes them, so a
  report someone opens in three weeks still says which answers were judged wrong and
  why. Regenerating the cached report compares the *merged content* rather than
  mtimes — the mtime version was wrong within the same second, which is exactly the
  window a person annotating right after a run lives in.

- **A playground page: one fixed system prompt, a list of user prompts, the models
  side by side** (`/playground.html`, linked from the workbench header). It is a
  separate bundle and a separate shell, so the workbench's own page is untouched.

  The result view is a grid of **uniform cells** — same width, same height, answer
  clipped — because the question it answers is "what did each model say to *this*
  prompt", and that is a comparison you scan rather than read. Press 对比 on a row
  and it opens underneath: the models side by side with the whole answer and the
  folded chain of thought, or a **character-level diff** against the first model
  (common prefix and suffix stripped first, then an LCS on what is left; the LLM
  answers that share an opening are the ones where this is worth reading). A single
  prompt may override the shared system prompt, and 存成用例集 writes the current
  system + prompts into `web/cases/` so a prompt that turned out to be interesting
  becomes a repeatable test.

- **`POST /api/runs` can take the cases inline.** `inlineCases` is an array of case
  objects (`{prompt, id?, system?, max_tokens?, temperature?}`) written straight
  into that run's `cases.jsonl`, and `system` sets the system prompt for the whole
  run — each case may still override it. That is what the playground page needs: a
  fixed system prompt plus a handful of ad-hoc prompts should not require saving a
  case set first. The three ways to describe a run (`caseSet` + `cases` ids, a
  single `prompt`, `inlineCases`) are mutually exclusive, and a request that mixes
  them is a 400 rather than a guess. Counting was updated with it, so the live
  status and the history rail report "2 models × 2 cases" for these runs instead of
  zero, and the global `system` is recorded in `request.json` so a rerun replays
  the same thing.

- **CI runs the suites on Windows too.** "The scripts are MoonBit now, so they are
  cross-platform" was a claim; a `windows-latest` job now backs it with a runner:
  `moon test --target native` in both modules, then `smoke.mbtx` (16 checks) and
  `server-api.mbtx` (42 checks) — which exercise process spawning, the mock endpoint,
  the CLI binaries, `@http`, `@fs` and the server's own child-process handling.

  Getting it green took five runs and each failure was a real platform difference,
  documented in `AGENTS.md` because they are the kind that look like environment
  noise:

  - `moon update` first: a fresh checkout has the bundled index, not the downloaded
    one, and without it dependency resolution fails with "module was not found in
    the registry".
  - A running `.mbtx` holds `_build/.../single/single.exe`, and Windows will not
    overwrite a running executable (`LNK1168`) — so a suite that builds the mock
    endpoint cannot itself be started with `moon run`; build, copy, run the copy.
  - A copied wrapper needs `.exe`: `CreateProcess` does not append it, so the mock
    endpoint "could not be started" until `build_mbtx` started deriving the suffix
    from the build output.
  - Executable paths must be absolute even with `cwd` set — POSIX resolves a relative
    path after the child `chdir`s, `CreateProcess` does not.
  - `D:\...` is an absolute path: two checkers only recognised `/`, and re-prefixed
    the caller's path with the working directory, producing a doubled path.

- **`demo.sh` and `web/build.sh` are `scripts/demo.mbtx` and
  `scripts/build-web.mbtx`.** With those two gone, the POSIX surface of the repo
  is down to `scripts/web-e2e.sh` and the `scripts/lib.sh` it sources — plus
  `cdp-dump.mjs`. `make demo`, `make web` and `make serve` all run the `.mbtx`
  versions now.

  Two small things the port surfaced: `println` is block-buffered when stdout is
  redirected, so a script that both prints its own lines and forwards child output
  has to put both through `@stdio.stdout.write` or the ordering comes out scrambled
  (the demo's first run printed the model output above its own "==> building"
  header); and `0.20.1`'s `@fs` has no `file_size`, so the build's product summary
  lists names rather than sizes instead of reading each file back to measure it.

- **`real-gateway.sh` is now `real-gateway.mbtx`** — the same four probes against
  a real endpoint, the same evidence file, and the same key handling: read from
  the environment only, never on a command line, and if the key turns up in the
  evidence the script deletes the file and exits non-zero rather than leave it
  behind. `@env.now()` milliseconds are turned into a UTC timestamp with the
  civil-from-days algorithm, so it no longer shells out to `date` either.

  What is left in shell after this round: `demo.sh` and `web/build.sh` (next), the
  `lib.sh` they share, and `web-e2e.sh` with its `cdp-dump.mjs` (deliberately
  deferred — that one drives Chromium over a CDP WebSocket, which is a separate
  risk and its own round).

- **`server-api.sh` is now `server-api.mbtx`** (42 assertions, the same ones, and
  what `make ci` runs). The shell version drove the HTTP contract with `curl`
  plus `sed`/`grep` on the response text; the MoonBit version calls the endpoints
  with `@http` and reads the JSON, so the assertions say what they mean. It also
  builds the page itself when `web/out/` is missing (the `GET /` assertion needs
  it), instead of assuming someone ran `make web` first.

  One difference caught while porting: the shell version compared the run's
  `exit_code` with `$(cat …)`, which strips the trailing newline for free. The
  port kept the newline and compared `"0\n"` against `"0"`, so a *successful* run
  looked like a failure until the comparison was trimmed — worth remembering when
  porting any `$(cat)` into a language that does not trim for you.

  0.20.1's `@http` has `get`/`post`/`put` helpers but no top-level `request`, so
  `DELETE` goes through a `Client` (origin in the constructor, path in the call)
  — noted in the script, because the newer async versions do have `@http.request`.

- **`smoke.sh` is now `smoke.mbtx`** (16 checks, same assertions, and it is what
  `make ci` runs). The shell version needed `grep`, `sed`, `curl`, `seq`, `mktemp`
  and a `source`d `lib.sh`; the MoonBit version needs nothing but the language and
  `moonbitlang/async` — process spawning, output capture, file reads and string
  assertions all exist there and work off POSIX. Two things it keeps from the
  shell version on purpose: the mock is built and *copied* to a distinct file
  before being spawned (spawning `moon run foo.mbtx` and killing it leaves the
  real server orphaned), and the mock is attached to a task group so the script
  cannot exit with a listener still running.

  Unlike a `.mbt` file, a `.mbtx` script cannot import anything local — an import
  of this module's own packages reports "module not found", it only consults the
  registry — so each converted script carries its own small assertion/process
  prologue rather than sharing one.

- **The server no longer spawns `bench` through `/bin/sh`.** This is the one that
  actually kept the workbench off Windows: every run went through
  `spawn_orphan("/bin/sh", ["-c", "bench … > …; echo $? > exit_code"])`, and
  Windows has no `/bin/sh`, so the very first click would have died there. The
  child is now spawned directly with an argv array and a task attached to the
  server's own lifetime waits for it to be reaped and writes `exit_code`. Two
  side effects worth having: the shell-quoting helper is gone (nothing to escape,
  and no command string left to inject into), and stdout/stderr are ordinary file
  redirects rather than `>` and `2>>` inside a string.

  Two things went wrong on the way, both kept in the comments because they are
  the kind of mistake that looks right: the argv array still began with the bench
  binary path (it was argv[0] for a shell command line, but `spawn` adds argv[0]
  itself, so the child saw its own path as a flag), and the waiter was first put
  in a `with_task_group`/`no_wait=true` scope — `no_wait` does not mean
  fire-and-forget, it means "do not wait for this task *and cancel it when the
  scope ends*", so the exit code was never written.

- `make serve` builds the page and then starts the server **from `web/`**, which is
  the part everyone forgets: the server resolves `out/`, `runs/`, `cases/` and
  `presets.json` against its working directory, so starting it from the repository
  root answers `/api/meta` and 404s every page request. The README's two-step
  version still works; this just removes the trap from the one-liner.
- The streaming probe's token budget is no longer hardcoded, and its failure
  message no longer guesses. `scripts/check_stream.mbtx` was asking for 256
  output tokens; a reasoning model can spend all of them thinking, which leaves
  the visible answer empty, which makes `faceoff` exit non-zero — and the probe
  then reported that as "a streaming request against this endpoint did not work",
  pointing at the gateway instead of at its own budget. Reported by the first
  real-gateway run (`docs/real-gateway-run.md`): 3 probes passed, this one failed,
  and the fix was on our side. The budget is now `STREAM_MAX_TOKENS` (default
  2048), named in the evidence line, and the message lists both likely causes
  instead of choosing one.

- **Two runs, side by side.** Tick two entries in the history rail and the main
  area becomes a comparison in three parts: which parameters actually differ
  (models, case set, repeats, `max_tokens`, pacing, the gateway — so "I only
  changed one thing" is something you can check rather than remember); every
  metric's median from both runs with a Δ column; and the two runs' answers for
  the same case next to each other, chain of thought included.

  Two decisions worth naming. The Δ column is **not** coloured: the same sign is
  good for throughput and bad for latency, and this layer has no per-metric
  polarity, so colouring would be the UI making a judgement it cannot support.
  And ticking a third run drops the oldest pick instead of ignoring the click —
  a click that does nothing is worse than one that visibly replaces something.

  A run that failed has no `data.json` to compare, so the view says so instead of
  waiting forever on "loading"; the parameter diff still shows, because that part
  comes from `request.json`, which every run has.

- **Case sets and presets are editable in the page.** The case panel lists the
  sets under `web/cases/`, ticks the cases a run will use, and edits them in
  place: `prompt` as the main text area, `id` beside it, and the per-case
  `system` / `max_tokens` / `temperature` folded under a `更多字段` that only
  opens when you need it. `另存为新集` forks the current set. A save round-trips
  fields it never displayed — the editor carries the raw record and merges the
  edited keys into it, so a hand-written field is not quietly dropped by a trip
  through the UI.

  Presets store a model list plus the run parameters (and the case set) so "the
  usual two models, three repeats, 2048 tokens" is one click. Saving under an
  existing name overwrites it; a preset with no name gets one derived from what
  it holds. Applying one puts menu models back in the checkboxes and menu-outsiders
  in the free-text field — otherwise a model that just got applied would be
  running but invisible.

  Two small things that make this usable rather than merely present: validation
  runs locally first, so "第 3 条没有 prompt" arrives without a round trip, and
  switching case sets drops selections that are not in the new set instead of
  letting the next run fail with "none of the selected ids are in case set".

- **The page is a workbench: the left column is the run history.** Every run that
  has happened is listed with its time, models, scale and counters; one click
  opens it read-only (the answer/chain-of-thought view, and the export links
  follow the run you are reading), `重跑` starts exactly the parameters that run
  used — read back from its `request.json`, gateway address included, because the
  key was never stored — and `删除` removes it. The list refreshes itself when a
  run finishes.

  The current run and the viewed run are separate state on purpose: sharing one
  slot means a finished run silently replaces the history you were reading. A
  failed run has no `data.json`, so opening one shows its `stderr` tail instead
  of a blank page.

  `scripts/web-e2e.sh` drives it in a real browser (open → read-only banner +
  answers, delete → the item goes away) and — like `scripts/server-api.sh` — the
  test's server now points `runs/`, `cases/` and `presets.json` at a temp
  directory, so running the suite cannot delete your data.

- **The server side of a test workbench: run history, named case sets, presets.**
  Until now the page could start a run and show that run; the things that made a
  test *manageable* were all file work by hand. The API grew:
  `GET /api/runs` (every past run, newest first, each carrying the `request.json`
  it ran with, so it can be replayed), `DELETE /api/runs/<id>`,
  `GET|PUT|DELETE /api/cases/<name>`, `GET|PUT /api/presets`. `POST /api/runs`
  takes a `caseSet` and the resolved name is written back into `request.json`, so
  history replays the suite that actually ran rather than whatever is the default
  later.

  Storage stays files, because that is the only thing that survives a restart:
  `web/cases/<name>.jsonl` per case set and `web/presets.json` for the model +
  parameter combinations. Both are gitignored — prompts can be private, and the
  contract test now points them (and `runs/`) at a temp directory so running it
  cannot delete your data. `LLM_WEB_CASES` became a seed: an empty case-set
  directory gets `cases/default.jsonl` copied from it, so existing setups keep
  working.

  Two validations are worth calling out because they turn silent wrongness into a
  400: a case without an `id` is given one on save (the bench side filters cases
  by id, so an id-less case could be ticked in the UI and silently not run), and a
  run whose selected ids match nothing in the set is refused instead of running
  zero cases. Case-set and preset names are restricted to `[A-Za-z0-9._-]` since
  they become path segments.

  `scripts/server-api.sh` covers all of it: 17 → 42 assertions, including the
  traversal and duplicate-id refusals.

- **The chain of thought is on the page now**, folded under every answer
  (`思考过程 · N token · M 字`, closed by default). The page data used to carry
  `reasoning_tokens` and not the reasoning text, so the side-by-side answer view
  could say how much a model thought but not *what* it thought — which is the
  whole comparison when both models ran the same prompt. `bench`'s page-data
  document now includes `reasoning` per answer, `web/shared` parses it, and the
  static report gets it for free because both front-ends render the same
  components.

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
