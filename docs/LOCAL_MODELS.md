# Local models: download, chat and limits

How the on-device model is installed and what the chat does under pressure.
Moved from the README; device validation is still pending.

The first chat offers a small download that is estimated to fit this device.
Open **Models** from the chat's menu to browse the catalog:

| Model | Download | Inputs | App context |
| --- | --- | --- | --- |
| Bonsai 2 2B | 547 MB | Text, tools | 4K |
| Qwen3 0.6B | 639 MB | Text | 4K |
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

Replies stream and can be stopped. On devices, LFM3, LFM3 VL, MiniCPM5, Qwen3 and imported GGUF models use a Q8_0 quantized KV cache with Metal Flash Attention (cutting KV memory nearly in half versus F16), while Bonsai retains its Q4_0 KV cache and 16K/32K contexts. Their memory budgets use their own layer/head metadata; LFM sliding attention is conservatively budgeted as full attention. You can also cap the context window (`Auto`, `4K`, `8K`, or `16K`) under **Models → Advanced** to lower memory use and heat without switching models. Pure-attention models (such as MiniCPM5, Qwen3, and standard imported GGUFs) use zero-RAM n-gram speculative decoding on Metal when repeating tokens from the conversation. Reading replies are bounded to 512 tokens; file proposals can use up to 2,048. Conversations are saved as tasks in the app’s protected storage,
excluded from backups. New chat keeps previous tasks.
Open **Saved tasks** to return to a conversation, rename it or explicitly delete
it. Up to 200 tasks are kept; delete an old task when that limit is reached.
Each task keeps its pinned repository commit. Restoring a task never replays
a tool call or restarts a reply; interrupted replies stay stopped. Existing
single-chat history migrates on the next successful save. Unreadable history
blocks changes until an explicit reset, which keeps a protected recovery copy.
Leaving the foreground stops replies and pauses downloads, except where iOS 26
lets the work continue (downloads; llama.cpp replies, which move to the CPU and
run slower). Memory warnings stop the reply and unload the runtime. Serious thermal pressure stops generation.
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

## Older iPhones (A12, A13) run on the CPU

llama.cpp's Metal backend (pinned `b12367`, `ggml-metal-device.m`) turns on
simdgroup reduction and simdgroup matrix multiply only for the Apple7 GPU
family (A14 and newer). On an A12 or A13 it refuses matrix multiply, softmax,
norms and flash attention on the graphics chip, so placing every layer there
made each step bounce to the CPU and back. An iPhone XR decoded Qwen3 0.6B at
2.8 tok/s that way (prefill 36.6 tok/s). Keel now runs llama.cpp on the CPU on
any chip without Apple7 (`LlamaGPU` in `Sources/LocalInference.swift`), and
the speed estimate for those chips uses `ModelFitEstimator.cpuBandwidthEfficiency`.
MLX is not offered there. A reply that ran on the CPU ends its stats line with
"CPU".

## Checking a USB-connected phone without tapping

Launch Keel with a prompt; it opens a new chat and asks once with the chosen
model, through the same path as Siri's Ask Keel:

```sh
pymobiledevice3 developer dvt launch "com.olivermikkola.keelmobile -KeelSelfTestPrompt 'Explain why leaves change colour in two short sentences.'"
pymobiledevice3 developer dvt screenshot reply.png   # after the reply finishes
```

Only a paired developer tool can pass launch arguments; a normal launch never
has one.

## Real-model integration checks

The mirror's opt-in `model_smoke` input accepts `all`, `4B`, `lfm3`, `lfm3-vl`,
`minicpm5`, and `qwen3-06b`. It verifies pinned weights, then runs
`SmallModelSmokeTests` through the app's inference loop. Qwen3 must complete
the starter writing example in the default chat mode. The tool models must
report a fresh CSV total from an executed SQL query, and the vision model must
identify a photo's color from its pixels. These checks run on the simulator's
CPU. Real iPhone memory headroom and speed need a physical-device run.

## Search by meaning

The Models screen has one more download that is not a chat model: **Search by
meaning** (EmbeddingGemma 300M, 334 MB, multilingual). With it installed, plain
chats get a `recall` tool: the model can look through earlier chats and through
files Keel made in other chats, and gets back up to five passages with where
each is from (`Harness/Recall.swift`).

How it works: documents are cut into passages of whole lines, the embedding
model turns each passage and the question into a vector, and the closest
passages win. The embedding model is a GGUF file run by the llama.cpp already
in the app, on the CPU, loaded for the search and unloaded after
(`Sources/EmbeddingRuntime.swift`). Vectors are saved on the phone, so only new
passages are read; the first searches read at most 120 new passages each and
say how many are left. Nothing leaves the phone.

Not measured on an iPhone yet: how long the first indexing takes, and memory
with a large chat model loaded at the same time.
