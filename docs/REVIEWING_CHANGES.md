# Reviewing proposed changes

Open **Review changes** in the task to inspect a pending proposal. The screen
shows its repository, immutable base commit, removed/added line numbers and
exact diff. **Show whitespace** reveals spaces and tabs. Opening the review or
choosing Done changes nothing.

**Apply to task** needs a separate confirmation. Keel re-reads the source branch
and byte-verified blob, checks the original SHA and exact UTF-8 content, and
rejects a moved branch or stale proposal. Only after that check succeeds is the
applied decision saved. **Discard proposal** keeps its history but changes no
file. A failed save leaves the proposal pending.

Approved content belongs only to this task. Another task at the same repository
and commit does not inherit it. Relaunch restores decisions without replaying a
model request, applying an edit or contacting GitHub.

Applying edits does not publish them. Open **Publish changes** for a separate
decision: choose an active GitHub Actions workflow, confirm the branch/commit
write, and let Keel dispatch it. The app persists the exact commit and run
identity, polls only the selected workflow and exact `head_sha`, and enables
**Open pull request** only after that run succeeds. A failure leaves the branch
and logs available for review; it does not open a pull request. Direct model
calls to publish remain disabled.

Current operations: exact replacement in an existing UTF-8 file, create a new
file in an existing directory, delete a file, and rename/move a file without
changing its content. Each is a separate proposal with the same immutable base,
byte checks and explicit apply decision. Existing files are limited to 64 KB,
replacement/show text to 4 KB, and a task to 16 proposals. Symlinks and
submodules are not followed. A full local workspace and in-process execution
remain separate audit work; list_files still describes the pinned base tree and
may not show task-local creates/deletes/renames.

Native review UI checks use the simulator-only `--edit-review-fixture` and
`--reset-edit-review-fixture` flags with explicitly recorded GitHub responses.
They prove review, cancel, apply, discard and relaunch control flow, not model
quality or live GitHub publication.
