#!/usr/bin/env python3
"""Select an available iOS simulator of the requested device family."""
import argparse
import json
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--family", choices=["iPhone", "iPad"], default="iPhone")
family = parser.parse_args().family

devices = json.loads(subprocess.check_output(
    ["xcrun", "simctl", "list", "devices", "available", "--json"], text=True
))["devices"]
for runtime, entries in devices.items():
    if ".iOS-" not in runtime:
        continue
    for device in entries:
        if device.get("isAvailable") and device["name"].startswith(family):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit(f"No available {family} simulator. Install a matching iOS simulator on the build machine.")
