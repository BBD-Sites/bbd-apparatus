#!/usr/bin/env python3
"""Shipping a session's transcript: the queue, the two doors out of the machine, and
the said-once notices the ship step leaves for the next session start.
launcher/events/stop-ship.sh holds the order (docs/launcher-contract.md section 10);
each step it takes is one subcommand here, so every step can be tested alone.

  ship.py queue-pointer <queue> <input-file> <where>   print the session id queued
  ship.py drain-list <queue> <current> <max>           the ids to ship this firing
  ship.py post-timeout                                 seconds one post may take
  ship.py get <queue> <sid> <field>                    one field of a pointer
  ship.py stamp <queue> <sid>                          which write of a pointer this is
  ship.py drop <queue> <sid> [<stamp>]
  ship.py lost <queue> <state> <sid> [<stamp>]         the transcript is gone
  ship.py notice <state> <key> <text>                  recorded once per key
  ship.py status <state> <status> <queue>              state/ship-status.json
  ship.py door <tenant.env>                            post | not-connected | captures
  ship.py post <tenant.env> <state> <queue> <sid> <stamp> <file> <redact.py>
  ship.py captures <project> <queue> <state> <sid> <stamp> <file> [...]

A stamp names one write of a pointer (its inode and modification time; every write
is a rename, so each has a new one). An entry is dropped only if its pointer is the
one that was rendered: a later turn of the same session that refreshed it while the
copy was being sent keeps it queued, so that turn is sent too.

A pointer holds no transcript text, so nothing unredacted is ever copied: redaction
runs when the queue is drained. One record per session, replaced in place, always
points at the latest transcript and keeps when it was first seen and how many times
shipping it was tried. The bootstrap writes the same record, with the same rules,
when no checkout exists yet; tests/test-fail-safe.sh holds the two to one shape.

The token is read here from tenant.env and nowhere else in the ship step: it is
never an argument (a process listing would show it), never in the environment of a
child, never printed and never logged. Every command exits 0, because a launcher
must never fail a turn; what happened is in the queue, the status file and the log.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

SESSION_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}")
TOKEN_SHAPE = re.compile(r"bbdt_[A-Za-z0-9]{40}")

# The neutral identity every captures commit carries; a tenant's own name never
# reaches the branch, and the same identity signs this repository's history.
CAPTURE_NAME = "apparatus maintainers"
CAPTURE_EMAIL = "apparatus-maintainers@users.noreply.github.com"
CAPTURES_REF = "refs/heads/captures"
LEASE_RETRIES = 3
GIT_TIMEOUT = 30
POST_TIMEOUT = 20


def now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def log(msg: str) -> None:
    """To stderr, which the dispatcher sends to launcher.log. A token shape is masked
    even though nothing here ever formats the token into a message."""
    print("ship: " + TOKEN_SHAPE.sub("[token]", msg), file=sys.stderr)


def write_json(path: str, doc) -> None:
    # mkstemp makes the file 0600, and the rename means a reader never sees half a file.
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".ship.")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(doc, f, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def read_json(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return {}
    return doc if isinstance(doc, dict) else {}


def valid_sid(sid) -> bool:
    return isinstance(sid, str) and SESSION_ID.fullmatch(sid) is not None


# ---------------------------------------------------------------------------- queue

def queue_pointer(queue: str, hook: dict, where: str) -> str | None:
    """Write or refresh queue/<session_id>.json; returns the session id, or None if the
    hook named no usable session (an id that is not a plain token could name a path)."""
    sid, path = hook.get("session_id"), hook.get("transcript_path")
    if not valid_sid(sid):
        return None
    target = os.path.join(queue, sid + ".json")
    old = read_json(target)
    attempts = old.get("attempts")
    record = {
        "session_id": sid,
        "transcript_path": path if isinstance(path, str) and path else str(old.get("transcript_path") or ""),
        "where": where,
        "first_seen": old.get("first_seen") or now(),
        "attempts": attempts if isinstance(attempts, int) and not isinstance(attempts, bool) else 0,
    }
    write_json(target, record)
    return sid


def drain_list(queue: str, current: str, limit: int) -> list:
    """The queued sessions to try this firing: the firing session first, then the
    `limit` oldest by first seen (then by name, so the order is stable). The firing
    session goes first so that old entries that keep failing, or a store that hangs
    on them, can never use up the step's time before the turn that just ended is
    sent. A cap keeps one firing short after a long time offline; the rest wait for
    the next turn."""
    entries = []
    for name in os.listdir(queue):
        sid = name[:-5] if name.endswith(".json") else ""
        if not valid_sid(sid) or sid == current:
            continue
        first = read_json(os.path.join(queue, name)).get("first_seen")
        entries.append((str(first or ""), sid))
    out = [sid for _, sid in sorted(entries)[:limit]]
    if valid_sid(current) and os.path.isfile(os.path.join(queue, current + ".json")):
        out.insert(0, current)
    return out


def stamp(queue: str, sid: str) -> str:
    try:
        st = os.stat(os.path.join(queue, sid + ".json"))
    except OSError:
        return ""
    return "%d-%d" % (st.st_ino, st.st_mtime_ns)


def drop(queue: str, sid: str, expect: str | None = None) -> bool:
    """Remove a pointer; with `expect`, only if it is still that write of it."""
    if not valid_sid(sid):
        return False
    if expect is not None and stamp(queue, sid) != expect:
        log("%s was refreshed while it was being sent; kept for the next turn" % sid)
        return False
    try:
        os.remove(os.path.join(queue, sid + ".json"))
    except FileNotFoundError:
        pass
    return True


def count_attempt(queue: str, sid: str) -> None:
    path = os.path.join(queue, sid + ".json")
    rec = read_json(path)
    if not rec:
        return
    n = rec.get("attempts")
    rec["attempts"] = (n if isinstance(n, int) and not isinstance(n, bool) else 0) + 1
    write_json(path, rec)


# -------------------------------------------------------------- notices and status

def notice(state: str, key: str, text: str) -> bool:
    """Record a notice for the next session start, once per key: a refused token or a
    full disk would otherwise say the same thing on every turn. Returns whether it
    was new. The session-start step reads `pending` and says each one once."""
    path = os.path.join(state, "notices.json")
    doc = read_json(path)
    pending = doc.get("pending")
    if not isinstance(pending, dict):
        pending = {}
    said = doc.get("said")
    if key in pending or (isinstance(said, dict) and key in said):
        return False
    pending[key] = {"text": text, "at": now()}
    doc["pending"] = pending
    write_json(path, doc)
    return True


def status(state: str, word: str, queue: str) -> None:
    """What the last ship step ended with, for the installer's check and for a person
    reading the state: shipped, kept, store-not-connected or selftest-failed."""
    try:
        queued = len([n for n in os.listdir(queue) if n.endswith(".json")])
    except OSError:
        queued = 0
    write_json(os.path.join(state, "ship-status.json"), {"status": word, "at": now(), "queued": queued})


# ------------------------------------------------------------------- tenant config

def tenant_env(path: str) -> dict:
    """tenant.env as KEY=VALUE text, the same rules as launcher/lib/common.sh: never
    executed, quotes stripped, `export ` allowed, and a file too large to be the
    installer's is not read."""
    out = {}
    try:
        if os.path.getsize(path) > 65536:
            return out
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return out
    for line in lines:
        line = line.rstrip("\r")
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        key = key[len("export "):] if key.startswith("export ") else key
        key = key.replace(" ", "")
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
            val = val[1:-1]
        out[key] = val
    return out


