#!/usr/bin/env bash
# Resolve the app's Swift packages into Package.resolved beside the generated
# project. Xcode Cloud builds with automatic package resolution turned off and
# fails without this file; ci_scripts/ci_post_clone.sh and the CI mirror run it.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# MLX (mlx-swift-lm, mlx-swift) needs Swift 6.3, which ships with Xcode 26.4 and later.
swift_version="$(xcrun swift --version 2>&1 | head -1)"
echo "Toolchain: $swift_version"
if ! echo "$swift_version" | grep -Eq 'Swift version (6\.([3-9]|[1-9][0-9])|[7-9])'; then
  echo "error: Keel Mobile needs Xcode 26.4 or later (Swift 6.3) for MLX. Pick a newer Xcode in the Xcode Cloud workflow's environment." >&2
  exit 1
fi

xcodebuild -resolvePackageDependencies -project KeelMobile.xcodeproj -scheme KeelMobile
resolved="KeelMobile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
test -f "$resolved"
echo "Resolved packages:"
grep -E '"identity"|"version"|"revision"' "$resolved" || true
