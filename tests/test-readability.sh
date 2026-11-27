#!/usr/bin/env bash
# The reading-level gate (design D24, docs/launcher-contract.md section 13). The grader
# (lib/readability.py) is pure python with no network: plain text is under the
# fifth-grade ceiling and says nothing; hard text is over it and the hardest sentences
# come back worst first; code, links' addresses, identifiers and the lines under the
# closing `---` are not graded; a short sentence is never quoted. At Stop the reply is
# already on screen, so a reply over the ceiling is never held: after the reader has run,
# those sentences are noted for the session's next reply; a claim the reader found still
# holds the turn once, without the grade in it; a second pass goes through. Run through
# the bootstrap as a session fires it, with a fake `claude`.
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

notes_dir="$home/.claude/bbd-apparatus/state/notes"
note() { cat "$notes_dir/$1" 2>/dev/null; }
rcpt_of() { python3 "$(h_repo_root)/lib/receipt.py" show "$home/.claude/bbd-apparatus/state/reader" "$1" 2>/dev/null; }

# 1. A hard reply is read first (one call). It is already on the person's screen, so it
# is not held: the hard sentences are noted for the session's next reply instead.
h_calls_reset claude
stop hard s1 p1 "$tmp/hard.md"
h_assert_hook_run hard "a hard reply"
h_assert_empty "$(h_run_out hard)" "a hard reply is not held"
n=$(note s1)
if has "$n" '"The authentication middleware was misconfigured'; then h_ok "the hard sentence is noted for the next reply"; else h_fail "the note does not quote the sentence: $n"; fi
if has "$n" "ceiling is 5"; then h_ok "the note names the ceiling"; else h_fail "the note does not name the ceiling"; fi
if has "$n" "without chopping"; then h_ok "the note says not to chop sentences into fragments"; else h_fail "the note does not warn against chopping"; fi
if has "$n" "The contact form now submits"; then h_fail "a plain sentence is quoted"; else h_ok "a plain sentence is not quoted"; fi
h_assert_eq "$(reads)" 1 "the reader runs once"
if has "$n" "A reader found"; then h_fail "a send verdict added reader findings to the note"; else h_ok "a send verdict adds nothing to the grade note"; fi
rcpt=$(rcpt_of "$tmp/hard.md")
case "$rcpt" in *'"blocked": 0'*) h_ok "the receipt records no block" ;; *) h_fail "the first-pass receipt is wrong: [$rcpt]" ;; esac
case "$rcpt" in *'"grade_flag": 1'*) h_ok "the receipt records the grade flag" ;; *) h_fail "the receipt does not record the grade flag: [$rcpt]" ;; esac

# 1b. The reader says fix with a claim AND the reply is above the ceiling: the claim holds
# the turn once, the hard sentence is noted, never put in the block; one reader call.
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
h_assert_eq "$(decision both)" block "a claim and a hard reply: held for the claim"
r=$(reason both)
if has "$r" 'CLAIMS: "every unauthenticated request was silently forwarded"'; then h_ok "the block carries the claim"; else h_fail "the claim is missing from the block: $r"; fi
if has "$r" "harder to read"; then h_fail "the block carries the grade"; else h_ok "the grade is not in the block"; fi
if has "$(note s7)" '"The authentication middleware was misconfigured'; then h_ok "the grade is noted for the next reply"; else h_fail "the grade was not noted: $(note s7)"; fi
h_assert_eq "$(reads)" 1 "both findings cost one reader call"
h_assert_eq "$(h_run_out both | grep -c '"decision"')" 1 "exactly one block was printed"
# The second pass of that turn can no longer block: the one extra block of design D45
# (a score chased after a grade hold) cannot arise once the grade holds nothing.
{ printf 'Redirect bad. Fixed it. Checked prod. Form works. Endpoint gone. Site same. Nothing needed from you. Ask if you want more. The page is fast. The mail sends.\n'; printf 'Every other page is as it was and you do not have to do anything more today. The old photos are gone. The text is short. The phone view is fine. The desktop view is fine. Nothing else moved.\n'; } >"$tmp/frag-both.md"
READER_OUT="$tmp/fix-claim.txt" stop both2 s7 p20 "$tmp/frag-both.md" stop_hook_active=true
h_assert_empty "$(h_run_out both2)" "the second pass of that turn cannot block"

# 2. A second pass is never held, however hard it is, but it is read in advisory mode and
# a receipt records it (the reader judges the reply; the grade is only a flag).
h_calls_reset claude
{ cat "$tmp/hard.md"; printf '\nThe corrected wording is shorter in places.\n'; } >"$tmp/hard-corrected.md"
stop again s1 p1 "$tmp/hard-corrected.md" stop_hook_active=true
h_assert_empty "$(h_run_out again)" "the second pass is never held"
h_assert_eq "$(reads)" 1 "the second pass is read by the reader"
case "$(rcpt_of "$tmp/hard-corrected.md")" in *'"status": "read"'*) h_ok "the second pass wrote a receipt" ;; *) h_fail "no receipt for the second pass" ;; esac

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
h_assert_eq "$(reads)" 1 "the second pass is read"
rcpt=$(rcpt_of "$tmp/hard3.md")
case "$rcpt" in *'"verdict": "fix"'*'"blocked": 0'*|*'"blocked": 0'*'"verdict": "fix"'*) h_ok "the receipt records the fix verdict and no block" ;; *) h_fail "the advisory receipt is wrong: [$rcpt]" ;; esac

# The guard still holds its cap itself, whatever a caller asks for (lib/loopguard.py).
guard_dir="$tmp/guard-cap"
python3 "$(h_repo_root)/lib/loopguard.py" allow "$guard_dir" gs t1 9; a1=$?
python3 "$(h_repo_root)/lib/loopguard.py" allow "$guard_dir" gs t1 9; a2=$?
python3 "$(h_repo_root)/lib/loopguard.py" allow "$guard_dir" gs t1 9; a3=$?
h_assert_eq "$a1$a2$a3" "001" "the guard never allows a third block in a turn, even asked for nine"
guard_dir2="$tmp/guard-ro"
python3 "$(h_repo_root)/lib/loopguard.py" allow "$guard_dir2" gr t1 1 grade; r1=$?
chmod 444 "$guard_dir2/gr.turn"
python3 "$(h_repo_root)/lib/loopguard.py" allow "$guard_dir2" gr t1 2 grade; r2=$?
python3 "$(h_repo_root)/lib/loopguard.py" allow "$guard_dir2" gr t1 2 grade; r3=$?
chmod 644 "$guard_dir2/gr.turn"
h_assert_eq "$r1$r2$r3" "011" "a record that cannot be written: the cap-2 call refuses, every time"

# 3. The same turn again without stop_hook_active: still nothing held.
stop capped s1 p1 "$tmp/hard.md"
h_assert_empty "$(h_run_out capped)" "the same turn is not held"

# 4. A new turn with a hard reply: not held either, and noted again.
rm -f "$notes_dir/s1"
{ cat "$tmp/hard.md"; printf '\nThe configuration across the environments was independently verified afterwards.\n'; } >"$tmp/hard2.md"
stop next s1 p2 "$tmp/hard2.md"
h_assert_empty "$(h_run_out next)" "a new turn with a hard reply is not held"
if has "$(note s1)" "ceiling is 5"; then h_ok "a new turn's grade is noted again"; else h_fail "a new turn's grade was not noted"; fi

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
