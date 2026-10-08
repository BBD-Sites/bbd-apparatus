#!/usr/bin/env bash
# stop-ship (Stop, asynchronous in the plugin): for now it only records a pointer to
# this session's transcript in the queue, which is also all that happens until the
# store is connected. Draining the queue, rendering, redaction, the post-scan and the
# post or captures-branch push arrive with the ship pull request.
python3 "$BBD_CHECKOUT/lib/ship.py" queue-pointer "$BBD_BASE/queue" "$BBD_INPUT" "$BBD_WHERE" \
  || echo "stop-ship: could not queue a pointer" >&2
exit 0
