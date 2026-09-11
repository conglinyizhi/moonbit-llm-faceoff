///|
fn ok_run(
  model : String,
  case_id : String,
  total_ms : Double,
  ttft_ms : Double?,
  completion : Int,
  reasoning : Int,
  attempts : Int,
) -> RunResult {
  {
    model,
    case_id,
    repeat: 0,
    attempts,
    ok: true,
    error: None,
    ttft_ms,
    ttfc_ms: None,
    total_ms,
    prompt_tokens: 10,
    completion_tokens: completion,
    reasoning_tokens: reasoning,
    content_chars: 5,
    reasoning_chars: 40,
    finish_reason: Some("stop"),
    content: "hello",
    reasoning: "thinking",
  }
}

///|
fn failed_run(model : String, case_id : String, message : String) -> RunResult {
  {
    model,
    case_id,
    repeat: 0,
    attempts: 2,
    ok: false,
    error: Some(message),
    ttft_ms: None,
    ttfc_ms: None,
    total_ms: 12.0,
    prompt_tokens: 0,
    completion_tokens: 0,
    reasoning_tokens: 0,
    content_chars: 0,
    reasoning_chars: 0,
    finish_reason: None,
    content: "",
    reasoning: "",
  }
}

///|
test "stats handle odd and even counts" {
  let odd = Stats::of([3.0, 1.0, 2.0])
  match odd {
    Some(stats) => {
      assert_eq(stats.n, 3)
      assert_eq(stats.median, 2.0)
      assert_eq(stats.min, 1.0)
      assert_eq(stats.max, 3.0)
      assert_eq(stats.mean, 2.0)
    }
    None => fail("expected stats")
  }
  let even = Stats::of([4.0, 1.0, 3.0, 2.0])
  match even {
    Some(stats) => assert_eq(stats.median, 2.5)
    None => fail("expected stats")
  }
  match Stats::of([]) {
    None => ()
    Some(_) => fail("expected no stats for an empty input")
  }
}

///|
test "throughput is derived from tokens and timing" {
  // 100 tokens in 1s, first token at 200ms => 100 / 0.8s after the wait.
  let result = ok_run("m", "c", 1000.0, Some(200.0), 100, 40, 1)
  match result.e2e_tok_per_s() {
    Some(value) => assert_true((value - 100.0).abs() < 0.0001)
    None => fail("expected end-to-end throughput")
  }
  match result.decode_tok_per_s() {
    Some(value) => assert_true((value - 125.0).abs() < 0.0001)
    None => fail("expected decode throughput")
  }
  match result.reasoning_ratio() {
    Some(value) => assert_true((value - 0.4).abs() < 0.0001)
    None => fail("expected a reasoning ratio")
  }
}

///|
test "failed runs have no throughput" {
  let failed = failed_run("m", "c", "boom")
  assert_eq(failed.e2e_tok_per_s(), None)
  assert_eq(failed.decode_tok_per_s(), None)
  assert_eq(failed.reasoning_ratio(), None)
}

///|
test "summarize keeps failures out of the statistics" {
  let results = [
    ok_run("a", "c1", 100.0, Some(10.0), 20, 5, 1),
    ok_run("a", "c2", 300.0, Some(30.0), 40, 10, 1),
    failed_run("a", "c3", "http 429"),
    ok_run("b", "c1", 900.0, Some(90.0), 200, 150, 1),
  ]
  let summary = summarize("a", results)
  assert_eq(summary.runs, 3)
  assert_eq(summary.failures, 1)
  assert_eq(summary.retried, 1)
  match summary.total_ms {
    Some(stats) => {
      assert_eq(stats.n, 2)
      assert_eq(stats.median, 200.0)
    }
    None => fail("expected totals")
  }
  let other = summarize("b", results)
  assert_eq(other.runs, 1)
  assert_eq(other.failures, 0)
}

///|
test "summarize counts truncated replies" {
  let long = {
    ..ok_run("a", "c1", 100.0, Some(10.0), 20, 5, 1),
    finish_reason: Some("length"),
  }
  let summary = summarize("a", [long])
  assert_eq(summary.truncated, 1)
}

