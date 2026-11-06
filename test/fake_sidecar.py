#!/usr/bin/env python3
"""Canned sidecar for the headless flow spec: answers every request with the
same two-edit chain (rewrite line 1, rewrite line 4), echoing the request id,
or with the edit list in NEOCURSOR_FAKE_EDITS_FILE when that is set.
Invoked exactly like the real sidecar, so init.lua's job plumbing is exercised
unmodified; the trailing real-sidecar path argument is ignored."""
import json
import os
import sys
import time

ERROR_FILE = os.environ.get("NEOCURSOR_FAKE_ERROR_FILE")
EDITS_FILE = os.environ.get("NEOCURSOR_FAKE_EDITS_FILE")
REQUEST_FILE = os.environ.get("NEOCURSOR_FAKE_REQUEST_FILE")

print("ready", file=sys.stderr, flush=True)

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    time.sleep(0.3)  # realistic backend RTT; a killed suggestion can't silently
    # resurrect via instant refetch, which would mask flow regressions
    try:
        req = json.loads(line)
    except json.JSONDecodeError:
        continue
    if REQUEST_FILE:
        with open(REQUEST_FILE, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    if ERROR_FILE and os.path.exists(ERROR_FILE):
        with open(ERROR_FILE, encoding="utf-8") as fh:
            print(json.dumps({"id": req.get("id"), "error": fh.read().strip()}), flush=True)
        continue
    edits = [
        {"text": "line1 = 100", "range": {"start": 1, "endInclusive": 1}},
        {"text": "line4 = 400", "range": {"start": 4, "endInclusive": 4}},
    ]
    if EDITS_FILE:
        with open(EDITS_FILE, encoding="utf-8") as fh:
            edits = json.load(fh)
    res = {
        "id": req.get("id"),
        "text": edits[0]["text"],
        "range": edits[0]["range"],
        "edits": edits,
        # after the chain, the server predicts the next place to edit
        "prediction": {"path": req.get("path"), "line": 2},
    }
    print(json.dumps(res), flush=True)
