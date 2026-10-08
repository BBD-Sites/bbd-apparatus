#!/usr/bin/env bash
# The captures branch (docs/launcher-contract.md section 10): a home with no token,
# such as a cloud session's machine, commits the redacted copy to refs/heads/captures
# of the tenant's own repository by git plumbing and pushes it. Against local bare
# remotes: the commit lands only on that branch; the working branch, the index and
# the working tree are untouched; the commit has no parent and the neutral identity;
# a second session's push keeps the first's file; a lease that went stale is retried;
# and a remote that cannot be reached keeps the queue.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

h_fake_bin git
h_fake_apparatus >/dev/null
repo_copy=$(h_bootstrap repo)
repo=$(h_fake_repo vault)
h_mark "$repo" tenant-a
remote="$H_TMP/vault.git"
fixture="$(h_repo_root)/tests/fixtures/transcripts/11111111-2222-4333-8444-555555555551.jsonl"
render() { PYTHONDONTWRITEBYTECODE=1 python3 "$(h_repo_root)/bin/apparatus" render "$1"; }

transcript() { # SESSION [EXTRA-TEXT]
  local t="$H_TMP/transcripts/$1.jsonl"
  mkdir -p "$H_TMP/transcripts"
  cp "$fixture" "$t"
  if [ -n "${2:-}" ]; then
    python3 -c 'import json,sys
print(json.dumps({"type": "user", "timestamp": "2026-01-05T10:20:00.000Z", "cwd": "/srv/projects/demo-notes",
  "message": {"role": "user", "content": sys.argv[1]}}))' "$2" >>"$t"
  fi
}

# ship NAME HOME REPO SESSION [VAR=value ...]: one cloud Stop ship turn, from the
# repository's own copy of the bootstrap, as a cloud session runs it.
ship() {
  local name=$1 home=$2 r=$3 sid=$4
  shift 4
  h_hook_json Stop cwd="$r" session_id="$sid" transcript_path="$H_TMP/transcripts/$sid.jsonl" \
    | h_launch "$name" "$home" CLAUDE_CODE_REMOTE=true CLAUDE_PROJECT_DIR="$r" "$@" -- "$repo_copy" stop-ship repo
}
on_remote() { git -C "$remote" "$@"; }
captured() { on_remote ls-tree --name-only -r refs/heads/captures 2>/dev/null | tr '\n' ' '; }

# The tenant has work in progress: a staged file and an edited one.
printf 'staged\n' >"$repo/staged.txt"
git -C "$repo" add staged.txt
printf 'edited\n' >>"$repo/README.md"
before_head=$(git -C "$repo" rev-parse HEAD)
before_branch=$(git -C "$repo" symbolic-ref HEAD)
before_index=$(git -C "$repo" ls-files -s --debug | cksum)
before_status=$(git -C "$repo" status --porcelain)
before_main=$(on_remote rev-parse refs/heads/main)

cloud=$(h_fake_home cloud)
transcript c1
h_calls_reset git
ship first "$cloud" "$repo" c1
h_assert_hook_run first "first capture"
h_assert_eq "$(captured)" "captures/c1.md " "first capture: the remote captures branch holds the session's file"
h_assert_eq "$(on_remote show refs/heads/captures:captures/c1.md)" "$(render "$H_TMP/transcripts/c1.jsonl")" \
  "first capture: the file is the redacted rendering"
if on_remote show refs/heads/captures:captures/c1.md | grep -q 'REDACTED:'; then h_ok "first capture: the file is redacted"
else h_fail "first capture: no redaction marker in the file"; fi
h_assert_eq "$(on_remote rev-list --parents -n 1 refs/heads/captures | wc -w | tr -d ' ')" 1 "first capture: the commit has no parent"
h_assert_eq "$(on_remote log -1 --format='%an <%ae>|%cn <%ce>' refs/heads/captures)" \
  "apparatus maintainers <apparatus-maintainers@users.noreply.github.com>|apparatus maintainers <apparatus-maintainers@users.noreply.github.com>" \
  "first capture: the commit carries the neutral identity"
