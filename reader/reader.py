#!/usr/bin/env python3
"""The reader: builds the reader's prompt from reader-prompt.md and the four parts, runs
it as one headless `claude -p` call on the person's own plan, and parses the verdict.

  reader.py read   --draft F --contract F [--rules F] [--asks F] [--kind reply|copy]
                   [--prompt F] [--bound SECONDS] [--model NAME]
          prints one JSON object: status, verdict, findings, count, elapsed, reason
  reader.py prompt --draft F --contract F [--rules F] [--asks F] [--kind K] [--prompt F]
          prints the assembled prompt, for a caller that will hand it to a reader itself
  reader.py parse  <verdict-file>
          prints the parse of a reader's output as the same JSON object
  reader.py words  <draft-file>
          prints the draft's prose word count (fenced code left out)

Status is one of: read (the reader answered in shape), unparseable (it answered out of
shape), empty (it printed nothing), no-claude (no `claude` on PATH), timeout (killed at
the bound), failed (a non-zero exit). The verdict is "fix" only when the status is read,
the first line says fix and at least one finding follows; everything else is "send", so
no failure of the reader's own can ever hold a reply back. The nested session runs with
BBD_NESTED set, in an empty directory, with no tools and no saved session, so the
person's hooks do nothing in it, it reads none of their project, and it is never shipped.
A token shape is masked in everything that goes in and everything that comes out.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROMPT_FILE = os.path.join(HERE, "reader-prompt.md")
TOKEN = re.compile(r"bbdt_[A-Za-z0-9]{40}")
MODEL = "haiku"
BOUND = 60
# A reply with fewer prose words than this is an acknowledgement or a structural
# deliverable, not a draft anyone needs read.
SUBSTANTIVE_WORDS = 50
# The most of each part the reader is given; a rules file is read from its start.
RULES_MAX = 12000
ASKS_MAX = 6000
DRAFT_MAX = 40000
REASON_MAX = 4000
SECTIONS = (
    "RESTATE", "CHAIN", "THE PERSON'S WORDS", "CLAIMS", "ANSWERED",
    "OWNER VOICE", "VALUE", "READING", "CONTRACT",
)
VERDICT_RE = re.compile(r"^\**\s*VERDICT\s*:\s*\**\s*(send|fix)\b", re.I)
COUNT_LINE = re.compile(r"^\d+\s+sentences?\s+or\s+bullets?\b", re.I)
# A quote mark of either kind (straight, or the curly pair a draft may carry, named by
# code point so this file holds none), or the lost-hedge form.
FINDING_START = re.compile("^(?:[\"'%s%s]|hedge lost:)" % (chr(0x201C), chr(0x2018)), re.I)
REASON_HEAD = (
    "A reader read this reply before it reaches the person and found these things. "
    "Fix each one, then send the corrected reply; keep everything else as it was.\n"
)


def read_text(path: str, limit: int) -> str:
    if not path:
        return ""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read(limit + 1)
    except OSError:
        return ""
    if len(text) > limit:
        text = text[:limit].rstrip() + "\n[cut here]"
    return TOKEN.sub("[token]", text).strip()


def prose_words(text: str) -> int:
    text = re.sub(r"```.*?```", " ", text, flags=re.S)
    return sum(1 for w in text.split() if re.search(r"[A-Za-z]", w))


def build_prompt(opts: dict) -> str:
    try:
        with open(opts.get("prompt") or PROMPT_FILE, encoding="utf-8") as f:
            template = f.read()
    except OSError:
        return ""
    kind = "copy the person's customers will read" if opts.get("kind") == "copy" \
        else "a reply to the person"
    parts = {
        "CONTRACT": read_text(opts.get("contract", ""), RULES_MAX) or "(none given)",
        "RULES": read_text(opts.get("rules", ""), RULES_MAX) or "(none)",
        "ASKS": read_text(opts.get("asks", ""), ASKS_MAX) or "(none recorded)",
        "DRAFT": read_text(opts.get("draft", ""), DRAFT_MAX),
        "KIND": kind,
    }
    out = template
    for key, value in parts.items():
        out = out.replace("{{%s}}" % key, value)
    return out


def parse(text: str) -> dict:
    """The reader's answer as verdict and findings; out of shape means send."""
    lines = [l.rstrip() for l in TOKEN.sub("[token]", text).splitlines()]
    lines = [l for l in lines if l.strip() and not l.strip().startswith("```")]
    if not lines:
        return {"status": "empty", "verdict": "send", "findings": [], "count": 0}
    # The person's own hooks run in the nested session too and may wrap the answer
    # (a tag line first, a closing line last), so the verdict is the first line that
    # says VERDICT, wherever it sits, and reading stops at a "---" trailer.
    start = next((i for i, l in enumerate(lines) if VERDICT_RE.match(l.strip())), -1)
    if start < 0:
        return {"status": "unparseable", "verdict": "send", "findings": [], "count": 0}
    said = VERDICT_RE.match(lines[start].strip()).group(1).lower()
    findings = []
    section = ""
    for line in lines[start + 1:]:
        if re.fullmatch(r"-{3,}", line.strip()):
            break
        bare = line.strip().strip("*").strip().rstrip(":")
        if bare.upper() in SECTIONS:
            section = bare.upper()
            continue
        fm = re.match(r"^[-*]\s+(.*)$", line.strip())
        if not fm or not section:
            continue
        body = fm.group(1).strip()
        if body.lower() in ("none", "none.") or COUNT_LINE.match(body):
            continue
        if re.fullmatch(r"hedge lost:\s*none\.?", body, re.I):
            continue
        # A finding opens with the quoted line, or names a lost hedge; anything else
        # under a heading is not in shape and is not a finding.
        if not FINDING_START.match(body):
            continue
        findings.append("%s: %s" % (section, body))
    verdict = "fix" if said == "fix" and findings else "send"
    return {"status": "read", "verdict": verdict, "findings": findings, "count": len(findings)}


