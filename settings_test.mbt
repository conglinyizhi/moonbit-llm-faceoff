///|
test "from_env applies defaults" {
  let settings = @llm_client.Settings::from_env({ "MOONLLM_API_KEY": "k" })
  assert_eq(settings.base_url, @llm_client.default_base_url)
  assert_eq(settings.model, @llm_client.default_model)
  assert_eq(settings.system, @llm_client.default_system)
  assert_eq(settings.timeout_ms, @llm_client.default_timeout_ms)
  assert_eq(settings.temperature, None)
}

///|
test "api key lookup order" {
  let moonllm_wins = @llm_client.Settings::from_env({
    "MOONLLM_API_KEY": "moonllm",
    "OPENAI_API_KEY": "openai",
  })
  assert_eq(moonllm_wins.api_key, "moonllm")
  let openai_fallback = @llm_client.Settings::from_env({
    "OPENAI_API_KEY": "openai",
  })
  assert_eq(openai_fallback.api_key, "openai")
  assert_eq(@llm_client.Settings::from_env({}).api_key, "")
}

///|
test "empty env values fall through to the next variable" {
  let settings = @llm_client.Settings::from_env({
    "MOONLLM_API_KEY": "",
    "OPENAI_API_KEY": "openai",
  })
  assert_eq(settings.api_key, "openai")
}

///|
test "base url and model overrides" {
  let settings = @llm_client.Settings::from_env({
    "MOONLLM_API_KEY": "k",
    "MOONLLM_BASE_URL": "http://localhost:1234/v1",
    "MOONLLM_MODEL": "qwen",
  })
  assert_eq(settings.base_url, "http://localhost:1234/v1")
  assert_eq(settings.model, "qwen")
  assert_eq(
    settings.chat_completions_url(),
    "http://localhost:1234/v1/chat/completions",
  )
}

///|
test "chat completions url does not double the slash" {
  let settings = @llm_client.Settings::from_env({
    "MOONLLM_API_KEY": "k",
    "MOONLLM_BASE_URL": "http://localhost:1234/v1/",
  })
  assert_eq(
    settings.chat_completions_url(),
    "http://localhost:1234/v1/chat/completions",
  )
}
