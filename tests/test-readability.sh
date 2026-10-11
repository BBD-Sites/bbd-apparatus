#!/usr/bin/env bash
# The reading-level gate (design D24, docs/launcher-contract.md section 13). The grader
# (lib/readability.py) is pure python with no network: plain text is under the
# fifth-grade ceiling and says nothing; hard text is over it and the hardest sentences
# come back worst first; code, links' addresses, identifiers and the lines under the
# closing `---` are not graded; a short sentence is never quoted. At Stop, a reply over
# the ceiling is held once with those sentences quoted, before the reader is run; the
# corrected reply (the second pass) goes through, and a plain reply goes on to the
# reader. Run through the bootstrap as a session fires it, with a fake `claude`.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

py="$(h_repo_root)/lib/readability.py"
tmp=$(h_tmpdir)
export PYTHONDONTWRITEBYTECODE=1

# The grader uses nothing outside the standard library and opens no socket.
if grep -n -E '^(import|from) +(urllib|http|socket|requests|ssl|ftplib|smtplib)' "$py" >/dev/null; then
  h_fail "the grader imports a network module"
else h_ok "the grader imports no network module"; fi

cat >"$tmp/plain.md" <<'EOF'
The form sends again. It broke when the site moved hosts. The page still posted to the old
address, so every message was lost. I fixed the address and sent a test message. It landed.
I cannot tell how many messages were lost, because the old host kept no record. Nothing is
yours to do.

Done.
EOF
cat >"$tmp/hard.md" <<'EOF'
The authentication middleware was misconfigured because the environment variable controlling the redirect behaviour had been overwritten during the deployment, which meant that every unauthenticated request was silently forwarded to an obsolete endpoint. I reconfigured the infrastructure and verified the configuration across all production environments. The contact form now submits correctly. The old endpoint is gone. Everything else on the site is unchanged and nothing further is required from you at this point.

Done.
EOF

h_assert_empty "$(python3 "$py" check "$tmp/plain.md")" "plain text: the check says nothing"
out=$(python3 "$py" check "$tmp/hard.md")
h_assert_eq "$(printf '%s\n' "$out" | head -n 1 | cut -f2)" 5 "hard text: the first line carries the ceiling"
case "$(printf '%s\n' "$out" | sed -n 2p)" in
  *"The authentication middleware was misconfigured"*) h_ok "hard text: the worst sentence is quoted first" ;;
  *) h_fail "hard text: the worst sentence is not first: $out" ;;
esac
case "$out" in *"The contact form now submits correctly."*) h_fail "a short sentence was quoted" ;; *) h_ok "a short plain sentence is never quoted" ;; esac
over=$(python3 "$py" grade "$tmp/hard.md")
under=$(python3 "$py" grade "$tmp/plain.md")
h_assert_eq "$(python3 -c "print('yes' if $over > 5 > $under else 'no')")" yes "the grade separates them (hard $over, plain $under)"
h_assert_eq "$(python3 "$py" check "$tmp/hard.md" --ceiling 30)" "" "a higher ceiling lets the same text through"
h_assert_eq "$(python3 "$py" check "$tmp/hard.md" --limit 1 | wc -l | tr -d ' ')" 2 "the limit caps the quoted sentences"
# Deterministic: the same text, the same answer.
h_assert_eq "$(python3 "$py" check "$tmp/hard.md")" "$out" "the same text gives the same answer"

# Not graded: fenced code, inline code, a link's address, identifiers, and the lines under
# the closing `---`.
cat >"$tmp/code.md" <<'EOF'
The page is live. I checked it on a phone. It loads in two seconds.

```
const authenticationMiddlewareConfigurationInitializer = initializeEnvironmentConfiguration(productionEnvironments);
```

