#!/usr/bin/env bash
# Upstream's release archive has device/Mac slices only. Build its simulator
# slice from the exact same source revision; CI caches/shares this across jobs.
set -euo pipefail
revision=fe14cad51bbfb3f1cc8d9cfd9d70e98a123743d3
checksum=4f57d09091d77c61d552939f6d75eff09a2e20e818cbb3544ec9443c168ee8b5
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="$root/build/runtime/build-apple/llama.xcframework"
if [[ -f "$destination/Info.plist" ]] && /usr/libexec/PlistBuddy -c Print "$destination/Info.plist" | grep -q simulator; then
  echo "Pinned simulator runtime already prepared."
  exit 0
fi
mkdir -p "$root/build/runtime-simulator/source" "$root/artifacts"
archive="$root/build/runtime-simulator/source.tar.gz"
curl --fail --location --retry 3 "https://github.com/ggml-org/llama.cpp/archive/$revision.tar.gz" -o "$archive"
echo "$checksum  $archive" | shasum -a 256 -c -
tar -xzf "$archive" -C "$root/build/runtime-simulator/source" --strip-components=1
(
  cd "$root/build/runtime-simulator/source"
  bash build-xcframework.sh ios-sim
) 2>&1 | tee "$root/artifacts/llama-simulator-build.log"
mkdir -p "$(dirname "$destination")"
ditto "$root/build/runtime-simulator/source/build-apple/llama.xcframework" "$destination"
