#!/usr/bin/env bash
# stop-gate (Stop, synchronous): the read-draft step, the one place that may print a
# block decision (docs/launcher-contract.md section 13). The reply the model is about
# to leave on screen is read by an independent reader on the person's own plan
# (reader/reader.py, one headless `claude -p`), and when anything is found, the turn is
# held once with ALL the findings as the reason, so the model sends one corrected reply.
# In order:
#   1. The draft is last_assistant_message. The reply is read for where each pending
#      ask stands, by its number (lib/ledger.py account), and the ask ledger moves to
#      match, on every pass.
#   2. stop_hook_active: this Stop is the second pass of the turn, after a block. The
#      turn's one block is spent, so the pass is ADVISORY: the reader still runs and
#      its receipt is written (advisory=1), but nothing can be held and no hand-back
#      is made (design D28: the reader judges the reply; the grade and the ask check
#      are only flags). One exception (design D45): when the first block quoted the
#      hard sentences and this pass's reader says fix, ONE more block is allowed, the
#      reader's findings alone (a score may have been chased); lib/loopguard.py holds
#      the cap of two blocks per turn.
#   3. Under 50 prose words there is nothing to read and nothing is held for asks.
#      The rules file the marker names is read against when it exists; a repository
#      with none is read against the reply contract alone.
#   4. A receipt for this exact draft (lib/receipt.py) means it was read already.
#   5. The reader runs FIRST, under a bound (60 seconds; BBD_READER_BOUND overrides,
#      1 to 600), with the reply contract, the rules file, the open asks and the draft:
#      one call per draft, whatever else is found.
#   6. Then the two deterministic checks: the reading level (lib/readability.py, pure
#      python, design D24) and the asks the reply left out (design D23). ALL findings
#      (the reader's, the quoted hard sentences, the missing asks) go into ONE block,
#      at most once per turn (lib/loopguard.py, keyed by the session and prompt_id, else
#      the draft's hash). Only the parts that exist are printed. When the reader itself
#      could not run (no `claude`, a timeout, a non-zero exit): on a desktop home the
#      reader adds nothing; in a cloud session its part is the assembled prompt to give
#      to a reader through the Agent tool.
#   7. A receipt is written for every read and every attempt, never for a skip.
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

# 2. The second pass of this turn, after a block: the reply goes through whatever is
# found, but it is still read below (advisory), so a corrected reply is never sent unread.
advisory=0
if python3 "$BBD_CHECKOUT/lib/hookio.py" flag "$BBD_INPUT" stop_hook_active 2>>"$BBD_LOG"; then
  advisory=1
  bbd_log "stop-gate: the second pass of this turn; the reply is read in advisory mode and goes through"
fi
turn=$pid
[ -n "$turn" ] || turn=$(python3 "$BBD_CHECKOUT/lib/receipt.py" hash "$draft" 2>>"$BBD_LOG")

# 3. Whether there is anything to read it against. A reply under fifty prose words is an
# acknowledgement: it is not read and not held for asks.
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

# 4. Read once. A draft with a receipt is not read again, and the grade is not
# measured again either (it was measured when the draft was read); the ask check still is.
read_already=0
if python3 "$BBD_CHECKOUT/lib/receipt.py" exists "$receipts" "$draft" 2>>"$BBD_LOG"; then
  read_already=1
  bbd_log "stop-gate: this draft was read already"
fi

# 5. The reader runs FIRST (one call), then the two deterministic checks are worked out,
# and every finding goes into the turn's ONE block. Running the reader after a
# deterministic hold used to spend the block on the grade or the missing asks and send
# the corrected reply on without its findings.
stop_reason=$(field stop_reason)
status=""; verdict=send; count=0; elapsed=0
if [ "$read_already" = 0 ]; then
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
fi

# The grade (design D24) and the missing asks (design D23) are flags beside the reader's
# findings, never a replacement for them. Neither is looked for on the second pass.
hard=""
asks_left=""
if [ "$advisory" = 0 ]; then
  [ "$read_already" = 0 ] && hard=$(python3 "$BBD_CHECKOUT/lib/readability.py" check "$draft" 2>>"$BBD_LOG")
  asks_left=$missing
fi

# 6. The block, in one piece: the reader's findings (or, in a cloud session where the
# reader could not run, the assembled prompt to hand to a reader through the Agent
# tool), then the quoted hard sentences, then the asks left out. Only the parts that
# exist are printed; at most one block per turn (lib/loopguard.py).
handback=""
case "$status" in
  no-claude|timeout|failed) [ "${BBD_WHERE:-}" = cloud ] && [ "$advisory" = 0 ] && handback=1 ;;
