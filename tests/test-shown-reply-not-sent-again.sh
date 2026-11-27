#!/usr/bin/env bash
# A reply the person has already read is never sent again (docs/launcher-contract.md
# section 13). Stop fires after the reply is on screen, so a block that says "send it
# again" makes a second full reply, which the person asked never to get. Replays of the
# two real cases, run through the bootstrap as a session fires it, with a fake `claude`:
#
#   1. a reply above the reading ceiling (the grade-5.5 case): not held; the grade and
#      the hard sentences reach the next prompt, once;
#   2. a reply of fifty words or more that leaves an ask out (the "where these asks
#      stand" case): not held; the asks reach the next prompt, once;
#   3. the reader's findings other than CLAIMS: not held; noted the same way;
#   4. a claim the reader found unsourced still holds the turn once, and the block says
#      not to send the reply again: fix the cause, one short line only if a fact is false;
#   5. nothing the Stop gate prints asks for the reply again.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

h_fake_bin git
h_fake_bin claude
h_fake_apparatus >/dev/null
boot=$(h_bootstrap)
home=$(h_fake_home h1)
repo=$(h_fake_repo vault)
h_mark "$repo" tenant-a
h_tenant_env "$home" tenant-a "BBD_CHANNEL=stable"
tmp=$(h_tmpdir)

verdict() { # FILE VERDICT SECTION FINDING: a reader answer with one finding (or none)
  local out=$1 v=$2 sec=$3 finding=$4 s
  {
    printf 'VERDICT: %s\n' "$v"
    for s in RESTATE CHAIN "THE PERSON'S WORDS" CLAIMS ANSWERED "OWNER VOICE" VALUE READING CONTRACT; do
      printf '%s\n' "$s"
      if [ "$s" = "$sec" ]; then printf -- '- %s\n' "$finding"
      elif [ "$s" = VALUE ]; then printf -- '- 5 sentences or bullets in the body\n'
      else printf -- '- none\n'; fi
    done
  } >"$out"
}
verdict "$tmp/send.txt" send none none
verdict "$tmp/fix-claim.txt" fix CLAIMS '"I tested the form and it works.": show what proved this'
verdict "$tmp/fix-restate.txt" fix RESTATE '"I made it simple": simple for whom'

