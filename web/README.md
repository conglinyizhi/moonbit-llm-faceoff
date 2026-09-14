# web/ — the page and its server

The web half of [faceoff](https://github.com/conglinyizhi/moonbit-llm-faceoff):
a page that runs a case set against several OpenAI-compatible models, shows the
answers side by side, and lets you annotate them — plus the local server it talks
to and the static report generator for the same data.

This is part of the one `conglinyizhi/moonbit-llm-faceoff` module. It builds from
the root `moon.mod` and is covered by `moon check` (both targets) and
`moon test --target native` at the repository root. `web/` does not call into the
library: it consumes the `data.json` that the `bench` CLI exports, which keeps
the statistics in a single implementation.

## Packages

- `shared` — parsing, metrics, diff and rendering, used by both the page and the
  report. This is the part worth depending on: `moon add
  conglinyizhi/moonbit-llm-faceoff`, then import
  `conglinyizhi/moonbit-llm-faceoff/web/shared`.
- `cmd/app` — the page itself (Rabbita, `js` target).
- `cmd/server` — the local server the page talks to (`/api/meta`, runs, case
  sets, presets, annotations; `native`).
- `cmd/ssg` — the static report generator (`native`).
- `cmd/build` — the page build entry point (`native`): it runs `ssg` and `app`,
  then copies the shell into `out/`.
- `styles` — `site.scss`, compiled by precss.

## Building and running it

```bash
make web         # export web/data.json from bench, then build the page into web/out/
make serve       # build the page, then serve it from web/ (Ctrl-C to stop)
make dev         # the same, but rebuild on change
make serve-demo  # mock endpoint + demo data + page, for a quick look
```

The page build is a package in this module, so it can also be run on its own:

```bash
moon run --target native web/cmd/build    # → web/out/
```

From a checkout, `make web` (i.e. `scripts/build-web.mbtx`) does one more step
first: it runs `bench --from-json` to write `web/data.json`, the document the page
and the report render. That step needs the `bench` CLI; the page build itself
does not.

Serving by hand is the same thing without the wrapper — and the server must be
started **from `web/`**, because it resolves `out/`, `runs/`, `cases/` and
`presets.json` relative to its working directory:

```bash
cd web && ../_build/native/debug/build/web/cmd/server/server.exe
# → http://127.0.0.1:8137/
```

Started from the repository root it answers `/api/meta` and then 404s every page
request; `make serve` does the `cd` for you.

## Where things live

| path | what |
| --- | --- |
| `web/out/` | the built page and the static report |
| `web/data.json` | page data exported from a run — gitignored |
| `web/runs/` | one directory per run — gitignored |
| `web/cases/` | your case sets, one `<name>.jsonl` each — gitignored |
| `web/presets.json` | your model + parameter combinations — gitignored |
| `web/shell/` | the `index.html` shell for the page |

Binaries land under the repository root, at
`_build/native/debug/build/web/cmd/<name>/<name>.exe`.

The root [`README.md`](../README.md) has the full picture, including how to point
the page at a real gateway and what each command does.
