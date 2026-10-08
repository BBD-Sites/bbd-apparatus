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

_bbd_log=""
_bbd_lock=""

# shellcheck disable=SC2329  # invoked by the EXIT trap
bbd_finish() {
  if [ -n "$_bbd_lock" ]; then rm -rf "$_bbd_lock" 2>/dev/null; _bbd_lock=""; fi
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
# Lets a failed exec return here, so it can still exit 0 instead of the shell dying.
shopt -s execfail
exec 2>/dev/null
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
# never the shell's own directory, which can belong to a different repository.
dir=${CLAUDE_PROJECT_DIR:-}
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

# bbd_bounded SECONDS CMD...: run CMD, killing it after SECONDS. macOS has no
# `timeout`, so the bound is a watcher process. Neither process keeps this script's
# stdout open, because the harness waits for stdout to close before it reads it.
bbd_bounded() {
  local secs=$1 pid watcher rc
  shift
  "$@" </dev/null >>"$_bbd_log" 2>&1 &
  pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null ) \
    </dev/null >/dev/null 2>&1 &
  watcher=$!
  if wait "$pid"; then rc=0; else rc=$?; fi
  kill -TERM "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  return "$rc"
}

# The checkout's own git calls never run a hook from the tenant's global git config.
bbd_git() { git -C "$co" -c core.hooksPath=/dev/null "$@"; }

# 4. Fast-forward. Resetting to FETCH_HEAD is both the fast-forward and the repair of
# a drifted or diverged checkout: the checkout always lands on the channel head.
co=$base/checkout-$channel
stamp=$base/state/fetch.stamp
if bbd_lock "$base/state/fetch.lock"; then
  last=$(cat "$stamp" 2>/dev/null || true)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $(($(bbd_now) - last)) -ge "$BBD_STAMP_FRESH" ]; then
    [ -d "$co/.git" ] || git init -q "$co" >>"$_bbd_log" 2>&1
    # git itself, not a function, runs in the background, so the kill reaches the
    # fetch and does not leave it running on after this turn has moved on.
    if bbd_bounded "$BBD_FETCH_BOUND" git -C "$co" -c core.hooksPath=/dev/null \
        fetch -q --no-tags --depth=1 "$BBD_URL" "$channel"; then
      bbd_git reset -q --hard FETCH_HEAD >>"$_bbd_log" 2>&1 \
        && bbd_git clean -q -ffdx >>"$_bbd_log" 2>&1
    else
      bbd_log "fetch of $channel failed or took over ${BBD_FETCH_BOUND}s; running the last checkout"
    fi
    bbd_now >"$stamp"
  fi
  bbd_unlock
fi

valid=""
if bbd_git rev-parse -q --verify 'HEAD^{commit}' >/dev/null 2>&1 && [ -f "$co/launcher/dispatch.sh" ]; then
  valid=1
fi

# 5. Signed heads. OFF by default, and on only where tenant.env sets
# BBD_REQUIRE_SIGNED_HEAD=1, until the maintainers' signing keys exist and an
# allowed_signers file ships beside this script (or in CFG/bbd-apparatus/). When on,
# a head no allowed key signed is not run: the checkout returns to the last head that
# verified, and with none, this run behaves as if there were no checkout at all.
case "$(bbd_env_get BBD_REQUIRE_SIGNED_HEAD)" in
  1|true|yes)
    signers=""
    for f in "$here/../allowed_signers" "$base/allowed_signers"; do
      if [ -s "$f" ]; then signers=$f; break; fi
    done
    verified=$base/state/verified-$channel
    bbd_verify() {
      [ -n "$signers" ] && bbd_git -c gpg.ssh.allowedSignersFile="$signers" verify-commit HEAD >>"$_bbd_log" 2>&1
    }
    if [ -n "$valid" ] && bbd_verify; then
      bbd_git rev-parse HEAD >"$verified" 2>/dev/null
    else
      valid=""
      good=$(cat "$verified" 2>/dev/null || true)
      if [ -n "$good" ] && bbd_git reset -q --hard "$good" >>"$_bbd_log" 2>&1 && bbd_verify \
          && [ -f "$co/launcher/dispatch.sh" ]; then
        valid=1
      fi
      bbd_log "the $channel head is not signed by an allowed key; refused"
    fi
    ;;
esac

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

# 6. Hand-off. The saved stdin goes over as a file in the state directory (0700); the
# dispatcher removes it when the event is done.
in_file=$(mktemp "$base/state/hook.XXXXXX" 2>/dev/null) || exit 0
printf '%s' "$input" >"$in_file"
if [ "$event" = skill ]; then
  exec "${BASH:-bash}" "$co/launcher/dispatch.sh" skill "$delivery" "$in_file" "$skill_name"
else
  exec "${BASH:-bash}" "$co/launcher/dispatch.sh" "$event" "$delivery" "$in_file"
fi
rm -f "$in_file"
bbd_log "could not start the dispatcher"
exit 0
