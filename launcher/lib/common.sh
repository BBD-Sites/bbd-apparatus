# shellcheck shell=bash
# The variables set here are read by the scripts that source this file.
# shellcheck disable=SC2034
# launcher/lib/common.sh: the helpers every launcher script in the checkout sources.
# Source it; it defines functions and the BBD_CHECKOUT path, and sets nothing else
# until a function is called.
#
# The bootstrap (plugin/launcher/bbd-launch.sh) applies the same gate before it hands
# over, and it cannot source this file, because it must work with no checkout at all
# and never changes. The gate is applied again here so the checkout's code, which can
# change, never depends on the bootstrap having been right, and can tighten the rule
# without a new bootstrap.
#
# bash 3.2 and python3 only. No jq, no `timeout`, no `source` of a config file.

BBD_CHECKOUT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P)
# Python's caches would land in the checkout and leak local paths into it.
export PYTHONDONTWRITEBYTECODE=1

BBD_LOG_MAX=262144
_BBD_TOKEN=""
_BBD_CLEANUP=""

# Every launcher exits 0 on every path, including a crash: a bug here must never turn
# into a blocked turn or an error the tenant sees. Exit 2 (block) is never used.
bbd_fail_safe() {
  set -E
  trap 'bbd_log "unhandled failure in ${BASH_SOURCE[0]##*/} at line $LINENO"' ERR
  trap '_bbd_exit' EXIT
  trap 'exit 0' INT TERM HUP
}

# shellcheck disable=SC2329  # invoked by the EXIT trap
_bbd_exit() {
  [ -n "$_BBD_CLEANUP" ] && rm -f "$_BBD_CLEANUP" 2>/dev/null
  exit 0
}

# bbd_cleanup FILE: removed when the launcher exits (the saved hook input, which
# carries the tenant's prompt text).
bbd_cleanup() { _BBD_CLEANUP=$1; }

# A hook can fire after its directory was deleted; git and python fail there.
bbd_recover_cwd() {
  if ! pwd -P >/dev/null 2>&1 || [ ! -d "${PWD:-/nonexistent}" ]; then
    cd "$HOME" 2>/dev/null || cd / || return 0
  fi
}

# Where the session ran, as the store records it.
bbd_where() {
  if [ "${CLAUDE_CODE_REMOTE:-}" = true ]; then
    echo cloud
  elif [ -n "${CLAUDE_CODE_BRIDGE_SESSION_ID:-}" ]; then
    echo remote-control
  else
    echo desktop
  fi
}

bbd_paths() {
  BBD_CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
  BBD_BASE=$BBD_CFG/bbd-apparatus
  BBD_ENV_FILE=$BBD_BASE/tenant.env
  BBD_LOG=$BBD_BASE/state/launcher.log
}

