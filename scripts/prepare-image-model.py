#!/usr/bin/env python3
"""Download the pinned Core ML image model folder for the image smoke test; every file is size- and SHA-256-checked."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
packs = json.loads((root / "scripts/fixtures/image-models.json").read_text())
if len(sys.argv) != 2 or sys.argv[1] not in packs:
    raise SystemExit("Usage: prepare-image-model.py {" + "|".join(packs) + "}")
pack = packs[sys.argv[1]]
folder = root / "build/fixtures/image" / sys.argv[1]
for item in pack["files"]:
    destination = folder / item["path"]
    destination.parent.mkdir(parents=True, exist_ok=True)

    def verified(path):
        if not path.exists() or path.stat().st_size != item["bytes"]:
            return False
        with path.open("rb") as stream:
            return hashlib.file_digest(stream, "sha256").hexdigest() == item["sha256"]

    if not verified(destination):
        url = f"https://huggingface.co/{pack['repository']}/resolve/{pack['revision']}/{pack['remoteFolder']}/{item['path']}"
        temporary = destination.with_name(destination.name + ".download")
        subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--silent", "--show-error", "--output", str(temporary), url], check=True)
        if not verified(temporary):
            raise SystemExit("Image model file failed pinned size/SHA-256 verification: " + item["path"])
        temporary.replace(destination)
    print("Verified", item["path"], item["bytes"], "bytes")
print(folder)
