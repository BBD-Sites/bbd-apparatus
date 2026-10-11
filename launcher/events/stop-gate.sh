#!/usr/bin/env bash
# stop-gate (Stop, synchronous): the read-draft step, the one place that may print a
# block decision (docs/launcher-contract.md section 13). The reply the model is about
# to leave on screen is read by an independent reader on the person's own plan
# (reader/reader.py, one headless `claude -p`), and when the reader finds something,
# the turn is held once with the findings as the reason, so the model sends a
# corrected reply. In order:
#   1. The draft is last_assistant_message. The reply is read for where each pending
#      ask stands, by its number (lib/ledger.py account), and the ask ledger moves to
#      match, on every pass. A reply of 50 prose words or more that leaves an ask out
#      is held once, with the missing asks handed back (design D23).
#   2. stop_hook_active: this Stop is the second pass of the turn, after a block; the
#      reply goes through whatever the reader would say.
#   3. Under 50 prose words there is nothing to read. The rules file the marker names
#      is read against when it exists; a repository with none is read against the
#      reply contract alone.
#   4. A receipt for this exact draft (lib/receipt.py) means it was read already.
#   5. The reading level (lib/readability.py, pure python): a reply above the fifth-grade
#      ceiling is held once with the hard sentences quoted, before the reader is paid for
#      (design D24).
#   6. The reader runs under a bound (60 seconds; BBD_READER_BOUND overrides, 1 to 600)
#      with the reply contract, the rules file, the session's open asks and the draft.
#   7. A verdict of fix becomes one block, at most once per turn (lib/loopguard.py,
#      keyed by the session and prompt_id, else the draft's hash). A verdict of send,
#      and an answer out of shape, lets the reply through. When the reader itself
#      could not run (no `claude`, a timeout, a non-zero exit): on a desktop home the
#      reply goes through, logged; in a cloud session the same one block hands the
#      model the assembled prompt to give to a reader through the Agent tool.
#   8. A receipt is written for every read and every attempt, never for a skip.
# Stdout here becomes the Stop decision, so nothing but that one object is printed.
# shellcheck source=../lib/common.sh
. "$BBD_CHECKOUT/launcher/lib/common.sh" || exit 0
trap 'exit 0' ERR INT TERM HUP

BOUND=60
case "${BBD_READER_BOUND:-}" in
  ''|*[!0-9]*) ;;
  *) if [ "$BBD_READER_BOUND" -ge 1 ] && [ "$BBD_READER_BOUND" -le 600 ]; then BOUND=$BBD_READER_BOUND; fi ;;
esac
receipts=$BBD_BASE/state/reader
guard=$BBD_BASE/state/loopguard
ledger_dir=$BBD_BASE/state/ledger
umask 077

draft=""
asks=""
result=""
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() { rm -f "$draft" "$asks" "$result" 2>/dev/null; exit 0; }
trap 'cleanup' EXIT

field() { python3 "$BBD_CHECKOUT/lib/hookio.py" field "$BBD_INPUT" "$1" 2>>"$BBD_LOG"; }
# jget FILE KEY: one field of the reader's JSON answer.
jget() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {}
v = d.get(sys.argv[2], "") if isinstance(d, dict) else ""
sys.stdout.write(str(v) if not isinstance(v, bool) else ("1" if v else "0"))' "$1" "$2" 2>>"$BBD_LOG"
}

