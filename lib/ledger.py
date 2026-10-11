#!/usr/bin/env python3
"""The per-session ask ledger: every ask the person typed, as one numbered line in the
order it came, so a reply can answer each by its number and a context summary cannot
lose one. The prompt step appends to it on every turn; the prompt and compact steps
read it back.

  ledger.py append <ledger-dir> <input-file>            record the hook's prompt; prints
                                                        the item's number, or nothing
                                                        when the prompt is skipped
  ledger.py open <ledger-dir> <session-id>              the pending items (open, running or
                                                        waiting), one per line
  ledger.py render <ledger-dir> <session-id> [<max>]    the pending items as a block to
                                                        inject, within <max> characters,
                                                        the oldest dropped first
  ledger.py close <ledger-dir> <session-id> <n>         mark item <n> done
  ledger.py mark <ledger-dir> <session-id> <n> <state>  move item <n> to open, running,
                                                        waiting or done (a done item stays done)
  ledger.py account <ledger-dir> <session-id> <reply-file>
                                                        read the reply for where each pending
                                                        ask stands, move the items it names,
                                                        and print the ones it left out

The file is <ledger-dir>/<session_id>.md, 0600 in a 0700 directory:

    # Asks in this session (the person's words, whole, spaces folded)

    1. running 2026-01-05T10:10Z: Make the home page load faster.
    2. done 2026-01-05T10:12Z: And add the phone number to the footer?

An item is open when it is said, then running, waiting or done as the reply says where
it stands (design D23). Only done leaves the list; the rest are pending, and are
injected on every prompt and after every compaction until a reply closes them.

A number is given once and never again, so "number 2" means the same ask for the
whole session, even after it is closed. Skipped, because none of them is the person's
ask: a prompt that is empty once the harness's own wrappers are removed, a slash
command, a JSON-shaped prompt and a system notification. A token shape is masked
before anything is written. Every command exits 0: a launcher never fails a turn.
"""
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
import time

SESSION_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}")
STATES = ("open", "running", "waiting", "done")
ITEM = re.compile(r"^(\d+)\. (open|running|waiting|done) (\S+): (.*)$")
TOKEN = re.compile(r"bbdt_[A-Za-z0-9]{40}")
HEADING = "# Asks in this session (the person's words, whole, spaces folded)"
# The most of one ask that is kept. A pasted document is not an ask; its first part
# says what was asked.
ITEM_MAX = 4000
# The wrappers Claude Code adds around what the person typed: a finished background
# task, the harness talking, and the parts of a slash command. Their text is never
# the person's ask. An unclosed wrapper is cut to the end, so wrapper text never
# leaks even when the close tag is missing.
WRAPPER_TAGS = (
    "task-notification",
    "system-reminder",
    "command-message",
    "command-name",
    "command-args",
    "local-command-stdout",
    "local-command-caveat",
)
NOT_USER_INPUT = "SYSTEM NOTIFICATION - NOT USER INPUT"


def path_for(ledger_dir: str, sid: str) -> str | None:
    if not isinstance(sid, str) or not SESSION_ID.fullmatch(sid):
        return None
    return os.path.join(ledger_dir, sid + ".md")


def strip_wrappers(text: str) -> str:
    for tag in WRAPPER_TAGS:
        text = re.sub(r"<%s(\s[^>]*)?>.*?</%s>" % (tag, tag), "", text, flags=re.S)
        text = re.sub(r"<%s(\s[^>]*)?>.*$" % tag, "", text, flags=re.S)
    return text


def clean(prompt: str) -> str:
    """The person's ask as one line, or the empty string when there is none."""
    if not isinstance(prompt, str):
        return ""
    typed = strip_wrappers(prompt)
    if NOT_USER_INPUT in typed:
        return ""
    one = " ".join(typed.split())
    if not one or one.startswith("/") or one.startswith("[{"):
        return ""
    one = TOKEN.sub("[token]", one)
    if len(one) > ITEM_MAX:
        one = one[:ITEM_MAX].rstrip() + " [cut]"
    return one


def read(path: str) -> list:
    """Every readable item as (number, status, stamp, text); damage is passed over."""
    items = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = ITEM.match(line.rstrip("\n"))
                if m:
                    items.append((int(m.group(1)), m.group(2), m.group(3), m.group(4)))
    except OSError:
        return []
    return items


