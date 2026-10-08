#!/usr/bin/env bash
# What fail safe means (docs/launcher-contract.md section 6), one planted failure at
# a time: offline, a checkout that cannot fast-forward, a fetch slower than its
# bound, no checkout and no network, a held fetch lock, a corrupt config, a crashing
# or chattering event, a store that cannot be reached, and an unsigned head where an
# allowed signers file exists. In every case the launcher exits 0 and prints nothing
# but hook JSON, and the turn's transcript is still queued or the last checkout
# still runs.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

h_fake_bin git
h_fake_apparatus >/dev/null
h_plant_event v1 prompt
boot=$(h_bootstrap)
home=$(h_fake_home h1)
repo=$(h_fake_repo vault)
h_mark "$repo" tenant-a
base="$home/.claude/bbd-apparatus"
co="$base/checkout-stable"
bare="$H_TMP/apparatus.git"

# A file's permission bits, the same on BSD and GNU (whose stat flags differ).
mode() { python3 -c 'import os,sys; print("%o" % (os.stat(sys.argv[1]).st_mode & 0o777))' "$1"; }

# The next run fetches, whatever the last one did.
expire_stamp() { rm -f "$base/state/fetch.stamp"; }

prompt() { # NAME [VAR=value ...]
  local name=$1
  shift
  h_hook_json UserPromptSubmit cwd="$repo" | h_launch "$name" "$home" "$@" -- "$boot" prompt plugin
}

# Online first: the checkout is made and its event runs.
h_sentinel_reset
prompt seed
h_assert_hook_run seed "first run online"
h_assert_eq "$(h_sentinel | awk '{print $1}')" "v1" "first run online: the fetched checkout ran"
h_assert_eq "$(git -C "$co" rev-parse HEAD)" "$(git -C "$bare" rev-parse stable)" "first run online: the checkout is at the channel head"

# Offline: the fetch fails, the last checkout runs.
h_plant_event v2 prompt
expire_stamp
h_sentinel_reset
h_calls_reset git
prompt offline H_FAKE_GIT_FETCH=fail
h_assert_hook_run offline "offline"
h_assert_nonempty "$(h_calls git | grep ' fetch ')" "offline: a fetch was attempted"
h_assert_eq "$(h_sentinel | awk '{print $1}')" "v1" "offline: the last checkout ran"

# Back online: the same turn's next event fast-forwards.
expire_stamp
h_sentinel_reset
prompt online
h_assert_eq "$(h_sentinel | awk '{print $1}')" "v2" "online again: the checkout fast-forwarded and the new code ran"

# Drift: a local commit, an edited tracked file and a stray file in the checkout, and
# a channel head rewritten so it no longer descends from the checkout.
h_git -C "$co" commit -q --allow-empty -m "local drift"
printf 'drift\n' >>"$co/launcher/dispatch.sh"
printf 'stray\n' >"$co/launcher/events/stray.sh"
src="$H_TMP/apparatus-src"
h_git -C "$src" commit -q --amend -m "test: rewritten history"
git -C "$src" push -q -f "$bare" HEAD:refs/heads/stable
h_plant_event v3 prompt
expire_stamp
h_sentinel_reset
prompt drift
h_assert_hook_run drift "non-fast-forward checkout"
h_assert_eq "$(git -C "$co" rev-parse HEAD)" "$(git -C "$bare" rev-parse stable)" "non-fast-forward checkout: reset to the channel head"
h_assert_empty "$(git -C "$co" status --porcelain)" "non-fast-forward checkout: no edited or stray file survives"
h_assert_eq "$(h_sentinel | awk '{print $1}')" "v3" "non-fast-forward checkout: the channel head's code ran"

# A fetch over the bound is abandoned and the last checkout runs.
h_plant_event v4 prompt
expire_stamp
h_sentinel_reset
prompt slow H_FAKE_GIT_FETCH=hang H_FAKE_GIT_HANG=20
h_assert_hook_run slow "fetch over the bound"
secs=$(h_run_secs slow)
if [ "$secs" -le 8 ]; then h_ok "fetch over the bound: abandoned after the bound (${secs}s)"
else h_fail "fetch over the bound: the run took ${secs}s"; fi
h_assert_eq "$(h_sentinel | awk '{print $1}')" "v3" "fetch over the bound: the last checkout ran"
h_assert_eq "$(git -C "$co" rev-parse HEAD)" "$(git -C "$bare" rev-parse stable~1)" "fetch over the bound: the checkout was not moved"

