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

///|
/// 分位数解析：老的结果文件里只有 median（那时还没存分位数），这时四个分位
/// 都回退到中位数——历史运行不该因为工具升级就打不开。
test "metric percentiles fall back to the median when absent" {
  let legacy =
    #|{"cases":[],"summaries":[{"model":"m","runs":2,"metrics":{"ttft_ms":{"n":2,"median":12.5,"min":10,"max":15}}}]}
  match parse_page_data(legacy) {
    Err(message) => fail("parse failed: " + message)
    Ok(data) => {
      let stats = data.summaries[0].metrics.get("ttft_ms").unwrap()
      assert_eq(stats.p10, 12.5)
      assert_eq(stats.p20, 12.5)
      assert_eq(stats.p50, 12.5)
      assert_eq(stats.p99, 12.5)
      assert_eq(stats.percentile("p99"), 12.5)
      assert_eq(stats.percentile("没听说过的分位"), 12.5)
    }
  }
}

///|
test "metric percentiles decode when present" {
  let fresh =
    #|{"cases":[],"summaries":[{"model":"m","runs":9,"metrics":{"total_ms":{"n":9,"median":40,"min":38,"max":60,"p10":38.5,"p20":39,"p50":40,"p99":58}}}]}
  match parse_page_data(fresh) {
    Err(message) => fail("parse failed: " + message)
    Ok(data) => {
      let summary = data.summaries[0]
      assert_eq(summary.metric_at("total_ms", "p10"), Some(38.5))
      assert_eq(summary.metric_at("total_ms", "p20"), Some(39.0))
      assert_eq(summary.metric_at("total_ms", "p50"), Some(40.0))
      assert_eq(summary.metric_at("total_ms", "p99"), Some(58.0))
      // 没有的指标仍然是「没有」，不是 0
      assert_eq(summary.metric_at("ttft_ms", "p99") is None, true)
    }
  }
}

///|
/// 正文首尾的空白不该进页面：模型很爱在答案前后各带一串换行，`<pre>` 会把它
/// 原样渲染成一大片空白——看着就是「答案上面空了一块」
test "display text trims the blank lines models like to add" {
  assert_eq(
    display_text("\n\n  {\"result\": \"甲\"}  \n\n"),
    "{\"result\": \"甲\"}",
  )
  // 中间的空行是内容，不能动
  assert_eq(display_text("甲\n\n乙"), "甲\n\n乙")
  assert_eq(display_text(""), "")
}
