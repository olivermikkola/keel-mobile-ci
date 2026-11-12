# AGENTS.md — Keel Mobile

Plain language. Oliver is not a Linux specialist: give exact commands and say
what they do.

## What this is
Agentic coding on an iPhone for people who **do not own a computer**. A local
model on the phone, the Keel harness ideas for small models, GitHub for code,
GitHub Actions for build and test. A standalone product: not part of MoE, and
not to be folded into it.

Desktop Keel is the Rust harness with a shell, compiler and git checkout. Mobile
has none of those, so it ports Keel's small-model techniques (see
`docs/HARNESS.md`) rather than its code or execution model. Read
`docs/ON_DEVICE_PLAN.md` before proposing work that assumes a host.

Paired mode (a gateway on someone's own computer) is an **Advanced** option.
No core feature may require it.

## Boundaries that do not move
- **No host, no shell.** iOS has no `fork`/`exec` and no compiler. Any plan that
  ends in "run `cargo test` on the phone" is wrong. Build and test happen in CI.
- **On-device inference is foreground-only.** When iOS suspends the app the
  model stops. Surface it and fail closed; never silently call a paid model.
- **Approvals are explicit.** Model output is input to a tool request, never
  authorization. Diff-touching and publishing need a decision in the UI.
- **Secrets never leave Keychain.** No token in a URL, a prompt, a log, or git.
  Never print a token or key in chat or terminal output.

## Working here
- Swift needs macOS; the Linux box cannot build it. The real check is the
  Codemagic `ios-simulator` workflow, so say what it proved and what it did not.
- Never claim device behaviour from a simulator run. Simulators have no Metal
  compute and different memory limits.
- Keep `project.yml` and `codemagic.yaml` in sync on the bundle ID and scheme.
  The `.xcodeproj` is generated, not committed.
- Small change per branch. One problem per PR.

## Checks
The harness package (`Harness/`, see `docs/HARNESS.md`) is plain Foundation
Swift and also tests on Linux:
```sh
swift test   # from the repo root; runs HarnessTests
```
The app:
```sh
# macOS, or the Codemagic simulator workflow
xcodegen generate --spec project.yml
bash scripts/test-ios-simulator.sh
```
Config-only sanity on Linux: `python3 -c "import yaml,sys;[yaml.safe_load(open(f)) for f in sys.argv[1:]]" project.yml codemagic.yaml`
