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

# A small real embedding model for the search-by-meaning test (English only).
# The product's search model is larger; this one keeps the test bundle small.
embedding=build/fixtures/all-MiniLM-L6-v2-Q4_K_M.gguf
if [[ ! -f "$embedding" ]]; then
  curl --fail --location --retry 3 \
    https://huggingface.co/second-state/All-MiniLM-L6-v2-Embedding-GGUF/resolve/544f204f2eaa2d71361ffc74d6df7170285b286a/all-MiniLM-L6-v2-Q4_K_M.gguf \
    -o "$embedding.partial"
  mv "$embedding.partial" "$embedding"
fi
echo "2ec4cee28a27a9c973d5f5230930d6ef6e52694bd2bc71be26a9bef5b1d755e6  $embedding" | shasum -a 256 -c -
