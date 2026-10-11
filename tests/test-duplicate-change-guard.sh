#!/usr/bin/env bash
# The duplicate-change guard (lib/dupchange.py, run by the pre-write event;
# docs/launcher-contract.md section 15). Writing the first file of a NEW OpenSpec change
# is refused once when an open change or a document already covers the same ground, and
# the refusal names it. Run through the bootstrap exactly as a session fires it.
#
# Refused once: a new name that says what an open change's name says, or whose own text
# is nearly an open change's proposal, or whose name repeats a document under docs/.
# Not refused: a genuinely different name; a file of a change that already exists; an
# archived change's name; a path outside openspec/changes or outside the repository; the
# same name a second time in the same session (it was told, it insists). Failing open:
# a hook input in an odd shape, an unreadable folder. Nothing is ever written, and the
# repository is untouched.
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

mkdir -p "$repo/openspec/changes/site-redesign" "$repo/openspec/changes/billing-portal" \
  "$repo/openspec/changes/archive/old-thing" "$repo/docs"
cat >"$repo/openspec/changes/site-redesign/proposal.md" <<'EOF'
## Why
The bakery website looks old. Customers cannot find the opening hours, the menu page is slow,
and the ordering form loses messages. We redesign the home page, the menu page, the ordering
form, the photo gallery, the opening hours block and the contact page, with a new footer.
EOF
printf '## Why\nPay invoices online.\n' >"$repo/openspec/changes/billing-portal/proposal.md"
printf '## Why\nDone long ago.\n' >"$repo/openspec/changes/archive/old-thing/proposal.md"
printf '# Onboarding guide\nHow a new customer starts.\n' >"$repo/docs/guide-onboarding.md"
git -C "$repo" add -A
h_git -C "$repo" commit -q -m "chore: changes and docs"
git -C "$repo" push -q origin HEAD 2>/dev/null

snapshot() { git --no-optional-locks -C "$repo" status --porcelain --untracked-files=all; find "$repo" -path "$repo/.git" -prune -o -type f -print | sort; }
before=$(snapshot)

