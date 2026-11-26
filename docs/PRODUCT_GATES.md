# Keel Mobile product gates

The goal is a local agent people open every day: easy model setup, a harness
that makes small models reliable, and tools that let the model do the work
rather than describe it. Coding is the first and hardest capability, and most
gates below are about it. Other capabilities arrive as tools on the same loop.
It is not an IDE or a git client: GitHub is where finished work goes, behind an
approval. No feature may require a paired host. Downloading a model and showing
chat does not finish it.
Native iOS uses Metal; WebGPU belongs to the browser product.

## Model and conversation experience

- Download a pinned model, see progress, cancel, verify it, select it and reclaim
  storage. No prompts leave the device for local inference.
- Stream real replies, stop promptly, retain partial text on interruption and
  explain context/memory/thermal failures without switching providers.
- Persist conversations and support returning to several tasks, renaming and
  deleting them explicitly. Saved tasks now preserve separate conversations and
  repository snapshots; latest native checks remain the evidence gate.
- Measure the target iPhone with 4B and 9B: first-token latency, sustained decode,
  peak memory, heat, background/foreground recovery, and airplane-mode replies.
  A simulator check is not evidence for these device gates.

## Repository work

The GitHub browser selects a branch and reads verified text at a pinned commit.
Director can propose exact replacements for explicit diff review and local task
approval. Direct automatic pushes, workflow dispatch and PR creation are disabled
while the separate reviewed publishing flow is completed.

Local work stops when the app enters the background; already-dispatched GitHub
CI continues remotely. Background processing and Dynamic Island progress are not
implemented. Physical-device lock recovery remains a validation gate.

- Connect GitHub with a credential kept in Keychain, choose repository and branch,
  then capture an immutable commit as the task’s starting point.
- Let the model list/search/read bounded repository content. Never put the
  credential in model context, logs or URLs; reject incomplete/truncated reads.
- Stage precise file changes locally and review readable diffs. Apply only after
  an explicit UI decision, reject stale bases, and retain a recoverable task.
- Create a separate branch, commit and PR only after a separate publishing
  decision. Never infer permission from a model answer.
- Surface CI for the exact proposed commit, inspect failing jobs, and let the
  agent propose a fix. Clearly distinguish queued, failed, cancelled and passed.
  The phone cannot compile or run a repository’s tests.

## Agent and review experience

- Start from a task and repository, follow readable activity, send follow-ups,
  and see whether the agent is working, needs review, stopped, failed or finished.
- Bound the tool loop and context; model output is always untrusted tool input.
  Editing, publishing and workflow dispatch have explicit approvals.
- Restore interrupted tasks without replaying a mutation or silently resuming
  on-device compute after a relaunch.
- Keep execution location visible: on-device inference, GitHub repository/CI
  actions, or paired-host tools. Host work can outlive a phone connection;
  on-device inference cannot.

## Evidence required before calling the app finished

- Native simulator build and meaningful XCTest/UI checks on the latest commit,
  with inspected screenshots, including larger text and iPad layouts.
- A physical-device run covering model setup, offline chat, interruption,
  an approved repository change, PR publication, CI feedback and recovery.
- A real repository task completed end to end; no scripted model response used
  to claim coding-agent quality or readiness.

Design references: [Locally / LM Link](https://lmstudio.ai/docs/lmlink/lmlink-in-locally)
for accessible model setup and clear device location;
[Cursor for iOS](https://cursor.com/docs/cloud-agent/mobile) for task activity
and follow-ups only, not for its editor or git surface. These are interaction
references, not claims that Keel implements either service’s protocol or cloud
infrastructure.
