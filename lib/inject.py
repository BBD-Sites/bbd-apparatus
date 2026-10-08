#!/usr/bin/env python3
"""The context a prompt or a compaction injects, composed under a hard cap and printed
as the one JSON object the hook may write.

  inject.py --event <EventName> --cap <chars> --ledger <dir> --session <id>
            [--text <file>]... [--inline <text>]... [--section <title> <file>]...

In order: every --text file and --inline text as it is (the apparatus's own texts; an
empty --inline adds nothing), every --section as a
"## title" heading over the file (the tenant's rules and standing instructions; a
missing or empty file gives no section), then the session's open asks from the
ledger. The whole is at most --cap characters. The asks give way first, oldest
first (lib/ledger.py); if the texts alone pass the cap, their tail is cut and the cut
is said. A token shape is masked wherever it appears, because this output becomes
model context. Prints nothing when there is nothing to say. Exits 0 always.
"""
from __future__ import annotations

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import hookio  # noqa: E402
import ledger  # noqa: E402

TOKEN = re.compile(r"bbdt_[A-Za-z0-9]{40}")


def read_text(path: str, limit: int) -> str:
    """The first LIMIT characters of a file; an unreadable file is empty."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read(limit).strip()
    except OSError:
        return ""


def compose(cap: int, ledger_dir: str, sid: str, texts: list, sections: list) -> str:
    parts = []
    for kind, value in texts:
        text = read_text(value, cap + 1) if kind == "file" else value.strip()[: cap + 1]
        if text:
            parts.append(text)
    for title, path in sections:
        text = read_text(path, cap + 1)
        if text:
            parts.append("## %s\n\n%s" % (title, text))
    if not parts:
        return ""
    head = TOKEN.sub("[token]", "\n\n".join(parts)) + "\n"
    if len(head) > cap:
        note = "\n[cut at %d characters]\n" % cap
        return head[: cap - len(note)].rstrip() + note
    block = ledger.render(ledger_dir, sid, cap - len(head) - 1) if sid else ""
    if block:
        head += "\n" + TOKEN.sub("[token]", block)
    return head


def parse(argv: list) -> dict | None:
    opts = {"event": "", "cap": 6000, "ledger": "", "session": "", "texts": [], "sections": []}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--event", "--cap", "--ledger", "--session", "--text", "--inline") and i + 1 < len(argv):
            v = argv[i + 1]
            if a == "--text":
                opts["texts"].append(("file", v))
            elif a == "--inline":
                opts["texts"].append(("inline", v))
            elif a == "--cap":
                try:
                    opts["cap"] = max(0, int(v))
                except ValueError:
                    return None
            else:
                opts[a[2:]] = v
            i += 2
        elif a == "--section" and i + 2 < len(argv):
            opts["sections"].append((argv[i + 1], argv[i + 2]))
            i += 3
        else:
            return None
    return opts if opts["event"] else None


def main(argv: list) -> int:
    opts = parse(argv)
    if opts is None:
        print("usage: inject.py --event E --cap N --ledger DIR --session ID [--text F]... [--inline T]..."
              " [--section T F]...", file=sys.stderr)
        return 0
    sid = opts["session"] if ledger.SESSION_ID.fullmatch(opts["session"] or "") else ""
    text = compose(opts["cap"], opts["ledger"], sid, opts["texts"], opts["sections"])
    if text.strip():
        print(hookio.context(opts["event"], text))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:  # noqa: BLE001 - a launcher must exit 0 whatever happens
        print("inject: %s" % type(exc).__name__, file=sys.stderr)
        sys.exit(0)
