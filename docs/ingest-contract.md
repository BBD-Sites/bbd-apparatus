# Ingest contract

How the Stop ship step sends one session to the tenant's store, and what each answer
from the store means. The store's ingest endpoint does not exist yet; this page is
the shape it must accept, and `lib/ship.py` already speaks it. Until a store address
is configured, nothing is sent (see "Before the store exists" below).

## The request

```
POST <url>/v1/captures/<session_id>
Authorization: Bearer <token>
Content-Type: text/markdown; charset=utf-8
X-Capture-Where: desktop | remote-control | cloud
X-Capture-Bytes: <length of the body in bytes>
X-Redactor: <sha256, in hex, of the lib/redact.py that redacted the body>

<the body>
```

- `<url>` is `BBD_INGEST_URL` from the account home's `tenant.env`, and `<token>` is
  `BBD_TOKEN` from the same file. Both are written only by the installer.
- `<session_id>` is the session's own id: letters, digits, `_` and `-`, at most 128
  characters. Anything else is never sent.
- The body is the session rendered as markdown by `apparatus render`, redacted
  before any truncation and again over the whole document, and then passed by the
  post-scan. It is the whole session so far, not the latest turn: each turn sends the
  session again, and the store keeps the longest copy.
- `X-Capture-Where` says where the session ran, as recorded when it was queued.
- `X-Redactor` lets the store tell which redactor a copy passed, so a copy made by a
  redactor later found wanting can be found and checked again.

The token travels only in the `Authorization` header. It is read from `tenant.env`
by the python that makes the request; it is never a command argument, never in a
child process's environment, never printed and never logged.

## Transport rules

- The address must be `https`. Plain `http` is accepted only to this machine's own
  loopback (`127.0.0.1`, `localhost`, `::1`), where no network carries the token.
  Any other address sends nothing and records a notice. A loopback request never
  goes through a proxy from the environment, which would carry the token in clear
  text; an `https` request may, because a proxy sees only the encrypted tunnel.
- A redirect is never followed: following one would resend the `Authorization`
  header to wherever it points. A 3xx answer keeps the entry.
- Each request has a 20-second timeout.

## The answers

| Answer | Meaning | The queue entry |
| --- | --- | --- |
| 200 or 201 | Stored. | Dropped. |
| 409 | The store already holds a longer copy of this session. | Dropped. |
| 401 or 403 | The token was refused. | Kept; a notice is recorded once for the home. |
| 413 | The body is too large for one request. | Kept; a notice is recorded once for the session. Upload in parts is a later task. |
| 5xx, a timeout, or no connection | The store cannot take it now. | Kept. |
| Anything else | Not in this contract. | Kept. |

A kept entry counts one more attempt in its pointer record and is tried again on the
next turn.

## Before the store exists

When `tenant.env` holds a token but no `BBD_INGEST_URL`, the store is not connected.
The ship step still runs the redactor self-test, renders and post-scans each session,
so both witnesses are exercised every turn; then it sends nothing, keeps every
pointer, and writes `store-not-connected` to `state/ship-status.json`. A notice is
recorded once, except on the `next` channel, which is the maintainers' own while the
store is being built. Once a later install writes the address, the next turn drains
the queue.

## What the store does on arrival

The store scans every copy again when it arrives, on the already-redacted text, and
holds a hit out of search until the tenant decides. It never redacts on a tenant's
behalf: nothing unredacted is ever sent to it.
