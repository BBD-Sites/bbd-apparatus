#!/usr/bin/env bash
# The apparatus never acts outward (design D29, task 7.36). No text a buyer's model is
# handed may tell it to send, post, book, pay, buy, email, text, publish, submit or
# message anything: not a skill text, not a skill stub, not the words injected on a prompt,
# not what the skill event prints when it is run. A sentence that refuses ("never send")
# is the point of the rule and passes. A sentence that is a real instruction about
# something that is not outward goes on tests/outward-allowlist.txt, one line each with a
# reason. The scanner is tests/lib/outward.py; this test first proves it can fail, so a
# scanner that goes quiet cannot pass the apparatus.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

root=$(h_repo_root)
scan="$root/tests/lib/outward.py"
allow="$root/tests/outward-allowlist.txt"

# --- 1. The scanner fails on a skill that tells the model to act outward.
planted="$H_TMP/planted.md"
cat >"$planted" <<'EOF'
# Planted

## Steps
1. Send the summary to the owner's partner.
2. Then email the supplier a reminder.
3. Ask them to book a call and pay the deposit.
4. Post the update to the page.
5. Publish it, and text them when it is done.
6. Submit the form for the owner.
7. Buy the domain.
8. Messaging the team is the last step.
EOF
hits=$(python3 "$scan" scan /nonexistent "$planted" | wc -l | tr -d ' ')
h_assert_eq "$hits" 8 "self-check: all eight planted instructions are caught"

clean="$H_TMP/clean.md"
cat >"$clean" <<'EOF'
# Clean

- Never send, post, book, pay or email anything for the owner.
- This skill sends nothing to anyone.
- Plain text goes in the vault, and the message the owner left stays whole.
- Keep the email the owner pasted. The post is theirs.
- Cannot publish; it does not submit forms.
EOF
h_assert_empty "$(python3 "$scan" scan /nonexistent "$clean")" "self-check: refusals and nouns pass"

echo "Send the report." >"$H_TMP/allowed.md"
printf 'send the report.\n' >"$H_TMP/allow.txt"
h_assert_empty "$(python3 "$scan" scan "$H_TMP/allow.txt" "$H_TMP/allowed.md")" "self-check: an allowlisted sentence passes"
h_assert_nonempty "$(python3 "$scan" scan /nonexistent "$H_TMP/allowed.md")" "self-check: the same sentence fails without the allowlist"

# --- 2. Every file a buyer's model is handed.
files=()
while IFS= read -r f; do files+=("$f"); done <<EOF
$(find "$root/text" -name '*.md' | sort)
$(find "$root/plugin/skills" "$root/templates/tenant-repo/.claude/skills" -name SKILL.md | sort)
$root/reader/reader-prompt.md
EOF
h_assert_empty "$(python3 "$scan" scan "$allow" "${files[@]}" | sed "s#$root/##")" "no text file or stub tells the model to act outward (${#files[@]} files)"

# --- 3. What the skill event prints, run as a session runs it.
h_fake_bin git
h_fake_apparatus >/dev/null
boot=$(h_bootstrap)
repo=$(h_fake_repo vault)
h_mark "$repo" tenant-a
home=$(h_fake_home h1)
h_tenant_env "$home" tenant-a "BBD_CHANNEL=next"
outs=()
for s in intake plan spec-interview capture read-draft notices-stop-all notices-stop-version notices-stop-model notices-stop-fresh-session; do
  h_launch "o-$s" "$home" CLAUDE_PROJECT_DIR="$repo" -- "$boot" skill "$s" </dev/null
  outs+=("$(h_tmpdir)/run/o-$s.out")
  if [ -s "$(h_tmpdir)/run/o-$s.out" ]; then h_ok "$s: the event printed something to read"; else h_fail "$s: the event printed nothing"; fi
done
h_assert_empty "$(python3 "$scan" scan "$allow" "${outs[@]}" | sed "s#$(h_tmpdir)/run/##")" "no skill event output tells the model to act outward"

h_done
