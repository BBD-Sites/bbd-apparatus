# Launcher contract

Every hook entry, in the plugin and in a tenant repository, runs one small bootstrap
script, `bbd-launch.sh`. The bootstrap never changes. It keeps a checkout of this
repository current and hands the event to the scripts in that checkout, which is how a
change here reaches a session that is already running. This page is the contract the
bootstrap and the checkout keep with each other and with Claude Code.

Throughout, `CFG` means `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`: the account home the
session runs under. A machine with several account homes has one `CFG` per home.

## 1. Inputs

Stdin is read once and saved to a file in the state directory, then passed to the
dispatcher. The fields used:

- Every event: `session_id`, `prompt_id`, `transcript_path`, `cwd`, `hook_event_name`.
- SessionStart: `source` (startup, resume, clear, compact, fork) and `model`.
- UserPromptSubmit: `prompt`.
- Stop: `last_assistant_message` and `stop_reason`.

Arguments: the first is the event name, the second is the delivery, `plugin` or `repo`.

Environment:

- `CLAUDE_PROJECT_DIR`: the preferred project root.
- `CLAUDE_CODE_REMOTE`: `true` means a cloud session.
- `CLAUDE_CODE_BRIDGE_SESSION_ID`: set means a Remote Control session.
- `CLAUDE_CONFIG_DIR`: the account home, else `$HOME/.claude`.

Where the session ran: `cloud` if `CLAUDE_CODE_REMOTE` is `true`, else
`remote-control` if the bridge id is set, else `desktop`.

## 2. Project root

The root is `CLAUDE_PROJECT_DIR`, else the JSON `cwd`. The shell's own working
directory is never used: a hook can be fired for one project while the shell sits in
another, and acting on the shell's directory would act on the wrong repository.

The candidate is confirmed with `git -C <dir> rev-parse --is-inside-work-tree` and
resolved with `--show-toplevel`. A worktree counts as a project: its `.git` is a file,
not a directory, so the check asks git rather than looking for `.git/`, and the vault
marker is committed, so every worktree carries it.

A skill is the one exception: its stub runs the bootstrap from the session's own Bash
tool, which starts in the session's project and brings no hook JSON, so with no
`CLAUDE_PROJECT_DIR` its working directory is taken as the project.

If the shell's working directory no longer exists, the bootstrap first moves to
`$HOME`, so that no git or python call fails on a dead directory.

## 3. Order inside the bootstrap

The bootstrap needs only bash 3.2, git and python3. It does not use jq, because a stock
Mac has none.

1. **Root and marker.** Recover the working directory, resolve the root, read the vault
   marker. No root or no valid marker: exit 0 at once, with no network call, no state
   written and no output.
2. **Delivery dedupe.** If the delivery is `repo`, `CLAUDE_CODE_REMOTE` is not `true`,
   and `CFG/bbd-apparatus/tenant.env` exists (only an install that also enabled the
   plugin writes it), exit 0: the plugin copy handles this home. Both copies fire in a
   desktop session, and without this step every turn would inject and ship twice.
3. **Channel.** `BBD_CHANNEL` from `tenant.env`, else `channel` from the marker, else
   `stable`.
4. **Fast-forward.**
   - The checkout lives at `CFG/bbd-apparatus/checkout-<channel>`.
   - A `mkdir` lock serializes runs; a lock older than 60 seconds is stale.
   - A fetch is skipped if the last one finished under 20 seconds ago (a stamp file),
     so the prompt and Stop hooks of one turn fetch once between them.
   - Otherwise:
     `git fetch --depth=1 https://github.com/Personal-Tooling/bbd-apparatus.git <channel>`
     under a 3-second bound. macOS has no `timeout` command, so the bound is a
     background process and a kill.
   - On success, `git reset --hard FETCH_HEAD`. That single step is both the
     fast-forward and the recovery from drift: the checkout always lands on the channel
     head.
   - On a failed or slow fetch, the last checkout runs.
   - With no checkout at all and a failed clone: the Stop ship event appends a pointer
     record to the queue and exits 0; every other event exits 0 silently.
5. **Signed heads (optional).** Required only where `tenant.env` sets
   `BBD_REQUIRE_SIGNED_HEAD=1`; the default is off until the maintainers' signing keys
   exist. When required, `git -c gpg.ssh.allowedSignersFile=<file> verify-commit HEAD`
   must pass, with the `allowed_signers` file beside the plugin's launcher directory or
   at `CFG/bbd-apparatus/allowed_signers`, or the checkout returns to the last
   verified commit (`state/verified-<channel>`); with none, the run behaves as if
   there were no checkout. One push to `stable` runs on every tenant's next turn, so a
   head that no maintainer key signed is not run.
