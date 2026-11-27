# Public TestFlight Release Checklist

Everything needed to go from `main` to a live **public TestFlight invite link** that you can post on **moesystems.com**, GitHub, social media, and share with friends.

---

## What Is Already Done in Code

- **Privacy Manifest (`Resources/PrivacyInfo.xcprivacy`)**: declares `UserDefaults` (`CA92.1`), `DiskSpace` (`E174.1`), and `SystemBootTime` (`35F9.1` for `ProcessInfo.systemUptime`), with `NSPrivacyTracking = false` and zero collected data types.
- **Export compliance (`project.yml`)**: `ITSAppUsesNonExemptEncryption: false`.
- **App Icon (`Resources/Assets.xcassets`)**: `1024×1024` RGB PNG with no alpha channel.
- **About & Licenses screen (`Sources/AboutView.swift`)**: reachable from Sidebar → **About**, shows version/build, privacy & AI-accuracy summary, TestFlight feedback instructions, and full in-app readers for `ThirdPartyNotices.txt` (including llama.cpp, MLX, StableDiffusionCore, Hugging Face Swift packages, Bonsai 2, LFM3, MiniCPM5, d1-2B, EmbeddingGemma, and Stable Diffusion 2.1), `LFMOpenLicense.txt`, and `BonsaiChatTemplateLicense.txt`.
- **Clean Apple device picker & iPad copy**: `HardwareRecommendationStore` shows only shipping Apple devices (no Xbox / unreleased A20), and UI strings adapt automatically to `"iPhone"` or `"iPad"`.
- **First launch**: `Apple on-device` is selected when available and requires no Keel model download. On other devices, the empty chat offers **Try a calculation** and recommends a download estimated to fit the current device, typically Qwen3 0.6B (about 640 MB).
- **Experimental MLX benchmark tucked under Advanced** in Models.
- **App Intents (`KeelIntents.swift`)**: clean of `ITMS-90626` ("iPhone" removed).

---

## Your Manual Checklist Before Turning On the Public TestFlight Link

Complete these steps in order. Once every box is checked, your public TestFlight link is ready to share.

### 1. Publish the Privacy Policy on `moesystems.com`
- [ ] Publish [docs/PRIVACY_POLICY.md](PRIVACY_POLICY.md) on your website (for example `https://moesystems.com/keel-privacy` or `https://moesystems.com/privacy/keel`).
- [ ] Open the URL in a private browser tab and confirm it loads over HTTPS with `200 OK` (no login wall, no 404).

### 2. Make the GitHub Connection Public for External Testers
Right now the live OAuth broker (`https://keel-mobile-github.oliver-e-mikkola.workers.dev/config`) points to your GitHub App at `https://github.com/apps/keel-mobile-oliver/installations/new`, which was created with `public: false`. External testers **cannot** install a private GitHub App on their repositories.
- [ ] Go to **GitHub → Settings → Developer settings → GitHub Apps → Keel Mobile Oliver → Advanced**.
- [ ] Click **Make public** and confirm.
- [ ] **Important:** Do **not** rename the GitHub App slug unless you also re-run broker setup, because the broker caches `install_url` (`https://github.com/apps/keel-mobile-oliver/installations/new`). Making it public without changing the slug keeps the existing broker working immediately.
- [ ] Verify by opening `https://github.com/apps/keel-mobile-oliver/installations/new` while signed into a **different** GitHub account (or ask a friend) and confirming GitHub offers to install it instead of showing a 404.

