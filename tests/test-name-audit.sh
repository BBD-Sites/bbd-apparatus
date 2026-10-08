#!/usr/bin/env bash
# No person, login, employer, business or client name anywhere in the repository:
# not in a tracked file, not in a tracked path, not in commit metadata. A public
# repository cannot hold the list it checks against, so the list lives outside it:
#   1. $NAME_DENYLIST_FILE, if set;
#   2. else ~/.config/bbd-apparatus/denylist.txt (a maintainer's machine);
#   3. else $NAME_DENYLIST, the Actions secret the workflow exports, written here
#      to a private temp file.
# One entry per line; blank lines and lines starting with # are ignored.
#
# The list must never carry the bare three-letter prefix of this repository's own
# name: the word-boundary match treats "-" as a boundary, so that entry would flag
# the repository name itself in every file. The list carries the business's full
# name and its other repositories' full names instead, which do not match it.
#
# Output names a file, a hit count and the entry's LINE NUMBER in the list, never
# the entry or the
# matching text, because CI logs of a public repository are public and the list is
# the secret.
#
# Four checks need no list: every commit's author email is the neutral identity,
# and its committer is too, or is GitHub's own web-flow identity, which a rebase
# merge on GitHub writes as committer (merges here are rebase only, so the author
# stays neutral); no home-directory path; no email address but the neutral one;
# no GitHub owner but this repository's own.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

ALLOWED_EMAIL="apparatus-maintainers@users.noreply.github.com"
# GitHub's web-flow committer, assembled so the email scan below does not flag this
# file; it is accepted only as a committer, never as an author.
GITHUB_COMMITTER="noreply""@github.com"
ALLOWED_OWNER="BBD-Sites"
# The owner this repository had before it moved (design D41). Any mention of it now is
# a stale address, and the frozen bootstrap must never fetch from it, so it is refused
# anywhere: files, paths and commit metadata. Assembled, so this file does not match.
FORMER_OWNER="Personal""-Tooling"
# Written as a bracket expression so this file does not match its own pattern.
HOME_PATH_RE='/User[s]/[^/[:space:]]+/'
EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
OWNER_RE='(github\.com|githubusercontent\.com)[/:][A-Za-z0-9_.-]+'

# Prints the path of a readable list, or nothing if no source is configured.
find_list() {
  if [ -n "${NAME_DENYLIST_FILE:-}" ]; then
    printf '%s\n' "$NAME_DENYLIST_FILE"
  elif [ -f "$HOME/.config/bbd-apparatus/denylist.txt" ]; then
    printf '%s\n' "$HOME/.config/bbd-apparatus/denylist.txt"
  elif [ -n "${NAME_DENYLIST:-}" ]; then
    local f="$H_TMP/denylist.txt"
    (umask 077 && printf '%s\n' "$NAME_DENYLIST" >"$f")
    printf '%s\n' "$f"
  fi
}

# Prints "LINE<tab>ENTRY" per entry, trimmed, keeping the line number so a hit can
# be traced back in the list without the log ever naming the entry.
list_entries() {
  [ -r "$1" ] || return 0
  tr -d '\r' <"$1" | awk '{ sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "") }
    $0 != "" && substr($0, 1, 1) != "#" { print NR "\t" $0 }'
}

# audit_names REPO LIST: prints one line per hit; nothing means clean.
audit_names() {
  local repo=$1 list=$2 n name hits tab
  tab=$(printf '\t')
  while IFS="$tab" read -r n name; do
    [ -n "$name" ] || continue
    hits=$(git -C "$repo" grep -c -I -i -w -F -e "$name" -- . 2>/dev/null || true)
    if [ -n "$hits" ]; then
      printf '%s\n' "$hits" | sed "s/^/deny-list line #$n in file /"
    fi
    if git -C "$repo" ls-files | grep -q -i -w -F -e "$name"; then
      echo "deny-list line #$n in a tracked path"
    fi
    if git -C "$repo" log --format='%an%n%cn%n%B' HEAD 2>/dev/null \
        | grep -q -i -w -F -e "$name"; then
      echo "deny-list line #$n in commit metadata (author, committer or message)"
    fi
  done <<LIST
$(list_entries "$list")
LIST
}

