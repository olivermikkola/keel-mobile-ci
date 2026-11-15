# Local models: download, chat and limits

How the on-device model is installed and what the chat does under pressure.
Moved from the README; device validation is still pending.

Open **Models** from the chat's menu. The catalog includes:

| Model | Download | Inputs | App context |
| --- | --- | --- | --- |
| LFM3 1.7B | 1.10 GB | Text, tools | 8K |
| LFM3 VL 2B | 1.30 GB including vision weights | Text, photos, tools | 8K |
| MiniCPM5 2B | 1.56 GB | Text, tools | 8K |
| Bonsai 2 4B | 1.21 GB | Text, tools | 16K |
| Bonsai 2 9B | 2.56 GB | Text, tools | 32K |

These are choices to compare, not a measured phone quality/speed ranking.
Each family uses its own native prompt framing and sampler. Thinking is disabled.
The pinned upstream llama.cpp `b12367` framework supports these architectures
and Bonsai's Q2_0 weights. Inference uses Metal on devices and CPU in the simulator.
No model server or gateway is used for chat.

For LFM3 VL, the language file and Q8 vision projector are separately hash-verified.
The model becomes available only when both are present. A paused projector download
keeps the verified language file. Choose **Attach photo** with the vision model:
images are resized to at most 768 pixels on their longest edge and 1 MB each,
with up to three per chat. Only photo IDs enter saved transcripts; compressed
pixels remain in protected private storage. Text models retain **Photo as text**
for OCR. Photo input is still images, not video or audio.

Tap **Pause** to keep a partial model download, or return to **Models** after
leaving the app. **Resume download** continues from the saved byte count;
**Verify download** finishes verification if all bytes were already received.
**Discard partial download** asks for confirmation before reclaiming its space.
A model is ready only after every required file matches its pinned size and hash.
If a server ignores a range request, Keel safely restarts the transfer instead
of appending duplicate bytes. Transport failures retain the partial file;
a failed checksum discards invalid bytes so they cannot be installed or reused.

Replies stream and can be stopped. The new small models use an 8K context
and F16 KV cache. Their memory budgets use their own layer/head metadata;
LFM sliding attention is conservatively budgeted as full attention. Bonsai retains
its Q4_0 KV cache and existing 16K/32K contexts. Reading replies are bounded to
512 tokens; file proposals can use up to 2,048. Conversations are saved as tasks in the app’s protected storage,
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

## Real-model integration checks

The mirror's opt-in `model_smoke` input accepts `all`, `4B`, `lfm3`, `lfm3-vl`,
or `minicpm5`. It downloads pinned weights into an isolated job, verifies them
again against the app catalog, then runs `SmallModelSmokeTests` through the actual
app inference/tool loop. A fresh CSV total must come from an executed SQL query;
the vision model must identify a photo's color from pixels without OCR. These
are narrow integration checks, not an agent benchmark or physical-iPhone proof.
