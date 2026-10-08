#!/usr/bin/env bash
# Nothing a tenant runs reads Claude Code's own session store: not its undocumented
# sessions endpoint, not the login credential in the keychain, and not session
# teleporting. Transcripts reach a tenant's store only through the hooks.
# The forbidden strings are assembled at run time so this file does not match itself.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

forbidden=$(printf '%s\n' \
  "/v1/code/""sessions" \
  "Claude Code""-credentials" \
  "find-generic""-password" \
  "--tele""port")

# scan REPO: one line per forbidden string per file; nothing means clean.
scan() {
  local repo=$1 n=0 s hits
  while IFS= read -r s; do
    n=$((n + 1))
    hits=$(git -C "$repo" grep -c -I -F -e "$s" -- . 2>/dev/null || true)
    [ -n "$hits" ] && printf '%s\n' "$hits" | sed "s/^/forbidden string #$n in /"
  done <<LIST
$forbidden
LIST
  return 0
}

fake=$(h_fake_repo planted)
h_assert_empty "$(scan "$fake")" "self-check: a clean repository passes"
printf '%s\n' "$forbidden" >"$fake/reader.sh"
h_git -C "$fake" add reader.sh
h_git -C "$fake" commit -q -m "test: planted"
n=$(scan "$fake" | grep -c 'in reader.sh' || true)
h_assert_eq "$n" "4" "self-check: each forbidden string is caught"

h_assert_empty "$(scan "$(h_repo_root)")" "repository: no tracked file reads the session API or its credential"

h_done
