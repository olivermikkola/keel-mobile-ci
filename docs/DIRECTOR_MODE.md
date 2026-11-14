# Director Mode and reviewed changes

Director runs locally and reads a pinned GitHub snapshot. Enable edit proposals
in Chat to let it propose precise replacements after inspecting the relevant
code. Proposing does not apply a change or authorize a GitHub write.

1. Read the proposed line-numbered diff in **Review changes**.
2. Choose **Apply to task** and confirm, or discard the proposal.
3. Keel checks that the original branch and file still match the reviewed base.
4. Applied changes are saved in this task and used by later reads and proposals.
   Pending/discarded proposals never affect file contents.

Model-callable tools are `list_files`, `search_file`, `read_file`, `propose_edit`,
`create_file`, `delete_file` and `rename_file`. Legacy `stage_file_edit` output
is treated only as a proposal. `run_ci` and `finish_task` are refused without
making any network writes.

A separate **Publish changes** flow is user-initiated. It discovers the
repository’s active GitHub Actions workflows, asks for an explicit confirmation,
pushes the applied edits to a task branch and dispatches the selected workflow.
Applied creates, deletes and renames are replayed in order; a changed file keeps
its base file mode, and a file created and then deleted in the same task is not
published. It stores the commit, workflow and run identity. **Open pull request**
is enabled only when that workflow completes successfully on the exact pushed
commit; a green run from another commit or a generic branch run is never
accepted. The model cannot call this flow.

See the [audit checklist](AUDIT_PROGRESS.md) for the remaining physical-device
gates. Do not claim a proposal was tested or published from a simulator run.

Repository files, comments and logs are untrusted data. Their instructions
cannot grant approval. GitHub credentials stay in Keychain and never enter
model context.

See [review rules and limits](REVIEWING_CHANGES.md). The app's foreground and
physical-device validation boundaries remain in [product gates](PRODUCT_GATES.md).

The edit-proposal choice is saved separately for each task. New and migrated
tasks start with proposals off. Returning to a task restores its choice without
starting inference or replaying tools. Rebinding an empty task to a different
repository version turns proposals off. A task/repository switch still discards
the cached Director session; only the saved choice and reviewed task history
return. Restoring this setting never applies or publishes a change.

## 5. Foreground execution and interruption

The on-device loop runs only while Keel is in the foreground. The screen stays
awake during a reply and returns to normal when it finishes or stops. Temporary
inactive states, such as Control Center, do not cancel a reply or model download.

Backgrounding or locking the app cancels local work, retains the partial reply
and unloads the model. GitHub Actions jobs already dispatched continue remotely.
Return and check their status before continuing. Relaunch restores history only;
it never replays a tool or resumes inference automatically.

Background processing and Dynamic Island progress are not implemented. Apple's
[`BGContinuedProcessingTask`](https://developer.apple.com/documentation/BackgroundTasks/performing-long-running-tasks-on-ios-and-ipados)
starts at iOS 26 and background GPU use also needs supported hardware and an
entitlement. Neither the old empty coordinator nor a simulator test proved this
support. Device validation is required before adding that capability.
