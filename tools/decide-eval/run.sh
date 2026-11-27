#!/usr/bin/env bash
# Builds decide-eval against a llama.cpp build and runs it.
# LLAMA_DIR: a llama.cpp checkout built with cmake (default ~/Projects/llama.cpp-b12367).
# SWIFT: the swift binary (default: swift on PATH).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
llama=${LLAMA_DIR:-$HOME/Projects/llama.cpp-b12367}
swift=${SWIFT:-swift}
flags=(-Xcc "-I$llama/include" -Xcc "-I$llama/ggml/include" -Xlinker "-L$llama/build/bin" -Xlinker "-rpath=$llama/build/bin")
"$swift" build --package-path "$here" -c release -j "${JOBS:-2}" "${flags[@]}" >&2
exec "$here/.build/release/decide-eval" "$@"
