#!/usr/bin/env bash
# A tenant token never enters git: it lives only in a home's untracked config, so it
# can never reach this public history. This is the tracked-file half of that rule:
# no tenant-token shape and no common credential shape in any tracked file.
# Fixtures under tests/fixtures/ are allowlisted by path, because the redactor's
# tests plant fake secrets there on purpose, and so is lib/redact.py alone, because
# its self-test must carry the fake values it proves it masks.
#
# Hits are reported as file and count only, never the matching text, so a real
# leak is not repeated into a public CI log.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

TOKEN_RE='bbdt_[A-Za-z0-9]{40}'
# The same shapes the session ingest's post-scan uses, so a credential that would be
# quarantined there is refused here too.
SECRET_RE='sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|pat-[a-z0-9]{2,6}-[0-9a-fA-F]{6,}|-----BEGIN [A-Z0-9 ]*PRIVATE KEY'
FIXTURES=':(exclude)tests/fixtures/'
SELFTEST=':(exclude,top)lib/redact.py'

# scan REPO: one line per file with a hit; nothing means clean.
scan() {
  local repo=$1
  LC_ALL=C git -C "$repo" grep -c -I -E -e "$TOKEN_RE" -- . "$FIXTURES" "$SELFTEST" 2>/dev/null \
    | sed 's/^/tenant-token shape in /' || true
  LC_ALL=C git -C "$repo" grep -c -I -E -e "$SECRET_RE" -- . "$FIXTURES" "$SELFTEST" 2>/dev/null \
    | sed 's/^/credential shape in /' || true
}

# The post-scan itself over the same tracked files, report-only so nothing tracked
# is ever moved: it is the check a capture must pass, so the repository passes it too.
postscan_tracked() {
  local repo=$1 files=() f
  while IFS= read -r -d '' f; do
    [ -f "$repo/$f" ] && files+=("$repo/$f")
  done < <(git -C "$repo" ls-files -z -- . "$FIXTURES" "$SELFTEST")
  [ "${#files[@]}" -gt 0 ] || return 0
  PYTHONDONTWRITEBYTECODE=1 python3 "$repo/bin/apparatus" postscan --report-only "${files[@]}" 2>&1 \
    | sed "s#^$repo/#credential shape (post-scan) in #" || true
}

# Planted values are assembled at run time, so no secret shape is ever committed
# outside the fixtures directory, including in this file.
body40=$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)
planted_token="bbdt""_$body40"
planted_secrets=$(printf '%s\n' \
  "gh""p_${body40}" \
  "AK""IA0000000000000000" \
  "sk""-ant-${body40}" \
  "-----BEGIN RSA PRIV""ATE KEY-----")

fake=$(h_fake_repo planted)
out=$(scan "$fake")
h_assert_empty "$out" "self-check: a clean repository passes"

printf 'token=%s\n' "$planted_token" >"$fake/config.txt"
mkdir -p "$fake/tests/fixtures"
printf '%s\n' "$planted_token" "$planted_secrets" >"$fake/tests/fixtures/planted.txt"
h_git -C "$fake" add -A
h_git -C "$fake" commit -q -m "test: planted"
out=$(scan "$fake")
case "$out" in *"tenant-token shape in config.txt:1"*) h_ok "self-check: a tracked tenant token is caught" ;;
  *) h_fail "self-check: a tracked tenant token was missed" ;; esac
case "$out" in *fixtures*) h_fail "self-check: the fixtures allowlist did not hold" ;;
  *) h_ok "self-check: fixtures are allowlisted by path" ;; esac
case "$out" in *"$planted_token"*|*"$body40"*) h_fail "self-check: the scan printed a secret value" ;;
  *) h_ok "self-check: the scan never prints the value" ;; esac

i=0
while IFS= read -r s; do
  i=$((i + 1))
  printf '%s\n' "$s" >"$fake/leak$i.txt"
done <<SECRETS
$planted_secrets
SECRETS
h_git -C "$fake" add -A
h_git -C "$fake" commit -q -m "test: more planted"
out=$(scan "$fake")
n=$(printf '%s\n' "$out" | grep -c '^credential shape in leak' || true)
h_assert_eq "$n" "$i" "self-check: every credential shape is caught"

out=$(scan "$(h_repo_root)")
h_assert_empty "$out" "repository: no tenant token or credential shape in any tracked file"

out=$(postscan_tracked "$(h_repo_root)")
h_assert_empty "$out" "repository: the post-scan finds nothing in any tracked file"

h_done
