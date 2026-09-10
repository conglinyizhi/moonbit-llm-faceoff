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

keywords = [ "moonbit", "llm", "openai", "benchmark", "comparison" ]

preferred_target = "native"

description = "OpenAI-compatible LLM client plus a harness that compares multiple models on the same case set, written in MoonBit."

import {
  "moonbitlang/async@0.20.1",
}
