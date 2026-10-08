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
   checkout. The file ships with every delivery: `plugin/allowed_signers` in the plugin
   (shell version 3 and later), `.claude/allowed_signers` in the tenant repository
   template beside the committed copy, and `CFG/bbd-apparatus/allowed_signers`, which the
   installer writes from the published file and refuses to install without. Each is the
   maintainers' public key under the neutral principal, and `docs/channels.md` says how
   every head pushed to a channel is signed by it. One push to `stable` runs on every
   tenant's next turn; this is what keeps that push the key holder's alone. With no file
   anywhere (a plugin older than version 3 on a home the installer has not written),
   heads are not verified until the plugin updates.
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
  `{"decision":"block","reason":"..."}` with exit 0, at most once per `prompt_id`
  (section 13).
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
| Store not connected (a token, no ingest address) | Render and post-scan anyway; send nothing; keep the queue; record `store-not-connected`. |
| Store down, slow or unreachable | Keep the entry; it is tried again next turn. |
| Repository remote unreachable (captures branch) | Keep the entry; it is tried again next turn. |
| A queued transcript is gone from disk | Drop the entry; record a loss notice once. |

## 7. Timeouts

Set in the hook entries, which never change, so they are chosen generously (seconds):

| Entry | Timeout |
| --- | --- |
| SessionStart | 20 |
| UserPromptSubmit | 10 |
| PreToolUse | 5 |
| Stop gate | 90 |
| Stop ship | asynchronous in the plugin, with an internal bound of 120; in a tenant repository's copy, 60, with an internal bound of 50 (section 10) |

## 8. State and queue layout

Everything lives under `CFG/bbd-apparatus/`, mode 0700, one per account home.

```
CFG/bbd-apparatus/
  tenant.env                 0600; the token and settings, written only by the installer
  allowed_signers            the published signers file, copied by the installer (section 3,
                             step 5); the installer refuses to install while it has none to copy
  excluded-homes             read by the installer only, from the config of the login that
                             runs it: homes it must never touch, one absolute path per line
  checkout-<channel>/        the apparatus checkout the launcher runs
  queue/<session_id>.json    a pointer record
  quarantine/<session_id>.md rendered copies the post-scan refused; never sent
  state/
    ledger/<session_id>.md   the session's ask ledger
    notices.json             notices to say, notices already said, and any stop the tenant asked for
    selftest-<sha>.ok        a passed redactor self-test for that checkout
    ship-status.json         how the last ship step ended, and how many entries wait
    ship.lock/               held while a ship step drains the queue
    outbox/                  a rendered copy while it is being sent; emptied by every run
    fetch.stamp              when the last fetch finished
    compactions/<session_id> the session's compaction count
    reader/<draft hash>.json the reader's receipt for one draft (section 13)
    loopguard/<session_id>.turn  the turn last blocked, and how many times
    draft.md                 a draft the person gave the read-draft skill; consumed by it
    launcher.log             errors, rotated and redacted
```

