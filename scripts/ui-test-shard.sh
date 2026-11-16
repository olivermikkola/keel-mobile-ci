#!/usr/bin/env bash
# Prints the xcodebuild -only-testing arguments for one shard of the UI tests.
# Usage: scripts/ui-test-shard.sh <shard 1..N> <N>. Every UI test class lands
# in exactly one shard (by sorted file name, round robin), so the shards
# together run the whole UI suite.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
shard="$1" total="$2"
index=0
for file in $(ls UITests/*.swift | LC_ALL=C sort); do
  class="$(basename "$file" .swift)"
  grep -q "class $class" "$file" || continue   # helpers such as MenuHelper hold no tests
  if (( index % total == shard - 1 )); then printf -- '-only-testing:KeelMobileUITests/%s\n' "$class"; fi
  index=$((index + 1))
done
