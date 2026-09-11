# Project guide for agents

A MoonBit project. Two modules: the root holds the library and the two CLIs,
`web/` holds the interactive page and the static report generator. `README.md`
describes what it does; this file is what an agent needs before touching it.
`CONTRIBUTING.md` has the same rules aimed at humans.

## Commands

`make ci` is the definition of passing — it is what CI runs. `make` alone lists
the targets, and the Makefile sets `MOON_CC` for you.

```bash
make ci                       # deps, check, tests, smoke, server API, page build
make e2e                      # add the browser test (real Chromium; slow)
moon run --target native scripts/server-api.mbtx   # server HTTP contract; asserts the key handling
moon run --target native scripts/real-gateway.mbtx   # the same probes against a real gateway; needs a key (not in CI)
moon test --target native     # 54 tests
moon info && moon fmt         # then check the .mbti diff — never hand-edit .mbti
moon run --target native scripts/smoke.mbtx   # the CLIs end to end against a local mock endpoint
bash scripts/demo.sh          # zero-API-key demo
```

Every one of those scripts starts its own mock endpoint — except
`real-gateway.mbtx`, which needs a real endpoint and a key and writes its result to
`docs/real-gateway-run.md`. You do not need an API key to verify a change, and
you should not reach for a real endpoint to do it.

## Load-bearing constraints

Breaking any of these produces a confusing failure, not a clean error.

- **`web/` must not depend on the root module.** The library pins
  `moonbitlang/async` 0.20.1 and Rabbita requires 0.21.x; one workspace can hold
  only one version, so merging them forces an `async` upgrade. `web/` reads
  `bench`'s exported `data.json` instead, which also keeps the statistics in one
  implementation.
- **No Python.** Test utilities are `.mbtx` scripts run with
  `moon run <file>.mbtx --target native` — the default target is wasm and cannot
  open a socket.
- **`@stdio.stderr` is a single global handle.** Writing to it from concurrent
  tasks aborts the process (SIGABRT plus a core dump, not a caught error).
  Serialize it, as `web/cmd/server/main.mbt` does with a semaphore.
- **Run ids come from an atomic `mkdir`,** not from a counter file. Creating an
  existing directory fails, and that failure is the test-and-set.
- **Ports are assigned by the kernel.** The server takes `LLM_WEB_PORT=0` and
  prints its bound port as the first line of stdout; the browser uses
  `--remote-debugging-port=0` and reports through `DevToolsActivePort`. Do not
  add a hardcoded port — this runs on shared machines.
- **The start button does not use the `disabled` attribute.** A VDOM diff that
  goes busy → idle does not remove it, which left the button permanently dead.
  Busy state is a class; repeat clicks are ignored in `update`.
- **The server must run with `web/` as its working directory.** `out/`, `runs/`
  and `../bench/cases.example.jsonl` are resolved relative to it; started from
  the repository root it answers `/api/meta` and then 404s every page request.
  It now prints a warning when the static directory is missing — keep that
  warning, it is the only thing that makes the failure legible.
- **A key typed into the page must never reach disk.** `web/runs/<id>/request.json`
  is written from a scrubbed copy of the request body, with `apiKey` removed
  before serialization. Keep it that way, and add an assertion when you touch it.
- **The export routes match a fixed allowlist of names** rather than joining
  user input onto a path. Do not turn `send_run_file` into a general file
  server.
- **Never commit a key,** and read `SECURITY.md` before writing anything that
  persists response bodies — an upstream error can echo the key back.

## MoonBit notes

- Code is organized in blocks separated by `///|`, each independently
  processable. Keep deprecated blocks in a `deprecated.mbt` in the package.
- Each directory is a package with its own `moon.pkg` listing imports and
  targets. Blackbox tests end in `_test.mbt`, whitebox tests in `_wbtest.mbt`.
- `moon ide` provides `peek-def`, `outline`, `find-references`.
- `moon coverage analyze > uncovered.log` for coverage.
- Prefer `assert_eq` for stable results. For snapshot tests of structured debug
  output, derive `Debug` and use `debug_inspect` rather than `Show`.
- Extra MoonBit skills: <https://github.com/moonbitlang/skills>