# One fetch per turn: a run within the stamp window does not fetch.
expire_stamp
prompt stamp-a
h_calls_reset git
prompt stamp-b
h_assert_empty "$(h_calls git | grep ' fetch ')" "a second event within the stamp window does not fetch"

# A fetch lock held by a live run is not waited for; a dead holder's is taken over.
expire_stamp
mkdir -p "$base/state/fetch.lock"
date +%s >"$base/state/fetch.lock/at"
h_calls_reset git
h_sentinel_reset
prompt locked
h_assert_hook_run locked "fetch lock held"
h_assert_empty "$(h_calls git | grep ' fetch ')" "fetch lock held: no fetch"
h_assert_nonempty "$(h_sentinel)" "fetch lock held: the last checkout still ran"
echo $(($(date +%s) - 120)) >"$base/state/fetch.lock/at"
h_calls_reset git
prompt stale
h_assert_nonempty "$(h_calls git | grep ' fetch ')" "a stale fetch lock is taken over"
if [ -d "$base/state/fetch.lock" ]; then h_fail "the fetch lock was left behind"; else h_ok "the fetch lock is released"; fi

# No checkout and no network: stop-ship queues a pointer, every other event exits 0
# silently.
home2=$(h_fake_home h2)
base2="$home2/.claude/bbd-apparatus"
for ev in session-start prompt pre-write stop-gate; do
  rm -f "$base2/state/fetch.stamp"
  h_sentinel_reset
  h_hook_json Hook cwd="$repo" session_id="sid-$ev" | h_launch "cold-$ev" "$home2" H_FAKE_GIT_FETCH=fail -- "$boot" "$ev" plugin
  h_assert_hook_run "cold-$ev" "no checkout, no network, $ev"
  h_assert_empty "$(h_run_out "cold-$ev")$(h_sentinel)" "no checkout, no network, $ev: silent"
  if [ -e "$base2/queue/sid-$ev.json" ]; then h_fail "no checkout, no network, $ev: queued a pointer"
  else h_ok "no checkout, no network, $ev: nothing queued"; fi
done
rm -f "$base2/state/fetch.stamp"
h_hook_json Stop cwd="$repo" session_id=sid-cold transcript_path=/x/sid-cold.jsonl \
  | h_launch cold-ship "$home2" H_FAKE_GIT_FETCH=fail -- "$boot" stop-ship plugin
h_assert_hook_run cold-ship "no checkout, no network, stop-ship"
rec="$base2/queue/sid-cold.json"
if [ -f "$rec" ]; then
  h_ok "no checkout, no network, stop-ship: a pointer is queued"
  h_assert_eq "$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1])))))' "$rec")" \
    "attempts first_seen session_id transcript_path where" "the pointer holds the five fields and nothing else"
  h_assert_eq "$(h_json_field transcript_path <"$rec")" "/x/sid-cold.jsonl" "the pointer names the transcript"
  h_assert_eq "$(h_json_field where <"$rec")" "desktop" "the pointer says where the session ran"
  h_assert_eq "$(mode "$rec")" "600" "the pointer is readable by its owner only"
else
  h_fail "no checkout, no network, stop-ship: no pointer queued"
fi
h_assert_eq "$(mode "$base2")" "700" "the state root is 0700"

# The checkout's stop-ship writes the same record the bootstrap does, and a second
# turn of one session refreshes it in place, keeping when it was first seen.
h_hook_json Stop cwd="$repo" session_id=sid-x transcript_path=/x/a.jsonl | h_launch ship-1 "$home" -- "$boot" stop-ship plugin
first=$(h_json_field first_seen <"$base/queue/sid-x.json")
sleep 1
h_hook_json Stop cwd="$repo" session_id=sid-x transcript_path=/x/b.jsonl | h_launch ship-2 "$home" -- "$boot" stop-ship plugin
h_assert_hook_run ship-2 "stop-ship from the checkout"
h_assert_eq "$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1])))))' "$base/queue/sid-x.json")" \
  "attempts first_seen project_root queued_at repo session_id tenant transcript_path where" \
  "the checkout's pointer has the bootstrap's five fields, plus when it was queued, the project, repository and tenant"