def door(env_path: str) -> str:
    """Which way out: a token means the HTTP post, or, with no ingest URL yet, the
    store is not connected; no token (a cloud machine, or a home with no install)
    means the captures branch."""
    env = tenant_env(env_path)
    if not env.get("BBD_TOKEN"):
        return "captures"
    return "post" if env.get("BBD_INGEST_URL") else "not-connected"


# ----------------------------------------------------------------------- HTTP post

class NoRedirect(urllib.request.HTTPRedirectHandler):
    """A redirect is never followed: urllib would resend the Authorization header to
    wherever it points. The 3xx surfaces as an HTTPError and the entry is kept."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def ingest_url(base: str, sid: str) -> str | None:
    """POST <url>/v1/captures/<sid>, over https; plain http only to this machine's own
    loopback, where no network sees the token."""
    parts = urllib.parse.urlsplit(base)
    if parts.scheme == "https" and parts.hostname:
        pass
    elif parts.scheme == "http" and parts.hostname in ("127.0.0.1", "localhost", "::1"):
        pass
    else:
        return None
    return base.rstrip("/") + "/v1/captures/" + sid


def post(env_path: str, state: str, queue: str, sid: str, expect: str, body_path: str, redactor: str) -> str:
    """Send one rendered, redacted, post-scanned copy (docs/ingest-contract.md) and
    apply the answer to the queue. Returns the outcome word."""
    env = tenant_env(env_path)
    token, base = env.get("BBD_TOKEN", ""), env.get("BBD_INGEST_URL", "")
    rec = read_json(os.path.join(queue, sid + ".json"))
    url = ingest_url(base, sid) if token and base else None
    if not url:
        notice(state, "ingest-url-refused", "The store address in this machine's settings is not https, so nothing was sent. Run the installer again.")
        log("ingest URL is not https; %s kept" % sid)
        return "kept"
    with open(body_path, "rb") as f:
        body = f.read()
    with open(redactor, "rb") as f:
        redactor_sha = hashlib.sha256(f.read()).hexdigest()
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "text/markdown; charset=utf-8")
    req.add_header("X-Capture-Where", str(rec.get("where") or "desktop"))
    req.add_header("X-Capture-Bytes", str(len(body)))
    req.add_header("X-Redactor", redactor_sha)
    handlers = [NoRedirect]
    if urllib.parse.urlsplit(url).scheme == "http":
        # Plain http is allowed only to loopback, so that no network carries the
        # token; a proxy from the environment would carry it in clear text.
        handlers.append(urllib.request.ProxyHandler({}))
    opener = urllib.request.build_opener(*handlers)
    try:
        with opener.open(req, timeout=POST_TIMEOUT) as resp:
            code = resp.status
    except urllib.error.HTTPError as e:
        code = e.code
    except Exception as e:  # noqa: BLE001 - offline, refused, timeout: all mean "later"
        count_attempt(queue, sid)
        # The reason is an OS or socket message (refused, timed out, no route); it
        # never holds the request, and log() masks a token shape regardless.
        reason = getattr(e, "reason", e)
        log("post of %s did not reach the store (%s: %s); kept"
            % (sid, type(e).__name__, str(reason)[:200].replace("\n", " ")))
        return "kept"
    if code in (200, 201):
        drop(queue, sid, expect)
        return "stored"
    if code == 409:
        # The store already holds a longer copy of this session: nothing to add.
        drop(queue, sid, expect)
        return "stored"
    count_attempt(queue, sid)
    if code in (401, 403):
        notice(state, "token-refused", "The store refused this machine's key, so new sessions are kept here and not sent. Run the installer again to renew it.")
    elif code == 413:
        notice(state, "too-large:" + sid, "One session is larger than the store accepts in one piece; it is kept here until large uploads are supported.")
    log("store answered %s for %s; kept" % (code, sid))
    return "kept"


# ------------------------------------------------------------------ captures branch

def git(project: str, *args, data: bytes | None = None, env_extra: dict | None = None):
    """git on the tenant's repository. The tenant's own config IS used here, unlike on
    the apparatus checkout, because it holds the credentials and proxy that reach
    their remote. Hooks are not: their pre-push could be slow or refuse, and this
    push is not their work. A prompt would hang an unattended hook, so none is
    allowed, and no background maintenance is started."""
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"
    # The lease retry reads git's own words, which a translated git would change.
    env["LC_ALL"] = "C"
    env["LANGUAGE"] = "C"
    if env_extra:
        env.update(env_extra)
    cmd = ["git", "-C", project, "-c", "core.hooksPath=/dev/null", "-c", "gc.auto=0",
           "-c", "maintenance.auto=false", *args]
    return subprocess.run(cmd, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          env=env, timeout=GIT_TIMEOUT)


def fetch_captures(project: str):
    """The remote captures head, as (sha, ok). A missing branch is fine (sha empty);
    a remote that cannot be read is not (ok False)."""
    # --refmap= keeps the fetch itself from moving a remote-tracking ref; only
    # FETCH_HEAD and objects are written. A FETCH_HEAD another fetch overwrote in
    # between gives a wrong lease, which the push refuses and retries.
    r = git(project, "fetch", "-q", "--no-tags", "--refmap=", "origin", CAPTURES_REF)
    if r.returncode == 0:
        sha = git(project, "rev-parse", "-q", "--verify", "FETCH_HEAD^{commit}")
        if sha.returncode == 0:
            return sha.stdout.decode().strip(), True
        return "", False
    # The fetch failed: either the branch does not exist yet or the remote is out of
    # reach. ls-remote --exit-code tells them apart (2 means no such ref).
    r = git(project, "ls-remote", "--exit-code", "origin", CAPTURES_REF)
    return "", r.returncode == 2


def ls_tree(project: str, treeish: str) -> list:
    """Entries of one tree level as raw `mode type sha\\tname` bytes, NUL-separated, so
    any name survives the round trip through mktree unchanged."""
    r = git(project, "ls-tree", "-z", treeish)
    if r.returncode != 0:
        return []
    return [e for e in r.stdout.split(b"\0") if e]


def entry_name(entry: bytes) -> bytes:
    return entry.split(b"\t", 1)[1]


def mktree(project: str, entries: list) -> str | None:
    r = git(project, "mktree", "-z", data=b"".join(e + b"\0" for e in entries))
    return r.stdout.decode().strip() if r.returncode == 0 else None


def build_commit(project: str, old: str, blobs: dict) -> str | None:
    """A parentless commit holding the old captures tree with each session's file
    replaced or added. Every other file, including other sessions', is carried over
    as it is, so no session overwrites another's and the branch never grows history."""
    top = ls_tree(project, old) if old else []
    sub = []
    for e in top:
        if entry_name(e) == b"captures" and b" tree " in e.split(b"\t", 1)[0]:
            sub = ls_tree(project, old + ":captures")
    names = {(sid + ".md").encode() for sid in blobs}
    sub = [e for e in sub if entry_name(e) not in names]
    sub += [b"100644 blob %s\t%s.md" % (blob.encode(), sid.encode()) for sid, blob in blobs.items()]
    sub_tree = mktree(project, sub)
    if not sub_tree:
        return None
    top = [e for e in top if entry_name(e) != b"captures"]
    top.append(b"040000 tree %s\tcaptures" % sub_tree.encode())
    tree = mktree(project, top)
    if not tree:
        return None
    ident = {"GIT_AUTHOR_NAME": CAPTURE_NAME, "GIT_AUTHOR_EMAIL": CAPTURE_EMAIL,
             "GIT_COMMITTER_NAME": CAPTURE_NAME, "GIT_COMMITTER_EMAIL": CAPTURE_EMAIL}
    msg = "captures: %s\n" % ", ".join(sorted(blobs))
    r = git(project, "commit-tree", "--no-gpg-sign", tree, data=msg.encode(), env_extra=ident)
    return r.stdout.decode().strip() if r.returncode == 0 else None


