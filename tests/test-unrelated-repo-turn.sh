#!/usr/bin/env bash
# A whole turn in a repository that is not the buyer's vault changes nothing
# (docs/launcher-contract.md section 4). The vault marker test runs each event on its
# own; this one runs a turn the way a session lives it, in the order a session fires
# it, in an unrelated repository that looks as much like a vault as it can: it has a
# remote, an OpenSpec tree, vault-shaped folders holding unsaved pages, and a tree
# that is dirty. Every event is fired with both deliveries, as a desktop session and
# as a cloud session, with the shell sitting in the marked vault, including the
# tool-write check and a skill. Nothing may be written, committed, pushed, queued,
# injected or printed, no network call may be attempted, no state directory may
# appear, and the marked vault beside it stays untouched. Last, the same turn in the
# marked vault does act, which shows the gate is what held the rest back.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

h_fake_bin git
h_fake_apparatus >/dev/null
boot_plugin=$(h_bootstrap plugin)
boot_repo=$(h_bootstrap repo)
home=$(h_fake_home h1)
vault=$(h_fake_repo vault)
other=$(h_fake_repo other)
h_mark "$vault" tenant-a
h_tenant_env "$home" tenant-a
base="$home/.claude/bbd-apparatus"

# The unrelated repository: a change folder, vault-shaped folders, a rules file and
# unsaved pages, none of it committed.
mkdir -p "$other/openspec/changes/site-redesign" "$other/00-inbox" "$other/30-projects"
printf 'Why: the site is old.\n' >"$other/openspec/changes/site-redesign/proposal.md"
printf 'raw note\n' >"$other/00-inbox/note.md"
printf 'page\n' >"$other/30-projects/page.md"
printf 'rules\n' >"$other/RULES.md"
git -C "$other" add openspec
h_git -C "$other" commit -q -m "chore: change folder"
git -C "$other" push -q origin HEAD 2>/dev/null
printf 'edited after the commit\n' >>"$other/openspec/changes/site-redesign/proposal.md"

snapshot() {
  local r
  for r in "$vault" "$other"; do
    git --no-optional-locks -C "$r" status --porcelain --untracked-files=all
    git -C "$r" ls-files -s
    git -C "$r" for-each-ref --format='%(refname) %(objectname)'
    git -C "$r" stash list
    git -C "$r.git" for-each-ref --format='%(refname) %(objectname)'
    find "$r" -path "$r/.git" -prune -o -type f -print | sort | while read -r f; do
      printf '%s %s\n' "$f" "$(cksum <"$f")"
    done
  done
  find "$home" -print | sort
}

# fire LABEL BOOT DELIVERY EVENT HOOK-JSON-ARGS...: one event, shell in the vault.
fire() {
  local label=$1 boot=$2 delivery=$3 ev=$4 vars=()
  shift 4
  if [ "$delivery" = cloud ]; then vars=(CLAUDE_CODE_REMOTE=true); fi
  (cd "$vault" && h_hook_json Hook cwd="$other" session_id="sid-$label" "$@" \
    | h_launch "$label" "$home" CLAUDE_PROJECT_DIR="$other" ${vars[@]+"${vars[@]}"} -- \
        "$boot" "$ev" "$([ "$boot" = "$boot_repo" ] && echo repo || echo plugin)")
}

check() { # LABEL: nothing changed, printed, queued, injected or attempted
  local label=$1 before=$2
  h_assert_hook_run "$label" "$label"
  h_assert_empty "$(h_run_out "$label")" "$label: nothing printed or injected"
  h_assert_eq "$(snapshot)" "$before" "$label: nothing written, committed or pushed"
  h_assert_empty "$(h_net_calls)" "$label: no fetch, push, commit or init attempted"
  if [ -e "$base/state" ] || [ -e "$base/queue" ]; then h_fail "$label: a state or queue directory appeared"
  else h_ok "$label: no state or queue directory"; fi
}

touch "$H_TMP/epoch"
sleep 1

# The turn, event by event, for both deliveries. The tool-write check is fired with a
# new change folder, the thing the duplicate guard looks at.
for pair in "plugin:$boot_plugin" "repo:$boot_repo" "cloud:$boot_repo"; do
  d=${pair%%:*}
  boot=${pair#*:}
  case "$d" in cloud) delivery=cloud ;; *) delivery=$d ;; esac
  before=$(snapshot)
  h_calls_reset git
  for ev in session-start prompt pre-write stop-gate stop-ship skill; do
    label="$d-$ev"
    case "$ev" in
      session-start) fire "$label" "$boot" "$delivery" "$ev" source=startup model=test-model ;;
      prompt) fire "$label" "$boot" "$delivery" "$ev" prompt="Plan the site redesign for the shop." ;;
      pre-write) fire "$label" "$boot" "$delivery" "$ev" tool_name=Write \
                   tool_input="json:{\"file_path\":\"$other/openspec/changes/site-redesign-v2/proposal.md\"}" ;;
      stop-gate|stop-ship) fire "$label" "$boot" "$delivery" "$ev" \
                   last_assistant_message="The site is done. Nothing is yours to do. $(printf 'More words follow here. %.0s' 1 2 3 4 5 6 7 8 9 10 11 12)" ;;
      skill) fire "$label" "$boot" "$delivery" "$ev" ;;
    esac
    check "$label" "$before"
  done
done

# A compaction in the unrelated repository counts nothing and injects nothing.
before=$(snapshot)
h_calls_reset git
fire compact-other "$boot_plugin" plugin session-start source=compact model=test-model
check compact-other "$before"

# The marked vault beside it, with the same turn, does act.
h_hook_json Stop cwd="$vault" session_id=sid-vault | h_launch vault-ship "$home" CLAUDE_PROJECT_DIR="$vault" -- "$boot_plugin" stop-ship plugin
if [ -f "$base/queue/sid-vault.json" ]; then h_ok "the marked vault: the turn is queued, so the gate is what held the rest back"
else h_fail "the marked vault: the turn was not queued"; fi
h_assert_empty "$(git -C "$other" status --porcelain | grep -v -E '^( M|\?\?) ' || true)" "the unrelated repository's unsaved pages are still unsaved"

h_done
