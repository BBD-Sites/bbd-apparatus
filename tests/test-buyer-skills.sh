#!/usr/bin/env bash
# The buyer's four skills (docs/skills.md): intake, plan, spec-interview and capture.
# Each is a stub in the plugin and in the tenant template (the manifest test checks the
# shape of every stub) and its text in text/skills/NAME.md, printed by the `skill` event.
# Checked here:
#   - the routing table: every stub name has a text, the event prints that text through
#     the bootstrap exactly as a session fires it, and a name with no text prints nothing;
#   - structure: each text names when to use it, its steps and its refusals, says it sends
#     nothing, is plain ASCII (no dash, smart quote or emoji), is under the size cap and
#     grades at or under fifth grade by the Stop gate's own grader;
#   - plan is gated by channel (data/skill-gates.json): open on next, nothing on stable;
#   - capture names the repository's size limit (25 MB unless the README says another)
#     and where a bigger file stays (the buyer's store unless the platform wrote that
#     Drive is connected), and a fault prints the default;
#   - what each skill must say (task 5.8, 6.1, 5.4, 7.24, 5.7, 7.35, 7.38);
#   - a contradiction with the record is said first, with the date: the line is in what
#     every prompt injects (task 7.40).
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

root=$(h_repo_root)
SKILLS="intake plan spec-interview capture"
CAP_BYTES=3500
py="$root/lib/skillinfo.py"

has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
# pos TEXT NEEDLE: the index of NEEDLE in TEXT, or -1.
pos() { python3 -c 'import sys; print(sys.argv[1].find(sys.argv[2]))' "$1" "$2"; }

# --- 1. The routing table and the structure of each text.
for s in $SKILLS; do
  f="$root/text/skills/$s.md"
  if [ -s "$f" ]; then h_ok "$s: the text exists"; else h_fail "$s: text/skills/$s.md is missing"; continue; fi
  stubs="$root/plugin/skills/$s/SKILL.md"
  # a gated skill has no stub in the tenant template (docs/skills.md, the planning gate)
  [ "$s" = plan ] || stubs="$stubs $root/templates/tenant-repo/.claude/skills/$s/SKILL.md"
  for stub in $stubs; do
    if [ -f "$stub" ]; then h_ok "$s: stub ${stub#"$root"/}"; else h_fail "$s: stub ${stub#"$root"/} is missing"; fi
  done
  body=$(cat "$f")
  if { has "$body" "## When to use"; }; then h_ok "$s: names its trigger"; else h_fail "$s: no 'When to use' section"; fi
  if { has "$body" "## Steps"; }; then h_ok "$s: has its steps"; else h_fail "$s: no 'Steps' section"; fi
  if { has "$body" "## Never"; }; then h_ok "$s: has its refusals"; else h_fail "$s: no 'Never' section"; fi
  never=$(awk '/^## Never/ { f = 1; next } f' "$f")
  if { has "$never" "sends nothing to anyone"; }; then h_ok "$s: says it sends nothing"; else h_fail "$s: does not say it sends nothing to anyone"; fi
  if [ "$(printf '%s\n' "$never" | grep -c '^- ')" -ge 2 ]; then h_ok "$s: two refusals or more"; else h_fail "$s: fewer than two refusals"; fi
  bytes=$(wc -c <"$f" | tr -d ' ')
  if [ "$bytes" -le "$CAP_BYTES" ]; then h_ok "$s: $bytes bytes, under $CAP_BYTES"; else h_fail "$s: $bytes bytes, over $CAP_BYTES"; fi
  if python3 -c 'import sys; sys.exit(0 if open(sys.argv[1], "rb").read().isascii() else 1)' "$f"; then
    h_ok "$s: plain ASCII"
  else h_fail "$s: a character outside plain ASCII (dash, smart quote or emoji)"; fi
  graded=$(python3 "$root/lib/readability.py" check "$f")
  h_assert_empty "$graded" "$s: at or under fifth grade by the Stop gate's grader"
done

# The grader and the size check can fail: a planted text is caught.
planted="$H_TMP/planted-skill.md"
printf '%s\n' "The implementation of comprehensive organizational infrastructure necessitates substantial administrative considerations regarding unprecedented circumstances." >"$planted"
if [ -n "$(python3 "$root/lib/readability.py" check "$planted")" ]; then h_ok "self-check: a hard text is caught by the grader"; else h_fail "self-check: a hard text passed the grader"; fi

