# Read a repository from your iPhone

Open **Connect → Open a GitHub repository**. Enter `owner/repository` or paste
its `https://github.com/owner/repository` address. Leave the branch empty to
use the default branch, or enter a branch name. Tap **Open repository**, then
**Browse files**.

Public repositories need no credential. For private repositories, enter a
fine-grained GitHub token with access to the chosen repository and **Contents:
read** permission. Keel saves it in the iOS Keychain only after successfully
opening the repository. The token is not placed in URLs, UserDefaults, model
context or logs. **Forget GitHub token** removes this app’s saved credential;
it does not revoke the token on GitHub or change the gateway pairing.

The selected branch resolves to a fixed commit and tree. Opening a file reads
its blob from that tree, so a branch update cannot silently replace the code
you are inspecting. Reopen the repository to select a newer commit.

The browser reads one directory at a time and shows UTF-8 text files up to
256 KB. It verifies blob size and Git object hash, rejects truncated or
inconsistent responses, and does not follow symlinks or submodules. Large or
unsupported content produces an explanation instead of partial text. Network
requests can be cancelled by leaving the screen; opening a repository also
has a Cancel button. GitHub error response bodies are never shown.

## Ask the local model about the repository

In an empty **Chat**, tap **Attach a repository**, open a branch, then choose
**Use in this chat**. Download/select a model under **Models**, return to Chat,
and ask a specific question. The model can call `list_files`, `read_file` and
`search_file`;
file results return to the model on the phone. The header shows the repository,
branch and fixed commit. GitHub serves the requested files; prompts and model
inference stay on the device. This mode needs network access for file reads.

Expand an activity row to inspect the actual lines read. Keel verifies the full
blob before passing the requested line range to the model. Folder listings are
paginated; reads default to 30 lines, allow at most 60 per request, and reject
results over 6,000 bytes instead of silently truncating them. Paths are resolved
from the task's fixed root tree; the model cannot choose a URL, SHA, credential
or different repository. Malformed, duplicate, unknown and incomplete tool
requests stop without execution. A well-formed known call with an invalid
numeric argument returns its allowed range to the model without fetching any
repository data. Rejected attempts consume the same eight-request budget;
values are never clamped or silently widened. A response that hits the output-token limit
cannot execute a tool. The loop stops after eight tool requests per message.

`search_file` finds literal, case-sensitive UTF-8 bytes in one known file at the pinned
commit. It verifies the entire supported blob before scanning, then returns
matching full lines and their original line numbers. `query` must be 1–256 UTF-8
bytes with no control characters or line breaks. Whitespace is significant;
put the query on one line inside its parameter tags. Encode `<` as `&lt;` and
`&` as `&amp;` in XML calls. Regex operators are plain text. `start_line` defaults
to 1; `count` defaults to 30 and allows 1–60 matching lines. Follow
`next_start_line` to continue. `remaining_matches` counts matches from the
requested starting line. Zero matches covers only that file range. Results
over 6,000 bytes fail without returning truncated lines. This is file search,
not a whole-repository search index.

Directory results explicitly contain names and types only. A reply's footer
reports the number of distinct files actually read in that turn; listing a
directory does not count as a file read. A successful search verifies the file
and counts as a read, including when its result has zero matching lines. This records tool evidence, not a
guarantee that the model's answer is correct. Earlier verified reads remain
in conversation context at the same pinned commit.
The runtime also enforces its 4,096-token context limit; it explains overflow
rather than silently dropping task history.
Missing paths, invalid ranges and unsupported/oversized files return a read
error to the model so it can choose a valid request within the same eight-call
budget. They are labelled **Not read**, never verified. Authentication,
rate-limit, inconsistent-data and cancellation failures stop the loop.

The snapshot, messages and tool results are saved together in protected app
storage, excluded from backups. Relaunch restores history without replaying
requests. **Stop** or leaving the foreground cancels inference and requests;
there is no automatic resumption or cloud fallback. Start a new chat to change
the attached repository version. **New chat** keeps the previous task; open
**Saved tasks** to return to it, rename it or explicitly delete it. Each task
keeps its own pinned commit. Unreadable saved history blocks new tasks and
changes until **Saved tasks → Reset saved tasks** is explicitly confirmed;
reset first keeps a protected recovery copy on this device.

This is the read layer for repository work. Cross-file discovery, editing, publishing and CI
execution still require their own implementation and explicit review decisions.
No shell or gateway is used for this loop.

## Verification

The native suite covers fixed-commit reads, branch URL encoding, object
integrity, truncated directories, response limits, credential isolation and
Keychain save/update/removal. The repeatable simulator UI check uses four
recorded public GitHub responses captured from `octocat/Hello-World` at commit
`7fd1a60b01f91b314f59955a4e4d4e80d8edf11d`. It exercises the real parser,
blob verification, navigation, attachment and relaunch with an explicitly
enabled debug-simulator transport. The transport is absent from device builds.
These screenshots are recorded-response UI proof, not live network proof.

The separate `ios-live-repository` workflow opens the real public
`octocat/Hello-World` repository and reads its verified README through the app.
It needs GitHub network access, and fails rather than substituting mock data.
It also attaches that snapshot to Chat and checks restoration after relaunch.
Shared runner IPs can exhaust GitHub's anonymous request quota, independently
of code changes. Live quota failures remain visible in that gate; neither the
recorded UI run nor the scripted unit tests substitutes for a successful live
check. Screenshots are exported in each workflow's artifacts.

Agent integration tests use scripted model responses to exercise verified path
resolution, pagination, bounded reads/turns, invalid calls, foreground
cancellation, migration and protected storage. These are control-flow checks,
not evidence of model quality. The opt-in `ios-model-tool-smoke` uses the real
pinned Bonsai 4B with the recorded responses to isolate actual model/tool use.
That recorded workflow also requires the actual model to use `search_file` and
obtain a verified matching line, rather than only guessing or using read_file.
The separate `ios-agent-smoke` runs the reading task with live GitHub and no
fixture fallback. Both require an actual verified file read; a guessed answer
fails. The live workflows check the runner's anonymous API quota before
downloading or building, and fail early if it is low. Quota can still change
while a test runs. These are single reading smokes on simulator CPU, not phone
measurements or editing/publishing benchmarks.

The XML tool protocol follows `tokenizer.chat_template` extracted from the
catalog's pinned 4B GGUF revision `50ebba61be85e5be07e8083db468ace0fc1bac43`.
The text-only serializer preserves its assistant thinking markers within a
tool turn and groups consecutive tool responses. Its protocol reference was
independently rendered with Jinja from that GGUF's original template. This
formatting check does not replace the actual-model reading gate.

References: [GitHub branches](https://docs.github.com/en/rest/branches/branches#get-a-branch),
[Git trees](https://docs.github.com/en/rest/git/trees#get-a-tree),
[Git blobs](https://docs.github.com/en/rest/git/blobs#get-a-blob).