h_assert_eq "$(on_remote rev-parse refs/heads/main)" "$before_main" "first capture: the remote's main is untouched"
h_assert_eq "$(on_remote for-each-ref --format='%(refname)' | tr '\n' ' ')" "refs/heads/captures refs/heads/main " \
  "first capture: no other remote ref was made"
h_assert_eq "$(git -C "$repo" rev-parse HEAD)" "$before_head" "first capture: the working branch's HEAD is untouched"
h_assert_eq "$(git -C "$repo" symbolic-ref HEAD)" "$before_branch" "first capture: the checked-out branch is unchanged"
h_assert_eq "$(git -C "$repo" ls-files -s --debug | cksum)" "$before_index" "first capture: the index is untouched"
h_assert_eq "$(git -C "$repo" status --porcelain)" "$before_status" "first capture: the working tree is untouched"
h_assert_empty "$(git -C "$repo" for-each-ref --format='%(refname)' refs/heads | grep captures || true)" \
  "first capture: no local branch was made"
if [ -f "$cloud/.claude/bbd-apparatus/queue/c1.json" ]; then h_fail "first capture: the pushed session is still queued"
else h_ok "first capture: the pushed session leaves the queue"; fi
tenant_calls=$(h_calls git | grep -F -e "-C $repo " || true)
h_assert_nonempty "$tenant_calls" "first capture: git ran on the tenant's repository"
h_assert_empty "$(printf '%s\n' "$tenant_calls" | grep -E '(^| )(checkout|switch|reset|add|stash|commit|merge|rebase|update-ref|branch)( |$)' || true)" \
  "first capture: no git command that moves a branch or touches the work tree or index ran on it"

# A second session, from another machine's clone: both files are kept.
second=$(h_fake_home second)
clone2="$H_TMP/clone2"
h_git clone -q "$remote" "$clone2"
transcript c2
ship second "$second" "$clone2" c2
h_assert_eq "$(captured)" "captures/c1.md captures/c2.md " "a second session's push keeps the first session's file"
h_assert_eq "$(on_remote show refs/heads/captures:captures/c1.md)" "$(render "$H_TMP/transcripts/c1.jsonl")" \
  "the second push leaves the first file's content as it was"
h_assert_eq "$(on_remote rev-list --parents -n 1 refs/heads/captures | wc -w | tr -d ' ')" 1 "the second commit has no parent either"

# A later turn of the first session replaces only its own file.
transcript c1 "one more turn"
ship again "$cloud" "$repo" c1
h_assert_eq "$(captured)" "captures/c1.md captures/c2.md " "a later turn: still one file per session"
h_assert_eq "$(on_remote show refs/heads/captures:captures/c1.md)" "$(render "$H_TMP/transcripts/c1.jsonl")" \
  "a later turn: the session's file holds its latest transcript"
h_assert_eq "$(on_remote show refs/heads/captures:captures/c2.md)" "$(render "$H_TMP/transcripts/c2.jsonl")" \
  "a later turn: the other session's file is untouched"

# Another session pushes between this one's fetch and its push: the lease is stale,
# so the push is refused, and the retry rebuilds on the newer branch.
third=$(h_fake_home third)
sneak="$H_TMP/sneak"
h_git clone -q "$remote" "$sneak"
git -C "$sneak" fetch -q origin captures
cat >"$H_TMP/before-push.sh" <<EOF
blob=\$(printf 'sneaked\n' | git -C "$sneak" hash-object -w --stdin)
sub=\$( { git -C "$sneak" ls-tree FETCH_HEAD:captures; printf '100644 blob %s\tc9.md\n' "\$blob"; } | git -C "$sneak" mktree)
top=\$(printf '040000 tree %s\tcaptures\n' "\$sub" | git -C "$sneak" mktree)
c=\$(GIT_AUTHOR_NAME=x GIT_AUTHOR_EMAIL=x GIT_COMMITTER_NAME=x GIT_COMMITTER_EMAIL=x git -C "$sneak" commit-tree "\$top" -m sneak)
git -C "$sneak" push -q -f origin "\$c:refs/heads/captures"
EOF
transcript c3
h_calls_reset git
ship stale "$third" "$repo" c3 H_FAKE_GIT_BEFORE_PUSH="$H_TMP/before-push.sh"
if [ -f "$H_TMP/before-push.sh.ran" ]; then h_ok "stale lease: the other session's push ran in between"
else h_fail "stale lease: the planted push never ran"; fi
h_assert_eq "$(captured)" "captures/c1.md captures/c2.md captures/c3.md captures/c9.md " \
  "stale lease: the retry keeps the other session's file and adds this one"
