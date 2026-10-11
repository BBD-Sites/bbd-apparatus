#!/usr/bin/env python3
"""The Stop loop guard: at most one block per turn, across every check that may block,
and never more than two.

  loopguard.py allow <guard-dir> <session-id> <turn-key> [cap [tag]]
  loopguard.py tag   <guard-dir> <session-id> <turn-key>

Exits 0 when a block is allowed now, and counts it; exits 1 when the cap for this turn
is already reached, so the caller lets the turn end. The turn key is the hook's
prompt_id, which changes only when the person sends a new prompt; a caller with no
prompt_id passes the draft's hash instead, which guards against the same draft being
blocked twice. The record is <guard-dir>/<session-id>.turn, one line, "<turn-key>
<count> [tag]"; a new turn key resets the count. The tag says what the last block
carried (the Stop gate writes "grade" for a block that quoted the hard sentences, whatever
else it carried, and "other" for any other), and `tag` prints it for the same turn key,
or nothing. The default cap is 1; a caller may ask for 2 (one more block when the first
quoted the hard sentences and the second-pass reader says fix) and the guard clamps any
larger ask to MAX_CAP, 2. Files older than seven days are removed on
the way past.

Why one: a block makes the model write its reply again, and a check that fires on the
rewritten reply too would hold the turn open for as long as it kept finding things. One
corrective pass is the help; the rest is noise. The second pass is let through whatever
the reader says.

Fail open: a session id that is not a plain word, an unwritable directory or a damaged
record all exit 0, because the guard only ever suppresses a block and must never
introduce one.
"""
from __future__ import annotations

import os
import re
import sys
import time

SESSION_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}")
DEFAULT_CAP = 1
MAX_CAP = 2
TTL_DAYS = 7


def prune(guard_dir: str) -> None:
    cutoff = time.time() - TTL_DAYS * 86400
    try:
        names = os.listdir(guard_dir)
    except OSError:
        return
    for name in names:
        path = os.path.join(guard_dir, name)
        try:
            if name.endswith(".turn") and os.path.getmtime(path) < cutoff:
                os.remove(path)
        except OSError:
            pass


def read_record(path: str) -> tuple:
    """(turn key, count, tag) from the record, or ("", 0, "") when absent or damaged."""
    try:
        with open(path, encoding="utf-8") as f:
            parts = f.read().split()
        if len(parts) in (2, 3) and parts[1].isdigit():
            return parts[0], int(parts[1]), parts[2] if len(parts) == 3 else ""
    except OSError:
        pass
    return "", 0, ""


def tag_of(guard_dir: str, sid: str, turn_key: str) -> str:
    """What the last block of this turn carried, or "" (also for any error)."""
    if not SESSION_ID.fullmatch(sid or "") or not turn_key:
        return ""
    key, count, tag = read_record(os.path.join(guard_dir, sid + ".turn"))
    return tag if key == turn_key and count > 0 else ""


def allow(guard_dir: str, sid: str, turn_key: str, cap: int, tag: str = "") -> bool:
    cap = min(max(1, cap), MAX_CAP)
    if not SESSION_ID.fullmatch(sid or "") or not turn_key:
        return True
    try:
        os.makedirs(guard_dir, mode=0o700, exist_ok=True)
        os.chmod(guard_dir, 0o700)
    except OSError:
        return True
    prune(guard_dir)
    path = os.path.join(guard_dir, sid + ".turn")
    stored_key, count, _old = read_record(path)
    if stored_key != turn_key:
        count = 0
    if count >= cap:
        return False
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(("%s %d %s\n" % (turn_key, count + 1, tag)) if tag else ("%s %d\n" % (turn_key, count + 1)))
    except OSError:
        return True
    return True


def main(argv: list) -> int:
    if len(argv) in (4, 5, 6) and argv[0] == "allow":
        cap = DEFAULT_CAP
        if len(argv) >= 5:
            try:
                cap = max(1, int(argv[4]))
            except ValueError:
                cap = DEFAULT_CAP
        tag = argv[5] if len(argv) == 6 and re.fullmatch(r"[a-z]{1,16}", argv[5]) else ""
        return 0 if allow(argv[1], argv[2], argv[3], cap, tag) else 1
    if len(argv) == 4 and argv[0] == "tag":
        print(tag_of(argv[1], argv[2], argv[3]))
        return 0
    print("usage: loopguard.py allow <guard-dir> <session-id> <turn-key> [cap [tag]] | tag <guard-dir> <session-id> <turn-key>", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:  # noqa: BLE001 - the guard only ever suppresses; a crash allows
        print("loopguard: %s" % type(exc).__name__, file=sys.stderr)
        sys.exit(0)
