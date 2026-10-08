#!/usr/bin/env bash
# The prompt and compact steps (docs/launcher-contract.md section 11), run through
# the bootstrap exactly as a session would fire them. On every prompt: the reply
# contract and the witness rules, the tenant's rules file, the standing instructions
# and the open asks are injected, in that order, as one hook JSON object; the ask is
# written to the session's ledger; a wrapper, a slash command or an empty prompt is
# not. The injection never passes 6,000 characters, dropping the oldest asks first,
# and a token shape never reaches stdout, the ledger or the log. On SessionStart
# with source compact: the compaction notice, the rules, the standing instructions
# and the open asks are injected and the session's compaction count goes up by one;
# any other source injects nothing here and leaves the count alone.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

h_fake_bin git
h_fake_apparatus >/dev/null
boot=$(h_bootstrap)
home=$(h_fake_home h1)
repo=$(h_fake_repo vault)
h_mark "$repo" tenant-a
h_tenant_env "$home" tenant-a "BBD_CHANNEL=stable"
base="$home/.claude/bbd-apparatus"
ledger="$base/state/ledger"
sid="s-prompt-1"
CAP=6000

# The tenant's rules file and standing instructions, committed as provisioning and a
# later task would leave them.
printf '%s\n' "# Rules" "RULE-ALPHA: reply in plain words." "RULE-BETA: never guess a date." >"$repo/RULES.md"
mkdir -p "$repo/.apparatus"
printf '%s\n' "STANDING-ONE: no bullet points in replies." >"$repo/.apparatus/standing.md"
git -C "$repo" add RULES.md .apparatus/standing.md
h_git -C "$repo" commit -q -m "chore: rules and standing"

# prompt NAME SESSION PROMPT: one UserPromptSubmit turn from the plugin.
prompt() {
  h_hook_json UserPromptSubmit cwd="$repo" session_id="$2" prompt="$3" \
    | h_launch "$1" "$home" -- "$boot" prompt plugin
}
# start NAME SESSION SOURCE: one SessionStart turn from the plugin.
start() {
  h_hook_json SessionStart cwd="$repo" session_id="$2" source="$3" model=test-model \
    | h_launch "$1" "$home" -- "$boot" session-start plugin
}
# ctx NAME: the injected text of a run (empty if the run printed nothing).
ctx() {
  local out
  out=$(h_run_out "$1")
  [ -n "$out" ] || return 0
  printf '%s' "$out" | python3 -c 'import json,sys
d=json.load(sys.stdin); print(d.get("hookSpecificOutput",{}).get("additionalContext",""), end="")'
}
event_name() {
  printf '%s' "$(h_run_out "$1")" | python3 -c 'import json,sys
d=json.load(sys.stdin); print(d.get("hookSpecificOutput",{}).get("hookEventName",""))'
}
chars() { python3 -c 'import sys; print(len(sys.stdin.read()))'; }
# position TEXT NEEDLE: the index of NEEDLE in TEXT, or -1.
position() { python3 -c 'import sys; print(sys.argv[1].find(sys.argv[2]))' "$1" "$2"; }
# items FILE: the numbered item lines of a ledger.
items() { grep -E '^[0-9]+\. ' "$1" 2>/dev/null || true; }

# 1. A plain prompt: one JSON object for UserPromptSubmit, carrying the contract, the
# witness rules, the rules file, the standing instructions and the ask as item 1.
prompt p1 "$sid" "Make the home page load faster."
h_assert_hook_run p1 "a plain prompt"
h_assert_eq "$(event_name p1)" UserPromptSubmit "a plain prompt: the event is UserPromptSubmit"
c=$(ctx p1)
for needle in "Start with the answer" "two separate checks" "three independent witnesses" \
    "RULE-ALPHA" "RULE-BETA" "STANDING-ONE" "1. Make the home page load faster."; do
  case "$c" in *"$needle"*) h_ok "a plain prompt: injects [$needle]" ;; *) h_fail "a plain prompt: missing [$needle]" ;; esac
done
a=$(position "$c" "Start with the answer"); b=$(position "$c" "two separate checks")
r=$(position "$c" "RULE-ALPHA"); s=$(position "$c" "STANDING-ONE"); l=$(position "$c" "1. Make the home page")
if [ "$a" -lt "$b" ] && [ "$b" -lt "$r" ] && [ "$r" -lt "$s" ] && [ "$s" -lt "$l" ]; then
  h_ok "a plain prompt: contract, witness rules, rules file, standing, ledger, in that order"
else h_fail "a plain prompt: the order is wrong ($a $b $r $s $l)"; fi
case "$c" in *"RULES.md"*) h_ok "a plain prompt: the rules section names the file" ;; *) h_fail "a plain prompt: the rules section does not name the file" ;; esac
if [ -f "$ledger/$sid.md" ]; then h_ok "a plain prompt: the ledger file exists"; else h_fail "a plain prompt: no ledger file"; fi
case "$(items "$ledger/$sid.md")" in
  "1. open "*"Z: Make the home page load faster.") h_ok "a plain prompt: item 1 is recorded open, stamped, in the person's words" ;;
  *) h_fail "a plain prompt: the ledger item is not in shape" ;;