def write(path: str, items: list) -> None:
    """The whole file, rewritten in place: 0600, and never seen half-written."""
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".ledger.")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(HEADING + "\n\n")
        for n, status, stamp, text in items:
            f.write("%d. %s %s: %s\n" % (n, status, stamp, text))
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def append(ledger_dir: str, hook: dict) -> int | None:
    """Record the hook's prompt as the next item; None when it is skipped."""
    path = path_for(ledger_dir, hook.get("session_id"))
    if path is None:
        return None
    text = clean(hook.get("prompt"))
    if not text:
        return None
    items = read(path)
    n = max([i[0] for i in items] + [0]) + 1
    stamp = time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime())
    items.append((n, "open", stamp, text))
    write(path, items)
    return n


def open_items(ledger_dir: str, sid: str) -> list:
    """Every pending item: open, running or waiting. Only done leaves the list."""
    path = path_for(ledger_dir, sid)
    if path is None:
        return []
    return [i for i in read(path) if i[1] != "done"]


def mark(ledger_dir: str, sid: str, n: int, state: str) -> bool:
    """Move item N to STATE. A done item stays done: a later reply that says 'waiting'
    about it does not reopen it."""
    path = path_for(ledger_dir, sid)
    if path is None or state not in STATES:
        return False
    items = read(path)
    changed = False
    out = []
    for item in items:
        if item[0] == n and item[1] != "done" and item[1] != state:
            item = (item[0], state, item[2], item[3])
            changed = True
        out.append(item)
    if changed:
        write(path, out)
    return changed


def close(ledger_dir: str, sid: str, n: int) -> bool:
    return mark(ledger_dir, sid, n, "done")


# Where a reply says an ask stands, read from the item's line or the line after it:
# a running or waiting word (the first of them) decides, else a done word that no
# negation denies; the contract's own closing words are the fallback when only one ask
# is pending.
STATE_WORDS = (
    ("done", re.compile(r"\b(done|finished|completed?|answered|fixed|resolved|closed)\b", re.I)),
    ("running", re.compile(r"\b(running|working on|in progress|underway|started|looking into)\b", re.I)),
    ("waiting", re.compile(r"\b(waiting|blocked|needs? (?:you|your)|on you|up to you|your call)\b", re.I)),
)
_LEAD = r"^\s*(?:[-*+>]\s*)*(?:\*\*|__)?"
# "Number 3 ...", "Ask 3:", "Q3", and a bare "3." or "3)" or "3:" at the start of a line.
MARK_WORD = re.compile(_LEAD + r"(?:number|no\.?|ask|question|item|q)\s*#?(\d{1,4})(?!\d)", re.I)
MARK_BARE = re.compile(_LEAD + r"#?(\d{1,4})(?!\d)(?:\*\*|__)?\s*[.):](?!\d)(?:\*\*|__)?(?=\s|$)")
CLOSING = re.compile(r"^\s*(?:\*\*|__)?\s*(done\.|still running\b.*|waiting on you\b.*)$", re.I)
CLOSING_STATE = {"done": "done", "still": "running", "waiting": "waiting"}


def line_number(line: str) -> tuple:
    """(item number, the rest of the line after the marker), or (None, '')."""
    for pat in (MARK_WORD, MARK_BARE):
        m = pat.match(line)
        if m:
            return int(m.group(1)), line[m.end():]
    return None, ""


# A done word is only done when nothing in its own clause denies it: "not done yet",
# "I have not fixed it", "never finished". A clause ends at a comma, semicolon, colon,
# full stop, dash or "but".
NEGATION = re.compile(
    r"\b(?:not|never|no|yet to|haven't|hasn't|isn't|wasn't|didn't|can't|couldn't|cannot)\b", re.I)
CLAUSE_END = re.compile(r"[,;:.!?]|\s-+\s|\bbut\b", re.I)


def negated(text: str, at: int) -> bool:
    """True when a negation stands in the same clause before position AT."""
    clause = CLAUSE_END.split(text[:at])[-1]
    return bool(NEGATION.search(clause))


