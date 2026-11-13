#!/usr/bin/env bash
# Run from the repository root on macOS. No Apple account/certificate required.
set -euo pipefail
mkdir -p artifacts
result_bundle="artifacts/iOS-Tests.xcresult"

collect_results() {
  # Keep the original xcodebuild exit status. Diagnostics must not hide failure.
  if [[ -d "$result_bundle" ]]; then
    xcrun xcresulttool get test-results summary --path "$result_bundle" \
      > artifacts/test-summary.json || true
    xcrun xcresulttool export attachments --path "$result_bundle" \
      --output-path artifacts/attachments || true
  fi
}
trap collect_results EXIT

SIMULATOR_ID="$(python3 scripts/ios-simulator.py --family "${KEEL_SIMULATOR_FAMILY:-iPhone}")"
xcodebuild test \
  -project KeelMobile.xcodeproj \
  -scheme KeelMobile \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -parallel-testing-enabled NO \
  -derivedDataPath build/ios-simulator \
  -resultBundlePath "$result_bundle" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY=- \
  "$@" \
  2>&1 | tee artifacts/xcodebuild-test.log
