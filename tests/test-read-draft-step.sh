#!/usr/bin/env bash
# The read-draft Stop step (docs/launcher-contract.md section 13), run through the
# bootstrap exactly as a session would fire it, with a fake `claude` standing in for
# the reader. A verdict of send passes silently; a verdict with findings blocks once,
# with the findings as the reason, and the same turn is never blocked again (the
# second pass carries stop_hook_active; a pass without it is capped by the loop guard);
# a new turn may block again. A draft already read, a draft under fifty prose words,
# a second pass and a repository with no rules file are not read at all. A reader that
# is absent, slow, failing or out of shape lets the reply through within the bound,
# logged, and a receipt is written for every read and every attempt. The token never
# reaches stdout, the log or the reader's input, and the reader's own session carries
# BBD_NESTED so its hooks do nothing. The skill event prints how to give a draft, then
# the verdict for one, and hands the prompt back when the reader cannot run.
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
tmp=$(h_tmpdir)
base="$home/.claude/bbd-apparatus"
receipts="$base/state/reader"
body=$(python3 -c 'import random,string; print("".join(random.choice(string.ascii_letters+string.digits) for _ in range(40)))')
token="bbdt""_$body"
h_tenant_env "$home" tenant-a "BBD_CHANNEL=stable" "BBD_TOKEN=$token"

printf '%s\n' "# Rules" "RULE-ALPHA: tell me what happened before how." "RULE-TOKEN: the key is $token" >"$repo/RULES.md"
git -C "$repo" add RULES.md
h_git -C "$repo" commit -q -m "chore: rules"

# Drafts. The long ones pass the fifty-word floor; each differs so its receipt differs.
draft() { # N: a substantive reply, with the token planted in it
  cat <<EOF
[site: contact form] draft $1

The form sends again. It broke when the site moved hosts: the page was still posting
to the old host's address, so every message was dropped without a word shown on the
page. I pointed it at the new address and sent a test message through it, which landed.
I cannot say how many messages were lost, because the old host kept no record. The key
in the settings is $token and it was not the cause. Nothing is yours to do.

Done.
EOF
}
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13; do draft "$n" >"$tmp/long-$n.md"; done
printf 'Done. The form sends again; nothing is yours to do.\n' >"$tmp/short.md"

# The reader's canned answers, in the shape the prompt asks for.
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
cat >"$tmp/fix.txt" <<EOF
[reader]
VERDICT: fix
RESTATE
- "I pointed it at the new address": which address
CHAIN
- none
THE PERSON'S WORDS
- none
CLAIMS
- "The key in the settings is $token and it was not the cause": how do you know it was not
ANSWERED
- "2. put our hours in the footer": not answered
OWNER VOICE
- none
VALUE
- 6 sentences or bullets in the body
READING
- none
CONTRACT
- none

Everything you asked for is done.
---
- ids: none
EOF
printf 'I read it and it seems fine to me, nothing to add.\n' >"$tmp/garbage.txt"

