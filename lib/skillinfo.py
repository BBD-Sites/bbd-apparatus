#!/usr/bin/env python3
"""Facts a skill's printed text needs from the checkout and the repository.

  skillinfo.py gate <gates.json> <skill> <channel>
        exit 0 when the skill is open on that channel, 1 when it is closed. Only the
        skills in GATED can be closed (the planning loop is not offered to a buyer until
        the operator has run four weekly reviews on it): one is open only on the channels
        the file lists for it, and a missing or unreadable file closes it everywhere.
  skillinfo.py place <repo-root>
        print the "This repository" block of the capture skill: the size limit for a file
        kept in the repository, in megabytes and bytes, and where a bigger file stays.

The limit is the one the vault's README states ("A file up to N MB is kept in
attachments/"), twenty-five when it states none (large-files requirement). The place is
the buyer's Drive only when the platform has written .apparatus/storage.json with
"drive": true (the buyer connected it in the portal); with no such file, or one that does
not say so, it is the buyer's own store prefix, which is the default and the right answer.
Nothing here asks the buyer anything, and a fault prints the default. Exits 0 except gate.
"""
from __future__ import annotations

import json
import os
import re
import sys

DEFAULT_LIMIT_MB = 25
GATED = ("plan",)
LIMIT_RE = re.compile(r"\bup to (\d{1,4}) ?MB\b", re.I)


def limit_mb(root: str) -> int:
    for rel in ("README.md", os.path.join("attachments", "README.md")):
        try:
            with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as f:
                m = LIMIT_RE.search(f.read(20000))
        except OSError:
            continue
        if m and int(m.group(1)) > 0:
            return int(m.group(1))
    return DEFAULT_LIMIT_MB


def drive_connected(root: str) -> bool:
    try:
        with open(os.path.join(root, ".apparatus", "storage.json"), encoding="utf-8") as f:
            return json.load(f).get("drive") is True
    except (OSError, ValueError, AttributeError):
        return False


def place(root: str) -> str:
    mb = limit_mb(root)
    where = "the owner's Google Drive folder for this system" if drive_connected(root) else "the owner's own store"
    return (
        "## This repository\n"
        "Size limit for a file kept in the repository: %d MB (%d bytes). A bigger file goes to %s.\n"
        % (mb, mb * 1024 * 1024, where)
    )


def gate_open(path: str, skill: str, channel: str) -> bool:
    if skill not in GATED:
        return True
    try:
        with open(path, encoding="utf-8") as f:
            chans = json.load(f).get(skill)
    except (OSError, ValueError, AttributeError):
        return False
    return isinstance(chans, list) and channel in chans


def main(argv: list) -> int:
    if len(argv) == 4 and argv[0] == "gate":
        return 0 if gate_open(argv[1], argv[2], argv[3]) else 1
    if len(argv) == 2 and argv[0] == "place":
        sys.stdout.write(place(argv[1]))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception:
        sys.exit(1 if sys.argv[1:2] == ["gate"] else 0)
