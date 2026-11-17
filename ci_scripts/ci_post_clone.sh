#!/usr/bin/env bash
# Xcode Cloud runs ci_scripts/ci_post_clone.sh after cloning the repository and
# before looking for KeelMobile.xcodeproj. Keep KeelMobile.xcodeproj generated
# from project.yml so git never tracks machine-generated project state.
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export HOMEBREW_NO_AUTO_UPDATE=1

repo_root="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$repo_root"

if ! command -v xcodegen >/dev/null 2>&1; then
  brew install xcodegen
fi

if [[ "${CI_XCODEBUILD_ACTION:-}" == "test" ]]; then
  bash scripts/prepare-llama-simulator.sh
else
  bash scripts/prepare-llama.sh
fi

bash scripts/prepare-test-model.sh
xcodegen generate --spec project.yml
test -d "$repo_root/KeelMobile.xcodeproj"


# Xcode Cloud builds with package resolution turned off, everywhere: it needs
# Package.resolved beside the generated project and will not write one. Use the
# committed, pinned file (kept in step by scripts/resolve-packages.sh on the CI mirror).
swift_version="$(xcrun swift --version 2>&1 | head -1)"
echo "Toolchain: $swift_version"
if ! echo "$swift_version" | grep -Eq 'Swift version (6\.([3-9]|[1-9][0-9])|[7-9])'; then
  echo "error: Keel Mobile needs Xcode 26.4 or later (Swift 6.3) for MLX. Pick a newer Xcode in the Xcode Cloud workflow's environment." >&2
  exit 1
fi
resolved_dir="$repo_root/KeelMobile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$resolved_dir"
cp "$repo_root/ci_scripts/Package.resolved" "$resolved_dir/Package.resolved"
echo "Pinned Swift packages copied into the generated project."