def reason(findings: list) -> str:
    body = REASON_HEAD
    for f in findings:
        line = "- %s\n" % f
        if len(body) + len(line) > REASON_MAX:
            body += "- (more findings were cut here)\n"
            break
        body += line
    return body.rstrip()


def run_reader(prompt: str, bound: int, model: str) -> dict:
    exe = shutil.which("claude")
    if not exe:
        return {"status": "no-claude", "output": ""}
    env = dict(os.environ)
    env["BBD_NESTED"] = "1"
    for k in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"):
        env.pop(k, None)
    cmd = [exe, "-p", "--model", model, "--tools", "", "--no-session-persistence",
           "--strict-mcp-config", "--output-format", "text"]
    workdir = tempfile.mkdtemp(prefix="reader.")
    proc = None
    try:
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, cwd=workdir, env=env,
                                start_new_session=True)
        try:
            out, err = proc.communicate(prompt.encode("utf-8"), timeout=bound)
        except subprocess.TimeoutExpired:
            kill_group(proc)
            return {"status": "timeout", "output": ""}
        text = out.decode("utf-8", "replace")
        if proc.returncode != 0:
            tail = err.decode("utf-8", "replace").strip().splitlines()[-1:] or [""]
            return {"status": "failed", "output": "", "exit": proc.returncode,
                    "error": TOKEN.sub("[token]", tail[0])[:200]}
        return {"status": "ok", "output": text}
    except OSError as exc:
        return {"status": "failed", "output": "", "error": type(exc).__name__}
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def kill_group(proc) -> None:
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(proc.pid, sig)
        except OSError:
            pass
        try:
            proc.wait(timeout=1)
            return
        except subprocess.TimeoutExpired:
            continue
    try:
        proc.kill()
    except OSError:
        pass


def read(opts: dict) -> dict:
    start = time.time()
    prompt = build_prompt(opts)
    bound = opts.get("bound", BOUND)
    result: dict
    if not prompt:
        result = {"status": "failed", "verdict": "send", "findings": [], "count": 0,
                  "error": "no prompt template"}
    else:
        ran = run_reader(prompt, bound, opts.get("model", MODEL))
        if ran["status"] == "ok":
            result = parse(ran["output"])
        else:
            result = {"status": ran["status"], "verdict": "send", "findings": [], "count": 0}
            for k in ("exit", "error"):
                if k in ran:
                    result[k] = ran[k]
    result["elapsed"] = round(time.time() - start, 2)
    result["reason"] = reason(result["findings"]) if result["verdict"] == "fix" else ""
    return result


def parse_args(argv: list) -> dict | None:
    opts: dict = {}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--draft", "--contract", "--rules", "--asks", "--kind", "--prompt",
                 "--bound", "--model") and i + 1 < len(argv):
            v = argv[i + 1]
            if a == "--bound":
                try:
                    opts["bound"] = min(600, max(1, int(v)))
                except ValueError:
                    return None
            elif a == "--kind":
                opts["kind"] = "copy" if v == "copy" else "reply"
            else:
                opts[a[2:]] = v
            i += 2
        else:
            return None
    return opts if opts.get("draft") and opts.get("contract") else None


def main(argv: list) -> int:
    if len(argv) == 2 and argv[0] == "parse":
        with open(argv[1], encoding="utf-8", errors="replace") as f:
            out = parse(f.read())
        out["reason"] = reason(out["findings"]) if out["verdict"] == "fix" else ""
        print(json.dumps(out, sort_keys=True))
        return 0
    if len(argv) == 2 and argv[0] == "words":
        print(prose_words(read_text(argv[1], DRAFT_MAX * 4)))
        return 0
    if argv and argv[0] in ("read", "prompt"):
        opts = parse_args(argv[1:])
        if opts is None:
            print("usage: reader.py read|prompt --draft F --contract F [--rules F] [--asks F]"
                  " [--kind reply|copy] [--prompt F] [--bound N] [--model M]", file=sys.stderr)
            return 0
        if argv[0] == "prompt":
            sys.stdout.write(build_prompt(opts))
        else:
            print(json.dumps(read(opts), sort_keys=True))
        return 0
    print("usage: reader.py read|prompt|parse|words ...", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:  # noqa: BLE001 - a launcher must exit 0 whatever happens
        print("reader: %s" % type(exc).__name__, file=sys.stderr)
        # A crash in a read still answers in shape, and the answer is to let the
        # reply through.
        if sys.argv[1:2] == ["read"]:
            print(json.dumps({"status": "failed", "verdict": "send", "findings": [], "count": 0,
                              "elapsed": 0, "reason": "", "error": type(exc).__name__}))
        sys.exit(0)
