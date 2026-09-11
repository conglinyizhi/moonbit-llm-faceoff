///|
/// 一段页面数据：一道用例、两个模型，其中一个失败。
fn sample_page_data_json() -> String {
  let text =
    #|{"source":"t.jsonl","models":["mock-a","mock-b"],
    #| "summaries":[{"model":"mock-a","runs":1,"failures":0,"truncated":0,"retried":0,
    #|   "metrics":{"ttft_ms":{"n":1,"median":1,"min":1,"max":1}}}],
    #| "cases":[{"id":"math-short","answers":[
    #|   {"model":"mock-a","ok":true,"total_ms":43,"ttft_ms":1,"completion_tokens":9,
    #|    "reasoning_tokens":4,"content":"391","reasoning":"weighing the question","error":null},
    #|   {"model":"mock-b","ok":false,"total_ms":0,"completion_tokens":0,
    #|    "reasoning_tokens":0,"content":"","error":"http 500: upstream exploded"}]}]}
  text
}

///|
test "page data carries the reasoning text, not only its token count" {
  match parse_page_data(sample_page_data_json()) {
    Err(message) => fail("parse failed: " + message)
    Ok(data) => {
      assert_eq(data.cases.length(), 1)
      let answers = data.cases[0].answers
      assert_eq(answers.length(), 2)
      assert_eq(answers[0].model, "mock-a")
      assert_eq(answers[0].content, "391")
      // 这一条是这次改动的全部意义：对比两个模型时要比的是思考全文，
      // 「思考了 4 个 token」回答不了那个问题。
      assert_eq(answers[0].reasoning, "weighing the question")
      assert_eq(answers[0].reasoning_tokens, 4)
      // 失败的那条本来就没有思考，解析成空串，不是崩掉
      assert_false(answers[1].ok)
      assert_eq(answers[1].reasoning, "")
      assert_eq(answers[1].error, Some("http 500: upstream exploded"))
    }
  }
}

///|
test "page data written without a reasoning field still parses" {
  let text =
    #|{"cases":[{"id":"c","answers":[{"model":"m","ok":true,"content":"x"}]}]}
  match parse_page_data(text) {
    Err(message) => fail("parse failed: " + message)
    Ok(data) => {
      assert_eq(data.cases[0].answers[0].content, "x")
      assert_eq(data.cases[0].answers[0].reasoning, "")
    }
  }
}

///|
/// 服务端转发的 live 行：字段名和 bench 写出来的完全一致，中间没有第二次
/// 翻译——页面读错一个名字就会变成「实时行永远静止」。
test "live progress decodes the event bench writes" {
  let line =
    #|{"event":"tick","t":1789116889397,"model":"mock-a","case":"stt-01","repeat":1,"maxTokens":512,"elapsedMs":1420,"phase":"content","tokPerS":61.25,"frags":44,"chars":187}
  let decoded = @json.parse(line) catch { _ => fail("bad json") }
  let live = match parse_live(Some(decoded), Some(240.0)) {
    None => fail("live did not decode")
    Some(live) => live
  }
  assert_eq(live.event, "tick")
  assert_eq(live.model, "mock-a")
  assert_eq(live.case_id, "stt-01")
  assert_eq(live.repeat, 1)
  assert_eq(live.phase, "content")
  assert_eq(live.tok_per_s, 61.25)
  assert_eq(live.chars, 187)
  assert_eq(live.tokens, 44)
  assert_eq(live.max_tokens, 512)
  assert_eq(live.age_ms, 240.0)
}

///|
/// case_done 少了 tick 才有的那几个字段，缺的按 0 算；完全没有 live 的老运行
/// 也不能让页面崩掉。
test "live progress tolerates a missing field and a missing payload" {
  let done =
    #|{"event":"case_done","model":"mock-a","case":"stt-01","repeat":0,"ok":true,"maxTokens":512,"totalMs":2000,"completionTokens":120,"tokPerS":96.0}
  let decoded = @json.parse(done) catch { _ => fail("bad json") }
  let live = match parse_live(Some(decoded), None) {
    None => fail("live did not decode")
    Some(live) => live
  }
  assert_eq(live.event, "case_done")
  assert_eq(live.chars, 0)
  assert_eq(live.age_ms, 0.0)
  assert_eq(parse_live(None, None) is None, true)
  assert_eq(parse_live(Some(Json::object({})), Some(1.0)) is None, true)
}
