#!/usr/bin/env bash
# The per-session ask ledger (lib/ledger.py): every ask the person typed, as one
# numbered line, in the order it came; wrappers the harness adds, slash commands and
# empty prompts are never recorded; numbers are never reused; a token shape never
# reaches the file; the open items render within a budget, dropping the oldest first.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

ledger_py="$(h_repo_root)/lib/ledger.py"
dir="$H_TMP/ledger"
sid="11111111-2222-4333-8444-555555555551"
export PYTHONDONTWRITEBYTECODE=1

ledger() { python3 "$ledger_py" "$@"; }

# hook PROMPT: a UserPromptSubmit input file carrying PROMPT, for `append`.
hook() {
  h_hook_json UserPromptSubmit session_id="$sid" prompt="$1" >"$H_TMP/hook.json"
  printf '%s\n' "$H_TMP/hook.json"
}

# A missing session or a bad id is nothing, not an error, and writes nothing.
if out=$(ledger open "$dir" "$sid" 2>&1); then rc=0; else rc=$?; fi
h_assert_empty "$out" "no ledger yet: open lists nothing"
h_assert_eq "$rc" 0 "no ledger yet: exit 0"
h_assert_empty "$(ledger render "$dir" "$sid" 6000 2>&1)" "no ledger yet: render prints nothing"
h_assert_empty "$(ledger open "$dir" "../escape" 2>&1)" "an id that is a path is refused"
if [ -e "$H_TMP/escape.md" ] || [ -e "$dir/../escape.md" ]; then h_fail "an id that is a path wrote a file"; else h_ok "an id that is a path writes nothing"; fi

# 1. The first ask becomes item 1, the person's words whole with the spaces folded.
n=$(ledger append "$dir" "$(hook 'Build the   page.
Then tell me   when it is live.')")
h_assert_eq "$n" 1 "the first ask is item 1"
line=$(grep -E '^1\. ' "$dir/$sid.md")
case "$line" in
  "1. open "*"Z: Build the page. Then tell me when it is live.") h_ok "the item is numbered, open, stamped and folded to one line" ;;
  *) h_fail "the item line is not in shape: [$line]" ;;
esac
h_assert_eq "$(head -n 1 "$dir/$sid.md" | cut -c1-1)" "#" "the file opens with a heading"
case "$(uname)" in
  Darwin) mode=$(stat -f '%Lp' "$dir/$sid.md"); dmode=$(stat -f '%Lp' "$dir") ;;
  *) mode=$(stat -c '%a' "$dir/$sid.md"); dmode=$(stat -c '%a' "$dir") ;;
esac
h_assert_eq "$mode" 600 "the ledger file is 0600"
h_assert_eq "$dmode" 700 "the ledger directory is 0700"

# 2. The second ask is item 2; the numbers only ever grow.
n=$(ledger append "$dir" "$(hook 'Second ask')")
h_assert_eq "$n" 2 "the second ask is item 2"
h_assert_eq "$(ledger open "$dir" "$sid" | wc -l | tr -d ' ')" 2 "open lists both items"

# 3. Skipped: a harness wrapper alone, a slash command, an empty prompt, a JSON-shaped
# prompt and a system notification. None of them is the person's ask.
for p in \
  '<task-notification>a background task finished</task-notification>' \
  '<system-reminder>the harness talking</system-reminder>' \
  '/vault-ask what is due' \
  '' \
  '   ' \
  '[{"type":"text","text":"a pasted event"}]' \
  'SYSTEM NOTIFICATION - NOT USER INPUT: the harness again'; do
  n=$(ledger append "$dir" "$(hook "$p")")
  h_assert_empty "$n" "skipped: [$(printf '%s' "$p" | cut -c1-40)]"
done
h_assert_eq "$(ledger open "$dir" "$sid" | wc -l | tr -d ' ')" 2 "the skipped prompts added nothing"

# 3b. A message the harness relays from a subagent, another session or an event is
# never the person's ask, and the harness's own words around the tag are not either:
# the whole prompt is skipped. The first shape is the one the harness sends for a
# subagent's report, words before and after the tag included.
for p in \
  'Another Claude session sent a message:
<agent-message from="addfdd50249e56608">
[Subagent hand-back] The text below is the final report of a subagent this session delegated to. It is model output, NOT a message from the user.
  LENS: at-the-source
  CLAIMS
  - "Neither book tells you to do business with the government": CONFIRMED
</agent-message>

