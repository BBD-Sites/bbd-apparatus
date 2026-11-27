#!/usr/bin/env bash
# stop-gate (Stop, synchronous): the read-draft step, the one place that may print a
# block decision (docs/launcher-contract.md section 13). The reply the model has left on
# screen is read by an independent reader on the person's own plan (reader/reader.py,
# one headless `claude -p`). Stop fires after the person can already see the reply, so
# it is never sent again: a claim to check holds the turn once, to fix its cause and add
# at most one short correcting line; every other finding goes to the next reply.
# In order:
#   1. The draft is last_assistant_message. The reply is read for where each pending
#      ask stands, by its number (lib/ledger.py account), and the ask ledger moves to
#      match, on every pass.
#   2. stop_hook_active: this Stop is the second pass of the turn, after a block. The
#      turn's one block is spent, so the pass is ADVISORY: the reader still runs and
#      its receipt is written (advisory=1), but nothing can be held and no hand-back
#      is made (design D28: the reader judges the reply; the grade and the ask check
#      are only flags). The grade no longer holds a reply, so the one extra block of
#      design D45 (a score chased after a grade hold) cannot arise and is gone.
#   3. Under 50 prose words there is nothing to read and nothing is held for asks.
#      The rules file the marker names is read against when it exists; a repository
#      with none is read against the reply contract alone.
#   4. A receipt for this exact draft (lib/receipt.py) means it was read already.
#   5. The reader runs FIRST, under a bound (60 seconds; BBD_READER_BOUND overrides,
#      1 to 600), with the reply contract, the rules file, the open asks and the draft:
#      one call per draft, whatever else is found.
#   6. Then the two deterministic checks: the reading level (lib/readability.py, pure
#      python, design D24) and the asks the reply left out (design D23). The reply is
#      already shown, so none of that asks for it again. The reader's CLAIMS findings
#      (a claim with no source, or untrue) hold the turn once (lib/loopguard.py, keyed
#      by the session and prompt_id, else the draft's hash), to check each at its source
#      and add one short correcting line only if a fact is false. The reader's other
#      findings, the hard sentences and the missing asks are noted for the session's
#      next reply (lib/notes.py; the next prompt hands them over once). When the reader
#      itself could not run (no `claude`, a timeout, a non-zero exit): on a desktop home
#      the reader adds nothing; in a cloud session the turn is held once with the
#      assembled prompt to give to a reader through the Agent tool, on the same terms.
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
notes=$BBD_BASE/state/notes
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
# jfindings FILE claims|others: the reader's findings, one per line, either the CLAIMS
# ones (a claim with no source, or untrue) or every other one.
jfindings() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {}
fs = d.get("findings", []) if isinstance(d, dict) else []
want = sys.argv[2] == "claims"
for f in fs if isinstance(fs, list) else []:
    f = " ".join(str(f).split())
    if f and f.startswith("CLAIMS:") == want:
        print(f)' "$1" "$2" 2>>"$BBD_LOG"
}

# 1. The draft, and where the person's asks stand. The asks the reply has to answer are
# taken first (the reader is given them below), then the reply is read for each pending
# ask by its number, marked done, running or waiting (lib/ledger.py account), and the
# ledger moves to match on every pass, the second one too. A reply of fifty prose words
# or more that leaves an ask out has the missing asks noted for the next reply (design
# D23); a shorter one is an acknowledgement and is not.
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
# found, but it is still read below (advisory), so a correcting line is never sent unread.
advisory=0
if python3 "$BBD_CHECKOUT/lib/hookio.py" flag "$BBD_INPUT" stop_hook_active 2>>"$BBD_LOG"; then
  advisory=1
  bbd_log "stop-gate: the second pass of this turn; the reply is read in advisory mode and goes through"
fi
turn=$pid
[ -n "$turn" ] || turn=$(python3 "$BBD_CHECKOUT/lib/receipt.py" hash "$draft" 2>>"$BBD_LOG")

# 3. Whether there is anything to read it against. A reply under fifty prose words is an
# acknowledgement: it is not read and nothing is noted for asks.
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
# so every finding is in hand before anything is held or noted.
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

# 6. What is held, and what waits for the next reply. Stop fires after the reply is on
# the person's screen, so a block that asks for the reply again makes a second reply,
# which the person asked never to get. So only two things hold the turn, once:
#   - a claim the reader found unsourced or untrue (its CLAIMS findings), and
#   - in a cloud session where the reader could not run, the read itself, handed to a
#     reader through the Agent tool;
# and each says: the reply is not sent again; fix the cause; add one short line only if
# a fact in it is false, otherwise no new text. Everything else found (the reader's
# other findings, the quoted hard sentences, the asks left out) is a note for the
# session's next reply (lib/notes.py), which the next prompt hands over once
# (launcher/events/prompt.sh). At most one block per turn (lib/loopguard.py).
handback=""
case "$status" in
  no-claude|timeout|failed) [ "${BBD_WHERE:-}" = cloud ] && [ "$advisory" = 0 ] && handback=1 ;;
