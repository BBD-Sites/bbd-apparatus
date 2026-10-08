"""Secret redaction for session transcripts, the safety core of a capture.

A transcript records real terminal output and real file contents, so anything a
session printed can be in it. Every capture is redacted on the machine that holds
it, before it is truncated and before it is written or sent anywhere.

The patterns are ordered, most specific first, and every pattern has a case in
self_test(). Add a pattern and its case in the same change, never one alone: a
pattern with no case can regress unseen, and a case with no pattern is a leak.

Ported unchanged in behaviour from the maintainers' own ingest tooling: the same
patterns in the same order, the same replacement markers, the same self-test
values. Python 3.9 and the standard library only, because that is what a stock
Mac ships.
"""
from __future__ import annotations

import re

# A private key, whole. Non-greedy, so two keys in one document stay two matches.
PEM_BLOCK = re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----", re.S)
# A private key whose END marker was cut off: everything after BEGIN is the key.
PEM_TRUNC = re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*", re.S)
# Secret-bearing fields of a JSON credential file (a service-account key, an OAuth
# token response), whatever the value looks like.
JSON_SECRET = re.compile(
    r'("(?:private_key|private_key_id|client_secret|client_email|refresh_token|access_token|api_key|secret)"\s*:\s*)"[^"]*"',
    re.I)
# KEY=/SECRET=/TOKEN=/PASSWORD= assignments. The secret word may carry word
# characters before AND after it (SERVICE_TOKEN_OPERATOR): a version that allowed
# only a prefix leaked exactly that shape.
ASSIGNED = re.compile(
    r"(?i)\b([A-Za-z0-9_]*(?:api[_-]?key|secret|token|password|passwd|pwd|access[_-]?key)[A-Za-z0-9_]*)"
    r"(\s*[:=]\s*)(['\"]?)([^\s'\"]{6,})(\3)")
# A tool input is JSON-dumped, so its newlines and tabs arrive as the two characters
# backslash-n / backslash-t, and \b does not fire between that n and a token.
B = r"(?:\b|(?<=\\n)|(?<=\\t))"
SIMPLE = [
    ("anthropic-key", re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}")),
    ("openai-key",    re.compile(B + r"sk-[A-Za-z0-9]{20,}\b")),
    ("github-token",  re.compile(B + r"gh[pousr]_[A-Za-z0-9]{20,}\b")),
    ("aws-access-key", re.compile(B + r"AKIA[0-9A-Z]{16}\b")),
    ("slack-token",   re.compile(B + r"xox[baprs]-[A-Za-z0-9-]{10,}\b")),
    ("hubspot-pat",   re.compile(B + r"pat-[a-z0-9]{2,6}-[0-9a-fA-F]{6,}[0-9a-fA-F-]*")),
    # Any eyJ-prefixed base64 token: three-part JWTs AND one- or two-segment encoded
    # JSON state (a `&t=eyJ...` URL parameter). eyJ is base64 for `{"`, so a long
    # one is a JSON token.
    ("encoded-token", re.compile(B + r"eyJ[A-Za-z0-9_-]{18,}(?:\.[A-Za-z0-9_-]+){0,2}")),
    ("ssh-pubkey",    re.compile(B + r"ssh-(?:rsa|ed25519|dss|ecdsa-[a-z0-9-]+)\s+AAAA[A-Za-z0-9+/]{20,}=*")),
]
BEARER = re.compile(r"(?i)" + B + r"Bearer\s+[A-Za-z0-9._~+/-]{16,}=*")
URL_USERINFO = re.compile(B + r"(https?|ftp|ssh|git)://[^\s:/@]+:[^\s@/]+@")
# A whole line of base64 (64 characters or more): the raw body of a key or a
# signature (openssh, SSHSIG) that no BEGIN/END wraps once it has been cut.
B64_LINE = re.compile(r"^[A-Za-z0-9+/]{64,}={0,2}$")


def redact(text: str) -> str:
    if not text:
        return text
    out = text
    out = PEM_BLOCK.sub("[REDACTED:private-key]", out)
    out = PEM_TRUNC.sub("[REDACTED:private-key-truncated]", out)
    out = JSON_SECRET.sub(lambda m: f'{m.group(1)}"[REDACTED:json-secret]"', out)
    out = ASSIGNED.sub(lambda m: f"{m.group(1)}{m.group(2)}{m.group(3)}[REDACTED:assigned-secret]{m.group(5)}", out)
    for name, rx in SIMPLE:
        out = rx.sub(f"[REDACTED:{name}]", out)
    out = BEARER.sub("Bearer [REDACTED:bearer]", out)
    out = URL_USERINFO.sub(lambda m: m.group(0).split("//", 1)[0] + "//[REDACTED:url-userinfo]@", out)
    out = "\n".join("[REDACTED:base64-blob]" if B64_LINE.match(ln) else ln for ln in out.split("\n"))
    return out


