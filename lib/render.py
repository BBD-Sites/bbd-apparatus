"""Turn one Claude Code session transcript (JSONL) into redacted markdown.

One JSONL file is one session and becomes one markdown document. Kept: user
prompts, assistant text, tool calls and tool results. A tool result is kept whole
(an email body, a file read, a command's output), because that is what a later
search needs; only a tool input is capped, to bound the body of a large file write.
Dropped: thinking blocks, subagent side threads (isSidechain) and command-line
plumbing (slash-command echoes and injected skill bodies), which are noise to a
reader and repeat text found elsewhere.

Every piece of text is redacted before it is truncated and again, as a whole,
after it is rendered. Ported unchanged in behaviour from the maintainers' own
ingest tooling, so a capture made here is byte for byte the format the existing
corpus already holds.
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path

from redact import redact

SKILL_INJECTION = re.compile(r"^\s*(Base directory for this skill:|<command-message>|<command-name>)")
TOOL_INPUT_CAP = 4000


def _cap(s: str, n: int) -> str:
    """Redact FIRST, then truncate, so a capped tool input can never cut through a
    PEM END marker and leave the key body unmatched (a bug an earlier version had)."""
    s = redact(s)
    return s if len(s) <= n else s[:n] + "…"


def _text_of(content) -> list[str]:
    out = []
    if isinstance(content, str):
        if SKILL_INJECTION.search(content):
            m = re.search(r"<command-name>([^<]+)</command-name>", content)
            if m:
                out.append(f"_(ran {m.group(1).strip()})_")
        else:
            out.append(redact(content.strip()))
        return out
    if not isinstance(content, list):
        return out
    for b in content:
        if not isinstance(b, dict):
            continue
        t = b.get("type")
        if t == "thinking":
            continue
        if t == "text":
            txt = (b.get("text") or "").strip()
            if not txt or SKILL_INJECTION.search(txt):
                continue
            out.append(redact(txt))
        elif t in ("tool_use", "server_tool_use"):
            name = b.get("name", "?")
            out.append(f"`[tool_use: {name}]` " + _cap(json.dumps(b.get("input", {}), ensure_ascii=False), TOOL_INPUT_CAP))
        elif t in ("tool_result", "advisor_tool_result"):
            c = b.get("content")
            if isinstance(c, list):
                c = " ".join(x.get("text", "") for x in c if isinstance(x, dict))
            elif isinstance(c, dict):
                c = c.get("text", json.dumps(c))
            out.append("`[result]` " + redact(str(c or "").strip()))
    return out


def extract_session(path: Path) -> dict | None:
    """Read one transcript; None when it holds no user or assistant turn worth
    keeping (a session that only ran a command, or only a side thread)."""
    meta = {"cwd": None, "gitBranch": None, "first_ts": None, "last_ts": None}
    turns = []
    with path.open(encoding="utf-8", errors="replace") as f:
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            try:
                o = json.loads(ln)
            except json.JSONDecodeError:
                continue
            if o.get("isSidechain"):
                continue
            if meta["cwd"] is None and o.get("cwd"):
                meta["cwd"] = o["cwd"]
            if meta["gitBranch"] is None and o.get("gitBranch"):
                meta["gitBranch"] = o["gitBranch"]
            ts = o.get("timestamp")
            if ts:
                meta["first_ts"] = meta["first_ts"] or ts
                meta["last_ts"] = ts
            if o.get("type") not in ("user", "assistant"):
                continue
            m = o.get("message")
            if not isinstance(m, dict):
                continue
            lines = [x for x in _text_of(m.get("content")) if x]
            if lines:
                turns.append((m.get("role", o.get("type")), lines))
    if not turns:
        return None
    meta["turns"] = turns
    meta["session_id"] = path.stem
    return meta


def render_markdown(meta: dict) -> str:
    cwd = meta.get("cwd") or ""
    repo = os.path.basename(cwd.rstrip("/")) if cwd else "unknown"
    fm = [
        "---", "type: session", f"session_id: {meta['session_id']}", f"repo: {repo}",
        f"cwd: {cwd}", f"git_branch: {meta.get('gitBranch') or ''}",
        f"first_ts: {meta.get('first_ts') or ''}", f"last_ts: {meta.get('last_ts') or ''}",
        f"turns: {len(meta['turns'])}", "redacted: true", "---", "",
        f"# Session {meta['session_id']} ({repo})", "",
    ]
    body = []
    for role, lines in meta["turns"]:
        body.append(f"## {role}")
        body.extend(lines)
        body.append("")
    # A final pass over the whole rendered document, as a second line of defense:
    # a secret split across two blocks, or carried in the front matter (a cwd or a
    # branch name), is matched here even though no single piece held all of it.
    return redact("\n".join(fm + body)) + "\n"