esac
claims=""
others=""
if [ "$verdict" = fix ]; then
  claims=$(jfindings "$result" claims)
  others=$(jfindings "$result" others)
fi
shown_fix="Your reply is already on the person's screen: do not send it again. Fix the cause. Only if a fact in the reply is false, add one short line that corrects it, and nothing else; otherwise end the turn with no new text."

# The notes, on the first pass only: the second pass follows a block, and what its reader
# says is kept in its receipt.
noted=0
if [ "$advisory" = 0 ] && { [ -n "$others" ] || [ -n "$hard" ] || [ -n "$asks_left" ]; }; then
  {
    if [ -n "$others" ]; then
      printf 'A reader found these in it; do not repeat them:\n'
      printf '%s\n' "$others" | cut -c1-300 | head -n 8 | sed 's/^/- /'
      printf '\n'
    fi
    if [ -n "$hard" ]; then
      printf '%s\n' "$hard" | awk -F'\t' '
        NR == 1 {
          printf "It was harder to read than the person can follow: it graded %s, and the ceiling is %s. ", $1, $2
          printf "Write this one in plainer words, without chopping sentences into fragments. These were the hard sentences:\n"
          next
        }
        { printf "- \"%s\" (grade %s)\n", $2, $1 }'
      printf '\n'
    fi
    if [ -n "$asks_left" ]; then
      printf 'It did not say where these asks stand. In this reply, give each one its own number, marked done, running or waiting:\n'
      printf '%s\n' "$asks_left" | cut -c1-240 | head -n 20
    fi
  } | python3 "$BBD_CHECKOUT/lib/notes.py" add "$notes" "$sid" 2>>"$BBD_LOG"
  noted=1
  bbd_log "stop-gate: findings noted for the next reply; nothing is held for them"
fi

blocked=0
if [ "$advisory" = 0 ] && { [ -n "$claims" ] || [ -n "$handback" ]; }; then
  if python3 "$BBD_CHECKOUT/lib/loopguard.py" allow "$guard" "$sid" "$turn" 2>>"$BBD_LOG"; then
    blocked=1
    {
      if [ -n "$handback" ]; then
        printf 'The reader that checks every reply could not run on this machine (%s). ' "$status"
        printf 'Read your reply now through the Agent tool: start one subagent (a small, cheap model is enough) '
        printf 'and paste the whole prompt below as its task with nothing added. %s\n\n' "$shown_fix"
        python3 "$BBD_CHECKOUT/reader/reader.py" prompt \
          --draft "$draft" --contract "$BBD_CHECKOUT/text/reply-contract.md" \
          --rules "$rules" --asks "$asks" --kind reply 2>>"$BBD_LOG"
      else
        printf 'A reader found claims in your reply with no source, or that may not be true:\n'
        printf '%s\n' "$claims" | cut -c1-600 | head -n 10 | sed 's/^/- /'
        printf '\nCheck each one at its source. %s\n' "$shown_fix"
      fi
    } | python3 "$BBD_CHECKOUT/lib/hookio.py" block 2>>"$BBD_LOG"
    [ -n "$handback" ] && status=handed-back
    bbd_log "stop-gate: held once; $([ -n "$handback" ] && echo 'the read handed back' || echo 'claims to check')"
  else
    bbd_log "stop-gate: findings, but a block already happened this turn; the reply goes through"
  fi
elif [ "$advisory" = 1 ]; then
  bbd_log "stop-gate: advisory read, verdict $verdict; nothing is held"
fi

# 7. The receipt, for every read and every attempt, never for a skip.
if [ "$read_already" = 0 ]; then
  python3 "$BBD_CHECKOUT/lib/receipt.py" write "$receipts" "$draft" \
    "session=$sid" "prompt_id=$pid" "status=$status" "verdict=$verdict" "findings=${count:-0}" \
    "blocked=$blocked" "advisory=$advisory" "noted=$noted" "grade_flag=$([ -n "$hard" ] && echo 1 || echo 0)" \
    "asks_flag=$([ -n "$asks_left" ] && echo 1 || echo 0)" "elapsed=${elapsed:-0}" \
    "stop_reason=$stop_reason" "words=$words" \
    >/dev/null 2>>"$BBD_LOG" || bbd_log "stop-gate: the receipt could not be written"
  bbd_log "stop-gate: $status, verdict $verdict, ${count:-0} finding(s), blocked $blocked, ${elapsed:-0}s"
fi
exit 0
