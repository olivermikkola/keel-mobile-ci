# Running the whole loop on the phone (no host)

Keel Mobile product plan. Research note, 2026-11-11. This is the original
research, not a current implementation report. See `PRODUCT_GATES.md` and
the README for current scope and validation gaps.
Every number is labelled measured, published or estimated, because the
difference decides the design.

Extracted from `webgpu-agent/apps/ios` on 2026-11-11, when Keel Mobile became its
own product rather than a mode of the gateway client.

The question: can Keel Mobile work with the model, the tools, git and GitHub all
on the phone, with the Beelink switched off?

Short answer: inference, editing, git and GitHub — yes. **Compiling and testing —
no.** That last one has no on-device substitute, so "no Beelink" means "the
executor moves to GitHub Actions", not "the executor disappears". Details below,
including why that is still a good product.

## 0. What the four jobs become

| Job | On the Beelink today | Without it |
|---|---|---|
| Inference | `llama-server` on the host | On-device Metal. Solved, see §1–2 |
| Read/edit files | Keel's shell tools in a workspace | GitHub Git Data API, or a local checkout in the app container |
| Git | `git` binary | GitHub API (no shell). `git2` in-process is the offline option |
| Build and test | `cargo test` in a PTY | **GitHub Actions.** No on-device alternative exists |
| Secrets (SSH, PAT) | Host keychain | iOS Keychain; SSH keys must not exist on the phone at all |
| Agent loop | Keel on the host | Port or reimplement, see §5 |

## 1. The model: 9B is the right target, 4B is the floor

Sizes are from the model docs; Keel scores are from `keel/README.md` (12 toy
tasks, run on the host over Vulkan — **not** a phone measurement).

| Model | PTQ1_0 | PQ2_0 | Q2_0 | Keel suite | Verdict |
|---|---:|---:|---:|---:|---|
| Bonsai 2 · 2B | 0.43 GB | 0.52 GB | 0.55 GB | 4/12 (33%) | Too weak to drive edits |
| Bonsai 2 · 4B | 0.95 GB | 1.15 GB | 1.21 GB | 10/12 (83%) | Guaranteed floor |
| Bonsai 2 · 9B | 2.00 GB | 2.42 GB | 2.56 GB | **12/12 (100%)** | Target |
| Bonsai 2 · 27B | 5.95 GB | 7.21 GB | 7.63 GB | 12/12 | Does not fit |

Memory budget on the actual device: iPhone 15 Pro has 8 GB, of which **~4.5 GB**
is usable by one app (published device tables, not measured by us). The 9B at
2.56 GB leaves ~2 GB for the app, the KV cache and the OS's own peaks. Tight but
plausible. **Skip the vision tower** — it is a separate 0.62 GB file for GGUF and
irrelevant to coding. That is an argument for the GGUF path over MLX, whose pack
fuses an FP16 vision tower into a 3.46 GB container.

One correction to `catalog/models.json`: it lists the 9B phone tier as needing
`min_device_mem_gb: 12`, which would rule out the 15 Pro. That rule of thumb
assumed a 4-bit-class file. A 2.5 GB ternary file fits a 4.5 GB budget, so the
12 GB line is stale. It is still unmeasured, which is what M0 is for.

Speed:

- **Published, iPhone 17 Pro Max (12 GB), MLX Swift:** 2B 89.9, 4B 39.8,
  **9B 22.3 tok/s**. On iPhone 18 Pro Max PrismML quotes 9B "up to 34 tok/s".
- **Published, A17 Pro reference point:** llama.cpp 7B Q4_0 (3.83 GB) at
  **9.01 tok/s** on an iPhone 15 Pro.
- **Estimated for the 15 Pro, 9B Q2_0:** 12–16 tok/s. Bandwidth-scaled from the
  two rows above; treat as a guess until M0.

Quality caveat that matters more than speed: the 9B reasons by default. PrismML
recommends **at least 8,192 output tokens** with thinking on, or turning thinking
off. On a phone, thinking tokens are the difference between a 30 s and a 3 min
answer — so ship with thinking off, or a hard `--reasoning-budget`.

## 2. The runtime

Three real options:

1. **PrismML's llama.cpp, iOS XCFramework.** Their release matrix lists an iOS
   XCFramework, and the fork carries Metal kernels for the ternary types.
   Independently confirmed in our own checkout
   (`~/Projects/llama.cpp`, Aug 2026): `ggml-metal.metal` carries `q2_0` mul_mv
   kernels at line 3846 and `tq2_0` at line 9997, with `GGML_TYPE_TQ2_0 = 35` and
   `GGML_TYPE_Q2_0 = 42` in `ggml.h`. So this is not a CPU-fallback situation.