6. **Hand-off.** `exec` the checkout's `launcher/dispatch.sh` with the event, the
   delivery and the saved stdin as a file:
   `dispatch.sh <event> <delivery> <input-file> [skill name]`. The dispatcher removes
   the file when the event is done.

A session that sets `BBD_NESTED` (the reader step starts one for itself) exits 0
before any of this, so its hooks neither recurse nor ship the reader's own session.

## 4. The vault marker

The launcher acts only in a repository that carries `.apparatus/vault.json`, committed
when the tenant's repository is provisioned:

```json
{"schema": 1, "tenant": "<tenant id, not a secret>", "channel": "stable", "rules": "RULES.md"}
```

The file must parse and name a tenant. On a machine with a token, the marker's tenant
must also equal `BBD_TENANT` in `tenant.env`. Otherwise the launcher does nothing:
nothing is captured, committed, pushed or injected. This is what keeps a machine that
also works in other repositories, including a test tenant's, from shipping them.

## 5. Exit codes and output

- Every launcher exits 0 on every path, including a crash: a trap on `ERR` and `EXIT`
  forces 0.
- Exit 2 is never used. A bug therefore cannot turn into a block.
- The one deliberate block is the Stop gate printing
  `{"decision":"block","reason":"..."}` with exit 0, at most once per `prompt_id`.
- Context is injected only through `hookSpecificOutput.additionalContext` on stdout.
  Stdout carries nothing else, because UserPromptSubmit stdout becomes model context.
- Errors go only to `CFG/bbd-apparatus/state/launcher.log`, which is rotated and
  redacted and never holds the token.

## 6. What fail safe means

In every case the turn ends normally and the transcript ships later or is queued.

| Case | Behavior |
| --- | --- |
| Offline | Run the last checkout; the ship step queues; the session shows nothing. |
| Checkout drifted, or cannot fast-forward | Reset hard to the channel head. |
| Fetch slower than 3 seconds | Abandon it for this turn; run the last checkout. |
| No checkout and no network | The ship step queues a pointer; other events do nothing. |
| Redactor self-test fails for this checkout | Nothing leaves the machine; the queue is kept. The session is not affected. |
| Post-scan finds a secret after redaction | Do not ship; move the rendered copy to the local quarantine; record a notice for the next session start. |
| Store refuses the token (401 or 403) | Keep the queue; record a notice once. |

## 7. Timeouts

Set in the hook entries, which never change, so they are chosen generously (seconds):

| Entry | Timeout |
| --- | --- |
| SessionStart | 20 |
| UserPromptSubmit | 10 |
| PreToolUse | 5 |
| Stop gate | 90 |
| Stop ship | asynchronous in the plugin, with an internal bound of 120 |

## 8. State and queue layout

Everything lives under `CFG/bbd-apparatus/`, mode 0700, one per account home.

```
CFG/bbd-apparatus/
  tenant.env                 0600; the token and settings, written only by the installer
  checkout-<channel>/        the apparatus checkout the launcher runs
  queue/<session_id>.json    a pointer record
  quarantine/                rendered copies the post-scan refused
  state/
    ledger/<session_id>.md   the session's ask ledger
    notices.json             notices already said, and any stop the tenant asked for
    selftest-<sha>.ok        a passed redactor self-test for that checkout
    fetch.stamp              when the last fetch finished
    compactions/<session_id> the session's compaction count
    launcher.log             errors, rotated and redacted
```

A queue record is a pointer, not a copy:
`{session_id, transcript_path, where, first_seen, attempts}`. It holds no transcript
text, so nothing unredacted is duplicated; redaction runs when the queue is drained, and
one record per session always points at the latest transcript.

Every Stop ship drains the queue first, oldest first, at most 5 records per firing. If a
record's transcript is gone when it is drained, that loss is recorded as a notice. A
cloud session's state lives in its machine and is lost when the machine is reclaimed, so
the cloud path does not depend on the queue: it commits the redacted copy to the
repository's `captures` branch instead.

## 9. The token

- Written only by the installer, only into `CFG/bbd-apparatus/tenant.env`, which must be
  outside every git work tree. The installer checks with `git -C <dir> rev-parse` and
  refuses otherwise.
- Read as `KEY=VALUE` text, never with `source`, so the file can never execute.
- Sent only by python, in an `Authorization` header. Never as a command argument (any
  process listing would show it), never on stdout (it would become model context),
  never in a log.
- Shaped as a fixed prefix and a random body, `bbdt_` plus 40 base62 characters, so the
  tests here and a redactor rule can recognize one. `tests/test-token-not-tracked.sh`
  fails if that shape appears in any tracked file.
- The tracked `.mcp.json` in a tenant repository carries the search URL only.
