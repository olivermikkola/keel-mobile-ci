#!/usr/bin/env bash
# Prints the xcodebuild -only-testing arguments for one shard of the UI tests.
# Usage: scripts/ui-test-shard.sh <shard 1..N> <N>. Every UI test class lands
# in exactly one shard, so the shards together run the whole UI suite.
# Classes are balanced by measured time (scripts/ui-test-weights.txt): longest
# first, each onto the shard with the least time so far. Ties break by name, so
# the split is the same on every machine.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
shard="$1" total="$2"
classes=()
for file in $(ls UITests/*.swift | LC_ALL=C sort); do
  class="$(basename "$file" .swift)"
  grep -q "class $class" "$file" || continue   # helpers such as MenuHelper hold no tests
  classes+=("$class")
done
printf '%s\n' "${classes[@]}" | awk -v shard="$shard" -v total="$total" '
  FNR == NR { if ($0 !~ /^#/ && NF == 2) weight[$1] = $2; next }
  { name[++count] = $0; w[count] = ($0 in weight) ? weight[$0] : 60 }
  END {
    # Longest first; equal weights by name.
    for (i = 1; i <= count; i++) order[i] = i
    for (i = 1; i <= count; i++) for (j = i + 1; j <= count; j++) {
      a = order[i]; b = order[j]
      if (w[b] > w[a] || (w[b] == w[a] && name[b] < name[a])) { order[i] = b; order[j] = a }
    }
    for (s = 1; s <= total; s++) load[s] = 0
    for (i = 1; i <= count; i++) {
      k = order[i]; best = 1
      for (s = 2; s <= total; s++) if (load[s] < load[best]) best = s
      load[best] += w[k]
      if (best == shard) printf "-only-testing:KeelMobileUITests/%s\n", name[k]
    }
  }' scripts/ui-test-weights.txt -
