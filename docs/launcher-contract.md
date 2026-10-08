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
   desktop session, and without this step every turn would inject and ship twice. A
   skill is not deduped: it runs once, from the one Bash call that invoked its stub,
   and on a Mac with the plugin the tenant may invoke the committed stub
   (`/read-draft`) as readily as the plugin's (`/bbd:read-draft`); both must answer.
3. **Channel.** `BBD_CHANNEL` from `tenant.env`, else `channel` from the marker, else
   `stable`.
4. **Fast-forward.**
   - The checkout lives at `CFG/bbd-apparatus/checkout-<channel>`.
   - A `mkdir` lock serializes runs; a lock older than 60 seconds is stale.
   - A fetch is skipped if the last one finished under 20 seconds ago (a stamp file),
     so the prompt and Stop hooks of one turn fetch once between them.
   - Otherwise:
     `git fetch --depth=1 https://github.com/BBD-Sites/bbd-apparatus.git <channel>`
     under a 3-second bound. macOS has no `timeout` command, so the bound is a
     background process and a kill.
   - On success, `git reset --hard FETCH_HEAD`. That single step is both the
     fast-forward and the recovery from drift: the checkout always lands on the channel
     head.
   - On a failed or slow fetch, the last checkout runs.
   - With no checkout at all and a failed clone: the Stop ship event appends a pointer
     record to the queue and exits 0; every other event exits 0 silently.
5. **Signed heads.** There is no setting that turns this off, because the bootstrap
   never changes and an off default would stay off forever. An `allowed_signers` file
   turns it on. The bootstrap looks for one beside the plugin
   (`$CLAUDE_PLUGIN_ROOT/allowed_signers`, else the directory above the bootstrap,
   which is `plugin/` for the plugin copy and `.claude/` for the committed copy), then
   at `CFG/bbd-apparatus/allowed_signers`. With such a file present, even an empty one,
   `git -c gpg.ssh.allowedSignersFile=<file> verify-commit` must pass on the fetched
   head before it is checked out, and on the checkout before it runs. An unsigned or
   badly signed head is refused, and the last verified checkout
   (`state/verified-<channel>`) runs; with none, the run behaves as if there were no
   checkout. With no file anywhere, heads are not verified; that is the state until the
   maintainers' signing keys ship with the plugin. One push to `stable` runs on every
   tenant's next turn, so once the keys ship, a head no maintainer key signed is not run.
6. **Hand-off.** Run the checkout's `launcher/dispatch.sh` as a child, with the event,
   the delivery and the saved stdin as a file:
   `dispatch.sh <event> <delivery> <input-file> [skill name]`. It is a child, not an
   `exec`, so a crash, an exit 2 or a hang in the checkout's code still ends in exit 0:
   its stdout is collected and only one JSON object of it is passed on (a skill's
   body is plain text and passes as it is), it is bounded at 600 seconds as an outer
   net for the asynchronous entry, and it is killed if the bootstrap is.

Every git call on the checkout names the checkout's repository outright, so git never
searches upward into a repository that happens to contain the home, and reads none of
the tenant's own git config; inherited `GIT_DIR` and its relatives are cleared first.
A checkout that is not a usable repository, or that cannot be reset, is removed and
fetched again on the next turn.

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

The template provisioning copies, `templates/tenant-repo/.apparatus/vault.json`, has
the same four fields with the tenant left empty, so a copy that provisioning has not
filled fails this gate rather than acting under a placeholder.

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

## 11. The prompt and compact steps

`launcher/events/prompt.sh` runs on every UserPromptSubmit, and
`launcher/events/compact.sh` runs when SessionStart carries `source: compact`, the
one hook that can put context back after a compaction. Both print one JSON object
whose `additionalContext` the model reads; the dispatcher passes on nothing else.

**The ask ledger.** Every prompt is written to `state/ledger/<session_id>.md` (0600 in
a 0700 directory) as the next numbered line, `<n>. open <utc>: <the words, whole,
spaces folded>`, by `lib/ledger.py`. A number is given once and never again, so
"number 3" names the same ask for the whole session, and a closed item is kept as
`done` with its number. Not recorded, because none is the person's ask: a prompt that
is empty once the harness's own wrappers are removed (`<task-notification>`,
`<system-reminder>` and the parts of a slash command), a slash command, a JSON-shaped
prompt, and a system notification. Typed text beside a wrapper is recorded on its own;
an unclosed wrapper is cut to the end of the prompt. One item keeps at most 4,000
characters. Closing an item is a later task's; the file format and the read path are
here.

**What a prompt injects, in order:**

1. `text/reply-contract.md` and `text/witness-rules.md`: the apparatus's own words,
   kept as text in this checkout so they change here and never in the plugin.
2. The tenant's rules file, the one the vault marker names (`rules`), under a heading
   that names the file. A marker that names none, or a file that is missing or
   empty, gives no section.
3. `.apparatus/standing.md` in the tenant repository, the standing instructions, the
   same way.
4. The session's open asks, oldest first, each under its number.

**What a compaction injects, in order:** `text/compact-notice.md` (one sentence saying
the session was compacted and that memory in the store is unaffected), then the rules
file, the standing instructions and the open asks as above. The reply contract is not
repeated there; the next prompt brings it. The compaction is counted in
`state/compactions/<session_id>`, a plain integer the fresh-session advice reads;
every other SessionStart source leaves the count alone.

**The cap.** The whole injection is at most 6,000 characters. The asks give way first,
oldest first, with one line saying how many are not shown; when not even the newest
fits, no asks are shown. If the texts and the rules alone pass the cap, their tail is
cut at the cap and the cut is said. A growing per-prompt rulebook was measured to
raise the correction rate, so the cap is a feature, not a limit to raise.

**The token.** A token shape (`bbdt_` plus 40 characters) is masked as `[token]` before
anything reaches the ledger or stdout, whether it came in the prompt, the rules file
or the standing instructions. The event scripts never hold the token's value: the
dispatcher parses `tenant.env` and exports no token to them.
