///|
/// A benchmark harness for comparing chat models on the same prompt suite.
///
/// The pieces are deliberately separate so the suite can change without
/// touching the measurement:
///
/// - `Case` / `parse_cases` — what to ask (JSONL or a JSON array).
/// - `run_bench` — runs every case against every model, serially, and records
///   one `RunResult` per attempt.
/// - `summarize` — turns raw runs into median/mean/min/max per model.
/// - `format_summaries` — the human-readable comparison.
///
/// Nothing here decides what a "good" answer is; the raw text of every run is
/// kept so scoring can be added later without rerunning the models.
