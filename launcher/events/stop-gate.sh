#!/usr/bin/env bash
# stop-gate (Stop, synchronous): the read-draft step, the one place that may print a
# block decision (docs/launcher-contract.md section 13). The reply the model is about
# to leave on screen is read by an independent reader on the person's own plan
# (reader/reader.py, one headless `claude -p`), and when the reader finds something,
# the turn is held once with the findings as the reason, so the model sends a
# corrected reply. In order:
#   1. stop_hook_active: this Stop is the second pass of the turn, after a block; the
#      reply goes through whatever the reader would say.
#   2. The draft is last_assistant_message. Under 50 prose words there is nothing to
#      read. With no rules file in the repository (the marker's `rules`, present and
#      not empty), the reader has nothing of the person's to read against, and the
#      step stands down.
#   3. A receipt for this exact draft (lib/receipt.py) means it was read already.
#   4. The reader runs under a bound (60 seconds; BBD_READER_BOUND overrides, 1 to 600)
#      with the reply contract, the rules file, the session's open asks and the draft.
#   5. A verdict of fix becomes one block, at most once per turn (lib/loopguard.py,
#      keyed by the session and prompt_id, else the draft's hash). A verdict of send,
#      and every failure of the reader's own (no `claude`, a timeout, a non-zero exit,
#      an answer out of shape), lets the reply through, logged.
#   6. A receipt is written for every read and every attempt, never for a skip.
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

# 1. The second pass of this turn.
if python3 "$BBD_CHECKOUT/lib/hookio.py" flag "$BBD_INPUT" stop_hook_active 2>>"$BBD_LOG"; then
  bbd_log "stop-gate: the second pass of this turn; the reply goes through"
  exit 0
fi

# 2. The draft, and whether there is anything to read it against.
draft=$(mktemp "$BBD_BASE/state/draft.XXXXXX" 2>/dev/null) || exit 0
python3 "$BBD_CHECKOUT/lib/hookio.py" text "$BBD_INPUT" last_assistant_message >"$draft" 2>>"$BBD_LOG"
words=$(python3 "$BBD_CHECKOUT/reader/reader.py" words "$draft" 2>>"$BBD_LOG")
case "$words" in ''|*[!0-9]*) words=0 ;; esac
if [ "$words" -lt 50 ]; then
  bbd_log "stop-gate: $words prose words; nothing to read"
  exit 0
fi
rules=""
[ -n "${BBD_RULES:-}" ] && rules=$BBD_PROJECT_ROOT/$BBD_RULES
if [ -z "$rules" ] || [ ! -s "$rules" ]; then
  bbd_log "stop-gate: no rules file to read against (${BBD_RULES:-none named}); the reply goes through"
  exit 0
fi

# 3. Read once.
if python3 "$BBD_CHECKOUT/lib/receipt.py" exists "$receipts" "$draft" 2>>"$BBD_LOG"; then
  bbd_log "stop-gate: this draft was read already; the reply goes through"
  exit 0
fi

sid=$(field session_id)
pid=$(field prompt_id)
stop_reason=$(field stop_reason)

# 4. The reader.
asks=$(mktemp "$BBD_BASE/state/asks.XXXXXX" 2>/dev/null) || exit 0
result=$(mktemp "$BBD_BASE/state/verdict.XXXXXX" 2>/dev/null) || exit 0
if [ -n "$sid" ]; then
  python3 "$BBD_CHECKOUT/lib/ledger.py" open "$ledger_dir" "$sid" >"$asks" 2>>"$BBD_LOG"
fi
python3 "$BBD_CHECKOUT/reader/reader.py" read \
  --draft "$draft" --contract "$BBD_CHECKOUT/text/reply-contract.md" \
  --rules "$rules" --asks "$asks" --kind reply --bound "$BOUND" >"$result" 2>>"$BBD_LOG"
status=$(jget "$result" status)
verdict=$(jget "$result" verdict)
count=$(jget "$result" count)
elapsed=$(jget "$result" elapsed)
[ -n "$status" ] || status=failed
[ "$verdict" = fix ] || verdict=send

# 5. One block per turn.
blocked=0
if [ "$verdict" = fix ]; then
  turn=$pid
  [ -n "$turn" ] || turn=$(python3 "$BBD_CHECKOUT/lib/receipt.py" hash "$draft" 2>>"$BBD_LOG")
  if python3 "$BBD_CHECKOUT/lib/loopguard.py" allow "$guard" "$sid" "$turn" 2>>"$BBD_LOG"; then
    blocked=1
    jget "$result" reason | python3 "$BBD_CHECKOUT/lib/hookio.py" block 2>>"$BBD_LOG"
  else
    bbd_log "stop-gate: a block already happened this turn; the reply goes through"
  fi
fi

# 6. The receipt.
python3 "$BBD_CHECKOUT/lib/receipt.py" write "$receipts" "$draft" \
  "session=$sid" "prompt_id=$pid" "status=$status" "verdict=$verdict" "findings=${count:-0}" \
  "blocked=$blocked" "elapsed=${elapsed:-0}" "stop_reason=$stop_reason" "words=$words" \
  >/dev/null 2>>"$BBD_LOG" || bbd_log "stop-gate: the receipt could not be written"
bbd_log "stop-gate: $status, verdict $verdict, ${count:-0} finding(s), blocked $blocked, ${elapsed:-0}s"
exit 0
