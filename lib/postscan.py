"""The second witness: scan already-redacted output for a surviving secret shape.

The self-test proves the redactor's patterns before anything is written (the first
witness). Real transcripts still carry shapes a pattern can miss, so after
rendering, the output itself is scanned for full-shape credentials, and any file
with a hit is moved to a quarantine directory: it is never sent, indexed or
searched. The rule fails closed: a hit is reported even if the move fails.

Ported unchanged in behaviour from the maintainers' own ingest tooling, where this
was a `LC_ALL=C grep -lIE "$SECRET_RE"` followed by `mv` into `<out>-quarantine`.
The match runs on raw bytes, as grep does under LC_ALL=C, and a file holding a NUL
byte is treated as binary and skipped, as grep -I does.
"""
from __future__ import annotations

import os
import re
import shutil
from pathlib import Path

# Kept as one string, in grep's extended syntax, so it can be compared with (and
# copied to) a shell caller unchanged. Every alternative is also valid Python.
SECRET_RE = (
    r"sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}"
    r"|xox[baprs]-[A-Za-z0-9-]{10,}|pat-[a-z0-9]{2,6}-[0-9a-fA-F]{6,}|-----BEGIN [A-Z0-9 ]*PRIVATE KEY"
)
_SECRET = re.compile(SECRET_RE.encode("ascii"))


def has_secret(path: str | os.PathLike) -> bool:
    """True if the file holds a secret shape. A binary file (one with a NUL byte)
    is skipped, as grep -I skips it."""
    data = Path(path).read_bytes()
    if b"\x00" in data:
        return False
    return _SECRET.search(data) is not None


def files_under(paths) -> list[Path]:
    """Expand each argument: a file is itself, a directory is every regular file
    beneath it (symlinks not followed), in a stable order."""
    out = []
    for p in paths:
        p = Path(p)
        if p.is_dir():
            for root, dirs, names in os.walk(p):
                dirs.sort()
                for n in sorted(names):
                    f = Path(root) / n
                    if f.is_file() and not f.is_symlink():
                        out.append(f)
        else:
            out.append(p)
    return out


def scan(paths, quarantine: str | os.PathLike | None = None,
         unmoved: list | None = None) -> list[Path]:
    """Scan files and directories; return every file with a hit, in scan order.

    With `quarantine`, each hit is moved into that directory under its own base
    name (a later hit of the same name replaces the earlier one, as `mv` does).
    Without it nothing is moved, which is the report-only mode a tracked-file audit
    needs. A hit whose move fails is still returned, and is also appended to
    `unmoved` when given, so the caller can say the file is still in place. A file
    that cannot be read raises, so a caller cannot mistake an unreadable file for a
    clean one."""
    hits = []
    for f in files_under(paths):
        if not has_secret(f):
            continue
        hits.append(f)
        if quarantine is not None:
            qdir = Path(quarantine)
            try:
                qdir.mkdir(parents=True, exist_ok=True)
                shutil.move(str(f), str(qdir / f.name))
            except OSError:
                if unmoved is not None:
                    unmoved.append(f)
    return hits
