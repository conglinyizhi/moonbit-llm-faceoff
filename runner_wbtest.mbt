///|
/// Whitebox test: `redact_key` is internal.
test "redact_key strips the configured key from an upstream body" {
  let body = "{\"error\":{\"message\":\"bad authorization: Bearer sk-secret-123\"}}"
  assert_eq(
    redact_key(body, "sk-secret-123"),
    "{\"error\":{\"message\":\"bad authorization: Bearer ***\"}}",
  )
}

///|
test "redact_key leaves text alone when there is nothing to hide" {
  let body = "{\"error\":{\"message\":\"rate limited\"}}"
  // 没配 key：原样返回
  assert_eq(redact_key(body, ""), body)
  // 正文里本来就不含 key
  assert_eq(redact_key(body, "sk-secret-123"), body)
}

///|
test "redact_key removes every occurrence" {
  assert_eq(redact_key("a sk-k b sk-k", "sk-k"), "a *** b ***")
}

///|
/// The whole point of the redaction: an upstream 401 that echoes the
/// Authorization header must not carry the key into the string we persist.
test "ClientError::to_string on a redacted body has no key in it" {
  let key = "sk-secret-123"
  let body = "{\"error\":{\"message\":\"bad authorization: Bearer " +
    key +
    "\"}}"
  let rendered = ClientError::to_string(
    Status(code=401, message=redact_key(body, key)),
  )
  assert_eq(
    rendered, "http 401: {\"error\":{\"message\":\"bad authorization: Bearer ***\"}}",
  )
  assert_true(rendered.contains("***"))
  assert_false(rendered.contains(key))
}
