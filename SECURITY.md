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

### Upstream error bodies are redacted

The client surfaces a non-2xx response body as `http <status>: <body>`, and that
string is then persisted: it goes to the bench run log, to
`web/runs/<id>/runs.jsonl` and `data.json`, and out to the browser. Some gateways
echo the request headers in their error text, so a body like
`bad authorization: Bearer <key>` would otherwise put the key in all of those
places.

The configured key is therefore stripped from the body at the point it becomes
part of an error, so it never reaches a log, a run directory or a page:

```text
http 401: {"error":{"message":"bad authorization: Bearer ***"}}
```

`scripts/smoke.sh` asserts this end to end. The bundled mock endpoint echoes the
`Authorization` header back on a 401, exactly as a careless gateway would, so
the test fails if the redaction stops working.

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
