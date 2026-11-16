#!/usr/bin/env python3
"""Prepare one real, pinned model for opt-in native checks; no inference here."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
models = json.loads((root / "scripts/fixtures/small-models.json").read_text())
if len(sys.argv) != 2 or sys.argv[1] not in models:
    raise SystemExit("Usage: prepare-small-model.py {4B|lfm3|lfm3-vl|minicpm5}")
folder = root / "build/fixtures"
folder.mkdir(parents=True, exist_ok=True)
for asset in models[sys.argv[1]]:
    destination = folder / asset["filename"]

    def verified(path):
        if not path.exists() or path.stat().st_size != asset["bytes"]:
            return False
        with path.open("rb") as stream:
            return hashlib.file_digest(stream, "sha256").hexdigest() == asset["sha256"]

    if not verified(destination):
        temporary = destination.with_suffix(".download")
        subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--output", str(temporary), asset["url"]], check=True)
        if not verified(temporary):
            raise SystemExit("Model fixture failed pinned size/SHA-256 verification: " + asset["filename"])
        temporary.replace(destination)
    print("Verified", asset["filename"], asset["bytes"], "bytes")