esac
case "$(uname)" in
  Darwin) fmode=$(stat -f '%Lp' "$ledger/$sid.md"); dmode=$(stat -f '%Lp' "$ledger") ;;
  *) fmode=$(stat -c '%a' "$ledger/$sid.md"); dmode=$(stat -c '%a' "$ledger") ;;
esac
h_assert_eq "$fmode" 600 "the ledger file is 0600"
h_assert_eq "$dmode" 700 "the ledger directory is 0700"

# 2. The second ask is item 2 and both are injected, each under its own number.
prompt p2 "$sid" "And add the phone number to the footer?"
c=$(ctx p2)
case "$c" in *"1. Make the home page load faster."*"2. And add the phone number to the footer?"*) h_ok "the second prompt: both asks, in order, under stable numbers" ;;
  *) h_fail "the second prompt: the asks are not both injected in order" ;; esac
h_assert_eq "$(items "$ledger/$sid.md" | wc -l | tr -d ' ')" 2 "the second prompt: two items in the ledger"

# 3. A wrapper alone, a slash command and an empty prompt add nothing to the ledger;
# the rules are still injected, because the model still acts on the turn.
prompt wrapper "$sid" "<task-notification>a background task finished</task-notification>"
prompt slash "$sid" "/vault-ask what is due"
prompt empty "$sid" ""
for n in wrapper slash empty; do
  h_assert_hook_run "$n" "a $n prompt"
  h_assert_eq "$(items "$ledger/$sid.md" | wc -l | tr -d ' ')" 2 "a $n prompt: nothing added to the ledger"
  case "$(ctx "$n")" in *"RULE-ALPHA"*) h_ok "a $n prompt: the rules are still injected" ;; *) h_fail "a $n prompt: the rules were not injected" ;; esac
done
prompt beside "$sid" "<system-reminder>the harness talking</system-reminder>Ship it today."
case "$(items "$ledger/$sid.md" | tail -n 1)" in
  "3. open "*"Z: Ship it today.") h_ok "typed text beside a wrapper is recorded without the wrapper" ;;
  *) h_fail "typed text beside a wrapper was not recorded on its own" ;;
esac

# 4. The cap: 6,000 characters at most, the oldest asks dropped first, the newest kept,
# and the count of what is not shown said. The rules and the standing instructions are
# never the first to go.
big=$(printf 'lorem %.0s' $(seq 1 240))
for n in 1 2 3 4 5 6; do prompt "big$n" "$sid" "Ask number $n: $big"; done
c=$(ctx big6)
h_assert_eq "$(printf '%s' "$c" | chars | awk -v cap="$CAP" '{print ($1 <= cap) ? "fits" : "over"}')" fits "the cap: the injection is at most $CAP characters"
case "$c" in *"Ask number 6:"*) h_ok "the cap: the newest ask is kept" ;; *) h_fail "the cap: the newest ask was dropped" ;; esac
case "$c" in *"1. Make the home page"*) h_fail "the cap: the oldest ask was kept over newer ones" ;; *) h_ok "the cap: the oldest ask is dropped first" ;; esac
case "$c" in *"not shown"*) h_ok "the cap: the dropped count is said" ;; *) h_fail "the cap: nothing says asks were dropped" ;; esac
case "$c" in *"RULE-ALPHA"*"STANDING-ONE"*) h_ok "the cap: the rules and standing instructions survive" ;; *) h_fail "the cap: the rules or standing instructions were cut" ;; esac
h_assert_eq "$(items "$ledger/$sid.md" | wc -l | tr -d ' ')" 9 "the cap: the ledger file itself keeps every ask"

# A rules file alone past the cap is cut at the cap, and the cut is said; no ask fits.
huge=$(printf 'RULE-LONG %.0s' $(seq 1 700))
printf '%s\n' "$huge" "RULE-TAIL: the last rule." >"$repo/RULES.md"
prompt huge-rules "$sid" "One more ask."
c=$(ctx huge-rules)
h_assert_hook_run huge-rules "a rules file past the cap"
h_assert_eq "$(printf '%s' "$c" | chars | awk -v cap="$CAP" '{print ($1 <= cap) ? "fits" : "over"}')" fits "a rules file past the cap: still at most $CAP characters"
case "$c" in *"cut at"*) h_ok "a rules file past the cap: the cut is said" ;; *) h_fail "a rules file past the cap: the cut is not said" ;; esac
case "$c" in *"Start with the answer"*) h_ok "a rules file past the cap: the contract is kept" ;; *) h_fail "a rules file past the cap: the contract was cut" ;; esac
case "$c" in *"RULE-TAIL"*) h_fail "a rules file past the cap: the tail survived a cut" ;; *) h_ok "a rules file past the cap: the tail is what goes" ;; esac
printf '%s\n' "# Rules" "RULE-ALPHA: reply in plain words." "RULE-BETA: never guess a date." >"$repo/RULES.md"

