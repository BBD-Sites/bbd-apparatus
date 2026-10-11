#!/usr/bin/env python3
"""Saving the buyer's vault for them at the end of a turn, from any surface, so they never
touch git (design D2 and the tenant-repo requirements "The buyer never touches git" and
"Two surfaces writing at once never lose a word").

  vaultsync.py sync <project-root> [--deadline <seconds>] [--settle <state-file>]
      Commit and push what changed under the vault's folders, on the buyer's current
      branch. Prints one line saying how it ended (see STATUS below). Exits 0 always.

  vaultsync.py settle <project-root> <state-file>
      Print, for the next prompt, a note naming the pages that hold two versions, or
      nothing. Pages that no longer hold the marker lines are forgotten.

What it does, in this order, and the reasons it does nothing:

  * Only in the repository the launcher already accepted (the vault marker); the
    marker's own `sync: false` turns it off, and its `folders` list replaces FOLDERS.
  * Only on a branch: a detached head, a merge or rebase in progress, or a page
    already in conflict is left alone.
  * Only when everything the working tree holds is the vault's: the folders in FOLDERS,
    the rules file the marker names, and the two files the launcher keeps in
    .apparatus. One path outside them (a half-built site, a script) and nothing is
    committed, fetched, merged or pushed, because that work is not the apparatus's to
    save.
  * What changed is committed with a plain message, in the buyer's own git identity.
  * The remote branch is fetched first. A remote that is ahead is merged in (a fast
    forward when nothing local was added) so the push lands on current work; a branch
    with changes on both sides is merged, and where both sides changed the same
    lines, BOTH versions are kept on the page between marker lines
    (KEEP_THIS / KEEP_OTHER) and the page is listed for the buyer's next turn to settle
    (`settle`). A page one side deleted and the other changed keeps the changed
    version; a binary file keeps the local one and the other beside it as <name>.other.
  * Then a plain push of the branch. Never a force push, never a rewrite; a push that
    loses a race is fetched, merged and tried again, three times at most.
  * No remote, or one that cannot be reached: the commit stays local and the next turn
    tries again.

STATUS is one of: off, busy, detached, outside, nothing, committed, pushed, merged,
kept-both:<n>, offline, failed.

The tenant's own git config is used (it holds the credentials and the proxy that reach
their remote). Their git hooks are not run, no prompt is allowed, and no background
maintenance is started. bash 3.2 and python3 only; no network but git's own.
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

# The operator's own vault shape, empty, is what a buyer's vault is (vault-layout).
FOLDERS = ("00-inbox", "10-references", "20-ideas", "30-projects", "40-areas",
           "50-resources", "60-archive", "70-library", "attachments", "openspec")
# The two files the launcher itself writes beside the marker, which the buyer's commit
# flow carries (docs/launcher-contract.md section 12).
LAUNCHER_FILES = (".apparatus/notices.json", ".apparatus/standing.md")
KEEP_THIS = "kept from this surface"
KEEP_OTHER = "kept from the other surface"
PUSH_TRIES = 3
FOLDER_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
IDENTITY = {"GIT_AUTHOR_NAME": "apparatus maintainers",
            "GIT_AUTHOR_EMAIL": "apparatus-maintainers@users.noreply.github.com",
            "GIT_COMMITTER_NAME": "apparatus maintainers",
            "GIT_COMMITTER_EMAIL": "apparatus-maintainers@users.noreply.github.com"}
MARK_THIS = re.compile(r"^<{7} " + re.escape(KEEP_THIS) + r"$", re.M)
MARK_OTHER = re.compile(r"^>{7} " + re.escape(KEEP_OTHER) + r"$", re.M)
SCAN_LIMIT = 2 * 1024 * 1024


class Clock:
    """Every git call gets what is left of the whole run's allowance."""

    def __init__(self, seconds: float):
        self.end = time.monotonic() + seconds

    def left(self) -> float:
        return max(1.0, self.end - time.monotonic())

    def spent(self) -> bool:
        return time.monotonic() >= self.end


