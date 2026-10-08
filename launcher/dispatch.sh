#!/usr/bin/env bash
# dispatch.sh: the checkout's entry point, started by the bootstrap.
#
#   dispatch.sh EVENT DELIVERY INPUT-FILE [SKILL-NAME]
#
# INPUT-FILE is the hook's stdin, saved by the bootstrap; it is removed when this
# exits. The event script runs as a child with these exported: BBD_EVENT,
# BBD_DELIVERY, BBD_INPUT, BBD_PROJECT_ROOT, BBD_TENANT, BBD_CHANNEL, BBD_WHERE,
# BBD_BASE, BBD_LOG and BBD_CHECKOUT. An event this checkout does not know exits 0,
# so a newer hook entry never breaks an older checkout.

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
# shellcheck source=lib/common.sh
. "$here/lib/common.sh" || exit 0
bbd_fail_safe

BBD_EVENT=${1:-}
BBD_DELIVERY=${2:-}
BBD_INPUT=${3:-}
if [ $# -ge 3 ]; then shift 3; else shift $#; fi
bbd_cleanup "$BBD_INPUT"
bbd_recover_cwd

case "$BBD_EVENT" in
  session-start|prompt|pre-write|stop-gate|stop-ship|skill) ;;
  *) exit 0 ;;
esac
script=$BBD_CHECKOUT/launcher/events/$BBD_EVENT.sh
[ -f "$script" ] || exit 0

bbd_gate "$BBD_DELIVERY" "$BBD_INPUT" "$BBD_EVENT" || exit 0
bbd_state_dirs || exit 0
export BBD_EVENT BBD_DELIVERY BBD_INPUT BBD_PROJECT_ROOT BBD_TENANT BBD_CHANNEL \
  BBD_WHERE BBD_BASE BBD_LOG BBD_CHECKOUT

# Stdout becomes model context on UserPromptSubmit and a decision on Stop, so only a
# single valid JSON object an event prints is passed on; anything else is logged and
# dropped rather than shown.
out=$("${BASH:-bash}" "$script" "$@" 2>>"$BBD_LOG")
if [ -n "$out" ]; then
  printf '%s' "$out" | python3 "$BBD_CHECKOUT/lib/hookio.py" check 2>>"$BBD_LOG"
fi
exit 0
