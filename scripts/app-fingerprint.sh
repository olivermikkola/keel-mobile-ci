#!/usr/bin/env bash
# One hash of everything the iOS app build and its tests read. CI skips the
# iOS jobs when this exact set of files already passed. Docs and the
# Linux-only eval tools are left out: changing them cannot change the app.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
git ls-files -z \
  | tr '\0' '\n' \
  | grep -Ev '^(docs/|tools/harness-eval/|tools/mlx-probe/|artifacts/)|\.md$' \
  | LC_ALL=C sort \
  | while IFS= read -r file; do
      # Symlinks hash as their target path, files as their content.
      if [[ -L "$file" ]]; then printf '%s -> %s\n' "$file" "$(readlink "$file")"
      elif [[ -f "$file" ]]; then printf '%s %s\n' "$file" "$(sha256sum "$file" | cut -d' ' -f1)"; fi
    done \
  | sha256sum | cut -d' ' -f1
