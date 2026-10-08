#!/usr/bin/env bash
# stop-ship (Stop; asynchronous in the plugin, synchronous in a cloud session's
# repository copy): the one step that sends a transcript off this machine
# (docs/launcher-contract.md section 10). In order:
#   1. queue a pointer to this session's transcript, so nothing below can lose it;
#   2. prove the redactor, once per checkout: a failed self-test sends nothing;
#   3. for this session first, then the oldest queued ones (at most 5): render (which
#      redacts, twice), then post-scan the rendered copy; a hit is quarantined and
#      never sent;
#   4. choose the door: a token means the HTTP post to the store (or, with no store
#      address yet, nothing leaves and the pointers wait); no token means the
#      repository's captures branch.
# Nothing here writes to stdout: a Stop hook's stdout is read as a decision.
# shellcheck source=../lib/common.sh
. "$BBD_CHECKOUT/launcher/lib/common.sh" || exit 0
exec >>"$BBD_LOG" 2>&1

ship_py="$BBD_CHECKOUT/lib/ship.py"
apparatus="$BBD_CHECKOUT/bin/apparatus"
queue=$BBD_BASE/queue
state=$BBD_BASE/state
outbox=$state/outbox
quarantine=$BBD_BASE/quarantine
env_file=$BBD_BASE/tenant.env
lock=$state/ship.lock
DRAIN_MAX=5
# The bounds follow the delivery. The plugin runs this step asynchronously, with no
# harness timeout, so it keeps its own. A tenant repository's copy (a cloud session)
# runs synchronously under the harness's 60-second timeout, so its whole step must
# end well inside that, or the harness kills it first.
#   SHIP_BOUND    the whole step is killed after this many seconds
#   SHIP_BUDGET   no old entry's render starts unless its bounds fit before this
#   PUSH_ROOM     no old entry's send starts unless this much time is left
# The firing session is rendered and sent first, on its own, before any old entry is
# touched. Old entries then go only while their work fits, so none can push the
# firing session past the kill. A kill loses nothing: every queue write is an atomic
# rename, and the pointers wait.
if [ "${BBD_DELIVERY:-}" = repo ]; then
  SHIP_BOUND=50
  SHIP_BUDGET=30
  RENDER_BOUND=15
  SCAN_BOUND=5
  SELFTEST_BOUND=20
  PUSH_ROOM=15
else
  SHIP_BOUND=120
  SHIP_BUDGET=90
  RENDER_BOUND=30
  SCAN_BOUND=15
  SELFTEST_BOUND=60
  PUSH_ROOM=30
fi
SHIP_MARGIN=5

ship() { python3 "$ship_py" "$@"; }

# 1. The pointer first.
current=$(ship queue-pointer "$queue" "$BBD_INPUT" "$BBD_WHERE" "$BBD_PROJECT_ROOT" "$BBD_TENANT")

# One ship step at a time per home: two draining one queue would send a session
# twice. A holder older than five minutes, past every bound below, is dead.
# The handoff is closed on both sides, so no turn waits for a later Stop:
#   - A run that finds the lock held waits for it, up to its own cutoff. Its pointer
#     is already queued, so waiting costs nothing, and when it gets the lock it
#     ships its own session first. Only if it reaches its cutoff while still
#     waiting does its turn wait for the next Stop in this home.
#   - The holder keeps reading the queue after every pass and lets go only when a
#     read finds nothing new (below). Anything queued after that last read belongs
#     to a Stop that is now waiting on the lock, and ships next.
locked=""
while [ $((SECONDS + SHIP_MARGIN)) -lt "$SHIP_BOUND" ]; do
  if bbd_lock "$lock" 300; then locked=1; break; fi
  sleep 0.5
done
if [ -z "$locked" ]; then
  bbd_log "stop-ship: the lock stayed held to this run's cutoff; $current waits for the next Stop"
  exit 0
