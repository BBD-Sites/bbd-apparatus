#!/usr/bin/env python3
"""The keep-current notices and the record of what was said (docs/launcher-contract.md
section 12).

  notices.py running-version <input-file>
      The Claude Code version the session runs, read from the LAST `version` field in
      the tail of the transcript the hook input names, or nothing if there is none.

  notices.py due --input <input-file> --state <notices.json> --models <models.json>
                 --cli <claude-code.json> --compactions <dir> [--root <project root>]
                 [--running-version <x.y.z>]... [--delivery plugin|repo]
                 [--kinds version,model,fresh-session,ship]
      Prints the text of every notice that is due, and records each one as said.
      Nothing is printed when nothing is due. --running-version may be given more
      than once (the transcript's and the CLI's); the newest wins.

  notices.py stop <notices.json> <kind|all>
      Records that the person does not want that kind of notice again. An unknown
      kind is refused: exit 0, a line on stderr, nothing written.

Four notices, each said once per account home:
  version        a newer Claude Code than the one running; once per newer version
  model          a newer model in the same line as the one in use; once per newer model
  fresh-session  the session has compacted FRESH_COMPACTIONS times, or its context is
                 past FRESH_CONTEXT share of the model's window; once per session and
                 step, so it is said again when the count rises to the next multiple
                 or the share enters the next FRESH_BAND
  ship           a notice the ship step left under `pending` (lib/ship.py): a refused
                 key, a held-back or lost session; once per key

A stop is honoured for the first three: `stop` in notices.json names kinds (or "all"),
and a marker whose `notices` is false turns every notice off. A ship notice reports
a loss, not a suggestion, so a stop does not cover it; only the marker does. No
network is used here; the data files are updated by pull request. Exits 0 always.
"""
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from string import Template

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import hookio  # noqa: E402

# The defaults for the fresh-session advice (design D36): change the number on the
# line, nothing else reads them.
FRESH_COMPACTIONS = 3
FRESH_CONTEXT = 0.60
# The advice is repeated only when the count rises: at every multiple of
# FRESH_COMPACTIONS, and at every FRESH_BAND of the window past FRESH_CONTEXT.
FRESH_BAND = 0.20

KINDS = ("version", "model", "fresh-session", "ship")
STOPPABLE = ("version", "model", "fresh-session")
TOKEN = re.compile(r"bbdt_[A-Za-z0-9]{40}")
VERSION = re.compile(r"^\s*v?(\d+\.\d+\.\d+)(?![\w.-])")
SESSION_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}")
# A dated snapshot (claude-x-20250929) and a long-context form (claude-x[1m]) name the
# same model as the bare id; both suffixes are dropped before the lineup is searched.
SUFFIX = re.compile(r"(-\d{8})?(\[[^\]]*\])?$")
TEXT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "text", "notices")
# How much of the transcript's tail is read for the running version. A session that
# was upgraded mid-way carries two builds, the older first, so the LAST field is the
# one that is true now, and the tail is where it is.
TAIL_LIMIT = 262144
PENDING_TEXT_LIMIT = 1000

