#!/usr/bin/env python3
"""Shipping a session's transcript. For now only the queue: the pointer record that
says a session has a transcript to ship. Rendering, redaction, the post to the store
and the captures branch arrive with the ship step (docs/launcher-contract.md 6, 8).

  ship.py queue-pointer <queue-dir> <input-file> <where>

A pointer holds no transcript text, so nothing unredacted is ever copied: redaction
runs when the queue is drained. One record per session, replaced in place, always
points at the latest transcript and keeps when it was first seen and how many times
shipping it was tried. The bootstrap writes the same record, with the same rules,
when no checkout exists yet; tests/test-fail-safe.sh holds the two to one shape.
"""
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
import time

SESSION_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}")


def queue_pointer(queue: str, hook: dict, where: str) -> str | None:
    """Write or refresh queue/<session_id>.json; returns its path, or None if the hook
    named no usable session (an id that is not a plain token could name a path)."""
    sid, path = hook.get("session_id"), hook.get("transcript_path")
    if not isinstance(sid, str) or not SESSION_ID.fullmatch(sid):
        return None
    target = os.path.join(queue, sid + ".json")
    try:
        with open(target, encoding="utf-8") as f:
            old = json.load(f)
    except (OSError, ValueError):
        old = {}
    if not isinstance(old, dict):
        old = {}
    attempts = old.get("attempts")
    record = {
        "session_id": sid,
        "transcript_path": path if isinstance(path, str) and path else str(old.get("transcript_path") or ""),
        "where": where,
        "first_seen": old.get("first_seen") or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "attempts": attempts if isinstance(attempts, int) and not isinstance(attempts, bool) else 0,
    }
    # mkstemp makes the file 0600, and the rename means a reader never sees half a record.
    fd, tmp = tempfile.mkstemp(dir=queue, prefix=".pointer.")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(record, f, sort_keys=True)
        f.write("\n")
    os.replace(tmp, target)
    return target


def main(argv: list) -> int:
    if len(argv) == 4 and argv[0] == "queue-pointer":
        queue, input_file, where = argv[1], argv[2], argv[3]
        try:
            with open(input_file, encoding="utf-8") as f:
                hook = json.load(f)
        except (OSError, ValueError):
            return 0
        if isinstance(hook, dict):
            queue_pointer(queue, hook, where)
        return 0
    print("usage: ship.py queue-pointer <queue-dir> <input-file> <where>", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:  # noqa: BLE001 - a launcher must exit 0 whatever happens
        print("ship: %s" % type(exc).__name__, file=sys.stderr)
        sys.exit(0)
