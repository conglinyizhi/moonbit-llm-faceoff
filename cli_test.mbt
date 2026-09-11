///|
fn parse_with_key(argv : Array[String]) -> Cli raise ConfigError {
  Cli::parse({ "MOONLLM_API_KEY": "k" }, argv)
}

///|
fn parse_result(argv : Array[String]) -> Result[Cli, ConfigError] {
  Ok(parse_with_key(argv)) catch {
    err => Err(err)
  }
}

///|
test "positional words become the prompt" {
  let cli = parse_with_key(["hello", "there"])
  assert_eq(cli.prompt, Some("hello there"))
  assert_false(cli.stream)
  assert_false(cli.show_help)
}

///|
test "flags override settings" {
  let cli = parse_with_key([
    "--stream", "--model", "m1", "--base-url", "http://x/v1", "--temperature", "0.25",
    "--max-tokens", "64", "--timeout-ms", "1500", "--system", "be terse", "hi",
  ])
  assert_true(cli.stream)
  assert_eq(cli.settings.model, "m1")
  assert_eq(cli.settings.base_url, "http://x/v1")
  assert_eq(cli.settings.temperature, Some(0.25))
  assert_eq(cli.settings.max_tokens, Some(64))
  assert_eq(cli.settings.timeout_ms, 1500)
  assert_eq(cli.settings.system, "be terse")
  assert_eq(cli.prompt, Some("hi"))
}

///|
test "short stream flag" {
  assert_true(parse_with_key(["-s", "hi"]).stream)
}

///|
test "separator turns the rest into literal prompt text" {
  let cli = parse_with_key(["--", "--stream", "is", "a", "flag"])
  assert_false(cli.stream)
  assert_eq(cli.prompt, Some("--stream is a flag"))
}

///|
test "no prompt means stdin" {
  assert_eq(parse_with_key(["--stream"]).prompt, None)
}

///|
test "missing api key is an error unless --no-key" {
  let env : Map[String, String] = Map([])
  assert_true((Ok(Cli::parse(env, ["hi"])) catch { err => Err(err) }) is Err(_))
  let cli = Cli::parse(env, ["--no-key", "hi"])
  assert_eq(cli.settings.api_key, "")
}

///|
test "unknown flag is rejected" {
  match parse_result(["--nope"]) {
    Err(ConfigError::UnknownFlag(flag~)) => assert_eq(flag, "--nope")
    _ => fail("expected UnknownFlag")
  }
}

///|
test "flag without value is rejected" {
  match parse_result(["--model"]) {
    Err(ConfigError::MissingValue(flag~)) => assert_eq(flag, "--model")
    _ => fail("expected MissingValue")
  }
}

///|
test "non-numeric value is rejected" {
  match parse_result(["--temperature", "warm"]) {
    Err(ConfigError::BadNumber(flag~, value~)) => {
      assert_eq(flag, "--temperature")
      assert_eq(value, "warm")
    }
    _ => fail("expected BadNumber")
  }
}

///|
test "status lines are on by default" {
  assert_false(parse_with_key(["hi"]).quiet)
  assert_false(parse_with_key(["hi"]).show_cot)
}

///|
test "quiet and show-cot parse, in both spellings" {
  let cli = parse_with_key(["-q", "--show-cot", "-s", "hi"])
  assert_true(cli.quiet)
  assert_true(cli.show_cot)
  assert_true(cli.stream)
  // The long spelling of the same two flags.
  let long = parse_with_key(["--quiet", "hi"])
  assert_true(long.quiet)
}
