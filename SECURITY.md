# Security

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting on this repository
(**Security** tab → **Report a vulnerability**) rather than opening a public
issue. If you are not sure whether something counts as a vulnerability, report
it anyway — the answer is cheap.

## Supported versions

Only the latest `0.1.x`. This project is pre-1.0 and makes breaking changes
between minor versions; see `CHANGELOG.md`.

## How this project handles your API key

The claims below were checked by running the server with a canary key, exercising
every path, and then searching the whole working tree for that key.
`scripts/server-api.mbtx` asserts them.

A key reaches the server one of two ways, and both behave the same once it does:

- **From the environment** — `MOONLLM_API_KEY` (falling back to
  `OPENAI_API_KEY`), or `--api-key` on the CLI.
- **Typed into the page** — the `API key` field in the web UI, sent to the local
  server as part of the run request. It is a `password` input; the value is never
  written back into the page, into a URL, or into `localStorage`. It lives in the
  tab's memory until you close it.

Whichever way it arrives:

- It is handed to the child `bench` process through the **environment, not its
  command line**, so it does not show up in `ps`.
- It is sent to exactly one destination: the endpoint at `MOONLLM_BASE_URL`, or
  the `baseUrl` supplied with that run. There is no telemetry and no second
  service.
- The server never sends a key *to* the browser. `GET /api/meta` reports only
  whether one is configured (`"hasKey": true|false`). The one path by which a
  fragment can reach the page is a masked upstream error body, described below.
- `web/runs/<id>/request.json` has its `apiKey` field removed before it is
  written, so a key typed into the page does not end up in the run directory.
- The "copy share link" button builds a URL that carries the configuration but
  never the key.

### Upstream error bodies are redacted

The client surfaces a non-2xx response body as `http <status>: <body>`, and that
string is then persisted: it goes to the bench run log, to
`web/runs/<id>/runs.jsonl` and `data.json`, and out to the browser. Some gateways
echo the request headers in their error text, so a body like
`bad authorization: Bearer <key>` would otherwise put the key in all of those
places.

The configured key is therefore masked at the point where the body becomes part
of an error, so it never reaches a log, a run directory or a page intact:

```text
http 401: {"error":{"message":"bad authorization: Bearer sk***3a"}}
```

The first two and last two characters stay, matching what provider dashboards do
(`sk-...ef`). That is enough for whoever reads the error to tell *which* key was
used — the reason for logging it at all — and not enough to use it. Keys shorter
than 12 characters are masked whole: showing four characters of an
eight-character secret gives away half of it.

`scripts/smoke.mbtx` asserts this end to end. The bundled mock endpoint echoes the
`Authorization` header back on a 401, exactly as a careless gateway would, so
the test fails if the masking stops working.

### What the server will hand out

`GET /api/runs/<id>/<name>` serves a fixed allowlist of files from that run's
directory: `runs.jsonl`, `data.json`, and a `report.html` generated on demand by
the static-report generator. Nothing else — the name is matched against the list
rather than joined onto a path, so `..` cannot escape it, and
`scripts/server-api.mbtx` checks that.

`GET /api/runs/<id>/context` is the same shape: it reads that run's `request.json`
(with the key already scrubbed before it was written) and `cases.jsonl`, and
serves the result as JSON. `scripts/server-api.mbtx` asserts the key is not in
it.

The consequence is that anything able to reach the server can read any run's
results. That is the same trust boundary as the rest of the server (loopback, no
authentication — see below), not a new one, but it is worth knowing before you
put this behind a proxy.

## What never enters the repository

This repository is public. The pages are built to be used with material that is
not, and the boundary is drawn in `.gitignore`:

- `web/cases/` — case sets. They hold the prompts you actually care about.
- `web/presets.json` — model and parameter combinations.
- `web/runs/` — every run directory: prompts sent, answers received, `runs.jsonl`,
  and the annotations you typed while reading them.
- `docs/real-gateway-run.md` — the output of the real-gateway smoke test, which
  names your endpoint and quotes its replies.

Ignore rules are the mechanism, but they are not the only reason these stay out:
**these files are user data and are not meant to be committed even when they look
harmless.** Placeholder text ("compute 17 x 23") reads fine in a screenshot and
still has no business in a published history. If you add a path that holds
personal material, add it here and to `.gitignore` in the same change, and check
with `git status --ignored` that it is ignored rather than merely untracked.

Before publishing anything that a run produced — a report, an excerpt, a
screenshot — read it. A model's answer can echo the prompt, and the prompt is
often the part you did not mean to share.

## Threat model

This is a local developer tool, not a service. Deliberately:

- The web server has **no authentication** and runs whatever benchmark the
  caller asks for. It binds to `127.0.0.1` explicitly, and it is not designed to
  be reachable from a network. Do not put it behind a reverse proxy on a public
  interface.
- It runs the harness in a subprocess with your environment, so anyone who can
  reach the server can spend your API budget.
- Benchmark runs execute several requests against a paid endpoint in parallel.
  Watch your limits if you point it at a production key.