# 5. A token shape in the prompt or the rules file reaches neither stdout, the ledger
# nor the log.
body=$(printf 'T%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)
token="bbdt""_$body"
printf '%s\n' "RULE-GAMMA: the token is $token" >>"$repo/RULES.md"
prompt leak "$sid" "Here is my token $token, keep it."
h_assert_hook_run leak "a token in the prompt and the rules"
if grep -rq "$body" "$H_TMP/run/leak.out" "$H_TMP/run/leak.err" "$base/state" 2>/dev/null; then
  h_fail "a token in the prompt and the rules: the token reached stdout, stderr, the ledger or the log"
else h_ok "a token in the prompt and the rules: the token is nowhere on stdout, in the ledger or in the log"; fi
case "$(ctx leak)" in *"[token]"*) h_ok "a token in the prompt and the rules: it is masked in place" ;; *) h_fail "a token in the prompt and the rules: no mask" ;; esac
printf '%s\n' "# Rules" "RULE-ALPHA: reply in plain words." "RULE-BETA: never guess a date." >"$repo/RULES.md"

# 6. No rules file and no standing instructions: the contract and the ledger still
# inject, with no section for what is missing and no error.
rm -f "$repo/RULES.md" "$repo/.apparatus/standing.md"
prompt bare "s-bare" "A bare ask."
h_assert_hook_run bare "no rules and no standing"
c=$(ctx bare)
case "$c" in *"Start with the answer"*"1. A bare ask."*) h_ok "no rules and no standing: the contract and the ask inject" ;; *) h_fail "no rules and no standing: the contract or the ask is missing" ;; esac
case "$c" in *"RULES.md"*|*"Standing instructions"*) h_fail "no rules and no standing: an empty section was injected" ;; *) h_ok "no rules and no standing: no empty section" ;; esac
git -C "$repo" checkout -q -- RULES.md .apparatus/standing.md

# 7. Compaction. A startup injects nothing here and records no count; a compaction
# injects the notice, the rules, the standing instructions and the open asks, under the
# same cap, and the count goes up by one each time.
csid="s-compact"
prompt c1 "$csid" "First ask of the compacting session."
start startup "$csid" startup
h_assert_eq "$(h_run_code startup)" 0 "startup: exits 0"
h_assert_empty "$(h_run_out startup)" "startup: injects nothing from this step"
if [ -e "$base/state/compactions/$csid" ]; then h_fail "startup: a compaction was counted"; else h_ok "startup: no compaction counted"; fi
start compact1 "$csid" compact
h_assert_hook_run compact1 "a compaction"
h_assert_eq "$(event_name compact1)" SessionStart "a compaction: the event is SessionStart"
c=$(ctx compact1)
for needle in "compacted" "memory in the store is unaffected" "RULE-ALPHA" "STANDING-ONE" "1. First ask of the compacting session."; do
  case "$c" in *"$needle"*) h_ok "a compaction: injects [$needle]" ;; *) h_fail "a compaction: missing [$needle]" ;; esac
done
case "$c" in *"Start with the answer"*) h_fail "a compaction: the reply contract was injected here as well" ;; *) h_ok "a compaction: the contract itself is left to the next prompt" ;; esac
h_assert_eq "$(cat "$base/state/compactions/$csid" 2>/dev/null)" 1 "a compaction: the count is 1"
h_assert_eq "$(printf '%s' "$c" | chars | awk -v cap="$CAP" '{print ($1 <= cap) ? "fits" : "over"}')" fits "a compaction: at most $CAP characters"
start compact2 "$csid" compact
h_assert_eq "$(cat "$base/state/compactions/$csid" 2>/dev/null)" 2 "a second compaction: the count is 2"
start resume "$csid" resume
h_assert_eq "$(cat "$base/state/compactions/$csid" 2>/dev/null)" 2 "a resume: the count is unchanged"
h_assert_empty "$(h_run_out resume)" "a resume: injects nothing from this step"
h_assert_eq "$(items "$ledger/$csid.md" | wc -l | tr -d ' ')" 1 "a compaction adds nothing to the ledger"
case "$(uname)" in
  Darwin) cmode=$(stat -f '%Lp' "$base/state/compactions") ;;
  *) cmode=$(stat -c '%a' "$base/state/compactions") ;;
esac
h_assert_eq "$cmode" 700 "the compactions directory is 0700"

# 8. A compaction with no ledger yet still injects the notice and the rules.
start compact-fresh "s-never-asked" compact
h_assert_hook_run compact-fresh "a compaction with no ledger"
case "$(ctx compact-fresh)" in *"compacted"*"RULE-ALPHA"*) h_ok "a compaction with no ledger: the notice and the rules inject" ;; *) h_fail "a compaction with no ledger: the notice or the rules are missing" ;; esac
h_assert_eq "$(cat "$base/state/compactions/s-never-asked" 2>/dev/null)" 1 "a compaction with no ledger: counted"

h_done