///|
test "summarize_all preserves model order" {
  let summaries = summarize_all(["b", "a"], [
    ok_run("a", "c", 1.0, Some(1.0), 1, 0, 1),
    ok_run("b", "c", 2.0, Some(1.0), 1, 0, 1),
  ])
  assert_eq(summaries.length(), 2)
  assert_eq(summaries[0].model, "b")
  assert_eq(summaries[1].model, "a")
}

///|
test "a run serializes with its timing and text" {
  let json = ok_run("m", "c", 1234.0, Some(56.0), 7, 3, 2).to_json()
  let text = json.stringify()
  assert_true(text.contains("\"model\":\"m\""))
  assert_true(text.contains("\"attempts\":2"))
  assert_true(text.contains("\"ttft_ms\":56"))
  assert_true(text.contains("\"content\":\"hello\""))
}

///|
test "a failed run serializes null timings" {
  let text = failed_run("m", "c", "http 429").to_json().stringify()
  assert_true(text.contains("\"ok\":false"))
  assert_true(text.contains("\"ttft_ms\":null"))
}

///|
test "results round-trip through json" {
  let original = ok_run("m", "c", 1234.0, Some(56.0), 7, 3, 2)
  let restored = RunResult::from_json(original.to_json())
  assert_eq(restored.model, "m")
  assert_eq(restored.case_id, "c")
  assert_eq(restored.attempts, 2)
  assert_eq(restored.ok, true)
  assert_eq(restored.ttft_ms, Some(56.0))
  assert_eq(restored.total_ms, 1234.0)
  assert_eq(restored.completion_tokens, 7)
  assert_eq(restored.reasoning_tokens, 3)
  assert_eq(restored.content, "hello")
  assert_eq(restored.reasoning, "thinking")
}

///|
test "a failed run round-trips too" {
  let failed = failed_run("m", "c", "http 429")
  let restored = RunResult::from_json(failed.to_json())
  assert_eq(restored.ok, false)
  assert_eq(restored.error, Some("http 429"))
  assert_eq(restored.ttft_ms, None)
}

///|
test "parse_results skips blank and malformed lines" {
  let text =
    #|{"model": "a", "case_id": "c"}
    #|
    #|{oops not json
    #|{"model": "b", "case_id": "c", "ok": true}
  let results = parse_results(text)
  assert_eq(results.length(), 2)
  assert_eq(results[0].model, "a")
  assert_eq(results[1].model, "b")
  assert_eq(results[1].ok, true)
}

///|
test "missing fields degrade to zero values" {
  let restored = RunResult::from_json(@json.parse("{\"model\": \"x\"}"))
  assert_eq(restored.model, "x")
  assert_eq(restored.ok, false)
  assert_eq(restored.ttft_ms, None)
  assert_eq(restored.finish_reason, None)
  assert_eq(restored.attempts, 1)
  assert_eq(restored.total_ms, 0.0)
  assert_eq(restored.content, "")
}

///|
test "page data carries sources, summaries and answers" {
  let results = [
    ok_run("a", "c1", 100.0, Some(10.0), 20, 5, 1),
    ok_run("b", "c1", 200.0, Some(20.0), 40, 10, 1),
  ]
  let text = page_data_json("t.jsonl", ["a", "b"], results).stringify()
  assert_true(text.contains("\"source\":\"t.jsonl\""))
  assert_true(text.contains("\"model\":\"a\""))
  assert_true(text.contains("\"metrics\""))
  assert_true(text.contains("\"ttft_ms\""))
  assert_true(text.contains("\"cases\""))
  assert_true(text.contains("\"content\":\"hello\""))
  // 思考全文也在里面：页面上要和答案一起看
  assert_true(text.contains("\"reasoning\":\"thinking\""))
}

///|
test "page data records a missing answer as null" {
  // model b never ran c1, so its slot is null rather than absent
  let text = page_data_json("t.jsonl", ["a", "b"], [
    ok_run("a", "c1", 100.0, Some(10.0), 20, 5, 1),
  ]).stringify()
  assert_true(text.contains("\"answers\":[{"))
  assert_true(text.contains(",null]"))
}

///|
test "the metric key list is the documented contract" {
  let names = metric_names()
  assert_eq(names.length(), 9)
  assert_true(names.contains("ttft_ms"))
  assert_true(names.contains("reasoning_ratio"))
  assert_true(names.contains("decode_tok_per_s"))
}