# stop NAME SESSION PROMPT-ID DRAFT-FILE [hook key=value ...] -- [VAR=value ...]: one Stop
# from the plugin. CLAUDECODE is set as a real session sets it, to see it stripped.
stop() {
  local name=$1 sid=$2 pid=$3 file=$4 hook=() vars=()
  shift 4
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do hook+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  vars=("$@")
  h_hook_json Stop cwd="$repo" session_id="$sid" prompt_id="$pid" stop_reason=end_turn \
      last_assistant_message="$(cat "$file")" ${hook[@]+"${hook[@]}"} \
    | h_launch "$name" "$home" CLAUDECODE=1 ${vars[@]+"${vars[@]}"} -- "$boot" stop-gate plugin
}
# prompt NAME SESSION TEXT: one UserPromptSubmit, so the session has an ask on record.
prompt() {
  h_hook_json UserPromptSubmit cwd="$repo" session_id="$2" prompt="$3" \
    | h_launch "$1" "$home" -- "$boot" prompt plugin
}
reads() { h_calls claude | grep -c -e '-p --model' || true; }
# receipt FILE KEY: one field of the receipt for a draft, or nothing.
receipt() {
  python3 "$(h_repo_root)/lib/receipt.py" show "$receipts" "$1" 2>/dev/null \
    | python3 -c 'import json,sys
raw=sys.stdin.read().strip()
d=json.loads(raw) if raw else {}
v=d.get(sys.argv[1],"")
print(v if not isinstance(v,bool) else ("1" if v else "0"))' "$2"
}
decision() { printf '%s' "$(h_run_out "$1")" | h_json_field decision 2>/dev/null; }
reason() { printf '%s' "$(h_run_out "$1")" | h_json_field reason 2>/dev/null; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
logf="$base/state/launcher.log"

# 1. A verdict of send: nothing on stdout, one reader call, a receipt that says so, and
# the reader was given the draft, the rules, the contract and the session's ask, with
# BBD_NESTED set and CLAUDECODE stripped, and never the token.
prompt ask-1 s1 "Why did the contact form stop sending?"
h_calls_reset claude
stop send s1 p1 "$tmp/long-1.md" -- H_FAKE_CLAUDE_STDOUT_FILE="$tmp/send.txt" H_FAKE_CLAUDE_RECORD="$tmp/rec-send"
h_assert_hook_run send "send verdict"
h_assert_empty "$(h_run_out send)" "send verdict: nothing on stdout"
h_assert_eq "$(reads)" 1 "send verdict: the reader ran once"
h_assert_eq "$(receipt "$tmp/long-1.md" status)" read "send verdict: the receipt records a read"
h_assert_eq "$(receipt "$tmp/long-1.md" verdict)" send "send verdict: the receipt records send"
h_assert_eq "$(receipt "$tmp/long-1.md" blocked)" 0 "send verdict: the receipt records no block"
h_assert_eq "$(receipt "$tmp/long-1.md" session)" s1 "send verdict: the receipt names the session"
given=$(cat "$tmp"/rec-send/stdin.* 2>/dev/null)
if has "$given" "The form sends again"; then h_ok "the reader was given the draft"; else h_fail "the reader was not given the draft"; fi
if has "$given" "RULE-ALPHA"; then h_ok "the reader was given the rules file"; else h_fail "the reader was not given the rules file"; fi
if has "$given" "Start with the answer"; then h_ok "the reader was given the reply contract"; else h_fail "the reader was not given the reply contract"; fi
if has "$given" "Why did the contact form stop sending"; then h_ok "the reader was given the session's ask"; else h_fail "the reader was not given the session's ask"; fi
if has "$given" "a reply to the person"; then h_ok "the draft is named as a reply"; else h_fail "the draft's kind is not named"; fi
if has "$given" "$body"; then h_fail "the token reached the reader's input"; else h_ok "the token never reached the reader's input"; fi
if has "$given" "[token]"; then h_ok "the token shape is masked in the reader's input"; else h_fail "the token shape is not masked in the reader's input"; fi
envs=$(cat "$tmp"/rec-send/env.* 2>/dev/null)
if has "$envs" "BBD_NESTED=1"; then h_ok "the reader's session carries BBD_NESTED"; else h_fail "the reader's session does not carry BBD_NESTED"; fi
if printf '%s\n' "$envs" | grep -q '^CLAUDECODE='; then h_fail "CLAUDECODE reached the reader's session"; else h_ok "CLAUDECODE is stripped from the reader's session"; fi
case "$(h_calls claude)" in *"--tools ''"*|*'--tools ""'*) h_ok "the reader runs with no tools" ;; *) h_fail "the reader was not run with no tools: $(h_calls claude)" ;; esac
case "$(h_calls claude)" in *"--model sonnet"*) h_ok "the reader runs on sonnet" ;; *) h_fail "the reader was not run on sonnet" ;; esac

