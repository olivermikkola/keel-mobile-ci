#!/usr/bin/env bash
# Compile the real iPhone code path without a signing certificate or Apple account.
# This produces an unsigned app, not an installable IPA or a device test result.
set -euo pipefail
mkdir -p artifacts
xcodebuild build \
  -project KeelMobile.xcodeproj \
  -scheme KeelMobile \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios-device \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee artifacts/xcodebuild-device.log
