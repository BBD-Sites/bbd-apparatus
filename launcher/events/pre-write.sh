#!/usr/bin/env bash
# pre-write (PreToolUse on Write, Edit, MultiEdit, NotebookEdit): the duplicate-change
# guard (docs/launcher-contract.md section 15). Before the first file of a NEW OpenSpec
# change is written, lib/dupchange.py looks for an open change or a document that
# already covers it and, if one does, prints a PreToolUse deny decision naming it, once
# per new name per session. Any other write prints nothing. It fails open: a fault here
# never blocks a write. Stdout here is the hook's decision, so nothing else is printed.
# shellcheck source=../lib/common.sh
. "$BBD_CHECKOUT/launcher/lib/common.sh" || exit 0
trap 'exit 0' ERR INT TERM HUP

python3 "$BBD_CHECKOUT/lib/dupchange.py" check \
  --input "$BBD_INPUT" --root "$BBD_PROJECT_ROOT" --state "$BBD_BASE/state/dupguard" 2>>"$BBD_LOG"
exit 0