A queue record is a pointer, not a copy:
`{session_id, transcript_path, where, first_seen, attempts}`, and, when the checkout
writes it, `queued_at` (when this turn was queued, in nanoseconds; a retry count
keeps it), `project_root`, `repo` (git's common directory, shared by every worktree
of one repository) and `tenant` (the vault marker's). The bootstrap, which runs with
no checkout, writes the first five only; for such a record the repository is read
from the transcript's own working directory. It holds no transcript text, so nothing
unredacted is duplicated; redaction runs when the queue is drained, and one record per
session always points at the latest transcript.

Every Stop ship sends its own session first, then drains up to 5 older records,
oldest first. If a record's transcript is gone when it is drained, that loss is
recorded as a notice. A cloud session's state lives in its machine and is lost when the machine is reclaimed, so
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

## 10. The ship step

`launcher/events/stop-ship.sh` runs on Stop: asynchronously in the plugin, and
synchronously in a cloud session's repository copy. It is the only step that sends
anything off the machine.

Its time bounds follow the delivery the dispatcher passes. The plugin entry has no
harness timeout. The repository copy runs under the harness's 60-second timeout,
and a cloud machine's queue is lost when the machine is reclaimed, so its whole step
must end well inside that.

| Bound (seconds) | Plugin | Repository copy |
| --- | --- | --- |
| Whole step, then killed | 120 | 50 |
| Budget: no old entry's render starts unless its bounds fit before this | 90 | 30 |
| One render | 30 | 15 |
| One post-scan | 15 | 5 |
| Redactor self-test | 60 | 20 |
| Room a push must still have before the kill | 30 | 15 |

In order:

1. **Queue.** Write or refresh this session's pointer record first, so nothing that
   follows can lose the turn.
2. **Lock.** One ship step at a time per home (`state/ship.lock`); two draining one
   queue would send a session twice. The handoff is closed on both sides, so a turn
   that ends while another step holds the lock is sent by that step, or by its own
   run once the lock frees.
   - A run that finds the lock held waits for it, up to its own cutoff (its
     whole-step bound minus 5 seconds). Its pointer is already queued, so waiting
     costs nothing. When it gets the lock it ships its own session first, then old
     entries as time allows. Its bound runs to its own cutoff, so the time it spent
     waiting comes off its shipping time.
   - The holder loops until quiet. It records every pointer write that was queued
     when it began, and every write it takes. After each pass it reads the queue
     again, and lets go of the lock only when a read finds nothing new, or when no
     render could start inside the budget. Each read takes the writes made since it
     began that it has not taken (a later turn of a session it was sending, another
     session), newest first.
   - No clock is compared, so a turn queued at any moment, or stamped by a clock
     that runs behind, is never skipped. Older entries that were already queued are
     not taken by these reads, so the cap of five per firing holds.
   - Anything queued after the holder's last read belongs to a Stop that is now
     waiting on the lock, and ships next.
   - The one turn that can still wait for a later Stop in this home is one whose own
     run reaches its cutoff while it is still waiting for the lock.
3. **Self-test.** `apparatus selftest` runs once per checkout commit, and a pass is
   cached as `state/selftest-<sha>.ok`, which holds the sha256 of the redactor it
   proved, so a redactor edited in place is tested again. A failure sends nothing,
   keeps the whole queue, and records `selftest-failed` and a notice once for that
   commit.
4. **Drain.** This session first, then the five oldest queued sessions by first
   seen that this firing's door may take (step 5). Each is
   rendered with `apparatus render` (redacted before truncation and again over the
   whole document) into `state/outbox/`, NUL bytes are removed (the post-scan skips a
   file holding one as binary; removing one can only join text into a longer shape),
   and the copy is post-scanned.
   - The firing session is always rendered, and is sent on its own, through either
     door, before any old entry is rendered. Old entries that keep failing, or a
     store that hangs on them, therefore cannot hold it back, and in the cloud the
     turn is pushed before the harness could kill the step.
   - An old entry is rendered only if its render and post-scan bounds fit inside
     the budget. It is posted only if the post's 20-second timeout, plus 5 seconds,
     fits inside the whole-step bound. A batch of old entries is pushed only if the
     push room still fits. The rest wait for the next turn.
   - A post-scan hit (exit 1 with the file named) moves the copy to `quarantine/`,
     records a notice once for that session, drops the entry, and sends nothing. A
     later turn of the same session is queued and checked again. A post-scan that
     could not run keeps the entry.
   - An entry is dropped only if its pointer is the one that was rendered. A later
     turn that refreshed it while the copy was in flight keeps it queued, so that
     turn is sent on the next firing.
   - A queued session whose transcript is gone is dropped with a loss notice. The
     session that is firing keeps its pointer even if its transcript is not on disk
     yet; a later drain decides.
   - A transcript with nothing to render yet: an old entry is dropped, the firing
     session's is kept.
5. **Door.** A `BBD_TOKEN` in `tenant.env` means the HTTP post
   (`docs/ingest-contract.md`); with no `BBD_INGEST_URL` the store is not connected,
   nothing is sent and every pointer waits. No token (a cloud machine, or a home with
   no install) means the captures branch below.
   - The door is chosen before the drain, because it decides which entries may be
     taken. The queue is per account home and can hold sessions from several
     projects.
   - The captures door writes into this session's own repository, so it takes only
     entries queued for this repository (worktrees of one repository count as one)
     and, where a tenant was recorded, for this marker's tenant. Every other entry
     stays queued for its own project's next Stop and never takes one of the five
     places. A home with no install accepts any tenant's marked repository, so
     without this rule one project's Stop would push another tenant's sessions into
     its own repository and store.
   - The HTTP door drains the whole home queue. That is safe because a home with a
     token holds one tenant's key, and the gate lets such a home act only in that
     tenant's repositories, so every entry is that tenant's. As a second check, an
     entry recorded for a tenant other than `tenant.env`'s `BBD_TENANT` is never
     posted under this key; it stays queued and is logged.

Every rendered copy in `state/outbox/` is removed when the step ends, however it
ends. Notices are recorded in `state/notices.json` under `pending`, keyed so each is
recorded once: `token-refused`, `too-large:<session>`, `quarantine:<session>`,
`loss:<session>`, `selftest-failed:<sha>`, `store-not-connected` and
`ingest-url-refused`. The session-start step says them.

### The captures branch

A home with no token commits the redacted copies to the tenant repository's own
`captures` branch and pushes it. The ref is a branch because the cloud's git proxy
refuses a push of anything else. Plumbing only, so the working tree, the index and
every local branch are left alone:

1. `git fetch --refmap= origin refs/heads/captures`, which writes only FETCH_HEAD and
   objects. A missing branch is fine; `git ls-remote
   --exit-code` tells a missing branch from a remote out of reach, which keeps the
   queue.
2. `git hash-object -w` each rendered copy; read the fetched tree with `git ls-tree`;
   replace or add only `captures/<session_id>.md`; write the trees with `git mktree`.
   Every other file, including other sessions', is carried over.
3. `git commit-tree` with no parent, holding the full tree, as
   `apparatus maintainers <apparatus-maintainers@users.noreply.github.com>`.
4. Push `<commit>:refs/heads/captures` to `origin` with
   `--force-with-lease=refs/heads/captures:<fetched sha>`, the sha left empty when
   the branch did not exist.
5. A lease refused because another session pushed in between is fetched and rebuilt,
   up to three more times; any other failure keeps the queue.

The tenant's own git config is used for this, because it holds the credentials and
proxy that reach their remote; their git hooks are not run, no prompt is allowed,
and no background maintenance is started. After a successful push git records
`refs/remotes/origin/captures` in the tenant's repository, as any push to a named
remote does; no local branch is made.

**Unverified:** whether the cloud's git proxy allows a force-with-lease push. Each
capture commit is parentless, so every push replaces the branch. If the proxy refuses
that, the fallback is a normal commit whose parent is the fetched head: the proxy
accepts it, but the branch grows history until the store prunes it. This is checked
end to end on a provisioned test tenant before it is relied on.

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

## 12. The session-start step

`launcher/events/session-start.sh` runs on every SessionStart. With `source: compact`
it runs the compact step (section 11) and prints nothing of its own. With every other
source (startup, resume, clear, fork) it prints the keep-current notices that are due
as one SessionStart object, or nothing at all. No rules, standing instructions or
asks are injected here; the next prompt brings them. Nothing here reads a network:
the two files compared against arrive with the checkout, and nothing reads the
session API (`tests/test-no-session-api.sh`).

**Four notices**, decided and recorded by `lib/notices.py`:

| Notice | Fires when | Said once per |
| --- | --- | --- |
| ship | the ship step left a notice under `pending` in the record (a refused key, a session held back by the post-scan, a session lost before it was sent; `lib/ship.py` writes them) | home and key |
| version | the running Claude Code is older than `latest` in `data/claude-code.json`; never in the cloud, where the machine runs the build it ships and no restart reaches a newer one | home and newer version |
| model | a model in the same line (opus, sonnet, haiku, fable) as the session's has a later release date in `data/models.json` | repository and newer model |
| fresh-session | the session's compaction count (`state/compactions/<session_id>`) has reached 3, or `context_tokens` is at least 60 percent of the model's `context_window`; the thresholds are the two constants at the top of `lib/notices.py`, his to change | home, session and step: said again only when the count rises to the next multiple of 3 (at 3, 6, 9) or the share enters the next 20-point band past 60 (at 60, 80, 100), the key being `fresh-session:<session_id>:<trigger>:<step>` |

The text of each is `text/notices/<name>.md`, filled in with the versions and names,
and asks the model to say the one sentence in its first reply and then let it rest.
A ship notice's sentence is the one `lib/ship.py` stored, wrapped by
`text/notices/ship.md`; it is said at the next session start or compaction, then
moved from `pending` to `said`.

**The running version** is the newest of two readings. One is the LAST `version`
field in the tail (256 KB) of the transcript the hook names, when it exists: a
session that was upgraded mid-way carries two builds, the older first, so the first
field would tell a person who already restarted to restart again. The other is what
`claude --version` on PATH prints, under a 2-second bound, because the current
build's lines may not be in the transcript yet when the hook fires. Neither is a
network call. No version notice is given when neither answers or the answer is not
`x.y.z`. The hook JSON itself carries no version field.

**The model** is the hook's `model`; a dated id (`-20250929`) or a long-context form
(`[1m]`) is compared by its bare id. A model not listed in `data/models.json` gets no model notice and no
context-share advice, because its line and window are not known, and a guess would
nag. Only the same line is offered: a session on a sonnet is never told about an opus,
because the line is what the person chose and what their plan is known to carry.

**The compact source** folds the fresh-session advice into the compact step's single
object, right after the compaction notice, because the dispatcher passes on exactly
one object. The count is read after the compact step has written it, so the third
compaction is the one that advises.

**The record is two files**, both of the shape `{schema, said, stop, pending}` where
`said` maps a key to when it was said and a notice is marked said when its text is
produced. What is the machine's lives in the home, `state/notices.json` (0600): the
version notice (`version:<latest>`), the fresh-session advice
(`fresh-session:<session_id>:<trigger>:<step>`, per session, so losing it costs
nothing) and the ship step's `pending` (`{key: {text, at}}`, which this step takes
from and never adds to). What is the person's lives in their repository,
`.apparatus/notices.json` (0644, beside the vault marker): the model notice
(`model:<newer id>`) and their `stop` list, so both travel with the vault as the rules
file does and outlive a cloud machine being reclaimed (D14), which the home's state
does not; the repository copy runs session start in the cloud, so without this a
cloud session would repeat the model notice and forget a stop every time. The hook
writes that file in the work tree only and never commits or pushes it; the person's
own commit flow carries it (the auto-commit is task 5.2). A missing file is created
on the first write; a file that exists but cannot be read is left as it is and the
home record stands in, with nothing said about it. Reads take both files: a stop or
a said key in either holds. Every key this step does not own is kept as it found it.
`stop` covers version, model and fresh-session, and not a ship notice, which reports
a loss rather than making a suggestion. A marker whose `notices` is `false` turns
every notice off for that repository, ship notices included.