h_assert_eq "$(h_calls git | grep -c ' push -q --force-with-lease')" 2 "stale lease: refused once, then pushed"

# Sessions on three machines at once: every file lands.
for n in 4 5 6; do
  transcript "c$n"
  h_git clone -q "$remote" "$H_TMP/clone$n"
  ship "par$n" "$(h_fake_home "par$n")" "$H_TMP/clone$n" "c$n" &
done
wait
h_assert_eq "$(captured)" "captures/c1.md captures/c2.md captures/c3.md captures/c4.md captures/c5.md captures/c6.md captures/c9.md " \
  "concurrent sessions: every session's file lands"

# A remote that cannot be reached: exit 0, and the session stays queued for later.
offline=$(h_fake_home offline)
clone7="$H_TMP/clone7"
h_git clone -q "$remote" "$clone7"
git -C "$clone7" remote set-url origin "$H_TMP/no-such-remote.git"
transcript c7
ship unreachable "$offline" "$clone7" c7
h_assert_hook_run unreachable "remote unreachable"
if [ -f "$offline/.claude/bbd-apparatus/queue/c7.json" ]; then h_ok "remote unreachable: the session stays queued"
else h_fail "remote unreachable: the session was dropped"; fi
case "$(captured)" in *c7.md*) h_fail "remote unreachable: the file reached the remote anyway" ;;
  *) h_ok "remote unreachable: nothing was pushed" ;; esac

# Two tenants' marked repositories on one home with no install. A session in A is
# left queued, and B's next Stop must not carry it into B's captures branch: the
# hook acts only on the project it was fired for, and each tenant's store holds only
# its own sessions. A's pointer waits, and A's own next Stop ships it to A.
shared=$(h_fake_home shared)
squeue="$shared/.claude/bbd-apparatus/queue"
ra=$(h_fake_repo tenant-a-vault)
h_mark "$ra" tenant-a
rb=$(h_fake_repo tenant-b-vault)
h_mark "$rb" tenant-b
captured_in() { git -C "$1" ls-tree --name-only -r refs/heads/captures 2>/dev/null | tr '\n' ' '; }

# A's session ends while A's remote is out of reach, so its pointer stays queued.
git -C "$ra" remote set-url origin "$H_TMP/no-such-remote.git"
transcript xa1
ship xa1 "$shared" "$ra" xa1
git -C "$ra" remote set-url origin "$H_TMP/tenant-a-vault.git"
if [ -f "$squeue/xa1.json" ]; then h_ok "two tenants: A's session is queued"; else h_fail "two tenants: A's session was not queued"; fi
# A pointer the bootstrap wrote before any checkout existed carries no project; its
# transcript's own working directory says where it belongs.
mkdir -p "$H_TMP/transcripts"
sed "s#/srv/projects/demo-notes#$ra#g" "$fixture" >"$H_TMP/transcripts/xa0.jsonl"
python3 -c 'import json,sys; json.dump({"session_id": "xa0", "transcript_path": sys.argv[1], "where": "desktop",
  "first_seen": "2026-01-01T00:00:00Z", "attempts": 0}, open(sys.argv[2], "w"))' "$H_TMP/transcripts/xa0.jsonl" "$squeue/xa0.json"

transcript xb1
ship xb1 "$shared" "$rb" xb1
h_assert_hook_run xb1 "two tenants, B fires"
h_assert_eq "$(captured_in "$H_TMP/tenant-b-vault.git")" "captures/xb1.md " "two tenants: B's captures branch holds only B's session"
if [ -f "$squeue/xa1.json" ] && [ -f "$squeue/xa0.json" ]; then h_ok "two tenants: A's pointers are still queued after B's Stop"
else h_fail "two tenants: B's Stop took A's pointers"; fi
h_assert_empty "$(captured_in "$H_TMP/tenant-a-vault.git")" "two tenants: nothing reached A's remote from B's Stop"