# 2. A verdict with findings: one block, the findings as the reason, the token masked.
h_calls_reset claude
stop fix s2 p2 "$tmp/long-2.md" -- H_FAKE_CLAUDE_STDOUT_FILE="$tmp/fix.txt"
h_assert_hook_run fix "fix verdict"
h_assert_eq "$(decision fix)" block "fix verdict: the decision is block"
r=$(reason fix)
if has "$r" 'RESTATE: "I pointed it at the new address": which address'; then h_ok "fix verdict: the reason quotes the finding"; else h_fail "fix verdict: the reason lacks the finding: $r"; fi
if has "$r" "2. put our hours in the footer"; then h_ok "fix verdict: the unanswered ask is in the reason"; else h_fail "fix verdict: the unanswered ask is missing"; fi
if has "$r" "corrected reply"; then h_ok "fix verdict: the reason asks for the corrected reply"; else h_fail "fix verdict: the reason does not ask for a corrected reply"; fi
if has "$r" "6 sentences"; then h_fail "fix verdict: the count line was taken as a finding"; else h_ok "fix verdict: the count line is not a finding"; fi
if has "$r" "ids: none"; then h_fail "fix verdict: a line below the trailer was taken as a finding"; else h_ok "fix verdict: the trailer is not read"; fi
if has "$(h_run_out fix)" "$body"; then h_fail "fix verdict: the token reached stdout"; else h_ok "fix verdict: the token never reached stdout"; fi
if has "$r" "[token]"; then h_ok "fix verdict: the token shape is masked in the reason"; else h_fail "fix verdict: the token shape is not masked in the reason"; fi
h_assert_eq "$(receipt "$tmp/long-2.md" verdict)" fix "fix verdict: the receipt records fix"
h_assert_eq "$(receipt "$tmp/long-2.md" blocked)" 1 "fix verdict: the receipt records the block"
h_assert_eq "$(receipt "$tmp/long-2.md" findings)" 3 "fix verdict: the receipt counts three findings"

# 3. The second pass of that turn carries stop_hook_active: not read, not blocked.
stop second s2 p2 "$tmp/long-3.md" stop_hook_active=true -- H_FAKE_CLAUDE_STDOUT_FILE="$tmp/fix.txt"
h_assert_hook_run second "second pass"
h_assert_empty "$(h_run_out second)" "second pass: nothing on stdout"
h_assert_eq "$(reads)" 1 "second pass: the reader did not run again"
h_assert_empty "$(receipt "$tmp/long-3.md" status)" "second pass: no receipt, nothing was read"

# 4. A pass of the same turn without stop_hook_active (a harness that does not send
# it) is read, but the loop guard lets it through: one block per turn.
stop capped s2 p2 "$tmp/long-4.md" -- H_FAKE_CLAUDE_STDOUT_FILE="$tmp/fix.txt"
h_assert_hook_run capped "capped pass"
h_assert_empty "$(h_run_out capped)" "capped pass: nothing on stdout although the reader said fix"
h_assert_eq "$(reads)" 2 "capped pass: the reader ran"
h_assert_eq "$(receipt "$tmp/long-4.md" verdict)" fix "capped pass: the receipt records fix"
h_assert_eq "$(receipt "$tmp/long-4.md" blocked)" 0 "capped pass: the receipt records no block"
if grep -q "a block already happened this turn" "$logf"; then h_ok "capped pass: the log says why"; else h_fail "capped pass: the log does not say why"; fi

# 5. A new turn in the same session may block again.
stop newturn s2 p3 "$tmp/long-5.md" -- H_FAKE_CLAUDE_STDOUT_FILE="$tmp/fix.txt"
h_assert_hook_run newturn "new turn"
h_assert_eq "$(decision newturn)" block "new turn: blocks again"

# 6. A draft read already is not read again, whatever the reader would say now.
h_calls_reset claude
stop again s3 p4 "$tmp/long-1.md" -- H_FAKE_CLAUDE_STDOUT_FILE="$tmp/fix.txt"
h_assert_hook_run again "a draft read already"
h_assert_empty "$(h_run_out again)" "a draft read already: nothing on stdout"
h_assert_eq "$(reads)" 0 "a draft read already: the reader did not run"

# 7. Under fifty prose words there is nothing to read.
h_calls_reset claude
stop short s4 p5 "$tmp/short.md" -- H_FAKE_CLAUDE_STDOUT_FILE="$tmp/fix.txt"
h_assert_hook_run short "a short reply"
h_assert_empty "$(h_run_out short)" "a short reply: nothing on stdout"
h_assert_eq "$(reads)" 0 "a short reply: the reader did not run"
h_assert_empty "$(receipt "$tmp/short.md" status)" "a short reply: no receipt"