Nothing is yours to do. See [the page](https://example.test/a/very/long/path/to/the/page).

Done.

---
- ids: src/middleware/authentication_redirect_configuration.ts and the commit 4f2a9b1, the deployment identifier 20261011-authentication-configuration-redirect
EOF
h_assert_empty "$(python3 "$py" check "$tmp/code.md")" "code, addresses and the trailer are not graded"

# A score is a flag, never a target: the hard text, chopped into fragments, grades low,
# and the grader does not pretend that is fine or not; it measures, and the reader
# (which sees the fragments) is what judges them. Pinned so nobody makes the grader
# reward chopping by adding a rule here.
h_assert_eq "$(python3 "$py" check /nonexistent/file 2>&1 | grep -c Traceback)" 0 "a missing file is not a crash"

# ---- At Stop.
h_fake_bin git
h_fake_bin claude
h_fake_apparatus >/dev/null
boot=$(h_bootstrap)
home=$(h_fake_home h1)
repo=$(h_fake_repo vault)
h_mark "$repo" tenant-a
h_tenant_env "$home" tenant-a "BBD_CHANNEL=stable"
cat >"$tmp/send.txt" <<'EOF'
VERDICT: send
RESTATE
- none
CHAIN
- none
THE PERSON'S WORDS
- none
CLAIMS
- none
ANSWERED
- none
OWNER VOICE
- none
VALUE
- 5 sentences or bullets in the body
READING
- none
CONTRACT
- none
EOF
stop() { # NAME SESSION PROMPT-ID DRAFT-FILE [hook key=value ...]
  local name=$1 sid=$2 pid=$3 file=$4
  shift 4
  h_hook_json Stop cwd="$repo" session_id="$sid" prompt_id="$pid" stop_reason=end_turn \
      last_assistant_message="$(cat "$file")" "$@" \
    | h_launch "$name" "$home" H_FAKE_CLAUDE_STDOUT_FILE="${READER_OUT:-$tmp/send.txt}" -- "$boot" stop-gate plugin
}
decision() { printf '%s' "$(h_run_out "$1")" | h_json_field decision 2>/dev/null; }
reason() { printf '%s' "$(h_run_out "$1")" | h_json_field reason 2>/dev/null; }
reads() { h_calls claude | grep -c -e '-p --model' || true; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# 1. A hard reply is read first (one call), then held once with the hard sentences quoted;
# the reader found nothing here, so the block carries only the grade.
h_calls_reset claude
stop hard s1 p1 "$tmp/hard.md"
h_assert_hook_run hard "a hard reply"
h_assert_eq "$(decision hard)" block "a hard reply is held"
r=$(reason hard)
if has "$r" '"The authentication middleware was misconfigured'; then h_ok "the hard sentence is quoted in the reason"; else h_fail "the reason does not quote the sentence: $r"; fi
if has "$r" "ceiling is 5"; then h_ok "the reason names the ceiling"; else h_fail "the reason does not name the ceiling"; fi
if has "$r" "Do not chop"; then h_ok "the reason says not to chop sentences into fragments"; else h_fail "the reason does not warn against chopping"; fi
if has "$r" "The contact form now submits"; then h_fail "a plain sentence is quoted"; else h_ok "a plain sentence is not quoted"; fi
h_assert_eq "$(reads)" 1 "the reader runs once, before the grade hold is decided"
if has "$r" "A reader read this reply"; then h_fail "a send verdict added reader findings to the block"; else h_ok "a send verdict adds nothing to the grade block"; fi
rcpt=$(python3 "$(h_repo_root)/lib/receipt.py" show "$home/.claude/bbd-apparatus/state/reader" "$tmp/hard.md" 2>/dev/null)
case "$rcpt" in *'"blocked": 1'*) h_ok "the first pass wrote a receipt that records the block" ;; *) h_fail "the first-pass receipt is wrong: [$rcpt]" ;; esac

