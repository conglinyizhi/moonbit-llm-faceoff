///|
/// The shell exit code to use when something goes wrong.
let failure_exit_code : Int = 1

///|
/// C `exit`, so failures surface as a non-zero process status.
///
/// The CLI is native-only, so linking straight to libc is fine.
extern "c" fn c_exit(code : Int) -> Unit = "exit"

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
  let cli = @llm_client.Cli::parse(env, argv) catch {
    err => {
      report_error(err.to_string())
      @stdio.stderr.write("try `llm_client --help`\n") catch {
        _ => ()
      }
      c_exit(failure_exit_code)
      return
    }
  }
  if cli.show_help {
    println(@llm_client.usage)
    return
  }
  let prompt = match cli.prompt {
    Some(prompt) => prompt
    None => @llm_client.read_prompt_from_stdin()
  }
  if prompt == "" {
    report_error("empty prompt: pass it as an argument or on stdin")
    c_exit(failure_exit_code)
    return
  }
  if cli.stream {
    let reply = @llm_client.stream_to_stdout(cli.settings, prompt) catch {
      err => {
        report_error(err.to_string())
        c_exit(failure_exit_code)
        return
      }
    }
    ignore(reply)
    @stdio.stdout.write("\n") catch {
      _ => ()
    }
    return
  }
  let reply = @llm_client.ask(cli.settings, prompt) catch {
    err => {
      report_error(err.to_string())
      c_exit(failure_exit_code)
      return
    }
  }
  println(reply)
}

///|
/// Write a diagnostic to stderr, ignoring a broken pipe.
async fn report_error(message : String) -> Unit {
  @stdio.stderr.write("error: " + message + "\n") catch {
    _ => ()
  }
}
