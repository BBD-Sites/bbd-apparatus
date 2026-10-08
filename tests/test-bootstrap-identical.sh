#!/usr/bin/env bash
# The plugin's bootstrap and the copy committed in a tenant repository are the same
# bytes. Both fire in a desktop session and the dedupe rule assumes they agree; a
# copy that drifted would behave differently in the cloud than on the Mac, where
# nobody would see it. The comparison is first shown to catch a one-byte change.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

root=$(h_repo_root)
plugin_copy="$root/plugin/launcher/bbd-launch.sh"
repo_copy="$root/templates/tenant-repo/.claude/hooks/bbd-launch.sh"

same() { cmp -s "$1" "$2"; }

# Self-check: a copy that differs by one byte is caught.
cp "$plugin_copy" "$H_TMP/drifted.sh"
printf ' ' >>"$H_TMP/drifted.sh"
if same "$plugin_copy" "$H_TMP/drifted.sh"; then h_fail "self-check: a drifted copy was not caught"
else h_ok "self-check: a drifted copy is caught"; fi

for f in "$plugin_copy" "$repo_copy"; do
  if [ -f "$f" ]; then h_ok "present: ${f#"$root"/}"; else h_fail "missing: ${f#"$root"/}"; fi
done
if same "$plugin_copy" "$repo_copy"; then h_ok "the two bootstrap copies are byte-identical"
else h_fail "the two bootstrap copies differ"; fi

# Tracked as executable in both places, so neither depends on being run with bash.
for f in plugin/launcher/bbd-launch.sh templates/tenant-repo/.claude/hooks/bbd-launch.sh; do
  mode=$(git -C "$root" ls-files -s -- "$f" | awk '{print $1}')
  if [ -z "$mode" ]; then
    echo "skip: $f is not committed yet, mode not checked"
  else
    h_assert_eq "$mode" 100755 "$f is tracked as executable"
  fi
done

h_done