prompt() { # SESSION PROMPT-ID TEXT
  h_hook_json UserPromptSubmit cwd="$repo" session_id="$1" prompt_id="$2" prompt="$3" \
    | h_launch "prompt-$1-$2" "$home" -- "$boot" prompt plugin
}
ctx() { # SESSION PROMPT-ID: the context the prompt step printed
  printf '%s' "$(h_run_out "prompt-$1-$2")" | python3 -c 'import json,sys
raw=sys.stdin.read().strip()
print(json.loads(raw)["hookSpecificOutput"]["additionalContext"] if raw else "")'
}
stop() { # NAME SESSION PROMPT-ID REPLY-FILE READER-ANSWER
  h_hook_json Stop cwd="$repo" session_id="$2" prompt_id="$3" stop_reason=end_turn \
      last_assistant_message="$(cat "$4")" \
    | h_launch "$1" "$home" H_FAKE_CLAUDE_STDOUT_FILE="$5" -- "$boot" stop-gate plugin
}
decision() { printf '%s' "$(h_run_out "$1")" | h_json_field decision 2>/dev/null; }
reason() { printf '%s' "$(h_run_out "$1")" | h_json_field reason 2>/dev/null; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
asks_again() { # TEXT: whether it asks for the reply to be sent again
  printf '%s' "$1" | sed 's/do not send it again//g' \
    | grep -qiE 'send (it|the reply|this reply|the corrected reply) again|then send the corrected reply'
}

# 1. The grade case: every ask accounted for, the reader says send, the reply grades
# above the ceiling.
sid="s-grade"
prompt "$sid" g1 "Import my old chat transcripts into the vault."
cat >"$tmp/hard.md" <<'EOF'
All of your old conversations are in the vault now, word for word, notwithstanding the verification asymmetry whereby the secondary checker could only sample the corpus, so the comprehensive reconciliation remains independently unconfirmed. Consequently, the implementation prioritizes deterministic serialization, notwithstanding substantial computational overhead attributable to concurrent ingestion procedures. The pictures are in too.

Done.
EOF
stop grade "$sid" g1 "$tmp/hard.md" "$tmp/send.txt"
h_assert_hook_run grade "a reply above the reading ceiling"
h_assert_empty "$(h_run_out grade)" "the grade case: a shown reply is not held"
prompt "$sid" g2 "Thanks. What next?"
c=$(ctx "$sid" g2)
if has "$c" "Do not send it again" && has "$c" "the ceiling is 5"; then h_ok "the grade case: the next prompt hears the grade"
else h_fail "the grade case: the next prompt does not carry the grade: $c"; fi
if has "$c" '"All of your old conversations are in the vault now'; then h_ok "the grade case: the hard sentence is quoted to the next reply"
else h_fail "the grade case: the hard sentence is missing: $c"; fi
prompt "$sid" g3 "And after that?"
if has "$(ctx "$sid" g3)" "About your last reply"; then h_fail "the grade case: the note came back a second time"
else h_ok "the grade case: the note is heard once"; fi

# 2. The asks case: two asks, a reply of fifty words or more that names only the first.
sid="s-asks"
prompt "$sid" a1 "Help me write a short, warm text to the coach about a later class time."
prompt "$sid" a1 "Also check whether Thursday works."
cat >"$tmp/asks.md" <<'EOF'
Here is a short, warm text you can send to the coach. It asks whether the whole family
can come to a later class, around five or after, three days a week, so everyone can go
together. It thanks the coach first and keeps the ask to one plain question. You can
change the days before you send it if the week looks different.

1. The text: done, it is above.
EOF
stop asks "$sid" a1 "$tmp/asks.md" "$tmp/send.txt"
h_assert_hook_run asks "a reply that leaves an ask out"
h_assert_empty "$(h_run_out asks)" "the asks case: a shown reply is not held"
prompt "$sid" a2 "Thanks."
c=$(ctx "$sid" a2)
if has "$c" "did not say where these asks stand" && has "$c" "2. Also check whether Thursday works."; then
  h_ok "the asks case: the next prompt hears the ask left out"
else h_fail "the asks case: the next prompt does not carry the missing ask: $c"; fi
if has "$c" "1. Help me write"; then h_fail "the asks case: the ask the reply did name came back in the note"
else h_ok "the asks case: only the missing ask is noted"; fi
prompt "$sid" a3 "Anything else?"
if has "$(ctx "$sid" a3)" "About your last reply"; then h_fail "the asks case: the note came back a second time"
else h_ok "the asks case: the note is heard once"; fi

# 3. A reader finding that is not a claim: noted, not held.
sid="s-restate"
cat >"$tmp/plain.md" <<'EOF'
The form sends again. It broke when the site moved hosts. The page still posted to the old
address, so every message was lost. I made it simple: I fixed the address and sent a test
message. It landed. I cannot tell how many messages were lost, because the old host kept
no record. Nothing is yours to do.

Done.
EOF
stop restate "$sid" r1 "$tmp/plain.md" "$tmp/fix-restate.txt"
h_assert_empty "$(h_run_out restate)" "a reader finding that is not a claim: not held"
prompt "$sid" r2 "Great."
c=$(ctx "$sid" r2)
if has "$c" 'RESTATE: "I made it simple": simple for whom'; then h_ok "a reader finding that is not a claim reaches the next prompt"
else h_fail "the reader's finding did not reach the next prompt: $c"; fi

# 4. A claim to check still holds the turn once, and never asks for the reply again.
sid="s-claim"
{ cat "$tmp/plain.md"; printf '\nI tested the form and it works.\n'; } >"$tmp/claim.md"
stop claim "$sid" c1 "$tmp/claim.md" "$tmp/fix-claim.txt"
h_assert_eq "$(decision claim)" block "a claim to check: the turn is held"
r=$(reason claim)
if has "$r" 'CLAIMS: "I tested the form and it works."'; then h_ok "a claim to check: the claim is quoted"; else h_fail "a claim to check: the claim is missing: $r"; fi
if has "$r" "do not send it again" && has "$r" "one short line"; then h_ok "a claim to check: the block says one short line, never the reply again"
else h_fail "a claim to check: the block does not say how to fix it: $r"; fi
if asks_again "$r"; then h_fail "a claim to check: the block asks for the reply again: $r"; else h_ok "a claim to check: the block never asks for the reply again"; fi
h_hook_json Stop cwd="$repo" session_id="$sid" prompt_id=c1 stop_reason=end_turn stop_hook_active=true \
    last_assistant_message="$(cat "$tmp/claim.md")
Correction: I sent one test message; I did not test every page." \
  | h_launch claim2 "$home" H_FAKE_CLAUDE_STDOUT_FILE="$tmp/fix-claim.txt" -- "$boot" stop-gate plugin
h_assert_empty "$(h_run_out claim2)" "a claim to check: the second pass goes through"

# 5. Nothing the Stop gate can print asks for a shown reply again.
gate="$(h_repo_root)/launcher/events/stop-gate.sh"
if asks_again "$(grep -v '^[[:space:]]*#' "$gate")"; then h_fail "the Stop gate still has words that ask for the reply again"
else h_ok "the Stop gate never asks for the reply again"; fi
for n in grade asks restate; do
  if asks_again "$(reason "$n")"; then h_fail "$n: a block asked for the reply again"; fi
done

h_done