2. **PrismML's mlx-swift fork.** This is what produced the 22.3 tok/s figure.
   Clean Swift API, but the container is 3.46 GB because of the bundled FP16
   vision tower.
3. **Stock llama.cpp ≥ b11555 with the `Q2_0` file.** Works, but only if the build
   includes Bonsai's Hadamard activation runtime — a runtime that knows `Q2_0`
   without knowing Bonsai 2 loads the file and produces gibberish. (PrismML's own
   docs say b11555 and b11556 in different places; pin an exact build and test it
   rather than trusting the number.)

Recommendation: **option 1, `Q2_0` (2.56 GB), vision tower omitted.** It is the
smallest memory footprint of the three and the one whose kernels we can verify
locally. Keep option 2 as the fallback if the XCFramework's Swift surface is too
awkward.

Apple's own **Foundation Models** framework is worth knowing about but is not
the answer for coding: the on-device model has a **4,096-token context** shared
across instructions, prompt, tool schemas and output, and Apple advises at most
3–5 tools. That is a commit-message or summarisation engine, not a coding agent.
It becomes interesting at iOS 26.4+/27, where `MLXLanguageModel` and
`CoreAILanguageModel` let a local model plug into the framework's tool calling —
but only once the 4K ceiling stops being the binding constraint.

## 3. The part that cannot go native: execution

iOS has no `fork`/`exec`, no shell, no compiler, and no background compute. A
phone cannot run `cargo build`, `pytest`, or a test suite, and it cannot keep an
agent loop alive while locked. So the executor has to be somewhere else, and
"not the Beelink" means **GitHub Actions**:

- `POST /repos/{owner}/{repo}/actions/workflows/{file}/dispatches` — needs a
  `workflow_dispatch` trigger on the default branch.
- Poll `GET /repos/.../actions/runs/{id}` for status and conclusion.
- `GET /repos/.../actions/runs/{id}/jobs` for per-step failures, and
  `/artifacts` to pull results.

Honest cost: queue time plus run time, typically 1–3 minutes for a small Rust
repo, and a cold runner re-downloads dependencies. The agent's turn becomes:
propose patch → wait for CI → read the failure → propose the next patch. That is
slower than a local PTY, and it is the only way to do it with no host.

It also changes the security story for the better: the phone never holds SSH
keys, and CI runs the build, so a compromised phone cannot reach the workspace
directly — only the repo it could already push to.

## 4. Git and secrets on the phone

Two options, and they are not equivalent:

- **GitHub Git Data API** (`/git/blobs`, `/git/trees`, `/git/commits`, `/git/refs`,
  plus `/pulls`). No shell, no clone, no working tree; each file is a request.
  Cheap approach: reuse the blob SHAs of unchanged files, create one tree, one
  commit, one ref update. Recommended first.
- **`git2`/libgit2 in-process.** Gives real local diffs and offline work, at the
  price of a native dependency, credentials plumbing and a working copy on disk.

Secrets: gateway tokens today are already in Keychain (the native client work in
`webgpu-agent-ios-bridge`). A GitHub credential follows the same rule — Keychain
only, never in a URL or a prompt. The repo-scoped GitHub App + device flow from
`IOS_PLAN.md` remains the right long-term onboarding; a fine-grained PAT is the
fast path and should be labelled as one.

## 5. Keel itself on the phone

Reading `keel-agent`, the loop is more portable than expected and the execution
layer is not:

- `vfs.rs` is a transactional VFS with a copy-on-write journal — good design,
  but it assumes a real filesystem to materialise into.
- `sandbox.rs` exposes a `ToolRegistry` and `ToolSpec`, so a different tool set is
  architecturally supported.
- `tools.rs` spawns `sh -c` and kills process groups with `libc::kill`, and uses
  `std::os::unix::process::CommandExt`. It compiles for iOS (Unix) and **cannot
  run there** — no `sh`, no spawn.

Two paths:

1. **Port `keel-agent` as a static library (uniffi → Swift).** Keeps the prompt
   assembly, compaction, guard and epistemic machinery. Costs a cross-compile
   target plus an iOS tool registry with no shell.
2. **Reimplement the loop in Swift.** The loop is small; what carries the value
   is the tool contracts and approvals, and those have to be rewritten for
   GitHub anyway.

