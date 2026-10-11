#!/usr/bin/env bash
# Saving the buyer's vault for them at the end of a turn (lib/vaultsync.py, run by the
# Stop ship step; docs/launcher-contract.md section 14). Local bare remotes stand in
# for the buyer's repository, and a second work tree stands in for the other surface.
#
# What changed under the vault's folders is committed with a plain message and pushed
# on the current branch. Nothing is committed, fetched or pushed when the working tree
# holds anything outside the vault's folders, in a detached head, with no remote branch
# reachable (the commit waits), or when the marker turns it off. The remote is brought
# current before the push; two surfaces that changed the same lines both survive on the
# page between marker lines and the page is named in the next prompt; a deleted page the
# other side changed keeps the changed page; a binary file keeps both files. A push is
# never forced: a remote that was rewritten is left as it is. A hung remote ends inside
# the bound. Last, the whole thing through the bootstrap's Stop ship step.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

sync_py="$(h_repo_root)/lib/vaultsync.py"
export PYTHONDONTWRITEBYTECODE=1
h_fake_bin git
tmp=$(h_tmpdir)

vault=$(h_fake_repo vault)
h_mark "$vault" tenant-a
remote="$tmp/vault.git"
settle1="$tmp/settle1.txt"
settle2="$tmp/settle2.txt"

surface=$tmp/surface2
git clone -q "$remote" "$surface" 2>/dev/null
git -C "$surface" config user.name "$H_GIT_NAME"
git -C "$surface" config user.email "$H_GIT_EMAIL"
git -C "$surface" config commit.gpgsign false

# sync ROOT [SETTLE]: the status line.
sync_in() { python3 "$sync_py" sync "$1" --deadline "${3:-20}" --settle "${2:-$settle1}"; }
head_of() { git -C "$1" rev-parse HEAD; }
remote_head() { git -C "$remote" rev-parse "refs/heads/${1:-main}" 2>/dev/null; }
put() { mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" >"$1/$2"; }
surface_save() { # MESSAGE: commit everything on the other surface and push main
  git -C "$surface" add -A
  h_git -C "$surface" commit -q -m "$1"
  git -C "$surface" push -q origin HEAD:main
}
surface_pull() { git -C "$surface" pull -q --no-rebase --no-edit origin main 2>/dev/null; }
pushes() { h_calls git | grep -E ' push ' || true; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# 1. A tree that holds anything outside the vault's folders is not the apparatus's to
# save: no commit, no fetch, no push, whatever else is in it.
put "$vault" "30-projects/alpha.md" "alpha one"
put "$vault" "src/app.js" "half built"
before_head=$(head_of "$vault")
h_calls_reset git
h_assert_eq "$(sync_in "$vault")" outside "a half-built site beside the notes: left alone"
h_assert_eq "$(head_of "$vault")" "$before_head" "outside: no commit"
h_assert_empty "$(h_net_calls)" "outside: no commit, fetch or push attempted"
h_assert_eq "$(remote_head)" "$before_head" "outside: the remote is untouched"
rm -f "$vault/src/app.js"
rmdir "$vault/src"

# 2. Only the vault's own changes: committed with a plain message and pushed on main.
put "$vault" "00-inbox/note.md" "a thought"
h_assert_eq "$(sync_in "$vault")" pushed "notes under the vault folders: committed and pushed"
h_assert_eq "$(remote_head)" "$(head_of "$vault")" "the remote has the new commit"
h_assert_empty "$(git -C "$vault" status --porcelain)" "the tree is clean afterwards"
msg=$(git -C "$vault" log -1 --format=%s)
case "$msg" in "Save your notes: 2 changes in 00-inbox, 30-projects") h_ok "the message is plain and counts the changes" ;; *) h_fail "the message is [$msg]" ;; esac
h_assert_eq "$(git -C "$vault" log -1 --format='%an <%ae>')" "$H_GIT_NAME <$H_GIT_EMAIL>" "the commit is in the repository's own identity"
forced() { h_calls git | grep ' push ' | grep -E -- '--force|--force-with-lease| -f |HEAD:\+|\+refs' || true; }
h_assert_empty "$(forced)" "no push was forced"

