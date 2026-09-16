# Using the library

The `bench` package is usable on its own, and so is the client.

## Import

```bash
moon add conglinyizhi/moonbit-llm-faceoff
```

Declare it with an explicit alias in your own `moon.pkg` (the module path ends in `faceoff`, and a hyphenated segment cannot serve as a default alias): `"conglinyizhi/moonbit-llm-faceoff" @faceoff`.

```moonbit
// one-shot; ask_outcome is the same request, keeping what the reply says about
// itself, because an empty answer is not a bug report and the stop reason and
// token counts explain it
let reply = @faceoff.ask(settings, "用一句话说明什么是航空母舰")
let outcome = @faceoff.ask_outcome(settings, prompt)
// outcome.content, outcome.reasoning, outcome.usage, outcome.finish_reason

// streaming, with reasoning fragments separated from the answer
let outcome = @faceoff.stream_parts(settings, prompt, async fn(part) {
  match part {
    Content(text) => handle_answer(text)
    Reasoning(thought) => handle_thought(thought)
  }
})

// benchmarking
let cases = @bench.parse_cases(text)
let results = @bench.run_bench(settings, models, cases, options, on_start, on_part, on_result)
println(@bench.format_summaries(@bench.summarize_all(models, results)))
```

## Entry points

`settings` comes from `@faceoff.Settings::from_env(env)`. `@bench.parse_results` reads a run log back, `RunResult::to_json` / `RunResult::from_json` round-trip a single attempt, and `page_data_json` builds the document the page renders. Errors are flattened into `ClientError` (`Transport` / `Status` / `Decode`) so callers do not need to import the transport packages.

## See also

- [`docs/cli.md`](cli.md): the two CLIs, which are thin wrappers over exactly these calls.
- [`docs/web.md`](web.md): the page, the server and the report generator that consume the same data.
- [`docs/library-survey.md`](library-survey.md): the Mooncakes survey of LLM client libraries, the gaps found while integrating one of them, and why that dependency was removed again.
