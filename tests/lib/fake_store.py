#!/usr/bin/env python3
"""A stand-in for the tenant's store, for tests only: an HTTP server on 127.0.0.1 that
records every request it receives and answers with a status the test chooses.

  fake_store.py DIR

It listens on a free port and writes that port to DIR/port once it is ready. Every
request is appended to DIR/requests.jsonl as {method, path, headers, body}, so a test
can assert exactly what the ship step sent. The answer is read from DIR/status on each
request (default 201); DIR/slow, if present, is "PATH-PREFIX SECONDS": a request
whose path starts with the prefix is held that long before its answer, so a test
can make some sessions' posts hang while others are answered at once. DIR/delay,
if present, is a number of seconds to wait before
answering, so a test can look at the process list while a post is in flight. A 3xx
answer carries a Location on this same server, so a test can see whether it is
followed. DIR/hook, if present, is run once (then removed) while a request is held,
so a test can act in the middle of a post. Python 3.9 standard library only, like the code under test.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


def read(path: str, default: str) -> str:
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().strip() or default
    except OSError:
        return default


class Handler(BaseHTTPRequestHandler):
    def _answer(self) -> None:
        size = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(size) if size else b""
        record = {
            "method": self.command,
            "path": self.path,
            "headers": {k: v for k, v in self.headers.items()},
            "body": body.decode("utf-8", "replace"),
        }
        with open(os.path.join(self.server.dir, "requests.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(record) + "\n")
        hook = os.path.join(self.server.dir, "hook")
        if os.path.exists(hook):
            os.replace(hook, hook + ".ran")
            subprocess.run(["bash", hook + ".ran"], check=False)
        delay = float(read(os.path.join(self.server.dir, "delay"), "0"))
        slow = read(os.path.join(self.server.dir, "slow"), "").split()
        if len(slow) == 2 and self.path.startswith(slow[0]):
            delay = max(delay, float(slow[1]))
        if delay:
            time.sleep(delay)
        status = int(read(os.path.join(self.server.dir, "status"), "201"))
        self.send_response(status)
        if 300 <= status < 400:
            self.send_header("Location", "/elsewhere")
        self.send_header("Content-Length", "0")
        self.end_headers()

    do_POST = _answer
    do_GET = _answer

    def log_message(self, *args) -> None:  # the test reads requests.jsonl, not stderr
        return


def main() -> int:
    directory = sys.argv[1]
    server = HTTPServer(("127.0.0.1", 0), Handler)
    server.dir = directory
    tmp = os.path.join(directory, "port.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(str(server.server_address[1]))
    os.replace(tmp, os.path.join(directory, "port"))
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