fi
# Every pointer write queued when this run began, and every one it takes, so its
# loop reads only what arrived after: the five-per-firing cap on older entries holds.
handled=$state/ship.handled
: >"$handled"
ship snapshot "$handled" "$queue"
start_ns=$(ship now-ns)
umask 077
mkdir -p "$outbox" "$quarantine" 2>/dev/null
chmod 700 "$outbox" "$quarantine" 2>/dev/null
# The lock and every rendered copy go with this run, however it ends: a rendered
# copy is redacted, but it is still the tenant's session and is never kept here.
trap 'rm -f "$outbox"/*.md "$outbox"/*.nul "$handled" 2>/dev/null; bbd_unlock "$lock"; exit 0' EXIT
trap 'exit 0' INT TERM HUP

# The function runs only through bbd_bounded below. Older shellcheck (the Ubuntu
# runner's) calls its body unreachable as SC2317, newer as SC2329.
# shellcheck disable=SC2317,SC2329
ship_step() {
  local door drain pass sha ok_file redactor_sha
  # 2. The self-test, once per checkout commit. The pass file also holds the sha256
  # of the redactor it proved, so a redactor edited in place after the pass is tested
  # again. A checkout that is not a repository has no commit to key on, so it is
  # tested on every run.
  sha=$(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git --git-dir="$BBD_CHECKOUT/.git" \
    rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)
  redactor_sha=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' \
    "$BBD_CHECKOUT/lib/redact.py" 2>/dev/null)
  ok_file=""
  [ -n "$sha" ] && ok_file=$state/selftest-$sha.ok
  if [ -z "$ok_file" ] || [ -z "$redactor_sha" ] || [ "$(cat "$ok_file" 2>/dev/null)" != "$redactor_sha" ]; then
    # Its output names the fake secrets it tests with; only the verdict is logged.
    if bbd_bounded "$SELFTEST_BOUND" python3 "$apparatus" selftest >/dev/null 2>&1; then
      [ -n "$ok_file" ] && printf '%s\n' "$redactor_sha" >"$ok_file"
      bbd_log "stop-ship: redactor self-test passed for ${sha:-an untracked checkout}"
    else
      bbd_log "stop-ship: redactor self-test FAILED for ${sha:-an untracked checkout}; nothing is sent, the queue is kept"
      ship notice "$state" "selftest-failed:${sha:-unknown}" \
        "This machine's copy of the redactor failed its own check, so no session was sent. They are kept here and go out once it passes."
      ship status "$state" selftest-failed "$queue"
      return 0
    fi
  fi

  # 3. The door decides which queued entries this firing may take. The HTTP door
  # posts under this home's one tenant.env, and a home with a token acts only in
  # that tenant's repositories, so it drains the whole home queue. The captures door
  # writes into this session's own repository, so it takes only the entries queued
  # for this repository and this tenant; another project's wait for its own Stop.
  door=$(ship door "$env_file")
  scope=()
  [ "$door" = captures ] && scope=("$BBD_PROJECT_ROOT" "$BBD_TENANT")

  # The first pass: this session, then the oldest queued. Then the holder loops
  # until quiet: after every pass it reads the queue again for pointer writes made
  # since it began that it has not taken (a later turn of a session, another
  # session), newest first, and lets go of the lock only when a read finds nothing, or
  # when no render could start inside the budget any more. Every pass has the same
  # render allowance, the budget; the push room is held back separately.
  drain=$(ship drain-list "$queue" "$current" "$DRAIN_MAX" ${scope[@]+"${scope[@]}"})
  ship_pass "$current" "$drain" "$SHIP_BUDGET"
  pass=1
  while [ $((SECONDS + RENDER_BOUND + SCAN_BOUND)) -le "$SHIP_BUDGET" ]; do
    drain=$(ship drain-list "$queue" - "$DRAIN_MAX" ${scope[@]+"${scope[@]}"} --handled "$handled")
    if [ -z "$drain" ]; then
      bbd_log "stop-ship: queue quiet after $pass pass(es); letting go of the lock"
      return 0
    fi
    ship_pass "" "$drain" "$SHIP_BUDGET"
    pass=$((pass + 1))
  done
  bbd_log "stop-ship: budget spent after $pass pass(es); what is left goes with the next run, which may already be waiting on the lock"
}