# 3. Again with nothing new: no commit, no push.
before_head=$(head_of "$vault")
h_calls_reset git
h_assert_eq "$(sync_in "$vault")" nothing "nothing new: nothing done"
h_assert_eq "$(head_of "$vault")" "$before_head" "nothing new: no empty commit"
h_assert_empty "$(pushes)" "nothing new: no push"

# 4. The remote is ahead and the local side adds its own: the push is brought current
# first, both sides' pages are in the result, and the other surface's page is here.
surface_pull
put "$surface" "40-areas/home.md" "from the phone"
surface_save "from the other surface"
put "$vault" "20-ideas/idea.md" "from the desktop"
h_calls_reset git
h_assert_eq "$(sync_in "$vault")" pushed "both sides changed different pages: merged and pushed"
h_assert_eq "$(remote_head)" "$(head_of "$vault")" "the remote has the merge"
for f in 40-areas/home.md 20-ideas/idea.md 30-projects/alpha.md; do
  if git -C "$remote" cat-file -e "main:$f" 2>/dev/null; then h_ok "the remote holds $f"; else h_fail "the remote lost $f"; fi
done
if [ -f "$vault/40-areas/home.md" ]; then h_ok "the other surface's page is here"; else h_fail "the other surface's page did not arrive"; fi
h_assert_empty "$(forced)" "the merge was pushed without force"

# 5. The remote is ahead and nothing local changed: the vault is brought current.
surface_pull
put "$surface" "10-references/ref.md" "a reference"
surface_save "another page"
h_assert_eq "$(sync_in "$vault")" merged "the remote is ahead and nothing is local: fast-forwarded"
if [ -f "$vault/10-references/ref.md" ]; then h_ok "the new page arrived"; else h_fail "the new page did not arrive"; fi
h_assert_eq "$(head_of "$vault")" "$(remote_head)" "the heads match"

# 6. Both surfaces changed the same line: both versions stay on the page, marked, the
# page is named, the remote has it, and the next prompt tells the model to settle it.
surface_pull
put "$surface" "30-projects/alpha.md" "alpha from the phone"
surface_save "phone edit"
put "$vault" "30-projects/alpha.md" "alpha from the desktop"
status=$(sync_in "$vault")
h_assert_eq "$status" "kept-both:1" "the same line changed on both sides: both kept"
page=$(cat "$vault/30-projects/alpha.md")
if has "$page" "alpha from the phone" && has "$page" "alpha from the desktop"; then h_ok "both versions are on the page"; else h_fail "a version was lost: $page"; fi
if has "$page" "<<<<<<< kept from this surface" && has "$page" ">>>>>>> kept from the other surface"; then h_ok "the versions are marked"; else h_fail "the versions are not marked: $page"; fi
h_assert_eq "$(remote_head)" "$(head_of "$vault")" "the marked page is pushed, not left on one machine"
note=$(python3 "$sync_py" settle "$vault" "$settle1" "$(h_repo_root)/text/settle.md")
if has "$note" "30-projects/alpha.md" && has "$note" "which one to keep"; then h_ok "the next turn is told which page to settle"; else h_fail "the settle note is wrong: [$note]"; fi
# The other surface pulls the marked page and is told too.
before=$(head_of "$surface")
h_assert_eq "$(sync_in "$surface" "$settle2")" merged "the other surface brings the marked page in"
h_assert_neq() { if [ "$1" != "$2" ]; then h_ok "$3"; else h_fail "$3"; fi; }
h_assert_neq "$(head_of "$surface")" "$before" "the other surface moved"
note=$(python3 "$sync_py" settle "$surface" "$settle2" "$(h_repo_root)/text/settle.md")
if has "$note" "30-projects/alpha.md"; then h_ok "the other surface is told as well"; else h_fail "the other surface is not told: [$note]"; fi
# The buyer settles it: the markers go, and the note goes with them.
put "$vault" "30-projects/alpha.md" "alpha from the phone"
h_assert_eq "$(sync_in "$vault")" pushed "the settled page is saved"
h_assert_empty "$(python3 "$sync_py" settle "$vault" "$settle1" "$(h_repo_root)/text/settle.md")" "a settled page is no longer named"

