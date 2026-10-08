#!/usr/bin/env bash
# session-start (SessionStart): the keep-current notices, and nothing else
# (docs/launcher-contract.md section 12). On source=compact the compact step runs
# (launcher/events/compact.sh) and its one JSON object is this event's output; it
# folds the fresh-session advice in itself, because the dispatcher passes on exactly
# one object. On every other source (startup, resume, clear, fork) lib/notices.py
# decides which notices are due, records them as said, and this prints them as one
# SessionStart object, or nothing. No rules are injected here: the next prompt
# brings them. No network call is made here: the data compared against
# (data/models.json, data/claude-code.json) arrives with the checkout.
# shellcheck source=../lib/common.sh
. "$BBD_CHECKOUT/launcher/lib/common.sh" || exit 0
trap 'exit 0' ERR INT TERM HUP

source=$(python3 "$BBD_CHECKOUT/lib/hookio.py" field "$BBD_INPUT" source 2>>"$BBD_LOG")
if [ "$source" = compact ]; then
  "${BASH:-bash}" "$BBD_CHECKOUT/launcher/events/compact.sh" "$@"
  exit 0
fi

# The running version is the newest of two readings, neither of them network: the
# LAST `version` field in the transcript's tail (a session upgraded mid-way carries
# two builds, the older first, and the current build's lines may not be written yet
# when this fires), and what the `claude` on PATH says under a 2-second bound (a
# desktop app bundles its own build, so the CLI alone can be older or newer than the
# session). notices.py takes the newest, so a person who already upgraded is never
# told to restart.
from_transcript=$(python3 "$BBD_CHECKOUT/lib/notices.py" running-version "$BBD_INPUT" 2>>"$BBD_LOG")
from_cli=""
if command -v claude >/dev/null 2>&1; then
  from_cli=$(bbd_bounded 2 claude --version 2>>"$BBD_LOG" | head -n 1 \
    | sed -n -E 's/^[[:space:]]*v?([0-9]+\.[0-9]+\.[0-9]+)([^0-9A-Za-z.-].*)?$/\1/p')
fi

text=$(python3 "$BBD_CHECKOUT/lib/notices.py" due \
  --input "$BBD_INPUT" --root "$BBD_PROJECT_ROOT" --delivery "$BBD_DELIVERY" \
  --state "$BBD_BASE/state/notices.json" \
  --models "$BBD_CHECKOUT/data/models.json" \
  --cli "$BBD_CHECKOUT/data/claude-code.json" \
  --compactions "$BBD_BASE/state/compactions" \
  --running-version "$from_transcript" --running-version "$from_cli" 2>>"$BBD_LOG")
if [ -n "$text" ]; then
  printf '%s\n' "$text" | python3 "$BBD_CHECKOUT/lib/hookio.py" context SessionStart 2>>"$BBD_LOG"
fi
exit 0
