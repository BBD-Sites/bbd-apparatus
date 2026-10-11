#!/usr/bin/env bash
# prompt (UserPromptSubmit): record the ask and hand the model what every reply must
# follow (docs/launcher-contract.md section 11). In order:
#   1. the ask goes into the session's ledger as the next numbered item, unless it is
#      only a harness wrapper, a slash command or empty (lib/ledger.py decides);
#   1b. the other surface's pages are brought in (lib/vaultsync.py pull: a fast-forward,
#      bounded to four seconds, fail open), before the settle note below is worked out;
#   2. one JSON object is printed for the dispatcher to pass on, carrying, in order:
#      the reply contract and the witness rules (text/, the apparatus's own words, so
#      they change here and not in the plugin), the tenant's rules file named in the
#      vault marker, the standing instructions (.apparatus/standing.md) and the open
#      asks, all within 6,000 characters, the oldest asks dropped first.
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

python3 "$BBD_CHECKOUT/lib/inject.py" \
  --event UserPromptSubmit --cap "$CAP" --ledger "$ledger_dir" --session "$sid" \
  --text "$BBD_CHECKOUT/text/reply-contract.md" \
  --text "$BBD_CHECKOUT/text/witness-rules.md" \
  --inline "$settle" \
  --section "Rules from your repository (${BBD_RULES:-none named})" "${rules:-/nonexistent}" \
  --section "Standing instructions" "$BBD_PROJECT_ROOT/.apparatus/standing.md" \
  2>>"$BBD_LOG"
exit 0
