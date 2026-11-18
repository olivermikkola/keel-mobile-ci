#!/usr/bin/env python3
"""Collect real Bonsai tool-call outputs using Keel Mobile's own prompt.

Sends repository tasks to a llama.cpp server (default http://127.0.0.1:8080)
with the app's system prompt and ChatML rendering, and the app's sampler
(top_k 40, top_p 0.9, temperature 0.6, 512-token limit, thinking off).
Writes one JSON line per sample. Read-only: nothing is executed.

  python3 tools/harness-eval/collect.py --out /tmp/outputs.jsonl --samples 2
"""
import argparse, json, re, subprocess, textwrap, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

TASKS = [
    "What does this repository do? Answer from the README.",
    "Where is the model download resumed after a pause?",
    "Which file defines the GitHub repository client?",
    "How many tool calls can the agent make per message?",
    "Find where the KV cache memory budget is computed.",
    "What models can I download in the app?",
    "Which workflow runs the iOS simulator tests?",
    "Where does the app stop generating when it goes to the background?",
    "Explain how edit proposals are reviewed before they apply.",
    "Is there a test for saved task deletion? Show it.",
    "What license is this project under?",
    "Where is the system prompt for Director mode?",
]

def system_prompt(repo: str, commit: str) -> str:
    source = (ROOT / "Sources/RepositoryAgent.swift").read_text()
    body = source.split('let system = """', 1)[1].split('"""', 1)[0]
    body = textwrap.dedent(body).strip("\n")
    return body.replace(r"\(snapshot.repository.fullName)", repo).replace(r"\(snapshot.commit)", commit)

def render(system: str, messages: list) -> str:
    # Same shape as LocalInference.prompt (Qwen ChatML, thinking off).
    last_user = max(i for i, m in enumerate(messages) if m["role"] == "user")
    out = f"<|im_start|>system\n{system.strip()}<|im_end|>\n"
    for i, m in enumerate(messages):
        text = m["text"].strip()
        if m["role"] == "tool":
            if i == 0 or messages[i - 1]["role"] != "tool": out += "<|im_start|>user"
            out += f"\n<tool_response>\n{text}\n</tool_response>"
            if i == len(messages) - 1 or messages[i + 1]["role"] != "tool": out += "<|im_end|>\n"
        else:
            out += f"<|im_start|>{m['role']}\n"
            if m["role"] == "assistant" and i > last_user: out += "<think>\n\n</think>\n\n"
            out += f"{text}<|im_end|>\n"
    return out + "<|im_start|>assistant\n<think>\n\n</think>\n\n"

def root_listing(commit: str) -> str:
    rows = subprocess.run(["git", "-C", str(ROOT), "ls-tree", commit], capture_output=True, text=True, check=True).stdout
    entries = []
    for row in rows.splitlines():
        meta, name = row.split("\t", 1)
        entries.append({"kind": "directory" if meta.split()[1] == "tree" else "file", "name": name})
    return json.dumps({"commit": commit, "entries": entries[:30], "next_offset": None, "note": "Names and types only. No file contents are included. Use read_file for text.",
                       "path": "", "result_type": "directory_listing", "total": len(entries)}, sort_keys=True, separators=(",", ":"))

LIST_ROOT = "<tool_call>\n<function=list_files>\n<parameter=path>.</parameter>\n</function>\n</tool_call>"

def complete(server: str, prompt: str, seed: int) -> dict:
    body = json.dumps({"prompt": prompt, "n_predict": 512, "top_k": 40, "top_p": 0.9, "temperature": 0.6,
                       "seed": seed, "cache_prompt": True, "stop": ["<|im_end|>"]}).encode()
    req = urllib.request.Request(server + "/completion", body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.load(r)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", default="http://127.0.0.1:8080")
    ap.add_argument("--out", required=True)
    ap.add_argument("--samples", type=int, default=2)
    a = ap.parse_args()
    commit = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    system = system_prompt("olivermikkola/keel-mobile", commit)
    listing = root_listing(commit)
    with open(a.out, "w") as f:
        for t, task in enumerate(TASKS):
            for turn in (1, 2):
                messages = [{"role": "user", "text": task}]
                if turn == 2:
                    messages += [{"role": "assistant", "text": LIST_ROOT}, {"role": "tool", "text": listing}]
                for s in range(a.samples):
                    r = complete(a.server, render(system, messages), seed=1000 * t + 10 * turn + s)
                    row = {"task": task, "turn": turn, "sample": s, "output": r["content"],
                           "tokens": r.get("tokens_predicted"), "model": Path(r.get("model", "")).name}
                    f.write(json.dumps(row) + "\n"); f.flush()
                    print(f"task {t} turn {turn} sample {s}: {r.get('tokens_predicted')} tokens", flush=True)

if __name__ == "__main__":
    main()