# 7. A page one side deleted and the other changed keeps the changed page.
put "$vault" "30-projects/gone.md" "to be deleted"
sync_in "$vault" >/dev/null
surface_pull
git -C "$surface" rm -q 30-projects/gone.md
surface_save "delete a page"
put "$vault" "30-projects/gone.md" "changed after the other side deleted it"
sync_in "$vault" >/dev/null
if [ -f "$vault/30-projects/gone.md" ] && has "$(cat "$vault/30-projects/gone.md")" "changed after"; then h_ok "the changed page survives the other side's delete"; else h_fail "the changed page was lost"; fi
h_assert_eq "$(remote_head)" "$(head_of "$vault")" "and it is pushed"

# 8. A binary file changed on both sides keeps both files.
surface_pull
printf 'BIN\000one' >"$vault/attachments-seed.tmp"
mkdir -p "$vault/attachments"
mv "$vault/attachments-seed.tmp" "$vault/attachments/logo.bin"
sync_in "$vault" >/dev/null
surface_pull
printf 'BIN\000phone' >"$surface/attachments/logo.bin"
surface_save "phone logo"
printf 'BIN\000desktop' >"$vault/attachments/logo.bin"
sync_in "$vault" >/dev/null
if [ -f "$vault/attachments/logo.bin" ] && [ -f "$vault/attachments/logo.bin.other" ]; then h_ok "a binary conflict keeps both files"; else h_fail "a binary conflict lost a file"; fi
h_assert_eq "$(remote_head)" "$(head_of "$vault")" "both binary files are pushed"

# 9. The current branch, not main.
git -C "$vault" checkout -q -b notes-branch
put "$vault" "00-inbox/branch.md" "on a branch"
main_before=$(remote_head main)
h_assert_eq "$(sync_in "$vault")" pushed "a feature branch: pushed"
h_assert_eq "$(remote_head notes-branch)" "$(head_of "$vault")" "the commit is on the buyer's branch on the remote"
h_assert_eq "$(remote_head main)" "$main_before" "main is untouched"
git -C "$vault" checkout -q main

# 10. A detached head, a marker that turns it off.
git -C "$vault" checkout -q --detach
put "$vault" "00-inbox/detached.md" "detached"
h_assert_eq "$(sync_in "$vault")" detached "a detached head: left alone"
rm -f "$vault/00-inbox/detached.md"
git -C "$vault" checkout -q main
python3 - "$vault/.apparatus/vault.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["sync"] = False
json.dump(d, open(sys.argv[1], "w"))
PY
put "$vault" "00-inbox/off.md" "off"
h_assert_eq "$(sync_in "$vault")" off "a marker with sync false: nothing is saved"
git -C "$vault" checkout -q -- .apparatus/vault.json
rm -f "$vault/00-inbox/off.md"
h_assert_empty "$(git -C "$vault" status --porcelain)" "the tree is back to clean"

# 11. The marker's own folders replace the default list.
python3 - "$vault/.apparatus/vault.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["folders"] = ["notes"]
json.dump(d, open(sys.argv[1], "w"))
PY
git -C "$vault" add .apparatus/vault.json
h_git -C "$vault" commit -q -m "chore: folders"
git -C "$vault" push -q origin HEAD:main
put "$vault" "notes/a.md" "in the named folder"
h_assert_eq "$(sync_in "$vault")" pushed "a folder the marker names is saved"
put "$vault" "30-projects/b.md" "no longer a vault folder here"
h_assert_eq "$(sync_in "$vault")" outside "a default folder the marker does not name is outside"
rm -f "$vault/30-projects/b.md"
git -C "$vault" revert -q --no-edit HEAD~1 2>/dev/null || true

# 12. A remote that cannot be reached: the commit waits, and the next turn pushes it.
vault2=$(h_fake_repo second)
h_mark "$vault2" tenant-a
git -C "$vault2" remote set-url origin "$tmp/nowhere.git"
put "$vault2" "00-inbox/offline.md" "written offline"
h_assert_eq "$(sync_in "$vault2" "$tmp/s3.txt")" offline "an unreachable remote: offline"
h_assert_empty "$(git -C "$vault2" status --porcelain)" "offline: the page is committed locally"
git -C "$vault2" remote set-url origin "$tmp/second.git"
h_assert_eq "$(sync_in "$vault2" "$tmp/s3.txt")" pushed "reachable again: the waiting commit is pushed"
h_assert_eq "$(git -C "$tmp/second.git" rev-parse refs/heads/main)" "$(head_of "$vault2")" "the remote has it"