# 8. No rules file in the repository (the marker names RULES.md and none is committed,
# which is every new tenant's state): the reply is still read, against the reply
# contract alone, with the rules part given as "(none)".
repo2=$(h_fake_repo vault2)
h_mark "$repo2" tenant-a
h_calls_reset claude
h_hook_json Stop cwd="$repo2" session_id=s5 prompt_id=p6 stop_reason=end_turn \
    last_assistant_message="$(cat "$tmp/long-6.md")" \
  | h_launch norules "$home" H_FAKE_CLAUDE_STDOUT_FILE="$tmp/send.txt" H_FAKE_CLAUDE_RECORD="$tmp/rec-norules" -- "$boot" stop-gate plugin
h_assert_hook_run norules "no rules file"
h_assert_empty "$(h_run_out norules)" "no rules file: nothing on stdout for a send verdict"
h_assert_eq "$(reads)" 1 "no rules file: the reader still ran"
h_assert_eq "$(receipt "$tmp/long-6.md" status)" read "no rules file: the receipt records a read"
given=$(cat "$tmp"/rec-norules/stdin.* 2>/dev/null)
if has "$given" "Start with the answer"; then h_ok "no rules file: the reader was given the reply contract"; else h_fail "no rules file: the reader was not given the reply contract"; fi
if has "$given" "RULE-ALPHA"; then h_fail "no rules file: another repository's rules reached the reader"; else h_ok "no rules file: no rules reached the reader"; fi
case "$given" in *"THE PERSON'S RULES"*"(none)"*"THE ASKS"*) h_ok "no rules file: the rules part reads (none)" ;; *) h_fail "no rules file: the rules part does not read (none)" ;; esac
rm -f "$receipts/$(python3 "$(h_repo_root)/lib/receipt.py" hash "$tmp/long-6.md").json"

# 9. No claude on PATH on a desktop home: the reply goes through at once, and the
# receipt says unread.
nobin="$tmp/bin-noclaude"
mkdir -p "$nobin"
ln -s "$tmp/bin/git" "$nobin/git"
# Every directory on PATH that holds a claude goes, the fake's and any real one (the
# CI runner installs one for the manifest test), so no run can reach a real account.
rest=""
while IFS= read -r d; do
  [ -n "$d" ] && [ ! -x "$d/claude" ] && rest="${rest:+$rest:}$d"
done <<PATHS
$(printf '%s' "$PATH" | tr ':' '\n')
PATHS
h_calls_reset claude
stop absent s6 p7 "$tmp/long-6.md" -- PATH="$nobin:$rest" H_FAKE_CLAUDE_STDOUT_FILE="$tmp/fix.txt"
h_assert_hook_run absent "no claude on PATH"
h_assert_empty "$(h_run_out absent)" "no claude on PATH: nothing on stdout"
h_assert_eq "$(receipt "$tmp/long-6.md" status)" no-claude "no claude on PATH: the receipt says so"
h_assert_eq "$(receipt "$tmp/long-6.md" verdict)" send "no claude on PATH: the verdict is send"
if [ "$(h_run_secs absent)" -lt 10 ]; then h_ok "no claude on PATH: the turn was not held"; else h_fail "no claude on PATH: took $(h_run_secs absent)s"; fi

