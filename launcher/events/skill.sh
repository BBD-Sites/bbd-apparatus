#!/usr/bin/env bash
# skill NAME: a skill's body, printed as plain text for the model to follow, from
# this checkout. The bootstrap passes the name alone (one word of [a-z0-9-]), so a
# skill that takes a value carries it in the name.
#
#   notices-stop-<kind>   record that the person does not want that kind of notice
#                         again (docs/launcher-contract.md section 12); kind is
#                         version, model, fresh-session or all. Prints one line that
#                         says it is off. An unknown kind is refused: nothing is
#                         printed, nothing is written, one line goes to the log.
#
# Every other name is a no-op until the read-draft pull request fills it.
# shellcheck source=../lib/common.sh
. "$BBD_CHECKOUT/launcher/lib/common.sh" || exit 0
trap 'exit 0' ERR INT TERM HUP

name=${1:-}
case "$name" in
  notices-stop-*)
    kind=${name#notices-stop-}
    case "$kind" in
      version|model|fresh-session|all) ;;
      *) bbd_log "notices-stop: unknown kind '$kind'; nothing written"; exit 0 ;;
    esac
    if python3 "$BBD_CHECKOUT/lib/notices.py" stop "$BBD_BASE/state/notices.json" "$kind" 2>>"$BBD_LOG"; then
      case "$kind" in
        all) what="Every keep-current notice is" ;;
        fresh-session) what="Fresh-session advice is" ;;
        *) what="The $kind notice is" ;;
      esac
      printf '%s\n' "$what now off for this account home. Tell the person that in one sentence, and say nothing more about it."
    fi
    ;;
esac
exit 0
