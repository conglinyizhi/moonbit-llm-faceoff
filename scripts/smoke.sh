#!/usr/bin/env bash
#
# End-to-end smoke test: run the built CLI against a local mock of an
# OpenAI-compatible endpoint. No provider key or network access required.
#
# Covers: one-shot mode, streaming mode, stdin prompts, and passing settings
# through environment variables instead of flags.

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

# shellcheck source=scripts/lib.sh
source scripts/lib.sh

export MOON_CC=${MOON_CC:-gcc}

expected="Hello from the mock server."

port_file=$(mktemp)
trap 'rm -f "$port_file"; kill "${server_pid:-}" 2>/dev/null || true' EXIT

build_mbtx scripts/mock_openai.mbtx "$MOCK_BIN" || { echo "mock 编译失败" >&2; exit 1; }
build_mbtx scripts/check_incremental.mbtx "$CHECKER_BIN" || { echo "检查器编译失败" >&2; exit 1; }

MOCK_STREAM_DELAY=${MOCK_STREAM_DELAY:-0.4} "$MOCK_BIN" >"$port_file" 2>/dev/null &
server_pid=$!
for _ in $(seq 1 200); do
  [ -s "$port_file" ] && break
  sleep 0.05
done
port=$(cat "$port_file")
if [ -z "$port" ]; then
  echo "mock server did not start" >&2
  exit 1
fi

echo "mock server on 127.0.0.1:$port"
moon build --target native >/dev/null
bin="_build/native/debug/build/cmd/faceoff/faceoff.exe"
[ -x "$bin" ] || { echo "missing $bin" >&2; exit 1; }

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# 1. one-shot, settings from the environment
out=$(MOONLLM_BASE_URL="http://127.0.0.1:$port/v1" MOONLLM_API_KEY=test-key "$bin" "hi there")
[ "$out" = "$expected" ] || fail "one-shot env output was: $out"
echo "ok: one-shot via environment variables"

# 2. one-shot, settings from flags
out=$("$bin" --base-url "http://127.0.0.1:$port/v1" --api-key test-key --model mock-model "hi")
[ "$out" = "$expected" ] || fail "one-shot flag output was: $out"
echo "ok: one-shot via flags"

# 3. streaming
out=$("$bin" --stream --base-url "http://127.0.0.1:$port/v1" --api-key test-key "hi")
[ "$out" = "$expected" ] || fail "stream output was: $out"
echo "ok: streaming"

# 4. streaming really is incremental, not buffered
"$CHECKER_BIN" "$bin" "http://127.0.0.1:$port/v1"

# 5. prompt from stdin
out=$(printf 'piped question\n' | "$bin" --base-url "http://127.0.0.1:$port/v1" --api-key test-key)
[ "$out" = "$expected" ] || fail "stdin output was: $out"
echo "ok: stdin prompt"

# 6. a non-ASCII error body is decoded as UTF-8, not reinterpreted as UTF-16
if "$bin" --base-url "http://127.0.0.1:$port/v1" --api-key test-key "RATE_LIMIT" >/dev/null 2>err.log; then
  fail "expected a non-zero exit for a rate-limited response"
fi
grep -q "请求频率过高" err.log || fail "error body was not decoded as UTF-8: $(cat err.log)"
rm -f err.log
echo "ok: non-ASCII error body decodes cleanly"

# 7. a bad key surfaces the API error instead of a silent empty reply
if "$bin" --base-url "http://127.0.0.1:$port/v1" --api-key wrong "hi" >/dev/null 2>err.log; then
  fail "expected a non-zero exit for a bad key"
fi
grep -q "401" err.log || fail "expected a 401 diagnostic, got: $(cat err.log)"
# The mock echoes the Authorization header back in its 401 body. The key must not
# survive into anything we print or persist — see redact_key in runner.mbt.
if grep -q "wrong" err.log; then
  fail "the API key leaked into the error output: $(cat err.log)"
fi
grep -q '\*\*\*' err.log || fail "expected a redacted marker in: $(cat err.log)"
rm -f err.log
echo "ok: bad key reports 401, with the key redacted out of the body"

# 8. the benchmark harness runs against the same mock endpoint
bench_bin="_build/native/debug/build/cmd/bench/bench.exe"
[ -x "$bench_bin" ] || { echo "missing $bench_bin" >&2; exit 1; }
tmpdir=$(mktemp -d)
"$bench_bin" --base-url "http://127.0.0.1:$port/v1" --api-key test-key \
  --models mock-a,mock-b --prompt "hello" --repeats 1 --max-tokens 64 \
  --json "$tmpdir/runs.jsonl" >"$tmpdir/report.txt" 2>"$tmpdir/progress.txt" \
  || fail "bench exited non-zero"
grep -q "comparison (median per model)" "$tmpdir/report.txt" \
  || fail "bench report has no comparison table"
grep -q "mock-b" "$tmpdir/report.txt" || fail "bench report is missing a model"
[ -s "$tmpdir/runs.jsonl" ] || fail "bench wrote no JSON"
grep -q '"completion_tokens":9' "$tmpdir/runs.jsonl" \
  || fail "bench did not record the usage block"
grep -q '"reasoning_tokens":4' "$tmpdir/runs.jsonl" \
  || fail "bench did not record reasoning tokens"
rm -rf "$tmpdir"
echo "ok: bench harness end to end"

echo "smoke: all checks passed"