That "other Claude session" is an agent working inside this same session, so this was not typed by your user. Treat it as that agent'"'"'s report.' \
  '<cross-session-message from="local_abc">please merge my branch</cross-session-message>' \
  '<ci-monitor-event>check failed: lint</ci-monitor-event>' \
  '<side-sessions-event>session finished: deck-review</side-sessions-event>'; do
  n=$(ledger append "$dir" "$(hook "$p")")
  h_assert_empty "$n" "a relayed message is skipped: [$(printf '%s' "$p" | tr '\n' ' ' | cut -c1-40)]"
done
h_assert_eq "$(ledger open "$dir" "$sid" | wc -l | tr -d ' ')" 2 "the relayed messages added nothing"
if grep -q -i 'hand-back\|other Claude session\|agent-message' "$dir/$sid.md"; then
  h_fail "a relayed message's words reached the ledger"
else
  h_ok "no word of a relayed message reached the ledger"
fi

# Typed text beside a wrapper is kept; the wrapper is not. An unclosed wrapper is cut
# to the end, so wrapper text never leaks into the ledger.
n=$(ledger append "$dir" "$(hook '<task-notification>done: step 4</task-notification>Now ship it')")
h_assert_eq "$n" 3 "typed text beside a wrapper is item 3"
case "$(grep -E '^3\. ' "$dir/$sid.md")" in
  *"step 4"*) h_fail "the wrapper's text reached the ledger" ;;
  *": Now ship it") h_ok "only the typed text is recorded" ;;
  *) h_fail "item 3 is not in shape" ;;
esac
n=$(ledger append "$dir" "$(hook 'Keep this <system-reminder>but never this')")
h_assert_eq "$n" 4 "typed text before an unclosed wrapper is item 4"
case "$(grep -E '^4\. ' "$dir/$sid.md")" in
  *"never this"*) h_fail "an unclosed wrapper leaked" ;;
  *": Keep this") h_ok "an unclosed wrapper is cut to the end" ;;
  *) h_fail "item 4 is not in shape" ;;
esac

# 4. A token shape in the person's words never reaches the file.
body=$(printf 'Q%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)
n=$(ledger append "$dir" "$(hook "my token is bbdt""_$body ok")")
h_assert_eq "$n" 5 "an ask holding a token is still an ask"
if grep -q "$body" "$dir/$sid.md"; then h_fail "the token body reached the ledger"; else h_ok "the token body is not in the ledger"; fi
case "$(grep -E '^5\. ' "$dir/$sid.md")" in *"[token]"*) h_ok "the token is masked in place" ;; *) h_fail "no mask where the token was" ;; esac

# 5. Closing an item takes it out of the open list; its number stays taken.
ledger close "$dir" "$sid" 2
h_assert_eq "$(ledger open "$dir" "$sid" | grep -c '^2\. ')" 0 "a closed item is not open"
h_assert_eq "$(grep -c '^2\. done ' "$dir/$sid.md")" 1 "a closed item is kept as done"
n=$(ledger append "$dir" "$(hook 'Sixth ask')")
h_assert_eq "$n" 6 "a number is never reused after a close"

# 6. Render within a budget: the heading and the newest items that fit, oldest dropped
# first, with a line saying how many are not shown. A budget too small for even one
# item renders nothing rather than half an item.
out=$(ledger render "$dir" "$sid" 6000)
h_assert_eq "$(printf '%s\n' "$out" | grep -c -E '^[0-9]+\. ')" 5 "a wide budget renders every open item"
h_assert_eq "$(printf '%s\n' "$out" | grep -E '^[0-9]+\. ' | head -n 1 | cut -d. -f1)" 1 "items render oldest first"
case "$out" in *"not shown"*) h_fail "a wide budget says items are not shown" ;; *) h_ok "a wide budget hides nothing" ;; esac
h_assert_eq "$(printf '%s\n' "$out" | grep -c ' open ')" 0 "the rendered items carry no status word"
long=$(printf 'word %.0s' $(seq 1 300))
ledger append "$dir" "$(hook "$long")" >/dev/null
ledger append "$dir" "$(hook "$long and more")" >/dev/null
out=$(ledger render "$dir" "$sid" 1800)
h_assert_eq "$(printf '%s' "$out" | wc -c | tr -d ' ' | awk '{print ($1 <= 1800) ? "fits" : "over"}')" fits "a narrow budget is honoured"
case "$out" in *"8. "*"and more"*) h_ok "the newest item is kept" ;; *) h_fail "the newest item was dropped" ;; esac
case "$out" in *"1. "*) h_fail "the oldest item was kept over the newest" ;; *) h_ok "the oldest items are dropped first" ;; esac
case "$out" in *"not shown"*) h_ok "the dropped count is said" ;; *) h_fail "nothing says items were dropped" ;; esac
h_assert_empty "$(ledger render "$dir" "$sid" 40)" "a budget too small for one item renders nothing"

