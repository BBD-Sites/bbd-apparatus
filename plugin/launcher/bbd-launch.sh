#!/usr/bin/env bash
# bbd-launch.sh: the bootstrap every hook entry runs, from the plugin and from the copy
# committed in a tenant repository (the two files are byte-identical, and a test says
# so). It NEVER changes (docs/launcher-contract.md): a fix to this file would reach
# only new installs, so everything that may ever need to change lives in the checkout
# it runs. That is why it does as little as it can: decide whether to act at all,
# keep the checkout current inside a hard time bound, and hand the event over.
#
#   bbd-launch.sh EVENT DELIVERY          EVENT: session-start, prompt, pre-write,
#   bbd-launch.sh skill NAME [DELIVERY]          stop-gate or stop-ship
#                                         DELIVERY: plugin or repo (skill: plugin)
#
# It needs bash 3.2, git and python3 only: no jq (a stock Mac has none) and no
# `timeout` (macOS has none). There is no `set -e`; every failure is handled where it
# happens, and the traps below turn anything unhandled into a quiet exit 0, because a
# hook that fails or blocks would interrupt the tenant's own work. Stdout stays empty
# here: on UserPromptSubmit it becomes model context, so only the checkout's
# dispatcher, which emits hook JSON, ever writes to it.

BBD_URL="https://github.com/Personal-Tooling/bbd-apparatus.git"
BBD_FETCH_BOUND=3   # seconds a fetch may take before this turn runs the last checkout
BBD_STAMP_FRESH=20  # seconds after a fetch in which another is skipped (one per turn)
BBD_LOCK_STALE=60   # seconds after which a fetch lock is taken to be a dead holder's
BBD_LOG_MAX=262144  # bytes of launcher.log kept before it is rotated
# An outer bound on the checkout's own code, for the one entry the harness does not
# time (the asynchronous Stop ship); every synchronous entry has a tighter harness
# timeout, and the checkout keeps its own tighter bounds inside this one.
BBD_DISPATCH_BOUND=600

_bbd_log=""
_bbd_lock=""
_bbd_child=""
_bbd_watcher=""
_bbd_in=""
_bbd_out=""

# shellcheck disable=SC2329  # invoked by the EXIT trap
bbd_finish() {
  if [ -n "$_bbd_child" ]; then bbd_kill_tree "$_bbd_child" TERM escalate; fi
  if [ -n "$_bbd_watcher" ]; then kill -TERM "$_bbd_watcher" 2>/dev/null; fi
  if [ -n "$_bbd_lock" ]; then rm -rf "$_bbd_lock" 2>/dev/null; _bbd_lock=""; fi
  if [ -n "$_bbd_in" ]; then rm -f "$_bbd_in" 2>/dev/null; fi
  if [ -n "$_bbd_out" ]; then rm -f "$_bbd_out" 2>/dev/null; fi
  exit 0
}

# Errors are written only once this repository has passed the marker gate, so an
# unmarked repository never gets a state directory. The bootstrap never reads the
# token, but anything token-shaped that git or python prints is masked anyway.
bbd_log() {
  [ -n "$_bbd_log" ] || return 0
  if [ -f "$_bbd_log" ] && [ "$(wc -c <"$_bbd_log" 2>/dev/null || echo 0)" -gt "$BBD_LOG_MAX" ]; then
    mv -f "$_bbd_log" "$_bbd_log.1" 2>/dev/null
  fi
  printf '%s bootstrap %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" \
    | sed -E 's/bbdt_[A-Za-z0-9]{40}/[token]/g' >>"$_bbd_log" 2>/dev/null
  return 0
}

set -E
trap 'bbd_finish' EXIT
trap 'bbd_log "unhandled failure at line $LINENO: $BASH_COMMAND"' ERR
trap 'exit 0' INT TERM HUP
exec 2>/dev/null
# A hook started from inside a git hook inherits GIT_DIR and its relatives; with them
# set, every git call below would act on that repository instead of the one named.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
  GIT_COMMON_DIR GIT_NAMESPACE GIT_PREFIX GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT \
  GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_NO_REPLACE_OBJECTS GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE
# An exported CDPATH makes `cd` print the directory, which would corrupt $(cd ...).
unset CDPATH
# The stock Mac python writes its bytecode cache under the home; a repository the
# gate refuses must leave nothing anywhere, so no cache is written at all.
export PYTHONDONTWRITEBYTECODE=1

