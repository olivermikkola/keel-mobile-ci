# Harness eval

Measures how a real local model's tool calls fare against Keel Mobile's
parser, before and after the harness cleanup (`Harness/ToolCallText.swift`).
It uses the app's own system prompt, prompt rendering and sampler, so it
measures what the phone would see apart from Metal-vs-CPU numeric differences.
Nothing is executed: only model output format is classified.

## Run

1. Start a llama.cpp server with a Bonsai GGUF, for example the 4B on CPU:
   ```sh
   llama-server -m Ternary-Bonsai-2-4B-Q2_0.gguf --port 8091 -c 16384 -ngl 0
   ```
2. Collect outputs (12 repository tasks × 2 turns × samples):
   ```sh
   python3 tools/harness-eval/collect.py --server http://127.0.0.1:8091 --out /tmp/out.jsonl --samples 3
   ```
3. Classify them with the app's real `RepositoryCall.parse`:
   ```sh
   bash tools/harness-eval/run.sh /tmp/out.jsonl
   ```

Turn 1 is the user's question. Turn 2 adds a real root listing of this
repository after a `list_files` call, which is where models start to drift.

## Reading the result

- **valid call / plain answer**: the app would run the call or show the answer.
- **rejected**: the strict parser refuses it, and the model gets a correction
  message, which costs a step.
- **regressions** must be 0: the cleanup may never turn a valid call invalid.
  `run.sh` exits with status 2 if it does.

The parser is extracted from `Sources/RepositoryAgent.swift` at run time, so
results always reflect the current app code.

## Results, 2026-11-12

Beelink, llama.cpp `prism-b12128` build, 72 samples per model (12 tasks × 2
turns × 3 seeds), app sampler (top_k 40, top_p 0.9, temperature 0.6).
4B ran on CPU, 9B on the Vulkan iGPU.

| Model | Parser | valid call | plain answer | rejected |
| --- | --- | --- | --- | --- |
| Bonsai 2 4B | before #40 | 57 | 11 | 4 |
| Bonsai 2 4B | after #40 | 60 | 11 | 1 |
| Bonsai 2 9B | before #40 | 64 | 6 | 2 |
| Bonsai 2 9B | after #40 | 65 | 6 | 1 |

What this says:
- The main format failure was a search query on its own line, copied from the
  call template. #40 fixed it in the parser.
- The remaining rejection in both models is `search_file` with path `.`,
  a real argument error that the model is told to correct.
- `ToolCallText` cleanup changed 4–5 outputs per model and recovered none: in
  the first two turns neither model fences its calls or adds trailing prose.
  It caused no regressions. Longer tasks are not measured yet.
- The 4B answers 11 of 72 questions without reading anything, despite the
  prompt saying to read first. That is the next thing worth a harness check.
