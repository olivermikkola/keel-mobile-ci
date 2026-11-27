# decide-eval

Runs the app's decision runtime (`Sources/DecisionRuntime.swift`, by
symlink) and harness on Linux, against a llama.cpp build, so its answers
can be compared with llama.cpp's own `/v1/systemone` server on the same d1
model. See `docs/DECIDE.md`.

## Build and run

Needs a llama.cpp checkout built with CMake (the app pins b12367) and Swift
for Linux:

```sh
# LLAMA_DIR: the llama.cpp checkout (default ~/Projects/llama.cpp-b12367)
# SWIFT: the swift binary if it is not on PATH
# JOBS: parallel compile jobs (default 2, keeps the machine cool)
SWIFT=~/.local/swift/swift-6.2-RELEASE-ubuntu24.04/usr/bin/swift \
  tools/decide-eval/run.sh --model d1-2B-Q4_K_M.gguf --request request.json --threads 2
```

`run.sh` builds the tool, then runs it with the arguments given. The
request is:

```json
{"state": "the document text, or null",
 "questions": [
   {"id": "refund", "type": "noul", "instructions": "Is the customer asking for a refund?"},
   {"id": "team", "type": "choice", "instructions": "Which team?",
    "criteria": [["billing", "Charges, refunds"], ["technical", null]]},
   {"id": "urgency", "type": "score", "instructions": "How urgent?",
    "criteria": ["Can wait", "Today", "Now"]}]}
```

Choice options are a list of `[key, description]` pairs so their order is
kept. `--split` reads the document in parts that fit `--context`, as the app
does on a phone. The output has each answer the way llama.cpp's server writes it, plus
`read_tokens`, `fraction_read` and `seconds`.

To compare, start `llama-server -m d1-2B-Q4_K_M.gguf -b 16384 -ub 16384`
and send the same questions to `/v1/systemone` (choice criteria as an
object, in the same order).