# 1. The draft, and where the person's asks stand. The asks the reply has to answer are
# taken first (the reader is given them below), then the reply is read for each pending
# ask by its number, marked done, running or waiting (lib/ledger.py account), and the
# ledger moves to match on every pass, the second one too. A reply of fifty prose words
# or more that leaves an ask out is held once with the missing asks handed back
# (design D23); a shorter one is an acknowledgement and is not.
draft=$(mktemp "$BBD_BASE/state/draft.XXXXXX" 2>/dev/null) || exit 0
python3 "$BBD_CHECKOUT/lib/hookio.py" text "$BBD_INPUT" last_assistant_message >"$draft" 2>>"$BBD_LOG"
sid=$(field session_id)
pid=$(field prompt_id)
asks=$(mktemp "$BBD_BASE/state/asks.XXXXXX" 2>/dev/null) || exit 0
words=$(python3 "$BBD_CHECKOUT/reader/reader.py" words "$draft" 2>>"$BBD_LOG")
case "$words" in ''|*[!0-9]*) words=0 ;; esac
missing=""
if [ -n "$sid" ]; then
  python3 "$BBD_CHECKOUT/lib/ledger.py" open "$ledger_dir" "$sid" >"$asks" 2>>"$BBD_LOG"
  missing=$(python3 "$BBD_CHECKOUT/lib/ledger.py" account "$ledger_dir" "$sid" "$draft" 2>>"$BBD_LOG")
fi

# 2. The second pass of this turn, after a block: the reply goes through.
if python3 "$BBD_CHECKOUT/lib/hookio.py" flag "$BBD_INPUT" stop_hook_active 2>>"$BBD_LOG"; then
  bbd_log "stop-gate: the second pass of this turn; the reply goes through"
  exit 0
fi
turn=$pid
[ -n "$turn" ] || turn=$(python3 "$BBD_CHECKOUT/lib/receipt.py" hash "$draft" 2>>"$BBD_LOG")
if [ -n "$missing" ] && [ "$words" -ge 50 ]; then
  if python3 "$BBD_CHECKOUT/lib/loopguard.py" allow "$guard" "$sid" "$turn" 2>>"$BBD_LOG"; then
    {
      printf 'Your reply does not say where these asks stand. Send it again with each one under its own number, marked done, running or waiting:\n\n'
      printf '%s\n' "$missing" | cut -c1-240 | head -n 20
    } | python3 "$BBD_CHECKOUT/lib/hookio.py" block 2>>"$BBD_LOG"
    bbd_log "stop-gate: held once; $(printf '%s\n' "$missing" | wc -l | tr -d ' ') ask(s) left out of the reply"
    exit 0
  fi
  bbd_log "stop-gate: asks left out, but a block already happened this turn; the reply goes through"
fi

# 3. Whether there is anything to read it against.
if [ "$words" -lt 50 ]; then
  bbd_log "stop-gate: $words prose words; nothing to read"
  exit 0
fi
# The rules file the marker names, when it exists: a new tenant's repository names
# one and ships none, and their replies are read all the same, against the reply
# contract alone (the reader is told the rules are "(none)").
rules=/nonexistent
if [ -n "${BBD_RULES:-}" ] && [ -s "$BBD_PROJECT_ROOT/$BBD_RULES" ]; then
  rules=$BBD_PROJECT_ROOT/$BBD_RULES
fi

# 4. Read once.
if python3 "$BBD_CHECKOUT/lib/receipt.py" exists "$receipts" "$draft" 2>>"$BBD_LOG"; then
  bbd_log "stop-gate: this draft was read already; the reply goes through"
  exit 0
fi

# 5. The reading level, measured before anything is paid for (design D24). The grader
# ships here (lib/readability.py: pure python, no network); a reply above the ceiling
# is held once with the sentences a reader would stumble on quoted, and the reply
# that follows is the second pass and goes through. A deterministic hold, so the
# reader is not run on a reply that is about to be rewritten. It is a flag, never a
# target: the message says to cut the idea or say it plainly, not to chop it up.
hard=$(python3 "$BBD_CHECKOUT/lib/readability.py" check "$draft" 2>>"$BBD_LOG")
if [ -n "$hard" ]; then
  if python3 "$BBD_CHECKOUT/lib/loopguard.py" allow "$guard" "$sid" "$turn" 2>>"$BBD_LOG"; then
    printf '%s\n' "$hard" | awk -F'\t' '
      NR == 1 {
        printf "This reply is harder to read than the person can follow: it grades at %s, and the ceiling is %s. ", $1, $2
        printf "These are the sentences a reader would stumble on. Say each one in plainer words, or cut the idea it carries. "
        printf "Do not chop sentences into fragments, and do not add or drop a fact. Then send the reply again.\n\n"
        next
      }
      { printf "- \"%s\" (grade %s)\n", $2, $1 }' | python3 "$BBD_CHECKOUT/lib/hookio.py" block 2>>"$BBD_LOG"
    bbd_log "stop-gate: held once for reading level; $(( $(printf '%s\n' "$hard" | wc -l) - 1 )) sentence(s) quoted"
    exit 0
  fi
  bbd_log "stop-gate: above the reading ceiling, but a block already happened this turn; the reply goes through"
