#!/usr/bin/env bash
# The shipped plugin/allowed_signers is what the bootstrap verifies every channel head
# against (docs/launcher-contract.md section 3, step 5; docs/channels.md). The private
# key is never on a test machine, so what the file does is proved with the command the
# bootstrap runs and a throwaway pair, as tests/test-fail-safe.sh proves the bootstrap:
#   - a file in the shipped line's shape (the same principal and options, a throwaway
#     key) verifies a head that key signed, and refuses a head another key signed, an
#     unsigned head, and every head when the file is empty;
#   - the shipped file itself refuses a head the throwaway key signed, so it names one
#     key and not just any key;
#   - when this working copy's HEAD carries a signature, the shipped file verifies it.
#     An unsigned HEAD is a local commit the lander re-signs, and is noted here; the
#     test workflow refuses it on the way into a channel.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

root=$(h_repo_root)
SIGNERS="$root/plugin/allowed_signers"

if [ ! -f "$SIGNERS" ]; then
  h_fail "plugin/allowed_signers is missing"
  h_done
fi
if ! command -v ssh-keygen >/dev/null 2>&1; then
  echo "skip: no ssh-keygen, signatures not checked"
  h_done
fi

# verify FILE REPO REV: the bootstrap's own check.
verify() { git -C "$2" -c gpg.ssh.allowedSignersFile="$1" verify-commit "$3" >/dev/null 2>&1; }

shipped_line=$(grep -v -e '^#' -e '^[[:space:]]*$' "$SIGNERS" | head -1)
principal=${shipped_line%% *}
h_assert_eq "$principal" "$H_GIT_EMAIL" "the shipped principal is the neutral identity"

ssh-keygen -q -t ed25519 -N '' -C test -f "$H_TMP/signer" >/dev/null
ssh-keygen -q -t ed25519 -N '' -C test -f "$H_TMP/stranger" >/dev/null
throwaway="$H_TMP/allowed_signers"
printf '%s namespaces="git" %s\n' "$principal" "$(cut -d' ' -f1,2 "$H_TMP/signer.pub")" >"$throwaway"

repo=$(h_fake_repo channel)
# sign_commit KEY MESSAGE: an empty commit on the fake channel, signed by KEY.
sign_commit() {
  git -C "$repo" -c user.name="$H_GIT_NAME" -c user.email="$H_GIT_EMAIL" -c gpg.format=ssh \
    -c user.signingkey="$H_TMP/$1" commit -q --allow-empty -S -m "$2"
}

sign_commit signer "test: signed by the allowed key"
good=$(git -C "$repo" rev-parse HEAD)
if verify "$throwaway" "$repo" "$good"; then h_ok "a head the allowed key signed verifies"
else h_fail "a head the allowed key signed did not verify"; fi
case "$(git -C "$repo" -c gpg.ssh.allowedSignersFile="$throwaway" verify-commit "$good" 2>&1)" in
  *"Good \"git\" signature for $principal"*) h_ok "verification names the principal" ;;
  *) h_fail "verification did not name the principal" ;;
esac
if verify "$SIGNERS" "$repo" "$good"; then h_fail "the shipped file accepted a head a throwaway key signed"
else h_ok "the shipped file refuses a head a key it does not name signed"; fi

sign_commit stranger "test: signed by another key"
if verify "$throwaway" "$repo" HEAD; then h_fail "a head another key signed verified"
else h_ok "a head another key signed is refused"; fi

h_git -C "$repo" commit -q --allow-empty -m "test: unsigned"
if verify "$throwaway" "$repo" HEAD; then h_fail "an unsigned head verified"
else h_ok "an unsigned head is refused"; fi

: >"$H_TMP/empty"
if verify "$H_TMP/empty" "$repo" "$good"; then h_fail "an empty signers file accepted a signed head"
else h_ok "an empty signers file refuses even a correctly signed head"; fi

# This working copy's own head.
if git -C "$root" cat-file commit HEAD 2>/dev/null | grep -q '^gpgsig '; then
  if verify "$SIGNERS" "$root" HEAD; then h_ok "this working copy's HEAD is signed by a key the shipped file names"
  else h_fail "this working copy's HEAD carries a signature the shipped file does not verify"; fi
else
  echo "skip: this working copy's HEAD is unsigned (a local commit; the lander re-signs, and the test workflow refuses an unsigned channel head)"
fi

h_done
