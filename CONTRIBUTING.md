# Contributing

Thanks for looking. This is a small project, so the notes below are the things
that will actually bite you rather than a process document.

## Getting set up

You need the [MoonBit toolchain](https://www.moonbitlang.com/download/) and a C
compiler (`gcc` or `clang`). Nothing else: no API key, no Python, and no Node
unless you want to run the browser test.

On Linux, name the C compiler explicitly. Without it, native builds fail looking
for an archiver at `/usr/bin/lib.exe` that does not exist:

```bash
export MOON_CC=gcc
```

## Running things

```bash
make                # list every target
make ci             # deps, type check, unit tests, smoke, build the page
make e2e            # the browser test as well (needs chromium, slow)
make demo           # ask a question, then benchmark two models — no API key
```

Those are thin wrappers over the raw commands, which you can also run directly:

```bash
moon check --target native
moon test --target native
bash scripts/smoke.sh
bash scripts/web-e2e.sh
bash web/build.sh
```

The first four each start their own mock endpoint, so none of them need a key or
network access. Against a real endpoint the knobs are `MOONLLM_BASE_URL`,
`MOONLLM_MODEL` and `MOONLLM_API_KEY`; the README has the details.

## House rules

**No Python.** Test utilities are MoonBit scripts (`.mbtx`) run with
`moon run <file>.mbtx --target native`. The `--target native` is not optional:
the default target is wasm, which cannot open a socket. Keeping the test path on
the same toolchain as the code is the whole point.

**Two modules, on purpose.** The root module and `web/` are separate MoonBit
modules, and `web/` deliberately does not depend on the root. The reason is a
version conflict: the library pins `moonbitlang/async` 0.20.1 while Rabbita
requires 0.21.x, and one workspace can only hold one version of a dependency.
`web/` therefore consumes `bench`'s exported `data.json` rather than calling
`bench` directly, so there is still only one implementation of the statistics.
Merging the modules means upgrading the library's `async` first — that is a real
change with its own risks, not a cleanup.

**`.mbti` files are generated.** Run `moon info` and read the diff; never edit
them by hand. `moon info && moon fmt` before committing is the habit. If nothing
in a `.mbti` changed, your change did not alter the public surface.

**Never commit a key.** You never need one to run the tests. `web/runs/` holds
run output and is gitignored, but see `SECURITY.md` before sharing anything from
it.

## Commits

Messages follow `<type>(<scope>): 描述`, with `feat` / `fix` / `docs` / `test` /
`chore` / `refactor`. Write the body about *why*: the diff already says what.

A pre-commit hook runs `moon check`. Enable it once per clone:

```bash
git config core.hooksPath .githooks
```

## Before opening a pull request

`make ci` is the baseline — it is what CI runs, so if it passes locally the
workflow should pass too. Then run `make e2e` if your change can affect the page
(CI does not run it). Say in the PR which ones you ran.

| your change | run |
| --- | --- |
| anything | `make ci` |
| the page or the server | `make ci e2e` |

If you changed anything user-visible, add a line to `CHANGELOG.md` under
`Unreleased`.

Browser tests are the flakiest part of the suite. If `scripts/web-e2e.sh` fails,
read the output snippet it prints first, and check whether it is a timing
problem before assuming your change broke something. It runs against a real
Chromium and leaves no state behind on success.
