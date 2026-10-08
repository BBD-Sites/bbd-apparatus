#!/usr/bin/env bash
# The launcher touches only a repository that carries the vault marker for this
# home's tenant (docs/launcher-contract.md section 4). Two repositories, each with a
# local bare remote: A is marked, B is not. Every event is run with
# CLAUDE_PROJECT_DIR=B while the shell sits in A (the defect of 2026-10-06), and
# again with the JSON cwd=B and no CLAUDE_PROJECT_DIR. Then A is marked for another
# tenant. In all of these nothing may be written, committed, pushed, queued or
# printed, and no network call may be attempted; the fake git records every call, so
# that last one is proved, not assumed. Last, A with the matching tenant: the queue
# entry appears, which shows the gate is what stopped the others.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

h_fake_bin git
h_fake_apparatus >/dev/null
boot=$(h_bootstrap)
home=$(h_fake_home h1)
a=$(h_fake_repo alpha)
b=$(h_fake_repo beta)
h_mark "$a" tenant-a
h_tenant_env "$home" tenant-a
base="$home/.claude/bbd-apparatus"
events="session-start prompt pre-write stop-gate stop-ship"

# Everything a launcher could change: each repository's tree, index, refs and stash,
# its remote's refs, and every file under the home.
snapshot() {
  local r
  for r in "$a" "$b"; do
    # --no-optional-locks: the snapshot's own status must not refresh the index.
    git --no-optional-locks -C "$r" status --porcelain --untracked-files=all
    git -C "$r" ls-files -s
    git -C "$r" for-each-ref --format='%(refname) %(objectname)'
    git -C "$r" stash list
    git -C "$r.git" for-each-ref --format='%(refname) %(objectname)'
    find "$r" -path "$r/.git" -prune -o -type f -newer "$H_TMP/epoch" -print
  done
  find "$home" -print | sort
}

# run_all LABEL HOME [VAR=value ...]: every event, shell in A; each must change
# nothing and print nothing.
run_all() {
  local label=$1 h=$2 ev before after
  shift 2
  for ev in $events; do
    before=$(snapshot)
    h_calls_reset git
    (cd "$a" && h_hook_json Hook cwd="$a" session_id="sid-$label-$ev" \
      | h_launch "$label-$ev" "$h" "$@" -- "$boot" "$ev" plugin)
    h_assert_hook_run "$label-$ev" "$label, $ev"
    h_assert_empty "$(h_run_out "$label-$ev")" "$label, $ev: nothing printed"
    after=$(snapshot)
    h_assert_eq "$after" "$before" "$label, $ev: nothing written, committed or pushed"
    h_assert_empty "$(h_net_calls)" "$label, $ev: no fetch, push, commit or init attempted"
    if [ -e "$base/state" ] || [ -e "$base/queue" ]; then
      h_fail "$label, $ev: a state or queue directory was created"
    else
      h_ok "$label, $ev: no state or queue directory"
    fi
  done
}

touch "$H_TMP/epoch"
sleep 1

# B is unmarked: CLAUDE_PROJECT_DIR=B while the shell sits in marked A.
run_all "cwd-trap-env" "$home" CLAUDE_PROJECT_DIR="$b"

# B is unmarked: the JSON cwd says B, there is no CLAUDE_PROJECT_DIR, the shell in A.
run_all_json() {
  local label=json-cwd ev before after
  for ev in $events; do
    before=$(snapshot)
    h_calls_reset git
    (cd "$a" && h_hook_json Hook cwd="$b" session_id="sid-$label-$ev" \
      | h_launch "$label-$ev" "$home" -- "$boot" "$ev" plugin)
    h_assert_hook_run "$label-$ev" "$label, $ev"
    after=$(snapshot)
    h_assert_eq "$after" "$before" "$label, $ev: nothing written, committed or pushed"
    h_assert_empty "$(h_net_calls)" "$label, $ev: no fetch, push, commit or init attempted"
    if [ -e "$base/state" ] || [ -e "$base/queue" ]; then
      h_fail "$label, $ev: a state or queue directory was created"
    else
      h_ok "$label, $ev: no state or queue directory"
    fi
  done
}
run_all_json

# The repository copy behaves the same in an unmarked repository, in the cloud.
before=$(snapshot)
h_calls_reset git
(cd "$a" && h_hook_json Stop cwd="$b" | h_launch cloud-unmarked "$home" CLAUDE_CODE_REMOTE=true CLAUDE_PROJECT_DIR="$b" -- "$boot" stop-ship repo)
h_assert_hook_run cloud-unmarked "repository copy in the cloud, unmarked repository"
h_assert_eq "$(snapshot)" "$before" "repository copy in the cloud, unmarked repository: nothing changed"
h_assert_empty "$(h_net_calls)" "repository copy in the cloud, unmarked repository: no network"

# A marker that does not parse, or names no tenant, is no marker.
for bad in 'not json' '{"schema":1}' '{"tenant":""}' '{"tenant":"../x"}' '[]'; do
  printf '%s\n' "$bad" >"$b/.apparatus-vault.tmp"
  mkdir -p "$b/.apparatus"
  mv "$b/.apparatus-vault.tmp" "$b/.apparatus/vault.json"
  h_calls_reset git
  h_hook_json Stop cwd="$b" | h_launch bad-marker "$home" CLAUDE_PROJECT_DIR="$b" -- "$boot" stop-ship plugin
  h_assert_hook_run bad-marker "marker [$bad]"
  h_assert_empty "$(h_net_calls)" "marker [$bad]: no network"
  if [ -e "$base/queue" ]; then h_fail "marker [$bad]: something was queued"; else h_ok "marker [$bad]: nothing queued"; fi
done
rm -rf "$b/.apparatus"

# A is marked for another tenant than this home's.
git -C "$a" rm -q -r .apparatus
h_git -C "$a" commit -q -m "chore: unmark"
h_mark "$a" tenant-b
run_all "wrong-tenant" "$home" CLAUDE_PROJECT_DIR="$a"

# The matching tenant: the gate opens, and the turn is queued.
git -C "$a" rm -q -r .apparatus
h_git -C "$a" commit -q -m "chore: unmark"
h_mark "$a" tenant-a
h_hook_json Stop cwd="$a" session_id=sid-match | h_launch match "$home" CLAUDE_PROJECT_DIR="$a" -- "$boot" stop-ship plugin
h_assert_hook_run match "matching tenant"
if [ -f "$base/queue/sid-match.json" ]; then h_ok "matching tenant: the queue entry appears"
else h_fail "matching tenant: no queue entry"; fi
h_assert_empty "$(git -C "$a" status --porcelain)" "matching tenant: the repository itself is untouched"

h_done
