# Product map

What Keel Mobile should grow into, from Oliver's reference screenshots
(2026-11-13): a local-model chat app's attach menu, and a general assistant's
sidebar, apps, connectors and scheduled tasks. Everything runs on the local
model. This is direction, not a status report; see the README for what works.

"Feasible" below is a judgement from the code and iOS rules, not a test. The
target phone is an iPhone 15 Pro (8 GB). The 4.5 GB app budget used for planning
is a heuristic from `docs/ON_DEVICE_PLAN.md` §1, not an OS guarantee;
physical device behaviour is still unmeasured.

## Shell

| Wanted | Plan | Feasible |
| --- | --- | --- |
| Chat as the home screen with a few starter suggestions | Replace the three tabs with one chat screen | Yes (built, #55) |
| Sidebar: recents, projects, apps, scheduled, customize, search | Recents are today's saved tasks. A project groups chats and gives them shared instructions and up to 10 read-only files (1 MB of text) under `project/` | Yes (built) |
| Model name in the header, tap to switch | Move the model library behind it | Yes (built, #55) |
| `+` menu: attach file, attach photo, take photo, thinking on/off | See "Inputs" | Yes (built) |
| Customize | Standing instructions the user writes, added to every chat | Yes (built) |
| Chat / Work | A switch beside the model name. Chat: a short prompt, reading tools and connectors, 4 tool calls, 512-token replies, no files made or code run. Work: the full agent. Each mode remembers the model last picked for it and marks recommended ones (Chat: LFM3, LFM3 VL, MiniCPM5; Work: Bonsai 2 9B, 4B). Apps and repository chats are always Work | Yes (built); heat and speed difference on a phone unmeasured |
| Memory | `remember` tool: the model asks to save one short fact about the user; the user taps Remember or Don't save. Up to 40 facts, newest ~1,200 characters go into every plain chat's prompt. Customize lists them, forgets one or all, and turns memory off | Yes (built) |
| Library | Every file the agent made and the user applied, from every plain chat, newest first: filter by pages, docs, tables and cards, search, open in its viewer, share as a file, or jump to the chat that made it | Yes (built) |

## Inputs

| Wanted | Plan | Feasible |
| --- | --- | --- |
| Attach file | Text, CSV and PDF text go into the task workspace, where the existing tools can read and search them | Yes (built, #54) |
| Attach or take a photo | First: Apple's on-device text recognition turns the photo into text (#54). Second: `LFM3 VL 2B` (~1.10 GB weights + ~0.20 GB vision projector in #62) for pixel-level image input | Yes (built: OCR in #54, `LFM3 VL 2B` vision in #62); phone speed and heat unmeasured |
| Thinking toggle | A template switch, capped so a reply cannot run for minutes | Yes (built) |
| Voice | iOS on-device dictation (`SFSpeechRecognizer`, offline mode) in, system speech (`AVSpeechSynthesizer`) out without loading a second LLM/audio weight file. Optional compact TTS model later | Yes (built: dictation in #66, speech output with `AVSpeechSynthesizer` in #80) |

## Models

Different small models trade speed, memory footprint, and coding or tool-use
ability (`docs/ON_DEVICE_PLAN.md` §1–2). Keel Mobile plans three tiers behind
the header model picker, filtered by a heuristic estimate of device memory
(`physicalMemory`):

| Tier | What is in it | Plan and limitations |
| --- | --- | --- |
| **Pinned catalog** | Revision- and SHA-256-pinned downloads in `ModelLibrary`: `Bonsai 2` 4B (`1.21 GB`) and 9B (`2.56 GB`), plus `LFM3 1.7B` (`1.10 GB`), `LFM3 VL 2B` (`1.30 GB` with vision), and `MiniCPM5 2B` (`1.56 GB`) in #62 | Tested against scripted and simulator smoke checks in CI; multi-step task reliability and physical iPhone speed/heat remain unmeasured |
| **Experimental shelf (candidate specs)** | Unverified candidate specs in `ExperimentalModelSpec.shelf`: reachable unpinned candidates (`LFM 2.5 1.2B Thinking` at `0.73 GB`, `mini-agent-v2 1.5B` at `0.99 GB`, `Ternary Bonsai 8B` at `2.18 GB`, and `Ternary Bonsai 2 27B` at `7.63 GB` for 16 GB+ devices; `docs/ON_DEVICE_PLAN.md` §1 notes 27B does not fit an 8 GB phone), plus disabled entries whose upstream Hugging Face URLs returned HTTP 401/404 during unauthenticated `HEAD` checks (`xLAM-2-1b-fc-r`, `Hammer-2.0-1.5B`, `granite-4.2-3B`, `Qwen3-4B-2507`) | Badged *"Experimental — tool reliability varies"*. Candidates are not installable until pinned with a verified revision and SHA-256 checksum |
| **Custom GGUF (Bring your own)** | Paste a Hugging Face `.gguf` link (`HuggingFaceGGUFLink`) or import a `.gguf` file from iOS Files | `GGUFHeader` inspects bounded header metadata (`<= 256 KB`) to check dimensions and estimate KV/recurrent memory (`DeviceMemoryGate`, defaulting conservatively to FP16 KV cache) for known modeled architectures (`qwen35`, `lfm2`/`lfm3`, `llama`, `qwen2`). Unknown architectures are flagged as unsupported for memory estimation. Memory estimates are planning heuristics, not OS Jetsam guarantees |

## Apps and media tools

An app is a preset: instructions, a tool set and a viewer for the result. Not a
separate program or a disconnected tab. Every generated file lives in the task
workspace so other tools and previews can use it.

| App | Plan | Feasible |
| --- | --- | --- |
| Websites | The agent writes HTML, CSS and JavaScript in the workspace; a web view previews it on the phone with no build step; GitHub Pages publishes it | Yes (preset and viewer built, #57, #69) |
| Sheets | CSV in, `run_sql` (with CSV files auto-mounted as tables) and scripts to work on it, table viewer, CSV out | Yes (preset, viewer and CSV tables built, #59, #60, #69) |
| Docs | Markdown in the workspace, rendered viewer, export to PDF | Yes (preset and viewer built, #60, #69) |
| Study | Flashcards and quizzes (`Q:`/`A:` and choices) from an attached file | Yes (preset and viewer built, #60, #69) |
| Slides | Slides as HTML, shown in the web view, export to PDF | Yes (preset, viewer and PDF export built) |
| Images | `generate_image` in plain Work chats, once the image model is downloaded from the Models screen (Stable Diffusion 2.1 base in Apple's Core ML build, 6-bit weights, 1.07 GB, pinned file by file in `ImageModelPack`). The picture is 512×512 (smaller sizes are scaled down), 20 steps, shown in the chat with Share. A diffusion model cannot share a ~4.5 GB phone memory budget with the chat model, so the chat model is unloaded first and loads again on the next step. The runtime is Core ML on the Neural Engine (`Sources/ImageRuntime.swift`), built from Apple's ml-stable-diffusion code copied into `Vendor/StableDiffusionCore` (its package cannot be resolved next to MLX's). Limits (prompt ≤ 300 characters, 300 s) are in `ImageRequest`. Optional tiled `Real-ESRGAN` 4× upscaler later | Built. A real picture is made in CI on the simulator's CPU (opt-in `image` run). Speed, heat and memory on an iPhone are not measured yet; the first picture after a download is slow while Core ML prepares the model |
| Music | Optional compact on-device audio generator writing short instrumental `.wav`/`.mp3` loops into the workspace using the same unload-first swap | Later |
| Video & 14B–27B models (16 GB+ tier) | Local video diffusion and large (`14B–27B`, `7.63 GB+`) models exceed an 8 GB iPhone's memory and thermal budget (`docs/ON_DEVICE_PLAN.md` §1, §8). Keep restricted to 16 GB+ M-series iPads | 16 GB+ devices only; not on 8 GB phones |

## Ideas to borrow from other on-device apps

- **Draw Things (iOS Metal diffusion):** Hardware-tier gating by device RAM and
  keeping heavy diffusion/video workloads restricted to devices that can fit them.
- **LoAi (offline image gen):** Unloading the chat LLM before loading diffusion
  weights so both models never sit in unified memory at the same time; few-step
  distilled SD 1.5 models; sketch-to-image input; saving prompt/seed metadata;
  and 128×128 tiled 4× upscaling (`Real-ESRGAN`).
- **PocketPal AI & Private LLM (local LLMs):** Custom GGUF import from Hugging
  Face or Files with header inspection and RAM-tiered model filtering.
- **Google AI Edge Gallery & Enclave (multimodal & voice):** Camera-to-workspace
  flows and offline voice input/output.

## Connectors and tool routing

Connections → Connectors lists services with a **Connect** button: Notion,
Linear, Jira & Confluence, Sentry (these open the service's own sign-in page),
and Hugging Face, Context7, DeepWiki and Microsoft Learn (no account). The user
never types an address or a token for a listed service. Sign-in is OAuth with
PKCE in the system browser sheet (`MCPConnectorAuth`, `MCPConnectorClient`);
Keel registers itself with the service as a public app, so there is no Keel
server in between and no shared secret. The grant is kept in Keychain and
renewed when it expires.

"Custom connector" takes a name and an address for any other MCP service; an
access token field exists only under Advanced.

A connector's tools are loaded only in chats where it is switched on, at most
five per connector (chosen on the connector's page), because every tool
description uses context a small model does not have. A tool the service does
not mark read-only asks the user before it runs, showing exactly what would be
sent; "Always allow this tool" remembers the choice.

Checked against the live services from Linux (`KEEL_LIVE_CONNECTORS=1 swift
test --filter MCPConnectorLiveTests`): handshake, tool list and a real lookup on
the no-account services, and sign-in discovery on the account services. Not yet
done on a phone: a real browser sign-in. Slack, Outlook and Canvas are not
listed because they only accept apps registered with them in advance.

`DynamicToolSelector` in `Harness/CustomModel.swift` provides a keyword and
recent-turn follow-up heuristic that caps active schemas at 5 tools and falls
back to core workspace tools on ambiguous prompts. It is evaluated offline with
`tools/harness-eval --eval-selector` (`38/38` recall = `100.0%` across the
workspace + connector suite, reducing active tool schema bytes from `4,651` to
`1,892` bytes, `59.3%` saved).

GitHub in a plain chat: once the account is connected, the model is offered
`github_repos` (the user's repositories) and `github_open` (open one in this
chat). Opening turns the chat into a repository chat and the same request
carries on inside it, so "open my keel-mobile repository and read the README"
works without a trip to Connections. A chat that already has files of its own
cannot switch. Measured with Bonsai 9B on the Linux box
(`KEEL_LIVE_MODEL=<llama-server> swift test --filter GitHubToolsLiveModelTests`):
asked to open a named repository it listed and then opened the right one 5/5
times; asked only "can you access my repositories" it listed them 4/5 times.

Web search (`web_search`, #70, #75) uses the user's configured Brave Search API
key and asks for explicit approval of the exact query before sending a request.
Reading a page the user links (`read_url`, #64, #71) needs no key.

## Leaving the app

What keeps going after the user switches away, and what cannot:

| Work | After leaving the app |
| --- | --- |
| Model download or import | **iOS 26 and later:** continues to the end. The tap that starts it also asks iOS for a continued background task (`ContinuedWork`, `BGContinuedProcessingTask`); iOS shows the progress on the Lock Screen and in the Dynamic Island, where the user can cancel it. **Older iOS, or if iOS refuses:** about 30 seconds, then it pauses and resumes from the same byte next time |
| Publishing to GitHub, starting CI | About 30 seconds (enough for a push and a dispatch) |
| The model writing a reply | **iOS 26 and later, llama.cpp models, no photos:** carries on. The tap that sends the message also asks iOS for a continued background task; if iOS agrees, leaving the app moves the model from the graphics processor to the CPU and it keeps what it has read (`InferencePlacement`). iOS shows the progress on the Lock Screen and in the Dynamic Island. Expect it to be several times slower there; the speed on a real iPhone is not measured yet. **Otherwise** (older iOS, MLX, Apple's model, a photo in the chat, or iOS says no): stops; the partial reply is kept. No iPhone may use its graphics processor in the background (Apple's engineers say only iPads with an M3 or newer can) |

Built and compiled against the iOS 26 SDK in CI; the logic is unit-tested with a
stand-in for iOS. Not yet seen on a phone: that iOS accepts the request and
shows the progress.

## Scheduled

iOS does not let an app run a model unattended at a set time. Built (#65): a
local notification fires at the scheduled time, and the task runs when the user
taps it. A true background run is not something to promise.

## Order

1. **Done:** Shell — one chat screen, sidebar, model in the header, `+` menu (#55, #61).
2. **Done:** Attach file, photo as recognised text (#54), and pixel vision with `LFM3 VL 2B` (#62).
3. **Done:** Per-chat workspace (#58), `run_js` (#56), `run_sql` CSV tables (#59),
   viewers (#57, #60), and sidebar Apps presets for Websites, Sheets, Docs, Study and Slides (#69) with PDF export.
4. **Done:** Small fast models (`LFM3`, `LFM3 VL 2B`, `MiniCPM5` in #62),
   grammar-constrained tool calls and leaked-reasoning stripping (#67, #68, #73),
   and custom GGUF imports from Files (#72) and Hugging Face links (#63, #74).
5. **Done:** `read_url` for user-linked pages (#64, #71) and web search with explicit query approval (#70, #75).
6. **Done:** Scheduled tasks as tap-to-run local notifications (#65), offline speech dictation (#66), and system speech output (`AVSpeechSynthesizer`, #80).
7. **Done:** Customize (standing instructions), thinking toggle (#82), and Slides preset (#81).
8. **Done:** Connectors through MCP (`MCPConnector`), loaded per chat, and evaluating `DynamicToolSelector` with `tools/harness-eval --eval-selector`.
9. **Next:** A diffusion runtime behind `ModelSwap` (groundwork built), then 16 GB+ iPad tier, and physical iPhone measurements.

Keep the rule from AGENTS.md: each capability is a tool with limits and tests.