# audit_static REPO: the checks that need no list. Prints one line per hit.
audit_static() {
  local repo=$1
  git -C "$repo" log --format='%H %ae %ce' HEAD 2>/dev/null \
    | awk -v ok="$ALLOWED_EMAIL" -v gh="$GITHUB_COMMITTER" \
        '$2 != ok || ($3 != ok && $3 != gh) { print "commit " substr($1, 1, 12) " carries an identity other than the neutral one" }' \
    | sort -u
  git -C "$repo" grep -c -I -E -e "$HOME_PATH_RE" -- . 2>/dev/null \
    | sed 's/^/home-directory path in file /' || true
  git -C "$repo" grep -h -o -I -E -e "$EMAIL_RE" -- . 2>/dev/null \
    | grep -v -x -F -e "$ALLOWED_EMAIL" | sort -u \
    | sed 's/.*/an email address other than the neutral one/' | sort -u || true
  git -C "$repo" grep -c -I -i -F -e "$FORMER_OWNER" -- . 2>/dev/null \
    | sed 's/^/the former owner named in file /' || true
  if git -C "$repo" log --format='%an%n%cn%n%B' HEAD 2>/dev/null | grep -q -i -F -e "$FORMER_OWNER"; then
    echo "the former owner named in commit metadata"
  fi
  git -C "$repo" ls-files 2>/dev/null | grep -i -F -e "$FORMER_OWNER" \
    | sed 's/^/the former owner named in the path /' || true
  git -C "$repo" grep -n -o -I -E -e "$OWNER_RE" -- . 2>/dev/null \
    | awk -F: -v ok="$ALLOWED_OWNER" '{ o = $NF; sub(/^.*[\/:]/, "", o); if ($0 !~ ("[/:]" ok "$")) print "GitHub owner other than " ok " in " $1 ":" $2 }' || true
}