# 9b. The same, in a cloud session: the reader cannot run there, so the turn is held
# once with the assembled prompt and the instruction to dispatch the reader through
# the Agent tool; the receipt says handed-back; the second pass goes through; a new
# turn is handed back again.
h_calls_reset claude
stop remote s10 p11 "$tmp/long-10.md" -- CLAUDE_CODE_REMOTE=true PATH="$nobin:$rest"
h_assert_hook_run remote "cloud, no claude"
h_assert_eq "$(decision remote)" block "cloud, no claude: the decision is block"
r=$(reason remote)
if has "$r" "Agent tool"; then h_ok "cloud, no claude: the reason says to dispatch the reader through the Agent tool"; else h_fail "cloud, no claude: the reason does not name the Agent tool"; fi
if has "$r" "You are a reader, not an editor"; then h_ok "cloud, no claude: the reason carries the assembled prompt"; else h_fail "cloud, no claude: the reason lacks the prompt"; fi
if has "$r" "The form sends again"; then h_ok "cloud, no claude: the prompt carries the draft"; else h_fail "cloud, no claude: the prompt lacks the draft"; fi
if has "$r" "Start with the answer"; then h_ok "cloud, no claude: the prompt carries the reply contract"; else h_fail "cloud, no claude: the prompt lacks the reply contract"; fi
if has "$r" "RULE-ALPHA"; then h_ok "cloud, no claude: the prompt carries the rules"; else h_fail "cloud, no claude: the prompt lacks the rules"; fi
if has "$r" "corrected reply"; then h_ok "cloud, no claude: the reason asks for the corrected reply"; else h_fail "cloud, no claude: the reason does not ask for the corrected reply"; fi
if has "$r" "$body"; then h_fail "cloud, no claude: the token reached the reason"; else h_ok "cloud, no claude: the token never reached the reason"; fi
h_assert_eq "$(receipt "$tmp/long-10.md" status)" handed-back "cloud, no claude: the receipt says handed-back"
h_assert_eq "$(receipt "$tmp/long-10.md" blocked)" 1 "cloud, no claude: the receipt records the block"
stop remote2 s10 p11 "$tmp/long-11.md" stop_hook_active=true -- CLAUDE_CODE_REMOTE=true PATH="$nobin:$rest"
h_assert_hook_run remote2 "cloud, second pass"
h_assert_empty "$(h_run_out remote2)" "cloud, second pass: nothing on stdout"
stop remote3 s10 p11 "$tmp/long-12.md" -- CLAUDE_CODE_REMOTE=true PATH="$nobin:$rest"
h_assert_hook_run remote3 "cloud, same turn without the flag"
h_assert_empty "$(h_run_out remote3)" "cloud, same turn without the flag: the loop guard lets it through"
h_assert_eq "$(receipt "$tmp/long-12.md" status)" no-claude "cloud, same turn without the flag: the receipt says no-claude, not handed-back"
stop remote4 s10 p12 "$tmp/long-13.md" -- CLAUDE_CODE_REMOTE=true PATH="$nobin:$rest"
h_assert_eq "$(decision remote4)" block "cloud, a new turn: handed back again"

# 10. A slow reader is killed at the bound and the reply goes through.
stop slow s7 p8 "$tmp/long-7.md" -- H_FAKE_CLAUDE_SLEEP=30 H_FAKE_CLAUDE_STDOUT_FILE="$tmp/fix.txt" BBD_READER_BOUND=3
h_assert_hook_run slow "a slow reader"
h_assert_empty "$(h_run_out slow)" "a slow reader: nothing on stdout"
h_assert_eq "$(receipt "$tmp/long-7.md" status)" timeout "a slow reader: the receipt says timeout"
if [ "$(h_run_secs slow)" -lt 15 ]; then h_ok "a slow reader: the turn ended within the bound ($(h_run_secs slow)s)"; else h_fail "a slow reader: took $(h_run_secs slow)s"; fi
if grep -q "stop-gate: timeout" "$logf"; then h_ok "a slow reader: the log says timeout"; else h_fail "a slow reader: the log does not say timeout"; fi

# 11. A reader that fails, and one that answers out of shape: both let the reply through.
stop failing s8 p9 "$tmp/long-8.md" -- H_FAKE_CLAUDE_EXIT=3 H_FAKE_CLAUDE_STDOUT_FILE="$tmp/fix.txt"
h_assert_hook_run failing "a failing reader"
h_assert_empty "$(h_run_out failing)" "a failing reader: nothing on stdout"
h_assert_eq "$(receipt "$tmp/long-8.md" status)" failed "a failing reader: the receipt says failed"
stop garbage s9 p10 "$tmp/long-9.md" -- H_FAKE_CLAUDE_STDOUT_FILE="$tmp/garbage.txt"
h_assert_hook_run garbage "a reader out of shape"
h_assert_empty "$(h_run_out garbage)" "a reader out of shape: nothing on stdout"
h_assert_eq "$(receipt "$tmp/long-9.md" status)" unparseable "a reader out of shape: the receipt says unparseable"

# 12. The token is nowhere: not on any stdout or stderr, not in the state directory.
if grep -r -q -F "$body" "$tmp/run" "$base/state" 2>/dev/null; then
  h_fail "the token reached a run's output or the state directory"
