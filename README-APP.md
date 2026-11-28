# Keel Mobile

Try the [TestFlight beta](https://moesystems.com/keel-mobile/) on iPhone or iPad running iOS or iPadOS 17+. Model fit depends on device RAM. See [the audit and verification log](docs/AUDIT_PROGRESS.md) for the latest build and physical-device evidence.

A local AI agent for iPhone. The model runs on the phone, and it can do things:
read and change files, search, run code, query data, and ship work to GitHub.

No computer. No model server. No cloud model behind it.

## The idea

Most local-model apps stop at chat. Keel Mobile is the one you open because the
model is yours, it is on the device, and it has tools.

- **One agent, many tools.** Every capability is a tool the model can call:
  files, search, a code sandbox, a SQL sandbox, GitHub. A new capability is a
  new tool, not a new app.
- **Coding comes first because it is the hardest.** An agent that can read a
  project, change it, run it and fix what broke can do most other jobs with the
  right tool added. So the coding loop is where the work goes now.
- **Not an IDE.** There is no editor to live in and no git client to learn.
  You say what you want, watch what the agent does, and approve what matters.
  Branches, diffs and pull requests are plumbing behind that approval.
- **Small models, made reliable.** Keel is the harness that makes small local
  models do real work. Keel Mobile carries its techniques to the phone.

It is for anyone who wants a capable agent on their own device, including
people whose only computer is their phone.

## How it works

| Piece | What it does |
| --- | --- |
| Model | LFM3 1.7B, LFM3 VL 2B (photos), MiniCPM5 2B, Qwen3 0.6B, and Bonsai 2 2B/4B/9B. Pinned downloads, custom GGUF imports from Files or Hugging Face links, model-specific templates and a shared llama.cpp runtime on Metal |
| Harness | Grammar-constrained tool calls, tolerant tool-call parsing, leaked-reasoning stripping, repeat-call reminders, a failure circuit breaker and context compaction sized to the model. See [the harness](docs/HARNESS.md) |
| Workspace | Each task gets its own virtual disk: one SQLite database holding the project's files, with search and a project map. No checkout, no paths to escape from |
| Tools | What the model can call. Each has hard limits on time, size and output |
| Approvals | Model output is a request, never permission. Applying a change, searching the web and publishing to GitHub are separate decisions you make in the app |

Code runs in sandboxes inside the app: JavaScript and SQL, with no network and
no access to anything outside the task. iOS cannot compile, so projects that
need a build or a test suite run those on GitHub Actions, and the agent reads
the result.

## Status

Public TestFlight beta ([join here](https://moesystems.com/keel-mobile/)). Automated checks run on Linux (`swift test`) and the iOS simulator + unsigned arm64 iPhone device compile; formal physical-device benchmark tables (tok/s, memory ceiling, heat) are still being logged in [docs/AUDIT_PROGRESS.md](docs/AUDIT_PROGRESS.md).

**Works in the app**

- Local chat: streaming replies, stop, saved tasks, Projects with shared instructions and read-only `project/` files, opt-in Memory facts, standing custom instructions (`Customize`), a capped `Thinking` toggle in the `+` menu, live context/thermal status pill, 1-tap local model fallback if Apple's safety filter refuses a reply, hands-free Voice conversation, and tap-to-run scheduled tasks
- Inference & memory controls: Q8_0 quantized KV cache with Metal Flash Attention for small and imported GGUF models (Q4_0 for Bonsai), user-selectable context window cap (`Auto` / `4K` / `8K` / `16K` under **Models → Advanced**), zero-RAM n-gram speculative decoding for pure-attention models, and an in-app **Phone report** (`About → Phone report`) plus runtime benchmark
- Background continuation on iOS 26+: model downloads, llama.cpp text replies (moved from GPU to CPU while backgrounded, slower than foreground), and short video renders can request a continued background task (`BGContinuedProcessingTask`) with Lock Screen / Dynamic Island progress; older iOS, MLX, Apple's model, and photo chats stop cleanly when you leave the app
- Model library: download, pause, resume, verify and delete pinned models, or import a custom GGUF model from Files or a Hugging Face link
- Send to Keel: share text, files, links, or photos from Photos, Files, Safari, or Mail via the iOS share sheet or **Open in Keel Mobile**, or prefill chats via `keelmobile://ask?text=...` and `keelmobile://open?url=...`
- Every chat has its own files: what you attach plus the changes you apply.
  No GitHub project needed
- Studios & Apps in the sidebar: **Images** (Core ML Stable Diffusion 2.1), **Videos** (short narrated videos with Kokoro neural TTS or Apple voices), **Carousels** (photo slide decks exported as PNG/PDF), **Decide** (ask the same questions across many PDFs/files with CSV export), and chat presets for Websites, Sheets, Docs, Study and Slides with built-in viewers, PDF export, and a **Library** of everything created
- Attach files, photos as recognised text, or photos directly with `LFM3 VL 2B`; dictate messages offline (`SFSpeechRecognizer`) and read replies aloud (`AVSpeechSynthesizer`)
- Agent tools: list, read and search files; propose edits, creates, deletes
  and renames; read user-linked web pages (`read_url`); search the web after you approve the exact query (`web_search`); opt-in on-device Calendar & Reminders tools (`EventKit`, approval-gated for writes, toggled in `Customize`); and use connected services such as Notion or Linear, added with one tap and switched on per chat (`mcp_*`)
- `run_sql`: the agent runs SQL in a locked-down scratch database. In a chat without a repository, each CSV file is a table: `SELECT * FROM sales.csv`
- `run_js` and `shell`: the agent runs JavaScript or an in-process JavaScript bash interpreter with budgeted access to the chat's files
- Review each proposed change, then apply or discard it. Open what it makes on
  the phone: a web page, a Markdown document, a CSV table, or flashcards and
  quizzes written as `Q:`/`A:` lines
- Open a GitHub project into a task workspace, pinned to one commit
- Publish applied changes to a branch, run a workflow, and open a pull request
  once that exact commit is green

**Not yet**

- Formal measurements on a physical iPhone (tok/s, peak memory, heat, and iOS 26 background continuation acceptance)

## Rules

- **Local means local.** If the on-device model cannot run, the app says so and
  stops. It never falls back to a cloud or paid model.
- **You approve, the model asks.** Nothing changes a file or leaves the phone
  because the model said so.
- **Secrets stay in Keychain.** Never in a prompt, a URL, a log or git.
- **Standalone.** No feature may need a paired computer. Pairing with your own
  machine exists, under [Advanced](docs/PAIRED_MODE.md).

## Repository

| Path | What |
| --- | --- |
| `Sources/` | The iOS app (SwiftUI) |
| `Harness/` | KeelHarness: plain Foundation Swift, also tested on Linux |
| `HarnessTests/`, `Tests/`, `UITests/` | Harness, app and UI tests |
| `tools/harness-eval/` | Scores real Bonsai output against the app's parser |
| `connector/` | Small OAuth broker for GitHub sign-in |
| `ci/`, `scripts/`, `codemagic.yaml` | Build, test and release |

## Develop

```sh
swift test    # harness tests, Linux or macOS
```

```sh
# the app, on macOS
brew install xcodegen
bash scripts/prepare-llama.sh
bash scripts/prepare-test-model.sh
xcodegen generate --spec project.yml
bash scripts/test-ios-simulator.sh
```

No Mac? CI runs the same checks. See [building and shipping](docs/BUILDING.md).

## The Keel family

One engine, focused surfaces — the canonical positioning is the
[Keel product vision](https://github.com/olivermikkola/keel-code/blob/main/docs/VISION.md).
Keel Mobile is the standalone on-device member: it carries the harness
techniques to the phone and never requires a paired computer.

| Product | What it is |
| --- | --- |
| [Keel Code](https://github.com/olivermikkola/keel-code) | CLI + TUI coding agent (`keel`) for small local models |
| [Keel Desktop](https://github.com/olivermikkola/keel-desktop) | Everyday local-AI app: Chat, Work, Images, Code |
| **Keel Mobile** (this repo) | Standalone on-device iPhone agent — the model runs on the phone |
| [Keel Console](https://github.com/olivermikkola/keel-xbox) | Living-room app for Xbox / TV |
| [Keel Arena](https://github.com/olivermikkola/keel-arena) | Public benchmarks and scorecards — the proof layer |

## Docs

- [Product map](docs/PRODUCT_MAP.md): where this is going
- [Product gates](docs/PRODUCT_GATES.md): what "finished" means
- [The harness](docs/HARNESS.md): small-model techniques and the task workspace
- [Local models](docs/LOCAL_MODELS.md): downloads, limits, what stops a reply
- [Projects from GitHub](docs/REPOSITORIES.md) and
  [reviewing changes](docs/REVIEWING_CHANGES.md)
- [Building and shipping](docs/BUILDING.md), [CI mirror](docs/CI_MIRROR.md)
- [Paired mode](docs/PAIRED_MODE.md)
- [On-device research note](docs/ON_DEVICE_PLAN.md), 2026-11-11

Copyright (c) 2026 Oliver Mikkola. All rights reserved. See [LICENSE](LICENSE).