# bbd_log MESSAGE: append to launcher.log, never to stdout or stderr. The token's
# value, and anything token-shaped, is masked, so the log can be read or shared
# without carrying the credential. Writes nothing before bbd_state_dirs, so a
# repository the gate refused never gets a state directory.
bbd_log() {
  [ -n "${BBD_LOG:-}" ] && [ -d "${BBD_LOG%/*}" ] || return 0
  local msg="$*"
  if [ -n "$_BBD_TOKEN" ]; then
    msg=${msg//"$_BBD_TOKEN"/[token]}
  fi
  if [ -f "$BBD_LOG" ] && [ "$(wc -c <"$BBD_LOG" 2>/dev/null || echo 0)" -gt "$BBD_LOG_MAX" ]; then
    mv -f "$BBD_LOG" "$BBD_LOG.1" 2>/dev/null
  fi
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" \
    | sed -E 's/bbdt_[A-Za-z0-9]{40}/[token]/g' >>"$BBD_LOG" 2>/dev/null
  return 0
}

# bbd_tenant_env FILE: parse tenant.env as KEY=VALUE text. It is never sourced, so a
# line in it can never execute. Sets BBD_ENV_TENANT, BBD_ENV_CHANNEL and
# BBD_ENV_INGEST_URL; the token goes only into _BBD_TOKEN, which is never exported,
# so no child process inherits it.
bbd_tenant_env() {
  local file=$1 line key val
  BBD_ENV_TENANT=""
  BBD_ENV_CHANNEL=""
  BBD_ENV_INGEST_URL=""
  _BBD_TOKEN=""
  [ -f "$file" ] && [ -r "$file" ] || return 0
  # A file this large is not one the installer wrote; reading it is not worth it.
  [ "$(wc -c <"$file" 2>/dev/null || echo 0)" -le 65536 ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; *=*) ;; *) continue ;; esac
    key=${line%%=*}
    val=${line#*=}
    key=${key#export }
    key=${key// /}
    case "$val" in \"*\") val=${val#\"}; val=${val%\"} ;; \'*\') val=${val#\'}; val=${val%\'} ;; esac
    case "$key" in
      BBD_TENANT) BBD_ENV_TENANT=$val ;;
      BBD_CHANNEL) BBD_ENV_CHANNEL=$val ;;
      BBD_INGEST_URL) BBD_ENV_INGEST_URL=$val ;;
      BBD_TOKEN) _BBD_TOKEN=$val ;;
    esac
  done <"$file"
  return 0
}

# bbd_project_root INPUT-FILE [EVENT]: prints the work tree's top level, from
# CLAUDE_PROJECT_DIR, else the hook JSON's cwd, and never from the shell's own
# directory, which can belong to another repository; except for a skill, which the
# session's own Bash tool runs from the project with no hook JSON. A worktree counts:
# git is asked, because a worktree's .git is a file, not a directory.
bbd_project_root() {
  local input=$1 event=${2:-} dir
  dir=${CLAUDE_PROJECT_DIR:-}
  if [ -z "$dir" ] && [ "$event" = skill ]; then
    dir=$PWD
  elif [ -z "$dir" ] && [ -f "$input" ]; then
    dir=$(python3 "$BBD_CHECKOUT/lib/hookio.py" field "$input" cwd 2>/dev/null)
  fi
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  [ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || return 1
  git -C "$dir" rev-parse --show-toplevel 2>/dev/null
}

# bbd_marker ROOT: parse ROOT/.apparatus/vault.json. Returns 1 unless it parses and
# names a tenant. Sets BBD_MARKER_TENANT, BBD_MARKER_CHANNEL, BBD_MARKER_RULES.
bbd_marker() {
  local file=$1/.apparatus/vault.json out
  BBD_MARKER_TENANT=""
  BBD_MARKER_CHANNEL=""
  BBD_MARKER_RULES=""
  [ -f "$file" ] || return 1
  out=$(python3 -c '
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
rules = doc.get("rules")
# The rules file is read from inside the repository only.
if not (isinstance(rules, str) and re.fullmatch(r"[A-Za-z0-9._/-]{1,200}", rules)
        and not rules.startswith("/") and ".." not in rules.split("/")):
    rules = ""
print(doc["tenant"])
print(doc["channel"] if word(doc.get("channel")) else "")
print(rules)
' "$file" 2>/dev/null)
  BBD_MARKER_TENANT=$(printf '%s\n' "$out" | sed -n 1p)
  BBD_MARKER_CHANNEL=$(printf '%s\n' "$out" | sed -n 2p)
  BBD_MARKER_RULES=$(printf '%s\n' "$out" | sed -n 3p)
  [ -n "$BBD_MARKER_TENANT" ]
}

# bbd_gate DELIVERY INPUT-FILE [EVENT]: returns 0 only when this event is ours to act on, the
# same rule as the bootstrap's (docs/launcher-contract.md sections 3 and 4). Sets
# BBD_PROJECT_ROOT, BBD_TENANT, BBD_CHANNEL, BBD_WHERE and BBD_RULES (the rules file
# the marker names, relative to the root; empty when it names none).
bbd_gate() {
  local delivery=$1 input=$2 event=${3:-}
  bbd_paths
  [ -z "${BBD_NESTED:-}" ] || return 1
  case "$delivery" in plugin|repo) ;; *) return 1 ;; esac
  BBD_PROJECT_ROOT=$(bbd_project_root "$input" "$event") || return 1
  [ -n "$BBD_PROJECT_ROOT" ] || return 1
  bbd_marker "$BBD_PROJECT_ROOT" || return 1
  bbd_tenant_env "$BBD_ENV_FILE"
  # A home that holds a token belongs to one tenant.
  if [ -e "$BBD_ENV_FILE" ] && [ "$BBD_ENV_TENANT" != "$BBD_MARKER_TENANT" ]; then
    return 1
  fi
  # The plugin copy handles a home that has tenant.env, except in the cloud, and
  # except for a skill, which runs once from the one Bash call that invoked its stub.
  if [ "$delivery" = repo ] && [ "$event" != skill ] && [ "${CLAUDE_CODE_REMOTE:-}" != true ] && [ -e "$BBD_ENV_FILE" ]; then
    return 1
  fi
  BBD_TENANT=$BBD_MARKER_TENANT
  BBD_RULES=$BBD_MARKER_RULES
  BBD_CHANNEL=${BBD_ENV_CHANNEL:-$BBD_MARKER_CHANNEL}
  case "$BBD_CHANNEL" in ''|-*|*[!A-Za-z0-9._-]*) BBD_CHANNEL=stable ;; esac
  BBD_WHERE=$(bbd_where)
  return 0
}

