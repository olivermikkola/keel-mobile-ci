# Runtime benchmark: llama.cpp vs MLX

Keel runs models with llama.cpp. MLX is the candidate second runtime. Add it
for chats only if it is clearly faster on a real iPhone (30% or more at both
reading and writing) and its tool calls are no worse
(`RuntimeBenchmark.verdict`, `docs/ON_DEVICE_PLAN.md` §2).

## On the phone

Models → **Runtime benchmark (llama.cpp vs MLX)**.

1. Download `LFM3 · 1.7B` (the GGUF) in Models if it is not there.
2. Download the MLX model on the benchmark screen: `LiquidAI/LFM3-1.7B-MLX-4bit`,
   about 0.99 GB, eight files pinned by revision, size and SHA-256
   (`Harness/MLXModelPack.swift`).
3. **Run benchmark.** llama.cpp runs the nine cases of `RuntimeBenchmark`
   first, with a fresh context per case, then is unloaded. Then MLX loads and
   runs the same nine prompts. The two models are never loaded together.
4. Read the summary and the verdict; **Copy results (JSON)** to paste them back.

Both runtimes get the same rendered prompt text and the same sampling
(`SamplingProfile.app`). Tool requests run **without** the tool-call grammar on
both, because MLX has no lazy grammar yet. That keeps the comparison fair; it
also means tool-call numbers are lower than in normal chats.

Keep Keel open: leaving the app stops the run. MLX does not run in the
simulator.

## On a Mac (CI)

`tools/mlx-probe` builds the app's `Sources/MLXRunner.swift` and the harness
into a command-line tool and runs the same cases on MLX. On the CI mirror,
run the workflow by hand with `model_smoke: mlx`. It downloads the pinned
model (`scripts/prepare-mlx-model.py`) and uploads `mlx-probe.txt` and
`mlx-probe.json`. Mac numbers say nothing about iPhone speed; they show that
the MLX path loads the model and produces sensible text and tool calls.

## Versions

- `mlx-swift-lm` pinned to `6352907` on `main`, the first commit with LFM3
  (ml-explore/mlx-swift-lm#750). No release had LFM3 yet.
- `swift-transformers` 1.4.0 for the tokenizer.
- MLX needs Swift 6.3: Xcode 26.4 or later (CI uses 26.6).