def captures(project: str, queue: str, state: str, items: list) -> str:
    """Commit each (session, rendered file) to the tenant repository's captures branch
    and push it, by plumbing only: objects are written, and the working tree, the
    index and every local branch are left alone.

    The ref must be a branch, because the cloud's git proxy refuses a push of
    anything else. UNVERIFIED: whether that proxy allows a force-with-lease push
    (each commit is parentless, so every push replaces the branch). If it does not,
    the fallback is a normal commit whose parent is the fetched head, which the
    proxy accepts but which grows history until the store prunes the branch."""
    blobs, stamps = {}, {}
    for sid, expect, path in items:
        stamps[sid] = expect
        r = git(project, "hash-object", "-w", "--no-filters", path)
        if r.returncode != 0:
            log("could not store %s in the repository; kept" % sid)
            return "kept"
        blobs[sid] = r.stdout.decode().strip()
    for _ in range(1 + LEASE_RETRIES):
        old, ok = fetch_captures(project)
        if not ok:
            for sid in blobs:
                count_attempt(queue, sid)
            log("the repository's remote could not be read; %d kept" % len(blobs))
            return "kept"
        commit = build_commit(project, old, blobs)
        if not commit:
            log("could not build the captures commit; kept")
            return "kept"
        r = git(project, "push", "-q", "--force-with-lease=%s:%s" % (CAPTURES_REF, old),
                "origin", "%s:%s" % (commit, CAPTURES_REF))
        if r.returncode == 0:
            for sid in blobs:
                drop(queue, sid, stamps[sid])
            return "stored"
        err = r.stderr.decode("utf-8", "replace")
        if "stale info" not in err and "rejected" not in err:
            break
        # Another session pushed after this one fetched: fetch again and rebuild on top.
    for sid in blobs:
        count_attempt(queue, sid)
    log("the captures push was refused or failed; %d kept" % len(blobs))
    return "kept"


