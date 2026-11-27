#!/usr/bin/env bash
# Keeps ci_scripts/Package.resolved (the app's pinned Swift packages) in step
# with project.yml. Run on a Mac with Xcode 26.4+ after `xcodegen generate`:
# it resolves the packages with Xcode and fails if the result differs from the
# committed file, printing the new one to commit. The CI mirror runs it.
# Xcode Cloud never resolves anything: ci_post_clone.sh copies the committed file.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

swift_version="$(xcrun swift --version 2>&1 | head -1)"
echo "Toolchain: $swift_version"
if ! echo "$swift_version" | grep -Eq 'Swift version (6\.([3-9]|[1-9][0-9])|[7-9])'; then
  echo "error: Keel Mobile needs Xcode 26.4 or later (Swift 6.3) for MLX." >&2
  exit 1
fi

committed="ci_scripts/Package.resolved"
generated="KeelMobile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
mkdir -p "$(dirname "$generated")"
# Start from the committed pins, so resolving keeps them unless project.yml changed.
[[ -f "$committed" ]] && cp "$committed" "$generated"
xcodebuild -resolvePackageDependencies -project KeelMobile.xcodeproj -scheme KeelMobile
mkdir -p artifacts && cp "$generated" artifacts/Package.resolved
if ! [[ -f "$committed" ]] || ! diff -u "$committed" "$generated"; then
  echo "error: $committed is missing or out of date. Commit the file above (artifact Package.resolved) as $committed." >&2
  exit 1
fi
echo "ci_scripts/Package.resolved matches what Xcode resolves."
