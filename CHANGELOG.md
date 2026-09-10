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

### Fixed

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
