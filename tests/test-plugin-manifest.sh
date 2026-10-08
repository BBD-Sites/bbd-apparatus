#!/usr/bin/env bash
# The marketplace, the shell plugin and the tenant repository template agree with each
# other, with the Claude Code docs (read 2026-10-07) and with the dispatcher:
#   - both manifests parse and carry the documented field names, the neutral owner and
#     no version in the marketplace entry (plugin.json pins it alone);
#   - every hook entry runs the bootstrap with an event the dispatcher routes, and every
#     event the dispatcher routes has an entry (compact is not one: session-start runs it
#     on source=compact), so neither can drift from the other;
#   - the timeouts are the contract's (docs/launcher-contract.md section 7), the ship
#     entry is the only asynchronous one, and the pre-write matcher is the fixed list;
#   - the plugin and the template point at the two bootstrap copies that exist;
#   - the template's settings register the marketplace with auto-update on and run the
#     same events through the committed copy with the repo delivery;
#   - the skill stubs route to the launcher's `skill read-draft` event;
#   - the template marker fails the gate until provisioning fills the tenant;
#   - `claude plugin validate --strict` passes on both, with no login (skipped with a
#     reason where no `claude` is on PATH; CI fails instead, so the step cannot vanish).
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

root=$(h_repo_root)
MARKET="$root/.claude-plugin/marketplace.json"
PLUGIN_DIR="$root/plugin"
MANIFEST="$PLUGIN_DIR/.claude-plugin/plugin.json"
HOOKS="$PLUGIN_DIR/hooks/hooks.json"
TEMPLATE="$root/templates/tenant-repo"
SETTINGS="$TEMPLATE/.claude/settings.json"
MARKER="$TEMPLATE/.apparatus/vault.json"
NEUTRAL="apparatus maintainers"
# The literal command text the hook entries carry; the harness substitutes the variables, not this shell.
# shellcheck disable=SC2016
PLUGIN_BOOT='bash "${CLAUDE_PLUGIN_ROOT}/launcher/bbd-launch.sh"'
# shellcheck disable=SC2016
REPO_BOOT='bash "$CLAUDE_PROJECT_DIR/.claude/hooks/bbd-launch.sh"'

# jget FILE EXPR: a value from a JSON file, by a python expression over `d`; nothing
# if the file is missing, does not parse, or the expression fails.
jget() {
  python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
    v = eval(sys.argv[2])
except Exception:
    sys.exit(0)
if isinstance(v, bool):
    print("true" if v else "false")
elif v is None:
    print("null")
elif isinstance(v, (dict, list)):
    print(json.dumps(v, sort_keys=True))
else:
    print(v)
' "$1" "$2" 2>/dev/null
}

parses() { python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null; }

for f in "$MARKET" "$MANIFEST" "$HOOKS" "$SETTINGS" "$MARKER"; do
  if [ -f "$f" ] && parses "$f"; then h_ok "parses: ${f#"$root"/}"; else h_fail "missing or not JSON: ${f#"$root"/}"; fi
done

# --- marketplace.json (docs: name, owner.name and plugins[] required; each entry
# needs name and source; a relative source starts with ./ from the marketplace root;
# version belongs in plugin.json alone).
h_assert_eq "$(jget "$MARKET" 'd["name"]')" bbd-apparatus "marketplace: name"
h_assert_eq "$(jget "$MARKET" 'd["owner"]["name"]')" "$NEUTRAL" "marketplace: owner.name is the neutral label"
h_assert_eq "$(jget "$MARKET" 'sorted(d["owner"].keys())')" '["name"]' "marketplace: the owner carries no email or url"
h_assert_nonempty "$(jget "$MARKET" 'd["description"]')" "marketplace: description present"
h_assert_eq "$(jget "$MARKET" 'len(d["plugins"])')" 1 "marketplace: one plugin entry"
h_assert_eq "$(jget "$MARKET" 'd["plugins"][0]["name"]')" bbd "marketplace: entry name is bbd"
h_assert_eq "$(jget "$MARKET" 'd["plugins"][0]["source"]')" ./plugin "marketplace: entry source is ./plugin"
h_assert_nonempty "$(jget "$MARKET" 'd["plugins"][0]["description"]')" "marketplace: entry description present"
h_assert_eq "$(jget "$MARKET" '"version" in d["plugins"][0]')" false "marketplace: the entry sets no version (plugin.json pins it)"
h_assert_eq "$(jget "$MARKET" 'd["plugins"][0]["source"].startswith("./") and ".." not in d["plugins"][0]["source"]')" true "marketplace: source is a relative path inside the repository"
if [ -d "$root/plugin" ]; then h_ok "marketplace: ./plugin exists"; else h_fail "marketplace: ./plugin does not exist"; fi

