///|
/// The shell exit code for a failed run.
let failure_exit_code : Int = 1

///|
/// C `exit`, so failures surface as a non-zero process status.
extern "c" fn c_exit(code : Int) -> Unit = "exit"

///|
/// Entry point.
///
/// Either runs the suite, or — with `--from-json` — reloads a previous run log
/// and only regenerates the report and page data. The replay path exists so a
/// page can be rebuilt without paying for the model calls again.
async fn main {
  let env = @env.get_env_vars()
  let all_args : Array[String] = @env.args()
  let argv : Array[String] = []
  for i = 1; i < all_args.length(); i = i + 1 {
    argv.push(all_args[i])
  }
  let cli = @harness.BenchCli::parse(env, argv) catch {
    err => {
      note("error: " + err.to_string())
      note("try `bench --help`")
      c_exit(failure_exit_code)
      return
    }
  }
  if cli.show_help {
    println(@harness.usage)
    return
  }
  let mut models = cli.models
  let mut results : Array[@harness.RunResult] = []
  let mut source = ""
  match cli.from_json {
    Some(path) => {
      let text = match read_text(path) {
        Ok(text) => text
        Err(message) => {
          note("error: " + message)
          c_exit(failure_exit_code)
          return
        }
      }
      results = @harness.parse_results(text)
      source = path
      if models.is_empty() {
        models = unique_models(results)
      }
      note(
        "replaying \{results.length()} run(s) from \{path}, \{models.length()} model(s)",
      )
    }
    None => {
      let cases = match load_cases(cli) {
        Ok(cases) => cases
        Err(message) => {
          note("error: " + message)
          c_exit(failure_exit_code)
          return
        }
      }
      let options : @harness.BenchOptions = {
        repeats: cli.repeats,
        max_tokens: cli.max_tokens,
        temperature: cli.temperature,
        system: cli.system,
        retry: cli.retry,
        retry_backoff_ms: cli.retry_backoff_ms,
        pace_ms: cli.pace_ms,
      }
      note(
        "\{models.length()} model(s) x \{cases.length()} case(s) x \{cli.repeats} repeat(s)",
      )
      results = @harness.run_bench(
        cli.settings,
        models,
        cases,
        options,
        async fn(model, case_id, repeat) {
          note("")
          note("> \{model}  \{case_id} #\{repeat + 1}")
        },
        async fn(part) {
          if cli.show_cot {
            match part {
              @faceoff.Reasoning(text) =>
                @stdio.stderr.write(text) catch {
                  _ => ()
                }
              @faceoff.Content(_) => ()
            }
          }
        },
        async fn(result) {
          note(@harness.format_run_line(result))
          if cli.show_output && result.ok {
            note("  --- answer ---")
            note(result.content)
            note("  --- end ---")
          }
        },
      )
      source = match (cli.cases_path, cli.prompt) {
        (Some(path), _) => path
        (None, Some(_)) => "inline prompt"
        (None, None) => ""
      }
    }
  }
  match cli.json_path {
    Some(path) => {
      let out = StringBuilder()
      for result in results {
        out.write_string(result.to_json().stringify())
        out.write_string("\n")
      }
      write_text(path, out.to_string())
    }
    None => ()
  }
  match cli.web_data {
    Some(path) => {
      let document = @harness.page_data_json(source, models, results)
      write_text(path, document.stringify(indent=2) + "\n")
    }
    None => ()
  }
  println(@harness.format_summaries(@harness.summarize_all(models, results)))
  let mut failures = 0
  for result in results {
    if !result.ok {
      failures = failures + 1
    }
  }
  if results.length() > 0 && failures == results.length() {
    c_exit(failure_exit_code)
  }
}

///|
/// Models in first-seen order, for replaying a log whose model list was not
/// given on the command line.
fn unique_models(results : Array[@harness.RunResult]) -> Array[String] {
  let seen : Array[String] = []
  for result in results {
    if !seen.contains(result.model) {
      seen.push(result.model)
    }
  }
  seen
}

///|
/// Read the suite from `--prompt` or `--cases`, as a message string on
/// failure so the caller can report it without importing the error types.
async fn load_cases(
  cli : @harness.BenchCli,
) -> Result[Array[@harness.Case], String] {
  match cli.prompt {
    Some(text) => Ok([@harness.Case::new("inline", text)])
    None =>
      match cli.cases_path {
        None => Err("no test cases given")
        Some(path) => {
          let text = match read_text(path) {
            Ok(text) => text
            Err(message) => return Err(message)
          }
          let cases = @harness.parse_cases(text) catch {
            err => return Err("\{path}: " + err.to_string())
          }
          Ok(cases)
        }
      }
  }
}

///|
async fn read_text(path : String) -> Result[String, String] {
  let data = @fs.read_file(path) catch {
    err => return Err("cannot read \{path}: " + err.to_string())
  }
  let text = data.text() catch {
    err => return Err("cannot decode \{path}: " + err.to_string())
  }
  Ok(text)
}

///|
async fn write_text(path : String, content : String) -> Unit {
  @fs.write_file(path, content, create_mode=@fs.CreateOrTruncate) catch {
    err => note("warning: could not write \{path}: " + err.to_string())
  }
}

///|
/// Write a progress or diagnostic line to stderr, keeping stdout for the report.
async fn note(message : String) -> Unit {
  @stdio.stderr.write(message + "\n") catch {
    _ => ()
  }
}