# A session the reader step starts for itself (PR 9) sets this, so its own hooks do
# nothing at all: no recursion, and the reader's session is never shipped.
[ -n "${BBD_NESTED:-}" ] && exit 0

event=${1:-}
delivery=${2:-}
skill_name=""
if [ "$event" = skill ]; then
  skill_name=${2:-}
  delivery=${3:-plugin}
  case "$skill_name" in ''|-*|*[!a-z0-9-]*) exit 0 ;; esac
fi
case "$event" in ''|-*|*[!a-z-]*) exit 0 ;; esac
case "$delivery" in plugin|repo) ;; *) exit 0 ;; esac

# A hook can fire after the session's directory was deleted (a removed worktree);
# every git and python call below would then fail, so start from the home instead.
if ! pwd -P >/dev/null 2>&1 || [ ! -d "${PWD:-/nonexistent}" ]; then
  cd "$HOME" 2>/dev/null || cd / || exit 0
fi
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)

cfg=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
base=$cfg/bbd-apparatus
env_file=$base/tenant.env

# Hook JSON arrives once on stdin. A skill runs from a Bash tool call, which brings
# no hook JSON and may never close stdin, so it is not read there.
input=""
if [ "$event" != skill ] && [ ! -t 0 ]; then
  input=$(cat)
fi

