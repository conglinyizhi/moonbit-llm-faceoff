///|
/// Whitebox tests: `redact_key` and `mask_key` are internal.
test "mask_key keeps two characters on each end" {
  assert_eq(mask_key("sk-1234567890abcdef"), "sk***ef")
}

///|
test "mask_key hides short keys entirely" {
  // 露四位就等于露一半，不如全遮
  assert_eq(mask_key("short"), "***")
  assert_eq(mask_key("test-key"), "***")
  assert_eq(mask_key("sk-12345678"), "***")
  // 刚好到阈值
  assert_eq(mask_key("sk-123456789"), "sk***89")
  // 空串不该进到这里，但也不该炸
  assert_eq(mask_key(""), "***")
}

///|
test "redact_key masks the configured key inside an upstream body" {
  let key = "sk-1234567890abcdef"
  let body = "{\"error\":{\"message\":\"bad authorization: Bearer " +
    key +
    "\"}}"
  assert_eq(
    redact_key(body, key),
    "{\"error\":{\"message\":\"bad authorization: Bearer sk***ef\"}}",
  )
}

///|
test "redact_key leaves text alone when there is nothing to hide" {
  let body = "{\"error\":{\"message\":\"rate limited\"}}"
  // 没配 key：原样返回
  assert_eq(redact_key(body, ""), body)
  // 正文里本来就不含 key
  assert_eq(redact_key(body, "sk-1234567890abcdef"), body)
}

///|
test "redact_key removes every occurrence" {
  let key = "sk-1234567890abcdef"
  assert_eq(redact_key("a " + key + " b " + key, key), "a sk***ef b sk***ef")
}

///|
/// The point of masking rather than erasing: the error stays diagnosable while
/// the key stays unusable.
test "a redacted error still identifies the key without exposing it" {
  let key = "sk-1234567890abcdef"
  let body = "{\"error\":{\"message\":\"bad authorization: Bearer " +
    key +
    "\"}}"
  let rendered = ClientError::to_string(
    Status(code=401, message=redact_key(body, key)),
  )
  assert_true(rendered.contains("sk***ef"))
  assert_false(rendered.contains(key))
}
