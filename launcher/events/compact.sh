#!/usr/bin/env bash
# compact: run by session-start.sh when SessionStart carries source=compact, the one
# hook that can put context back after a compaction (docs/launcher-contract.md
# section 11). It counts the compaction in state/compactions/<session_id> (the
# fresh-session advice reads that count) and prints one JSON object carrying the
# compaction notice (text/compact-notice.md), the tenant's rules file, the standing
# instructions and the open asks, within the same 6,000 characters as a prompt.
# The reply contract itself is not repeated here: the next prompt brings it.
# shellcheck source=../lib/common.sh
. "$BBD_CHECKOUT/launcher/lib/common.sh" || exit 0
trap 'exit 0' ERR INT TERM HUP

CAP=6000
ledger_dir=$BBD_BASE/state/ledger
counts=$BBD_BASE/state/compactions
umask 077

sid=$(python3 "$BBD_CHECKOUT/lib/hookio.py" field "$BBD_INPUT" session_id 2>>"$BBD_LOG")
# The id names a file, so only a plain id is counted (the ledger's own rule).
case "$sid" in
  ''|-*|.*|*[!A-Za-z0-9_-]*) sid="" ;;
  *) [ "${#sid}" -le 128 ] || sid="" ;;
esac
if [ -n "$sid" ]; then
  mkdir -p "$counts" 2>/dev/null && chmod 700 "$counts" 2>/dev/null
  n=$(cat "$counts/$sid" 2>/dev/null || true)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1))
  if printf '%s\n' "$n" >"$counts/$sid.tmp" 2>/dev/null; then
    mv -f "$counts/$sid.tmp" "$counts/$sid" 2>/dev/null || bbd_log "compact: could not record the count"
  else
    bbd_log "compact: could not record the count"
  fi
fi

rules=""
[ -n "${BBD_RULES:-}" ] && rules=$BBD_PROJECT_ROOT/$BBD_RULES

python3 "$BBD_CHECKOUT/lib/inject.py" \
  --event SessionStart --cap "$CAP" --ledger "$ledger_dir" --session "$sid" \
  --text "$BBD_CHECKOUT/text/compact-notice.md" \
  --section "Rules from your repository (${BBD_RULES:-none named})" "${rules:-/nonexistent}" \
  --section "Standing instructions" "$BBD_PROJECT_ROOT/.apparatus/standing.md" \
  2>>"$BBD_LOG"
exit 0
