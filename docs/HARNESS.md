# Keel harness on the phone

Desktop Keel (`olivermikkola/keel`, Rust) exists to make small local models do
useful coding work. Keel Mobile ports the techniques, not the code: there is no
shell, no subprocess and no plugin kernel on iOS.

| Keel technique (desktop source) | What it does | Keel Mobile |
| --- | --- | --- |
| Repeat-tool reminder (`keel-agent/src/guard.rs`) | Same tool + same arguments again → append an escalating reminder at 2, 4 and 7 repeats so the model breaks the loop | Built: `Harness/RepeatGuard.swift`, same thresholds and wording. Used by the app's tool loop |
| Tolerant tool-call parsing (`<tool_call>` text fallback) | Small models wrap calls in prose or code fences; recover the call instead of failing the turn | Built: `Harness/ToolCallText.swift` removes a code fence or trailing prose around exactly one call and adds a missing `</tool_call>`. Never changes arguments; the strict parser still decides. Used by the app's tool loop |
| Tool-result pruning (`compaction.rs`, `ToolResultPruner`) | Long tool outputs from older turns are shortened so recent ones keep their room | Built: `ToolResultPruner` in `Harness/ContextBudget.swift`, desktop defaults 8192/4096/1024 |
| Context budget sized to the real window (`ContextBudget`, `AdaptiveCompactor`) | Estimate tokens, compact older turns before the window is full, keep recent turns intact | Built: `ContextBudget`, desktop ratios (compact at 75%, aim for 50%, keep 3 recent steps). Folds the oldest whole steps into one summary note. Used by the app; a task still stops after 8 tool calls |
| Environment circuit breaker (`guard.rs`) | Several environment failures in a row → tell the model to stop retrying | Built: `Harness/CircuitBreaker.swift`, trips after 3 failures in a row with advice per GitHub failure kind. Used by the app's tool loop |
| Approvals as data (`keel-cli` approvals) | Model output is a request, never permission | Done: proposals need a UI decision (audit P0-1) |

## The task workspace ("virtual disk")

Desktop Keel works in a checkout on disk. The phone has no checkout, so each
task gets one SQLite database instead (`Harness/TaskWorkspace.swift`):

| Piece | What it does |
| --- | --- |
| Pinned base | The recursive Git tree of the task's commit. A file's bytes are stored only after their Git blob hash matches that tree (`GitBlob`), whether they arrive in a tarball or one at a time |
| Archive import | `importArchive` unpacks GitHub's gzip tarball in plain Swift (`Inflate.swift`, `TarReader.swift`): two requests fetch a whole repository instead of one request per file. Nothing is written to disk as a file |
| Overlay | The changes the user applied in this task (create, edit, delete, rename), rebuilt from the saved task whenever they change. Listing, reading and search all see it |
| Search | `search` covers every stored text file: exact bytes first, then ignoring ASCII case, then files ranked by the query's words (SQLite FTS5, with camelCase parts indexed). The result says which mode matched and how many files it could not cover |
| Repository map | `repoMap` is a table of contents for the system prompt (folders, files, declarations) within a character budget. Byte-stable for the same state, so the prompt prefix stays cached |

Paths are database keys compared byte for byte, never filesystem paths. There
is nothing to traverse out of and no symlink to follow, and `Makefile` and
`makefile`, or two Unicode forms of one name, stay separate files. A folder on
the phone's case-insensitive disk could not promise that.

The app uses it: opening a project imports the archive into the task's
workspace, and the tools read from there.

## Running code

The phone has no shell, so code runs in sandboxes inside the app's process.

| Piece | What it does |
| --- | --- |
| SQL (`Harness/SQLSandbox.swift`) | `run_sql` against a scratch SQLite database, with limits on time, rows, output and database size. Wired into the app (#52). A chat's CSV files load as in-memory tables for each call (`Harness/FileTables.swift`): `sales.csv` is queryable as `sales.csv` or `sales` |
| Scripts (`Harness/ScriptSandbox.swift`) | JavaScript whose only way out is a small set of host calls into the task workspace, each counted against a budget. No network function exists. Wired into the app as `run_js` (#56) |
| Web preview (`Harness/WebPreview.swift`) | Builds one self-contained page from a workspace HTML file: local CSS and JS inlined, a no-network Content Security Policy first. The review screen's Preview button shows it |
| File viewers (`Harness/FileView.swift`, `Markdown.swift`, `StudyDeck.swift`) | Markdown documents, CSV tables and study decks (`Q:`/`A:` cards, `- [x]` multiple choice) as pages behind the same policy. Markdown is escaped, never passed through as HTML; card text is set with `textContent` |

Compiled projects and test suites run on GitHub Actions; the agent reads the
result.

Not ported: shell sandboxing (Landlock), LSP, subagents and swarms, MCP. They
need a host, or they are frozen in desktop Keel. In-app compute stays sandboxed
against task data only (`SQLSandbox` for scratch SQLite; `ScriptSandbox` inside a
locked-down `WKWebView` with no network or host filesystem access).

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

Linux needs the SQLite headers once: `sudo apt install libsqlite3-dev`. Apple
platforms use the SDK's own SQLite. The same tests are part of the iOS test
target, so the simulator workflow runs them against the phone SDK's SQLite.

`HarnessTests/ArchiveFixture.swift` is a real `git archive` of a tiny
repository, generated by `tools/make-archive-fixture.py`.

`ToolCallTextTests` reads the strict call pattern straight from
`Sources/RepositoryAgent.swift`, so it fails if the app's parser changes shape.