class Git:
    def __init__(self, root: str, clock: Clock):
        self.root = root
        self.clock = clock
        self.env = dict(os.environ)
        self.env["GIT_TERMINAL_PROMPT"] = "0"
        self.env["LC_ALL"] = "C"
        self.env["LANGUAGE"] = "C"

    def run(self, *args, data: bytes | None = None, env_extra: dict | None = None):
        env = dict(self.env)
        if env_extra:
            env.update(env_extra)
        cmd = ["git", "-C", self.root, "-c", "core.hooksPath=/dev/null", "-c", "gc.auto=0",
               "-c", "maintenance.auto=false", "-c", "core.quotepath=off", *args]
        try:
            return subprocess.run(cmd, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  env=env, timeout=self.clock.left())
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess(cmd, 124, b"", b"timeout")

    def ok(self, *args, **kw) -> bool:
        return self.run(*args, **kw).returncode == 0

    def out(self, *args) -> str:
        r = self.run(*args)
        return r.stdout.decode("utf-8", "replace").strip() if r.returncode == 0 else ""


def marker(root: str) -> dict:
    try:
        with open(os.path.join(root, ".apparatus", "vault.json"), encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return {}
    return doc if isinstance(doc, dict) else {}


def allowed_paths(root: str) -> tuple:
    """(folders, single files) the vault is made of for this repository."""
    doc = marker(root)
    folders = FOLDERS
    custom = doc.get("folders")
    if isinstance(custom, list) and custom and all(isinstance(f, str) and FOLDER_NAME.fullmatch(f) for f in custom):
        folders = tuple(custom)
    files = list(LAUNCHER_FILES)
    rules = doc.get("rules")
    if isinstance(rules, str) and re.fullmatch(r"[A-Za-z0-9._/-]{1,200}", rules) \
            and not rules.startswith("/") and ".." not in rules.split("/"):
        files.append(rules)
    return folders, tuple(files)


def is_allowed(path: str, folders: tuple, files: tuple) -> bool:
    if path in files:
        return True
    parts = path.split("/")
    return len(parts) > 1 and parts[0] in folders and ".." not in parts


def changed_paths(git: Git) -> list | None:
    """Every path the working tree differs in, untracked ones included, or None when
    git could not say. A rename lists both of its paths."""
    r = git.run("status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=all")
    if r.returncode != 0:
        return None
    entries = r.stdout.split(b"\0")
    paths = []
    i = 0
    while i < len(entries):
        e = entries[i]
        i += 1
        if len(e) < 4:
            continue
        xy, path = e[:2].decode("ascii", "replace"), e[3:].decode("utf-8", "replace")
        paths.append((xy, path))
        if xy[0] in "RC" or xy[1] in "RC":
            if i < len(entries) and entries[i]:
                paths.append((xy, entries[i].decode("utf-8", "replace")))
            i += 1
    return paths


def busy(git: Git) -> bool:
    for ref in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"):
        if git.ok("rev-parse", "-q", "--verify", ref):
            return True
    for name in ("rebase-merge", "rebase-apply", "BISECT_LOG"):
        p = git.out("rev-parse", "--git-path", name)
        if p:
            full = p if os.path.isabs(p) else os.path.join(git.root, p)
            if os.path.exists(full):
                return True
    return False


def identity_env(git: Git) -> dict:
    """The buyer's own identity; the maintainers' neutral one only where git has none."""
    if git.out("config", "user.name") and git.out("config", "user.email"):
        return {}
    return dict(IDENTITY)


def message(paths: list) -> str:
    where = sorted({p.split("/")[0] if "/" in p else p for _x, p in paths})
    n = len({p for _x, p in paths})
    shown = ", ".join(where[:3]) + (" and more" if len(where) > 3 else "")
    return "Save your notes: %d %s in %s" % (n, "change" if n == 1 else "changes", shown)


def commit_all(git: Git, paths: list) -> bool:
    names = sorted({p for _x, p in paths})
    # Explicit paths: only what was just checked is added, whatever else appears later.
    r = git.run("add", "-A", "--", *names)
    if r.returncode != 0:
        return False
    if git.ok("diff", "--cached", "--quiet"):
        return True  # nothing to record after all
    r = git.run("commit", "-q", "--no-gpg-sign", "-m", message(paths), env_extra=identity_env(git))
    return r.returncode == 0


def blob(git: Git, sha: str) -> bytes:
    return git.run("cat-file", "blob", sha).stdout


def keep_both(git: Git, path: str) -> str:
    """Resolve one conflicted path so that no word is lost. Returns "marked" for a text
    page now holding both versions, "other" for a binary file, "kept" otherwise."""
    r = git.run("ls-files", "-u", "-z", "--", path)
    stages = {}
    for entry in r.stdout.split(b"\0"):
        if not entry:
            continue
        meta, _tab, _name = entry.partition(b"\t")
        mode, sha, stage = meta.decode("ascii", "replace").split()
        stages[int(stage)] = (mode, sha)
    full = os.path.join(git.root, path)
    ours, theirs, base = stages.get(2), stages.get(3), stages.get(1)
    if ours and theirs:
        a, b = blob(git, ours[1]), blob(git, theirs[1])
        if b"\0" in a or b"\0" in b:
            with open(full, "wb") as f:
                f.write(a)
            with open(full + ".other", "wb") as f:
                f.write(b)
            git.run("add", "--", path, path + ".other")
            return "other"
        old = blob(git, base[1]) if base else b""
        with tempfile.TemporaryDirectory() as tmp:
            paths = []
            for name, content in (("ours", a), ("base", old), ("theirs", b)):
                p = os.path.join(tmp, name)
                with open(p, "wb") as f:
                    f.write(content)
                paths.append(p)
            m = subprocess.run(["git", "merge-file", "-p", "-L", KEEP_THIS, "-L", "before", "-L", KEEP_OTHER, *paths],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=git.clock.left())
        if m.returncode < 0 or m.returncode > 127:
            # merge-file itself failed: keep both whole, one after the other, marked.
            merged = (b"<<<<<<< " + KEEP_THIS.encode() + b"\n" + a.rstrip(b"\n") + b"\n=======\n"
                      + b.rstrip(b"\n") + b"\n>>>>>>> " + KEEP_OTHER.encode() + b"\n")
        else:
            merged = m.stdout
        with open(full, "wb") as f:
            f.write(merged)
        git.run("add", "--", path)
        return "marked" if m.returncode != 0 or MARK_THIS.search(merged.decode("utf-8", "replace")) else "kept"
    survivor = ours or theirs
    if survivor:
        with open(full, "wb") as f:
            f.write(blob(git, survivor[1]))
        git.run("add", "--", path)
    return "kept"


def merge_in(git: Git, remote_ref: str, branch: str) -> tuple:
    """Merge the remote branch into the current one. Returns (ok, [pages that now hold
    two versions])."""
    msg = "Bring in the other surface's changes to %s" % branch
    r = git.run("merge", "--no-edit", "--no-ff", "-m", msg, remote_ref, env_extra=identity_env(git))
    if r.returncode == 0:
        return True, []
    unmerged = [p for p in git.run("diff", "--name-only", "--diff-filter=U", "-z").stdout.split(b"\0") if p]
    if not unmerged:
        git.run("merge", "--abort")
        return False, []
    pages = []
    for raw in unmerged:
        path = raw.decode("utf-8", "replace")
        if keep_both(git, path) == "marked":
            pages.append(path)
    msg = "Bring in the other surface's changes to %s; %d %s hold two versions" % (
        branch, len(pages), "page" if len(pages) == 1 else "pages")
    r = git.run("commit", "-q", "--no-gpg-sign", "-m", msg, env_extra=identity_env(git))
    if r.returncode != 0:
        git.run("merge", "--abort")
        return False, []
    return True, pages


def changed_between(git: Git, old: str, new: str) -> list:
    r = git.run("diff", "--name-only", "-z", "%s..%s" % (old, new))
    return [p.decode("utf-8", "replace") for p in r.stdout.split(b"\0") if p]


def holds_two_versions(root: str, path: str) -> bool:
    full = os.path.join(root, path)
    try:
        if os.path.getsize(full) > SCAN_LIMIT:
            return False
        with open(full, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return False
    return bool(MARK_THIS.search(text) and MARK_OTHER.search(text))


def load_settle(state: str) -> list:
    try:
        with open(state, encoding="utf-8") as f:
            return [line.rstrip("\n") for line in f if line.strip()]
    except OSError:
        return []


def save_settle(state: str, pages: list) -> None:
    if not state:
        return
    if not pages:
        try:
            os.unlink(state)
        except OSError:
            pass
        return
    d = os.path.dirname(state) or "."
    os.makedirs(d, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".settle.", dir=d)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("\n".join(sorted(set(pages))) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, state)


def remember(git: Git, state: str, old: str, new: str, extra: list) -> None:
    """Pages that came in holding two versions (from this merge, or from the other
    surface's own), added to the list the next prompt reads."""
    folders, files = allowed_paths(git.root)
    pages = list(load_settle(state))
    pages.extend(extra)
    if old and new and old != new:
        pages.extend(p for p in changed_between(git, old, new) if is_allowed(p, folders, files)
                     and holds_two_versions(git.root, p))
    save_settle(state, [p for p in pages if holds_two_versions(git.root, p)])


def push(git: Git, branch: str) -> bool:
    return git.run("push", "-q", "origin", "HEAD:refs/heads/" + branch).returncode == 0


def sync(root: str, seconds: float, state: str = "") -> str:
    clock = Clock(seconds)
    git = Git(root, clock)
    doc = marker(root)
    if doc.get("sync") is False:
        return "off"
    branch = git.out("symbolic-ref", "-q", "--short", "HEAD")
    if not branch:
        return "detached"
    if busy(git):
        return "busy"
    paths = changed_paths(git)
    if paths is None:
        return "failed"
    if any("U" in xy or xy in ("AA", "DD") for xy, _p in paths):
        return "busy"
    folders, files = allowed_paths(root)
    if any(not is_allowed(p, folders, files) for _xy, p in paths):
        return "outside"
    status = "nothing"
    if paths:
        if not commit_all(git, paths):
            return "failed"
        status = "committed"
    if not git.ok("remote", "get-url", "origin"):
        return status
    remote_ref = "refs/remotes/origin/" + branch
    kept = []
    for _try in range(PUSH_TRIES):
        if clock.spent():
            return "offline"
        fetched = git.run("fetch", "-q", "--no-tags", "origin", "+refs/heads/%s:%s" % (branch, remote_ref))
        if fetched.returncode != 0:
            # The branch is not on the remote yet, or the remote cannot be reached:
            # ls-remote tells them apart (exit 2 is "no such branch").
            lr = git.run("ls-remote", "--exit-code", "--heads", "origin", branch)
            if lr.returncode != 2:
                return "offline"
            remote = ""
        else:
            remote = git.out("rev-parse", "-q", "--verify", remote_ref + "^{commit}")
        head = git.out("rev-parse", "HEAD")
        if remote and remote != head:
            if git.ok("merge-base", "--is-ancestor", remote, "HEAD"):
                pass  # only ahead
            elif git.ok("merge-base", "--is-ancestor", "HEAD", remote):
                if not git.ok("merge", "-q", "--ff-only", remote_ref):
                    return "failed"
                remember(git, state, head, git.out("rev-parse", "HEAD"), [])
                return "merged"
            else:
                ok, pages = merge_in(git, remote_ref, branch)
                if not ok:
                    return "failed"
                kept.extend(pages)
                remember(git, state, head, git.out("rev-parse", "HEAD"), pages)
                status = "merged"
        if remote == git.out("rev-parse", "HEAD"):
            return "kept-both:%d" % len(kept) if kept else status
        if push(git, branch):
            if kept:
                return "kept-both:%d" % len(kept)
            return "pushed"
        # The push was refused (another surface landed first) or could not run; fetch and try again.
    return "failed"


def settle_note(root: str, state: str, template: str) -> str:
    pages = [p for p in load_settle(state) if holds_two_versions(root, p)]
    save_settle(state, pages)
    if not pages:
        return ""
    try:
        with open(template, encoding="utf-8") as f:
            text = f.read().strip()
    except OSError:
        return ""
    listed = "\n".join("- " + p for p in pages[:20])
    return text.replace("$pages", listed)


def state_name(root: str) -> str:
    return hashlib.sha256(os.path.realpath(root).encode("utf-8")).hexdigest()[:16] + ".txt"


def main(argv: list) -> int:
    if len(argv) >= 2 and argv[0] == "sync":
        seconds, state, rest = 25.0, "", argv[2:]
        while len(rest) >= 2:
            if rest[0] == "--deadline":
                try:
                    seconds = max(1.0, float(rest[1]))
                except ValueError:
                    pass
            elif rest[0] == "--settle":
                state = rest[1]
            rest = rest[2:]
        print(sync(argv[1], seconds, state))
        return 0
    if len(argv) in (3, 4) and argv[0] == "settle":
        template = argv[3] if len(argv) == 4 else ""
        note = settle_note(argv[1], argv[2], template)
        if note:
            print(note)
        return 0
    if len(argv) == 2 and argv[0] == "state-name":
        print(state_name(argv[1]))
        return 0
    print("usage: vaultsync.py sync ROOT [--deadline S] [--settle FILE] | settle ROOT FILE TEMPLATE"
          " | state-name ROOT", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:  # noqa: BLE001 - a launcher must exit 0 whatever happens
        print("vaultsync: %s" % type(exc).__name__, file=sys.stderr)
        sys.exit(0)