# --- plugin.json (docs: name required, kebab-case, not a reserved prefix; version
# pins; author.name required when author is set).
h_assert_eq "$(jget "$MANIFEST" 'd["name"]')" bbd "plugin: name equals the marketplace entry name"
h_assert_nonempty "$(jget "$MANIFEST" 'd["version"]')" "plugin: version is pinned"
h_assert_nonempty "$(jget "$MANIFEST" 'd["description"]')" "plugin: description present"
h_assert_eq "$(jget "$MANIFEST" 'd["author"]["name"]')" "$NEUTRAL" "plugin: author.name is the neutral label"
h_assert_eq "$(jget "$MANIFEST" 'sorted(d["author"].keys())')" '["name"]' "plugin: the author carries no email or url"
case "$(jget "$MANIFEST" 'd["name"]')" in
  claude|anthropic|anthropics|claude-code|claude-mods|claude-*|anthropic-*|anthropics-*|cc-plugin-*) h_fail "plugin: name is reserved" ;;
  *) h_ok "plugin: name is not reserved" ;;
esac
for f in "$MARKET" "$MANIFEST" "$HOOKS" "$SETTINGS"; do
  [ -f "$f" ] || continue
  if grep -q '@' "$f"; then h_fail "no address: ${f#"$root"/} contains an @"; else h_ok "no address: ${f#"$root"/}"; fi
done

# --- hooks.json. hook_lines FILE: one line per command hook:
#   EVENT MATCHER TIMEOUT ASYNC COMMAND
# Fields that are unset print as "-". Nothing if the file does not parse.
hook_lines() {
  python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
    hooks = d["hooks"]
except Exception:
    sys.exit(0)
for event, groups in hooks.items():
    for g in groups:
        m = g.get("matcher", "-") or "-"
        for h in g.get("hooks", []):
            if h.get("type") != "command":
                print("%s %s - - NOT-A-COMMAND-HOOK" % (event, m))
                continue
            t = h.get("timeout", "-")
            a = "async" if h.get("async") is True else "-"
            print("%s %s %s %s %s" % (event, m, t, a, h.get("command", "")))
' "$1" 2>/dev/null
}

# routed_events: the events on the dispatcher's case line, one per line.
routed_events() {
  grep -E '^[[:space:]]*[a-z|-]+\) ;;$' "$root/launcher/dispatch.sh" | head -1 \
    | sed 's/) ;;$//; s/^[[:space:]]*//' | tr '|' '\n'
}