Recommendation: **path 2 for the first version**, then borrow pieces from path 1
(compaction, guard, recorder) once the loop is proven. Porting the harness before
the tools exist is backwards.

## 6. The real bottleneck is prefill, not decode

Decode at 12–16 tok/s is usable. Prompt processing is not: published estimates
put a 4K-token prompt at **26 s** on a 2B and **49 s** on a 4B on an iPhone 15
Pro, and a 32K prompt at 3.5–6.5 minutes. A coding turn carries a system prompt,
tool schemas, file content and history — easily 2–6K tokens — so time-to-first-
token of 20–60 s is the honest expectation.

Mitigations, in order of value:

1. **Keep the prompt small.** Short system prompt, 3–5 tools, no file dumps.
   Retrieve the two relevant hunks, not the file.
2. **Reuse the KV cache / llama.cpp slots** across turns instead of re-prefilling
   an unchanged prefix. `LocalInference` now keeps the exact decoded token
   sequence and reuses it only when it is a prefix of the next prompt. The
   hybrid recurrent state is never rewound: a divergent or cancelled turn clears
   the context and pays a clean prefill. This gives the large win on the normal
   append-only tool loop without a second memory-sized state snapshot.
3. **Compact aggressively.** Keel already has `compaction.rs`; it matters far more
   here than on a host.
4. **Speculative decoding.** The 9B ships an MTP draft head (2.68 GB combined with
   PQ2_0). PrismML's notes say the quantized-KV caveat does not affect Metal, and
   speculative gains grow with context. Worth measuring, not worth assuming.
5. **Edit, not rewrite.** Ask for a patch against known content so output stays
   short — the same trick that made the 9B pass Keel's suite in 110 s on a host.

## 7. Milestones

- **M0 — measure, no Beelink involved.** Ship the 9B `Q2_0` to the iPhone 15 Pro
  in a throwaway app, log tok/s, time-to-first-token and the peak of
  `os_proc_available_memory()` at 2K/4K/8K context. This decides 9B vs 4B for
  real, and replaces the stale 12 GB rule in `catalog/models.json`.
- **M1 — offline inference UI.** Chat, tool-call parsing, approval screen, no
  network. Proof that the phone alone is useful.
- **M2 — repository tools.** Read tree, read file, apply patch, open PR, all
  through the Git Data API with a Keychain credential.
- **M3 — Actions as executor.** Dispatch, poll, read the failing job, feed it
  back as a tool result. This is the moment the Beelink is optional.
- **M4 — two honest modes.** "On device, no host" and "paired to a host", with
  the difference visible in the UI. Never silently fall back to a paid model.

## 8. What would kill this

- **Thermals.** Sustained 9B decode on an A17 Pro heats; published numbers are
  "up to", on newer chips, likely short bursts. M0 must run for minutes, not
  seconds.
- **Memory headroom.** 2.56 GB of weights plus app plus KV at 8K context may
  exceed 4.5 GB. The 4B is the fallback, and the app must degrade rather than be
  killed by jetsam.
- **Prefill latency** making the loop feel broken (§6).
- **CI round-trip** making each turn feel like a code review instead of a
  conversation.
- **App Store 2.5.2** if model files were downloaded as executable artifacts —
  they are weights, not code, but the review note has to say so plainly.

## Sources

- PrismML model docs (sizes, sampling, speculative decoding, runtime matrix):
  <https://docs.prismml.com/models/bonsai-2-9b>, <https://docs.prismml.com/download/formats>
- PrismML launch post (iPhone numbers, platform coverage):
  <https://prismml.com/news/prismml-expands-bonsai-2-family-with-2b-4b-and-9b-models-for-on-device-ai>
- Bonsai 2 small whitepaper (MLX Swift on iPhone 17 Pro Max: 89.9 / 39.8 / 22.3):
  `PrismML-Eng/Bonsai-demo/bonsai-2-small-whitepaper.pdf`
- iPhone app memory budget (~4.5 GB of 8 GB) and prefill estimates:
  <https://llmrun.dev/device/iphone-15-pro>
- llama.cpp A17 Pro reference (7B Q4_0, 9.01 tok/s):
  <https://github.com/ggml-org/llama.cpp/discussions/4508>
- Apple Foundation Models context window (4,096 tokens) and tool guidance:
  <https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window>
- Local kernels verified in this repo's checkout: `~/Projects/llama.cpp`,
  commit `4df29be4f`, `ggml/src/ggml-metal/ggml-metal.metal:3846,9997`,
  `ggml/include/ggml.h` (`TQ2_0 = 35`, `Q2_0 = 42`).
