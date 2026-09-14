# moonbit-llm-faceoff-web

The web half of [faceoff](https://github.com/conglinyizhi/moonbit-llm-faceoff):
a page that runs a case set against several OpenAI-compatible models, shows the
answers side by side, and lets you annotate them — plus the static report
generator for the same data.

A separate module from `conglinyizhi/moonbit-llm-faceoff` on purpose: the page
consumes the benchmark CLI's exported `data.json` instead of calling into the
library, which keeps the statistics in one implementation.

## Packages

- `shared` — parsing, metrics, diff and rendering, used by both the page and the
  report. This is the part worth depending on: `moon add
  conglinyizhi/moonbit-llm-faceoff-web`, then import
  `conglinyizhi/moonbit-llm-faceoff-web/shared`.
- `cmd/server` — the local server the page talks to (`/api/meta`, runs, case
  sets, presets, annotations).
- `cmd/ssg` — the static report generator.
- `cmd/app` — the page itself (Rabbita).

## Running it

Cloning the repository is still the way: the page build also needs
`scripts/build-web.mbtx` and the Makefile, which sit outside this module.

```bash
make dev         # dev server: rebuilds on change
make serve       # build once, then serve
make serve-demo  # mock endpoint + demo data + page, for a quick look
```

The main repository's README has the full picture, including how to point the
page at a real gateway.
