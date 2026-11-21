# Keel Mobile audit work

Source: `../reports/keel-mobile-audit-2026-11-11.md`, snapshot `de66959`.
This is the implementation and evidence checklist, not a completion claim.
Check the current branch, PR and real test artifacts before promoting an item.
A scripted-model test proves control flow only; simulator results do not prove
iPhone Metal performance, memory headroom, thermals or lock recovery.

| Finding | Required result and evidence | State |
| --- | --- | --- |
| P0-1 approvals | Persist proposals, readable diff, explicit apply, separate publication/CI/PR decisions; injection-shaped calls cannot mutate GitHub | PR #20 merged (`be0c4ac`); 91 passed, 5 skipped. Model tools can only read and propose; apply is an explicit UI decision. Publishing/CI/PR tools are refused, so no model output can mutate GitHub. A reviewed publication flow is drafted in #30 and is gated on native CI. |
| P0-2 background claims | Implement supported background behavior or remove unsupported claims and stop safely | PR #16 merged; 78 unit and 3 UI tests passed, 4 optional skips; device gate open |
| P0-3 task isolation | Bind session to task and full snapshot; switch/delete/rebind regressions | PR #15 merged; 80 unit and 9 UI tests passed, 5 optional skips |
| P1-4 prefill reuse | Checkpoint hybrid/recurrent state, reuse exact token prefix, invalidate safely; actual runtime cached/uncached equivalence and prompt-token counters | PR #22 merged (`2832e49`); 94 passed, 5 skipped. Append-only exact-token prefix reuse; divergence and cancellation clear the context, so recurrent state is never rewound. Prompt-token counters are tested. Device timing remains open. |
| P1-5 memory | Metadata-derived attention and recurrent budgets; overflow/missing-metadata tests; measured runtime/device allocations | PR #21 merged. Budget uses the pinned GGUF metadata (8 full-attention layers, 4 KV heads, 256-wide K/V), Q4_0 bytes and recurrent state: 9B/32K = 3.29 GB, 4B/16K = 1.80 GB. Simulator run `d4fa1c2` passed 94 tests; the one failure was the test’s own off-by-one constant, fixed in `bd9ca37`. Device compile passed on `d4fa1c2`. Physical-device measurement remains open. |
| P1-6 CI | Discover workflows; observe selected workflow and exact SHA, persist run identity, no stale success, green exact commit required before reviewed PR | PR #30: explicit branch/CI confirmation, persisted commit/run identity and reviewed content hashes, strict workflow/run/commit checks, fresh CI and branch checks before PR creation, and idempotent repeat PR actions. Queued reruns clear cached success; same-path edits invalidate the published review. Publishing replays #31's create/delete/rename operations in order and keeps base file modes. Publish-screen visual checks, a real GitHub write and physical-device checks remain open. |
| P1-7 file/workspace operations | Reviewed create/delete/rename with byte identity and stale-base rules; per-task local workspace; investigate safe in-process execution | PR #31: create/delete/rename proposals, explicit apply and task-local reads, including rename-then-recreate, empty files and byte-distinct Unicode paths. Saved history retains absence markers so deleted/moved sources cannot reappear without an explicit create. Listings still describe the pinned base. The per-task workspace now exists in the harness package (SQLite virtual disk, hash-verified tarball import, overlay, repository search and map; 20 tests on Linux and in the iOS suite) but the app's tools do not use it yet. In-process execution remains open. |
| P1-8 credentials | Scope guidance by browsing/publishing/dispatch, actionable missing-permission errors; research repository-scoped GitHub App onboarding | PR #19 is a draft. Native code/unit tests passed, but the latest UI test run failed two timing/scroll assertions on `1efcddc`; the test-only fix `d4f921e` is unbuilt because Codemagic now returns `402 BILLING_NOT_ENABLED`. GitHub owner setup, browser OAuth and physical-phone sign-in remain open. |
| P2-9 lifecycle | Inactive overlay keeps work; background stops; idle timer resets; memory warning saves and unloads | PR #16 merged; device behavior still needs validation |
| P2-10 robustness | Malformed call recovery, bounded protocol, byte-exact edits/entities, bounded output, matrix job logs, stale base, persisted Director/CI state, interrupted rows, task-specific mode, idempotent PR | PR #20 covers malformed calls, exact edits/entities, bounded output, stale bases, persisted proposals/decisions and interrupted rows. PR #33 saves proposal mode per task, defaults legacy tasks off, rejects mode changes during work or failed storage, and discards cached sessions on task/repository/mode changes. PR #30 adds idempotent PR actions and failed-job log excerpts. |
| P2-11 scaling | Off-main task persistence, bounded chunked HTTP, immutable verified content cache/workspace, prefill progress, explicit locked-file policy | PR #32: streaming checkpoints coalesce on a serial utility queue and critical saves wait for them; GitHub API reads enforce limits before each data-chunk append and cancel oversized responses during transfer; verified blobs are cached by content SHA (64 entries / 8 MB); prefill reports `done/total` tokens and the composer shows a spinner. Regression tests cover declared and unknown-length overflow and in-flight cancellation. Remaining: full per-task workspace and on-device timing. |
| P2-12 tests/CI | Native check on latest PR head; meaningful adversarial tests for the above; real model and physical-device gates reported separately | Visual (#18), review (#20), prefix (#22) and recovery (#23) passed their latest-head simulator runs (101, 91, 94 and 92 passed; 0 failed). Main integration and the memory test-only commit are unbuilt because Codemagic returns `402 BILLING_NOT_ENABLED` for new builds. |
| P2-13 docs | Correct entitlements copy/API claims, edit guidance, staging cleanup fixture, saved-task fixture docs, local-network usage text and LAN/Tailscale validation | Most copy/API claims were corrected in #16/#18/#20/#28, including the token scopes, fixture launch arguments and `NSLocalNetworkUsageDescription`. Remaining: the legacy `.partial` cleanup and its test. |
| Additional: missing Director history | Pass user request and tool observations through real ChatML assembly; inspect model input in regression | PR #17 merged; 80 unit and 3 UI tests passed, 4 optional skips |

## Integration state — 12 November 2026

`main` after the audit-doc merge is `75c2f0b` and contains #18 (visual/palette),
#20 (review/apply approval gate), #22 (append-only prefix reuse), #21
(hybrid-attention memory budget) and #23 (download recovery). All five branches merged without conflicts.
Their individual simulator evidence is listed above.

A final test run on the integrated `main` could not start: Codemagic returns
`402 {"error":"BILLING_NOT_ENABLED"}` for every new build. The last queued
device compile (`d4fa1c2`) passed, and the last queued simulator runs passed on
their own heads. Do not treat the integrated commit as green until billing is
enabled and the `ios-simulator` + `ios-device-compile` workflows run on it.

## Research and improvement decisions

- Start with the existing byte-verified repository tools and exact edit/diff
  implementation. Do not add a second weaker resolver or text replacement path.
- Apple's continued-processing task is iOS 26+, with GPU resource checks and an
  entitlement. An empty coordinator is not background support. Keep foreground
  semantics honest until hardware validation exists.
- Pinned PrismML runtime `d7b2896`: `llama-memory-hybrid.cpp` filters recurrent
  layers out of the attention KV cache. The old flat 40 KB/token guard is not a
  model-derived estimate. Recurrent state and compute allocations still count.
- Prefix caching must restore recurrent state, not just remove KV suffixes.
  The merged implementation avoids rewinding entirely: it reuses only when the
  whole decoded sequence is an exact prefix, and otherwise clears the context.
  This needs no second memory-sized checkpoint. Device output equivalence and
  timing still need measurement against a clean prefill.
- Evaluate PQ2_0/PTQ1_0, the vendor's thinking-off sampler, Qwen/Granite tiers,
  and speculative decoding on a fixed coding-task slice. Do not switch defaults
  based only on file size or host benchmarks. Verify template and license for
  each candidate. No added model or speed claim until the comparison passes.
- Research interpreter isolation before adding Python/Node/ios_system.
  A directory prefix or `ios_setMiniRoot` is not a security boundary for native
  code. A local runtime must not reach Keychain, transcripts, model storage or
  arbitrary networks. GitHub CI remains necessary for compiled projects.
- UI library/editor/terminal suggestions are candidates, not dependencies to add
  indiscriminately. Prefer the smallest implementation that solves an observed
  phone workflow problem and validate with actual screens.

Sources inspected:

- [Apple continued processing](https://developer.apple.com/documentation/BackgroundTasks/performing-long-running-tasks-on-ios-and-ipados)
- [GitHub workflow runs](https://docs.github.com/en/rest/actions/workflow-runs)
- [Pinned hybrid memory implementation](https://github.com/PrismML-Eng/llama.cpp/blob/d7b2896/src/llama-memory-hybrid.cpp)
- [Vendor prompt-cache guidance](https://github.com/PrismML-Eng/Bonsai-demo/blob/main/PROMPT-CACHE.md)

## Completion gate

Every row above needs current evidence, including each listed subproblem.
Keep unresolved design choices and device measurements open. Before calling
this audit complete, run native tests on the final integrated commit, inspect
review screens on iPhone/iPad/larger text, complete a real approved repository
change with exact-commit CI and recovery, and verify the selected models on the
physical phone. Do not treat documentation or fixture-only tests as that proof.
