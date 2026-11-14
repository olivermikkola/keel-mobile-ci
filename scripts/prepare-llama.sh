#!/usr/bin/env bash
# Pinned runtime with Bonsai Q2_0, LFM3/vision and MiniCPM5 support.
set -euo pipefail
version=b12367
checksum=8da10b8b087a06e0a06c48ee6967d91a4a008aa4b6eb50423faa131abd6e1355
mkdir -p build/runtime
archive=build/runtime/llama-$version.zip
if [[ ! -f "$archive" ]]; then
  curl --fail --location --retry 3 \
    "https://github.com/ggml-org/llama.cpp/releases/download/$version/llama-$version-xcframework.zip" \
    -o "$archive.partial"
  mv "$archive.partial" "$archive"
fi
echo "$checksum  $archive" | shasum -a 256 -c -
unzip -q -o "$archive" -d build/runtime
