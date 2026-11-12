#!/usr/bin/env bash
# Classify collected outputs with the app's real parser, before and after the
# harness cleanup. Linux or macOS with a Swift toolchain.
#   bash tools/harness-eval/run.sh /tmp/outputs.jsonl
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
# The parser, its argument error and RepositoryAgentError: everything before RepositoryTools.
end=$(grep -n '^struct RepositoryTools' "$root/Sources/RepositoryAgent.swift" | cut -d: -f1)
head -n $((end - 1)) "$root/Sources/RepositoryAgent.swift" > "$work/RepositoryCall.swift"
swiftc -O -swift-version 5 -o "$work/classify" "$root"/Harness/*.swift "$root/Sources/GitPath.swift" \
  "$work/RepositoryCall.swift" "$root/tools/harness-eval/swift/main.swift"
"$work/classify" "$1"