def self_test() -> int:
    """Prove the redactor masks each class, including the shapes that leaked an
    earlier version. Returns 0 on a pass, 1 on any failure; the caller fails closed.

    The values below are fake and are the ones the original tests used, byte for
    byte. Only the text around them was made neutral for a public repository."""
    # Imported here because render imports this module; a top-level import would
    # be circular.
    from render import _text_of

    cases = {
        "anthropic-key":  "ANTHROPIC_API_KEY=sk-ant-api03-AbCdEf0123456789AbCdEf0123",
        "openai-key":     "key is sk-AbCdEf0123456789AbCdEf01 done",
        "github-token":   "token ghp_AbCdEf0123456789AbCdEf0123456789abcd",
        "aws-access-key": "AKIAIOSFODNN7EXAMPLE in config",
        "slack-token":    "xoxb-1234567890-AbCdEfGhIjKl",
        "jwt":            "auth eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NSJ9.AbCdEf-Ghij",
        "bearer":         "Authorization: Bearer abcdef0123456789ABCDEF0123",
        "url-userinfo":   "clone https://user:s3cr3tpass@localhost/x/y.git",
        "pem":            "-----BEGIN RSA PRIVATE KEY-----\nMIIabcdEFkeyBODY\n-----END RSA PRIVATE KEY-----",
        "assigned":       "PASSWORD=hunter2hunter2",
        # --- shapes that leaked the first version of the redactor: ---
        # The value is split in two adjacent literals, which Python joins when it
        # compiles, so the bytes tested are unchanged; whole, it is close enough to a
        # real HubSpot key that a host's push protection refuses the commit.
        "hubspot-suffix": "HUBSPOT_TOKEN_OPERATOR=pat-na1-" "00000000-0000-4000-8000-000000000000",
        "json-pkid":      '"private_key_id": "8a1b2c3d4e5f6071829304a5b6c7d8e9f0a1b2c3"',
        "json-pk-pem":    '"private_key": "-----BEGIN PRIVATE KEY-----\\nMIIsaJSONbody\\n-----END PRIVATE KEY-----\\n"',
        "ssh-pubkey":     "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIQRSTUVWXYZ0123456789abcdefgh user@host",
        "ssh-body-line":  "U1NIU0lHAAAAAQAAADMAAAALc3NoLWVkMjU1MTkAAAAgsskLZMfRa4aRKbGSQCV8ZdiBmJABCDEFGH",
        "pem-truncated":  "-----BEGIN RSA PRIVATE KEY-----\nMIIstillSensitiveTruncatedBodyNoEndMarker",
        "eyj-url-token":  "GET /reports/weekly/1001?week=2026-05-10&t=eyJvd25lcnMiOlsxMjNdLCJzY2FsZSI6dHJ1ZX0",
        "pat-prefix":     "the app whose token starts with pat-na1-87b6c3d2",
        # --- shapes a JSON-dumped tool input carries (literal backslash-n before the token): ---
        "pubkey-after-json-newline": "host.local\\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJSONnewlineKEYbody0123456789 user@host",
        "ghp-after-json-newline":    "echo\\nghp_JsonNewline0123456789AbCdEf0123456789",
    }
    secrets = [
        "sk-ant-api03-AbCdEf0123456789AbCdEf0123", "sk-AbCdEf0123456789AbCdEf01",
        "ghp_AbCdEf0123456789AbCdEf0123456789abcd", "AKIAIOSFODNN7EXAMPLE",
        "xoxb-1234567890-AbCdEfGhIjKl", "s3cr3tpass", "MIIabcdEFkeyBODY", "hunter2hunter2",
        "pat-na1-" "00000000-0000-4000-8000-000000000000", "8a1b2c3d4e5f6071829304a5b6c7d8e9f0a1b2c3",
        "MIIsaJSONbody", "AAAAC3NzaC1lZDI1NTE5AAAAIQRSTUVWXYZ0123456789abcdefgh",
        "U1NIU0lHAAAAAQAAADMAAAALc3NoLWVkMjU1MTkAAAAgsskLZMfRa4aRKbGSQCV8ZdiBmJABCDEFGH",
        "MIIstillSensitiveTruncatedBodyNoEndMarker",
        "eyJvd25lcnMiOlsxMjNdLCJzY2FsZSI6dHJ1ZX0", "pat-na1-87b6c3d2",
        "AAAAC3NzaC1lZDI1NTE5AAAAIJSONnewlineKEYbody0123456789", "ghp_JsonNewline0123456789AbCdEf0123456789",
    ]
    failures = []
    for name, raw in cases.items():
        if "[REDACTED" not in redact(raw):
            failures.append(f"{name}: nothing redacted -> {redact(raw)!r}")
    blob = redact("\n".join(cases.values()))
    for s in secrets:
        if s in blob:
            failures.append(f"LEAK: secret {s[:14]}\u2026 survived redaction")
    for benign in ("We rebased the branch and the build is green; see issue 12.",
                   "The token economics of retrieval favor compile-once-query-cheap.",
                   "git_branch: feature-12-ingest-sessions"):
        if redact(benign) != benign:
            failures.append(f"false-positive: benign altered -> {redact(benign)!r}")
    # A tool result is kept whole (only tool inputs are capped), and a secret at its
    # very end is still redacted.
    long_result = [{"type": "tool_result", "content": "line\n" * 5000 + "PASSWORD=hunter2hunter2"}]
    rendered = _text_of(long_result)[0]
    if "hunter2hunter2" in rendered or rendered.count("line\n") != 5000:
        failures.append("long tool result was truncated or not redacted")
    if failures:
        print("SELF-TEST FAILED:")
        for f in failures:
            print("  -", f)
        return 1
    print(f"SELF-TEST PASSED: {len(cases)} secret classes masked, no leaks, benign intact.")
    return 0
