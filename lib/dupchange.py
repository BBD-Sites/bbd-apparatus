#!/usr/bin/env python3
"""The duplicate-change guard: before a file of a NEW OpenSpec change is written, look for
an open change (or a document) that already covers the same ground, and refuse once,
naming it (the tenant-repo requirement "An existing change is found before a new one is
made", and continuous-flow "An existing change is extended, never duplicated").

  dupchange.py check --input <hook-input-file> --root <project-root> --state <dir>

Reads a PreToolUse hook input. When the tool is writing a file under
openspec/changes/<name>/ and that folder does not exist yet, the change is new. It is a
duplicate when, among the open changes (every folder under openspec/changes except
archive) and the documents under docs/:

  * the names say the same thing: equal, or one name's words all appear in the other
    (two words or more), or at least 60 percent of their words are shared; or
  * for a change, the words in the text being written (when the tool carries it) are
    nearly the words of the open change's proposal: 80 percent of the new text's
    leading key words (eight or more of them) appear there, or 50 percent when the new
    name also shares a word with the open change's name.

Words are lowercased, short and everyday ones dropped, and a plural folded to its
singular. Prints one PreToolUse deny decision naming the open change, or nothing. It
refuses ONCE per new name per session (state/<session id>), so a model that has looked
at the open change and still means to start a separate one is let through on its second
try; it never edits anything and never refuses a write to a change that already exists.
Anything unexpected (an unreadable folder, a hook input in a shape this does not know)
prints nothing: a write is never blocked by a fault in this check. Exits 0 always.
"""
from __future__ import annotations

import json
import os
import re
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import hookio  # noqa: E402

CHANGES = os.path.join("openspec", "changes")
SESSION_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}")
CHANGE_PATH = re.compile(r"^openspec/changes/([A-Za-z0-9][A-Za-z0-9._-]*)/.+$")
WORD = re.compile(r"[a-z][a-z0-9]{2,}")
# Words that every change name or proposal carries and that say nothing about which
# piece of work it is.
STOP = frozenset("""
the and for with from into onto over under that this these those then than when where which
who whom what why how not nor but are was were been being has have had having does did done
can could would should will may might must shall its our their your you they them his her
add adds adding new old update updates fix fixes change changes make makes use uses using
support supports allow allows need needs want wants get gets set sets run runs also each
every any all some more most less least very just only about after before between through
per via one two three first second last next same other another such own too both either
neither here there now yet still already again once why change spec specs openspec proposal
design task tasks requirement requirements scenario scenarios
""".split())
NAME_SHARE = 0.6
KEYWORDS = 12
KEYWORDS_MIN = 8
KEYWORD_SHARE = 0.8
KEYWORD_SHARE_WITH_NAME = 0.5
TEXT_LIMIT = 4000
PROPOSAL_LIMIT = 20000
DOCS_LIMIT = 3000


def stem(word: str) -> str:
    if len(word) > 4 and word.endswith("ies"):
        return word[:-3] + "y"
    if len(word) > 3 and word.endswith("s") and not word.endswith("ss"):
        return word[:-1]
    return word


def tokens(text: str) -> list:
    return [stem(w) for w in WORD.findall(text.lower()) if w not in STOP]


def name_words(name: str) -> set:
    return set(tokens(name.replace("-", " ").replace("_", " ").replace(".", " ")))


def names_alike(a: set, b: set) -> bool:
    if not a or not b:
        return False
    small, large = (a, b) if len(a) <= len(b) else (b, a)
    if small == large:
        return True
    if len(small) >= 2 and small <= large:
        return True
    return len(a & b) / len(a | b) >= NAME_SHARE


def keywords(text: str) -> list:
    counts = Counter(t for t in tokens(text) if len(t) >= 4)
    return [w for w, _n in counts.most_common(KEYWORDS)]


def read_head(path: str, limit: int) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read(limit)
    except OSError:
        return ""


def written_text(tool_input: dict) -> str:
    """The text the tool is about to write, when it carries it."""
    for key in ("content", "new_string", "new_source"):
        v = tool_input.get(key)
        if isinstance(v, str):
            return v[:TEXT_LIMIT]
    edits = tool_input.get("edits")
    if isinstance(edits, list):
        return " ".join(e.get("new_string", "") for e in edits if isinstance(e, dict)
                        and isinstance(e.get("new_string"), str))[:TEXT_LIMIT]
    return ""


