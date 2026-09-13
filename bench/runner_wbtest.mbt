///|
/// `settings_for` 决定「一条用例这一次实际发出去的参数」。
///
/// 默认是用例级优先（用例自带 system / maxTokens / temperature 盖掉运行级的），
/// 勾了 system_override 之后反过来：运行级那条 system 赢，用例自带的被丢掉。
/// 这条链的另一端在页面上（「覆盖测试集内的 system prompt」那个勾），
/// 服务端把勾转成 bench 的 --system-override 再走到这里。
fn base_settings() -> @faceoff.Settings {
  {
    api_key: "test-key",
    base_url: "http://127.0.0.1:1/v1",
    model: "mock-a",
    system: "",
    temperature: None,
    max_tokens: None,
    timeout_ms: 60_000,
    enable_thinking: false,
    reasoning_effort: None,
  }
}

///|
fn options_with(system : String, force : Bool) -> BenchOptions {
  {
    repeats: 1,
    max_tokens: 64,
    temperature: None,
    system,
    system_override: force,
    cot_thinking: [],
    cot_effort: [],
    parallel: "serial",
    retry: 0,
    retry_backoff_ms: 0,
    pace_ms: 0,
  }
}

///|
test "system：默认用例自带的那条优先" {
  let run = Case::new("c1", "问题", system="用例的 system")
  let got = settings_for(
    base_settings(),
    "mock-a",
    run,
    options_with("运行级的 system", false),
  )
  assert_eq(got.system, "用例的 system")
}

///|
test "system：用例没带就落到运行级" {
  let run = Case::new("c1", "问题")
  let got = settings_for(
    base_settings(),
    "mock-a",
    run,
    options_with("运行级的 system", false),
  )
  assert_eq(got.system, "运行级的 system")
}

///|
test "system_override：勾上之后运行级盖掉用例自带的" {
  let run = Case::new("c1", "问题", system="用例的 system")
  let got = settings_for(
    base_settings(),
    "mock-a",
    run,
    options_with("运行级的 system", true),
  )
  assert_eq(got.system, "运行级的 system")
}

///|
test "system_override 不影响 maxTokens 与 temperature 的用例级优先" {
  let run = Case::new(
    "c1",
    "问题",
    system="用例的 system",
    max_tokens=7,
    temperature=0.9,
  )
  let got = settings_for(
    base_settings(),
    "mock-a",
    run,
    options_with("运行级的 system", true),
  )
  assert_eq(got.system, "运行级的 system")
  assert_eq(got.max_tokens, Some(7))
  assert_eq(got.temperature, Some(0.9))
}

///|
test "推理开关：只在勾中的那个模型的 settings 上出现" {
  let options : BenchOptions = {
    repeats: 1,
    max_tokens: 64,
    temperature: None,
    system: "",
    system_override: false,
    cot_thinking: ["mock-a"],
    cot_effort: ["mock-b"],
    parallel: "serial",
    retry: 0,
    retry_backoff_ms: 0,
    pace_ms: 0,
  }
  let a = settings_for(base_settings(), "mock-a", Case::new("c1", "问题"), options)
  let b = settings_for(base_settings(), "mock-b", Case::new("c1", "问题"), options)
  let c = settings_for(base_settings(), "mock-c", Case::new("c1", "问题"), options)
  assert_true(a.enable_thinking)
  assert_eq(a.reasoning_effort, None)
  assert_eq(b.enable_thinking, false)
  assert_eq(b.reasoning_effort, Some("high"))
  // 没勾的模型一个都不带
  assert_eq(c.enable_thinking, false)
  assert_eq(c.reasoning_effort, None)
}

///|
test "parallel：三个取值，其余拒绝" {
  assert_eq(parse_parallel(""), Ok("serial"))
  assert_eq(parse_parallel("serial"), Ok("serial"))
  assert_eq(parse_parallel("models"), Ok("models"))
  assert_eq(parse_parallel("all"), Ok("all"))
  assert_true(parse_parallel("parallel") is Err(_))
  assert_true(parse_parallel("ALL") is Err(_))
}