# Self-check first: a gate that has never been seen to fire is not a gate. A
# synthetic list and a planted repository prove each check catches what it is for
# and that the repository's own name survives the word-boundary rule.
self_check() {
  local fake list out at="@"
  fake=$(h_fake_repo planted)
  list="$H_TMP/synthetic-list.txt"
  printf '%s\n' '# a comment line' '' 'Quentin Exampleperson' 'acme-ops' >"$list"

  out=$(audit_names "$fake" "$list"; audit_static "$fake")
  h_assert_empty "$out" "self-check: a clean repository passes"

  printf '%s\n' 'This is bbd-apparatus, and acme-opsy is a different word.' >"$fake/ok.txt"
  h_git -C "$fake" add ok.txt
  h_git -C "$fake" commit -q -m "docs: a near miss"
  out=$(audit_names "$fake" "$list")
  h_assert_empty "$out" "self-check: word boundaries spare the repository name and longer words"

  printf '%s\n' 'Thanks to QUENTIN exampleperson.' >"$fake/credit.txt"
  h_git -C "$fake" add credit.txt
  h_git -C "$fake" commit -q -m "docs: credit"
  out=$(audit_names "$fake" "$list")
  case "$out" in
    *"line #3 in file credit.txt"*) h_ok "self-check: a name in a file is caught, case-insensitively" ;;
    *) h_fail "self-check: a name in a file was missed" ;;
  esac
  case "$out" in
    *"Quentin"*|*"QUENTIN"*) h_fail "self-check: the output repeated a deny-list entry" ;;
    *) h_ok "self-check: the output never repeats an entry" ;;
  esac

  printf 'x\n' >"$fake/acme-ops.txt"
  h_git -C "$fake" add acme-ops.txt
  h_git -C "$fake" commit -q -m "chore: a path"
  out=$(audit_names "$fake" "$list")
  case "$out" in
    *"line #4 in a tracked path"*) h_ok "self-check: a name in a path is caught" ;;
    *) h_fail "self-check: a name in a path was missed" ;;
  esac

  git -C "$fake" commit -q --allow-empty -m "chore: hello from acme-ops"
  out=$(audit_names "$fake" "$list")
  case "$out" in
    *"line #4 in commit metadata"*) h_ok "self-check: a name in a commit message is caught" ;;
    *) h_fail "self-check: a name in a commit message was missed" ;;
  esac

  # A rebase merge on GitHub keeps the neutral author and writes GitHub's own
  # committer; that pair passes, and every other mix with a foreign email fails.
  identity_case() {
    local label=$1 author=$2 committer=$3 want=$4 r got
    r=$(h_fake_repo "identity-$label")
    GIT_AUTHOR_NAME=x GIT_AUTHOR_EMAIL="$author" GIT_COMMITTER_NAME=x GIT_COMMITTER_EMAIL="$committer" \
      git -C "$r" commit -q --allow-empty -m "chore: $label"
    got=pass
    case "$(audit_static "$r")" in *"identity other than the neutral one"*) got=fail ;; esac
    h_assert_eq "$got" "$want" "self-check: identity case $label is a $want"
  }
  identity_case rebase-merge "$ALLOWED_EMAIL" "$GITHUB_COMMITTER" pass
  identity_case github-author "$GITHUB_COMMITTER" "$GITHUB_COMMITTER" fail
  identity_case github-author-neutral-committer "$GITHUB_COMMITTER" "$ALLOWED_EMAIL" fail
  identity_case foreign-committer "$ALLOWED_EMAIL" "someone${at}example.org" fail
  identity_case foreign-author "someone${at}example.org" "$GITHUB_COMMITTER" fail

  git -C "$fake" -c user.email="someone${at}example.org" commit -q --allow-empty -m "chore: other identity"
  printf '%s\n' "/Use""rs/someone/notes" "write to someone${at}example.org" \
    "see https://github.com""/elsewhere/thing" "see https://github.com/${ALLOWED_OWNER}/bbd-apparatus" \
    "${ALLOWED_EMAIL}" >"$fake/leaks.txt"
  h_git -C "$fake" add leaks.txt
  h_git -C "$fake" commit -q -m "docs: leaks"
  out=$(audit_static "$fake")
  case "$out" in *"identity other than the neutral one"*) h_ok "self-check: a foreign commit email is caught" ;;
    *) h_fail "self-check: a foreign commit email was missed" ;; esac
  case "$out" in *"home-directory path in file leaks.txt"*) h_ok "self-check: a home-directory path is caught" ;;
    *) h_fail "self-check: a home-directory path was missed" ;; esac
  case "$out" in *"email address other than the neutral one"*) h_ok "self-check: a foreign email address is caught" ;;
    *) h_fail "self-check: a foreign email address was missed" ;; esac
  case "$out" in *"GitHub owner other than ${ALLOWED_OWNER} in leaks.txt:3"*) h_ok "self-check: a foreign GitHub owner is caught" ;;
    *) h_fail "self-check: a foreign GitHub owner was missed" ;; esac
  case "$out" in *"leaks.txt:4"*) h_fail "self-check: this repository's own owner was flagged" ;;
    *) h_ok "self-check: this repository's own owner passes" ;; esac
  case "$out" in *"former owner"*) h_fail "self-check: the former owner was reported where it does not appear" ;;
    *) h_ok "self-check: no former-owner report without the former owner" ;; esac

  # The old address of this repository is refused, even though its owner part is
  # spelled differently in case: a file carrying it fails the audit.
  old=$(h_fake_repo former-owner)
  printf 'BBD_URL="https://github.com/%s/bbd-apparatus.git"\n' "$(printf '%s' "$FORMER_OWNER" | tr '[:upper:]' '[:lower:]')" >"$old/bootstrap.sh"
  h_git -C "$old" add bootstrap.sh
  h_git -C "$old" commit -q -m "chore: an old address"
  out=$(audit_static "$old")
  case "$out" in *"the former owner named in file bootstrap.sh"*) h_ok "self-check: the former owner's URL is caught" ;;
    *) h_fail "self-check: the former owner's URL was missed" ;; esac
  git -C "$old" rm -q bootstrap.sh
  h_git -C "$old" commit -q -m "chore: moved from $FORMER_OWNER"
  out=$(audit_static "$old")
  case "$out" in *"former owner named in commit metadata"*) h_ok "self-check: the former owner in a commit message is caught" ;;
    *) h_fail "self-check: the former owner in a commit message was missed" ;; esac
  # A tracked path carrying the former owner's name is caught too, even when
  # every file's contents are clean.
  mkdir -p "$old/docs"
  printf 'clean\n' >"$old/docs/moved-from-$(printf '%s' "$FORMER_OWNER" | tr '[:upper:]' '[:lower:]').md"
  h_git -C "$old" add docs
  h_git -C "$old" commit -q -m "docs: a clean file"
  out=$(audit_static "$old")
  case "$out" in *"the former owner named in the path docs/moved-from-"*) h_ok "self-check: the former owner in a tracked path is caught" ;;
    *) h_fail "self-check: the former owner in a tracked path was missed" ;; esac
}

self_check

repo=$(h_repo_root)

out=$(audit_static "$repo")
h_assert_empty "$out" "repository: commit identities, paths, email addresses and GitHub owners"

list=$(find_list)
count=0
if [ -n "$list" ]; then
  count=$(list_entries "$list" | grep -c . || true)
fi
if [ "$count" -eq 0 ]; then
  if [ -n "${CI:-}" ]; then
    # Fails closed: in CI an empty list would turn the audit into a silent pass.
    h_fail "no deny-list entries in CI; set the NAME_DENYLIST secret"
  else
    echo "skip: no deny-list on this machine, names not checked"
  fi
else
  out=$(audit_names "$repo" "$list")
  h_assert_empty "$out" "repository: no deny-list entry ($count checked) in files, paths or commit metadata"
fi

h_done
