# Project guide for agents

A MoonBit project. Two modules: the root holds the library and the two CLIs,
`web/` holds the interactive page and the static report generator. `README.md`
describes what it does; this file is what an agent needs before touching it.
`CONTRIBUTING.md` has the same rules aimed at humans.

## Commands

```bash
export MOON_CC=gcc            # Linux: without it native builds look for /usr/bin/lib.exe
moon check --target native
moon test --target native     # 48 tests
moon info && moon fmt         # then check the .mbti diff — never hand-edit .mbti
bash scripts/smoke.sh         # the CLIs end to end against a local mock endpoint
bash scripts/demo.sh          # zero-API-key demo
bash scripts/web-e2e.sh       # real Chromium; slow, and the flakiest part of the suite
```

Every one of those scripts starts its own mock endpoint. You do not need an API
key, and you should not reach for a real endpoint to verify a change.

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
