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
repo_copy="$(h_repo_root)/templates/tenant-repo/.claude/hooks/bbd-launch.sh"
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

h_done