# ship_pass FIRST DRAIN LIMIT: render, post-scan and send the sessions in DRAIN (one
# id per line). FIRST is the firing session: it is always tried, it is sent on its
# own as soon as it is ready, before any other entry is rendered, and a missing or
# empty transcript is not a loss for it. With an empty FIRST, an entry queued after
# this run began is live in that sense too (its session ended a turn moments ago).
# Every entry but FIRST is under LIMIT: its render starts only if its bounds fit
# before LIMIT seconds.
# shellcheck disable=SC2317,SC2329
ship_pass() {
  local first=$1 drain=$2 limit=$3 live sid at transcript out rc hit stamp outcome=""
  ready=()
  stamps=()
  live=$first
  if [ -z "$first" ]; then
    for sid in $drain; do
      at=$(ship get "$queue" "$sid" queued_at)
      case "$at" in ''|*[!0-9]*) ;; *) [ "$at" -gt "$start_ns" ] && live="$live $sid" ;; esac
    done
  fi
  for sid in $drain; do
    # The limit holds back every entry but the firing session, which is always
    # tried, and comes first.
    if [ "$sid" != "$first" ] && [ $((SECONDS + RENDER_BOUND + SCAN_BOUND)) -gt "$limit" ]; then
      bbd_log "stop-ship: out of time; the rest wait for the next turn"
      break
    fi
    # Taken before the transcript is read: if a later turn refreshes the pointer
    # while this copy is in flight, the entry is not dropped and that turn goes too.
    stamp=$(ship stamp "$queue" "$sid")
    # Taken now, so the loop's next read skips this write of the pointer whatever
    # happens to it below; a later turn rewrites queued_at and is read again.
    ship mark-handled "$handled" "$queue" "$sid"
    transcript=$(ship get "$queue" "$sid" transcript_path)
    if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
      # The firing session's transcript may not be on disk yet; any other session's
      # is gone for good, and that loss is said once.
      case " $live " in *" $sid "*) ;; *) ship lost "$queue" "$state" "$sid" "$stamp" ;; esac
      continue
    fi
    out=$outbox/$sid.md
    if bbd_bounded "$RENDER_BOUND" python3 "$apparatus" render "$transcript" >"$out"; then rc=0; else rc=$?; fi
    if [ "$rc" -eq 3 ]; then
      # Nothing to render yet. The firing session may still gain turns; an old one
      # never will.
      case " $live " in *" $sid "*) ;; *) ship drop "$queue" "$sid" "$stamp" ;; esac
      rm -f "$out"
      continue
    elif [ "$rc" -ne 0 ]; then
      bbd_log "stop-ship: render of $sid failed ($rc); kept"
      rm -f "$out"
      continue
    fi
    # A NUL byte in the rendered copy (a tool printed a binary file) would make the
    # post-scan skip the whole file as binary, so NUL bytes are removed before it
    # scans. Removing one can only join text into a longer shape, never hide one.
    if ! { tr -d '\000' <"$out" >"$out.nul" && mv -f "$out.nul" "$out"; }; then
      bbd_log "stop-ship: could not prepare $sid for the post-scan; kept"
      rm -f "$out" "$out.nul"
      continue
    fi
    # A hit exits 1 and prints the file's name; a crash also exits 1 but prints
    # nothing on stdout, and is kept for the next turn rather than taken for a hit.
    if hit=$(bbd_bounded "$SCAN_BOUND" python3 "$apparatus" postscan --quarantine "$quarantine" "$out"); then rc=0; else rc=$?; fi
    if [ "$rc" -eq 1 ] && [ -n "$hit" ]; then
      # A secret shape survived redaction. The copy is in quarantine for the tenant to
      # look at, and the session is not sent; a later turn of it is checked again.
      bbd_log "stop-ship: post-scan hit in $sid; quarantined, not sent"
      ship notice "$state" "quarantine:$sid" \
        "One session held something that looked like a password or key after cleaning, so it was kept on this machine and not sent."
      ship drop "$queue" "$sid" "$stamp"
      rm -f "$out"
      continue
    elif [ "$rc" -ne 0 ]; then
      bbd_log "stop-ship: post-scan of $sid could not run ($rc); kept"
      rm -f "$out"
      continue
    fi
    ready+=("$sid")
    stamps+=("$stamp")
    # The firing session goes out on its own the moment it is ready, before any old
    # entry is rendered: in a cloud session the harness kills this step at 60
    # seconds and the machine's queue is lost when it is reclaimed, so its turn must
    # not wait behind entries that are slow or failing.
    if [ "$sid" = "$first" ]; then
      ship_send "$first" || outcome=kept
      [ -n "$outcome" ] || outcome=shipped
      ready=()
      stamps=()
    fi
  done
  if [ "${#ready[@]}" -gt 0 ]; then
    if ship_send "$first"; then [ -n "$outcome" ] || outcome=shipped; else outcome=kept; fi
  fi
  case "$door" in post|captures) [ -z "$outcome" ] || ship status "$state" "$outcome" "$queue" ;; esac
  return 0
}

