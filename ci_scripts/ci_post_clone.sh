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