# The state and queue directories, 0700: they hold transcript pointers, the ledger
# and the log, which are the tenant's alone even on a shared machine.
bbd_state_dirs() {
  bbd_paths
  umask 077
  mkdir -p "$BBD_BASE/state" "$BBD_BASE/queue" 2>/dev/null || return 1
  chmod 700 "$BBD_BASE" "$BBD_BASE/state" "$BBD_BASE/queue" 2>/dev/null
  return 0
}

# bbd_lock DIR STALE-SECONDS: a mkdir lock, atomic on every filesystem. Returns 1 at
# once if a live holder has it; a holder older than STALE-SECONDS is taken to be dead.
bbd_lock() {
  local lock=$1 stale=$2 now at
  now=$(date +%s)
  if ! mkdir "$lock" 2>/dev/null; then
    at=$(cat "$lock/at" 2>/dev/null || true)
    case "$at" in
      ''|*[!0-9]*) [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] || return 1 ;;
      *) [ $((now - at)) -ge "$stale" ] || return 1 ;;
    esac
    rm -rf "$lock" 2>/dev/null
    mkdir "$lock" 2>/dev/null || return 1
  fi
  printf '%s\n' "$now" >"$lock/at"
  return 0
}

bbd_unlock() { rm -rf "$1" 2>/dev/null; return 0; }

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

# bbd_bounded SECONDS CMD...: run a command, it and everything under it killed after
# SECONDS (macOS has no `timeout`). Its stdout is passed through; the watcher holds no
# stdout, so a caller reading the output is not kept waiting by it, and it kills its
# own sleep when stopped, so nothing of it outlives the run.
bbd_bounded() {
  local secs=$1 pid watcher rc
  shift
  "$@" </dev/null &
  pid=$!
  (
    trap 'kill "$s" 2>/dev/null; exit 0' TERM
    sleep "$secs" & s=$!
    wait "$s" 2>/dev/null || exit 0
    bbd_kill_tree "$pid" TERM
    sleep 1 & s=$!
    wait "$s" 2>/dev/null || exit 0
    bbd_kill_tree "$pid" KILL
  ) </dev/null >/dev/null 2>&1 &
  watcher=$!
  if wait "$pid"; then rc=0; else rc=$?; fi
  kill -TERM "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  return "$rc"
}
