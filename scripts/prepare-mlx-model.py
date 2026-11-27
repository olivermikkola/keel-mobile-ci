#!/usr/bin/env python3
"""Download one pinned MLX model folder for the MLX probe; every file is size- and SHA-256-checked."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
packs = json.loads((root / "scripts/fixtures/mlx-models.json").read_text())
if len(sys.argv) != 2 or sys.argv[1] not in packs:
    raise SystemExit("Usage: prepare-mlx-model.py {" + "|".join(packs) + "}")
pack = packs[sys.argv[1]]
folder = root / "build/fixtures/mlx" / sys.argv[1]
folder.mkdir(parents=True, exist_ok=True)
for item in pack["files"]:
    destination = folder / item["name"]

    def verified(path):
        if not path.exists() or path.stat().st_size != item["bytes"]:
            return False
        with path.open("rb") as stream:
            return hashlib.file_digest(stream, "sha256").hexdigest() == item["sha256"]

    if not verified(destination):
        url = f"https://huggingface.co/{pack['repository']}/resolve/{pack['revision']}/{item['name']}"
        temporary = destination.with_suffix(destination.suffix + ".download")
        subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--output", str(temporary), url], check=True)
        if not verified(temporary):
            raise SystemExit("MLX model file failed pinned size/SHA-256 verification: " + item["name"])
        temporary.replace(destination)
    print("Verified", item["name"], item["bytes"], "bytes")
print(folder)