# 1b. One block, both kinds of finding: the reader says fix (an unsourced claim) and the
# reply is above the ceiling. The single block quotes the reader's finding AND the hard
# sentence, and the reader was called once.
cat >"$tmp/fix-claim.txt" <<'EOF2'
VERDICT: fix
RESTATE
- none
CHAIN
- none
THE PERSON'S WORDS
- none
CLAIMS
- "every unauthenticated request was silently forwarded": say where this comes from, or drop it
ANSWERED
- none
OWNER VOICE
- none
VALUE
- 5 sentences or bullets in the body
READING
- none
CONTRACT
- none
EOF2
{ cat "$tmp/hard.md"; printf '\nThe redirect rules were rewritten as part of this pass.\n'; } >"$tmp/hard-both.md"
h_calls_reset claude
READER_OUT="$tmp/fix-claim.txt" stop both s7 p20 "$tmp/hard-both.md"
h_assert_eq "$(decision both)" block "a fix verdict and a hard reply: held"
r=$(reason both)
if has "$r" 'CLAIMS: "every unauthenticated request was silently forwarded"'; then h_ok "the one block carries the reader's finding"; else h_fail "the reader's finding is missing from the block: $r"; fi
if has "$r" '"The authentication middleware was misconfigured'; then h_ok "the one block also quotes the hard sentence"; else h_fail "the hard sentence is missing from the block: $r"; fi
h_assert_eq "$(reads)" 1 "both findings cost one reader call"
h_assert_eq "$(h_run_out both | grep -c '"decision"')" 1 "exactly one block was printed"
READER_OUT="$tmp/fix-claim.txt" stop both2 s7 p20 "$tmp/hard-both.md" stop_hook_active=true
h_assert_empty "$(h_run_out both2)" "the second pass of that turn cannot block"

# 2. The reply that follows is the second pass: it is never held again, however hard it
# is, but it is read in advisory mode and a receipt records it (the reader judges the
# reply; the grade is only a flag).
h_calls_reset claude
{ cat "$tmp/hard.md"; printf '\nThe corrected wording is shorter in places.\n'; } >"$tmp/hard-corrected.md"
stop again s1 p1 "$tmp/hard-corrected.md" stop_hook_active=true
h_assert_empty "$(h_run_out again)" "the second pass is never held again"
h_assert_eq "$(reads)" 1 "the second pass is read by the reader"
rcpt=$(python3 "$(h_repo_root)/lib/receipt.py" show "$home/.claude/bbd-apparatus/state/reader" "$tmp/hard-corrected.md" 2>/dev/null)
case "$rcpt" in *'"status": "read"'*) h_ok "the second pass wrote a receipt" ;; *) h_fail "no receipt for the second pass: [$rcpt]" ;; esac

# 2b. A reader that says fix on that second pass cannot hold the reply: advisory only.
cat >"$tmp/fix.txt" <<'EOF2'
VERDICT: fix
RESTATE
- "I made it simple": simple for whom
CHAIN
- none
THE PERSON'S WORDS
- none
CLAIMS
- none
ANSWERED
- none
OWNER VOICE
- none
VALUE
- 5 sentences or bullets in the body
READING
- none
CONTRACT
- none
EOF2
{ cat "$tmp/hard.md"; printf '\nThe release candidate was subsequently reconfigured by the infrastructure team.\n'; } >"$tmp/hard3.md"
h_calls_reset claude
READER_OUT="$tmp/fix.txt" stop advisory s5 p9 "$tmp/hard3.md" stop_hook_active=true
h_assert_empty "$(h_run_out advisory)" "a fix verdict on the second pass does not hold the reply"
h_assert_eq "$(reads)" 1 "the second pass after a reading-level hold is read"
rcpt=$(python3 "$(h_repo_root)/lib/receipt.py" show "$home/.claude/bbd-apparatus/state/reader" "$tmp/hard3.md" 2>/dev/null)
case "$rcpt" in *'"verdict": "fix"'*'"blocked": 0'*|*'"blocked": 0'*'"verdict": "fix"'*) h_ok "the receipt records the fix verdict and no block" ;; *) h_fail "the advisory receipt is wrong: [$rcpt]" ;; esac

