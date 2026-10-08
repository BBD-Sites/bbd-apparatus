#!/usr/bin/env python3
"""The reader receipt: one small file per draft the reader was run on, named by the hash
of the draft's text, so the Stop gate can tell a draft it has already read from a new
one, and so a later look can see what the reader said about each.

  receipt.py hash <draft-file>                        print the draft's hash
  receipt.py exists <receipt-dir> <draft-file>        exit 0 when a receipt exists
  receipt.py write <receipt-dir> <draft-file> [key=value ...]
                                                      write the receipt; prints its path
  receipt.py show <receipt-dir> <draft-file>          print the receipt's JSON, or nothing

The hash is sha256 of the text with every run of whitespace folded to one space and the
ends trimmed, so a re-wrapped copy of the same words is the same draft. The receipt is
<receipt-dir>/<hash>.json, 0600 in a 0700 directory, holding whatever key=value pairs
the caller gives (session, verdict, findings, blocked, elapsed, status, stop_reason,
read_at) and never the draft's text. The per-session ask ledger is a different file
and is not touched here. Every command but `exists` exits 0 whatever happens: a
launcher never fails a turn on its own bookkeeping.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import tempfile
import time

HASH_RE = re.compile(r"[0-9a-f]{64}")
# Receipts older than this are removed when a new one is written, so the directory
# does not grow for ever; a draft is only ever re-read within one turn.
TTL_DAYS = 7


def normalize(text: str) -> str:
    return " ".join(text.split())


def draft_hash(text: str) -> str:
    return hashlib.sha256(normalize(text).encode("utf-8")).hexdigest()


def read_file(path: str) -> str:
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def receipt_path(receipt_dir: str, text: str) -> str:
    return os.path.join(receipt_dir, draft_hash(text) + ".json")


def exists(receipt_dir: str, text: str) -> bool:
    return os.path.isfile(receipt_path(receipt_dir, text))


def load(receipt_dir: str, text: str) -> dict:
    try:
        with open(receipt_path(receipt_dir, text), encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return {}
    return doc if isinstance(doc, dict) else {}


def coerce(value: str):
    """A key=value pair's value as a number or boolean where it reads as one."""
    if value in ("true", "false"):
        return value == "true"
    try:
        if re.fullmatch(r"-?\d+", value):
            return int(value)
        if re.fullmatch(r"-?\d+\.\d+", value):
            return float(value)
    except ValueError:
        pass
    return value


def prune(receipt_dir: str) -> None:
    cutoff = time.time() - TTL_DAYS * 86400
    try:
        names = os.listdir(receipt_dir)
    except OSError:
        return
    for name in names:
        path = os.path.join(receipt_dir, name)
        try:
            if name.endswith(".json") and os.path.getmtime(path) < cutoff:
                os.remove(path)
        except OSError:
            pass


def write(receipt_dir: str, text: str, fields: dict) -> str:
    os.makedirs(receipt_dir, mode=0o700, exist_ok=True)
    os.chmod(receipt_dir, 0o700)
    prune(receipt_dir)
    doc = dict(fields)
    doc["draft_hash"] = draft_hash(text)
    doc.setdefault("read_at", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    path = receipt_path(receipt_dir, text)
    fd, tmp = tempfile.mkstemp(dir=receipt_dir, prefix=".receipt.")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(doc, f, sort_keys=True)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    return path


def main(argv: list) -> int:
    if len(argv) == 2 and argv[0] == "hash":
        print(draft_hash(read_file(argv[1])))
        return 0
    if len(argv) == 3 and argv[0] == "exists":
        return 0 if exists(argv[1], read_file(argv[2])) else 1
    if len(argv) == 3 and argv[0] == "show":
        doc = load(argv[1], read_file(argv[2]))
        if doc:
            print(json.dumps(doc, sort_keys=True))
        return 0
    if len(argv) >= 3 and argv[0] == "write":
        fields = {}
        for pair in argv[3:]:
            key, sep, value = pair.partition("=")
            if sep and re.fullmatch(r"[a-z_]{1,40}", key):
                fields[key] = coerce(value)
        print(write(argv[1], read_file(argv[2]), fields))
        return 0
    print("usage: receipt.py hash|exists|show|write ...", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:  # noqa: BLE001 - a launcher must exit 0 whatever happens
        print("receipt: %s" % type(exc).__name__, file=sys.stderr)
        sys.exit(0)
