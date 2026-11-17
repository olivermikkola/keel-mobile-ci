#!/usr/bin/env python3
"""Fail a live-only CI gate before model download/build if public quota is low."""
import datetime
import json
import sys
import urllib.error
import urllib.request

request = urllib.request.Request(
    "https://api.github.com/rate_limit",
    headers={"User-Agent": "KeelMobile-CI", "Cache-Control": "no-cache"},
)
try:
    with urllib.request.urlopen(request, timeout=20) as response:
        core = json.load(response)["resources"]["core"]
    reset = datetime.datetime.fromtimestamp(core["reset"], datetime.timezone.utc)
    print(f"Anonymous GitHub core quota: {core['remaining']}/{core['limit']}; resets {reset.isoformat()}")
    if core["remaining"] < 10:
        sys.exit("Live check cannot start: shared runner GitHub quota is low. Retry after the reset.")
except (urllib.error.URLError, ValueError, KeyError) as error:
    sys.exit(f"GitHub quota preflight unavailable ({type(error).__name__}); live proof was not run.")
