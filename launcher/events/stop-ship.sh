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
# The plugin runs this step asynchronously with no harness timeout, so it keeps its
# own: the whole step is killed after SHIP_BOUND seconds. The firing session is
# always rendered and sent first. An old entry is rendered only if its render and
# post-scan bounds both fit before SHIP_BUDGET, and posted only if the post's own
# timeout fits before SHIP_BOUND with a margin, so no old entry's work is ever cut
# off by the kill, and none can push the firing session past it. A kill loses
# nothing: every queue write is an atomic rename, and the pointers wait.
SHIP_BOUND=120
SHIP_BUDGET=90
SHIP_MARGIN=5
RENDER_BOUND=30
SCAN_BOUND=15

ship() { python3 "$ship_py" "$@"; }

# 1. The pointer first.
current=$(ship queue-pointer "$queue" "$BBD_INPUT" "$BBD_WHERE")

# One ship step at a time per home: two draining one queue would send a session
# twice. A run that finds the lock held leaves its pointer for the holder or the
# next turn. A holder older than five minutes, past every bound below, is dead.
bbd_lock "$lock" 300 || exit 0
umask 077
mkdir -p "$outbox" "$quarantine" 2>/dev/null
chmod 700 "$outbox" "$quarantine" 2>/dev/null
# The lock and every rendered copy go with this run, however it ends: a rendered
# copy is redacted, but it is still the tenant's session and is never kept here.
trap 'rm -f "$outbox"/*.md "$outbox"/*.nul 2>/dev/null; bbd_unlock "$lock"; exit 0' EXIT
trap 'exit 0' INT TERM HUP

# The function runs only through bbd_bounded below. Older shellcheck (the Ubuntu
# runner's) calls its body unreachable as SC2317, newer as SC2329.
# shellcheck disable=SC2317,SC2329
ship_step() {
  local sha ok_file redactor_sha sid transcript out rc hit stamp result i post_timeout ready=() stamps=() args=()
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
    if bbd_bounded 60 python3 "$apparatus" selftest >/dev/null 2>&1; then
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

  # 3. Render and post-scan each session to try.
  for sid in $(ship drain-list "$queue" "$current" "$DRAIN_MAX"); do
    # The budget holds back old entries only: the firing session is always tried,
    # and comes first.
    if [ "$sid" != "$current" ] && [ $((SECONDS + RENDER_BOUND + SCAN_BOUND)) -gt "$SHIP_BUDGET" ]; then
      bbd_log "stop-ship: out of time; the rest wait for the next turn"
      break
    fi
    # Taken before the transcript is read: if a later turn refreshes the pointer
    # while this copy is in flight, the entry is not dropped and that turn goes too.
    stamp=$(ship stamp "$queue" "$sid")
    transcript=$(ship get "$queue" "$sid" transcript_path)
    if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
      # The firing session's transcript may not be on disk yet; any other session's
      # is gone for good, and that loss is said once.
      [ "$sid" = "$current" ] || ship lost "$queue" "$state" "$sid" "$stamp"
      continue
    fi
    out=$outbox/$sid.md
    if bbd_bounded "$RENDER_BOUND" python3 "$apparatus" render "$transcript" >"$out"; then rc=0; else rc=$?; fi
    if [ "$rc" -eq 3 ]; then
      # Nothing to render yet. The firing session may still gain turns; an old one
      # never will.
      [ "$sid" = "$current" ] || ship drop "$queue" "$sid" "$stamp"
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
  done
  [ "${#ready[@]}" -gt 0 ] || return 0

  # 4. The door.
  case "$(ship door "$env_file")" in
    post)
      result=shipped
      post_timeout=$(ship post-timeout)
      case "$post_timeout" in ''|*[!0-9]*) post_timeout=20 ;; esac
      i=0
      while [ "$i" -lt "${#ready[@]}" ]; do
        sid=${ready[$i]}
        # The firing session is first and always posted; an old entry's post starts
        # only if it can finish before the step is killed.
        if [ "$sid" != "$current" ] \
            && [ $((SECONDS + post_timeout + SHIP_MARGIN)) -gt "$SHIP_BOUND" ]; then
          bbd_log "stop-ship: out of time to post; the rest wait for the next turn"
          result=kept
          break
        fi
        [ "$(ship post "$env_file" "$state" "$queue" "$sid" "${stamps[$i]}" "$outbox/$sid.md" \
          "$BBD_CHECKOUT/lib/redact.py")" = stored ] || result=kept
        i=$((i + 1))
      done
      ship status "$state" "$result" "$queue"
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
      ;;
    *)
      i=0
      while [ "$i" -lt "${#ready[@]}" ]; do
        args+=("${ready[$i]}" "${stamps[$i]}" "$outbox/${ready[$i]}.md")
        i=$((i + 1))
      done
      if [ "$(ship captures "$BBD_PROJECT_ROOT" "$queue" "$state" "${args[@]}")" = stored ]; then
        ship status "$state" shipped "$queue"
      else
        ship status "$state" kept "$queue"
      fi
      ;;
  esac
}

bbd_bounded "$SHIP_BOUND" ship_step || bbd_log "stop-ship: the ship step failed or ran past ${SHIP_BOUND}s"
exit 0
