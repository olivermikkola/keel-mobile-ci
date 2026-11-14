# Building, testing and shipping

Moved out of the README so that page stays about the product. Nothing here has
been re-verified by the move; check the workflow files before relying on a step.

Swift for iOS needs macOS. Two ways to get a native check without owning a Mac:

- **GitHub Actions on the public CI mirror** (`olivermikkola/keel-mobile-ci`):
  harness tests on Linux, the simulator suite and an unsigned iPhone compile.
  See [CI mirror](CI_MIRROR.md).
- **Codemagic** (`codemagic.yaml`): the same checks plus signing and TestFlight.
  New Codemagic builds were refused with `402 BILLING_NOT_ENABLED` as of
  2026-11-12; see [audit progress](AUDIT_PROGRESS.md).

The harness package alone tests on Linux with `swift test`; see
[Keel harness on the phone](HARNESS.md).

## Codemagic workflows

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
   App Store Connect publishing step. [Signed build-only guide](BUILD_ONLY_IPA.md).
5. For TestFlight, use the App Store Connect integration named
   `MoE` (`.p8`, Key ID, Issuer ID in Codemagic's secure
   integration, never in Git), then run `ios-testflight` when you intend to
   upload to App Store Connect. Its false submission flags still allow upload.


## If Keel is missing in TestFlight

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
a live failure. See [repository verification](REPOSITORIES.md#verification).

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

The runtime archive is pinned to `b12367` and verified by checksum.
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

## iPad layout checks

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

The upstream b12367 archive contains iPhone and Mac slices only. Simulator CI
uses `scripts/prepare-llama-simulator.sh` to build the simulator slice from the
same checksum-pinned source revision. A cached preparation job shares it with
the simulator and opt-in real-model jobs. On a Mac, run this script instead of
`prepare-llama.sh` when preparing a simulator-only checkout.