# The stop, in the delivery the notice came through: the skill the stub registers (the
# plugin's are namespaced by its id; a committed stub's are not), and the Bash call the
# stub pre-approves, for a model that has the texts but not the stub.
STOP_SKILLS = {"plugin": "/bbd:notices-stop-%s", "repo": "/notices-stop-%s"}
STOP_COMMANDS = {
    "plugin": 'bash "${CLAUDE_PLUGIN_ROOT}/launcher/bbd-launch.sh" skill notices-stop-%s',
    "repo": 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/bbd-launch.sh" skill notices-stop-%s repo',
}


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_json(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return {}
    return doc if isinstance(doc, dict) else {}


def parse_version(text: str) -> tuple | None:
    """(major, minor, patch) from the start of TEXT, or None when it is not that shape."""
    m = VERSION.match(text or "")
    if not m:
        return None
    return tuple(int(p) for p in m.group(1).split("."))


def newest(candidates: list) -> str:
    """The newest x.y.z among the candidates, or ""."""
    best, best_t = "", None
    for c in candidates:
        t = parse_version(c or "")
        if t and (best_t is None or t > best_t):
            best, best_t = VERSION.match(c).group(1), t
    return best


def running_version(input_path: str) -> str:
    """The LAST `version` field in the transcript's tail, or ""."""
    path = hookio.field(hookio.load(input_path), "transcript_path")
    if not path or not os.path.isfile(path):
        return ""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(max(0, size - TAIL_LIMIT))
            text = f.read(TAIL_LIMIT).decode("utf-8", errors="replace")
    except OSError:
        return ""
    for line in reversed(text.splitlines()):
        try:
            doc = json.loads(line)
        except ValueError:
            continue
        if isinstance(doc, dict):
            v = doc.get("version")
            if isinstance(v, str) and parse_version(v):
                return VERSION.match(v).group(1)
    return ""


def template(name: str, **fields: str) -> str:
    try:
        with open(os.path.join(TEXT_DIR, name + ".md"), encoding="utf-8") as f:
            text = f.read().strip()
    except OSError:
        return ""
    return Template(text).safe_substitute(fields) if text else ""


class Record:
    """notices.json: what was said, what the ship step left pending, and any stop the
    tenant asked for. Keys this code does not know are kept as they are, so a writer
    on the other side of the file (lib/ship.py) loses nothing when this one saves."""

    def __init__(self, path: str):
        self.path = path
        self.doc = load_json(path)
        said = self.doc.get("said")
        self.said = said if isinstance(said, dict) else {}
        pending = self.doc.get("pending")
        self.pending = pending if isinstance(pending, dict) else {}
        stop = self.doc.get("stop")
        if isinstance(stop, str):
            stop = [stop]
        self.stop = {s for s in stop if isinstance(s, str)} if isinstance(stop, list) else set()
        self.dirty = False

    def stopped(self, kind: str) -> bool:
        return kind in STOPPABLE and ("all" in self.stop or kind in self.stop)

    def mark(self, key: str) -> None:
        self.said[key] = now()
        self.dirty = True

    def add_stop(self, kind: str) -> None:
        if kind not in self.stop:
            self.stop.add(kind)
            self.dirty = True

    def take_pending(self) -> list:
        """Every pending notice, oldest first, each removed from pending as it is taken."""
        items = []
        for key in sorted(self.pending, key=lambda k: str(self.pending[k].get("at", ""))
                          if isinstance(self.pending[k], dict) else ""):
            entry = self.pending[key]
            text = entry.get("text") if isinstance(entry, dict) else entry
            if isinstance(text, str) and text.strip():
                items.append((key, " ".join(text.split())[:PENDING_TEXT_LIMIT]))
        for key, _ in items:
            del self.pending[key]
            self.dirty = True
        return items

    def save(self) -> None:
        if not self.dirty:
            return
        doc = dict(self.doc)
        doc.update({"schema": 1, "said": self.said, "stop": sorted(self.stop), "pending": self.pending})
        d = os.path.dirname(self.path) or "."
        os.makedirs(d, mode=0o700, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".notices.", dir=d)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(doc, f, indent=1, sort_keys=True)
                f.write("\n")
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.path)
        except OSError:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def marker_allows(root: str) -> bool:
    """False when the repository's marker turns notices off."""
    if not root:
        return True
    doc = load_json(os.path.join(root, ".apparatus", "vault.json"))
    return doc.get("notices") is not False


def find_model(models: list, model_id: str) -> dict | None:
    want = SUFFIX.sub("", (model_id or "").strip(), count=1)
    for m in models:
        if isinstance(m, dict) and isinstance(m.get("id"), str) and m["id"] == want:
            return m
    return None


def newer_in_line(models: list, current: dict) -> dict | None:
    """The newest model in CURRENT's line, if it was released after CURRENT."""
    best = current
    for m in models:
        if not isinstance(m, dict) or m.get("line") != current.get("line"):
            continue
        if isinstance(m.get("released"), str) and m["released"] > str(best.get("released", "")):
            best = m
    return best if best is not current else None


def stop_command(delivery: str, kind: str) -> str:
    return STOP_COMMANDS.get(delivery, STOP_COMMANDS["plugin"]) % kind


def stop_skill(delivery: str, kind: str) -> str:
    return STOP_SKILLS.get(delivery, STOP_SKILLS["plugin"]) % kind


def version_notice(rec: Record, running: str, cli: dict, delivery: str) -> str:
    latest = cli.get("latest") if isinstance(cli.get("latest"), str) else ""
    have, want = parse_version(running), parse_version(latest)
    if not have or not want or have >= want:
        return ""
    key = "version:" + latest
    if key in rec.said:
        return ""
    text = template("version", latest=latest, running=running,
                    stop_skill=stop_skill(delivery, "version"),
                    stop_command=stop_command(delivery, "version"))
    if text:
        rec.mark(key)
    return text


def model_notice(rec: Record, model_id: str, models: list, delivery: str) -> str:
    current = find_model(models, model_id)
    if not current:
        return ""
    newer = newer_in_line(models, current)
    if not newer:
        return ""
    key = "model:" + newer["id"]
    if key in rec.said:
        return ""
    text = template(
        "model",
        newer_name=str(newer.get("name", newer["id"])),
        newer_id=newer["id"],
        newer_released=str(newer.get("released", "")),
        newer_for=str(newer.get("for", "the same work")),
        current_name=str(current.get("name", current["id"])),
        stop_skill=stop_skill(delivery, "model"),
        stop_command=stop_command(delivery, "model"),
    )
    if text:
        rec.mark(key)
    return text


def compaction_count(compactions_dir: str, sid: str) -> int:
    if not compactions_dir or not sid:
        return 0
    try:
        with open(os.path.join(compactions_dir, sid), encoding="utf-8") as f:
            return int(f.read().strip() or "0")
    except (OSError, ValueError):
        return 0


