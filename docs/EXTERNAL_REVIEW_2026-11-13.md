# External review checklist (2026-11-13)

An outside model reviewed the public CI mirror and wrote an audit (AUD-01 to
AUD-05) and a roadmap (about 70 items). This is each claim checked against
`main` at `fde19e1`.

**The review read an old snapshot.** The mirror's `main` was `64fdebd` (PR #33,
12 Nov 15:54). It predates the task workspace, repository search and map, the
SQL and script sandboxes and the harness wiring (#36 to #52). It saw 4 harness
files; there are 21.

Marks: `[x]` already done or not a defect. `[~]` partly done. `[ ]` open.
"Not verified" means the claim could not be checked from this repository.

## Wrong premises in the review

- [x] **"`connector/` proxies inference."** No. It is a GitHub sign-in (OAuth)
  broker. `Sources/Gateway.swift` is paired mode: a gateway on the user's own
  computer. There is no hosted model anywhere.
- [x] **"The agent cannot execute anything."** `run_sql` runs in the app (#52).
  The JavaScript sandbox exists in the harness; its app runner is not built.
- [x] **"Context is FIFO pruning only."** `ContextBudget` compacts whole steps,
  `ToolResultPruner` shortens old tool output, and `RepoMap` gives an outline.
- [x] **"0xdead10cc is a GPU kill."** As far as I know that code is for holding
  a file or database lock while suspended, not for GPU work. The background
  GPU risk itself is real; see AUD-03.
- [x] **Its proposed README** describes a repository and diff app, which is the
  framing `README.md` and `AGENTS.md` now reject.

## Audit findings

- [x] **AUD-01 test fixtures in release builds.** Not a defect. All five files
  are wrapped in `#if DEBUG && targetEnvironment(simulator)`, and so is the
  launch-argument code in `KeelMobileApp.swift`.
  - [ ] Optional: have `scripts/verify-signed-ipa.py` assert no fixture symbols.
- [~] **AUD-02 prompt injection through file text.** Mostly done.
  `AgentPrompt.chatML` defuses `<|` and `<tool_response>` in all message text,
  so a file cannot forge a role or a tool result. Tool calls are parsed only
  from model output, and anything that changes files needs approval in the UI.
  - [ ] `<think>` and `</think>` inside file text are not defused. Add the
    escape and a test.
  - [x] HMAC nonces: not needed on top of the above.
- [~] **AUD-03 background GPU work.** Leaving the foreground cancels the reply
  and llama.cpp's abort callback is set. The cleanup is asynchronous, and a
  comment in `LocalChat.swift` says so. Whether iOS ever kills the app in that
  window can only be seen on a real iPhone.
  - [ ] Device test: background the app mid-reply 20 times, check for crashes.
- [ ] **AUD-04 two build definitions.** True: `project.yml` compiles `Harness/`
  as app sources (Swift 5 mode) and `Package.swift` builds it as a package.
  The harness tests run in both, which is the parity check today. Making it a
  real package dependency means marking the app-facing API `public`.
  Low value now.
- [~] **AUD-05 large repositories.** The file browser already walks one folder
  at a time. The workspace import uses the recursive tree (16 MB cap) and the
  tarball (size cap) and refuses a truncated or oversized repository with a
  clear error. So big repositories are refused, not broken.
  - [ ] Lazy import for large repositories. Only when someone needs it.

## Roadmap items that already exist

- [x] INF-09 quantized KV cache (`Q4_0` keys and values)
- [x] INF-12 resumable downloads with hash check
- [x] INF-13 memory check before loading a model
- [x] INF-07 "gear 1": thinking is switched off for every turn
- [x] HAR-06 old tool output shortened (`ToolResultPruner`)
- [x] HAR-08 failure kinds in the circuit breaker
- [x] GIT-03 pull request after a green run on the exact commit, with failed-job
  log excerpts
- [~] INF-10 heat: the reply stops at serious heat; it does not slow down
- [~] HAR-03 repeat guard sorts argument keys; it does not catch overlapping
  line ranges
- [~] AST-02/04/08 `RepoMap` (keyword-based outline, minor folders demoted) and
  FTS5 search exist. No syntax tree, no ranking by references, no embeddings

## Worth doing

In the order I would do them.

- [ ] **HAR-01 grammar-constrained tool calls.** Make the sampler unable to
  emit a malformed call. `llama_sampler_init_grammar_lazy` exists in our local
  llama.cpp checkout. `tools/harness-eval` already counts rejected calls, so
  the gain is measurable on the Beelink before any phone work. Check first
  that the pinned Bonsai framework exports the function. It fixes the shape of
  a call, not a wrong path or argument, so "100% of failures" is an overclaim.
- [ ] **Telemetry line (UX-06).** Prefill and decode tokens per second, memory.
  Needed anyway for the device measurements in `PRODUCT_GATES.md`.
- [ ] **HAR-03 overlapping-read detection.** Small, harness-only, tests on Linux.
- [ ] **INF-07 "gear 2": a capped thinking budget for edits only.** Measure
  with the eval first: does thinking make edits more often correct?
- [ ] **Syntax check before review (WSM-02), without WasmKit.** See below.
- [ ] **AUD-02 remainder and the AUD-03 device test** from above.

## Needs a measurement or an answer first

- [ ] **INF-02 prompt lookup decoding** (guess the next tokens by copying from
  the prompt). Plausible for code. Two blockers. First, the "about 6x" figure
  is not verified. Second, speculative decoding must throw away rejected
  tokens, and our own notes say Bonsai's recurrent state cannot be rewound
  (`ON_DEVICE_PLAN.md` §6). Find out how PrismML's draft head handles that
  before building anything.
- [ ] **INF-01 Metal "few-row" kernels.** We pin PrismML's fork at `b12128`.
  The cited pull request numbers and "v0.6.0" are not verified, and whether
  the fork carries those kernels is unknown.
- [ ] **INF-08 saved model state on disk** to skip the first prefill. Depends
  on the same recurrent-state question, and the files are large.
- [ ] **MCP client (MCP-01).** Fits "a new capability is a new tool". Cost:
  every tool description takes context a small model does not have. Roots,
  sampling and elicitation are not needed.
- [ ] **Syntax tree and reference ranking (AST-01 to AST-05).** Adds a C
  library and one grammar per language. Do it only if the eval shows the model
  fails at finding code rather than at editing it.
- [ ] **Live Activity (UX-01).** The agent stops when the app leaves the
  foreground, so today it could only show "paused" or a CI wait.

## Not doing

- [x] **Editor, per-hunk staging, three-column iPad IDE (UX-03, 04, 05).**
  Against the product direction: not an IDE.
- [x] **Cloud model routing or failover (EDG-02, HAR-07).** Against the rule:
  no fallback to a hosted model.
- [x] **App Attest and JWT sessions (SEC-01, 02).** Built on the wrong premise
  about `connector/`. Revisit only if the sign-in broker is abused.
- [x] **MLX backend (INF-06).** Already rejected in `ON_DEVICE_PLAN.md` §2: the
  MLX pack is 3.46 GB with a vision tower we do not use.
- [x] **INF-04, 11, 14, 15.** Nothing to disable, no adapters exist, and the
  rest is speculative.
- [x] **WasmKit and a plugin ecosystem (WSM-01, 03 to 06).** See below.
- [x] **HAR-04, 05, 12; AST-06, 09, 10; GIT-02, 04; SEC-04; UX-02, 07; CI-03.**
  No evidence yet that any of them fixes a failure we have.

## One idea the review missed

The script sandbox is built on `WKWebView`. Web views already run WebAssembly
with a fast compiler, in a separate process with its own memory. So linters, a
syntax-tree parser, or Python (Pyodide) could run inside the sandbox we already
have, instead of adding a slower pure-Swift interpreter. This is an inference
from the sandbox design, not something tested: the app runner for the sandbox
does not exist yet, and memory next to a 2.5 GB model is unmeasured.