h_assert_eq "$(h_json_field project_root <"$base/queue/sid-x.json")" "$repo" "the checkout's pointer names the project it fired for"
h_assert_eq "$(h_json_field tenant <"$base/queue/sid-x.json")" "tenant-a" "the checkout's pointer names the marker's tenant"
h_assert_eq "$(h_json_field transcript_path <"$base/queue/sid-x.json")" "/x/b.jsonl" "a later turn points at the latest transcript"
h_assert_eq "$(h_json_field first_seen <"$base/queue/sid-x.json")" "$first" "a later turn keeps when the session was first seen"
h_hook_json Stop cwd="$repo" session_id=../escape | h_launch ship-bad "$home" -- "$boot" stop-ship plugin
h_assert_hook_run ship-bad "a session id that is a path"
if [ -e "$base/escape.json" ]; then h_fail "a session id escaped the queue directory"; else h_ok "a session id that is a path writes nothing"; fi

# A corrupt config: binary noise, a line that would run if the file were sourced, and
# no tenant. The home then matches no tenant, so nothing acts, and nothing executes.
home3=$(h_fake_home h3)
mkdir -p "$home3/.claude/bbd-apparatus"
# shellcheck disable=SC2016  # the lines are meant literally: they must never run
{ head -c 512 /dev/urandom; printf '\n$(touch %s/pwned)\nBBD_CHANNEL=`touch %s/pwned`\n' "$H_TMP" "$H_TMP"; } \
  >"$home3/.claude/bbd-apparatus/tenant.env"
for ev in prompt stop-ship; do
  h_hook_json Hook cwd="$repo" | h_launch "corrupt-$ev" "$home3" -- "$boot" "$ev" plugin
  h_assert_hook_run "corrupt-$ev" "corrupt config, $ev"
done
if [ -e "$H_TMP/pwned" ]; then h_fail "corrupt config: a line in it executed"; else h_ok "corrupt config: nothing in it executed"; fi
h_assert_empty "$(ls "$home3/.claude/bbd-apparatus/queue" 2>/dev/null)" "corrupt config: nothing queued"
# The same lines after a valid tenant: values are text, the channel is refused and
# falls back to stable, and the turn runs.
# shellcheck disable=SC2016  # the lines are meant literally: they must never run
h_tenant_env "$home3" tenant-a 'BBD_CHANNEL=`touch '"$H_TMP"'/pwned`' '$(touch '"$H_TMP"'/pwned)'
h_sentinel_reset
h_hook_json Hook cwd="$repo" | h_launch corrupt-valid "$home3" -- "$boot" prompt plugin
h_assert_hook_run corrupt-valid "config with hostile lines"
if [ -e "$H_TMP/pwned" ]; then h_fail "hostile config: a line in it executed"; else h_ok "hostile config: nothing in it executed"; fi
h_assert_nonempty "$(h_sentinel)" "hostile config: the stable checkout ran"

# Corrupt hook input: not JSON, and an empty stdin.
printf 'not json{' | h_launch bad-input "$home" -- "$boot" stop-ship plugin
h_assert_hook_run bad-input "hook input that is not JSON"
h_launch no-input "$home" -- "$boot" prompt plugin </dev/null
h_assert_hook_run no-input "empty hook input"
h_hook_json Hook cwd="$repo" | h_launch bad-args "$home" -- "$boot" '../x' plugin
h_assert_hook_run bad-args "an event name that is a path"
h_hook_json Hook cwd="$repo" | h_launch unknown "$home" -- "$boot" no-such-event plugin
h_assert_hook_run unknown "an unknown event"

# A crashing event, and one that prints noise: exit 0, and only hook JSON reaches
# stdout.
h_apparatus_file launcher/events/prompt.sh '#!/usr/bin/env bash
echo "not hook json"
exit 7'
h_apparatus_file launcher/events/session-start.sh '#!/usr/bin/env bash
printf "%s" "{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"hello\"}}"'
h_apparatus_file launcher/events/stop-gate.sh '#!/usr/bin/env bash
set -e
false'
expire_stamp
for ev in prompt session-start stop-gate; do
  h_hook_json Hook cwd="$repo" | h_launch "noisy-$ev" "$home" -- "$boot" "$ev" plugin
  h_assert_hook_run "noisy-$ev" "event $ev that crashes or prints"
done
h_assert_empty "$(h_run_out noisy-prompt)" "an event's non-JSON output is dropped"
h_assert_eq "$(h_run_out noisy-session-start | h_json_field hookSpecificOutput)" \
  "{'hookEventName': 'SessionStart', 'additionalContext': 'hello'}" "an event's hook JSON is passed through"
