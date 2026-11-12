# Keel Mobile

Agentic coding on an iPhone, using local ai on iphone metal.

A local model runs on the phone. The agent reads a GitHub repository, proposes
changes you review, publishes them as a pull request, and reads CI to see if
they work. Think an on-device model app and an agentic editor in one app.

**Who it is for:** someone whose only computer is their phone. Internet is
assumed; a computer is not. GitHub holds the code and GitHub Actions builds and
tests it, because iOS cannot compile or run a project's tests.

**Why "Keel":** Keel is the harness that makes small local models do useful
coding work. Keel Mobile carries the same ideas to the phone: tolerant tool-call
parsing, repeat-call reminders, context budgets and compaction sized to the
model, and explicit approvals. The desktop Keel is Rust with a shell; this is
Swift with no shell, so the ideas are ported, not the code. See
[Keel harness on the phone](docs/HARNESS.md).

**Not part of MoE.** Keel Mobile is a standalone product. It must work with no
Beelink, no gateway and no paired host.

## State (2026-11-12)

Default tabs are **Chat**, **Models** and **Connect**. Connect offers the local
model library and GitHub.

**Paired mode is an advanced option.** It is the native gateway client
extracted from `webgpu-agent` (`apps/ios` @ `e32d726`): Keychain-backed pairing
to a Rust gateway over HTTPS, host commands with optional PTY, approvals and the
workspace diff. It is for people who do have a host. No core feature may depend
on it. **Workspace** and **Approvals** appear only while a host is connected.

**On-device chat is implemented; device validation is pending.** The first tab
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

**GitHub repository browsing is implemented.** Open Connect → Open a GitHub
repository, choose a branch, and browse text files at its fixed commit. Public
repositories need no token; private-repository credentials stay in Keychain.
See [setup and limits](docs/REPOSITORIES.md).

**Repository-aware local chat is implemented.** In an empty chat, attach a
repository and choose **Use in this chat**. Bonsai can list folders, read
verified line ranges and search literal text within a known file through GitHub,
then answer with those results. Search returns matching lines and pagination;
zero matches only covers the requested file range. Activity
shows actual reads and the pinned commit; expand a read to inspect its content.
The task's repository version is saved with its conversation. Start a new chat
to switch versions. [Tool scope and limits](docs/REPOSITORIES.md).

**Director edit proposals require review.** Attach a repository and enable
**Edit proposals**. The on-device model can read verified code and propose exact
replacements. Open **Review changes**, inspect the line-numbered diff, then
explicitly apply or discard each proposal. Applying updates only this saved task;
it checks the original branch and file before accepting the change. Decisions
survive relaunch, and unapproved proposals never alter subsequent file reads.

Direct model tools for pushing commits, dispatching CI and opening pull requests
are disabled. A separate reviewed publishing flow is still audit work in progress;
Keel must not infer permission from model output or repository instructions.
See [reviewing changes](docs/REVIEWING_CHANGES.md) and the
[audit checklist](docs/AUDIT_PROGRESS.md).

Local work runs while Keel is in the foreground. The screen stays awake while
working; temporary overlays do not stop a reply. Leaving or locking the app
stops local work and saves the partial reply. Already-dispatched GitHub CI
continues remotely. Background processing and Dynamic Island progress are not
implemented.

## Build without a personal Mac

1. In Codemagic, select this branch, then **Check for configuration file**.
   `codemagic.yaml` defines manually started workflows; no automatic paid
   triggers.
2. Run **iOS simulator checks (no Apple account)**. It generates the project
   with XcodeGen, builds, runs XCTest and a native UI smoke test, and needs no
   Apple certificate. Artifacts include `iOS-Tests.xcresult`,
   `test-summary.json`, `xcodebuild-test.log` and screenshot attachments, also
   on failure. A simulator app cannot be installed on an iPhone.
3. Run **iPhone compile check (unsigned, no Apple account)** to compile the real
   device code path and link the iPhone runtime slice. This catches errors hidden
   behind simulator conditionals. Its unsigned app artifact cannot be installed
   on an iPhone, and it does not prove Metal behaviour or phone memory headroom.
4. To check signed packaging before uploading, run `ios-signed-artifact` using
   matching distribution signing files already uploaded to Codemagic. It keeps
   the IPA and a source/hash/signature report as build artifacts and has no
   App Store Connect publishing step. [Signed build-only guide](docs/BUILD_ONLY_IPA.md).
5. For TestFlight, use the App Store Connect integration named
   `MoE` (`.p8`, Key ID, Issuer ID in Codemagic's secure
   integration, never in Git), then run `ios-testflight` when you intend to
   upload to App Store Connect. Its false submission flags still allow upload.

### If Keel is missing in TestFlight

Run the manual `ios-testflight-status` workflow. It reads Apple's existing app
record, build processing/export-compliance state and internal tester-group
assignments without building or uploading. The artifact is
`artifacts/testflight-status.json`; credentials and tester addresses are never
included. An upload success alone does not prove a build is available to testers.
Set `KEEL_WAIT_FOR_BUILD_VERSION` to a build number (for example `4`) to wait
up to ten minutes for Apple's processing and confirm that build is in internal
testing and assigned to a group with testers. A timeout fails the check.
The upload workflow numbers each new build above Apple's highest existing
build number and verifies the exported IPA's explicit encryption declaration
before publishing it.