# ---------------------------------------------------------------------------- main

def main(argv: list) -> int:
    cmd, args = (argv[0], argv[1:]) if argv else ("", [])
    if cmd == "queue-pointer" and len(args) == 3:
        queue, input_file, where = args
        hook = read_json(input_file)
        if hook:
            sid = queue_pointer(queue, hook, where)
            if sid:
                print(sid)
    elif cmd == "drain-list" and len(args) == 3:
        for sid in drain_list(args[0], args[1], int(args[2])):
            print(sid)
    elif cmd == "post-timeout" and not args:
        print(POST_TIMEOUT)
    elif cmd == "get" and len(args) == 3 and valid_sid(args[1]):
        value = read_json(os.path.join(args[0], args[1] + ".json")).get(args[2])
        if isinstance(value, str):
            print(value.replace("\n", " "))
    elif cmd == "stamp" and len(args) == 2 and valid_sid(args[1]):
        print(stamp(args[0], args[1]))
    elif cmd == "drop" and len(args) in (2, 3):
        drop(args[0], args[1], args[2] if len(args) == 3 else None)
    elif cmd == "lost" and len(args) in (3, 4) and valid_sid(args[2]):
        if drop(args[0], args[2], args[3] if len(args) == 4 else None):
            notice(args[1], "loss:" + args[2], "One earlier session could not be saved: its transcript was gone from this machine before it could be sent.")
    elif cmd == "notice" and len(args) == 3:
        notice(args[0], args[1], args[2])
    elif cmd == "status" and len(args) == 3:
        status(args[0], args[1], args[2])
    elif cmd == "door" and len(args) == 1:
        print(door(args[0]))
    elif cmd == "post" and len(args) == 7 and valid_sid(args[3]):
        print(post(*args))
    elif cmd == "captures" and len(args) >= 6 and len(args) % 3 == 0:
        project, queue, state, rest = args[0], args[1], args[2], args[3:]
        items = [tuple(rest[i:i + 3]) for i in range(0, len(rest), 3) if valid_sid(rest[i])]
        print(captures(project, queue, state, items) if items else "kept")
    else:
        print("ship: unknown or malformed command", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:  # noqa: BLE001 - a launcher must exit 0 whatever happens
        print("ship: %s" % type(exc).__name__, file=sys.stderr)
        sys.exit(0)