# 13. No remote at all: committed, nothing to push.
vault3=$tmp/third
git init -q "$vault3"
git -C "$vault3" symbolic-ref HEAD refs/heads/main
git -C "$vault3" config user.name "$H_GIT_NAME"
git -C "$vault3" config user.email "$H_GIT_EMAIL"
git -C "$vault3" config commit.gpgsign false
h_mark_local() { mkdir -p "$1/.apparatus"; printf '{"schema":1,"tenant":"tenant-a","channel":"stable","rules":"RULES.md"}\n' >"$1/.apparatus/vault.json"; }
h_mark_local "$vault3"
git -C "$vault3" add -A
h_git -C "$vault3" commit -q -m "chore: marker"
put "$vault3" "00-inbox/x.md" "local only"
h_assert_eq "$(sync_in "$vault3" "$tmp/s4.txt")" committed "no remote: committed and nothing pushed"

# 14. A remote that was rewritten is never overwritten: unrelated history refuses to
# merge, the status says so, the local commit stays, and the remote is as it was.
vault4=$(h_fake_repo fourth)
h_mark "$vault4" tenant-a
rewrite=$tmp/rewrite
git clone -q "$tmp/fourth.git" "$rewrite" 2>/dev/null
git -C "$rewrite" checkout -q --orphan fresh
git -C "$rewrite" rm -rf -q . 2>/dev/null
put "$rewrite" "README.md" "a different history"
git -C "$rewrite" add -A
h_git -C "$rewrite" commit -q -m "unrelated"
git -C "$rewrite" push -q --force origin fresh:main 2>/dev/null
rewritten=$(git -C "$tmp/fourth.git" rev-parse refs/heads/main)
put "$vault4" "00-inbox/mine.md" "my page"
h_assert_eq "$(sync_in "$vault4" "$tmp/s5.txt")" failed "unrelated history: not merged, not pushed"
h_assert_eq "$(git -C "$tmp/fourth.git" rev-parse refs/heads/main)" "$rewritten" "the rewritten remote was not overwritten"
if git -C "$vault4" log --format=%s | grep -q '^Save your notes'; then h_ok "the local commit is kept"; else h_fail "the local commit was lost"; fi
h_assert_empty "$(git -C "$vault4" status --porcelain)" "the tree is clean, and in no half-merged state"

# 15. A remote that hangs ends inside the bound.
vault5=$(h_fake_repo fifth)
h_mark "$vault5" tenant-a
put "$vault5" "00-inbox/slow.md" "slow remote"
start=$(date +%s)
status=$(H_FAKE_GIT_FETCH=hang H_FAKE_GIT_HANG=30 sync_in "$vault5" "$tmp/s6.txt" 3)
took=$(( $(date +%s) - start ))
h_assert_eq "$status" offline "a hung fetch: offline"
if [ "$took" -le 10 ]; then h_ok "a hung fetch ends inside the bound (${took}s)"; else h_fail "a hung fetch took ${took}s"; fi