esac
blocked=0
parts=""
# One more block, in one case only: the first block quoted the hard sentences (whether
# or not the reader also found something), so the writer may have chased the score by
# chopping sentences, and the reader's verdict on the second pass is fix. The block is
# tagged "grade" when it carried the hard sentences, else "other". The guard holds the
# cap of two (design D45).
extra=0
cap=1
tag=other
[ -n "$hard" ] && tag=grade
if [ "$advisory" = 1 ] && [ "$verdict" = fix ] \
    && [ "$(python3 "$BBD_CHECKOUT/lib/loopguard.py" tag "$guard" "$sid" "$turn" 2>>"$BBD_LOG")" = grade ]; then
  extra=1
  cap=2
fi
if { [ "$advisory" = 0 ] && { [ "$verdict" = fix ] || [ -n "$handback" ] || [ -n "$hard" ] || [ -n "$asks_left" ]; }; } \
    || [ "$extra" = 1 ]; then
  if python3 "$BBD_CHECKOUT/lib/loopguard.py" allow "$guard" "$sid" "$turn" "$cap" "$tag" 2>>"$BBD_LOG"; then
    blocked=1
    parts=$(mktemp "$BBD_BASE/state/parts.XXXXXX" 2>/dev/null) || exit 0
    {
      if [ -n "$handback" ]; then
        printf 'The reader that checks every reply before it is sent could not run on this machine (%s). ' "$status"
        printf 'Before you send, read it yourself through the Agent tool: start one subagent (a small, cheap model is enough), '
        printf 'paste the whole prompt below as its task with nothing added, act on each finding it returns, '
        printf 'then send the corrected reply. If it finds nothing, send the reply as it is.\n\n'
        python3 "$BBD_CHECKOUT/reader/reader.py" prompt \
          --draft "$draft" --contract "$BBD_CHECKOUT/text/reply-contract.md" \
          --rules "$rules" --asks "$asks" --kind reply 2>>"$BBD_LOG"
        printf '\n\n'
        status=handed-back
      elif [ "$verdict" = fix ]; then
        jget "$result" reason
        printf '\n\n'
      fi
      if [ -n "$hard" ]; then
        printf '%s\n' "$hard" | awk -F'\t' '
          NR == 1 {
            printf "This reply is harder to read than the person can follow: it grades at %s, and the ceiling is %s. ", $1, $2
            printf "These are the sentences a reader would stumble on. Say each one in plainer words, or cut the idea it carries. "
            printf "Do not chop sentences into fragments, and do not add or drop a fact. Then send the reply again.\n\n"
            next
          }
          { printf "- \"%s\" (grade %s)\n", $2, $1 }'
        printf '\n'
      fi
      if [ -n "$asks_left" ]; then
        printf 'Your reply does not say where these asks stand. Send it again with each one under its own number, marked done, running or waiting:\n\n'
        printf '%s\n' "$asks_left" | cut -c1-240 | head -n 20
      fi
    } >"$parts"
    python3 "$BBD_CHECKOUT/lib/hookio.py" block <"$parts" 2>>"$BBD_LOG"
    bbd_log "stop-gate: held once; reader $verdict, reading level $([ -n "$hard" ] && echo flagged || echo ok), $([ -n "$asks_left" ] && printf '%s\n' "$asks_left" | wc -l | tr -d ' ' || echo 0) ask(s) left out"
  else
    bbd_log "stop-gate: findings, but a block already happened this turn; the reply goes through"
  fi
elif [ "$advisory" = 1 ]; then
  bbd_log "stop-gate: advisory read, verdict $verdict; nothing is held"
fi
rm -f "$parts" 2>/dev/null

# 7. The receipt, for every read and every attempt, never for a skip.
if [ "$read_already" = 0 ]; then
  python3 "$BBD_CHECKOUT/lib/receipt.py" write "$receipts" "$draft" \
    "session=$sid" "prompt_id=$pid" "status=$status" "verdict=$verdict" "findings=${count:-0}" \
    "blocked=$blocked" "advisory=$advisory" "second_block=$extra" "grade_flag=$([ -n "$hard" ] && echo 1 || echo 0)" \
    "asks_flag=$([ -n "$asks_left" ] && echo 1 || echo 0)" "elapsed=${elapsed:-0}" \
    "stop_reason=$stop_reason" "words=$words" \
    >/dev/null 2>>"$BBD_LOG" || bbd_log "stop-gate: the receipt could not be written"
  bbd_log "stop-gate: $status, verdict $verdict, ${count:-0} finding(s), blocked $blocked, ${elapsed:-0}s"
fi
exit 0
