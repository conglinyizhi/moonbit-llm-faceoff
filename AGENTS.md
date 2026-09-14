# Project guide for agents

A MoonBit project. One module at the root holds the library, the two CLIs, the benchmark harness under `bench/`, and the page, its server and the static report under `web/`. `README.md` describes what it does; this file is what an agent needs before touching it. `CONTRIBUTING.md` has the same rules aimed at humans.

## Commands

`make ci` is the definition of passing: it is what CI runs. `make` alone lists the targets, and the Makefile sets `MOON_CC` for you.

```bash
make ci                       # fmt, then check + tests; then smoke ∥ api ∥ web
make e2e                      # add the browser test (real Chromium; slow)
make serve                    # one-shot: build the page, then serve it from web/
make dev                      # same, but rebuild on change (page → page; server → restart)
moon run --target native scripts/server-api.mbtx   # server HTTP contract; asserts the key handling
moon run --target native scripts/real-gateway.mbtx   # the same probes against a real gateway; needs a key (not in CI)
moon test --target native     # 85 tests, one run
moon info && moon fmt         # then check the .mbti diff; never hand-edit .mbti
moon run --target native scripts/smoke.mbtx   # the CLIs end to end against a local mock endpoint
moon run --target native scripts/demo.mbtx   # zero-API-key demo
```

Every one of those scripts starts its own mock endpoint, except `real-gateway.mbtx`, which needs a real endpoint and a key and writes its result to `docs/real-gateway-run.md`. You do not need an API key to verify a change, and you should not reach for a real endpoint to do it.

## Load-bearing constraints

Breaking any of these produces a confusing failure, not a clean error.

