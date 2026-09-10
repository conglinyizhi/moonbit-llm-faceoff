///|
/// 手搭一份小数据，不读文件：shared 必须与 target 无关，测试也不该碰文件系统。
fn sample_data() -> PageData {
  {
    source: "runs/run-1/cases.jsonl",
    models: ["mock-a", "mock-b"],
    summaries: [
      {
        model: "mock-a",
        runs: 2,
        failures: 0,
        truncated: 0,
        retried: 0,
        metrics: { "ttft_ms": { n: 2, median: 2.0, min: 2.0, max: 2.0, } },
      },
      {
        model: "mock-b",
        runs: 2,
        failures: 1,
        truncated: 1,
        retried: 3,
        metrics: { "ttft_ms": { n: 2, median: 0.5, min: 0.0, max: 1.0, } },
      },
    ],
    cases: [
      {
        id: "math-short",
        answers: [
          {
            model: "mock-a",
            ok: true,
            total_ms: 43.0,
            completion_tokens: 9,
            reasoning_tokens: 4,
            content: "Hello from the mock server.",
            error: None,
          },
          {
            model: "mock-b",
            ok: false,
            total_ms: 0.0,
            completion_tokens: 0,
            reasoning_tokens: 0,
            content: "",
            error: Some("http 500: upstream exploded"),
          },
        ],
      },
    ],
  }
}

///|
test "results_markdown renders a comparison table with one column per model" {
  let md = results_markdown(sample_data())
  assert_true(md.contains("| 指标 | mock-a | mock-b |"))
  assert_true(md.contains("| --- | --- | --- |"))
  assert_true(md.contains("首 token (ms)"))
  // 有单位的指标带单位，没单位的不该出现一个空括号
  assert_true(md.contains("| 输出 token |"))
  assert_false(md.contains("输出 token ()"))
  // 数值走的是和页面同一个格式化函数
  assert_true(md.contains("2 ms"))
}

///|
test "results_markdown carries the run counts the metric table omits" {
  let md = results_markdown(sample_data())
  assert_true(md.contains("运行："))
  assert_true(md.contains("mock-a 2 次（失败 0，截断 0，重试 0）"))
  assert_true(md.contains("mock-b 2 次（失败 1，截断 1，重试 3）"))
}

///|
test "results_markdown shows content for a good answer and the error for a bad one" {
  let md = results_markdown(sample_data())
  assert_true(md.contains("## 用例 `math-short`"))
  assert_true(md.contains("### mock-a"))
  assert_true(md.contains("43 ms · 9 token（推理 4）"))
  assert_true(md.contains("Hello from the mock server."))
  assert_true(md.contains("### mock-b"))
  assert_true(md.contains("失败：http 500: upstream exploded"))
  // 失败的回答不该伪造一个代码块出来
  assert_false(md.contains("```text\n\n```"))
}

///|
test "results_markdown includes the data source and survives empty data" {
  assert_true(
    results_markdown(sample_data()).contains("runs/run-1/cases.jsonl"),
  )
  let empty = results_markdown(empty_page_data())
  assert_true(empty.contains("# 模型对比"))
  // 没有模型就不该吐出一个空表头
  assert_false(empty.contains("| 指标 |"))
}
