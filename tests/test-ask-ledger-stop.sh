#!/usr/bin/env bash
# The ask ledger at Stop (docs/launcher-contract.md sections 11 and 13, design D23).
# Every prompt is an item in the session's ledger, including the ones sent while the
# agent was working. A reply of fifty prose words or more that leaves a pending ask out
# is held once, with the missing asks handed back; the reply that names each ask by
# number with done, running or waiting goes through. The ledger moves to match what the
# reply says, on the held pass and the second pass alike; only done leaves the list;
# running and waiting items are injected on every later prompt and after a compaction,
# with their state. One pending ask is accounted for by the contract's closing line.
# A reply under fifty words is never held for this. Run through the bootstrap exactly
# as a session fires it, with a fake `claude` standing in for the reader.
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
base="$home/.claude/bbd-apparatus"
ledger="$base/state/ledger"

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

# A reply long enough to be read (over fifty prose words); the lines after the filler
# are the part under test. Each call makes a different reply.
filler() {
  printf 'Here is where the work stands after this pass over the site. The pages load faster now, '
  printf 'the images are smaller, and the form sends again. I checked each page on a phone and on a '
  printf 'desktop, and nothing else on them moved. The old photos are gone from the home page, and '
  printf 'the text there is shorter, so it reads in half the time it did. Reply number %s.\n\n' "$1"
}
prompt() { # SESSION PROMPT-ID TEXT
  h_hook_json UserPromptSubmit cwd="$repo" session_id="$1" prompt_id="$2" prompt="$3" \
    | h_launch "prompt-$1-$2" "$home" -- "$boot" prompt plugin
}
stop() { # NAME SESSION PROMPT-ID REPLY [hook key=value ...]
  local name=$1 sid=$2 pid=$3 reply=$4
  shift 4
  h_hook_json Stop cwd="$repo" session_id="$sid" prompt_id="$pid" stop_reason=end_turn \
      last_assistant_message="$reply" "$@" \
    | h_launch "$name" "$home" H_FAKE_CLAUDE_STDOUT_FILE="$tmp/send.txt" -- "$boot" stop-gate plugin
}
decision() { printf '%s' "$(h_run_out "$1")" | h_json_field decision 2>/dev/null; }
reason() { printf '%s' "$(h_run_out "$1")" | h_json_field reason 2>/dev/null; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
state_of() { grep -E "^$2\. " "$ledger/$1.md" | awk '{print $2}'; }
reads() { h_calls claude | grep -c -e '-p --model' || true; }

# 1. Three asks in one turn, the last two sent while the agent was working. The reply
# names only the first: it is held once, and the other two are handed back.
sid=s-three
prompt "$sid" t1 "Make the home page load faster."
prompt "$sid" t1 "Is the contact form working?"
prompt "$sid" t1 "Put our opening hours in the footer."
h_assert_eq "$(grep -c -E '^[0-9]+\. open ' "$ledger/$sid.md")" 3 "three prompts in one turn are three items"
stop held "$sid" t1 "$(filler 1)
1. Home page: done, it loads in two seconds.

Still running: the form and the hours."
h_assert_hook_run held "a reply that leaves two asks out"
h_assert_eq "$(decision held)" block "the reply is held"
r=$(reason held)
if has "$r" "2. Is the contact form working?" && has "$r" "3. Put our opening hours in the footer."; then
  h_ok "the held reason hands back both missing asks"
else h_fail "the held reason does not list the missing asks: $r"; fi
if has "$r" "1. Make the home page"; then h_fail "the reason lists the ask the reply did name"; else h_ok "the ask the reply did name is not handed back"; fi
if has "$r" "done, running or waiting"; then h_ok "the reason says what to mark each ask"; else h_fail "the reason does not say how to mark"; fi
h_assert_eq "$(state_of "$sid" 1)" "done" "the ask the reply called done is closed"
h_assert_eq "$(reads)" 1 "a reply held for the ledger is read once, in the same pass"
if has "$r" "A reader read this reply"; then h_fail "a send verdict added reader findings to the ledger block"; else h_ok "a send verdict adds nothing to the ledger block"; fi

# 1b. The reader says fix AND two asks are left out: one block, both in it, one reader call.
cat >"$tmp/fix.txt" <<'EOF2'
VERDICT: fix
RESTATE
- none
CHAIN
- none
THE PERSON'S WORDS
- none
CLAIMS
- "the pages load faster now": say where this comes from, or drop it
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
sidb=s-both
prompt "$sidb" b1 "Make the home page load faster."
prompt "$sidb" b1 "Is the contact form working?"
h_calls_reset claude
h_hook_json Stop cwd="$repo" session_id="$sidb" prompt_id=b1 stop_reason=end_turn \
    last_assistant_message="$(filler 20)
1. Home page: done." \
  | h_launch both "$home" H_FAKE_CLAUDE_STDOUT_FILE="$tmp/fix.txt" -- "$boot" stop-gate plugin
h_assert_eq "$(decision both)" block "a fix verdict and a missing ask: held"
rb=$(reason both)
if has "$rb" "the pages load faster now" && has "$rb" "2. Is the contact form working?"; then h_ok "the one block carries the reader's finding and the missing ask"; else h_fail "the combined block is missing a part: $rb"; fi
h_assert_eq "$(reads)" 1 "both findings cost one reader call"
h_assert_eq "$(h_run_out both | grep -c '"decision"')" 1 "exactly one block was printed"
h_hook_json Stop cwd="$repo" session_id="$sidb" prompt_id=b1 stop_reason=end_turn stop_hook_active=true \
    last_assistant_message="$(filler 21)
1. Home page: done.
2. The form: done." \
  | h_launch both2 "$home" H_FAKE_CLAUDE_STDOUT_FILE="$tmp/fix.txt" -- "$boot" stop-gate plugin
h_assert_empty "$(h_run_out both2)" "the second pass cannot block, whatever the reader says"

# 2. The corrected reply is the second pass: it goes through, and the ledger follows it.
h_calls_reset claude
stop second "$sid" t1 "$(filler 2)
1. Home page: done.
2. The form: running, I am testing it.
3. Opening hours: waiting on you for the hours.

Waiting on you for the hours." stop_hook_active=true
h_assert_hook_run second "the second pass"
h_assert_empty "$(h_run_out second)" "the second pass is not held"
h_assert_eq "$(state_of "$sid" 2)" running "the second pass moves item 2 to running"
h_assert_eq "$(state_of "$sid" 3)" waiting "the second pass moves item 3 to waiting"
h_assert_eq "$(reads)" 1 "the corrected reply is still read, in advisory mode"

# 3. Running and waiting items come back on the next prompt, with their state, and after
# a compaction; the closed one does not.
prompt "$sid" t2 "Thanks. And what about the logo?"
ctx=$(printf '%s' "$(h_run_out "prompt-$sid-t2")" | python3 -c 'import json,sys
print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')
if has "$ctx" "2. (running) Is the contact form working?" && has "$ctx" "3. (waiting) Put our opening hours"; then
  h_ok "the next prompt carries the running and waiting items with their state"
else h_fail "the next prompt does not carry the pending items: $ctx"; fi
if has "$ctx" "1. Make the home page"; then h_fail "a closed item came back"; else h_ok "the closed item does not come back"; fi
if has "$ctx" "4. Thanks. And what about the logo"; then h_ok "the new ask is item 4"; else h_fail "the new ask is not item 4"; fi
h_hook_json SessionStart cwd="$repo" session_id="$sid" source=compact model=test-model \
  | h_launch compacted "$home" -- "$boot" session-start plugin
cctx=$(printf '%s' "$(h_run_out compacted)" | python3 -c 'import json,sys
print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')
if has "$cctx" "2. (running) Is the contact form working?" && has "$cctx" "4. Thanks. And what about the logo"; then
  h_ok "a compaction brings the pending items back"
else h_fail "a compaction lost the pending items: $cctx"; fi

# 4. A reply that accounts for every pending ask goes through to the reader, and the
# reader is given the asks as they stood before the reply closed them.
h_calls_reset claude
stop answered "$sid" t2 "$(filler 4)
2. The form: done, a test message landed.
3. Opening hours: done, they are in the footer.
4. The logo: done, it is larger.

Done." H_FAKE_CLAUDE_RECORD="$tmp/rec"
h_assert_hook_run answered "a reply that accounts for every ask"
h_assert_empty "$(h_run_out answered)" "a complete reply is not held"
h_assert_eq "$(reads)" 1 "a complete reply goes on to the reader"
h_assert_eq "$(grep -c -E '^[0-9]+\. done ' "$ledger/$sid.md")" 4 "every item is now done"
h_assert_empty "$(grep -E '^[0-9]+\. (open|running|waiting) ' "$ledger/$sid.md")" "nothing is pending"

# 5. One pending ask: the contract's closing line is its state, and the reply passes.
sid=s-one
prompt "$sid" u1 "Change the heading to green."
h_calls_reset claude
stop one "$sid" u1 "$(filler 5)
The heading is green on every page.

Done."
h_assert_empty "$(h_run_out one)" "one pending ask and a closing line: not held"
h_assert_eq "$(state_of "$sid" 1)" "done" "the closing line closes the one ask"
prompt "$sid" u2 "Now the footer."
stop none "$sid" u2 "$(filler 6)
The footer changed."
h_assert_eq "$(decision none)" block "one pending ask and no closing line: held"
h_assert_eq "$(state_of "$sid" 2)" open "an ask the reply does not state stays open"

# 6. A short reply is an acknowledgement: never held, but it can still close an ask.
sid=s-short
prompt "$sid" v1 "Is it live?"
prompt "$sid" v1 "Is the form fixed?"
stop short "$sid" v1 "1. Yes, it is live.
2. Done."
h_assert_empty "$(h_run_out short)" "a short reply is not held"
h_assert_eq "$(state_of "$sid" 2)" "done" "a short reply still moves the ledger"
h_assert_eq "$(state_of "$sid" 1)" open "what a short reply does not say stays open"

# 7. A session with no ledger (no prompt was recorded) is never held for the ledger.
stop noledger s-none n1 "$(filler 7)
Nothing else."
h_assert_empty "$(h_run_out noledger)" "no ledger: nothing is held"

h_done
