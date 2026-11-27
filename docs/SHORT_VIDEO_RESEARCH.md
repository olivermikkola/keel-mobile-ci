# Short video + on-device TTS — research brief

Research note for Keel Mobile. Compiled 2026-11-26 (Europe/Helsinki).
Harness for `create_short_video` already exists (`Harness/ShortVideo.swift`);
this note ranks what to wire next and what to refuse.

## Verdict

Ship **storyboard → Kokoro-class neural TTS → AVFoundation `.mp4`**. Do not
build video understanding, local video diffusion, cloud TTS, or Apple system
speech for shorts. That matches `docs/PRODUCT_MAP.md` and the 8 GB phone budget.

The missing work is almost all app-side: voice pack, image-path resolution,
renderer, chat wiring, preview/share.

## What Keel already has

| Piece | State | Path |
| --- | --- | --- |
| `create_short_video` schema, limits, `RenderPlan`, voice id parsing | Built + tested | `Harness/ShortVideo.swift`, `HarnessTests/ShortVideoTests.swift` |
| Tool registry / routing / Work-only catalog flag | Built | `ToolRegistry`, `ToolRouting`, `AgentPrompt.shortVideo` |
| `generate_image` unload-first pattern | Built end-to-end | `ImageRequest`, `ImageRuntime`, `LocalChat` |
| Photo capture / picker (pixels off-workspace) | Built | `PhotoAttachment`, `CameraCapture` |
| System reply speech (`AVSpeechSynthesizer`) | Built for chat Listen — **out of scope for shorts** | `ReplySpeech` |
| Offline dictation | Built | `OfflineDictation` |
| AVAssetWriter / composition / `.mp4` player | **Missing** | — |
| Neural TTS pack download | **Missing** | — |
| App offer of `shortVideo:` | **Missing** (`LocalChat` never passes the flag) | `Sources/LocalChat.swift` |

Hard constraints (do not bend): no shell/FFmpeg, no silent cloud, no GPU work
after the user leaves the app, harness tests before app wiring, ~4.5 GB usable
of 8 GB, approvals explicit (`AGENTS.md`, `PRODUCT_GATES.md`).

## Three problem shapes (only one fits)

| Shape | Feasible on 8 GB phone? | Notes |
| --- | --- | --- |
| **A. Generate from storyboard** (photos + narration → render) | **Yes** | Current design. LLM is director; phone is editor. |
| **B. Edit existing video by understanding it** | No for v1 | Needs frame/ASR understanding; RAM/context choke; PRODUCT_MAP excludes it. |
| **C. Local video diffusion** | No on phones | PRODUCT_MAP: 16 GB+ iPads only. |

Shape A is what the screenshots described and what the harness encodes.

## On-device TTS ranking (shorts narration)

Quality bar: “sounds like a real narrator,” not Apple’s system voices. Local only.

| Rank | Engine | Why | Fit for Keel |
| --- | ---: | --- | --- |
| **1** | **Kokoro-82M** | Apache-2.0; 54 voices (`af_heart` etc.); proven on iPhone Core ML / MLX; ~0.08 RTF and ~676 MB peak in Soniqo Core ML benches; commercial-friendly | **Default.** Matches `defaultVoiceID = af_heart`. |
| 2 | Supertonic-3 (~99M) | Strong multilingual (31 langs); Core ML ~0.15 RTF / ~956 MB peak | Later if non-English shorts matter; OpenRAIL-M use restrictions; upstream archived. |
| 3 | Piper | Fast on some phones in field data, older sound, GPL forks / voice license mess | Skip for Keel product voice. |
| — | Orpheus (~3B Llama) | Emotion tags, needs GPU-class memory | Too heavy. |
| — | Apple `AVSpeechSynthesizer` | Always there | Keep for chat Listen only; shorts already reject `system` / `siri`. |
| — | ElevenLabs / cloud | High quality | Product forbids silent cloud; user rejected for this app. |

### Kokoro packaging notes for Keel

