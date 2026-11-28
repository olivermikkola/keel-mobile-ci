#!/usr/bin/env bash
# Classify collected outputs with the app's real parser, before and after the
# harness cleanup. Linux or macOS with a Swift toolchain.
#   bash tools/harness-eval/run.sh /tmp/outputs.jsonl
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
# The app's parser lives in the harness package, so this is the code the phone runs.
sqlite=()
[[ "$(uname)" == Linux ]] && sqlite=(-I "$root/Package/CSQLite")
swiftc -O -swift-version 5 "${sqlite[@]}" -o "$work/classify" "$root"/Harness/*.swift \
  "$root/tools/harness-eval/swift/main.swift" -lsqlite3
"$work/classify" "$1"
