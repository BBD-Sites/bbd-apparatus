#!/usr/bin/env bash
# Two copies of the bootstrap fire in a desktop session: the plugin's and the one
# committed in the tenant repository. Only one may act, or every turn would inject
# and ship twice. The repository copy stands down on a home that has tenant.env
# (only an install that also enabled the plugin writes it); it runs in the cloud,
# where no plugin loads, and on a home with no install. Where the session ran is
# recorded as cloud, remote-control or desktop.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

h_fake_bin git
h_fake_apparatus >/dev/null
h_plant_event v1 prompt
boot=$(h_bootstrap)
repo_copy="$(h_repo_root)/templates/tenant-repo/.claude/hooks/bbd-launch.sh"
repo=$(h_fake_repo vault)
h_mark "$repo" tenant-a
installed=$(h_fake_home installed)
h_tenant_env "$installed" tenant-a
bare_home=$(h_fake_home uninstalled)

queued() { [ -f "$1/.claude/bbd-apparatus/queue/$2.json" ]; }
where_of() { h_json_field where <"$1/.claude/bbd-apparatus/queue/$2.json"; }

# Installed Mac home, repository copy: stands down, before any network or state.
h_calls_reset git
h_sentinel_reset
h_hook_json Stop cwd="$repo" session_id=sid-dup | h_launch dup "$installed" CLAUDE_PROJECT_DIR="$repo" -- "$repo_copy" stop-ship repo
h_assert_hook_run dup "repository copy on an installed home"
h_hook_json UserPromptSubmit cwd="$repo" | h_launch dup-prompt "$installed" CLAUDE_PROJECT_DIR="$repo" -- "$repo_copy" prompt repo
h_assert_hook_run dup-prompt "repository copy on an installed home, prompt"
if queued "$installed" sid-dup; then h_fail "repository copy on an installed home: it queued the turn"
else h_ok "repository copy on an installed home: it stands down"; fi
h_assert_empty "$(h_sentinel)" "repository copy on an installed home: no event ran"
h_assert_empty "$(h_net_calls)" "repository copy on an installed home: no fetch"

# The plugin copy on the same home acts, so the turn is handled exactly once.
h_hook_json Stop cwd="$repo" session_id=sid-dup | h_launch dup-plugin "$installed" CLAUDE_PROJECT_DIR="$repo" -- "$boot" stop-ship plugin
h_assert_hook_run dup-plugin "plugin copy on an installed home"
if queued "$installed" sid-dup; then h_ok "plugin copy on an installed home: it queues the turn"
else h_fail "plugin copy on an installed home: nothing queued"; fi
h_assert_eq "$(where_of "$installed" sid-dup)" desktop "plugin copy on a desktop: where is desktop"

# The cloud: the repository copy runs, even if a tenant.env were present.
h_hook_json Stop cwd="$repo" session_id=sid-cloud | h_launch cloud "$installed" CLAUDE_CODE_REMOTE=true CLAUDE_PROJECT_DIR="$repo" -- "$repo_copy" stop-ship repo
h_assert_hook_run cloud "repository copy in the cloud"
if queued "$installed" sid-cloud; then h_ok "repository copy in the cloud: it runs"
else h_fail "repository copy in the cloud: it stood down"; fi
h_assert_eq "$(where_of "$installed" sid-cloud)" cloud "repository copy in the cloud: where is cloud"

# A cloud machine has no install: the repository copy runs there too.
cloud_home=$(h_fake_home cloud-vm)
h_hook_json Stop cwd="$repo" session_id=sid-vm | h_launch cloud-vm "$cloud_home" CLAUDE_CODE_REMOTE=true CLAUDE_PROJECT_DIR="$repo" -- "$repo_copy" stop-ship repo
h_assert_hook_run cloud-vm "repository copy on a cloud machine"
if queued "$cloud_home" sid-vm; then h_ok "repository copy on a cloud machine: it runs"
else h_fail "repository copy on a cloud machine: it stood down"; fi

# A home with no install: the repository copy is the only one, so it runs.
h_sentinel_reset
h_hook_json Stop cwd="$repo" session_id=sid-bare | h_launch bare "$bare_home" CLAUDE_PROJECT_DIR="$repo" -- "$repo_copy" stop-ship repo
h_assert_hook_run bare "repository copy on a home with no install"
if queued "$bare_home" sid-bare; then h_ok "repository copy on a home with no install: it runs"
else h_fail "repository copy on a home with no install: it stood down"; fi
h_hook_json UserPromptSubmit cwd="$repo" | h_launch bare-prompt "$bare_home" CLAUDE_PROJECT_DIR="$repo" -- "$repo_copy" prompt repo
h_assert_eq "$(h_sentinel | awk '{print $1, $2}')" "v1 prompt" "repository copy on a home with no install: its events run"

# Remote Control is told apart from the desktop.
h_hook_json Stop cwd="$repo" session_id=sid-rc | h_launch rc "$installed" CLAUDE_CODE_BRIDGE_SESSION_ID=bridge-1 CLAUDE_PROJECT_DIR="$repo" -- "$boot" stop-ship plugin
h_assert_eq "$(where_of "$installed" sid-rc)" remote-control "a Remote Control session: where is remote-control"

# CLAUDE_CONFIG_DIR names the account home when it is set.
alt="$H_TMP/alt-config"
mkdir -p "$alt"
h_hook_json Stop cwd="$repo" session_id=sid-alt | h_launch alt "$bare_home" CLAUDE_CONFIG_DIR="$alt" CLAUDE_PROJECT_DIR="$repo" -- "$boot" stop-ship plugin
if [ -f "$alt/bbd-apparatus/queue/sid-alt.json" ]; then h_ok "CLAUDE_CONFIG_DIR is the account home"
else h_fail "CLAUDE_CONFIG_DIR was not used"; fi

# A delivery that is neither plugin nor repo does nothing.
h_hook_json Stop cwd="$repo" session_id=sid-odd | h_launch odd "$bare_home" CLAUDE_PROJECT_DIR="$repo" -- "$boot" stop-ship other
h_assert_hook_run odd "an unknown delivery"
if queued "$bare_home" sid-odd; then h_fail "an unknown delivery acted"; else h_ok "an unknown delivery does nothing"; fi

h_done