def first_state(text: str) -> str:
    """The state a line states. A running or waiting word wins over a done word on the
    same line (the work is not over while a reply says it still runs); a done word that
    follows a negation is not a state at all."""
    text = text.replace(chr(0x2019), "'")
    best, best_at = "", None
    for state, pat in STATE_WORDS:
        if state == "done":
            continue
        m = pat.search(text)
        if m and (best_at is None or m.start() < best_at):
            best, best_at = state, m.start()
    if best:
        return best
    for m in STATE_WORDS[0][1].finditer(text):
        if not negated(text, m.start()):
            return "done"
    return ""


def states_in(reply: str) -> dict:
    """{item number: state} for every item the reply names with a state."""
    lines = reply.splitlines()
    found: dict = {}
    for i, line in enumerate(lines):
        n, rest = line_number(line)
        if n is None or n in found:
            continue
        state = first_state(rest)
        if not state and i + 1 < len(lines) and line_number(lines[i + 1])[0] is None:
            state = first_state(lines[i + 1])
        if state:
            found[n] = state
    return found


def closing_state(reply: str) -> str:
    for line in reversed(reply.splitlines()):
        m = CLOSING.match(line.strip())
        if m:
            return CLOSING_STATE[m.group(1).split()[0].rstrip(".").lower()]
    return ""


def account(ledger_dir: str, sid: str, reply: str) -> list:
    """Move the pending items the reply names, and return the ones it leaves out as
    (number, text). With one pending ask, the contract's closing line is its state."""
    pending = open_items(ledger_dir, sid)
    if not pending:
        return []
    said = states_in(reply)
    if len(pending) == 1 and pending[0][0] not in said:
        state = closing_state(reply)
        if state:
            said[pending[0][0]] = state
    missing = []
    for n, _status, _stamp, text in pending:
        if n in said:
            mark(ledger_dir, sid, n, said[n])
        else:
            missing.append((n, text))
    return missing


RENDER_HEADING = "## Open asks in this session (answer each under its own number, and say done, running or waiting)"


def render(ledger_dir: str, sid: str, budget: int) -> str:
    """The open items as a block for injection: the heading, then the items oldest
    first, dropping the oldest until the block fits the budget, with one line saying
    how many are not shown. Nothing when not even the newest item fits."""
    items = open_items(ledger_dir, sid)
    if not items:
        return ""
    lines = [("%d. %s" % (n, text)) if status == "open" else ("%d. (%s) %s" % (n, status, text))
             for n, status, _stamp, text in items]
    dropped = 0
    while lines:
        head = [RENDER_HEADING]
        if dropped:
            head.append("(%d earlier %s not shown)" % (dropped, "ask" if dropped == 1 else "asks"))
        block = "\n".join(head + [""] + lines) + "\n"
        if len(block) <= budget:
            return block
        lines.pop(0)
        dropped += 1
    return ""


def main(argv: list) -> int:
    if len(argv) == 3 and argv[0] == "append":
        try:
            with open(argv[2], encoding="utf-8") as f:
                hook = json.load(f)
        except (OSError, ValueError):
            return 0
        if isinstance(hook, dict):
            n = append(argv[1], hook)
            if n is not None:
                print(n)
        return 0
    if len(argv) == 3 and argv[0] == "open":
        for n, _status, stamp, text in open_items(argv[1], argv[2]):
            print("%d. %s: %s" % (n, stamp, text))
        return 0
    if len(argv) in (3, 4) and argv[0] == "render":
        try:
            budget = int(argv[3]) if len(argv) == 4 else 6000
        except ValueError:
            budget = 6000
        sys.stdout.write(render(argv[1], argv[2], budget))
        return 0
    if len(argv) == 5 and argv[0] == "mark":
        try:
            mark(argv[1], argv[2], int(argv[3]), argv[4])
        except ValueError:
            pass
        return 0
    if len(argv) == 4 and argv[0] == "account":
        try:
            with open(argv[3], encoding="utf-8", errors="replace") as f:
                reply = f.read()
        except OSError:
            return 0
        for n, text in account(argv[1], argv[2], reply):
            print("%d. %s" % (n, text))
        return 0
    if len(argv) == 4 and argv[0] == "close":
        try:
            close(argv[1], argv[2], int(argv[3]))
        except ValueError:
            pass
        return 0
    print("usage: ledger.py append|open|render|close|mark|account ...", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:  # noqa: BLE001 - a launcher must exit 0 whatever happens
        print("ledger: %s" % type(exc).__name__, file=sys.stderr)
        sys.exit(0)