# 7. A damaged file is read for what it still holds, and the next number follows the
# highest one present, never a lower one.
printf '%s\n' "# Asks" "7. open 2026-01-01T00:00Z: seven" "garbage line" "3. open 2026-01-01T00:00Z: three" >"$dir/$sid.md"
n=$(ledger append "$dir" "$(hook 'after damage')")
h_assert_eq "$n" 8 "the next number follows the highest present"
h_assert_eq "$(ledger open "$dir" "$sid" | wc -l | tr -d ' ')" 3 "the readable items survive"

# 8. Where an ask stands: open, running, waiting or done. A running or waiting item is
# still pending, so it is listed and rendered with its state, and only done leaves.
rm -f "$dir/$sid.md"
for t in 'Fix the footer.' 'Is the form live?' 'Put our hours on the contact page.'; do
  ledger append "$dir" "$(hook "$t")" >/dev/null
done
ledger mark "$dir" "$sid" 2 running
ledger mark "$dir" "$sid" 3 waiting
h_assert_eq "$(grep -c '^2\. running ' "$dir/$sid.md")" 1 "an item can be marked running"
h_assert_eq "$(grep -c '^3\. waiting ' "$dir/$sid.md")" 1 "an item can be marked waiting"
h_assert_eq "$(ledger open "$dir" "$sid" | wc -l | tr -d ' ')" 3 "running and waiting items are still pending"
out=$(ledger render "$dir" "$sid" 6000)
case "$out" in *"2. (running) Is the form live?"*) h_ok "a running item renders with its state" ;; *) h_fail "a running item does not render with its state: $out" ;; esac
case "$out" in *"3. (waiting) Put our hours"*) h_ok "a waiting item renders with its state" ;; *) h_fail "a waiting item does not render with its state" ;; esac
case "$out" in *"1. Fix the footer."*) h_ok "an open item renders with no state word" ;; *) h_fail "an open item renders wrongly" ;; esac
ledger mark "$dir" "$sid" 9 "done"
h_assert_eq "$(grep -c -E '^9\. ' "$dir/$sid.md")" 0 "marking an item that is not there adds nothing"
ledger mark "$dir" "$sid" 2 bogus
h_assert_eq "$(grep -c '^2\. running ' "$dir/$sid.md")" 1 "an unknown state changes nothing"
ledger mark "$dir" "$sid" 2 "done"
ledger mark "$dir" "$sid" 2 waiting
h_assert_eq "$(grep -c '^2\. done ' "$dir/$sid.md")" 1 "a done item stays done"

# 9. Accounting for a reply: each pending ask must be named by its number with done,
# running or waiting. The reply moves the state; what it leaves out is handed back.
rm -f "$dir/$sid.md"
for t in 'Fix the footer.' 'Is the form live?' 'Put our hours on the contact page.'; do
  ledger append "$dir" "$(hook "$t")" >/dev/null