**The stop is written by a skill.** Each notice text tells the model: if the person
says they do not want this notice again, use the stop skill for its kind
(`/bbd:notices-stop-<kind>` from the plugin, `/notices-stop-<kind>` from a committed
stub in a cloud session) and say in one sentence that it is off; if the skill is not
loaded, the Bash call the stub pre-approves is the fallback. The four stubs sit beside
`read-draft` under `plugin/skills/` and `templates/tenant-repo/.claude/skills/`, each
pre-approving exactly its one bootstrap call, so the model's call meets no permission
prompt. The command is the bootstrap's skill form, in the delivery the notice came
through:

```
bash "${CLAUDE_PLUGIN_ROOT}/launcher/bbd-launch.sh" skill notices-stop-<kind>
bash "$CLAUDE_PROJECT_DIR/.claude/hooks/bbd-launch.sh" skill notices-stop-<kind> repo
```

`<kind>` is `version`, `model`, `fresh-session` or `all`. The kind rides in the
skill's name because the bootstrap, which never changes, passes a skill one word and
nothing after it. Adding the stubs changed the plugin shell, so its version moved
from 1 to 2; the shell's version moves only when the shell itself changes. `launcher/events/skill.sh` records the stop through
`lib/notices.py stop` and prints the one line the model says; a name with any other
kind is refused: nothing printed, nothing written, one line in the log.

