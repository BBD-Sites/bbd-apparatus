#!/usr/bin/env python3
"""What the Stop gate found on a reply the person has already read, kept for the
session's next reply and handed to it once.

  notes.py add  <notes-dir> <session-id>     the note on stdin, added to the session's file
  notes.py take <notes-dir> <session-id>     print the session's notes once, then remove them

Stop fires after the reply is on the person's screen, so a block that asks for the reply
again makes a second reply, which the person asked never to get. A finding about how the
reply reads (the reader's, the reading level, the asks it left out) is therefore not a
block: the gate adds it here, and the next UserPromptSubmit (launcher/events/prompt.sh)
takes it and puts it in front of the next reply, under one line saying the last reply
is not to be sent again. Take removes the file, so a note is heard once.

The file is <notes-dir>/<session-id>, 0600 in a 0700 directory. A note already in the
file is not added twice (a turn that stops twice finds the same things). The whole is at
most NOTES_MAX characters, the newest kept. A session id that is not a plain word adds
and takes nothing. Files older than seven days are removed on the way past. Every
command exits 0 whatever happens: a launcher never fails a turn on its own bookkeeping.
"""
from __future__ import annotations

import os
import re
import sys
import time

SESSION_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}")
TOKEN = re.compile(r"bbdt_[A-Za-z0-9]{40}")
NOTES_MAX = 2500
TTL_DAYS = 7
HEAD = (
    "About your last reply: the person has already read it. Do not send it again, and do "
    "not bring this up unless a fact in it was false. Let this reply follow these:"
)


def path_for(notes_dir: str, sid: str) -> str:
    return os.path.join(notes_dir, sid) if SESSION_ID.fullmatch(sid or "") else ""


def prune(notes_dir: str) -> None:
    cutoff = time.time() - TTL_DAYS * 86400
    try:
        names = os.listdir(notes_dir)
    except OSError:
        return
    for name in names:
        p = os.path.join(notes_dir, name)
        try:
            if os.path.getmtime(p) < cutoff:
                os.remove(p)
        except OSError:
            pass


def read(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def add(notes_dir: str, sid: str, note: str) -> None:
    path = path_for(notes_dir, sid)
    note = TOKEN.sub("[token]", note).strip()
    if not path or not note:
        return
    os.makedirs(notes_dir, mode=0o700, exist_ok=True)
    os.chmod(notes_dir, 0o700)
    prune(notes_dir)
    have = read(path).strip()
    if note in have:
        return
    text = (have + "\n\n" + note).strip() if have else note
    if len(text) > NOTES_MAX:
        text = text[-NOTES_MAX:]
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text + "\n")


def take(notes_dir: str, sid: str) -> str:
    path = path_for(notes_dir, sid)
    if not path:
        return ""
    text = read(path).strip()
    try:
        os.remove(path)
    except OSError:
        pass
    return "%s\n\n%s" % (HEAD, text) if text else ""


def main(argv: list) -> int:
    if len(argv) != 3 or argv[0] not in ("add", "take"):
        print("usage: notes.py add|take <notes-dir> <session-id>", file=sys.stderr)
        return 0
    if argv[0] == "add":
        add(argv[1], argv[2], sys.stdin.read())
    else:
        out = take(argv[1], argv[2])
        if out:
            print(out)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:  # noqa: BLE001 - a launcher must exit 0 whatever happens
        print("notes: %s" % type(exc).__name__, file=sys.stderr)
        sys.exit(0)
