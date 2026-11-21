# AGENTS.md — Keel Mobile

Plain language. Oliver is not a Linux specialist: give exact commands and say
what they do.

## What this is
A local AI agent for iPhone. The model runs on the phone and acts through
tools: files, search, code execution, data, GitHub. It is the app you open
because it is local and it can do the job. A standalone product: not part of
MoE, and not to be folded into it.

Coding is the first and hardest capability, so most current work is the coding
loop. It is not the whole product. Once the agent can read, change and run a
project reliably, most other jobs are a matter of adding the right tool.

## What this is not
- **Not an IDE or a git client.** Do not build file-tree editors, branch
  pickers, commit screens or diff tooling as places the user lives in. The user
  states a goal, follows activity and approves. A diff is shown when a decision
  needs it. Git, branches and pull requests are plumbing.
- **Not a remote control for a computer.** Paired mode (a gateway on someone's
  own machine) is an **Advanced** option. No core feature may require it.
- **Not a cloud client.** No silent fallback to a paid or hosted model.

When writing copy, UI text or docs, lead with what the agent can do, not with
repositories, commits and PRs.

## Adding a capability
A capability is a tool the model can call. Before proposing a new screen or
mode, ask whether it is a tool. A tool needs:
- a strict call format and a clear, short result for a small model;
- named limits for time, size and output;
- no reach outside the task (no app files, no network unless that is the tool);
- tests in `HarnessTests/` first, app wiring as a separate PR.

## Boundaries that do not move
- **No shell, no subprocess, no compiler.** iOS has no `fork`/`exec`. Code runs
  in in-process sandboxes (`Harness/ScriptSandbox.swift`,
  `Harness/SQLSandbox.swift`). Anything that needs a build or a test suite runs
  on GitHub Actions. A plan that ends in "run `cargo test` on the phone" is
  wrong.
- **No graphics processor in the background.** iOS refuses it on every
  iPhone. On iOS 26 a reply the user started may carry on after they leave
  the app, with iOS's permission (a continued background task) and on the CPU,
  which is slower; llama.cpp moves there and keeps what it has read
  (`InferencePlacement`). MLX, Apple's model, photos and older iOS versions
  stop when the app is left. When iOS suspends or ends the work, the model
  stops: surface it and fail closed.
- **Approvals are explicit.** Model output is input to a tool request, never
  authorization. Changing files and publishing need a decision in the UI.
- **Secrets never leave Keychain.** No token in a URL, a prompt, a log, or git.
  Never print a token or key in chat or terminal output.

## Working here
- The harness (`Harness/`, see `docs/HARNESS.md`) is plain Foundation Swift.
  Desktop Keel is Rust with a shell; its techniques are ported, not its code.
- The app needs macOS to build; the Linux box cannot. Native checks run on the
  public CI mirror or Codemagic (`docs/BUILDING.md`, `docs/CI_MIRROR.md`). Say
  what a run proved and what it did not.
- Never claim device behaviour from a simulator run. Simulators have no Metal
  compute and different memory limits.
- Keep `project.yml` and `codemagic.yaml` in sync on the bundle ID and scheme.
  The `.xcodeproj` is generated, not committed.
- Size a PR by the work, not by its line count. One PR may carry a whole
  feature, or several related fixes together. Do not split work to keep PRs
  small: every PR pays a Mac check run, and runs queue behind each other.
- Do not sit waiting on checks. Publish the branch to the mirror, then start
  the next piece of work on a new branch off main and come back when the run
  has finished.
- `scripts/make-ci-mirror.sh` picks the checks for a branch: light (iPhone
  compile and unit tests) unless the branch changed a screen, a UI test,
  resources, the project file or the CI. A light pass is enough to merge. After
  merging, publish main to the mirror: that runs the full UI suite. If main
  fails there, fixing it comes before anything else.
- Headless only for builds and tests; never open GUI windows on the desktop.

## Checks
The harness package:
```sh
swift test   # from the repo root; runs HarnessTests (Linux: needs libsqlite3-dev)
```
The app:
```sh
# macOS, or CI
xcodegen generate --spec project.yml
bash scripts/test-ios-simulator.sh
```
Config-only sanity on Linux: `python3 -c "import yaml,sys;[yaml.safe_load(open(f)) for f in sys.argv[1:]]" project.yml codemagic.yaml`