`data/models.json` and `data/claude-code.json` are maintained by pull request, not read
from a registry at session start: the cloud session machine's network allowlist admits
github.com and raw.githubusercontent.com only, so a registry read would fail there and
the two kinds of session would disagree, while a file in the checkout rides the same
fast-forward (section 3) that carries every other change to every tenant. The latest
Claude Code version is checked against the npm registry weekly by
`.github/workflows/keep-current.yml`, which goes red when the file is behind; that red
run is the signal to open the data pull request. The model lineup has no machine-readable
public source that carries release dates, so it is read from the model pages by hand.

## 13. The Stop gate: the read-draft step

`launcher/events/stop-gate.sh` runs on every Stop, synchronously, before the ship step.
It is the one place that may print a block decision. The reply the model has just
finished (`last_assistant_message`) is read by an independent reader on the person's own
plan, and when the reader finds something, the turn is held once with the findings as
the reason, so the model sends a corrected reply. Stop fires after the reply is already
on screen, so "read before it is sent" can only mean this: one loop-guarded block,
followed by the corrected reply. Nothing else here reaches the person.

**When it reads.** All of these must hold, in this order; otherwise the step exits 0
with nothing printed and one line in the log saying which failed:

1. `stop_hook_active` is not true. When it is, this Stop is the second pass of the turn,
   after a block, and the reply goes through whatever the reader would say.
2. The draft has at least 50 prose words (fenced code left out). Shorter is an
   acknowledgement, not a draft anyone needs read.
3. No receipt exists for this exact draft (`state/reader/<hash>.json`, the hash of the
   text with whitespace runs folded). A draft is read once.

The repository's rules file, the one the vault marker names, is read against when it
exists and is not empty. A repository with none (a new tenant's names `RULES.md` and
ships none) is read all the same, against the reply contract alone, with the rules
part given to the reader as "(none)"; standing down there would mean no reply of a
new tenant's is ever read.