transcript xa2
ship xa2 "$shared" "$ra" xa2
h_assert_eq "$(captured_in "$H_TMP/tenant-a-vault.git")" "captures/xa0.md captures/xa1.md captures/xa2.md " \
  "two tenants: A's next Stop ships A's queued sessions to A"
h_assert_eq "$(captured_in "$H_TMP/tenant-b-vault.git")" "captures/xb1.md " "two tenants: B's branch is still only B's"
if [ -f "$squeue/xa1.json" ] || [ -f "$squeue/xa0.json" ]; then h_fail "two tenants: A's pointers are still queued after A shipped"
else h_ok "two tenants: A's pointers leave the queue once A ships them"; fi

# A cloud session (no token, the repository's own copy of the hook, which the
# harness kills at 60 seconds) with slow old entries queued for the same repository.
# The firing session must reach the captures branch first, on its own, and the step
# must end inside the repository delivery's bound, so the harness never kills it
# before the turn is pushed: the cloud machine's queue is lost when it is reclaimed.
# Last in this file, because it plants a render that is slow for these entries.
real_apparatus=$(cat "$(h_repo_root)/bin/apparatus")
h_apparatus_file bin/apparatus "$(printf '%s\n' "$real_apparatus" | python3 -c '
import sys
src = sys.stdin.read()
hook = (
    "\n# Planted by tests/test-captures-branch.sh: a render that takes 25 seconds for a\n"
    "# transcript whose name says slow, standing in for a large or stuck transcript.\n"
    "if len(sys.argv) > 2 and sys.argv[1] == \"render\" and \"slow\" in sys.argv[2]:\n"
    "    import time\n"
    "    time.sleep(25)\n"
)
marker = "from pathlib import Path\n"
assert marker in src
sys.stdout.write(src.replace(marker, marker + hook, 1))')"
cloudhome=$(h_fake_home cloud-slow)
cqueue="$cloudhome/.claude/bbd-apparatus/queue"
rc_repo=$(h_fake_repo cloud-vault)
h_mark "$rc_repo" tenant-a
mkdir -p "$cqueue"
for n in 1 2 3; do
  sed "s#/srv/projects/demo-notes#$rc_repo#g" "$fixture" >"$H_TMP/transcripts/slow$n.jsonl"
  python3 -c 'import json,sys; json.dump({"session_id": sys.argv[1], "transcript_path": sys.argv[2], "where": "cloud",
    "first_seen": "2026-01-0%sT00:00:00Z" % sys.argv[3], "attempts": 0}, open(sys.argv[4], "w"))' \
    "slow$n" "$H_TMP/transcripts/slow$n.jsonl" "$n" "$cqueue/slow$n.json"
done
chmod 700 "$cqueue"
transcript cf1
start=$(date +%s)
( ship cloud-slow "$cloudhome" "$rc_repo" cf1 ) &
job=$!
reached=""
while kill -0 "$job" 2>/dev/null; do
  if [ -z "$reached" ] && captured_in "$H_TMP/cloud-vault.git" | grep -q 'captures/cf1.md'; then
    reached=$(($(date +%s) - start))
  fi
  sleep 0.5
done
wait "$job"
total=$(($(date +%s) - start))
if [ -z "$reached" ] && captured_in "$H_TMP/cloud-vault.git" | grep -q 'captures/cf1.md'; then reached=$total; fi
h_assert_hook_run cloud-slow "a cloud session with slow old entries"
if [ -n "$reached" ] && [ "$reached" -le 20 ]; then h_ok "cloud, slow old entries: the firing session reached the branch first (${reached}s)"
else h_fail "cloud, slow old entries: the firing session reached the branch late or never (${reached:-never}s)"; fi
if [ "$total" -le 55 ]; then h_ok "cloud, slow old entries: the step ended inside the repository bound (${total}s)"
else h_fail "cloud, slow old entries: the step ran ${total}s, past the repository bound"; fi
if [ -f "$cqueue/slow1.json" ]; then h_ok "cloud, slow old entries: an old entry that did not fit stays queued"
else h_fail "cloud, slow old entries: an old entry that did not fit was dropped"; fi

h_done
