#!/usr/bin/env bash
# prompt (UserPromptSubmit): record the ask and hand the model what every reply must
# follow (docs/launcher-contract.md section 11). In order:
#   1. the ask goes into the session's ledger as the next numbered item, unless it is
#      only a harness wrapper, a slash command or empty (lib/ledger.py decides);
#   1b. the other surface's pages are brought in (lib/vaultsync.py pull: a fast-forward,
#      bounded to four seconds, fail open), before the settle note below is worked out;
#   2. one JSON object is printed for the dispatcher to pass on, carrying, in order:
#      the reply contract and the witness rules (text/, the apparatus's own words, so
#      they change here and not in the plugin), what the Stop gate noted on the last
#      reply (lib/notes.py, taken once: that reply was already shown, so its findings
#      shape this one instead), the tenant's rules file named in the
#      vault marker, the standing instructions (.apparatus/standing.md) and the open
#      asks, all within 6,000 characters, the oldest asks dropped first. On a turn the
#      harness started, not the person, the reply contract, the notes and the open
#      asks are left out.
# Stdout here becomes model context, so nothing but that object is printed, and a
# token shape is masked before it leaves (lib/inject.py). Errors go to the log.
# shellcheck source=../lib/common.sh
. "$BBD_CHECKOUT/launcher/lib/common.sh" || exit 0
trap 'exit 0' ERR INT TERM HUP

CAP=6000
ledger_dir=$BBD_BASE/state/ledger
umask 077
mkdir -p "$ledger_dir" 2>/dev/null || exit 0
chmod 700 "$ledger_dir" 2>/dev/null

python3 "$BBD_CHECKOUT/lib/ledger.py" append "$ledger_dir" "$BBD_INPUT" >/dev/null 2>>"$BBD_LOG" \
  || bbd_log "prompt: the ledger append failed"

sid=$(python3 "$BBD_CHECKOUT/lib/hookio.py" field "$BBD_INPUT" session_id 2>>"$BBD_LOG")
rules=""
[ -n "${BBD_RULES:-}" ] && rules=$BBD_PROJECT_ROOT/$BBD_RULES

# The other surface's pages first (lib/vaultsync.py pull): a note saved from the phone is
# on this disk before the model reads anything. A fast-forward only, bounded to four
# seconds, and it can never fail the prompt.
bbd_vault_pull 4 || true

# Pages that hold two versions, because two surfaces changed the same lines at once
# (lib/vaultsync.py): the model is told to settle them with the person on this turn.
settle=$(python3 "$BBD_CHECKOUT/lib/vaultsync.py" settle "$BBD_PROJECT_ROOT" \
  "$BBD_BASE/state/settle/$(python3 "$BBD_CHECKOUT/lib/vaultsync.py" state-name "$BBD_PROJECT_ROOT" 2>>"$BBD_LOG")" \
  "$BBD_CHECKOUT/text/settle.md" 2>>"$BBD_LOG")

# A turn the harness started, not the person (a finished background task, a CI event,
# another session's message: lib/ledger.py relayed). Its wake notice says to add nothing
# while the last line still holds, so nothing that shapes a reply goes in: not the reply
# contract, not the open asks with their "say where each stands", and not the Stop gate's
# notes, which stay for the person's next typed turn. Injecting the contract here made
# one session restate the same question on every wake. The witness rules, the settle
# note, the rules file and the standing instructions still go in.
contract=$BBD_CHECKOUT/text/reply-contract.md
asks_sid=$sid
lastnote=""
if [ "$(python3 "$BBD_CHECKOUT/lib/ledger.py" relayed "$BBD_INPUT" 2>>"$BBD_LOG")" = relayed ]; then
  contract=/nonexistent
  asks_sid=""
else
  # What the Stop gate found on the last reply, which the person has already read
  # (lib/notes.py): handed to this reply once, then gone.
  lastnote=$(python3 "$BBD_CHECKOUT/lib/notes.py" take "$BBD_BASE/state/notes" "$sid" 2>>"$BBD_LOG")
fi

python3 "$BBD_CHECKOUT/lib/inject.py" \
  --event UserPromptSubmit --cap "$CAP" --ledger "$ledger_dir" --session "$asks_sid" \
  --text "$contract" \
  --text "$BBD_CHECKOUT/text/witness-rules.md" \
  --inline "$lastnote" \
  --inline "$settle" \
  --section "Rules from your repository (${BBD_RULES:-none named})" "${rules:-/nonexistent}" \
  --section "Standing instructions" "$BBD_PROJECT_ROOT/.apparatus/standing.md" \
  2>>"$BBD_LOG"
exit 0