# audit_hooks FILE BOOT DELIVERY: one line per defect; nothing means the file's entries
# all run BOOT with an event the dispatcher routes and the DELIVERY given, every
# routed event but skill has an entry, and the timeouts and flags are the contract's.
audit_hooks() {
  local file=$1 boot=$2 delivery=$3 line event matcher timeout async cmd rest ev
  local seen=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    event=${line%% *}; rest=${line#* }
    matcher=${rest%% *}; rest=${rest#* }
    timeout=${rest%% *}; rest=${rest#* }
    async=${rest%% *}; cmd=${rest#* }
    case "$cmd" in
      "$boot "*) ;;
      *) echo "$event: command does not run the bootstrap: $cmd"; continue ;;
    esac
    rest=${cmd#"$boot" }
    ev=${rest%% *}
    rest=${rest#"$ev"}
    rest=${rest# }
    if [ "$rest" != "$delivery" ]; then echo "$event: delivery is [$rest], wanted [$delivery]"; fi
    if [ ! -f "$root/launcher/events/$ev.sh" ]; then echo "$event: event [$ev] has no launcher/events/$ev.sh"; fi
    if ! routed_events | grep -q -x -F -e "$ev"; then
      echo "$event: event [$ev] is not routed by launcher/dispatch.sh"
    fi
    seen="$seen $ev"
    case "$ev" in
      session-start) [ "$event" = SessionStart ] && [ "$matcher" = - ] && [ "$timeout" = 20 ] && [ "$async" = - ] \
        || echo "$event: session-start wants no matcher, timeout 20, synchronous; got matcher [$matcher] timeout [$timeout] $async" ;;
      prompt) [ "$event" = UserPromptSubmit ] && [ "$matcher" = - ] && [ "$timeout" = 10 ] && [ "$async" = - ] \
        || echo "$event: prompt wants no matcher, timeout 10, synchronous; got matcher [$matcher] timeout [$timeout] $async" ;;
      pre-write) [ "$event" = PreToolUse ] && [ "$matcher" = "Write|Edit|MultiEdit|NotebookEdit" ] && [ "$timeout" = 5 ] && [ "$async" = - ] \
        || echo "$event: pre-write wants matcher Write|Edit|MultiEdit|NotebookEdit, timeout 5, synchronous; got matcher [$matcher] timeout [$timeout] $async" ;;
      stop-gate) [ "$event" = Stop ] && [ "$matcher" = - ] && [ "$timeout" = 90 ] && [ "$async" = - ] \
        || echo "$event: stop-gate wants timeout 90, synchronous; got matcher [$matcher] timeout [$timeout] $async" ;;
      stop-ship)
        if [ "$delivery" = plugin ]; then
          [ "$event" = Stop ] && [ "$matcher" = - ] && [ "$async" = async ] && [ "$timeout" = - ] \
            || echo "$event: the plugin's stop-ship wants async and no timeout; got matcher [$matcher] timeout [$timeout] $async"
        else
          [ "$event" = Stop ] && [ "$matcher" = - ] && [ "$async" = - ] && [ "$timeout" = 60 ] \
            || echo "$event: the repository's stop-ship wants timeout 60, synchronous; got matcher [$matcher] timeout [$timeout] $async"
        fi ;;
      skill) echo "$event: skill is not a hook event" ;;
      *) echo "$event: unknown event [$ev]" ;;
    esac
  done <<LINES
$(hook_lines "$file")
LINES
  # Every event the dispatcher routes, apart from skill, has an entry. A script under
  # launcher/events that the dispatcher does not route (compact.sh, run by session-start
  # on source=compact) is not a hook event and needs none.
  for ev in $(routed_events); do
    [ "$ev" = skill ] && continue
    case " $seen " in *" $ev "*) ;; *) echo "no entry runs the routed event $ev" ;; esac
  done
  # The ship runs after the gate, so a block is decided before the turn is shipped.
  local order
  order=$(hook_lines "$file" | awk '$1 == "Stop" { for (i = 5; i <= NF; i++) if ($i == "stop-gate" || $i == "stop-ship") printf "%s ", $i }')
  [ "$order" = "stop-gate stop-ship " ] || echo "Stop: wanted the gate before the ship, got [$order]"
}

# Self-check: a hooks file with a drifted entry is caught, so the audit is a gate.
planted="$H_TMP/planted-hooks.json"
cat >"$planted" <<'JSON'
{"hooks": {
  "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/launcher/bbd-launch.sh\" session-start plugin", "timeout": 20}]}],
  "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/launcher/bbd-launch.sh\" prompt repo", "timeout": 10}]}],
  "PreToolUse": [{"matcher": "Write", "hooks": [{"type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/launcher/bbd-launch.sh\" pre-write plugin", "timeout": 5}]}],
  "Stop": [{"hooks": [
    {"type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/launcher/bbd-launch.sh\" stop-ship plugin", "async": true},
    {"type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/launcher/bbd-launch.sh\" stop-gate plugin", "timeout": 30},
    {"type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/launcher/bbd-launch.sh\" no-such-event plugin"},
    {"type": "command", "command": "python3 other.py stop-gate plugin"}]}]
}}
JSON
out=$(audit_hooks "$planted" "$PLUGIN_BOOT" plugin)
case "$out" in *"delivery is [repo]"*) h_ok "self-check: a wrong delivery is caught" ;; *) h_fail "self-check: a wrong delivery was missed" ;; esac
case "$out" in *"pre-write wants matcher"*) h_ok "self-check: a drifted matcher is caught" ;; *) h_fail "self-check: a drifted matcher was missed" ;; esac
case "$out" in *"stop-gate wants timeout 90"*) h_ok "self-check: a drifted timeout is caught" ;; *) h_fail "self-check: a drifted timeout was missed" ;; esac
case "$out" in *"[no-such-event] has no launcher/events"*) h_ok "self-check: an event the dispatcher does not route is caught" ;; *) h_fail "self-check: an unrouted event was missed" ;; esac
case "$out" in *"does not run the bootstrap"*) h_ok "self-check: a command that is not the bootstrap is caught" ;; *) h_fail "self-check: a foreign command was missed" ;; esac
case "$out" in *"wanted the gate before the ship"*) h_ok "self-check: a ship before the gate is caught" ;; *) h_fail "self-check: the Stop order was not checked" ;; esac

