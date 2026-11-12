#!/usr/bin/env bash
# Tiny CPU-only test fixture. Never offered as a product model.
set -euo pipefail
mkdir -p build/fixtures
file=build/fixtures/stories15M-q4_0.gguf
if [[ ! -f "$file" ]]; then
  curl --fail --location --retry 3 \
    https://huggingface.co/ggml-org/models/resolve/499bc8821c6b12b4e53c5bffcb21ec206f212d81/tinyllamas/stories15M-q4_0.gguf \
    -o "$file.partial"
  mv "$file.partial" "$file"
fi
echo "66967fbece6dbe97886593fdbb73589584927e29119ec31f08090732d1861739  $file" | shasum -a 256 -c -
