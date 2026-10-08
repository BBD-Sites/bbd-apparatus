# Redaction

A session transcript records real terminal output and real file contents, so a key a
session printed or a credential file it read is in the transcript. Redaction runs on the
machine that holds the transcript, inside the hook, before anything leaves it. Nothing
unredacted is sent to the store, and the store never redacts on a tenant's behalf.

The code is `lib/redact.py`, `lib/render.py` and `lib/postscan.py`, behind `bin/apparatus`.
It is a port of the maintainers' own ingest tooling, unchanged in behaviour: the same
patterns in the same order, the same replacement markers, the same cap and the same final
pass, so a capture made here has the format that tooling's corpus already holds.

## What is redacted

Each match is replaced by a marker that names its class, such as `[REDACTED:github-token]`.
The classes, in the order they run:

1. Private keys: a whole PEM block, then a block whose END marker was cut off.
2. Secret fields of a JSON credential file: `private_key`, `private_key_id`,
   `client_secret`, `client_email`, `refresh_token`, `access_token`, `api_key`, `secret`.
3. Assignments whose name contains `key`, `secret`, `token`, `password` and the like
   (`PASSWORD=...`, `SERVICE_TOKEN_OPERATOR: ...`); the name is kept, the value replaced.
4. Known token shapes: Anthropic and OpenAI keys, GitHub tokens, AWS access keys, Slack
   tokens, HubSpot private-app tokens, any long `eyJ` token (JWTs and encoded JSON state),
   and SSH public keys.
5. `Bearer` tokens.
6. A user and password inside a URL (`https://user:pass@host`).
7. Any whole line of 64 or more base64 characters: a key or signature body with nothing
   around it.

A tool input written as JSON carries its newlines as the two characters backslash-n, so
the token patterns also match right after one.

## How a transcript is rendered

`apparatus render <transcript.jsonl>` prints one session as markdown. User prompts,
assistant text, tool calls and tool results are kept; thinking blocks, side threads and
injected command and skill text are dropped. A tool result is kept whole. A tool input is
redacted first and only then capped at 4000 characters, so a cut can never separate a key
from its END marker. When the document is assembled, the whole of it is redacted once more,
which catches a value that no single piece held entirely.

## Two witnesses, and both fail closed

- **Before: the self-test.** `apparatus selftest` (or `apparatus redact --self-test`) runs
  every class against fake values, checks that none survives, that ordinary prose is left
  alone, and that a very long tool result is kept whole with a secret at its end still
  redacted. If it fails, nothing is rendered or sent; the session is kept to try again.
- **After: the post-scan.** `apparatus postscan <path>...` scans the rendered output for a
  surviving full-shape credential. It exits 1 on any hit and prints only the names of the
  files that hit, never the matching text.

Every new pattern lands with its own self-test case in the same change.

## Quarantine

A file the post-scan flags is moved out of what was scanned: into `--quarantine DIR` when
given, else into `<dir>-quarantine` beside the scanned directory. A quarantined file is
never sent, indexed or searched. A hit counts even if the move fails; the command says the
file is still in place and still exits 1. `--report-only` scans and moves nothing, which is
how the repository's own tests scan its tracked files.

The store runs its own scan again when a transcript arrives, on the already-redacted copy,
and holds a hit out of search until the tenant decides.
