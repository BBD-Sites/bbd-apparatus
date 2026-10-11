#!/usr/bin/env bash
# Two things the apparatus must never do, each proved by a scan that first proves it can fail.
#
# 1. No consent or legal warning anywhere (terms-and-rights, task 7.37). Recordings and the
#    law around them are the buyer's own responsibility, and the terms say so once; the
#    apparatus never warns. No file the apparatus ships (a skill, a stub, a launcher script,
#    a library, a doc, the template) holds a string that warns about consent, recording law
#    or legality, so no refusal path can exist either.
#
# 2. Nothing is pushed to the buyer by default (buyer-dashboard, task 7.39). The brief
#    defaults to never. No code the apparatus ships sends mail, a text or a push, and the
#    plugin's hooks and the template's settings register no Notification hook. The plan
#    skill says the brief is off.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

root=$(h_repo_root)

# The files the apparatus ships: everything tracked or new, apart from the tests, which
# carry the patterns themselves.
shipped() {
  git -C "$root" ls-files --cached --others --exclude-standard 2>/dev/null | grep -v '^tests/' | sed "s#^#$root/#"
}
WARN_RE='consent|wiretap|two-party|one-party|all[- ]part(y|ies)|illegal|unlawful|\blegal(ly)?\b|\blawful(ly)?\b|recording laws?|permission to record|inform (the|all) (other|parties)|tell (the|them) (other|caller)'
CHANNEL_RE='smtplib|sendmail|mailx|osascript|terminal-notifier|notify-send|twilio|pushover|ntfy|apns|\bsmtp|\bsms\b|imessage|webhook|"Notification"|Notification\)'

scan() { # REGEX FILE...: file:line for each match, folded case
  grep -n -i -E -e "$1" "${@:2}" 2>/dev/null | sed "s#$root/##" | cut -c1-160
}

# --- 1. Warnings.
planted="$H_TMP/planted.md"
printf '%s\n' "Before you record a call, get the other person's consent." "Recording laws differ by state." >"$planted"
h_assert_eq "$(scan "$WARN_RE" "$planted" | wc -l | tr -d ' ')" 2 "self-check: a consent warning and a recording-law warning are caught"
files=()
while IFS= read -r f; do [ -f "$f" ] && files+=("$f"); done <<EOF
$(shipped)
EOF
h_assert_nonempty "${files[*]:-}" "the scan has files to read"
h_assert_empty "$(scan "$WARN_RE" "${files[@]}")" "no consent or legal warning in any shipped file (${#files[@]} files)"

# --- 2. Nothing pushed.
printf '%s\n' "import smtplib" "osascript -e 'display notification'" >"$planted"
h_assert_eq "$(scan "$CHANNEL_RE" "$planted" | wc -l | tr -d ' ')" 2 "self-check: a mail and a notification path are caught"
code=()
while IFS= read -r f; do
  case "$f" in
    "$root"/launcher/*|"$root"/lib/*|"$root"/bin/*|"$root"/install/*|"$root"/plugin/*|"$root"/templates/*|"$root"/reader/*|"$root"/text/*)
      [ -f "$f" ] && code+=("$f") ;;
  esac
done <<EOF
$(shipped)
EOF
h_assert_empty "$(scan "$CHANNEL_RE" "${code[@]}")" "no mail, text or push path in the launcher, libraries, plugin or template (${#code[@]} files)"

# No Notification hook is registered by the plugin or the template, and no hook runs a
# command that is not the bootstrap, so no second path to the buyer exists.
for f in "$root/plugin/hooks/hooks.json" "$root/templates/tenant-repo/.claude/settings.json"; do
  events=$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["hooks"])))' "$f" 2>/dev/null)
  h_assert_eq "$events" "PreToolUse SessionStart Stop UserPromptSubmit" "${f#"$root"/}: the hook events are the four, none a notification"
done

# The plan skill says the brief is off, and every skill says it sends nothing.
plan=$(cat "$root/text/skills/plan.md")
case "$plan" in *"set to never"*"no push, text or email"*) h_ok "the plan skill says the brief is never and nothing is pushed" ;; *) h_fail "the plan skill does not state the brief default" ;; esac

h_done