**The reader** is `reader/reader.py`: it fills `reader/reader-prompt.md` with the reply
contract (`text/reply-contract.md`), the rules file, the session's open asks from the
ledger (the person's own words, so the reader can see what was dropped or left
unanswered) and the draft, and runs one headless call:

```
claude -p --model sonnet --tools "" --no-session-persistence --strict-mcp-config --output-format text
```

Sonnet, not the plan's haiku (design decision D43 in the memory-platform change),
because this reader holds the person's turn and a false finding costs them a corrected
reply they did not need: in the calibration run of 2026-10-08 haiku passed the accepted
draft in one run of two (the other flagged 18 things) and sonnet in two of two. The cost
the person is told at intake is one sonnet call per substantive turn. The receipts under
`state/reader/` are what to read after the canary window before anyone revisits it.

with the prompt on stdin, in an empty temporary directory (so none of the person's
project is read), with `BBD_NESTED=1` in its environment (so every launcher in that
session exits at once: no recursion, and the reader's own session is never shipped) and
`CLAUDECODE` removed from it. The call is killed, with everything under it, at 60
seconds (`BBD_READER_BOUND` overrides, 1 to 600; the hook entry's own timeout is 90).
Not `--bare`: that flag reads no OAuth login, and the reader runs on the person's plan.
A token shape is masked in everything handed to the reader and everything it returns.

**The verdict** is parsed strictly. The first line that says `VERDICT: send` or
`VERDICT: fix` is the verdict (the person's own hooks run in the nested session too and
may wrap the answer in a tag or a closing line, so it need not be the first line);
reading stops at a `---` trailer; a finding is a `- ` line under one of the nine
headings that opens with a quote or with `hedge lost:`; `- none` and the sentence count
are not findings. `fix` holds only with at least one finding. Anything else (no
`claude` on PATH, a timeout, a non-zero exit, no output, an answer out of shape) is
`send`: no failure of the reader's own can hold a reply back on a desktop home.

**When the reader cannot run in a cloud session** (`CLAUDE_CODE_REMOTE` is `true` and
the status is `no-claude`, `timeout` or `failed`), the reply is not let through unread:
the same one block per turn is printed, and its reason is the assembled prompt
(`reader-prompt.md` filled with the contract, the rules, the asks and the draft) under
the instruction to give it to a reader through the Agent tool, act on each finding and
send the corrected reply. The receipt records `handed-back`. On a desktop home the
same failure lets the reply through, logged, because there the next turn's reader will
run and a block would only hold the person up.

**The block** is `{"decision":"block","reason":"..."}`, the reason being the findings,
one per line with their heading, under one sentence asking for the corrected reply, at
most 4,000 characters. It is printed at most once per turn: `lib/loopguard.py` keeps
`state/loopguard/<session_id>.turn` keyed by `prompt_id` (the harness's own turn
identity), or by the draft's hash when the hook carries no `prompt_id`, and a second
`fix` in the same turn is logged and let through. `stop_hook_active` is the first line
of that guard; the file is the second, for a harness that does not send the field.

**The receipt**, `lib/receipt.py`, is written for every read and every attempt, never
for a skip: session, prompt_id, status (`read`, `unparseable`, `empty`, `no-claude`,
`timeout`, `failed`, `handed-back`), verdict, the number of findings, whether the turn was blocked,
the seconds the reader took, the hook's `stop_reason` and the word count. Never the
draft's text. Receipts and guard files older than seven days are removed in passing.

**The skill** (`launcher/events/skill.sh`, behind the `read-draft` stubs) runs the same
reader by hand. The stub's one pre-approved command carries no arguments and the
bootstrap reads no stdin for a skill, so the draft travels through one file: with no
`state/draft.md` the body says to write the exact text there and run the same command
again; with one, the reader runs on it against the contract and the rules, the verdict
and the findings are printed in plain text, a receipt is written with session `skill`,
and the file is removed. A first line of `kind: copy` names the draft as copy the
person's customers will read (the owner-voice and third-grade passes apply) and is not
part of the draft. When the reader cannot run (no `claude`, a timeout, a failure) the
body hands the assembled prompt back, so the model can give it to a reader of its own
with the Agent tool.

**Calibration.** `reader/calibrate.sh` reads every `reader/calibration/rejected-*.md`
and `accepted-*.md` with the calibration asks and rules beside them, on the real
`claude`, and fails unless every rejected draft gets `fix` and every accepted one
`send`. It is run, and its date recorded in the pull request, whenever the prompt or a
draft changes.
