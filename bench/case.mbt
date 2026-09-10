///|
/// One prompt to run against every model under test.
///
/// Only `prompt` is required in the source file; everything else falls back to
/// the benchmark options.
pub(all) struct Case {
  id : String
  prompt : String
  system : String?
  max_tokens : Int?
  temperature : Double?
} derive(Eq, Debug)

///|
pub extend Case with Eq::{equal, not_equal}

///|
pub extend Case with @debug.Debug::{to_repr}

///|
pub fn Case::new(
  id : String,
  prompt : String,
  system? : String,
  max_tokens? : Int,
  temperature? : Double,
) -> Case {
  { id, prompt, system, max_tokens, temperature, }
}

///|
/// Errors raised while loading a case file.
pub(all) suberror CaseError {
  /// The file held no cases at all.
  EmptySuite
  /// A case was not a JSON object, or the document was malformed.
  BadCase(line~ : Int, message~ : String)
  /// A case object had no usable `prompt`.
  MissingPrompt(line~ : Int)
}

///|
pub fn CaseError::to_string(self : CaseError) -> String {
  match self {
    EmptySuite => "the case suite is empty"
    BadCase(line~, message~) =>
      if line == 0 {
        "invalid case suite: " + message
      } else {
        "invalid case on line \{line}: " + message
      }
    MissingPrompt(line~) => "case on line \{line} has no non-empty \"prompt\""
  }
}

///|
/// Parse a case suite.
///
/// Two shapes are accepted, chosen by the first non-space character:
///
/// - a JSON array of case objects, `[{"prompt": ...}, ...]`
/// - JSON Lines, one case object per line; blank lines and lines starting with
///   `#` are skipped.
///
/// `line` numbers in errors refer to the source line for JSONL, and to the
/// 1-based position within the array otherwise.
pub fn parse_cases(text : String) -> Array[Case] raise CaseError {
  let trimmed = text.trim(chars=" \t\r\n")
  if trimmed.length() == 0 {
    raise EmptySuite
  }
  let document = if trimmed.has_prefix("[") {
    @json.parse(trimmed.to_owned()) catch {
      err => raise BadCase(line=0, message=err.to_string())
    }
  } else {
    let items : Array[Json] = []
    let mut line_no = 0
    for line in text.split("\n") {
      line_no = line_no + 1
      let content = line.trim(chars=" \t\r")
      if content.length() == 0 || content.has_prefix("#") {
        continue
      }
      items.push(
        @json.parse(content.to_owned()) catch {
          err => raise BadCase(line=line_no, message=err.to_string())
        },
      )
    }
    Json::array(items)
  }
  let items = match document {
    Array(items) => items
    _ =>
      raise BadCase(
        line=0,
        message="expected a JSON array or one object per line",
      )
  }
  if items.is_empty() {
    raise EmptySuite
  }
  let cases : Array[Case] = []
  let mut index = 0
  for item in items {
    index = index + 1
    cases.push(case_of_json(item, index))
  }
  cases
}

///|
fn case_of_json(json : Json, position : Int) -> Case raise CaseError {
  guard json is Object(obj) else {
    raise BadCase(line=position, message="each case must be a JSON object")
  }
  let prompt = match obj.get("prompt") {
    Some(String(prompt)) => prompt
    _ => raise MissingPrompt(line=position)
  }
  if prompt.length() == 0 {
    raise MissingPrompt(line=position)
  }
  {
    id: match obj.get("id") {
      Some(String(id)) => id
      _ => "case-\{position}"
    },
    prompt,
    system: string_field(obj, "system"),
    max_tokens: int_field(obj, "max_tokens"),
    temperature: number_field(obj, "temperature"),
  }
}

///|
fn string_field(obj : Map[String, Json], key : String) -> String? {
  match obj.get(key) {
    Some(String(value)) => Some(value)
    _ => None
  }
}

///|
fn int_field(obj : Map[String, Json], key : String) -> Int? {
  match obj.get(key) {
    Some(Number(value, ..)) => Some(value.to_int())
    _ => None
  }
}

///|
fn number_field(obj : Map[String, Json], key : String) -> Double? {
  match obj.get(key) {
    Some(Number(value, ..)) => Some(value)
    _ => None
  }
}
