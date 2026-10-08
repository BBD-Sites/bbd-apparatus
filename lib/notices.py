#!/usr/bin/env python3
"""The keep-current notices and the record of what was said (docs/launcher-contract.md
section 12).

  notices.py running-version <input-file>
      The Claude Code version the session runs, read from the transcript the hook
      input names (its lines carry a `version` field), or nothing if the transcript
      has none yet.

  notices.py due --input <input-file> --state <notices.json> --models <models.json>
                 --cli <claude-code.json> --compactions <dir> [--root <project root>]
                 [--running-version <x.y.z>] [--kinds version,model,fresh-session]
      Prints the text of every notice that is due, and records each one as said.
      Nothing is printed when nothing is due.

Three notices, each said once per account home:
  version        a newer Claude Code than the one running; once per newer version
  model          a newer model in the same line as the one in use; once per newer model
  fresh-session  the session has compacted FRESH_COMPACTIONS times, or its context is
                 past FRESH_CONTEXT share of the model's window; once per session

A stop is honoured: `stop` in notices.json names kinds (or "all"), and a marker whose
`notices` is false turns every notice off. No network is used here; the data files
are updated by pull request. Exits 0 always.
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

KINDS = ("version", "model", "fresh-session")
TOKEN = re.compile(r"bbdt_[A-Za-z0-9]{40}")
VERSION = re.compile(r"^\s*v?(\d+\.\d+\.\d+)(?![\w.-])")
SESSION_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}")
DATED = re.compile(r"-\d{8}$")
TEXT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "text", "notices")
TRANSCRIPT_LIMIT = 262144


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


def running_version(input_path: str) -> str:
    """The `version` the transcript's lines carry, or ""."""
    path = hookio.field(hookio.load(input_path), "transcript_path")
    if not path or not os.path.isfile(path):
        return ""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read(TRANSCRIPT_LIMIT)
    except OSError:
        return ""
    for line in text.splitlines():
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
    """notices.json: what was said, and any stop the tenant asked for."""

    def __init__(self, path: str):
        self.path = path
        doc = load_json(path)
        self.said = doc.get("said") if isinstance(doc.get("said"), dict) else {}
        stop = doc.get("stop")
        if isinstance(stop, str):
            stop = [stop]
        self.stop = {s for s in stop if isinstance(s, str)} if isinstance(stop, list) else set()
        self.dirty = False

    def stopped(self, kind: str) -> bool:
        return "all" in self.stop or kind in self.stop

    def mark(self, key: str) -> None:
        self.said[key] = now()
        self.dirty = True

    def save(self) -> None:
        if not self.dirty:
            return
        doc = {"schema": 1, "said": self.said, "stop": sorted(self.stop)}
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
    want = DATED.sub("", model_id or "")
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


def version_notice(rec: Record, running: str, cli: dict) -> str:
    latest = cli.get("latest") if isinstance(cli.get("latest"), str) else ""
    have, want = parse_version(running), parse_version(latest)
    if not have or not want or have >= want:
        return ""
    key = "version:" + latest
    if key in rec.said:
        return ""
    text = template("version", latest=latest, running=running)
    if text:
        rec.mark(key)
    return text


def model_notice(rec: Record, model_id: str, models: list) -> str:
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


def fresh_notice(rec: Record, doc: dict, sid: str, models: list, compactions_dir: str) -> str:
    if not sid:
        return ""
    key = "fresh-session:" + sid
    if key in rec.said:
        return ""
    reason = ""
    count = compaction_count(compactions_dir, sid)
    if count >= FRESH_COMPACTIONS:
        reason = "has been compacted %d times" % count
    else:
        tokens = doc.get("context_tokens")
        # An integer in the hook JSON; a string of digits is read the same way.
        if isinstance(tokens, str) and tokens.isdigit():
            tokens = int(tokens)
        current = find_model(models, hookio.field(doc, "model"))
        window = current.get("context_window") if current else None
        if (isinstance(tokens, int) and not isinstance(tokens, bool) and tokens > 0
                and isinstance(window, int) and window > 0 and tokens / window >= FRESH_CONTEXT):
            reason = "is past %d percent of its context" % int(100 * tokens / window)
    if not reason:
        return ""
    text = template("fresh-session", reason=reason)
    if text:
        rec.mark(key)
    return text


def due(opts: dict) -> str:
    doc = hookio.load(opts["input"])
    if not marker_allows(opts.get("root", "")):
        return ""
    rec = Record(opts["state"])
    models = load_json(opts["models"]).get("models")
    models = models if isinstance(models, list) else []
    kinds = [k for k in opts["kinds"] if k in KINDS and not rec.stopped(k)]
    sid = hookio.field(doc, "session_id")
    if not SESSION_ID.fullmatch(sid):
        sid = ""
    parts = []
    if "version" in kinds:
        parts.append(version_notice(rec, opts.get("running", ""), load_json(opts["cli"])))
    if "model" in kinds:
        parts.append(model_notice(rec, hookio.field(doc, "model"), models))
    if "fresh-session" in kinds:
        parts.append(fresh_notice(rec, doc, sid, models, opts["compactions"]))
    rec.save()
    return TOKEN.sub("[token]", "\n\n".join(p for p in parts if p))


def parse(argv: list) -> dict | None:
    opts = {"input": "", "state": "", "models": "", "cli": "", "compactions": "", "root": "",
            "running": "", "kinds": list(KINDS)}
    names = {"--input": "input", "--state": "state", "--models": "models", "--cli": "cli",
             "--compactions": "compactions", "--root": "root", "--running-version": "running"}
    i = 0
    while i + 1 < len(argv):
        a, v = argv[i], argv[i + 1]
        if a in names:
            opts[names[a]] = v
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
    if argv and argv[0] == "due":
        opts = parse(argv[1:])
        if opts is None:
            print("usage: notices.py due --input F --state F --models F --cli F --compactions DIR"
                  " [--root DIR] [--running-version V] [--kinds a,b]", file=sys.stderr)
            return 0
        text = due(opts)
        if text:
            print(text)
        return 0
    print("usage: notices.py running-version INPUT | due ...", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:  # noqa: BLE001 - a launcher must exit 0 whatever happens
        print("notices: %s" % type(exc).__name__, file=sys.stderr)
        sys.exit(0)