- **License:** Apache-2.0 weights (`hexgrad/Kokoro-82M`). No voice cloning in the base model (preset packs only) — fine for a narrator tool.
- **Size:** plan on roughly **170–330 MB** download depending on Core ML export (bucketed vs single 5 s E2E FP16). Pin file-by-file like `ImageModelPack`.
- **Runtime:** prefer **Core ML / ANE** for shorts (same family as Stable Diffusion path; leaves MLX free for chat benchmarks). MLX works but vocoder memory needs chunking (community reports peaks from ~2.4 GB down to ~0.9 GB with patches). Pure ONNX CPU is a fallback, slower, more battery.
- **Memory with chat:** unload chat first (same as images). `neuralFits` already assumes ~400 MB working headroom after unload. Scene lines are ≤280 characters — keep synthesis passes short so peaks stay well under jetsam.
- **Background:** iOS will not keep Metal/ANE work alive the way users expect; fail closed when suspended (same as photos/MLX).

**Recommendation:** pin one Kokoro Core ML pack + English voice embeddings; offer `af_heart` (and a short list) once downloaded; gate `shortVideo:` like `image:`.

## Native render path (no FFmpeg)

Documented AVFoundation pattern that matches `RenderPlan`:

1. For each scene: load image → Ken Burns via Core Image / layer instructions (`slow_zoom`, `pan_left`, `pan_right`) → write or compose video track for `clip.duration`.
2. For each narration line: neural TTS → PCM/CAF/M4A segment timed to real audio length (replace harness’s character estimate once audio exists).
3. Optional overlay: `AVVideoComposition` / Core Animation text layer.
4. `AVMutableComposition` + `AVAssetExportSession` → H.264 `.mp4` (9:16 default 1080×1920).
5. Store beside chat like `ImageRuntime` sidecars (workspace is text-centric today); preview with `AVPlayer`, Share sheet.

Do **not** bundle FFmpeg or generate CLI flags — AGENTS.md forbids shell, and PRODUCT_MAP already chose native stitch.

## Critical gap: image paths

Storyboard `image: lighthouse.png` assumes workspace-resolvable files. Today:

- Attached photos live in `PhotoInputs/<uuid>.jpg` and often never become workspace files (vision attachments skip text ingest).
- `generate_image` saves a UUID PNG under `GeneratedImages/` and sets `message.image`; it does **not** reliably materialize the model’s `path` as workspace bytes.

**Before** render can work, resolve or copy:

- chat photo attachments → stable workspace-relative names, or
- generated images → write `request.path` into the task workspace / sidecar map the tool can resolve.

Without this, the tool will validate and then fail at render.

## Adjacent tools — what to wire (and what not)

Ordered by leverage after shorts v1:

| Priority | Capability | Form | Notes |
| --- | --- | --- | --- |
| P0 | Neural TTS pack + `create_short_video` app wiring | Tool already defined | Unload → TTS → stitch → preview |
| P0 | Persist `storyboard.md` next to `.mp4` | File + re-call | Enables `propose_edit` for narration/order/overlays |
| P1 | Voice picker / re-render | UI | Same tool, different `voice=` |
| P1 | Simple trim / duration nudge | UI on `RenderPlan` | Timing is not prose; avoid a trim tool until needed |
| P2 | **Music / BGM** (`generate_music` or `bgm` arg) | New tool | PRODUCT_MAP “Later”. Stable Audio 3 *small* is emerging on-device (~1.6 GB peak on Mac for short clips; iPhone ports exist but ~GB of weights). Same unload-first swap; do **after** shorts render is solid. Prefer short loops under ~15 s for BGM. |
| P2 | Captions as burned-in overlays | Already in schema (`overlay:`) | Improve typography in renderer |
| P3 | Attach audio files | Attachment MIME + UI | LOCAL_MODELS still says photos only; expand carefully |
| Defer | AppPreset “Shorts” | Preset | Images/shorts are plain Work tools today; needs a video viewer first |
| Defer | MCP / Shortcuts as media pipes | — | Text-oriented; don’t smuggle binary media through them |
| Refuse | Video understanding / “edit this clip by watching it” | — | Wrong problem for 8 GB |
| Refuse | Local video diffusion on phones | — | 16 GB+ tier |
| Refuse | Cloud TTS | — | Local product |

Chat Listen can stay on `AVSpeechSynthesizer`. Optionally later, offer Kokoro for **reply speech** once the pack exists (PRODUCT_MAP “optional compact TTS later”) — separate from shorts, same pack.