- **`web/` does not call into the root library; it consumes `bench`'s exported `data.json`.** The page used to live in its own module because `rabbita` and the library needed different `moonbitlang/async` versions, and one workspace can only hold one. That conflict is gone: everything is on 0.21.3, and this is now a single module behind the root `moon.mod`. The boundary that is still load-bearing is the data hand-off: the statistics are computed once, in `bench`, and passed over as JSON (a live run crosses a process boundary; the static report reads the file). Keep `web/` off the library's API: the moment it calls into `bench`, the statistics gain a second implementation.
- **The client talks to the endpoint directly; no client library sits in between.** The request body is built as `Json` (`request_body`) and the reply is read back out of `Json` (`response_text`), so what this module exposes is the wire format, not some library's types. Streaming frames SSE itself, and `parse_sse_line` is a pure function so the framing logic stays unit-testable. The package's only dependency is `moonbitlang/async`. Delegating the stream to a library was tried and dropped: that entry point took a *synchronous* callback, and a synchronous callback cannot call `@stdio.stdout.write`, so fragments could not be written out as they arrived.
- **Parallel steps in `scripts/ci.sh` must collect every exit code.** Bare `wait` returns 0. `make -s smoke & make -s api & make -s web & wait` therefore wrote `=== [e2e] ok` while `make api` had exited 1: a whole CI run was green with five failing assertions inside it, and the next hour went into asking why the green run was wrong instead of what the failure was. Wait on each pid.
- **A local `make ci` can be fooled by a leftover `_build`; a fresh checkout cannot.** Merging the two modules left `web/_build/` behind, and the server's `LLM_WEB_SSG` default still named the pre-merge path: it resolved to that leftover binary here and to nothing on a runner, so the same commit was green locally and 500 on CI. When a change moves where build outputs land, verify in a clone (`git clone . /tmp/x && make ci` there), not in the working tree.
- **No Python.** Test utilities are `.mbtx` scripts run with `moon run <file>.mbtx --target native`: the default target is wasm and cannot open a socket.
- **`@stdio.stderr` is a single global handle.** Writing to it from concurrent tasks aborts the process (SIGABRT plus a core dump, not a caught error). Serialize it, as `web/cmd/server/main.mbt` does with a semaphore.
- **Run ids come from an atomic `mkdir`,** not from a counter file. Creating an existing directory fails, and that failure is the test-and-set.
- **Ports are assigned by the kernel.** The server takes `LLM_WEB_PORT=0` and prints its bound port as the first line of stdout; the browser uses `--remote-debugging-port=0` and reports through `DevToolsActivePort`. Do not add a hardcoded port: this runs on shared machines.
- **The start button does not use the `disabled` attribute.** A VDOM diff that goes busy → idle does not remove it, which left the button permanently dead. Busy state is a class; repeat clicks are ignored in `update`.
- **The server must run with `web/` as its working directory.** `out/`, `runs/` and `../bench/cases.example.jsonl` are resolved relative to it; started from the repository root it answers `/api/meta` and then 404s every page request. It now prints a warning when the static directory is missing. Keep that warning: it is the only thing that makes the failure legible.
- **A key typed into the page must never reach disk.** `web/runs/<id>/request.json` is written from a scrubbed copy of the request body, with `apiKey` removed before serialization. Keep it that way, and add an assertion when you touch it.
- **The export routes match a fixed allowlist of names** rather than joining user input onto a path. Do not turn `send_run_file` into a general file server.
- **The artifact's depth under `--target-dir` differs per platform.** On Linux moon appends the source file name again (`<dir>/<name>/native/…`); on Windows it does not (`<dir>/native/…`), which the CI job's log shows. Look for both before concluding a build failed: code that only knew one shape reported a *successful* build as "compile failed" for two CI rounds.
- **Each `.mbtx` builds into its own target-dir** (`scripts/_build/mbtx/<name>/…`, see `mbtx_dir` in `scripts/lib.sh` and in each script). They used to share `_build/.../single/single.exe`, so a running suite could not build the mock endpoint it spawns, because Windows refuses to overwrite a running executable (`LNK1168: cannot open ... for writing`). Separate directories remove that collision. `.github/workflows/ci.yml`'s Windows job still builds, copies and runs (so the runner needs no shell) and now locates the binary with `Get-ChildItem -Recurse` instead of hardcoding the path. On Linux `moon run` is fine; the failure mode is `text file busy` at worst.
- **A copied wrapper needs the platform's executable suffix.** `@process.spawn` finds `scripts/_build/mock-endpoint` on Linux; on Windows `CreateProcess` will not append `.exe` and reports "cannot find the file specified". `build_mbtx` therefore derives the suffix from what the build produced (`single.exe` vs `single`).
- **Executable paths must be absolute even when `cwd` is passed.** On POSIX a relative path is resolved after the child `chdir`s, so `"./_build/.../ssg.exe"` with `cwd=web` works. `CreateProcess` does not do that: it fails with "The system cannot find the file specified". Four such call sites were found by the Windows job.
- **Never commit a key,** and read `SECURITY.md` before writing anything that persists response bodies: an upstream error can echo the key back.
- **Never commit user data.** `web/cases/`, `web/presets.json`, `web/runs/` and `docs/real-gateway-run.md` are ignored on purpose: case sets, annotations and real-gateway output belong to whoever ran them. Placeholder-looking content is still user content. Adding a new path that holds any of it means adding it to `.gitignore` and to the list in `SECURITY.md` in the same change.

## MoonBit notes

- Code is organized in blocks separated by `///|`, each independently processable. Keep deprecated blocks in a `deprecated.mbt` in the package.
- Each directory is a package with its own `moon.pkg` listing imports and targets. Blackbox tests end in `_test.mbt`, whitebox tests in `_wbtest.mbt`.
- `moon ide` provides `peek-def`, `outline`, `find-references`.
- `moon coverage analyze > uncovered.log` for coverage.
- Prefer `assert_eq` for stable results. For snapshot tests of structured debug output, derive `Debug` and use `debug_inspect` rather than `Show`.
- Extra MoonBit skills: <https://github.com/moonbitlang/skills>
