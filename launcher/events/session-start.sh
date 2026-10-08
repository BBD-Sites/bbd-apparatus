#!/usr/bin/env bash
# session-start (SessionStart): on source=compact, the compact step runs
# (launcher/events/compact.sh) and its one JSON object is this event's output. Every
# other source (startup, resume, clear, fork) is a no-op until the keep-current
# notices pull request fills it. When it does, a compaction's notices must be folded
# into the compact step's single object, because the dispatcher passes on exactly
# one; the entry exists now because hook entries never change.
# shellcheck source=../lib/common.sh
. "$BBD_CHECKOUT/launcher/lib/common.sh" || exit 0
trap 'exit 0' ERR INT TERM HUP

source=$(python3 "$BBD_CHECKOUT/lib/hookio.py" field "$BBD_INPUT" source 2>>"$BBD_LOG")
if [ "$source" = compact ]; then
  "${BASH:-bash}" "$BBD_CHECKOUT/launcher/events/compact.sh" "$@"
fi
exit 0
