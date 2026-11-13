#!/usr/bin/env bash
# Pinned Bonsai-capable runtime. Run before XcodeGen on macOS.
set -euo pipefail
version=prism-b12128-d7b2896
checksum=f61bc329b9c33ea207e685370de1660115ecbce1c3bfeeb2e2b8534099b31ed0
mkdir -p build/runtime
archive=build/runtime/llama.zip
if [[ ! -f "$archive" ]]; then
  curl --fail --location --retry 3 \
    "https://github.com/PrismML-Eng/llama.cpp/releases/download/$version/llama-$version-xcframework.zip" \
    -o "$archive.partial"
  mv "$archive.partial" "$archive"
fi
echo "$checksum  $archive" | shasum -a 256 -c -
unzip -q -o "$archive" -d build/runtime