else h_ok "the token is on no stdout, no stderr and nowhere in the state directory"; fi
if find "$base/state" -maxdepth 1 -name 'draft.*' -o -maxdepth 1 -name 'asks.*' -o -maxdepth 1 -name 'verdict.*' | grep -q .; then
  h_fail "a temp file of the step was left in the state directory"
else h_ok "the step leaves no temp file behind"; fi

# 13. The skill: how to give a draft; then the verdict for one; the kind line; the
# prompt handed back when the reader cannot run.
skill() { # NAME [VAR=value ...]
  local name=$1
  shift
  h_launch "$name" "$home" CLAUDE_PROJECT_DIR="$repo" "$@" -- "$boot" skill read-draft </dev/null
}
skill howto
h_assert_eq "$(h_run_code howto)" 0 "skill, no draft: exits 0"
if has "$(h_run_out howto)" "$base/state/draft.md"; then h_ok "skill, no draft: names the file to write"; else h_fail "skill, no draft: does not name the file"; fi
if has "$(h_run_out howto)" "run the same command again"; then h_ok "skill, no draft: says to run again"; else h_fail "skill, no draft: does not say to run again"; fi

cp "$tmp/long-2.md" "$base/state/draft.md"
h_calls_reset claude
skill verdict H_FAKE_CLAUDE_STDOUT_FILE="$tmp/fix.txt" H_FAKE_CLAUDE_RECORD="$tmp/rec-skill"
h_assert_eq "$(h_run_code verdict)" 0 "skill, a draft: exits 0"
if has "$(h_run_out verdict)" "verdict: fix"; then h_ok "skill, a draft: prints the verdict"; else h_fail "skill, a draft: no verdict printed"; fi
if has "$(h_run_out verdict)" "which address"; then h_ok "skill, a draft: prints the findings"; else h_fail "skill, a draft: no findings printed"; fi
if has "$(h_run_out verdict)" "$body"; then h_fail "skill, a draft: the token reached stdout"; else h_ok "skill, a draft: the token never reached stdout"; fi
if [ -e "$base/state/draft.md" ]; then h_fail "skill, a draft: the draft file was left in place"; else h_ok "skill, a draft: the draft file is consumed"; fi
h_assert_eq "$(reads)" 1 "skill, a draft: the reader ran once"
h_assert_eq "$(receipt "$tmp/long-2.md" session)" skill "skill, a draft: the receipt names the skill"

{ printf 'kind: copy\n'; cat "$tmp/long-3.md"; } >"$base/state/draft.md"
skill copy H_FAKE_CLAUDE_STDOUT_FILE="$tmp/send.txt" H_FAKE_CLAUDE_RECORD="$tmp/rec-copy"
if has "$(h_run_out copy)" "verdict: send"; then h_ok "skill, customer copy: prints send"; else h_fail "skill, customer copy: no send verdict"; fi
given=$(cat "$tmp"/rec-copy/stdin.* 2>/dev/null)
if has "$given" "customers will read"; then h_ok "skill, customer copy: the kind reaches the reader"; else h_fail "skill, customer copy: the kind did not reach the reader"; fi
if has "$given" "kind: copy"; then h_fail "skill, customer copy: the kind line was read as part of the draft"; else h_ok "skill, customer copy: the kind line is not part of the draft"; fi

cp "$tmp/long-4.md" "$base/state/draft.md"
skill handback PATH="$nobin:$rest"
h_assert_eq "$(h_run_code handback)" 0 "skill, no claude: exits 0"
if has "$(h_run_out handback)" "could not run here (no-claude)"; then h_ok "skill, no claude: says the reader could not run"; else h_fail "skill, no claude: does not say why"; fi
if has "$(h_run_out handback)" "You are a reader, not an editor"; then h_ok "skill, no claude: hands the prompt back"; else h_fail "skill, no claude: no prompt handed back"; fi
if has "$(h_run_out handback)" "The form sends again"; then h_ok "skill, no claude: the prompt carries the draft"; else h_fail "skill, no claude: the prompt lacks the draft"; fi
if has "$(h_run_out handback)" "$body"; then h_fail "skill, no claude: the token reached stdout"; else h_ok "skill, no claude: the token never reached stdout"; fi

h_done
