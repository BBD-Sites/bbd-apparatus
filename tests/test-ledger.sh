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

h_done