def fresh_notice(rec: Record, doc: dict, sid: str, models: list, compactions_dir: str,
                 delivery: str) -> str:
    """Said once per session and step: the key carries the trigger and the step it
    reached, so the advice comes at compaction 3, 6, 9 and at 60, 80, 100 percent,
    and not at every compaction or resume in between."""
    if not sid:
        return ""
    key = reason = ""
    count = compaction_count(compactions_dir, sid)
    if count >= FRESH_COMPACTIONS:
        key = "fresh-session:%s:compactions:%d" % (sid, count // FRESH_COMPACTIONS)
        if key not in rec.said:
            reason = "has been compacted %d times" % count
    if not reason:
        tokens = doc.get("context_tokens")
        # An integer in the hook JSON; a string of digits is read the same way.
        if isinstance(tokens, str) and tokens.isdigit():
            tokens = int(tokens)
        current = find_model(models, hookio.field(doc, "model"))
        window = current.get("context_window") if current else None
        if (isinstance(tokens, int) and not isinstance(tokens, bool) and tokens > 0
                and isinstance(window, int) and window > 0 and tokens / window >= FRESH_CONTEXT):
            share = tokens / window
            key = "fresh-session:%s:context:%d" % (sid, int((share - FRESH_CONTEXT) / FRESH_BAND))
            if key not in rec.said:
                reason = "is past %d percent of its context" % int(100 * share)
    if not reason:
        return ""
    text = template("fresh-session", reason=reason,
                    stop_skill=stop_skill(delivery, "fresh-session"),
                    stop_command=stop_command(delivery, "fresh-session"))
    if text:
        rec.mark(key)
    return text


def ship_notices(rec: Record) -> str:
    parts = []
    for key, text in rec.take_pending():
        if key in rec.said:
            continue
        filled = template("ship", text=text)
        if filled:
            rec.mark(key)
            parts.append(filled)
    return "\n\n".join(parts)


def due(opts: dict) -> str:
    doc = hookio.load(opts["input"])
    if not marker_allows(opts.get("root", "")):
        return ""
    rec = Record(opts["state"])
    models = load_json(opts["models"]).get("models")
    models = models if isinstance(models, list) else []
    kinds = [k for k in opts["kinds"] if k in KINDS and not rec.stopped(k)]
    delivery = opts.get("delivery") or "plugin"
    sid = hookio.field(doc, "session_id")
    if not SESSION_ID.fullmatch(sid):
        sid = ""
    parts = []
    if "ship" in kinds:
        parts.append(ship_notices(rec))
    if "version" in kinds:
        parts.append(version_notice(rec, newest(opts["running"]), load_json(opts["cli"]), delivery))
    if "model" in kinds:
        parts.append(model_notice(rec, hookio.field(doc, "model"), models, delivery))
    if "fresh-session" in kinds:
        parts.append(fresh_notice(rec, doc, sid, models, opts["compactions"], delivery))
    rec.save()
    return TOKEN.sub("[token]", "\n\n".join(p for p in parts if p))


def stop(state: str, kind: str) -> bool:
    """Record a stop; False (and a line on stderr) for a kind that is not one."""
    if kind != "all" and kind not in STOPPABLE:
        print("notices-stop: unknown kind %r; one of %s or all"
              % (kind, ", ".join(STOPPABLE)), file=sys.stderr)
        return False
    rec = Record(state)
    rec.add_stop(kind)
    rec.save()
    return True


def parse(argv: list) -> dict | None:
    opts = {"input": "", "state": "", "models": "", "cli": "", "compactions": "", "root": "",
            "delivery": "", "running": [], "kinds": list(KINDS)}
    names = {"--input": "input", "--state": "state", "--models": "models", "--cli": "cli",
             "--compactions": "compactions", "--root": "root", "--delivery": "delivery"}
    i = 0
    while i + 1 < len(argv):
        a, v = argv[i], argv[i + 1]
        if a in names:
            opts[names[a]] = v
        elif a == "--running-version":
            opts["running"].append(v)
        elif a == "--kinds":
            opts["kinds"] = [k.strip() for k in v.split(",") if k.strip()]
        else:
            return None
        i += 2
    if i != len(argv) or not (opts["input"] and opts["state"]):
        return None
    return opts


def main(argv: list) -> int:
    if len(argv) == 2 and argv[0] == "running-version":
        v = running_version(argv[1])
        if v:
            print(v)
        return 0
    if len(argv) == 3 and argv[0] == "stop":
        stop(argv[1], argv[2])
        return 0
    if argv and argv[0] == "due":
        opts = parse(argv[1:])
        if opts is None:
            print("usage: notices.py due --input F --state F --models F --cli F --compactions DIR"
                  " [--root DIR] [--running-version V]... [--delivery D] [--kinds a,b]",
                  file=sys.stderr)
            return 0
        text = due(opts)
        if text:
            print(text)
        return 0
    print("usage: notices.py running-version INPUT | stop STATE KIND | due ...", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:  # noqa: BLE001 - a launcher must exit 0 whatever happens
        print("notices: %s" % type(exc).__name__, file=sys.stderr)
        sys.exit(0)
