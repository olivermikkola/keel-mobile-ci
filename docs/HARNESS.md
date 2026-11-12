# Keel harness on the phone

Desktop Keel (`olivermikkola/keel`, Rust) exists to make small local models do
useful coding work. Keel Mobile ports the techniques, not the code: there is no
shell, no subprocess and no plugin kernel on iOS.

| Keel technique (desktop source) | What it does | Keel Mobile |
| --- | --- | --- |
| Repeat-tool reminder (`keel-agent/src/guard.rs`) | Same tool + same arguments again → append an escalating reminder at 2, 4 and 7 repeats so the model breaks the loop | Built: `Harness/RepeatGuard.swift`, same thresholds and wording. Not yet wired into the app |
| Tolerant tool-call parsing (`<tool_call>` text fallback) | Small models wrap calls in prose or code fences; recover the call instead of failing the turn | Built: `Harness/ToolCallText.swift` removes a code fence or trailing prose around exactly one call and adds a missing `</tool_call>`. Never changes arguments; the strict parser still decides. Not yet wired |
| Tool-result pruning (`compaction.rs`, `ToolResultPruner`) | Long tool outputs from older turns are shortened so recent ones keep their room | Built: `ToolResultPruner` in `Harness/ContextBudget.swift`, desktop defaults 8192/4096/1024 |
| Context budget sized to the real window (`ContextBudget`, `AdaptiveCompactor`) | Estimate tokens, compact older turns before the window is full, keep recent turns intact | Built: `ContextBudget`, desktop ratios (compact at 75%, aim for 50%, keep 3 recent steps). Folds the oldest whole steps into one summary note. Not yet wired: the app still stops a task after 8 tool calls |
| Environment circuit breaker (`guard.rs`) | Several environment failures in a row → tell the model to stop retrying | Built: `Harness/CircuitBreaker.swift`, trips after 3 failures in a row with advice per GitHub failure kind. Not yet wired |
| Approvals as data (`keel-cli` approvals) | Model output is a request, never permission | Done: proposals need a UI decision (audit P0-1) |

Not ported: shell sandboxing (Landlock), LSP, subagents and swarms, MCP. They
need a host, or they are frozen in desktop Keel.

## Rules

- Harness code is plain Foundation Swift with no UIKit or SwiftUI, so its tests
  run on Linux with `swift test` as well as in the iOS suite.
- A harness change is proven by its tests. Wiring it into the app is a separate
  PR, proven only by the iOS simulator workflow.
- Thresholds and budgets are named constants with the desktop value noted, so
  the two products can be compared.

## Running the tests

On Linux (Swift 6.2 toolchain, no Xcode) or macOS, from the repo root:

```sh
swift test
```

`ToolCallTextTests` reads the strict call pattern straight from
`Sources/RepositoryAgent.swift`, so it fails if the app's parser changes shape.