Keel uses [Apple app record 6833182988](https://appstoreconnect.apple.com/apps/6833182988/testflight/ios),
originally named **WebGPU Agent**. Open that existing record rather than creating
another app or changing Keel's bundle ID. Its internal group is
**Keel Mobile - Pre Alpha**. Apple Account Holder access to the portal alone
does not install an app: accept the internal tester invitation in TestFlight.

For an already-uploaded Keel build blocked on missing export compliance, the
manual `ios-testflight-enable-existing` workflow requires an explicit
`KEEL_TESTFLIGHT_BUILD_ID` (Apple's build UUID, not its version number). It sets
the same exempt-encryption declaration as `project.yml`, assigns only that
valid, unexpired build to the existing internal group, and corrects the editable
primary app listing name from WebGPU Agent to **Keel Mobile - Local Coding**
(the exact name "Keel Mobile" is already reserved by another developer).
The Home Screen display name remains Keel Mobile. It does not create
testers, upload a build, submit a review, or release an App Store version.
It fails unless Apple reports the selected build `IN_BETA_TESTING`; rerun the
read-only status workflow if Apple's state change is still processing.

A Linux syntax check is not proof of native behaviour. Device measurements —
tok/s, memory ceiling, thermal throttling — only exist on hardware.

The simulator workflow uses explicit recorded responses for repository UI
navigation and persistence. **Live GitHub repository UI** is a separate check
requiring available GitHub API quota; it never substitutes fixture data for
a live failure. See [repository verification](docs/REPOSITORIES.md#verification).

The optional **Real Bonsai repository-agent smoke** workflow downloads the
pinned 1.21 GB 4B model and requires it to read a live GitHub README before
quoting its contents. It runs the actual native CPU model and tools. The regular
suite skips this larger check; scripted model tests establish control flow only.
A passing smoke is one reading task, not coding quality or iPhone performance.
**Real Bonsai with recorded repository responses** isolates the same actual
model/tool loop from GitHub network availability. Its result is recorded-data
proof; the live smoke remains separate.

## Signing

Bundle ID `com.olivermikkola.keelmobile`. **Register it in the Apple Developer
portal before the first signed build**, and keep it in sync with `project.yml`
and `codemagic.yaml`. Changing a bundle ID after a TestFlight build means losing
that app's history, so get it right now.

The simulator-only entitlements file supplies the app identity used by the
Keychain test; it does not create a separate access group. TestFlight still uses
Apple's provisioning profile. Do not revoke existing certificates to make room
without checking what uses them.

## On a Mac

```sh
brew install xcodegen
bash scripts/prepare-llama.sh
bash scripts/prepare-test-model.sh
xcodegen generate --spec project.yml
bash scripts/test-ios-simulator.sh

# Optional: compile for an iPhone without signing or connecting a device.
bash scripts/build-ios-device.sh
```

For a physical device, open the generated project in Xcode, select your
development team and the connected iPhone, and enable automatic signing.

The runtime archive is pinned to `prism-b12128-d7b2896` and verified by checksum.
The simulator suite generates real text with a pinned 19 MB TinyStories fixture,
tests cancellation/reuse, context overflow, checksum rejection and chat storage,
and captures the native chat and model-library screens. TinyStories is a test
fixture only. These checks do not establish Bonsai coding quality, phone memory
headroom, Metal speed or thermal behaviour. Those require the target iPhone.

Debug simulator fixtures are selected with launch arguments and compiled out of
device builds: `--saved-task-fixture` / `--reset-saved-task-fixture` for saved
tasks, `--recorded-repository` with `KEEL_RECORDED_REPOSITORY` for recorded
GitHub responses, `--edit-review-fixture` for the review screen, and
`--partial-model-fixture` / `--model-failure-fixture` for download states.

## Pairing (current mode)

Use the gateway's **HTTPS origin**, with no path, token query or URL fragment.
Bare HTTP is rejected. The bearer credential lives in Keychain and is accessible
only while the device is unlocked. The address alone is in UserDefaults. Tap
Connect to reconnect after launch; Disconnect keeps the pairing, Forget removes
the Keychain entry.

The focused `ios-navigation` workflow runs the unit suite and native
pairing/navigation checks. Connected-layout screenshots use an explicit debug
simulator fixture; they do not prove a live host connection or execution. This
fixture is absent from device builds and creates no gateway client or stored credential.

## Rules this repo keeps

- No secrets in the app, in prompts, or in git. Gateway tokens in Keychain;
  GitHub credentials do too, once they exist.
- The model's output is input to a tool request, never authorization. Mutating
  operations need an explicit decision in the UI.
- No silent fallback to a paid or cloud model. If the on-device model cannot
  run, the app says so and stops.
- Headless only for builds and tests; never open GUI windows on the desktop.

## References

- [Codemagic native iOS](https://docs.codemagic.io/yaml-quick-start/building-a-native-ios-app/)
- [XcodeGen project spec](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md)
- [TestFlight](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
- [GitHub repository browser: setup and limits](docs/REPOSITORIES.md)

### iPad layout checks

The `ios-ipad-simulator` workflow runs the same unit and recorded-response UI
suite on an available iPad simulator. It also checks model setup and connections
in landscape, then returns to portrait and captures both layouts. Review the
screenshots before claiming tablet layout is verified. This does not prove
physical-device inference, memory limits or multitasking recovery.

On macOS, after generating the project:

```sh
KEEL_SIMULATOR_FAMILY=iPad bash scripts/test-ios-simulator.sh \
  -skip-testing:KeelMobileUITests/RepositoryUITests/testOpenPublicRepositoryAndReadRealFile
```

The default remains iPhone. A missing requested device family fails explicitly;
it never silently substitutes a phone for a tablet check.
