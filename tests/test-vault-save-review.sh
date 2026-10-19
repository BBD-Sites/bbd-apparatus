#!/usr/bin/env bash
# Saving the vault when its branch takes changes only through a pull request
# (lib/vaultsync.py, REVIEW; docs/launcher-contract.md section 14). A local bare remote
# whose pre-receive hook refuses every push to main with GitHub's own words stands in
# for a protected branch, and a fake GitHub CLI stands in for the pull request.
#
# A branch that accepts pushes is saved as before: no save branch, no CLI. A refused
# push lands the same commits on one long-lived save branch, by plain fast-forward
# pushes only, with one pull request reused and squash auto-merge turned on. When the
# pull request has merged, the next prompt (or save) moves the local branch back to the
# remote's, keeping the old head under a backup ref, so the branch keeps pulling. A
# push refused everywhere, or a missing CLI, never loses a change. A copy already
# stranded many commits ahead and one behind is recovered with `recover`: every file
# lands, the branch returns to the remote's, and a dated backup ref keeps the old head.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

sync_py="$(h_repo_root)/lib/vaultsync.py"
export PYTHONDONTWRITEBYTECODE=1
h_fake_bin git
tmp=$(h_tmpdir)

# The fake GitHub CLI: it records every call, keeps one pull request in $tmp/gh/pr
# ("<url> manual" or "<url> auto"), fails the subcommand H_GH_FAIL names, and runs
# $H_GH_ON_MERGE (the pull request merging at once) when auto-merge is turned on.
mkdir -p "$tmp/gh" "$tmp/calls"
cat >"$tmp/bin/gh" <<SH
#!/usr/bin/env bash
state=$tmp/gh
printf '%s\n' "\$*" >>$tmp/calls/gh.log
[ -n "\${H_GH_FAIL:-}" ] && [ "\$2" = "\$H_GH_FAIL" ] && { echo "gh: failed" >&2; exit 1; }
case "\$1 \$2" in
  "pr list") [ -f "\$state/pr" ] && cat "\$state/pr"; exit 0 ;;
  "pr create") echo "https://github.invalid/pull/1 manual" >"\$state/pr"; echo "https://github.invalid/pull/1"; exit 0 ;;
  "pr merge") echo "https://github.invalid/pull/1 auto" >"\$state/pr"
    if [ -n "\${H_GH_ON_MERGE:-}" ]; then bash "\$H_GH_ON_MERGE" >/dev/null 2>&1; rm -f "\$state/pr"; fi
    exit 0 ;;
esac
exit 1
SH
chmod +x "$tmp/bin/gh"
export BBD_GH="$tmp/bin/gh"

put() { mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" >"$1/$2"; }
head_of() { git -C "$1" rev-parse HEAD; }
on() { git -C "$1" rev-parse -q --verify "refs/heads/$2" 2>/dev/null; }
sync_in() { python3 "$sync_py" sync "$1" --deadline 20 --settle "$tmp/settle.txt"; }
pull_in() { python3 "$sync_py" pull "$1" --deadline 20 --settle "$tmp/settle.txt"; }
gh_calls() { cat "$tmp/calls/gh.log" 2>/dev/null; }
gh_reset() { : >"$tmp/calls/gh.log"; }
forced() { h_calls git | grep ' push ' | grep -E -- '--force|--force-with-lease| -f |HEAD:\+|\+refs' || true; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
holds() { git -C "$1" cat-file -e "$2:$3" 2>/dev/null; }

# protect BARE: refuse every push to main as GitHub does, and every push to a
# vault-save branch too while BARE/deny-save exists.
protect() {
  cat >"$1/hooks/pre-receive" <<'SH'
#!/bin/sh
while read -r old new ref; do
  case "$ref" in
    refs/heads/main)
      echo "error: GH006: Protected branch update failed for refs/heads/main." >&2
      echo "error: Changes must be made through a pull request." >&2
      exit 1 ;;
    refs/heads/vault-save/*)
      if [ -f "$GIT_DIR/deny-save" ] || [ -f deny-save ]; then echo "error: denied" >&2; exit 1; fi ;;
  esac
done
exit 0
SH
  chmod +x "$1/hooks/pre-receive"
}

# land BARE [delete]: the pull request merges as GitHub's squash does: one new commit
# on main with the save branch's tree merged in, the save branch kept or deleted.
land() {
  local bare=$1 w="$tmp/land.$RANDOM"
  git clone -q "$bare" "$w" 2>/dev/null
  git -C "$w" merge -q --squash "origin/vault-save/main" >/dev/null 2>&1
  h_git -C "$w" commit -q -m "Save your notes (#1)"
  mv "$bare/hooks/pre-receive" "$bare/hooks/pre-receive.off"
  git -C "$w" push -q origin HEAD:main
  [ "${2:-}" = delete ] && git -C "$w" push -q origin :refs/heads/vault-save/main
  mv "$bare/hooks/pre-receive.off" "$bare/hooks/pre-receive"
  rm -rf "$w"
}

# 1. A branch that accepts pushes: saved exactly as before, no save branch, no CLI.
open=$(h_fake_repo open)
h_mark "$open" tenant-a
put "$open" "00-inbox/a.md" "a note"
gh_reset
h_assert_eq "$(sync_in "$open")" pushed "a branch that accepts pushes: pushed as before"
h_assert_eq "$(on "$tmp/open.git" main)" "$(head_of "$open")" "the remote main has the note"
h_assert_empty "$(on "$tmp/open.git" vault-save/main)" "no save branch is made"
h_assert_empty "$(gh_calls)" "the GitHub CLI is never run"

# 2. A protected main: the save lands on the save branch, a pull request is opened and
# set to squash auto-merge, and main on the remote is untouched.
vault=$(h_fake_repo vault)
h_mark "$vault" tenant-a
bare="$tmp/vault.git"
protect "$bare"
main0=$(on "$bare" main)
put "$vault" "00-inbox/one.md" "first note"
gh_reset
h_calls_reset git
h_assert_eq "$(sync_in "$vault")" proposed "a protected main: saved through a pull request"
h_assert_eq "$(on "$bare" main)" "$main0" "the remote main is untouched"
h_assert_eq "$(on "$bare" vault-save/main)" "$(head_of "$vault")" "the save branch holds the local head"
if holds "$bare" vault-save/main 00-inbox/one.md; then h_ok "the save branch holds the note"; else h_fail "the save branch lacks the note"; fi
calls=$(gh_calls)
if has "$calls" "pr create --head vault-save/main --base main"; then h_ok "a pull request is opened from the save branch into main"; else h_fail "no pull request was opened: [$calls]"; fi
if has "$calls" "pr merge https://github.invalid/pull/1 --auto --squash"; then h_ok "squash auto-merge is turned on"; else h_fail "auto-merge was not turned on: [$calls]"; fi
h_assert_empty "$(forced)" "no push was forced"
h_assert_empty "$(git -C "$vault" status --porcelain)" "the tree is clean"

# 3. A second save while the pull request is open: the save branch moves forward, and the
# same pull request is reused.
save1=$(on "$bare" vault-save/main)
put "$vault" "20-ideas/two.md" "second note"
gh_reset
h_assert_eq "$(sync_in "$vault")" proposed "a second save: proposed again"
save2=$(on "$bare" vault-save/main)
if git -C "$bare" merge-base --is-ancestor "$save1" "$save2"; then h_ok "the save branch moved by fast-forward"; else h_fail "the save branch was rewritten"; fi
calls=$(gh_calls)
if has "$calls" "pr create"; then h_fail "a second pull request was opened"; else h_ok "the open pull request is reused"; fi
if has "$calls" "pr merge"; then h_fail "auto-merge was asked for again though it is on"; else h_ok "auto-merge already on: not asked again"; fi

# 4. The pull request merges (squash; the branch is kept). The next prompt moves main back
# to the remote's: every page is there, and the old head is kept under a backup ref.
old_head=$(head_of "$vault")
land "$bare"
rm -f "$tmp/gh/pr"
h_assert_eq "$(pull_in "$vault")" pulled "after the merge, the prompt's pull moves main back"
h_assert_eq "$(head_of "$vault")" "$(on "$bare" main)" "local main is the remote main again"
h_assert_eq "$(git -C "$vault" rev-parse -q --verify refs/vault-save/backup/main)" "$old_head" "the old head is kept under a backup ref"
for f in 00-inbox/one.md 20-ideas/two.md; do
  if [ -f "$vault/$f" ]; then h_ok "$f is still on disk"; else h_fail "$f was lost"; fi
done
h_assert_empty "$(git -C "$vault" status --porcelain)" "the tree is clean after moving back"
h_assert_eq "$(pull_in "$vault")" nothing "and the next pull has nothing to do"

# 5. The next save after a squash merge: the stale save branch is merged in, the push is a
# fast-forward, and the pull request shows only the new page.
put "$vault" "30-projects/three.md" "third note"
h_calls_reset git
h_assert_eq "$(sync_in "$vault")" proposed "the next save goes to the same save branch"
save3=$(on "$bare" vault-save/main)
if git -C "$bare" merge-base --is-ancestor "$save2" "$save3"; then h_ok "still a fast-forward after the squash merge"; else h_fail "the save branch was rewritten after the squash"; fi
h_assert_eq "$(git -C "$bare" diff --name-only "main...vault-save/main")" "30-projects/three.md" "the pull request holds only the new page"
h_assert_empty "$(forced)" "no push was forced"

# 6. Merged and the branch deleted; the next save has nothing new: main is moved back.
land "$bare" delete
rm -f "$tmp/gh/pr"
h_assert_eq "$(sync_in "$vault")" realigned "the save after the merge moves main back"
h_assert_eq "$(head_of "$vault")" "$(on "$bare" main)" "local main is the remote main"
if [ -f "$vault/30-projects/three.md" ]; then h_ok "the page is still on disk"; else h_fail "the page was lost"; fi
# And a new save starts the save branch again from the current main.
put "$vault" "00-inbox/four.md" "fourth note"
h_assert_eq "$(sync_in "$vault")" proposed "a deleted save branch is started again"
h_assert_eq "$(git -C "$bare" diff --name-only "main...vault-save/main")" "00-inbox/four.md" "it carries only the new page"
land "$bare" delete
rm -f "$tmp/gh/pr"
pull_in "$vault" >/dev/null

# 7. A refused push never loses a change: with no CLI the branch still carries the note;
# with the CLI failing the reason is named; with the save branch refused too, the note
# stays committed locally and on disk.
put "$vault" "00-inbox/five.md" "fifth note"
h_assert_eq "$(BBD_GH=/nonexistent/gh sync_in "$vault")" "proposed:no-gh" "no GitHub CLI: the save branch is pushed and the status says why"
if holds "$bare" vault-save/main 00-inbox/five.md; then h_ok "the note reached the remote anyway"; else h_fail "the note did not leave the machine"; fi
put "$vault" "00-inbox/six.md" "sixth note"
h_assert_eq "$(H_GH_FAIL=create sync_in "$vault")" "proposed:no-pr" "the CLI cannot open a pull request: named"
h_assert_eq "$(H_GH_FAIL=merge sync_in "$vault")" "proposed:no-auto-merge" "auto-merge cannot be turned on: named"
touch "$bare/deny-save"
save_before=$(on "$bare" vault-save/main)
main_before=$(on "$bare" main)
put "$vault" "00-inbox/seven.md" "seventh note"
h_assert_eq "$(sync_in "$vault")" failed "every push refused: the save fails open"
h_assert_eq "$(on "$bare" vault-save/main)" "$save_before" "the save branch is untouched"
h_assert_eq "$(on "$bare" main)" "$main_before" "the remote main is untouched"
if holds "$vault" HEAD 00-inbox/seven.md && [ -f "$vault/00-inbox/seven.md" ]; then h_ok "the note is committed locally and on disk"; else h_fail "a refused push lost the note"; fi
rm -f "$bare/deny-save"
h_assert_eq "$(sync_in "$vault")" proposed "once the save branch accepts again, the note goes out"
if holds "$bare" vault-save/main 00-inbox/seven.md; then h_ok "the held note reached the save branch"; else h_fail "the held note never left"; fi
land "$bare" delete
rm -f "$tmp/gh/pr"
pull_in "$vault" >/dev/null

# 8. A copy already stranded: many saves committed on main that the remote refused, and
# one commit behind from another surface. `recover` lands every file through the pull
# request, waits for it to merge, returns main to the remote's and keeps a dated backup.
stuck=$(h_fake_repo stuck)
h_mark "$stuck" tenant-a
sbare="$tmp/stuck.git"
other="$tmp/stuck-other"
git clone -q "$sbare" "$other" 2>/dev/null
put "$other" "40-areas/from-phone.md" "the other surface"
git -C "$other" add -A
h_git -C "$other" commit -q -m "phone"
git -C "$other" push -q origin HEAD:main
protect "$sbare"
i=1
while [ "$i" -le 12 ]; do
  put "$stuck" "00-inbox/capture-$i.md" "capture $i"
  git -C "$stuck" add -A
  h_git -C "$stuck" commit -q -m "Save your notes: 1 change in 00-inbox"
  i=$((i + 1))
done
stranded=$(head_of "$stuck")
git -C "$stuck" fetch -q origin
counts=$(git -C "$stuck" rev-list --left-right --count main...origin/main | tr '\t' ' ')
h_assert_eq "$counts" "12 1" "the stand-in is stranded: 12 ahead, 1 behind"
cat >"$tmp/land-stuck.sh" <<SH
. "$(h_repo_root)/tests/lib/harness.sh"
H_TMP=$tmp
tmp=$tmp
$(declare -f land)
land "$sbare" delete
SH
rm -f "$tmp/gh/pr"
status=$(H_GH_ON_MERGE="$tmp/land-stuck.sh" python3 "$sync_py" recover "$stuck" --deadline 30 --settle "$tmp/settle-stuck.txt")
case "$status" in proposed+recovered:refs/vault-save/backup/main-*) h_ok "recover lands and returns main ($status)" ;; *) h_fail "recover did not finish: [$status]" ;; esac
backup=${status#*recovered:}
h_assert_eq "$(head_of "$stuck")" "$(on "$sbare" main)" "local main is the remote main"
if git -C "$stuck" merge-base --is-ancestor "$stranded" "$backup"; then h_ok "the backup ref keeps every stranded commit"; else h_fail "the backup ref lost stranded commits"; fi
missing=""
i=1
while [ "$i" -le 12 ]; do
  f="00-inbox/capture-$i.md"
  { [ -f "$stuck/$f" ] && holds "$sbare" main "$f"; } || missing="$missing $f"
  i=$((i + 1))
done
h_assert_empty "$missing" "every stranded capture is on disk and on the remote main"
if [ -f "$stuck/40-areas/from-phone.md" ]; then h_ok "the other surface's page arrived too"; else h_fail "the other surface's page is missing"; fi
h_assert_empty "$(git -C "$stuck" status --porcelain)" "the tree is clean"
h_assert_eq "$(git -C "$stuck" rev-list --left-right --count main...origin/main | tr '\t' ' ')" "0 0" "neither ahead nor behind"
h_assert_eq "$(pull_in "$stuck")" nothing "and it pulls cleanly again"

# A pull request that does not merge in time: recover says so and leaves main where it is.
put "$stuck" "00-inbox/late.md" "late"
git -C "$stuck" add -A
h_git -C "$stuck" commit -q -m "Save your notes: 1 change in 00-inbox"
late=$(head_of "$stuck")
rm -f "$tmp/gh/pr"
h_assert_eq "$(python3 "$sync_py" recover "$stuck" --deadline 6 --settle "$tmp/settle-stuck.txt")" "proposed+waiting" "not merged in time: waiting, said plainly"
h_assert_eq "$(head_of "$stuck")" "$late" "main is left where it was"
if [ -f "$stuck/00-inbox/late.md" ]; then h_ok "the page is still on disk"; else h_fail "waiting lost the page"; fi

h_done
