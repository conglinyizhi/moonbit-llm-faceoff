// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "conglinyizhi/moonbit-llm-faceoff"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/conglinyizhi/moonbit-llm-faceoff"

license = "MIT"

keywords = [ "moonbit", "llm", "openai", "benchmark", "comparison", "rabbita" ]

preferred_target = "native"

description = "OpenAI-compatible LLM client, a harness that compares multiple models on the same case set, and a browser UI for the results — all in MoonBit."

import {
  "conglinyizhi/precss@0.1.3",
  "moonbit-community/rabbita@0.15.7",
  "moonbitlang/async@0.21.3",
}