h_assert_empty "$(audit_hooks "$HOOKS" "$PLUGIN_BOOT" plugin)" "plugin hooks: every entry runs the bootstrap with a routed event, the contract's timeouts and the plugin delivery"
h_assert_eq "$(jget "$HOOKS" 'sorted(k for k in d if k not in ("hooks", "description"))')" '[]' "plugin hooks: only hooks and description at the top level"
h_assert_eq "$(hook_lines "$HOOKS" | grep -c .)" 5 "plugin hooks: five command entries"
if [ -f "$PLUGIN_DIR/launcher/bbd-launch.sh" ]; then h_ok "plugin hooks: the bootstrap they name exists"; else h_fail "plugin hooks: plugin/launcher/bbd-launch.sh is missing"; fi
if [ -e "$PLUGIN_DIR/allowed_signers" ]; then
  h_fail "plugin: an allowed_signers file is present; with one, every unsigned head is refused, so it ships only with the signing keys"
else
  h_ok "plugin: no allowed_signers file until the signing keys ship"
fi

# --- the tenant repository template.
h_assert_empty "$(audit_hooks "$SETTINGS" "$REPO_BOOT" repo)" "template settings: the same events through the committed copy, repo delivery, ship synchronous at 60"
if [ -f "$TEMPLATE/.claude/hooks/bbd-launch.sh" ]; then h_ok "template settings: the bootstrap they name exists"; else h_fail "template: .claude/hooks/bbd-launch.sh is missing"; fi
h_assert_eq "$(jget "$SETTINGS" 'd["extraKnownMarketplaces"]["bbd-apparatus"]["source"]')" '{"repo": "BBD-Sites/bbd-apparatus", "source": "github"}' "template settings: the marketplace is declared from this repository"
h_assert_eq "$(jget "$SETTINGS" 'd["extraKnownMarketplaces"]["bbd-apparatus"]["autoUpdate"]')" true "template settings: marketplace auto-update is on"
h_assert_eq "$(jget "$SETTINGS" '"enabledPlugins" in d')" false "template settings: no enabledPlugins (a relative-path plugin would load from project settings and act beside the committed copy)"
h_assert_eq "$(jget "$SETTINGS" 'sorted(d.keys())')" '["extraKnownMarketplaces", "hooks"]' "template settings: nothing else is set for the tenant"

# Every hook entry in both files runs a bootstrap that is one of the two identical copies.
if cmp -s "$PLUGIN_DIR/launcher/bbd-launch.sh" "$TEMPLATE/.claude/hooks/bbd-launch.sh"; then
  h_ok "the two bootstrap copies the manifests point at are the same bytes"
else
  h_fail "the two bootstrap copies the manifests point at differ"
fi

# --- skill stubs: a stub names its directory, routes to `skill <name>` and pre-approves
# that one call. The template's stub runs the committed copy with the repo delivery.
check_skill() {
  local file=$1 boot=$2 delivery=$3 name front body
  name=$(basename "$(dirname "$file")")
  if [ ! -f "$file" ]; then h_fail "skill $name: ${file#"$root"/} is missing"; return; fi
  front=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$file")
  body=$(awk 'f { print } $0 == "---" { c++; if (c == 2) f = 1 }' "$file")
  h_assert_eq "$(printf '%s\n' "$front" | sed -n 's/^name:[[:space:]]*//p')" "$name" "skill $name: frontmatter name equals the directory"
  h_assert_nonempty "$(printf '%s\n' "$front" | sed -n 's/^description:[[:space:]]*//p')" "skill $name: description present"
  case "$front" in *"allowed-tools: Bash($boot skill $name"*) h_ok "skill $name: its one launcher call is pre-approved" ;;
    *) h_fail "skill $name: allowed-tools does not pre-approve the launcher call" ;; esac
  case "$body" in *"$boot skill $name${delivery:+ $delivery}"*) h_ok "skill $name: the body runs skill $name through the bootstrap" ;;
    *) h_fail "skill $name: the body does not run skill $name through the bootstrap" ;; esac
  if [ -f "$root/launcher/events/skill.sh" ]; then h_ok "skill $name: the dispatcher has a skill event"; else h_fail "skill $name: no launcher/events/skill.sh"; fi
}
for d in "$PLUGIN_DIR"/skills/*/; do
  [ -d "$d" ] || { h_fail "plugin: no skills directory"; break; }
  check_skill "${d}SKILL.md" "$PLUGIN_BOOT" ""
done
for d in "$TEMPLATE"/.claude/skills/*/; do
  [ -d "$d" ] || { h_fail "template: no skills directory"; break; }
  check_skill "${d}SKILL.md" "$REPO_BOOT" repo