if grep -q 'dropped output' "$base/state/launcher.log" 2>/dev/null; then h_ok "dropped output is logged"
else h_fail "dropped output was not logged"; fi

# A broken dispatcher (an exit 2, which would block the turn, with raw text on
# stdout, or a syntax error): the bootstrap still exits 0 and passes on only hook JSON.
expire_stamp
h_apparatus_file launcher/dispatch.sh '#!/usr/bin/env bash
echo "raw text from a broken dispatcher"
exit 2'
h_hook_json Hook cwd="$repo" | h_launch broken-dispatch "$home" -- "$boot" prompt plugin
h_assert_hook_run broken-dispatch "a dispatcher that exits 2 and prints raw text"
h_assert_empty "$(h_run_out broken-dispatch)" "a broken dispatcher's raw text never reaches stdout"
expire_stamp
h_apparatus_file launcher/dispatch.sh '#!/usr/bin/env bash
if then fi ((('
h_hook_json Hook cwd="$repo" | h_launch syntax-dispatch "$home" -- "$boot" stop-gate plugin
h_assert_hook_run syntax-dispatch "a dispatcher with a syntax error"

# The harness kills a hook at its timeout: the dispatcher under it goes too, and so
# does what the dispatcher started (an event, its python), which a kill of the
# dispatcher alone would leave running.
expire_stamp
# shellcheck disable=SC2016  # the planted script expands its own variables
h_apparatus_file launcher/dispatch.sh '#!/usr/bin/env bash
printf "%s %s\n" "$$" "$PPID" >"$H_SENTINEL.pids"
out=$(sh -c '"'"'echo $$ >"$H_SENTINEL.child"; exec sleep 30'"'"')'
rm -f "$H_TMP/sentinel.log.pids" "$H_TMP/sentinel.log.child"
( h_hook_json Hook cwd="$repo" | h_launch term "$home" -- "$boot" prompt plugin ) &
launcher_job=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$H_TMP/sentinel.log.pids" ] && [ -s "$H_TMP/sentinel.log.child" ] && break
  sleep 0.5
done
read -r dispatch_pid boot_pid <"$H_TMP/sentinel.log.pids"
read -r grandchild_pid <"$H_TMP/sentinel.log.child"
if kill -0 "$grandchild_pid" 2>/dev/null; then h_ok "the planted grandchild was running"
else h_fail "the planted grandchild never ran"; fi
kill -TERM "$boot_pid"
wait "$launcher_job"
h_assert_hook_run term "a bootstrap killed by the harness"
sleep 1
for pair in "dispatcher:$dispatch_pid" "dispatcher's own child:$grandchild_pid"; do
  if kill -0 "${pair##*:}" 2>/dev/null; then
    h_fail "a killed bootstrap left its ${pair%%:*} running"
    kill -KILL "${pair##*:}" 2>/dev/null
  else
    h_ok "a killed bootstrap takes its ${pair%%:*} with it"
  fi
done
expire_stamp
h_apparatus_file launcher/dispatch.sh "$(cat "$(h_repo_root)/launcher/dispatch.sh")"

# The bound's watcher leaves nothing behind: no sleep of the fetch bound or the
# dispatcher's outer bound outlives a run.
# Only orphans count: a leaked sleep has lost its watcher, while a sleep whose parent
# is still a bash process belongs to a launcher that is still running (another test
# run on the same machine, say). Process ids are compared, not a count, because other
# sleeps come and go meanwhile.
orphan_sleeps() {
  local pid ppid pcomm
  for pid in $(pgrep -f -x 'sleep (3|600)' 2>/dev/null); do
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$ppid" ] || continue
    pcomm=$(ps -o comm= -p "$ppid" 2>/dev/null)
    case "$pcomm" in *bash) continue ;; esac
    echo "$pid"
  done | sort
}
orphan_sleeps >"$H_TMP/sleeps.before"
for n in 1 2 3; do
  expire_stamp
  prompt "no-leak-$n"
done
sleep 1
orphan_sleeps >"$H_TMP/sleeps.after"
h_assert_empty "$(comm -13 "$H_TMP/sleeps.before" "$H_TMP/sleeps.after")" "no watcher sleep outlives a run"

# A checkout whose .git is broken, in a home that is itself a git repository (a
# dotfiles home): git must not walk up and reset the home. The checkout is rebuilt.
home4=$(h_fake_home h4)
printf 'keep me\n' >"$home4/.bashrc"
h_git init -q "$home4"
git -C "$home4" add .bashrc
h_git -C "$home4" commit -q -m "chore: dotfiles"
home_head=$(git -C "$home4" rev-parse HEAD)
h_plant_event v7 prompt
h_hook_json Hook cwd="$repo" | h_launch home-repo-seed "$home4" -- "$boot" prompt plugin
co4="$home4/.claude/bbd-apparatus/checkout-stable"
for broken in file dir; do
  rm -rf "$co4/.git"
  if [ "$broken" = file ]; then printf 'gitdir: /nowhere\n' >"$co4/.git"; else mkdir -p "$co4/.git"; fi
  rm -f "$home4/.claude/bbd-apparatus/state/fetch.stamp"
  h_sentinel_reset
  h_hook_json Hook cwd="$repo" | h_launch "home-repo-$broken" "$home4" -- "$boot" prompt plugin
  h_assert_hook_run "home-repo-$broken" "a broken checkout .git ($broken) inside a home repository"
  h_assert_eq "$(git -C "$home4" rev-parse HEAD)" "$home_head" "broken checkout .git ($broken): the home repository's HEAD is untouched"
  if [ -f "$home4/.bashrc" ] && [ ! -e "$home4/launcher" ]; then h_ok "broken checkout .git ($broken): the home's files are untouched"
  else h_fail "broken checkout .git ($broken): the home's files were changed"; fi
  h_assert_eq "$(h_sentinel | awk '{print $1}')" "v7" "broken checkout .git ($broken): the checkout is rebuilt and runs"
done

# Git lock files left by a killed run do not wedge the checkout.
: >"$co/.git/index.lock"
: >"$co/.git/shallow.lock"
h_plant_event v8 prompt
expire_stamp
h_sentinel_reset
prompt stale-git-locks
h_assert_hook_run stale-git-locks "leftover git lock files"
h_assert_eq "$(h_sentinel | awk '{print $1}')" "v8" "leftover git lock files: cleared, and the new head runs"

# GIT_DIR inherited from a git hook: the tenant's repository is not moved.
repo_head=$(git -C "$repo" rev-parse HEAD)
h_plant_event v9 prompt
expire_stamp
h_sentinel_reset
prompt git-dir GIT_DIR="$repo/.git" GIT_WORK_TREE="$repo" GIT_INDEX_FILE="$repo/.git/index"
h_assert_hook_run git-dir "GIT_DIR inherited"
h_assert_eq "$(git -C "$repo" rev-parse HEAD)" "$repo_head" "GIT_DIR inherited: the tenant's repository HEAD is untouched"
h_assert_empty "$(git -C "$repo" status --porcelain)" "GIT_DIR inherited: the tenant's tree is untouched"
h_assert_eq "$(h_sentinel | awk '{print $1}')" "v9" "GIT_DIR inherited: the checkout still updates and runs"

# The tenant's own git config does not steer the checkout: a URL rewrite to nowhere
# and a hook directory are both ignored.
mkdir -p "$H_TMP/their-hooks"
printf '#!/bin/sh\ntouch "%s/their-hook-ran"\n' "$H_TMP" >"$H_TMP/their-hooks/post-checkout"
chmod +x "$H_TMP/their-hooks/post-checkout"
git config -f "$home/.gitconfig" url.file:///nowhere.insteadOf "file://$H_TMP/apparatus.git"
git config -f "$home/.gitconfig" core.hooksPath "$H_TMP/their-hooks"
h_plant_event v10 prompt
expire_stamp
h_sentinel_reset
prompt their-config
h_assert_eq "$(h_sentinel | awk '{print $1}')" "v10" "the home's git config does not redirect the fetch"
if [ -e "$H_TMP/their-hook-ran" ]; then h_fail "a hook from the home's git config ran"; else h_ok "no hook from the home's git config runs"; fi
rm -f "$home/.gitconfig"

# The log never carries the token: common.sh masks its value and its shape.
body=$(printf 'Q%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)
token="bbdt""_$body"
h_tenant_env "$home" tenant-a "BBD_TOKEN=$token"
(
  # shellcheck source=../launcher/lib/common.sh
  . "$(h_repo_root)/launcher/lib/common.sh"
  HOME=$home
  unset CLAUDE_CONFIG_DIR
  bbd_paths
  bbd_tenant_env "$BBD_ENV_FILE"
  bbd_log "a message carrying $token and bbdt""_${body}"
  # The token is parsed into a variable no child can inherit.
  env | grep -c "$body" || true
) >"$H_TMP/child-env.txt"
h_assert_eq "$(cat "$H_TMP/child-env.txt")" "0" "the token is not exported to child processes"
if grep -q "$body" "$base/state/launcher.log"; then h_fail "the log carries the token"
else h_ok "the log never carries the token"; fi
h_assert_nonempty "$(grep '\[token\]' "$base/state/launcher.log")" "the token is masked in the log"
h_hook_json Stop cwd="$repo" | h_launch with-token "$home" -- "$boot" stop-ship plugin
if grep -rq "$body" "$H_TMP/run" "$base/state" "$base/queue"; then h_fail "a launcher run printed or logged the token"
else h_ok "a launcher run with a token prints and logs none of it"; fi
rm -f "$base/tenant.env"

# The store cannot be reached (nothing listens at its address): the turn ends
# normally, and the session stays queued with the attempt counted.
closed_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
h_tenant_env "$home" tenant-a "BBD_TOKEN=$token" "BBD_INGEST_URL=http://127.0.0.1:$closed_port"
mkdir -p "$H_TMP/transcripts"
cp "$(h_repo_root)/tests/fixtures/transcripts/11111111-2222-4333-8444-555555555551.jsonl" "$H_TMP/transcripts/sid-down.jsonl"
h_hook_json Stop cwd="$repo" session_id=sid-down transcript_path="$H_TMP/transcripts/sid-down.jsonl" \
  | h_launch store-down "$home" -- "$boot" stop-ship plugin
h_assert_hook_run store-down "store unreachable"
if [ -f "$base/queue/sid-down.json" ]; then h_ok "store unreachable: the session stays queued"
else h_fail "store unreachable: the session was dropped"; fi
h_assert_eq "$(h_json_field attempts <"$base/queue/sid-down.json" 2>/dev/null)" 1 "store unreachable: the attempt is counted"
rm -f "$base/tenant.env" "$base/queue/sid-down.json"

# Signed heads. There is no switch to turn the check off: an allowed_signers file,
# wherever the bootstrap looks for one, turns it on. With none anywhere, an unsigned
# head runs. The bootstrap under test is the harness's copy with nothing beside it; the
# file the repository ships beside the plugin copy is tests/test-signed-channel.sh's.
if [ -e "$(dirname "$boot")/../allowed_signers" ]; then
  h_fail "the bootstrap under test has an allowed_signers file beside it; the no-file case cannot be tested"
fi
h_plant_event v5 prompt
expire_stamp
h_sentinel_reset
h_hook_json Hook cwd="$repo" | h_launch no-signers "$home" -- "$boot" prompt plugin
h_assert_hook_run no-signers "no allowed signers anywhere"
h_assert_eq "$(h_sentinel | awk '{print $1}')" "v5" "no allowed signers anywhere: an unsigned head runs"

# A signers file is present but empty: that is not an off switch, every head is
# refused. With no head ever verified, nothing runs, and the transcript still queues.
: >"$base/allowed_signers"
h_plant_event v5b prompt
expire_stamp
h_sentinel_reset
h_hook_json Hook cwd="$repo" | h_launch empty-signers "$home" -- "$boot" prompt plugin
h_assert_hook_run empty-signers "an empty allowed signers file"
h_assert_empty "$(h_run_out empty-signers)" "an empty allowed signers file: nothing on stdout"
h_assert_empty "$(h_sentinel)" "an empty allowed signers file: the unsigned head did not run"
h_assert_eq "$(git -C "$co" rev-parse HEAD)" "$(git -C "$bare" rev-parse stable~1)" "an empty allowed signers file: the unsigned head was not checked out"
h_hook_json Stop cwd="$repo" session_id=sid-unsigned | h_launch unsigned-ship "$home" -- "$boot" stop-ship plugin
h_assert_hook_run unsigned-ship "an unsigned head refused, stop-ship"
if [ -f "$base/queue/sid-unsigned.json" ]; then h_ok "an unsigned head refused: the transcript is still queued"
else h_fail "an unsigned head refused: nothing queued"; fi
rm -f "$base/allowed_signers"

if command -v ssh-keygen >/dev/null 2>&1; then
  # Assembled, so no email address is written into this public file.
  at="@"
  ssh-keygen -q -t ed25519 -N '' -C test -f "$H_TMP/signer" >/dev/null
  ssh-keygen -q -t ed25519 -N '' -C test -f "$H_TMP/stranger" >/dev/null
  signers_line=$(printf 'signer%sexample.invalid namespaces="git" %s' "$at" "$(cut -d' ' -f1,2 "$H_TMP/signer.pub")")
  # publish_signed KEY TAG: a channel head whose prompt event records TAG, signed by KEY.
  publish_signed() {
    # shellcheck disable=SC2016  # the planted script expands H_SENTINEL when it runs
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" %s >>"$H_SENTINEL"\n' "$2" >"$src/launcher/events/prompt.sh"
    chmod +x "$src/launcher/events/prompt.sh"
    git -C "$src" add -A
    git -C "$src" -c user.name=t -c "user.email=t${at}example.invalid" -c gpg.format=ssh \
      -c user.signingkey="$H_TMP/$1" commit -q -S -m "test: signed $2"
    git -C "$src" push -q -f "$bare" HEAD:refs/heads/stable
  }
  # run_signed NAME [VAR=value ...]: one prompt with a fresh fetch.
  run_signed() {
    local name=$1
    shift
    expire_stamp
    h_sentinel_reset
    h_hook_json Hook cwd="$repo" | h_launch "$name" "$home" "$@" -- "$boot" prompt plugin
    h_assert_hook_run "$name" "$name"
    h_assert_empty "$(h_run_out "$name")" "$name: nothing on stdout"
  }

  # The file beside the plugin, found through CLAUDE_PLUGIN_ROOT.
  mkdir -p "$H_TMP/plugin-root"
  printf '%s\n' "$signers_line" >"$H_TMP/plugin-root/allowed_signers"
  publish_signed signer signed-1
  run_signed signed-head CLAUDE_PLUGIN_ROOT="$H_TMP/plugin-root"
  h_assert_eq "$(h_sentinel)" "signed-1" "a correctly signed head is accepted and runs"
  good=$(git -C "$co" rev-parse HEAD)

  h_plant_event v6 prompt
  run_signed unsigned-head CLAUDE_PLUGIN_ROOT="$H_TMP/plugin-root"
  h_assert_eq "$(h_sentinel)" "signed-1" "an unsigned head is refused and the last verified checkout runs"
  h_assert_eq "$(git -C "$co" rev-parse HEAD)" "$good" "an unsigned head is never checked out"

  publish_signed stranger stranger-1
  run_signed stranger-head CLAUDE_PLUGIN_ROOT="$H_TMP/plugin-root"
  h_assert_eq "$(h_sentinel)" "signed-1" "a head signed by a key not allowed is refused and the last verified checkout runs"
  h_assert_eq "$(git -C "$co" rev-parse HEAD)" "$good" "a head signed by a key not allowed is never checked out"

  # The same refusal with the file in the home's own apparatus directory.
  rm -f "$H_TMP/plugin-root/allowed_signers"
  printf '%s\n' "$signers_line" >"$base/allowed_signers"
  run_signed home-signers
  h_assert_eq "$(h_sentinel)" "signed-1" "with the file in CFG/bbd-apparatus, the badly signed head is refused"
  rm -f "$base/allowed_signers"

  # And with the file beside a plugin found from the bootstrap's own location.
  mkdir -p "$H_TMP/plugin/launcher"
  cp "$boot" "$H_TMP/plugin/launcher/bbd-launch.sh"
  printf '%s\n' "$signers_line" >"$H_TMP/plugin/allowed_signers"
  expire_stamp
  h_sentinel_reset
  h_hook_json Hook cwd="$repo" | h_launch beside-signers "$home" -- "$H_TMP/plugin/launcher/bbd-launch.sh" prompt plugin
  h_assert_hook_run beside-signers "allowed signers beside the plugin"
  h_assert_eq "$(h_sentinel)" "signed-1" "with the file beside the plugin, the badly signed head is refused"

  # A newer correctly signed head is accepted again.
  publish_signed signer signed-2
  run_signed signed-again CLAUDE_PLUGIN_ROOT="$H_TMP/plugin"
  h_assert_eq "$(h_sentinel)" "signed-2" "a later correctly signed head is accepted"
  rm -f "$H_TMP/plugin/allowed_signers"
else
  echo "skip: no ssh-keygen, signed and badly signed heads not checked"
fi

h_done