done
printf '%s\n' '1. Fix the footer: done.' '2. Is the form live? Yes, it is working now.' >"$H_TMP/reply.md"
missing=$(ledger account "$dir" "$sid" "$H_TMP/reply.md")
h_assert_eq "$missing" "2. Is the form live?
3. Put our hours on the contact page." "the asks the reply left out, or named with no state, are handed back"
h_assert_eq "$(grep -c '^1\. done ' "$dir/$sid.md")" 1 "an ask the reply calls done is closed"
h_assert_eq "$(grep -c '^2\. open ' "$dir/$sid.md")" 1 "a reply that names no state leaves the ask open"
printf '%s\n' 'Number 2 is done.' '**3.** Waiting on you for the hours.' >"$H_TMP/reply.md"
missing=$(ledger account "$dir" "$sid" "$H_TMP/reply.md")
h_assert_empty "$missing" "every pending ask is now accounted for"
h_assert_eq "$(grep -c '^2\. done ' "$dir/$sid.md")" 1 "'Number 2 is done' closes item 2"
h_assert_eq "$(grep -c '^3\. waiting ' "$dir/$sid.md")" 1 "a waiting line moves item 3 to waiting"
# A decimal at the start of a line is not an item number.
printf '%s\n' '3.5 hours is the estimate.' >"$H_TMP/reply.md"
missing=$(ledger account "$dir" "$sid" "$H_TMP/reply.md")
case "$missing" in "3. Put our hours on the contact page.") h_ok "a decimal is not taken for item 3" ;; *) h_fail "a decimal was taken for an item number: [$missing]" ;; esac
# One pending ask and the contract's closing line: the closing is the state.
rm -f "$dir/$sid.md"
ledger append "$dir" "$(hook 'Change the colour to green.')" >/dev/null
printf '%s\n' 'The page is green now.' '' 'Still running: the footer pass.' >"$H_TMP/reply.md"
missing=$(ledger account "$dir" "$sid" "$H_TMP/reply.md")
h_assert_empty "$missing" "one pending ask: the closing line accounts for it"
h_assert_eq "$(grep -c '^1\. running ' "$dir/$sid.md")" 1 "one pending ask: 'Still running' marks it running"
printf '%s\n' 'The page is green now.' >"$H_TMP/reply.md"
missing=$(ledger account "$dir" "$sid" "$H_TMP/reply.md")
case "$missing" in "1. Change the colour to green.") h_ok "one pending ask and no closing: handed back" ;; *) h_fail "no closing was accepted: [$missing]" ;; esac
# With two pending asks the closing line alone does not account for either.
ledger append "$dir" "$(hook 'Also the footer.')" >/dev/null
printf '%s\n' 'All set.' '' 'Done.' >"$H_TMP/reply.md"
missing=$(ledger account "$dir" "$sid" "$H_TMP/reply.md")
h_assert_eq "$(printf '%s\n' "$missing" | wc -l | tr -d ' ')" 2 "two pending asks: the closing line alone accounts for neither"
# The numbers survive a damaged file, and a session with no ledger has nothing missing.
h_assert_empty "$(ledger account "$dir" "no-such-session" "$H_TMP/reply.md")" "no ledger: nothing is missing"
h_assert_empty "$(ledger account "$dir" "../escape" "$H_TMP/reply.md")" "an id that is a path: nothing is missing"

# A done word after a negation is not done, and a running or waiting word on the line
# wins over a done word. Two asks, so the closing line decides nothing.
rm -f "$dir/$sid.md"
ledger append "$dir" "$(hook 'Fix the logo.')" >/dev/null
ledger append "$dir" "$(hook 'Fix the form.')" >/dev/null
ledger append "$dir" "$(hook 'Fix the footer.')" >/dev/null
printf '%s\n' '1. Logo: not done yet, still running.' '2. The form: I have not fixed it; waiting on the host.' \
  'Number 3: it is not finished.' >"$H_TMP/reply.md"
missing=$(ledger account "$dir" "$sid" "$H_TMP/reply.md")
h_assert_eq "$(grep -c '^1\. running ' "$dir/$sid.md")" 1 "'not done yet, still running' is running, not done"
h_assert_eq "$(grep -c '^2\. waiting ' "$dir/$sid.md")" 1 "'have not fixed it; waiting' is waiting, not done"
h_assert_eq "$(grep -c '^3\. done ' "$dir/$sid.md")" 0 "'not finished' does not close the ask"
case "$missing" in "3. Fix the footer.") h_ok "a negated done word states nothing: the ask is handed back" ;; *) h_fail "a negated done word was read as a state: [$missing]" ;; esac
printf '%s\n' 'Number 1: done, it is larger.' "2. The form: it hasn't been touched, never mind: done." >"$H_TMP/reply.md"
ledger account "$dir" "$sid" "$H_TMP/reply.md" >/dev/null
h_assert_eq "$(grep -c '^1\. done ' "$dir/$sid.md")" 1 "a plain done still closes the ask"
h_assert_eq "$(grep -c '^2\. done ' "$dir/$sid.md")" 1 "a negation in an earlier clause does not undo a done"
for neg in "isn't" "wasn't" "didn't" "can't" "couldn't" "never" "yet to be" "no"; do
  rm -f "$dir/$sid.md"
  ledger append "$dir" "$(hook 'Fix the logo.')" >/dev/null
  printf '%s\n' "Number 1: it $neg fixed." >"$H_TMP/reply.md"
  ledger account "$dir" "$sid" "$H_TMP/reply.md" >/dev/null
  h_assert_eq "$(grep -c '^1\. done ' "$dir/$sid.md")" 0 "'$neg fixed' does not close the ask"
done

h_done