# --- 2. The event, through the bootstrap.
h_fake_bin git
h_fake_apparatus >/dev/null
boot=$(h_bootstrap)
repo=$(h_fake_repo vault)
h_mark "$repo" tenant-a
home_s=$(h_fake_home hs)
home_n=$(h_fake_home hn)
h_tenant_env "$home_s" tenant-a "BBD_CHANNEL=stable"
h_tenant_env "$home_n" tenant-a "BBD_CHANNEL=next"

skill() { # NAME HOME [VAR=value ...]
  local name=$1 home=$2
  shift 2
  h_launch "$name-$(basename "$home")" "$home" CLAUDE_PROJECT_DIR="$repo" "$@" -- "$boot" skill "$name" </dev/null
}
out_of() { h_run_out "$1-$(basename "$2")"; }

for s in intake spec-interview capture; do
  skill "$s" "$home_s"
  h_assert_eq "$(h_run_code "$s-hs")" 0 "$s: the event exits 0"
  title=$(head -n 1 "$root/text/skills/$s.md")
  h_assert_eq "$(out_of "$s" "$home_s" | head -n 1)" "$title" "$s: the event prints the text"
done
h_assert_eq "$(out_of intake "$home_s")" "$(cat "$root/text/skills/intake.md")" "intake: the printed text is the file, whole"
h_assert_eq "$(out_of spec-interview "$home_s")" "$(cat "$root/text/skills/spec-interview.md")" "spec-interview: the printed text is the file, whole"

# plan: gated by channel.
skill plan "$home_s"
h_assert_empty "$(out_of plan "$home_s")" "plan: nothing is printed on stable"
h_assert_eq "$(h_run_code plan-hs)" 0 "plan: closed, the event still exits 0"
skill plan "$home_n"
h_assert_eq "$(out_of plan "$home_n")" "$(cat "$root/text/skills/plan.md")" "plan: the text is printed on next"

# plan on stable is genuinely absent for a buyer: the tenant template carries no plan stub,
# and the plugin stub cannot be picked by its description on any channel.
if [ ! -e "$root/templates/tenant-repo/.claude/skills/plan" ]; then h_ok "plan: the tenant template has no plan skill"; else h_fail "plan: the tenant template still carries the plan stub"; fi
planstub="$root/plugin/skills/plan/SKILL.md"
planfront=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$planstub")
if printf '%s\n' "$planfront" | grep -q '^disable-model-invocation: true$'; then h_ok "plan: the plugin stub cannot be invoked by the model"; else h_fail "plan: the plugin stub does not set disable-model-invocation: true"; fi
plandesc=$(printf '%s\n' "$planfront" | sed -n 's/^description:[[:space:]]*//p')
if printf '%s' "$plandesc" | grep -q -i -E 'use when|to-do|today|weekly|review|waiting|plans'; then h_fail "plan: the stub description still carries trigger words: $plandesc"; else h_ok "plan: the stub description carries no trigger words"; fi

# a name with no text prints nothing.
skill no-such-skill "$home_n"
h_assert_empty "$(out_of no-such-skill "$home_n")" "an unknown skill name prints nothing"

# --- 3. The gate and the place, directly.
gates="$H_TMP/gates.json"
printf '{"plan": ["next"]}\n' >"$gates"
if { python3 "$py" gate "$gates" plan next; }; then h_ok "gate: plan open on next"; else h_fail "gate: plan closed on next"; fi
if { python3 "$py" gate "$gates" plan stable; }; then h_fail "gate: plan open on stable"; else h_ok "gate: plan closed on stable"; fi
if { python3 "$py" gate "$H_TMP/none.json" plan next; }; then h_fail "gate: plan open with no file"; else h_ok "gate: a missing file closes plan"; fi
printf 'not json' >"$H_TMP/bad.json"
if { python3 "$py" gate "$H_TMP/bad.json" plan next; }; then h_fail "gate: plan open on a broken file"; else h_ok "gate: a broken file closes plan"; fi
printf '{"plan": "next"}\n' >"$H_TMP/shape.json"
if { python3 "$py" gate "$H_TMP/shape.json" plan next; }; then h_fail "gate: plan open on a wrong shape"; else h_ok "gate: a wrong shape closes plan"; fi
if { python3 "$py" gate "$H_TMP/none.json" intake stable; }; then h_ok "gate: another skill is never gated"; else h_fail "gate: intake was closed"; fi
h_assert_eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])))' "$root/data/skill-gates.json")" "{'plan': ['next']}" "the shipped gate opens plan on next alone"

