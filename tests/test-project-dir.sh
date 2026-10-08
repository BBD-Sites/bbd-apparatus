#!/usr/bin/env bash
# The launcher acts on the project it was fired for: CLAUDE_PROJECT_DIR, else the hook
# JSON's cwd, never the shell's own directory (the spike's defect: a hook fired for
# one repository while the shell sat in another). A worktree, whose .git is a file,
# is a project. A dead working directory is survived. Each case plants the wrong
# directory where a careless launcher would look, and checks which root ran.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

h_fake_bin git
h_fake_apparatus >/dev/null
h_plant_event v1 prompt
boot=$(h_bootstrap)
home=$(h_fake_home h1)
a=$(h_fake_repo alpha)
b=$(h_fake_repo beta)
h_mark "$a" tenant-a
h_mark "$b" tenant-a
mkdir -p "$b/sub/dir"

# ran_root NAME: the project root the planted event saw, or nothing.
ran_root() { h_sentinel | awk '{print $3}'; }

# CLAUDE_PROJECT_DIR wins over both the JSON cwd and the shell's directory.
h_sentinel_reset
(cd "$a" && h_hook_json UserPromptSubmit cwd="$a" \
  | h_launch env-wins "$home" CLAUDE_PROJECT_DIR="$b" -- "$boot" prompt plugin)
h_assert_hook_run env-wins "CLAUDE_PROJECT_DIR set"
h_assert_eq "$(ran_root)" "$b" "CLAUDE_PROJECT_DIR wins over the JSON cwd and the shell cwd"

# With no CLAUDE_PROJECT_DIR, the JSON cwd wins over the shell's directory, and a
# subdirectory resolves to its work tree's top level.
h_sentinel_reset
(cd "$a" && h_hook_json UserPromptSubmit cwd="$b/sub/dir" \
  | h_launch json-cwd "$home" -- "$boot" prompt plugin)
h_assert_hook_run json-cwd "JSON cwd only"
h_assert_eq "$(ran_root)" "$b" "the JSON cwd wins over the shell cwd, resolved to the top level"

# Neither given: the shell's directory is a marked repository, and still nothing runs.
h_sentinel_reset
(cd "$a" && printf '{"session_id":"s1"}' | h_launch no-root "$home" -- "$boot" prompt plugin)
h_assert_hook_run no-root "no project dir and no JSON cwd"
h_assert_empty "$(h_sentinel)" "the shell cwd alone is never taken as the project"

# A worktree counts as a project, though its .git is a file.
wt="$H_TMP/alpha-worktree"
git -C "$a" worktree add -q -b wt "$wt" 2>/dev/null
if [ -f "$wt/.git" ]; then h_ok "the worktree's .git is a file"; else h_fail "the worktree's .git is not a file"; fi
h_sentinel_reset
h_hook_json UserPromptSubmit cwd="$wt" | h_launch worktree "$home" CLAUDE_PROJECT_DIR="$wt" -- "$boot" prompt plugin
h_assert_hook_run worktree "a worktree"
h_assert_eq "$(ran_root)" "$wt" "a worktree is a project, under its own root"
h_hook_json Stop cwd="$wt" session_id=sid-wt | h_launch worktree-ship "$home" CLAUDE_PROJECT_DIR="$wt" -- "$boot" stop-ship plugin
if [ -f "$home/.claude/bbd-apparatus/queue/sid-wt.json" ]; then h_ok "a worktree's turn is queued"
else h_fail "a worktree's turn was not queued"; fi

# The project dir given is not a repository, or does not exist: nothing runs.
mkdir -p "$H_TMP/plain"
for d in "$H_TMP/plain" "$H_TMP/missing"; do
  h_sentinel_reset
  (cd "$a" && h_hook_json UserPromptSubmit cwd="$a" | h_launch "not-repo" "$home" CLAUDE_PROJECT_DIR="$d" -- "$boot" prompt plugin)
  h_assert_hook_run not-repo "CLAUDE_PROJECT_DIR not a repository ($(basename "$d"))"
  h_assert_empty "$(h_sentinel)" "CLAUDE_PROJECT_DIR not a repository ($(basename "$d")): the shell cwd is not used instead"
done

# A dead working directory: the shell starts in a directory that was deleted.
dead="$H_TMP/dead"
mkdir -p "$dead"
h_sentinel_reset
(
  cd "$dead" || exit 1
  rmdir "$dead"
  h_hook_json UserPromptSubmit cwd="$b" 2>/dev/null \
    | h_launch dead-cwd "$home" CLAUDE_PROJECT_DIR="$b" -- "$boot" prompt plugin
)
h_assert_hook_run dead-cwd "a dead working directory"
h_assert_eq "$(ran_root)" "$b" "a dead working directory is survived and the project still runs"
(
  mkdir -p "$dead" && cd "$dead" && rmdir "$dead"
  h_launch dead-ship "$home" CLAUDE_PROJECT_DIR="$b" -- "$boot" stop-ship plugin <<JSON
{"session_id":"sid-dead","transcript_path":"/x/sid-dead.jsonl","cwd":"$b"}
JSON
)
h_assert_hook_run dead-ship "a dead working directory, stop-ship"
if [ -f "$home/.claude/bbd-apparatus/queue/sid-dead.json" ]; then h_ok "a dead working directory: the turn is queued"
else h_fail "a dead working directory: the turn was not queued"; fi

h_done
