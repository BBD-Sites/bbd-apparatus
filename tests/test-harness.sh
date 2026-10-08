#!/usr/bin/env bash
# The harness every later test leans on: if a fake repository could not push, or a
# fake git stopped recording, the tests built on them would pass for the wrong reason.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

work=$(h_fake_repo alpha)
h_assert_eq "$(git -C "$work" rev-parse HEAD)" "$(git -C "$work.git" rev-parse refs/heads/main)" \
  "a fake repository's commit is on its bare remote"
h_assert_eq "$(git -C "$work" log -1 --format='%ae %ce')" "$H_GIT_EMAIL $H_GIT_EMAIL" \
  "a fake repository commits with the neutral identity"
case "$work" in "$H_TMP"/*) h_ok "a fake repository lives in the test's temp directory" ;;
  *) h_fail "a fake repository escaped the temp directory" ;; esac

h_fake_bin git
h_fake_bin claude
git -C "$work" status --porcelain >/dev/null
calls=$(h_calls git)
case "$calls" in *"status --porcelain"*) h_ok "the fake git records its arguments" ;;
  *) h_fail "the fake git recorded nothing" ;; esac
h_assert_eq "$(git -C "$work" rev-parse --is-inside-work-tree)" "true" "the fake git still behaves like git"

out=$(H_FAKE_CLAUDE_STDOUT="hello" H_FAKE_CLAUDE_EXIT=3 claude plugin install x --scope user)
code=$?
h_assert_eq "$out:$code" "hello:3" "the fake claude prints and exits as told"
h_assert_eq "$(h_calls claude)" "plugin install x --scope user" "the fake claude records its arguments"

json=$(h_hook_json UserPromptSubmit prompt='say "hi"' cwd="$work")
h_assert_eq "$(printf '%s' "$json" | h_json_field hook_event_name)" "UserPromptSubmit" "hook JSON carries the event name"
h_assert_eq "$(printf '%s' "$json" | h_json_field prompt)" 'say "hi"' "hook JSON quotes an event field safely"
h_assert_eq "$(printf '%s' "$json" | h_json_field cwd)" "$work" "hook JSON takes an override"
for f in session_id prompt_id transcript_path; do
  h_assert_nonempty "$(printf '%s' "$json" | h_json_field "$f")" "hook JSON has $f"
done

h_done