def new_change(root: str, tool_input: dict) -> str:
    """The name of the change this write would create, or ''."""
    path = tool_input.get("file_path") or tool_input.get("notebook_path")
    if not isinstance(path, str) or not path:
        return ""
    full = os.path.realpath(path if os.path.isabs(path) else os.path.join(root, path))
    real_root = os.path.realpath(root)
    if not full.startswith(real_root + os.sep):
        return ""
    rel = full[len(real_root) + 1:].replace(os.sep, "/")
    m = CHANGE_PATH.match(rel)
    if not m or m.group(1) in ("archive", ".archive"):
        return ""
    name = m.group(1)
    if os.path.isdir(os.path.join(real_root, CHANGES, name)):
        return ""
    return name


def open_changes(root: str) -> list:
    base = os.path.join(root, CHANGES)
    found = []
    for name in sorted(os.listdir(base)):
        if name.startswith(".") or name == "archive":
            continue
        if os.path.isdir(os.path.join(base, name)):
            found.append(name)
    return found


def documents(root: str) -> list:
    base = os.path.join(root, "docs")
    found = []
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for f in sorted(filenames):
            if f.lower().endswith((".md", ".mdx", ".txt")):
                found.append(os.path.relpath(os.path.join(dirpath, f), root).replace(os.sep, "/"))
        if len(found) >= DOCS_LIMIT:
            break
    return found[:DOCS_LIMIT]


def find_match(root: str, name: str, text: str) -> str:
    """The repository-relative path of the open change or document the new one repeats."""
    mine = name_words(name)
    if not mine:
        return ""
    for existing in open_changes(root):
        theirs = name_words(existing)
        if names_alike(mine, theirs):
            return "%s/%s" % (CHANGES.replace(os.sep, "/"), existing)
    new_keys = keywords(text) if text else []
    if len(new_keys) >= KEYWORDS_MIN:
        for existing in open_changes(root):
            proposal = read_head(os.path.join(root, CHANGES, existing, "proposal.md"), PROPOSAL_LIMIT)
            if not proposal:
                continue
            seen = set(tokens(proposal)) | name_words(existing)
            share = sum(1 for k in new_keys if k in seen) / len(new_keys)
            need = KEYWORD_SHARE_WITH_NAME if (mine & name_words(existing)) else KEYWORD_SHARE
            if share >= need:
                return "%s/%s" % (CHANGES.replace(os.sep, "/"), existing)
    for doc in documents(root):
        stem_name = os.path.splitext(os.path.basename(doc))[0]
        if names_alike(mine, name_words(stem_name)):
            return doc
    return ""


def already_refused(state: str, sid: str, name: str) -> bool:
    """True when this name was refused in this session before; records it when not."""
    if not SESSION_ID.fullmatch(sid or ""):
        return True  # no usable session to remember the refusal in: let it through, so it cannot repeat
    path = os.path.join(state, sid)
    try:
        with open(path, encoding="utf-8") as f:
            if name in {line.strip() for line in f}:
                return True
    except OSError:
        pass
    try:
        os.makedirs(state, mode=0o700, exist_ok=True)
        with open(path, "a", encoding="utf-8") as f:
            f.write(name + "\n")
        os.chmod(path, 0o600)
    except OSError:
        return True  # cannot record the refusal, so cannot keep it to once: let it through
    return False


def decision(reason: str) -> str:
    return json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason}})


def check(input_path: str, root: str, state: str) -> str:
    hook = hookio.load(input_path)
    tool_input = hook.get("tool_input")
    if not isinstance(tool_input, dict) or not root:
        return ""
    name = new_change(root, tool_input)
    if not name:
        return ""
    match = find_match(root, name, written_text(tool_input))
    if not match:
        return ""
    if already_refused(state, hookio.field(hook, "session_id"), name):
        return ""
    return decision(
        "A change that covers this is already open: %s. Add to it instead of starting a second one "
        "called %s, and tell the person you did. If this is really separate work, say in one "
        "sentence what makes it different and write the file again; this check only asks once." % (match, name))


def main(argv: list) -> int:
    if argv and argv[0] == "check":
        opts = {}
        rest = argv[1:]
        while len(rest) >= 2:
            opts[rest[0]] = rest[1]
            rest = rest[2:]
        if rest or not {"--input", "--root", "--state"} <= set(opts):
            print("usage: dupchange.py check --input F --root DIR --state DIR", file=sys.stderr)
            return 0
        out = check(opts["--input"], opts["--root"], opts["--state"])
        if out:
            print(out)
        return 0
    print("usage: dupchange.py check --input F --root DIR --state DIR", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:  # noqa: BLE001 - fail open: a fault here never blocks a write
        print("dupchange: %s" % type(exc).__name__, file=sys.stderr)
        sys.exit(0)
