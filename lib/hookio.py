#!/usr/bin/env python3
"""Hook input and output: the one place that reads a hook's stdin JSON and writes the
JSON Claude Code reads back, so every event speaks the same shape.

  hookio.py field <input-file> <name>    print one top-level string field, or nothing,
                                         as one line (newlines become spaces)
  hookio.py text <input-file> <name>     print one top-level string field as it is,
                                         newlines kept, for a caller writing it to a file
  hookio.py flag <input-file> <name>     exit 0 when the field is true (a boolean, or
                                         the word), else 1
  hookio.py context <EventName>          stdin text -> hookSpecificOutput.additionalContext
  hookio.py block                        stdin text -> {"decision": "block", "reason": ...}
  hookio.py check                        stdin -> the same JSON object, or nothing

Every command but `flag` exits 0: a launcher must never fail a turn. `check` prints only a single
JSON object and drops anything else, because a hook's stdout on UserPromptSubmit
becomes model context and on Stop becomes a decision.
"""
from __future__ import annotations

import json
import sys
from typing import Any


def load(path: str) -> dict:
    """The hook's input as a dict; an unreadable or non-object input is empty."""
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return {}
    return doc if isinstance(doc, dict) else {}


def field(doc: dict, name: str) -> str:
    value = doc.get(name)
    return value if isinstance(value, str) else ""


def context(event: str, text: str) -> str:
    return json.dumps(
        {"hookSpecificOutput": {"hookEventName": event, "additionalContext": text}}
    )


def block(reason: str) -> str:
    return json.dumps({"decision": "block", "reason": reason})


def check(raw: str) -> str:
    """The input re-serialized if it is one JSON object, else the empty string."""
    try:
        doc: Any = json.loads(raw)
    except ValueError:
        return ""
    return json.dumps(doc) if isinstance(doc, dict) else ""


def main(argv: list) -> int:
    if not argv:
        return 0
    cmd = argv[0]
    if cmd == "field" and len(argv) == 3:
        value = field(load(argv[1]), argv[2])
        if value:
            # One line: a caller reads it with $(...), and a newline would split it.
            print(value.replace("\n", " ").replace("\r", " "))
    elif cmd == "text" and len(argv) == 3:
        value = field(load(argv[1]), argv[2])
        if value:
            sys.stdout.write(value)
    elif cmd == "flag" and len(argv) == 3:
        value = load(argv[1]).get(argv[2])
        return 0 if value is True or value == "true" else 1
    elif cmd == "context" and len(argv) == 2:
        text = sys.stdin.read()
        if text.strip():
            print(context(argv[1], text))
    elif cmd == "block" and len(argv) == 1:
        reason = sys.stdin.read().strip()
        if reason:
            print(block(reason))
    elif cmd == "check" and len(argv) == 1:
        out = check(sys.stdin.read())
        if out:
            print(out)
        else:
            print("hookio: dropped output that was not one JSON object", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:  # noqa: BLE001 - a launcher must exit 0 whatever happens
        print("hookio: %s" % type(exc).__name__, file=sys.stderr)
        sys.exit(0)
