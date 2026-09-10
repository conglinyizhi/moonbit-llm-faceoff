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

- The key comes from `MOONLLM_API_KEY` (falling back to `OPENAI_API_KEY`) or the
  `--api-key` flag. It is handed to the child `bench` process through the
  environment.
- It is sent to exactly one destination: the endpoint at `MOONLLM_BASE_URL`.
  There is no telemetry and no second service.
- The page never receives the key. `GET /api/meta` reports only whether a key is
  configured (`"hasKey": true|false`); the key stays on the server's side of the
  request boundary, and the browser talks to the server, not to the endpoint.
- Run output under `web/runs/<id>/` holds the request payload, the metrics and
  the model output. It does not hold the key.

### Known limitation: an upstream error can echo the key back

The client surfaces a non-2xx response body verbatim as `http <status>: <body>`,
and that string is persisted to `web/runs/<id>/runs.jsonl` and `data.json` and is
then served to the browser.

If your endpoint echoes the request headers in its error text — some gateways do
— the key lands in those files and on the page. This is reproducible against the
bundled mock endpoint, which answers a bad key with
`bad authorization: Bearer <key>`.

Until this is redacted, treat anything under `web/runs/` as potentially holding
a key: check a run directory, or a screenshot of an error, before sharing it.
Redacting the configured key from error text before it is persisted is the
intended fix.

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