## Status (2026-11-26)

- **Voice:** Kokoro-82M through [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.18.4 (Apache-2.0, Core ML; ANE-v3 pipeline on iOS 18+, legacy on 17, CPU in the simulator). `Sources/NarrationVoice.swift`, Models → Narration. FluidAudio downloads into `Application Support/NarrationVoice` and hash-checks against pinned Hugging Face revisions; four English voices are fetched with the pack. Its LuxTTS lexicon (espeak-ng-derived, GPL-3.0) is deleted from the app bundle at build time and a test fails if it ships. Real-voice CI check: run the mirror workflow with `model_smoke: voice`.
- **Renderer:** `Sources/ShortVideoRenderer.swift` (#171): pictures with camera moves and overlays drawn into H.264 at 1080×1920/30 fps, AAC narration laid on per scene; scenes last as long as their line.
- **Draft screen:** `Sources/ShortVideoDraftView.swift`: player, scene jumps, narration waveform, clip strip, "Describe a change…", Save to Photos, Share. A viewer; changes go back to the agent.
- **Chat wiring:** `create_short_video` is offered in plain Work chats once the voice is downloaded. Storyboard paths resolve to generated pictures (by the name the model gave them) and photos (`photo.jpg`, `photo-2.jpg`, in attach order). The chat model steps aside, each line is spoken, the video is rendered into `GeneratedVideos/` with a JSON manifest, and the chat shows a card that opens the draft screen. A requested change becomes a chat message; the tool result carries the storyboard so the model can edit and re-render.
- **Known limits:** photos can only be attached with a vision model (LFM3 VL), so with text-only models shorts use generated pictures; chat photos are 768 px and look soft at 1080×1920; no music yet.

## Recommended wiring order

1. **Pin Kokoro Core ML pack** (checksums, Models UI, `availableVoices`, `neuralFits` gate) — mirror `ImageModelPack`.
2. **Fix image resolution** so storyboard paths map to real JPEG/PNG bytes (attachments + `generate_image` paths). Harness: `ShortVideoMediaIndex` + storyboard round-trip (`Harness/ShortVideoMedia.swift`). App still needs to fill the index from `PhotoInputs` / `GeneratedImages`.
3. **`Sources/ShortVideoRenderer.swift`** (name flexible): TTS → AVFoundation export from `RenderPlan`; respect `timeLimit`, cancel, thermal, fail-closed on background.
4. **Wire `LocalChat`**: `shortVideo:` when pack installed + Work; execute like `generate_image` (or Apply card — pick one; images today auto-run).
5. **Preview + Share** for `.mp4`; optional Library entry later.
6. **Write `storyboard.md`** beside output so edits are `propose_edit` + re-render (serialize helper is ready).
7. **UI polish**: voice picker, simple trim.
8. **Music/BGM tool** only after 1–6 are real on a device (not simulator claims).
9. Keep Antigravity’s tool-loop work separate; shorts are a media PR, not a parser PR.

## What “done” looks like for v1

User in Work chat, with Kokoro pack downloaded and a few photos attached (or generated):

1. Asks for a short narrated reel.
2. Model calls `create_short_video` with scene block + `af_heart`.
3. Phone unloads chat model, speaks lines on-device, stitches 9:16 `.mp4`, reloads chat.
4. User previews and shares. No network for TTS or render.

## Sources (external)

- Soniqo iOS Core ML benches (Kokoro ~0.08 RTF / ~676 MB; Supertonic-3 ~0.15 / ~956 MB)
- Magrathea / community Kokoro MLX vs ONNX iPhone notes (vocoder memory, background limits)
- mattmireles / aufklarer Kokoro Core ML packaging and peak-memory tables
- hexgrad/Kokoro-82M Apache-2.0 model card
- AVFoundation image→movie + composition patterns (AssetWriter / MutableComposition / Ken Burns)
- Stable Audio 3 small MLX / iOS ports (music later; heavy vs TTS)

Internal: `AGENTS.md`, `docs/PRODUCT_MAP.md`, `docs/PRODUCT_GATES.md`, `docs/HARNESS.md`, `Harness/ShortVideo.swift`, explore audits of `LocalChat` / `ImageRuntime` / `PhotoAttachment`.
