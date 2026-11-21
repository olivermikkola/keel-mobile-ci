#!/usr/bin/env bash
# Opt-in native agent smoke. A real catalog model; never a scripted response.
set -euo pipefail
mkdir -p build/fixtures
model_path=build/fixtures/bonsai-agent-smoke.gguf
model_sha=64a5183b44921bdb5ac4a6f5f92007821d6ebe5c66997d3c147fd214ab9433d4
if [[ ! -f "$model_path" ]] || ! echo "$model_sha  $model_path" | shasum -a 256 -c - >/dev/null 2>&1; then
  curl --fail --location --retry 3 \
    'https://huggingface.co/prism-ml/Ternary-Bonsai-2-4B-gguf/resolve/50ebba61be85e5be07e8083db468ace0fc1bac43/Ternary-Bonsai-2-4B-Q2_0.gguf' \
    --output "$model_path.partial"
  echo "$model_sha  $model_path.partial" | shasum -a 256 -c -
  mv "$model_path.partial" "$model_path"
fi