fi

stop_reason=$(field stop_reason)

# 6. The reader.
result=$(mktemp "$BBD_BASE/state/verdict.XXXXXX" 2>/dev/null) || exit 0
python3 "$BBD_CHECKOUT/reader/reader.py" read \
  --draft "$draft" --contract "$BBD_CHECKOUT/text/reply-contract.md" \
  --rules "$rules" --asks "$asks" --kind reply --bound "$BOUND" >"$result" 2>>"$BBD_LOG"
status=$(jget "$result" status)
verdict=$(jget "$result" verdict)
count=$(jget "$result" count)
elapsed=$(jget "$result" elapsed)
[ -n "$status" ] || status=failed
[ "$verdict" = fix ] || verdict=send

# 7. One block per turn: the reader's findings, or, in a cloud session where the
# reader could not run (no `claude` on the machine, a timeout, a failure), the
# assembled prompt handed to the model to give to a reader of its own through the
# Agent tool. On a desktop home that failure lets the reply through, logged.
handback=""
case "$status" in
  no-claude|timeout|failed) [ "${BBD_WHERE:-}" = cloud ] && handback=1 ;;
esac
blocked=0
if [ "$verdict" = fix ] || [ -n "$handback" ]; then
  if python3 "$BBD_CHECKOUT/lib/loopguard.py" allow "$guard" "$sid" "$turn" 2>>"$BBD_LOG"; then
    blocked=1
    if [ -n "$handback" ]; then
      {
        printf 'The reader that checks every reply before it is sent could not run on this machine (%s). ' "$status"
        printf 'Before you send, read it yourself through the Agent tool: start one subagent (a small, cheap model is enough), '
        printf 'paste the whole prompt below as its task with nothing added, act on each finding it returns, '
        printf 'then send the corrected reply. If it finds nothing, send the reply as it is.\n\n'
        python3 "$BBD_CHECKOUT/reader/reader.py" prompt \
          --draft "$draft" --contract "$BBD_CHECKOUT/text/reply-contract.md" \
          --rules "$rules" --asks "$asks" --kind reply 2>>"$BBD_LOG"
      } | python3 "$BBD_CHECKOUT/lib/hookio.py" block 2>>"$BBD_LOG"
      status=handed-back
    else
      jget "$result" reason | python3 "$BBD_CHECKOUT/lib/hookio.py" block 2>>"$BBD_LOG"
    fi
  else
    bbd_log "stop-gate: a block already happened this turn; the reply goes through"
  fi
fi

# 8. The receipt.
python3 "$BBD_CHECKOUT/lib/receipt.py" write "$receipts" "$draft" \
  "session=$sid" "prompt_id=$pid" "status=$status" "verdict=$verdict" "findings=${count:-0}" \
  "blocked=$blocked" "elapsed=${elapsed:-0}" "stop_reason=$stop_reason" "words=$words" \
  >/dev/null 2>>"$BBD_LOG" || bbd_log "stop-gate: the receipt could not be written"
bbd_log "stop-gate: $status, verdict $verdict, ${count:-0} finding(s), blocked $blocked, ${elapsed:-0}s"
exit 0
