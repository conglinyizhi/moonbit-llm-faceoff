# Contributing

Thanks for looking. This is a small project, so the notes below are the things that will actually bite you rather than a process document.

## Getting set up

You need the [MoonBit toolchain](https://www.moonbitlang.com/download/) and a C compiler (`gcc` or `clang`). Nothing else: no API key, no Python, and no Node unless you want to run the browser test.

On Linux, name the C compiler explicitly. Without it, native builds fail looking for an archiver at `/usr/bin/lib.exe` that does not exist:

```bash
export MOON_CC=gcc
```

### If the build fails

| symptom | fix |
| --- | --- |
| `failed to resolve native archiver executable /usr/bin/lib.exe`, or `new native backend requires a C compiler/linker driver` | a C compiler exists but wasn't picked up. Set it explicitly: `MOON_CC=gcc moon build --target native` (every script here already defaults to that) |
| `Cannot find import '...'` | stale registry index: run `moon update` |
| browser tests fail with `cannot open shared object file` | the browser binary is older than the system libraries it links against. Check with `ldd $(command -v chromium)`, or point the tests elsewhere with `CHROME=/path/to/chrome` |

## Reading the repo

Five lines for anyone who has not read MoonBit before:

| you see | it is |
| --- | --- |
| `moon.mod` / `moon.pkg` | the module manifest (one per repository, like `package.json` or `Cargo.toml`) / the package manifest: **one directory = one package**, listing that package's imports |
| `*.mbt` / `*.mbtx` | source files (`foo_test.mbt` / `foo_wbtest.mbt` are blackbox / whitebox tests) / a **single-file script**: `moon run --target native file.mbtx`, no manifest needed. Used here for the test utilities under `scripts/` |
| `_build/` | build output (`_build/native/debug/build/.../main.exe`); `moon build` / `run` / `test` / `check` are build, run, test, type-check |

For the language itself, see <https://docs.moonbitlang.com/> and the package registry <https://mooncakes.io/>. This repo is one module: one `moon.mod` at the root covers the library, the two CLIs, the benchmark harness under `bench/`, and the page, its server and the static report under `web/`; a single `moon check` (native + js) and a single `moon test --target native` cover the whole thing.

## Where the detail lives

| document | covers |
| --- | --- |
| [`docs/cli.md`](docs/cli.md) | `faceoff` and `bench`: installing them, every flag, the environment variables, the suite format, the metrics, rate limits and replay, the outputs, and the probes against a real gateway |
| [`docs/web.md`](docs/web.md) | the page and its server: what every panel does, the URL parameters, the HTTP API, the server environment, the static report, and the `web/` layout |
| [`docs/library.md`](docs/library.md) | using `bench` and the client as MoonBit packages: the import alias, one-shot, streaming, benchmarking, and the error type |
| [`docs/testing.md`](docs/testing.md) | what `make ci` runs, the five suites and what each covers, why four of them are shaped that way, and the two suites CI does not run |

## Running things

```bash
make                # list every target
make ci             # fmt, then check + unit tests; then smoke ∥ api ∥ web
make e2e            # the browser test as well (needs chromium, slow)
make demo           # ask a question, then benchmark two models; no API key
```

Those are thin wrappers over the raw commands, which you can also run directly:

```bash
moon check --target native
moon check --target js
moon test --target native
moon run --target native scripts/smoke.mbtx
bash scripts/web-e2e.sh
moon run --target native scripts/build-web.mbtx
```

The test and end-to-end commands each start their own mock endpoint, so none of them need a key or network access. What each suite covers, and why four of them are written the way they are, is in [`docs/testing.md`](docs/testing.md).

`scripts/real-gateway.mbtx` is the exception, and it is the one you do not run by reflex: it talks to a **real** endpoint, needs `MOONLLM_BASE_URL`, `MOONLLM_MODEL` and `MOONLLM_API_KEY` exported, and writes what it observed to `docs/real-gateway-run.md`. Use it to prove the client works against a real gateway, not to check a change.

## House rules

**No Python.** Test utilities are MoonBit scripts (`.mbtx`) run with `moon run <file>.mbtx --target native`. The `--target native` is not optional: the default target is wasm, which cannot open a socket. Keeping the test path on the same toolchain as the code is the whole point.

**One module, with `web/` off the library's API.** The library, the CLIs, the harness and the page are one MoonBit module behind the root `moon.mod`. `web/` deliberately does not call into the library: it consumes `bench`'s exported `data.json` instead. That keeps the statistics in one implementation. The page used to live in its own module because the library pinned `moonbitlang/async` 0.20.1 while Rabbita requires 0.21.x and one workspace can only hold one version; the library is on 0.21.3 now, so that split is history.

**`.mbti` files are generated.** Run `moon info` and read the diff; never edit them by hand. `moon info && moon fmt` before committing is the habit. If nothing in a `.mbti` changed, your change did not alter the public surface.

**Never commit a key.** You never need one to run the tests. `web/runs/` holds run output and is gitignored, but see `SECURITY.md` before sharing anything from it.

## Commits

Messages follow `<type>(<scope>): 描述`, with `feat` / `fix` / `docs` / `test` / `chore` / `refactor`. Write the body about *why*: the diff already says what.

A pre-commit hook runs `moon check`. Enable it once per clone:

```bash
git config core.hooksPath .githooks
```

## Before opening a pull request

`make ci` is the baseline: it is what CI runs, so if it passes locally the workflow should pass too. Then run `make e2e` if your change can affect the page (CI does not run it). Say in the PR which ones you ran.

One exception worth knowing: a local pass can come from leftovers. The merge that turned the two modules into one left `web/_build/` behind, and the server's ssg path resolved to that stale binary here and to nothing on a fresh checkout: the same commit was green locally and 500 on CI. If your change moves where build outputs land, or renames a package, check it in a clone:

```bash
git clone . /tmp/clean && cd /tmp/clean && make ci
```

| your change | run |
| --- | --- |
| anything | `make ci` |
| the page or the server | `make ci e2e` |

If you changed anything user-visible, add a line to `CHANGELOG.md` under `Unreleased`.

Browser tests are the flakiest part of the suite. If `scripts/web-e2e.sh` fails, read the output snippet it prints first, and check whether it is a timing problem before assuming your change broke something. It runs against a real Chromium and leaves no state behind on success.