# 16. Through the bootstrap, as a session fires it: the Stop ship step saves the vault,
# a tree with a stray file is left alone, the prompt after a two-surface edit names the
# page, and an unmarked repository is never touched.
h_fake_apparatus >/dev/null
boot=$(h_bootstrap)
home=$(h_fake_home h1)
h_tenant_env "$home" tenant-a "BBD_CHANNEL=stable"
base="$home/.claude/bbd-apparatus"
vault6=$(h_fake_repo sixth)
h_mark "$vault6" tenant-a
put "$vault6" "30-projects/stop.md" "saved at the end of the turn"
h_hook_json Stop cwd="$vault6" session_id=sid-sync | h_launch stop-ok "$home" CLAUDE_PROJECT_DIR="$vault6" -- "$boot" stop-ship plugin
h_assert_hook_run stop-ok "a Stop in a marked vault"
h_assert_eq "$(git -C "$tmp/sixth.git" rev-parse refs/heads/main)" "$(head_of "$vault6")" "the Stop saved the vault to the remote"
h_assert_empty "$(git -C "$vault6" status --porcelain)" "the Stop left a clean tree"
if grep -q 'vault sync: pushed' "$base/state/launcher.log"; then h_ok "the log says the vault was saved"; else h_fail "the log does not say the vault was saved"; fi
put "$vault6" "30-projects/stop2.md" "second"
put "$vault6" "tools/build.sh" "not the vault"
remote_before=$(git -C "$tmp/sixth.git" rev-parse refs/heads/main)
h_hook_json Stop cwd="$vault6" session_id=sid-sync | h_launch stop-outside "$home" CLAUDE_PROJECT_DIR="$vault6" -- "$boot" stop-ship plugin
h_assert_eq "$(git -C "$tmp/sixth.git" rev-parse refs/heads/main)" "$remote_before" "a stray file: the Stop saved nothing"
if [ -f "$vault6/30-projects/stop2.md" ] && ! git -C "$vault6" log --format=%s -1 | grep -q 'stop2'; then h_ok "a stray file: the page is still unsaved, not half-saved"; else h_fail "a stray file: something was committed"; fi
rm -f "$vault6/tools/build.sh"
rmdir "$vault6/tools"
rm -f "$vault6/30-projects/stop2.md"

# The repository copy in the cloud saves too, on its shorter bound.
put "$vault6" "30-projects/cloud.md" "from a cloud session"
h_hook_json Stop cwd="$vault6" session_id=sid-cloud | h_launch stop-cloud "$home" CLAUDE_CODE_REMOTE=true CLAUDE_PROJECT_DIR="$vault6" -- "$(h_bootstrap repo)" stop-ship repo
h_assert_eq "$(git -C "$tmp/sixth.git" rev-parse refs/heads/main)" "$(head_of "$vault6")" "a cloud session's Stop saved the vault"

# The prompt after a two-surface edit names the page.
surface6=$tmp/surface6
git clone -q "$tmp/sixth.git" "$surface6" 2>/dev/null
git -C "$surface6" config user.name "$H_GIT_NAME"
git -C "$surface6" config user.email "$H_GIT_EMAIL"
git -C "$surface6" config commit.gpgsign false
put "$surface6" "40-areas/shared.md" "base line"
git -C "$surface6" add -A
h_git -C "$surface6" commit -q -m "base"
git -C "$surface6" push -q origin HEAD:main
git -C "$vault6" pull -q --no-rebase --no-edit origin main 2>/dev/null
put "$surface6" "40-areas/shared.md" "phone line"
git -C "$surface6" add -A
h_git -C "$surface6" commit -q -m "phone"
git -C "$surface6" push -q origin HEAD:main
put "$vault6" "40-areas/shared.md" "desktop line"
h_hook_json Stop cwd="$vault6" session_id=sid-sync | h_launch stop-conflict "$home" CLAUDE_PROJECT_DIR="$vault6" -- "$boot" stop-ship plugin
h_hook_json UserPromptSubmit cwd="$vault6" session_id=sid-sync prompt="What did I miss?" \
  | h_launch prompt-conflict "$home" -- "$boot" prompt plugin
ctx=$(printf '%s' "$(h_run_out prompt-conflict)" | python3 -c 'import json,sys
print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')
if has "$ctx" "40-areas/shared.md" && has "$ctx" "which one to keep"; then h_ok "the prompt after a two-surface edit names the page"; else h_fail "the prompt does not name the page: $ctx"; fi
printf '%s\n' "desktop line" >"$vault6/40-areas/shared.md"
h_hook_json UserPromptSubmit cwd="$vault6" session_id=sid-sync prompt="Settled." \
  | h_launch prompt-settled "$home" -- "$boot" prompt plugin
if has "$(h_run_out prompt-settled)" "40-areas/shared.md"; then h_fail "a settled page is still named"; else h_ok "a settled page is no longer named"; fi

h_done