done
skill_names() { find "$1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sed 's#.*/##' | sort | tr '\n' ' '; }
h_assert_eq "$(skill_names "$PLUGIN_DIR"/skills)" "$(skill_names "$TEMPLATE"/.claude/skills)" "the plugin and the template carry the same skill stubs"

# --- the template marker: the shape the launcher reads, with the tenant left empty so a
# copy that provisioning has not filled never acts; filled, the same file passes.
h_assert_eq "$(jget "$MARKER" 'd["schema"]')" 1 "template marker: schema 1"
h_assert_eq "$(jget "$MARKER" 'd["tenant"]')" "" "template marker: tenant is empty until provisioning fills it"
h_assert_eq "$(jget "$MARKER" 'd["channel"]')" stable "template marker: channel stable"
h_assert_eq "$(jget "$MARKER" 'd["rules"]')" RULES.md "template marker: rules file named"
h_assert_eq "$(jget "$MARKER" 'sorted(d.keys())')" '["channel", "rules", "schema", "tenant"]' "template marker: exactly the four fields the contract names"

if [ -f "$MARKER" ]; then
  h_fake_apparatus >/dev/null
  h_plant_event t1 prompt
  boot=$(h_bootstrap)
  repo=$(h_fake_repo vault)
  home=$(h_fake_home tenant)
  mkdir -p "$repo/.apparatus"
  cp "$MARKER" "$repo/.apparatus/vault.json"
  h_git -C "$repo" add .apparatus/vault.json
  h_git -C "$repo" commit -q -m "chore: unfilled marker"
  h_calls_reset git
  h_hook_json UserPromptSubmit cwd="$repo" | h_launch unfilled "$home" CLAUDE_PROJECT_DIR="$repo" -- "$boot" prompt plugin
  h_assert_hook_run unfilled "unfilled template marker"
  h_assert_empty "$(h_sentinel)" "unfilled template marker: no event ran"
  h_assert_empty "$(h_net_calls)" "unfilled template marker: no fetch"
  if [ -e "$home/.claude/bbd-apparatus" ]; then h_fail "unfilled template marker: a state directory was made"; else h_ok "unfilled template marker: nothing written to the home"; fi
  python3 -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["tenant"] = "tenant-a"
json.dump(d, open(p, "w"))
' "$repo/.apparatus/vault.json"
  h_git -C "$repo" commit -q -am "chore: provisioning fills the tenant"
  h_hook_json UserPromptSubmit cwd="$repo" | h_launch filled "$home" CLAUDE_PROJECT_DIR="$repo" -- "$boot" prompt plugin
  h_assert_hook_run filled "filled template marker"
  h_assert_eq "$(h_sentinel | awk '{print $1, $2}')" "t1 prompt" "filled template marker: the event runs"
fi

# --- claude plugin validate --strict, with no login: an empty home stands in for a
# machine that has never signed in. Where no CLI is on PATH the step is skipped with a
# reason, except in CI, where the workflow installs it and a missing CLI is a failure.
if command -v claude >/dev/null 2>&1; then
  vhome="$H_TMP/validate-home"
  mkdir -p "$vhome/.claude"
  for target in "$root" "$PLUGIN_DIR"; do
    label=${target#"$root"}
    label=${label:-the marketplace root}
    out=$(env -i PATH="$PATH" HOME="$vhome" CLAUDE_CONFIG_DIR="$vhome/.claude" TMPDIR="${TMPDIR:-/tmp}" LANG=C \
      claude plugin validate --strict "$target" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
      h_ok "claude plugin validate --strict passes on $label"
    else
      h_fail "claude plugin validate --strict failed (exit $rc) on $label"
      printf '%s\n' "$out" | sed 's/^/    /'
    fi
  done
elif [ -n "${CI:-}" ]; then
  h_fail "no claude CLI on PATH in CI; the workflow installs it so the validate step cannot be skipped"
else
  echo "skip: no claude CLI on PATH, claude plugin validate not run"
fi

h_done