place_in() { # README-TEXT [STORAGE-JSON]: a repo root with that README and storage file; prints the block
  local d
  d=$(mktemp -d "$H_TMP/place.XXXXXX")
  [ -n "$1" ] && printf '%s\n' "$1" >"$d/README.md"
  if [ $# -ge 2 ]; then mkdir -p "$d/.apparatus"; printf '%s\n' "$2" >"$d/.apparatus/storage.json"; fi
  python3 "$py" place "$d"
}
block=$(place_in "")
if { has "$block" "25 MB (26214400 bytes)"; }; then h_ok "place: no README, 25 MB"; else h_fail "place: default limit not 25 MB: $block"; fi
if { has "$block" "the owner's own store"; }; then h_ok "place: no connection, the buyer's own store"; else h_fail "place: not the store: $block"; fi
block=$(place_in "A file up to 10 MB is kept in \`attachments/\`.")
if { has "$block" "10 MB (10485760 bytes)"; }; then h_ok "place: the README's limit is used"; else h_fail "place: README limit ignored: $block"; fi
block=$(place_in 'Nothing about size here.' '{"drive": true}')
if { has "$block" "Google Drive folder"; }; then h_ok "place: Drive connected, Drive"; else h_fail "place: Drive flag ignored: $block"; fi
block=$(place_in "" '{"drive": false}')
if { has "$block" "the owner's own store"; }; then h_ok "place: Drive false, the store"; else h_fail "place: false read as connected: $block"; fi
block=$(place_in "" 'this is not json')
if { has "$block" "the owner's own store"; }; then h_ok "place: a broken storage file, the store"; else h_fail "place: broken file did not fall back: $block"; fi
block=$(place_in "" '{"drive": "yes"}')
if { has "$block" "the owner's own store"; }; then h_ok "place: only true connects Drive"; else h_fail "place: a string read as connected: $block"; fi
if has "$(cat "$py")" "input(" ; then h_fail "place: the helper asks a question"; else h_ok "place: the helper asks nothing"; fi

# capture through the event: the block is appended with this repository's facts.
printf '%s\n' "A file up to 12 MB is kept in \`attachments/\`." >"$repo/README.md"
skill capture "$home_s"
if { has "$(out_of capture "$home_s")" "12 MB (12582912 bytes)"; }; then h_ok "capture: the repository's limit is printed"; else h_fail "capture: limit not printed"; fi
if { has "$(out_of capture "$home_s")" "own store"; }; then h_ok "capture: the place is printed"; else h_fail "capture: place not printed"; fi

# --- 4. What each skill must say.
intake=$(cat "$root/text/skills/intake.md")
plan=$(cat "$root/text/skills/plan.md")
spec=$(cat "$root/text/skills/spec-interview.md")
capture=$(cat "$root/text/skills/capture.md")

# 7.38 intake: every area offered, none required; money offered once and apart from
# bookkeeping; faith asked first and the shelf offered after; storage never asked.
for need in "none is needed" "any can be added later" "family" "health" "money" "faith" "each business"; do
  if { has "$intake" "$need"; }; then h_ok "intake: offers [$need]"; else h_fail "intake: missing [$need]"; fi
done
if { has "$intake" "bookkeeping is a separate thing"; }; then h_ok "intake: money is kept apart from bookkeeping"; else h_fail "intake: bookkeeping not kept apart"; fi
if { has "$intake" "do not ask again"; }; then h_ok "intake: money is asked once"; else h_fail "intake: money may be asked twice"; fi
a=$(pos "$intake" "Ask their faith"); b=$(pos "$intake" "free shelf")
if [ "$a" -ge 0 ] && [ "$b" -gt "$a" ]; then h_ok "intake: faith is asked, then the shelf is offered"; else h_fail "intake: faith/shelf order wrong ($a $b)"; fi
if { has "$intake" "Only then say"; }; then h_ok "intake: the shelf comes only after a faith is named"; else h_fail "intake: the shelf may come before the faith"; fi
if { has "$intake" "keep advice neutral"; }; then h_ok "intake: neutral for a buyer without faith"; else h_fail "intake: no neutral path"; fi
if { has "$intake" "Never ask where recordings, transcripts or files are kept"; }; then h_ok "intake: storage is never asked"; else h_fail "intake: storage not barred"; fi
if { has "$intake" "RULES.md" && has "$intake" "40-areas/" && has "$intake" "30-projects/"; }; then h_ok "intake: writes rules, areas and projects"; else h_fail "intake: does not name where it writes"; fi
if { has "$intake" "Read it all back"; }; then h_ok "intake: reads it back"; else h_fail "intake: no read-back"; fi
if printf '%s' "$intake" | grep -q -i -E 'storage|where to store|drive'; then h_fail "intake: mentions storage or Drive"; else h_ok "intake: no word of storage or Drive"; fi
if { has "$intake" "already exists" || has "$intake" "If RULES.md already exists"; }; then h_ok "intake: a later run adds one area only"; else h_fail "intake: no add-one-area path"; fi

# 6.1 / 7.35 plan: tiers, dates and Big 3 only; the horizons all at once; waiting-on with
# who and since; done with a date; recurring; the brief off.
for need in "day, week, month, year and five years" "Big 3" "tier" "waiting: Name since" "done: date" "every: 30d" "no priority labels" "milestone" "Roll the near ones from the far ones" "ask nothing twice"; do
  if { has "$plan" "$need"; }; then h_ok "plan: says [$need]"; else h_fail "plan: missing [$need]"; fi
done
if { has "$plan" "set to never" && has "$plan" "no push, text or email"; }; then h_ok "plan: the brief is never and nothing is pushed"; else h_fail "plan: the brief default is not stated"; fi
if { has "$plan" "ask once"; }; then h_ok "plan: asks an unknown name once"; else h_fail "plan: no ask-once"; fi

# 5.4 spec interview.
for need in "openspec/changes/" "extend it" "proposal.md" "tasks.md" "Keep it current" "refused because a change already covers it"; do
  if { has "$spec" "$need"; }; then h_ok "spec-interview: says [$need]"; else h_fail "spec-interview: missing [$need]"; fi
done

# 7.24 / 5.7 capture.
for need in "00-inbox/" "attachments/" "extend the open change" "do each one now" "never goes in git" "not built yet" "not fetched" "from memory" "its own parallel agent" "how many were started" "the owner sends it from their own account"; do
  if { has "$capture" "$need"; }; then h_ok "capture: says [$need]"; else h_fail "capture: missing [$need]"; fi
done

# --- 5. 7.40: the contradiction line reaches the model on every prompt.
h_tenant_env "$home_s" tenant-a "BBD_CHANNEL=stable"
h_hook_json UserPromptSubmit cwd="$repo" session_id=s-skill-1 prompt="Please write a job posting." \
  | h_launch contradiction "$home_s" -- "$boot" prompt plugin
ctx=$(h_run_out contradiction | python3 -c 'import json,sys
d=json.load(sys.stdin); print(d.get("hookSpecificOutput",{}).get("additionalContext",""), end="")')
if { has "$ctx" "contradicts something their own record shows"; }; then h_ok "contradiction: injected on a prompt"; else h_fail "contradiction: not injected"; fi
if { has "$ctx" "quote the earlier line with its date"; }; then h_ok "contradiction: quote and date"; else h_fail "contradiction: no quote and date"; fi
if { has "$ctx" "Never soften it or hold it for later"; }; then h_ok "contradiction: never softened or held"; else h_fail "contradiction: may be softened"; fi
a=$(pos "$ctx" "say so first"); b=$(pos "$ctx" "then do what they asked")
if [ "$a" -ge 0 ] && [ "$b" -gt "$a" ]; then h_ok "contradiction: said first, then the ask is done"; else h_fail "contradiction: order wrong"; fi

h_done
