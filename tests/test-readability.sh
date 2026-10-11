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
    | h_launch "$name" "$home" H_FAKE_CLAUDE_STDOUT_FILE="$tmp/send.txt" -- "$boot" stop-gate plugin
}
decision() { printf '%s' "$(h_run_out "$1")" | h_json_field decision 2>/dev/null; }
reason() { printf '%s' "$(h_run_out "$1")" | h_json_field reason 2>/dev/null; }
reads() { h_calls claude | grep -c -e '-p --model' || true; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# 1. A hard reply is held once, with the hard sentences quoted and no reader run.
h_calls_reset claude
stop hard s1 p1 "$tmp/hard.md"
h_assert_hook_run hard "a hard reply"
h_assert_eq "$(decision hard)" block "a hard reply is held"
r=$(reason hard)
if has "$r" '"The authentication middleware was misconfigured'; then h_ok "the hard sentence is quoted in the reason"; else h_fail "the reason does not quote the sentence: $r"; fi
if has "$r" "ceiling is 5"; then h_ok "the reason names the ceiling"; else h_fail "the reason does not name the ceiling"; fi
if has "$r" "Do not chop"; then h_ok "the reason says not to chop sentences into fragments"; else h_fail "the reason does not warn against chopping"; fi
if has "$r" "The contact form now submits"; then h_fail "a plain sentence is quoted"; else h_ok "a plain sentence is not quoted"; fi
h_assert_eq "$(reads)" 0 "the reader is not run on a reply that is about to be rewritten"

# 2. The reply that follows is the second pass: it goes through, however hard it is.
h_calls_reset claude
stop again s1 p1 "$tmp/hard.md" stop_hook_active=true
h_assert_empty "$(h_run_out again)" "the second pass is never held again"
h_assert_eq "$(reads)" 0 "the second pass is not read"

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