# 2c. A score chased. The first block carried only the grade; the writer chops the
# sentences into fragments to pass it; the second-pass reader says fix. That is the one
# case where a second block is allowed, quoting the reader's findings. It is the last:
# the cap is two blocks per turn.
cat >"$tmp/fix-frag.txt" <<'EOF2'
VERDICT: fix
RESTATE
- none
CHAIN
- none
THE PERSON'S WORDS
- none
CLAIMS
- none
ANSWERED
- none
OWNER VOICE
- none
VALUE
- 5 sentences or bullets in the body
READING
- "Config bad. Fixed. Done.": fragments, not sentences; say each idea in a full plain sentence
CONTRACT
- none
EOF2
h_calls_reset claude
{ cat "$tmp/hard.md"; printf '\nThe rollout was repeated on the staging environment afterwards.\n'; } >"$tmp/hard-chase.md"
stop chase1 s8 p30 "$tmp/hard-chase.md"
h_assert_eq "$(decision chase1)" block "chased: the first pass holds on the grade alone"
if has "$(reason chase1)" "A reader read this reply"; then h_fail "chased: the first block carried reader findings"; else h_ok "chased: the first block carried only the grade"; fi
{ printf 'Config bad. Redirect wrong. Fixed it. Checked prod. Form works. Old endpoint gone. Site unchanged. Nothing needed.\n'; printf 'Everything else on the site is the same as it was and you do not need to do anything. The page loads fast. The form sends mail. The photos are small. The text is short. Ask me if you want more.\n'; } >"$tmp/frag1.md"
READER_OUT="$tmp/fix-frag.txt" stop chase2 s8 p30 "$tmp/frag1.md" stop_hook_active=true
h_assert_eq "$(decision chase2)" block "chased: a second-pass reader fix gets one more block"
if has "$(reason chase2)" "fragments, not sentences"; then h_ok "chased: the second block quotes the reader's finding"; else h_fail "chased: the second block lacks the finding: $(reason chase2)"; fi
if has "$(reason chase2)" "harder to read"; then h_fail "chased: the second block repeated the grade"; else h_ok "chased: the second block is the reader's alone"; fi
{ cat "$tmp/frag1.md"; printf 'One more edit was made.\n'; } >"$tmp/frag2.md"
READER_OUT="$tmp/fix-frag.txt" stop chase3 s8 p30 "$tmp/frag2.md" stop_hook_active=true
h_assert_empty "$(h_run_out chase3)" "chased: a third pass cannot block"
rcpt=$(python3 "$(h_repo_root)/lib/receipt.py" show "$home/.claude/bbd-apparatus/state/reader" "$tmp/frag2.md" 2>/dev/null)
case "$rcpt" in *'"blocked": 0'*) h_ok "chased: the third pass receipt records no block" ;; *) h_fail "chased: the third pass receipt is wrong: [$rcpt]" ;; esac
# The cap is held in the guard itself, whatever a caller asks for.
guard_dir="$tmp/guard-cap"
python3 "$(h_repo_root)/lib/loopguard.py" allow "$guard_dir" gs t1 9; a1=$?
python3 "$(h_repo_root)/lib/loopguard.py" allow "$guard_dir" gs t1 9; a2=$?
python3 "$(h_repo_root)/lib/loopguard.py" allow "$guard_dir" gs t1 9; a3=$?
h_assert_eq "$a1$a2$a3" "001" "the guard never allows a third block in a turn, even asked for nine"
# A first block that carried the reader's findings leaves the second pass advisory:
# that is the both/both2 case above (reader fix plus grade, then the second pass is silent).

# 3. A harness that does not send stop_hook_active: the loop guard still caps it at one.
stop capped s1 p1 "$tmp/hard.md"
h_assert_empty "$(h_run_out capped)" "the same turn is not held a second time"

# 4. A new turn may be held again (a different reply: the reader has a receipt for the last).
{ cat "$tmp/hard.md"; printf '\nThe configuration across the environments was independently verified afterwards.\n'; } >"$tmp/hard2.md"
stop next s1 p2 "$tmp/hard2.md"
h_assert_eq "$(decision next)" block "a new turn may be held again"

# 5. A plain reply goes on to the reader.
h_calls_reset claude
stop plain s2 q1 "$tmp/plain.md"
h_assert_hook_run plain "a plain reply"
h_assert_empty "$(h_run_out plain)" "a plain reply is not held"
h_assert_eq "$(reads)" 1 "a plain reply goes on to the reader"

# 6. A reply under fifty prose words is never graded.
printf 'The authentication middleware configuration was overwritten during the deployment of infrastructure.\n' >"$tmp/short.md"
h_calls_reset claude
stop short s3 r1 "$tmp/short.md"
h_assert_empty "$(h_run_out short)" "a short reply is not held for its reading level"

h_done
