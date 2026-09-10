# Benchmark notes

## Setup

Gateway: `https://api.modelbest.cn/v1` (OpenAI-compatible).
Models: `MiniCPM5-1B` (1B) and `MiniCPM5-2B` (2B).
Suite: `bench/cases.example.jsonl` — 6 cases (arithmetic, a word problem, factual
Chinese, JSON formatting, Python code, Chinese prose) x 3 repeats x 2 models = 36
attempts.
Serial, `temperature 0.0`, `max_tokens 2048`, `--pace-ms 3000 --retry 3`.
Raw data: `bench/results-example.jsonl`. 0 failures, 0 truncations, 0 retries.

Both models are **reasoning models**: they emit `delta.reasoning_content`
before `delta.content`, and report `reasoning_tokens` in the usage block. That
single fact drives most of what follows.

## Result

| metric (median) | MiniCPM5-1B | MiniCPM5-2B | 2B / 1B |
| --- | --- | --- | --- |
| first token (ms) | 138 | 160.5 | 1.2x |
| first answer (ms) | 532 | 472.5 | 0.9x |
| total (ms) | 598.5 | 607.5 | 1.0x |
| completion tokens | 212.5 | 84.5 | 0.4x |
| reasoning tokens | 183 | 54 | 0.3x |
| reasoning share | 0.9 | 0.7 | 0.8x |
| decode tok/s | 442.9 | 201.2 | 0.5x |
| end-to-end tok/s | 351.5 | 145.3 | 0.4x |

## Reading it

- **The 1B decodes 2.2x faster per token**, which is what "smaller model is
  faster" usually means.
- **But the 2B emits 60% fewer tokens for the same answers.** Its reasoning
  share is lower and its chains of thought are far shorter.
- **The two effects cancel.** Total wall time is 598ms vs 607ms — a tie. Anyone
  benchmarking on tok/s alone would have called the 1B the winner and missed
  the actual result.
- On these five cases both models were correct, so this is a cost/latency
  comparison, not a quality verdict. The 2B reaches the same answers with 46%
  of the total tokens (1868 vs 4059 across the suite).

Sample outputs on `code-python`, both correct:

```python
# MiniCPM5-1B, 345 tokens
def is_palindrome(s):
    # 清理字符串：移除空格并转换为小写
    cleaned = s.replace(" ", "").lower()
    return cleaned == cleaned[::-1]
```

```python
# MiniCPM5-2B, 101 tokens
def is_palindrome(s):
    s = s.replace(" ", "").lower()
    return s == s[::-1]
```

## Things the run turned up

1. **The gateway rate-limits, and it is easy to miss.**
   The first unpaced run lost 7 of 18 attempts to `429`, all of them on the 1B
   — because the 1B finishes faster, more requests land inside the same minute.
   Without pacing or retries the report would have quietly compared 11 samples
   against 18. Hence `--pace-ms` and `--retry`.

2. **The 429 body was mojibake.** The error text came back as
   `≻牥潲≻笺挢摯≥...`, which is UTF-16LE bytes rendered as UTF-8. The cause was
   `client.read_all().binary().to_unchecked_string()`: `to_unchecked_string`
   reinterprets raw bytes as UTF-16 code units instead of decoding UTF-8. Fixed
   by using `read_all().text()`. `scripts/smoke.sh` now asserts on a non-ASCII
   error body so it cannot regress.

3. **`@fs.write_file` does not create files by default.** Omitting `create`
   selects `TruncateExisting`, so writing a fresh results file failed with
   `No such file or directory`. Needs `create_mode=@fs.CreateOrTruncate`.

4. **`usage` arrives by default on this gateway.** No
   `stream_options: {include_usage: true}` needed — the final chunk carries
   `choices: []` and a usage block, which is also where `reasoning_tokens`
   lives. The client reads it so token counts are measured, not estimated from
   character counts.

## Caveats

- Five cases and three repeats is an illustration, not a verdict. The harness
  is built so the suite can be replaced (`--cases`) without touching the
  measurement.
- `temperature 0.0` still is not fully deterministic; the 2B's `writing-zh`
  runs produced both 89- and 36-token answers.
- Token counts are the gateway's, not ours. A gateway that reports usage
  differently would move the throughput numbers.
- `--timeout-ms` does not apply to the streaming path, so a stalled connection
  is bounded by the OS, not by the harness.