# ship_send FIRST: send what is in ready[] and stamps[] through the door. FIRST is
# always sent; any other entry is sent only if its send can finish before the step is
# killed. Returns 1 if anything was not stored.
# shellcheck disable=SC2317,SC2329
ship_send() {
  local first=$1 sid i post_timeout ok=0 args=()
  case "$door" in
    post)
      post_timeout=$(ship post-timeout)
      case "$post_timeout" in ''|*[!0-9]*) post_timeout=20 ;; esac
      i=0
      while [ "$i" -lt "${#ready[@]}" ]; do
        sid=${ready[$i]}
        if [ "$sid" != "$first" ] \
            && [ $((SECONDS + post_timeout + SHIP_MARGIN)) -gt "$SHIP_BOUND" ]; then
          bbd_log "stop-ship: out of time to post; the rest wait for the next turn"
          return 1
        fi
        [ "$(ship post "$env_file" "$state" "$queue" "$sid" "${stamps[$i]}" "$outbox/$sid.md" \
          "$BBD_CHECKOUT/lib/redact.py")" = stored ] || ok=1
        i=$((i + 1))
      done
      return "$ok"
      ;;
    not-connected)
      # The store does not exist yet: the witnesses above ran, the pointers wait, and
      # the tenant is told once, except the maintainers' own tenant on the next
      # channel while the store is being built.
      ship status "$state" store-not-connected "$queue"
      if [ "$BBD_CHANNEL" != next ]; then
        ship notice "$state" store-not-connected \
          "Your sessions are being kept on this machine until your store is connected; nothing is lost."
      fi
      return 0
      ;;
    *)
      # One push for the batch. A batch without the firing session starts only if a
      # push still fits before the kill.
      case " ${ready[*]} " in
        *" $first "*) ;;
        *) if [ $((SECONDS + PUSH_ROOM + SHIP_MARGIN)) -gt "$SHIP_BOUND" ]; then
             bbd_log "stop-ship: out of time to push; the rest wait for the next turn"
             return 1
           fi ;;
      esac
      i=0
      while [ "$i" -lt "${#ready[@]}" ]; do
        args+=("${ready[$i]}" "${stamps[$i]}" "$outbox/${ready[$i]}.md")
        i=$((i + 1))
      done
      [ "$(ship captures "$BBD_PROJECT_ROOT" "$queue" "$state" "${args[@]}")" = stored ]
      ;;
  esac
}

# The bound runs to this run's own cutoff: a run that waited for the lock has that
# much less time, and every budget inside reads the same clock (SECONDS).
remaining=$((SHIP_BOUND - SECONDS))
bbd_bounded "$remaining" ship_step || bbd_log "stop-ship: the ship step failed or reached its cutoff"
exit 0
