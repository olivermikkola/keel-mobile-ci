# Keel Mobile Privacy Policy

**Last updated:** 20 November 2026  
**Developer:** Oliver Mikkola (moesystems.com)

Keel Mobile is a local AI agent for iPhone and iPad. Privacy is the core design of the app: your models, chats, files, memory and voice dictation run directly on your device.

## 1. Data We Do Not Collect

Keel Mobile does **not** collect, track, sell or share personal data, analytics, advertising identifiers, crash telemetry or prompt logs.

- There is no Keel user account.
- There is no Keel cloud model or silent cloud fallback.
- Your conversations, attached files, generated files, custom instructions, saved memory facts, Decide documents and generated images stay stored locally on your device in Apple's protected app storage.

## 2. Optional Network Features (Only When You Choose Them)

Keel Mobile makes network requests **only** when you initiate or approve an optional feature:

- **Downloading models (Hugging Face):** When you download a catalog model, check trending models or import a model link, your device downloads files directly from `huggingface.co`.
- **Reading a linked web page (`read_url`):** Only fetches a URL that you explicitly provide in a chat.
- **Web search (`web_search`):** Optional. Uses your own Brave Search API key (kept in iOS Keychain) and asks your explicit approval for the exact search query before sending it to Brave Search.
- **GitHub connection:** Optional. Connects to GitHub using OAuth (with a minimal OAuth token-exchange broker that never persists your GitHub tokens) or a personal access token you enter. Tokens are stored exclusively in iOS Keychain on your device. Reading repositories, committing branches and opening pull requests happen directly between your device and GitHub, behind your explicit UI approvals.
- **MCP Connectors (e.g., Notion, Linear, Jira, Sentry, Context7, DeepWiki, Hugging Face, Microsoft Learn, or custom):** Optional. Connects directly from your device to the third-party service you choose, using OAuth or a token you provide (stored in iOS Keychain). Non-read-only tool calls ask for your approval before running.
- **Paired computer gateway (Advanced):** Optional. Connects only to a gateway address and token you explicitly enter.

Each third-party service you choose to connect is governed by that service's own privacy policy.

## 3. Permissions on Your Device

Keel Mobile requests device permissions only when you use the corresponding feature:

- **Camera & Photo Library:** To attach photos for OCR or on-device vision models, or as a starting image for Apple Image Playground. Photos stay on your device.
- **Microphone & Speech Recognition:** For offline on-device dictation and voice chat (`SFSpeechRecognizer` with on-device recognition required). Audio never leaves your device.
- **Notifications:** Only if you schedule a reminder task (local notification; runs on-device only when you tap it).
- **Local Network:** Only if you enter a local gateway address under Connections → Advanced → Pair a computer.

## 4. Deleting Your Data

You can delete individual chats, projects, memory facts, downloaded models, generated images or saved connections inside the app at any time. Uninstalling Keel Mobile removes all local app data from your device.

## 5. Beta Testing (TestFlight)

If you install Keel Mobile through Apple TestFlight and choose to submit feedback or crash reports through TestFlight, Apple provides that diagnostic information to the developer under Apple's TestFlight terms.

## 6. Contact

If you have questions about this privacy policy, contact Oliver Mikkola via [moesystems.com](https://moesystems.com).
