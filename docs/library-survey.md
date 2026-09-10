# Mooncakes survey: LLM client libraries for MoonBit

Question: is there a candidate library on Mooncakes that would speed up
building an OpenAI-compatible client in MoonBit?

Answer: yes, several — the ecosystem is over-supplied rather than
under-supplied. The real work is picking one and knowing where it stops.

> **Outcome (later, 2026-09-10): the dependency was removed again.** The survey
> below is kept as written, because the reasoning about *candidate selection* is
> still the useful part. But the package it settled on was dropped once two
> things became clear: its streaming entry point could not be used anyway (see
> the gaps section), and a single-file client turned out to be small enough that
> the library was not earning its place. `faceoff` now depends on nothing but
> `moonbitlang/async`. Read the rest as a record of the investigation, not as the
> current dependency list.

## How this was checked

Followed the evidence chain in `clyzhi-moonwell-spring` → `references/mooncakes.md`:
`moon search` → `moon add` into a scratch module → `moon tree` → read
`moon.mod` and the generated `.mbti`. Nothing below is inferred from a
familiar package name.

```bash
moon search json http client openai llm fetch curl
moon add <pkg>@<version>      # in a disposable module
moon tree
```

Toolchain: moon `0.1.20260904`, `moonbitlang/async` `0.20.1`.

## Candidates

| package | version | what it is | preferred target | direct deps |
| --- | --- | --- | --- | --- |
| `DC-Z-lab/moonllm` | 0.1.0 | OpenAI-compatible chat/streaming/tools/multimodal; also has `chat_anthropic`; ships example REPLs | native | `oboard/mio`, `moonbitlang/async` |
| `mizchi/llm` | 0.3.2 | multi-provider (`OpenAI`/`OpenRouter`/`Ollama`/`Cloudflare`/custom) plus a full agent layer (loops, skills, tools) | js | `mizchi/x`, `moonbitlang/async` |
| `tonyfettes/openai` | 0.1.1 | typed OpenAI chat completions + streaming; transport behind an injectable `HttpClient` trait | wasm | `moonbitlang/x` |
| `co63oc/moonbit_promptkit` | 0.1.7 | broad OpenAI-compatible SDK (chat, embeddings, images, audio, MCP) | native | `moonbitlang/async`, `moonbitlang/x` |
| `marianoguerra/llm` | 0.3.1 | dialect-agnostic IR with one wire mapping per provider and a pluggable transport | native | `moonbitlang/async` |
| `trkbt10/llm_interop` | 0.3.0 | protocol translation between providers | wasm | `mizchi/x`, `moonbitlang/async`, subprocess |

Also present, not evaluated in depth: `QuietlyChan/moonai` (provider-neutral
SDK), `morning-start/prism` (protocol middleware), `eanzhao/pi-moonbit`
(multi-provider CLI agent), `moonbit-community/codex`, `marianoguerra/mcp-client`.

Supporting pieces that showed up in the search and are worth knowing:

- `moonbitlang/async/http` — HTTP client *and* `Server`; enough to build both
  the client and a local mock endpoint for tests.
- `moonbitlang/core/json` — JSON is in the standard library; `gmlewis/jsonutil`
  is explicitly deprecated in favour of it.
- `oboard/mio`, `oboard/reqbest` — async HTTP libraries several of the above
  build on.

## What was chosen, and why

`DC-Z-lab/moonllm`:

- native is the first-class target, which matches a CLI client.
- the request/response types are exactly the OpenAI wire shape
  (`ChatRequest` with chained setters, `Message`, `ChatResponse`, `Usage`).
- real HTTP over `oboard/mio` — no subprocess, no `curl` dependency.
- one-shot decoding, retries, and error types come for free.

`mizchi/llm` would have been the choice for a multi-provider or agent-shaped
tool, and `tonyfettes/openai` for the cleanest pure-type surface, but both pull
in more than a single-endpoint client needs (agent loop / a `wasm`-first
transport).

## Gaps found while integrating

1. **moonllm's streaming callback is synchronous.**
   `Client::chat_stream(request, on_delta)` takes `(String) -> Unit`, and
   `chat_stream_full` calls it from inside an async function. A sync callback
   cannot call `@stdio.stdout.write`, which is async, so it cannot write
   fragments to stdout as they arrive — it can only buffer or use `println`
   per fragment. moonllm's own `examples/chat_repl` works around this by
   calling `println` on every fragment.

   Workaround used here: keep moonllm for request construction and the
   one-shot path, and run the streaming path directly over
   `moonbitlang/async/http` (`post_stream` → read lines → parse SSE → async
   `stdout.write`). `parse_sse_line` is a pure function, so the framing logic is
   still unit-testable.

2. **No sync stdout write exists in the standard library.**
   `println` is the only sync console primitive; `print` is not defined.
   Everything else goes through async `@io.Writer`.

3. **native builds need `MOON_CC` on this machine.**
   Plain `moon build --target native` fails with
   `new native backend requires a C compiler/linker driver` and
   `failed to resolve native archiver executable /usr/bin/lib.exe`, even with
   `clang`/`gcc`/`ar` on `PATH`. `MOON_CC=gcc` fixes it. This matches the
   entry already recorded in the moonwell failure index; it is an environment
   issue, not a property of the library.

4. **`Bytes::to_unchecked_string()` is not a UTF-8 decode.** moonllm reads
   non-2xx bodies with `read_all().binary().to_unchecked_string()`, which
   reinterprets raw bytes as UTF-16 code units. On this gateway the 429 body
   (Chinese) came back as `≻牥潲≻笺挢摯≥...` mojibake. `&Data::text()` decodes
   UTF-8 correctly. Copied that pattern early and had to fix it; the mock server
   now sends a non-ASCII error body so the smoke test catches it.

5. **`@fs.write_file` does not create by default.** Omitting `create` resolves
   `create_mode` to `TruncateExisting`, so writing a new results file fails with
   `No such file or directory`. Needs `create_mode=@fs.CreateOrTruncate`.

6. **`pub extend` noise.** `derive(Eq)`/`derive(Debug)` on public types emits
   `implicit_impl_as_method` warnings unless the methods are also re-exported
   via `pub extend`. Applied to `SseEvent`, `Settings`, `TokenUsage`, `StreamPart`
   and `Case`.