### 3. Check App Store Connect Listing & Privacy (App ID `6833182988`)
Open [App Store Connect → Keel Mobile (6833182988)](https://appstoreconnect.apple.com/apps/6833182988/testflight/ios):
- [ ] **App Name** (App Information → Name): confirm the public-facing name testers will see on the TestFlight link is what you want (not `WebGPU Agent`; note `Keel Mobile` was taken, e.g. `Keel Mobile - Local AI` or `Keel - Local AI Agent`).
- [ ] **Privacy Policy URL** (App Privacy → Privacy Policy): paste your live `moesystems.com` privacy policy URL from Step 1.
- [ ] **App Privacy Questionnaire** (App Privacy → Get Started / Edit): select **No, we do not collect data from this app** and click **Publish**. (Matches `PrivacyInfo.xcprivacy`.)
- [ ] **Test Information** (TestFlight → Test Information):
  - **Feedback Email**: your public beta support email.
  - **Beta App Description**:
    > Keel Mobile is a local AI agent that runs directly on your iPhone or iPad. Download open-weight models (Bonsai 2, LFM3, MiniCPM5) or use Apple's on-device model to chat offline, work with files, run JavaScript and SQL sandboxes, create web pages/docs/slides/sheets/study decks, generate images on-device, and optionally connect GitHub or MCP services. No Keel account and no cloud model fallback.
  - **Beta App Review Information**: fill in your contact First Name, Last Name, Phone Number, Email, uncheck **Sign-in required**, and paste the **Review Notes** below.

#### Ready-to-Paste Beta App Review Notes
```text
Keel Mobile is a 100% on-device local AI agent. No account or login is required.

How to test quickly:
1. On an iOS 26 device with Apple Intelligence enabled, "Apple on-device" is ready immediately — type any prompt on the home screen and tap Send.
2. If Keel opens without a ready model, tap "Try a calculation" and send the sample. It should answer 391 immediately. Tap "Download and get started" to install the recommended model from Hugging Face, then ask it to write a short message offline.
3. To try file tools and apps, open Models to choose a tool-capable model that fits the test device. Attach a file, or open Menu -> Apps -> Websites/Sheets/Docs/Slides/Study.
4. Menu -> About shows app version, privacy details, and third-party/model licenses.

Optional integrations (not required to use the app):
- GitHub, MCP Connectors, Brave Search (BYOK), and Paired Computer Gateway (under Connections -> Advanced) are all optional and disabled by default.
- Background processing (UIBackgroundModes: processing + BGTaskSchedulerPermittedIdentifiers) is used exclusively on iOS 26+ via BGContinuedProcessingTask so user-initiated model downloads and local replies can finish after switching apps.

All file edits, web searches, Shortcuts runs, non-read-only MCP tool calls, and GitHub publish actions require explicit user approval in the UI.
```

### 4. Ship a Fresh Build via Xcode Cloud
- [ ] Confirm `main` is merged and green on the CI mirror (`olivermikkola/keel-mobile-ci`).
- [ ] In App Store Connect → **Xcode Cloud**, start a build from `main` (or verify the automatic build from `main` succeeded) and wait for it to finish processing in TestFlight.
- [ ] Confirm Export Compliance shows **No** / ready (handled automatically by `ITSAppUsesNonExemptEncryption = false`).

### 5. Real-Device Smoke Test on Your iPhone (Before Making It Public)
Install the new TestFlight build on your own iPhone (ideally after deleting the old app once so you test the true cold-start experience):
- [ ] **Cold start**: test `Apple on-device` on a phone with Apple Intelligence. On an older phone without a model installed, send **Try a calculation** and confirm `391` appears before any download. Start the recommended download, pause it, reopen Keel, resume, and send a short writing request after the download finishes. Record the phone model, TestFlight build number, model name, and time to the first reply.
- [ ] **Local chat + tools**: ask it to create a small HTML page or CSV table; review diff, apply, open preview, check **Library**.
- [ ] **Background & recovery**: start a reply or download, lock screen / switch apps, verify iOS 26 Dynamic Island / continued work or clean paused banner with **Continue** button.
- [ ] **About screen**: open Menu → **About**; verify version/build number and open all three license documents.
- [ ] **Connections**: test **GitHub** sign-in (confirm the public GitHub App flow works) and test at least **one MCP connector** (e.g. Context7/DeepWiki no-auth, and Notion or Linear OAuth browser sign-in if you have an account).
- [ ] **iPad check (if you have an iPad)**: verify copy says `"iPad"`, not `"iPhone"`, and sheets/sidebar lay out cleanly.

### 6. Enable External Testing & Public TestFlight Link
- [ ] In App Store Connect → **TestFlight → External Testing**, click **+** to create a group (for example **Public Beta**).
- [ ] Add your verified build from Step 4 to the group.
- [ ] Fill in **What to Test** for testers:
  > Welcome to the Keel Mobile public beta!
  >
  > Everything runs locally on your iPhone or iPad — no Keel account and no cloud model behind it.
  > - Start chatting with Apple on-device if it’s available. If Keel asks you to download a model, you can try a calculation first. Download the model Keel recommends for your device, then try a short question or a writing request offline.
  > - Try Apps (Websites, Docs, Slides, Sheets, Study), Decide, Images, and optional GitHub or MCP connectors.
  > - Please report bugs or rough edges by taking a screenshot or tapping Send Beta Feedback in TestFlight (include your device model and which AI model you used).
- [ ] Click **Submit for Review** (Apple Beta App Review typically takes a few hours to 24 hours for the first external build of a version).
- [ ] Once status changes to **Approved / Ready to Test**, open the **Public Beta** group and toggle **Enable Public Link** on (optionally set a tester cap, e.g. 500 or 1,000, while you monitor feedback).
- [ ] Copy the `https://testflight.apple.com/join/...` URL and test opening it on your phone.
- [ ] Post the link on **moesystems.com**, GitHub README, social media, and send it to friends!