# bbd_env_get KEY: the value of KEY=VALUE in tenant.env. The file is read as text and
# never sourced, so nothing in it can execute. The token is never asked for here.
bbd_env_get() {
  local want=$1 line key val
  [ -f "$env_file" ] && [ -r "$env_file" ] || return 0
  [ "$(wc -c <"$env_file" 2>/dev/null || echo 0)" -le 65536 ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; *=*) ;; *) continue ;; esac
    key=${line%%=*}
    val=${line#*=}
    key=${key#export }
    key=${key// /}
    [ "$key" = "$want" ] || continue
    case "$val" in \"*\") val=${val#\"}; val=${val%\"} ;; \'*\') val=${val#\'}; val=${val%\'} ;; esac
    printf '%s\n' "$val"
    return 0
  done <"$env_file"
  return 0
}

# 1. Root and marker. The root is the harness's project dir, else the hook JSON's cwd,
# never the shell's own directory, which can belong to a different repository. The
# one exception is a skill: it is run by the session's own Bash tool, which starts in
# the session's project and brings no hook JSON, so there the directory is the
# project.
dir=${CLAUDE_PROJECT_DIR:-}
if [ -z "$dir" ] && [ "$event" = skill ]; then
  dir=$PWD
fi
if [ -z "$dir" ] && [ -n "$input" ]; then
  dir=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    doc = {}
cwd = doc.get("cwd") if isinstance(doc, dict) else None
print(cwd.replace("\n", " ") if isinstance(cwd, str) else "")
' 2>/dev/null)
fi
[ -n "$dir" ] && [ -d "$dir" ] || exit 0
# Asking git, not looking for .git/, because a worktree's .git is a file.
[ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || exit 0
root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
[ -n "$root" ] && [ -f "$root/.apparatus/vault.json" ] || exit 0

marker=$(python3 -c '
import json, re, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        doc = json.load(f)
except Exception:
    sys.exit(0)
if not isinstance(doc, dict):
    sys.exit(0)
def word(v):
    return isinstance(v, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", v) is not None
if not word(doc.get("tenant")):
    sys.exit(0)
print(doc["tenant"])
print(doc["channel"] if word(doc.get("channel")) else "")
' "$root/.apparatus/vault.json" 2>/dev/null)
tenant=$(printf '%s\n' "$marker" | sed -n 1p)
marker_channel=$(printf '%s\n' "$marker" | sed -n 2p)
[ -n "$tenant" ] || exit 0

# A home that holds a token belongs to one tenant: a marked repository of any other
# tenant (a test tenant's, say) is not this home's to ship.
if [ -e "$env_file" ] && [ "$(bbd_env_get BBD_TENANT)" != "$tenant" ]; then
  exit 0
fi

# 2. Delivery dedupe. Only an install that also enabled the plugin writes tenant.env,
# so on such a home the plugin copy runs and the repository copy stands down; a cloud
# session has no plugin, so there the repository copy always runs.
if [ "$delivery" = repo ] && [ "${CLAUDE_CODE_REMOTE:-}" != true ] && [ -e "$env_file" ]; then
  exit 0
fi

# 3. Channel.
channel=$(bbd_env_get BBD_CHANNEL)
[ -n "$channel" ] || channel=$marker_channel
case "$channel" in ''|-*|*[!A-Za-z0-9._-]*) channel=stable ;; esac

if [ "${CLAUDE_CODE_REMOTE:-}" = true ]; then
  where=cloud
elif [ -n "${CLAUDE_CODE_BRIDGE_SESSION_ID:-}" ]; then
  where=remote-control
else
  where=desktop
fi

umask 077
mkdir -p "$base/state" "$base/queue" 2>/dev/null || exit 0
chmod 700 "$base" "$base/state" "$base/queue" 2>/dev/null
_bbd_log=$base/state/launcher.log
exec 2>>"$_bbd_log"


bbd_now() { date +%s; }

# A mkdir lock: atomic on every filesystem. The holder writes its start time inside;
# a lock older than BBD_LOCK_STALE is a holder that died, and is taken over. A lock
# held by a live run is not waited for: this run skips the fetch instead.
bbd_lock() {
  local lock=$1 now at
  now=$(bbd_now)
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$now" >"$lock/at"
    _bbd_lock=$lock
    return 0
  fi
  at=$(cat "$lock/at" 2>/dev/null || true)
  case "$at" in ''|*[!0-9]*)
    # No time yet: either its holder is between mkdir and writing it, or it died
    # there. Only the directory's own age tells them apart.
    [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] || return 1 ;;
  *)
    [ $((now - at)) -ge "$BBD_LOCK_STALE" ] || return 1 ;;
  esac
  rm -rf "$lock" 2>/dev/null
  mkdir "$lock" 2>/dev/null || return 1
  printf '%s\n' "$now" >"$lock/at"
  _bbd_lock=$lock
  return 0
}

bbd_unlock() {
  if [ -n "$_bbd_lock" ]; then rm -rf "$_bbd_lock" 2>/dev/null; _bbd_lock=""; fi
}

# bbd_tree PID: PID and every process below it, from one process listing taken
# before anything is killed, so a kill reaches the grandchildren (an event's python,
# git's transport helper) that a plain kill of PID would leave running. A process
# that detached itself (a double fork, setsid) is no longer below PID and is not
# reached; nothing the launcher starts does that.
bbd_tree() {
  ps -A -o pid= -o ppid= 2>/dev/null | awk -v root="$1" '
    $1 != $2 { kids[$2] = kids[$2] " " $1 }
    END {
      queue = root
      out = ""
      while (queue != "") {
        n = split(queue, q, " ")
        queue = ""
        for (i = 1; i <= n; i++) {
          out = out " " q[i]
          if (q[i] in kids) queue = queue kids[q[i]]
        }
      }
      print out
    }'
}

# bbd_kill_tree PID SIGNAL [escalate]: signal PID's whole tree; with "escalate", a second
# later KILL whatever of that same tree is still alive, for a process that ignores
# TERM. Without ps (a minimal container), only PID itself is reached.
bbd_kill_tree() {
  local pids p alive=""
  pids=$(bbd_tree "$1")
  if [ -z "$pids" ]; then
    pids=$1
    bbd_log "no process listing; only the direct child is stopped"
  fi
  # shellcheck disable=SC2086  # a list of numeric pids
  kill "-$2" $pids 2>/dev/null
  if [ "${3:-}" = escalate ]; then
    for p in $pids; do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
    if [ -n "$alive" ]; then
      sleep 1
      # shellcheck disable=SC2086  # a list of numeric pids
      kill -KILL $alive 2>/dev/null
    fi
  fi
  return 0
}

# bbd_bounded SECONDS OUT CMD...: run CMD with its stdout to the file OUT, killing it
# and everything under it after SECONDS. macOS has no `timeout`, so the bound is a
# watcher process; it kills its own sleep when it is stopped, so nothing of it
# outlives the run. Neither process holds this script's stdout, because the harness
# waits for stdout to close. If this script is itself killed, the EXIT trap kills
# both.
bbd_bounded() {
  local secs=$1 out=$2 rc child
  shift 2
  "$@" </dev/null >>"$out" 2>>"$_bbd_log" &
  child=$!
  _bbd_child=$child
  (
    trap 'kill "$s" 2>/dev/null; exit 0' TERM
    sleep "$secs" & s=$!
    wait "$s" 2>/dev/null || exit 0
    bbd_kill_tree "$child" TERM
    sleep 1 & s=$!
    wait "$s" 2>/dev/null || exit 0
    bbd_kill_tree "$child" KILL
  ) </dev/null >/dev/null 2>&1 &
  _bbd_watcher=$!
  if wait "$_bbd_child"; then rc=0; else rc=$?; fi
  kill -TERM "$_bbd_watcher" 2>/dev/null || true
  wait "$_bbd_watcher" 2>/dev/null || true
  _bbd_child=""
  _bbd_watcher=""
  return "$rc"
}

# Every git call on the checkout names its repository outright, so git never goes
# looking upward: a broken checkout inside a home tracked by its own repository
# would otherwise reset that repository. The tenant's own git config is not read
# either (no URL rewrite, prompt, hook or background daemon of theirs applies to a
# public fetch); proxy and certificate settings still come from the environment.
bbd_git_env() {
  env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 "$@"
}
bbd_git() {
  bbd_git_env git --git-dir="$co/.git" --work-tree="$co" -C "$co" \
    -c core.hooksPath=/dev/null -c core.fsmonitor=false -c gc.auto=0 "$@"
}

# 5 (setup). Signed heads. OFF by default, and on only where tenant.env sets
# BBD_REQUIRE_SIGNED_HEAD=1, until the maintainers' signing keys exist and an
# allowed_signers file ships beside this script's directory (or in
# CFG/bbd-apparatus/). When on, a head no allowed key signed is never checked out,
# and never run: the checkout stays at, or returns to, the last head that verified,
# and with none, this run behaves as if there were no checkout at all.
signed=""
signers=""
case "$(bbd_env_get BBD_REQUIRE_SIGNED_HEAD)" in
  1|true|yes)
    signed=1
    for f in "$here/../allowed_signers" "$base/allowed_signers"; do
      if [ -s "$f" ]; then signers=$f; break; fi
    done
    ;;
esac
verified=$base/state/verified-$channel
bbd_verify() { # REV
  [ -n "$signers" ] && bbd_git -c gpg.ssh.allowedSignersFile="$signers" verify-commit "$1" >>"$_bbd_log" 2>&1
}

# 4. Fast-forward, under the lock; every write to the checkout happens here. Resetting
# to FETCH_HEAD is both the fast-forward and the repair of a drifted or diverged
# checkout: the checkout always lands on the channel head. The reset runs only when
# the head moved or the tree drifted, so a run already reading the checkout is
# disturbed only by a real release.
co=$base/checkout-$channel
stamp=$base/state/fetch.stamp
if bbd_lock "$base/state/fetch.lock"; then
  # Holding the lock means no other launcher is in git here, so any git lock file
  # left is from a run that was killed; left in place it would fail every later turn.
  rm -f "$co"/.git/*.lock "$co"/.git/refs/heads/*.lock 2>/dev/null
  if [ -e "$co" ] && ! bbd_git rev-parse --git-dir >/dev/null 2>&1; then
    bbd_log "the $channel checkout is not a usable repository; starting it again"
    rm -rf "$co"
  fi
  last=$(cat "$stamp" 2>/dev/null || true)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $(($(bbd_now) - last)) -ge "$BBD_STAMP_FRESH" ]; then
    [ -d "$co/.git" ] || bbd_git_env git init -q "$co" >>"$_bbd_log" 2>&1
    # git itself, not a shell function, is what runs in the background (env execs
    # it), so the kill reaches the fetch and nothing of it outlives this turn.
    if bbd_bounded "$BBD_FETCH_BOUND" "$_bbd_log" \
        env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 git --git-dir="$co/.git" \
        -c core.hooksPath=/dev/null -c core.fsmonitor=false -c gc.auto=0 \
        fetch -q --no-tags --depth=1 "$BBD_URL" "$channel"; then
      head_now=$(bbd_git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null || true)
      head_new=$(bbd_git rev-parse -q --verify 'FETCH_HEAD^{commit}' 2>/dev/null || true)
      drift=$(bbd_git status --porcelain --untracked-files=all 2>/dev/null || echo unreadable)
      if [ -n "$signed" ] && ! bbd_verify FETCH_HEAD; then
        bbd_log "the $channel head is not signed by an allowed key; not checked out"
      elif [ -n "$head_new" ] && { [ "$head_now" != "$head_new" ] || [ -n "$drift" ]; }; then
        if ! { bbd_git reset -q --hard FETCH_HEAD >>"$_bbd_log" 2>&1 \
               && bbd_git clean -q -ffdx >>"$_bbd_log" 2>&1; }; then
          # A checkout that cannot be reset is in an unknown state; the next turn
          # starts it again rather than run it.
          bbd_log "could not reset the $channel checkout; it will be fetched again"
          rm -rf "$co"
        fi
      fi
    else
      bbd_log "fetch of $channel failed or took over ${BBD_FETCH_BOUND}s; running the last checkout"
    fi
    bbd_now >"$stamp"
  fi
  if [ -n "$signed" ] && [ -d "$co/.git" ] && ! bbd_verify HEAD; then
    good=$(cat "$verified" 2>/dev/null || true)
    case "$good" in
      *[!0-9a-f]*|'') ;;
      *) bbd_git reset -q --hard "$good" >>"$_bbd_log" 2>&1 \
           && bbd_git clean -q -ffdx >>"$_bbd_log" 2>&1 ;;
    esac
  fi
  bbd_unlock
fi

valid=""
if bbd_git rev-parse -q --verify 'HEAD^{commit}' >/dev/null 2>&1 && [ -f "$co/launcher/dispatch.sh" ]; then
  valid=1
fi
if [ -n "$valid" ] && [ -n "$signed" ]; then
  if bbd_verify HEAD; then
    bbd_git rev-parse HEAD >"$verified" 2>/dev/null
  else
    valid=""
    bbd_log "the $channel checkout is not signed by an allowed key; refused"
  fi
fi

# No runnable checkout (first run offline, or a refused head). Only the transcript
# matters then: Stop ship records a pointer to it, which the checkout's ship step
# drains on a later turn; the pointer holds no transcript text, so nothing unredacted
# is copied. Every other event does nothing.
if [ -z "$valid" ]; then
  if [ "$event" = stop-ship ]; then
    printf '%s' "$input" | python3 -c '
import json, os, re, sys, tempfile, time
queue, where = sys.argv[1], sys.argv[2]
try:
    hook = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(hook, dict):
    sys.exit(0)
sid, path = hook.get("session_id"), hook.get("transcript_path")
if not isinstance(sid, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}", sid):
    sys.exit(0)
target = os.path.join(queue, sid + ".json")
try:
    with open(target, encoding="utf-8") as f:
        old = json.load(f)
except Exception:
    old = {}
if not isinstance(old, dict):
    old = {}
attempts = old.get("attempts")
record = {
    "session_id": sid,
    "transcript_path": path if isinstance(path, str) and path else str(old.get("transcript_path") or ""),
    "where": where,
    "first_seen": old.get("first_seen") or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "attempts": attempts if isinstance(attempts, int) and not isinstance(attempts, bool) else 0,
}
fd, tmp = tempfile.mkstemp(dir=queue, prefix=".pointer.")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(record, f, sort_keys=True)
    f.write("\n")
os.replace(tmp, target)
' "$base/queue" "$where" >>"$_bbd_log" 2>&1 || bbd_log "could not queue a pointer"
  fi
  exit 0
fi

# 6. Hand-off. The dispatcher runs as a bounded child, not by exec, so the guarantees
# above outlive any bug in the checkout's code: a crash, an exit 2 or a hang there
# still ends here with exit 0. Its stdout goes to a file and only one JSON object of
# it is passed on as hook output (a skill's body is plain text for the model, so it
# passes as it is). The saved stdin and the output are both in the state directory
# (0700) and removed afterwards.
in_file=$(mktemp "$base/state/hook.XXXXXX" 2>/dev/null) || exit 0
out_file=$(mktemp "$base/state/out.XXXXXX" 2>/dev/null) || { rm -f "$in_file"; exit 0; }
_bbd_in=$in_file
_bbd_out=$out_file
printf '%s' "$input" >"$in_file"
if [ "$event" = skill ]; then
  # A skill's body is printed only when the run finished: half a body is worse than
  # none, because the model would follow it.
  if bbd_bounded "$BBD_DISPATCH_BOUND" "$out_file" "${BASH:-bash}" "$co/launcher/dispatch.sh" \
      skill "$delivery" "$in_file" "$skill_name"; then
    cat "$out_file" 2>/dev/null
  else
    bbd_log "the dispatcher failed for skill $skill_name"
  fi
else
  bbd_bounded "$BBD_DISPATCH_BOUND" "$out_file" "${BASH:-bash}" "$co/launcher/dispatch.sh" \
    "$event" "$delivery" "$in_file" || bbd_log "the dispatcher failed for $event"
  if [ -s "$out_file" ]; then
    python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        doc = json.loads(f.read())
except Exception:
    doc = None
if isinstance(doc, dict):
    print(json.dumps(doc))
else:
    sys.stderr.write("bootstrap: dropped dispatcher output that was not one JSON object\n")
' "$out_file" 2>>"$_bbd_log"
  fi
fi
exit 0
