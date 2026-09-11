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
