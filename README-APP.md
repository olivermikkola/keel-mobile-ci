# Keel Mobile

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
| Model | Bonsai 2 4B (1.21 GB) or 9B (2.56 GB), run by a pinned llama.cpp build on Metal. Downloaded once, verified by hash |
| Harness | Tolerant tool-call parsing, repeat-call reminders, a failure circuit breaker and context compaction sized to the model. See [the harness](docs/HARNESS.md) |
| Workspace | Each task gets its own virtual disk: one SQLite database holding the project's files, with search and a project map. No checkout, no paths to escape from |
| Tools | What the model can call. Each has hard limits on time, size and output |
| Approvals | Model output is a request, never permission. Applying a change and publishing it are separate decisions you make in the app |

Code runs in sandboxes inside the app: JavaScript and SQL, with no network and
no access to anything outside the task. iOS cannot compile, so projects that
need a build or a test suite run those on GitHub Actions, and the agent reads
the result.

## Status

Pre-alpha. Everything below is tested on the iOS simulator. Speed, memory and
heat on a real iPhone are not measured yet.

**Works in the app**

- Local chat: streaming replies, stop, saved tasks you can return to
- Model library: download, pause, resume, verify, delete
- Every chat has its own files: what you attach plus the changes you apply.
  No GitHub project needed
- Attach files, and photos as recognised text
- Agent tools: list, read and search files; propose edits, creates, deletes
  and renames
- `run_sql`: the agent runs SQL in a locked-down scratch database. In a chat without a repository, each CSV file is a table: `SELECT * FROM sales.csv`
- `run_js`: the agent runs JavaScript with budgeted access to the chat's files
- Review each proposed change, then apply or discard it. Open what it makes on
  the phone: a web page, a Markdown document, a CSV table, or flashcards and
  quizzes written as `Q:`/`A:` lines
- Open a GitHub project into a task workspace, pinned to one commit
- Publish applied changes to a branch, run a workflow, and open a pull request
  once that exact commit is green

**Not yet**

- Measurements on a physical iPhone
- Work that continues in the background; the agent stops when the app does
- Tools beyond files, code and GitHub

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
