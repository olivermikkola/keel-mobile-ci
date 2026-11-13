# Local models: download, chat and limits

How the on-device model is installed and what the chat does under pressure.
Moved from the README; device validation is still pending.

The first tab
opens a local conversation. Models offers Bonsai 2 4B (1.21 GB) and 9B (2.56 GB),
with progress, pause/resume, disk-space checks and SHA-256 verification before
installation. Start with 4B. A pinned Bonsai-capable llama.cpp XCFramework runs
inference through Metal on devices and CPU on the simulator. No model server or
gateway is used for chat.

Tap **Pause** to keep a partial model download, or return to **Models** after
leaving the app. **Resume download** continues from the saved byte count;
**Verify download** finishes verification if all bytes were already received.
**Discard partial download** asks for confirmation before reclaiming its space.
Nothing is installed until the complete file matches the pinned size and hash.
If a server ignores a range request, Keel safely restarts the transfer instead
of appending duplicate bytes. Transport failures retain the partial file;
a failed checksum discards invalid bytes so they cannot be installed or reused.

Replies stream, can be stopped, and use 4-bit quantized KV cache (`Q4_0`) on
device, enabling 16,384 tokens for 4B and 32,768 tokens for 9B within the iPhone's
~4.5 GB app memory budget. A 512-token per-turn reply limit and disabled thinking keep
replies bounded. Conversations are saved as tasks in the app’s protected storage,
excluded from backups. New chat keeps previous tasks.
Open **Saved tasks** to return to a conversation, rename it or explicitly delete
it. Up to 200 tasks are kept; delete an old task when that limit is reached.
Each task keeps its pinned repository commit. Restoring a task never replays
a tool call or restarts a reply; interrupted replies stay stopped. Existing
single-chat history migrates on the next successful save. Unreadable history
blocks changes until an explicit reset, which keeps a protected recovery copy.
Leaving the foreground stops replies and pauses downloads; memory warnings stop the
reply and unload the runtime. Serious thermal pressure stops generation.
There is no automatic retry or cloud fallback.

The `ios-model-downloads` check runs the unit suite and model/pairing UI tests.
Its HTTP fixtures exercise cancellation after data is written, reopening and
resuming that file, invalid/ignored ranges, bounded output and hash rejection.
The UI fixture checks relaunch and explicit discard; it is absent from device
builds. That workflow also probes a native resume of the final 16 bytes from
the pinned 9B CDN, using a sparse prefix fixture and cancelling if Range is
ignored. This checks native redirects and offsets above 2 GB without a full
model download. It does not verify the model's complete contents.
These checks do not prove iPhone background/lock behaviour or actual
cellular-network reliability. The existing live GitHub UI check is separate.
