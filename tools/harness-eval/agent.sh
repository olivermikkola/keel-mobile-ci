#!/usr/bin/env bash
# Build and run the multi-turn agent eval. Linux or macOS with a Swift toolchain.
#   bash tools/harness-eval/agent.sh --server http://127.0.0.1:8080 --samples 2
# All arguments go to the eval; see README.md for the list.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
build="${KEEL_EVAL_BUILD:-$root/.build/harness-eval}"
mkdir -p "$build"
sqlite=()
[[ "$(uname)" == Linux ]] && sqlite=(-I "$root/Package/CSQLite")
newest="$(find "$root/Harness" "$root/tools/harness-eval/agent" -name '*.swift' -newer "$build/agent" 2>/dev/null | head -1 || true)"
if [[ ! -x "$build/agent" || -n "$newest" ]]; then
  swiftc -O -swift-version 5 "${sqlite[@]}" -o "$build/agent" "$root"/Harness/*.swift \
    "$root"/tools/harness-eval/agent/*.swift -lsqlite3
fi
exec "$build/agent" --root "$root" "$@"
