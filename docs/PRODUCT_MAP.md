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
| Sidebar: recents, projects, apps, scheduled, customize, search | Recents are today's saved tasks. A project groups tasks and shares files and instructions | Yes |
| Model name in the header, tap to switch | Move the model library behind it | Yes (built, #55) |
| `+` menu: attach file, attach photo, take photo, thinking on/off | See "Inputs" | Yes |
| Customize | Standing instructions the user writes, added to every chat | Yes |

## Inputs

| Wanted | Plan | Feasible |
| --- | --- | --- |
| Attach file | Text, CSV and PDF text go into the task workspace, where the existing tools can read and search them | Yes (built, #54) |
| Attach or take a photo | First: Apple's on-device text recognition turns the photo into text (#54). Second: `LFM3 VL 2B` (~1.10 GB weights + ~0.20 GB vision projector in #62) for pixel-level image input | Yes (built: OCR in #54, `LFM3 VL 2B` vision in #62); phone speed and heat unmeasured |
| Thinking toggle | A template switch, capped so a reply cannot run for minutes | Yes |
| Voice | iOS on-device dictation (`SFSpeechRecognizer`, offline mode) in, system speech (`AVSpeechSynthesizer`) out without loading a second LLM/audio weight file. Optional compact TTS model later | Yes (built: dictation in #66, speech output with `AVSpeechSynthesizer`) |

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
| Images | Planned `generate_image` tool/preset writing `.png` into the workspace. Because a diffusion model (`~0.65–1.6 GB`) cannot share a ~4.5 GB phone memory budget with the chat LLM, the app must unload the chat LLM first, run a few-step diffusion model (and optional tiled `Real-ESRGAN` 4× upscaler), save the PNG, and reload the LLM on the next turn | Later; requires sequential model unload and device measurement |
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

Notion, Slack, mail, issue trackers and the like, through an MCP client and a
sign-in per service (the GitHub sign-in broker in `connector/` is the pattern).
A connector's tools are loaded only in chats where it is switched on, because
every tool description uses context a small model does not have.

`DynamicToolSelector` in `Harness/CustomModel.swift` provides a simple,
unwired keyword and recent-turn follow-up heuristic that caps active schemas at
5 tools and falls back to core workspace tools on ambiguous prompts. It is a
heuristic prototype, not a trained retriever, and must be evaluated with
`tools/harness-eval` before wiring into the app.

Web search (`web_search`, #70, #75) uses the user's configured Brave Search API
key and asks for explicit approval of the exact query before sending a request.
Reading a page the user links (`read_url`, #64, #71) needs no key.

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
7. **Next:** Customize (standing instructions) and thinking toggle.
8. **Next:** Connectors through MCP, loaded per chat, and evaluating `DynamicToolSelector` with `tools/harness-eval`.
9. **Next:** Sequential-unload image generation, then 16 GB+ iPad tier, and physical iPhone measurements.

Keep the rule from AGENTS.md: each capability is a tool with limits and tests.