# write NAME SESSION TOOL PATH [CONTENT]: one PreToolUse from the plugin.
write() {
  local name=$1 sid=$2 tool=$3 path=$4 content=${5:-}
  local ti
  ti=$(python3 -c 'import json,sys; d={"file_path": sys.argv[1]};
if sys.argv[2]: d["content"]=sys.argv[2]
print("json:"+json.dumps(d))' "$path" "$content")
  h_hook_json PreToolUse cwd="$repo" session_id="$sid" tool_name="$tool" tool_input="$ti" \
    | h_launch "$name" "$home" -- "$boot" pre-write plugin
}
decision() { printf '%s' "$(h_run_out "$1")" | python3 -c 'import json,sys
raw=sys.stdin.read().strip()
print(json.loads(raw)["hookSpecificOutput"].get("permissionDecision","") if raw else "")' 2>/dev/null; }
reason() { printf '%s' "$(h_run_out "$1")" | python3 -c 'import json,sys
raw=sys.stdin.read().strip()
print(json.loads(raw)["hookSpecificOutput"].get("permissionDecisionReason","") if raw else "")' 2>/dev/null; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
new() { printf '%s/openspec/changes/%s/proposal.md' "$repo" "$1"; }

# 1. A new name that says the same thing as an open change: refused, naming it.
write v2 s1 Write "$(new site-redesign-v2)" "## Why
Something."
h_assert_hook_run v2 "a near-duplicate name"
h_assert_eq "$(decision v2)" deny "a name that repeats an open change is refused"
r=$(reason v2)
if has "$r" "openspec/changes/site-redesign" && has "$r" "site-redesign-v2"; then h_ok "the reason names the open change and the new name"; else h_fail "the reason is wrong: $r"; fi
if has "$r" "billing-portal"; then h_fail "the reason names an unrelated change"; else h_ok "the reason names only the matching change"; fi
if has "$r" "only asks once"; then h_ok "the reason says it asks once"; else h_fail "the reason does not say it asks once"; fi

# 2. The same name again in the same session: let through (it was told).
write v2-again s1 Write "$(new site-redesign-v2)" "## Why
Something."
h_assert_empty "$(h_run_out v2-again)" "the same name a second time in the session is let through"
# Another session is told again.
write v2-other s2 Write "$(new site-redesign-v2)" "## Why
Something."
h_assert_eq "$(decision v2-other)" deny "another session is told too"

# 3. A genuinely different change is let through, and so is a name with only one shared word.
write fresh s3 Write "$(new orchard-map)" "## Why
Map the orchard rows."
h_assert_empty "$(h_run_out fresh)" "an unrelated name is let through"
write one s3 Write "$(new site-analytics)" "## Why
Count visits."
h_assert_empty "$(h_run_out one)" "one shared word is not a duplicate"

# 4. The words of the new text are the words of an open change's proposal, under a name that
# shares nothing with it.
write words s4 Write "$(new bakery-refresh)" "## Why
The bakery website looks old. Customers cannot find the opening hours, the menu page is slow, and the ordering form loses messages. We redesign the home page, the menu page, the ordering form, the photo gallery and the contact page."
h_assert_eq "$(decision words)" deny "a new text that repeats an open proposal is refused"
if has "$(reason words)" "openspec/changes/site-redesign"; then h_ok "and it names that change"; else h_fail "and it does not name that change: $(reason words)"; fi
write other-words s5 Write "$(new orchard-notes)" "## Why
Orchard rows need numbers, pruning dates, spray records and a map of every tree, so that the pickers know where to start each morning."
h_assert_empty "$(h_run_out other-words)" "a new text about something else is let through"

# 5. A document under docs/ that the name repeats.
write doc s6 Write "$(new onboarding-guide)" "## Why
Write it."
h_assert_eq "$(decision doc)" deny "a name that repeats a document is refused"
if has "$(reason doc)" "docs/guide-onboarding.md"; then h_ok "and it names the document"; else h_fail "and it does not name the document"; fi

# 6. An archived change is not open.
write archived s7 Write "$(new old-thing)" "## Why
Again."
h_assert_empty "$(h_run_out archived)" "an archived change's name is let through"

# 7. A file of a change that already exists is never refused, and neither is an edit to one.
write existing s8 Write "$repo/openspec/changes/site-redesign/design.md" "## Design"
h_assert_empty "$(h_run_out existing)" "a file of an existing change is let through"
write edit s8 Edit "$repo/openspec/changes/site-redesign/proposal.md" ""
h_assert_empty "$(h_run_out edit)" "an edit of an existing change is let through"
write multi s8 MultiEdit "$(new site-redesign-v3)" ""
h_assert_eq "$(decision multi)" deny "a MultiEdit that creates a duplicate is refused as well"

# 8. Not a change at all: other paths, a path outside the repository.
write src s9 Write "$repo/src/site-redesign.ts" "x"
h_assert_empty "$(h_run_out src)" "a source file is let through"
write notes s9 Write "$repo/30-projects/site-redesign.md" "x"
h_assert_empty "$(h_run_out notes)" "a vault page is let through"
write outside s9 Write "$H_TMP/elsewhere/openspec/changes/site-redesign-v2/proposal.md" "x"
h_assert_empty "$(h_run_out outside)" "a path outside the repository is let through"

# 9. Failing open: input in an odd shape, an unreadable folder, a session with no id.
printf '{"session_id":"s10","tool_name":"Write","tool_input":"not an object","cwd":"%s"}' "$repo" \
  | h_launch odd "$home" -- "$boot" pre-write plugin
h_assert_hook_run odd "a tool_input that is not an object"
h_assert_empty "$(h_run_out odd)" "a tool_input that is not an object is let through"
printf 'not json at all' | h_launch junk "$home" CLAUDE_PROJECT_DIR="$repo" -- "$boot" pre-write plugin
h_assert_hook_run junk "input that is not JSON"
h_assert_empty "$(h_run_out junk)" "input that is not JSON is let through"
chmod 000 "$repo/openspec/changes"
write unreadable s11 Write "$(new site-redesign-v4)" "x"
chmod 755 "$repo/openspec/changes"
h_assert_hook_run unreadable "an unreadable changes folder"
h_assert_empty "$(h_run_out unreadable)" "an unreadable changes folder is let through"

# 9b. A session with no usable id cannot be told once, so it is never told: let through.
write noid "" Write "$(new site-redesign-v5)" "## Why
Something."
h_assert_hook_run noid "a hook with no session id"
h_assert_empty "$(h_run_out noid)" "no session id: the write is let through, so a refusal cannot repeat"
write badid "../x" Write "$(new site-redesign-v5)" "## Why
Something."
h_assert_empty "$(h_run_out badid)" "a session id that is a path: the write is let through"

# 10. Nothing in the repository changed, and the log says why a refusal happened.
h_assert_eq "$(snapshot)" "$before" "the repository is untouched by every check"
if [ -d "$base/state" ]; then h_ok "the state directory exists once the gate has opened"; else h_fail "no state directory"; fi

h_done
