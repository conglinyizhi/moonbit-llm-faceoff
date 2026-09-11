///|
/// The shell exit code to use when something goes wrong.
let failure_exit_code : Int = 1

///|
/// C `exit`, so failures surface as a non-zero process status.
///
/// The CLI is native-only, so linking straight to libc is fine.
extern "c" fn c_exit(code : Int) -> Unit = "exit"

///|
/// What the status line and the empty-reply warning need.
///
/// Both reply paths produce the same four things, so they share this instead of
/// each printing its own summary.
struct Report {
  /// Characters of visible answer.
  content_chars : Int
  /// Characters of chain of thought.
  reasoning_chars : Int
  usage : @client.TokenUsage?
  finish_reason : String?
  elapsed_ms : UInt64
}

///|
/// Entry point: resolve settings, then run one prompt in either one-shot or
/// streaming mode.
async fn main {
  let env = @env.get_env_vars()
  let all_args : Array[String] = @env.args()
  let argv : Array[String] = []
  for i = 1; i < all_args.length(); i = i + 1 {
    argv.push(all_args[i])
  }
  let cli = @client.Cli::parse(env, argv) catch {
    err => {
      report_error(err.to_string())
      @stdio.stderr.write("try `faceoff --help`\n") catch {
        _ => ()
      }
      c_exit(failure_exit_code)
      return
    }
  }
  if cli.show_help {
    println(@client.usage)
    return
  }
  let prompt = match cli.prompt {
    Some(prompt) => prompt
    None => @client.read_prompt_from_stdin()
  }
  if prompt == "" {
    report_error("empty prompt: pass it as an argument or on stdin")
    c_exit(failure_exit_code)
    return
  }
  // A one-shot request is silent until it is completely done, which for a
  // reasoning model can be a minute of a seemingly dead terminal. Say what is
  // about to happen, on stderr, where it cannot end up in a pipe.
  if !cli.quiet {
    note(
      "-> POST " +
      cli.settings.chat_completions_url() +
      "  model=" +
      cli.settings.model +
      limit_note(cli.settings),
    )
  }
  if cli.stream {
    run_stream(cli, prompt)
  } else {
    run_one_shot(cli, prompt)
  }
}

///|
/// One request, one reply, printed when it is complete.
async fn run_one_shot(cli : @client.Cli, prompt : String) -> Unit {
  let start = @env.now()
  let outcome = @client.ask_outcome(cli.settings, prompt) catch {
    err => {
      report_error(err.to_string())
      c_exit(failure_exit_code)
      return
    }
  }
  let report : Report = {
    content_chars: outcome.content.length(),
    reasoning_chars: outcome.reasoning.length(),
    usage: outcome.usage,
    finish_reason: outcome.finish_reason,
    elapsed_ms: @env.now() - start,
  }
  println(outcome.content)
  finish(report, cli.quiet)
}

///|
/// One request, printed as it arrives.
async fn run_stream(cli : @client.Cli, prompt : String) -> Unit {
  let start = @env.now()
  let outcome = @client.stream_parts(cli.settings, prompt, async fn(part) {
    match part {
      @client.StreamPart::Content(text) =>
        @stdio.stdout.write(text) catch {
          _ => ()
        }
      @client.StreamPart::Reasoning(text) =>
        if cli.show_cot {
          @stdio.stderr.write(text) catch {
            _ => ()
          }
        }
    }
  }) catch {
    err => {
      report_error(err.to_string())
      c_exit(failure_exit_code)
      return
    }
  }
  @stdio.stdout.write("\n") catch {
    _ => ()
  }
  // 思考碎片是连续写出去的，接状态行之前先把那一行结掉
  if cli.show_cot {
    @stdio.stderr.write("\n") catch {
      _ => ()
    }
  }
  let report : Report = {
    content_chars: outcome.content.length(),
    reasoning_chars: outcome.reasoning.length(),
    usage: outcome.usage,
    finish_reason: outcome.finish_reason,
    elapsed_ms: @env.now() - start,
  }
  finish(report, cli.quiet)
}

///|
/// The status line, then the question of whether we actually got an answer.
///
/// An empty reply used to be a blank line and exit 0: a pipeline could not tell
/// it apart from a working model that happened to say nothing, and the one
/// common cause — a reasoning model spending the whole token budget on thinking
/// — was invisible. Now it is a warning on stderr and a non-zero exit.
async fn finish(report : Report, quiet : Bool) -> Unit {
  if !quiet {
    note(summary_line(report))
  }
  if report.content_chars == 0 {
    note(empty_reply_warning(report))
    c_exit(failure_exit_code)
  }
}

///|
fn summary_line(report : Report) -> String {
  "<- " +
  seconds(report.elapsed_ms) +
  "  content " +
  report.content_chars.to_string() +
  " chars  reasoning " +
  report.reasoning_chars.to_string() +
  " chars" +
  usage_note(report.usage) +
  finish_note(report.finish_reason)
}

///|
fn usage_note(usage : @client.TokenUsage?) -> String {
  match usage {
    Some(usage) =>
      "  tokens " +
      usage.prompt_tokens.to_string() +
      "+" +
      usage.completion_tokens.to_string() +
      "(reasoning " +
      usage.reasoning_tokens.to_string() +
      ")"
    None => ""
  }
}

///|
fn finish_note(finish_reason : String?) -> String {
  match finish_reason {
    Some(reason) => "  finish_reason=" + reason
    None => ""
  }
}

///|
fn limit_note(settings : @client.Settings) -> String {
  match settings.max_tokens {
    Some(max_tokens) => "  max_tokens=" + max_tokens.to_string()
    None => ""
  }
}

///|
fn empty_reply_warning(report : Report) -> String {
  let reason = match report.finish_reason {
    Some(reason) => "finish_reason: " + reason + "; "
    None => ""
  }
  let tokens = match report.usage {
    Some(usage) =>
      usage.completion_tokens.to_string() +
      " completion tokens, " +
      usage.reasoning_tokens.to_string() +
      " of them reasoning; "
    None => ""
  }
  "warning: the reply carried no visible content (" +
  reason +
  tokens +
  report.reasoning_chars.to_string() +
  " chars of reasoning)\n" +
  "  a reasoning model can spend the whole budget thinking before it starts answering:\n" +
  "  raise --max-tokens, or add `--stream --show-cot` to watch the reasoning arrive."
}

///|
/// Seconds with exactly one decimal. `0.0s` reads better than `0s`: it says the
/// request was measured rather than that the timer was skipped.
fn seconds(elapsed_ms : UInt64) -> String {
  let tenths = (elapsed_ms.to_double() / 100.0).round().to_int()
  (tenths / 10).to_string() + "." + (tenths % 10).to_string() + "s"
}

///|
/// Write a note to stderr, ignoring a broken pipe — status output is never worth
/// failing a run over.
async fn note(message : String) -> Unit {
  @stdio.stderr.write(message + "\n") catch {
    _ => ()
  }
}

///|
/// Write a diagnostic to stderr, ignoring a broken pipe.
async fn report_error(message : String) -> Unit {
  @stdio.stderr.write("error: " + message + "\n") catch {
    _ => ()
  }
}
