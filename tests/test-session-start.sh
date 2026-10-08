#!/usr/bin/env bash
# The session-start step (docs/launcher-contract.md section 12), run through the
# bootstrap exactly as a session would fire it. On startup, resume, clear and fork it
# prints the keep-current notices that are due and nothing else: a newer Claude Code
# than the one running, a newer model in the same line as the one in use, and the
# fresh-session advice once a session has compacted three times or its context is
# past sixty percent. Each notice is said once per home (per version, per newer model,
# per session), a stop in notices.json or the marker silences it, and nothing is said
# when everything is current. On compact, the compact step still runs and the
# fresh-session advice is folded into its one JSON object. The step makes no network
# call of its own, and a token shape never reaches stdout.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

h_fake_bin git
h_fake_bin claude
h_fake_apparatus >/dev/null
boot=$(h_bootstrap)
repo=$(h_fake_repo vault)
h_mark "$repo" tenant-a
root=$(h_repo_root)
tmp=$(h_tmpdir)

printf '%s\n' "# Rules" "RULE-ALPHA: reply in plain words." >"$repo/RULES.md"
git -C "$repo" add RULES.md
h_git -C "$repo" commit -q -m "chore: rules"

# The data the notices compare against, as shipped in this working copy.
latest_cli=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["latest"])' "$root/data/claude-code.json" 2>/dev/null)
h_assert_nonempty "$latest_cli" "data/claude-code.json names the latest Claude Code version"
newest_opus=$(python3 -c '
import json,sys
ms=[m for m in json.load(open(sys.argv[1]))["models"] if m["line"]=="opus"]
print(max(ms, key=lambda m: m["released"])["id"])' "$root/data/models.json" 2>/dev/null)
h_assert_nonempty "$newest_opus" "data/models.json carries an opus line with release dates"

# newhome NAME: a fresh account home with a token for tenant-a; prints its path.
newhome() {
  local home
  home=$(h_fake_home "$1")
  h_tenant_env "$home" tenant-a "BBD_CHANNEL=stable"
  printf '%s\n' "$home"
}
# start NAME HOME SESSION SOURCE MODEL [CLI-VERSION] [key=value ...]: one SessionStart
# turn from the plugin. CLI-VERSION is what the fake `claude --version` prints.
start() {
  local name=$1 home=$2 sid=$3 source=$4 model=$5 cli=${6:-} transcript
  shift 6 2>/dev/null || shift $#
  transcript="$tmp/transcripts/$sid.jsonl"
  h_calls_reset claude
  h_hook_json SessionStart cwd="$repo" session_id="$sid" source="$source" model="$model" \
      transcript_path="$transcript" "$@" \
    | h_launch "$name" "$home" H_FAKE_CLAUDE_STDOUT="$cli" -- "$boot" session-start plugin
}
# transcript SESSION VERSION [EXTRA-JSON-FIELD]: a transcript whose lines carry a version.
transcript() {
  mkdir -p "$tmp/transcripts"
  python3 -c '
import json,sys
sid, ver, extra = sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else ""
lines = [{"type": "attachment", "sessionId": sid}, {"type": "user", "version": ver, "sessionId": sid}]
if extra:
    lines[1]["note"] = extra
print("\n".join(json.dumps(l) for l in lines))' "$@" >"$tmp/transcripts/$1.jsonl"
}
# transcript2 SESSION OLD NEW: a transcript that began on build OLD and continued on
# build NEW, with enough between them that OLD sits outside any tail read.
transcript2() {
  mkdir -p "$tmp/transcripts"
  python3 -c '
import json,sys
sid, old, new = sys.argv[1:4]
lines = [{"type": "user", "version": old, "sessionId": sid}]
lines += [{"type": "assistant", "sessionId": sid, "text": "x" * 1000} for _ in range(300)]
lines.append({"type": "user", "version": new, "sessionId": sid})
print("\n".join(json.dumps(l) for l in lines))' "$@" >"$tmp/transcripts/$1.jsonl"
}
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
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
# said HOME: the keys recorded in notices.json, one per line.
said() {
  python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
print("\n".join(sorted(d.get("said",{}))))' "$1/.claude/bbd-apparatus/state/notices.json" 2>/dev/null
}
# One remote operation is allowed per run: the bootstrap's own fetch of the fixed URL.
net_beyond_bootstrap() {
  h_calls git | grep -E '(^| )(fetch|clone|pull|push|ls-remote)( |$)' \
    | grep -v -F -e "fetch -q --no-tags --depth=1 $H_APPARATUS_URL" || true
}

# 1. Everything current: a session on the newest opus with the latest Claude Code
# prints nothing, writes no notice, and still exits 0.
home=$(newhome current)
h_calls_reset git
start current "$home" s-cur startup "$newest_opus" "$latest_cli (Claude Code)"
h_assert_hook_run current "everything current"
h_assert_empty "$(h_run_out current)" "everything current: nothing is said"
h_assert_empty "$(said "$home")" "everything current: nothing is recorded as said"
h_assert_empty "$(net_beyond_bootstrap)" "everything current: no network call beyond the bootstrap's fetch"
h_assert_eq "$(h_calls claude)" "--version" "everything current: the CLI is asked only for its version"

# 2. Behind on both: an old Claude Code and the older opus. Both notices come in one
# SessionStart object, in plain words, with no rules and no reply contract; a
# second session in the same home is told neither again.
home=$(newhome behind)
start behind "$home" s-b1 startup claude-opus-5 "2.0.0 (Claude Code)"
h_assert_hook_run behind "behind on both"
h_assert_eq "$(event_name behind)" SessionStart "behind on both: the event is SessionStart"
c=$(ctx behind)
if has "$c" "$latest_cli" && has "$c" "2.0.0"; then h_ok "behind on both: the version notice names both versions"; else h_fail "behind on both: no version notice"; fi
if has "$c" "$newest_opus"; then h_ok "behind on both: the model notice names the newer model"; else h_fail "behind on both: no model notice"; fi
if has "$c" "/model $newest_opus"; then h_ok "behind on both: the one step to switch is given"; else h_fail "behind on both: the switch step is missing"; fi
if has "$c" "RULE-ALPHA" || has "$c" "Start with the answer"; then h_fail "behind on both: rules or the reply contract were injected at session start"; else h_ok "behind on both: no rules and no reply contract"; fi
case "$(said "$home")" in *"model:$newest_opus"*"version:$latest_cli"*|*"version:$latest_cli"*"model:$newest_opus"*) h_ok "behind on both: both notices are recorded" ;; *) h_fail "behind on both: the record is incomplete" ;; esac
start behind2 "$home" s-b2 startup claude-opus-5 "2.0.0 (Claude Code)"
h_assert_hook_run behind2 "the next session in that home"
h_assert_empty "$(h_run_out behind2)" "the next session in that home: neither notice is said again"
case "$(uname)" in
  Darwin) nmode=$(stat -f '%Lp' "$home/.claude/bbd-apparatus/state/notices.json") ;;
  *) nmode=$(stat -c '%a' "$home/.claude/bbd-apparatus/state/notices.json") ;;
esac
h_assert_eq "$nmode" 600 "notices.json is 0600"

# 3. The running version is the newest of the transcript's LAST version field and
# what the CLI on PATH says. A session that began on an older build and was resumed
# on the current one is not told to restart, and the once-per-version key is not
# spent on it; a tail newer than the CLI is the one compared. A newer line than the
# one in use is not offered: a sonnet session is never told about an opus.
home=$(newhome transcript)
transcript2 s-t0 2.0.0 "$latest_cli"
start upgraded "$home" s-t0 resume claude-sonnet-5-5 "2.0.0 (Claude Code)"
h_assert_hook_run upgraded "a session resumed after an upgrade"
h_assert_empty "$(h_run_out upgraded)" "a session resumed after an upgrade: no notice from the head's older build"
h_assert_empty "$(said "$home" | grep '^version:' || true)" "a session resumed after an upgrade: the once-per-version key is not spent"
transcript s-t2 2.0.0
start cli-newer "$home" s-t2 resume claude-sonnet-5-5 "$latest_cli (Claude Code)"
h_assert_empty "$(h_run_out cli-newer)" "the CLI on PATH is newer than the transcript's tail: no notice"
transcript s-t1 2.1.100
start transcript "$home" s-t1 resume claude-sonnet-5-5 "2.0.0 (Claude Code)"
h_assert_hook_run transcript "the transcript's tail is newer than the CLI"
c=$(ctx transcript)
if has "$c" "2.1.100"; then h_ok "the transcript's tail is newer than the CLI: it is the one compared"; else h_fail "the transcript's tail is newer than the CLI: it was not used"; fi
h_assert_eq "$(h_calls claude)" "--version" "the transcript's tail is newer than the CLI: the CLI was asked as well"
if has "$c" "opus"; then h_fail "a sonnet session was told about an opus"; else h_ok "a sonnet session is not told about another line"; fi

# 4. A version the CLI prints in an unexpected shape, or an unknown model, is not a
# notice and not a crash.
home=$(newhome odd)
start odd "$home" s-o1 startup some-other-model "no version here"
h_assert_hook_run odd "an odd version and an unknown model"
h_assert_empty "$(h_run_out odd)" "an odd version and an unknown model: nothing is said"

# A model id in its long-context form (a bracketed suffix) or its dated form is the
# same model: it is compared, and the window it is compared against is its own.
home=$(newhome suffix)
start bracket "$home" s-br startup "claude-opus-5[1m]" "$latest_cli (Claude Code)"
h_assert_hook_run bracket "a bracketed model id"
if has "$(ctx bracket)" "$newest_opus"; then h_ok "a bracketed model id: the model notice still comes"; else h_fail "a bracketed model id: no model notice"; fi
start bracket-ctx "$home" s-br2 resume "claude-opus-5-5[1m]" "$latest_cli (Claude Code)" context_tokens=700000
if has "$(ctx bracket-ctx)" "fresh session"; then h_ok "a bracketed model id: the context advice still comes"; else h_fail "a bracketed model id: no context advice"; fi
start dated "$home" s-dt startup claude-sonnet-4-5-20250929 "$latest_cli (Claude Code)"
if has "$(ctx dated)" "claude-sonnet-5-5"; then h_ok "a dated model id: the model notice names the newest sonnet"; else h_fail "a dated model id: no model notice"; fi

# 5. Fresh-session advice after three compactions, folded into the compact step's
# one object with the compaction notice and the rules; said once per session.
home=$(newhome compact)
start c1 "$home" s-c compact claude-opus-5-5 "$latest_cli (Claude Code)"
start c2 "$home" s-c compact claude-opus-5-5 "$latest_cli (Claude Code)"
for n in c1 c2; do
  h_assert_hook_run "$n" "compaction $n"
  if has "$(ctx "$n")" "fresh session"; then h_fail "compaction $n: the advice came before the third compaction"; else h_ok "compaction $n: no advice yet"; fi
done
start c3 "$home" s-c compact claude-opus-5-5 "$latest_cli (Claude Code)"
h_assert_hook_run c3 "the third compaction"
c=$(ctx c3)
h_assert_eq "$(event_name c3)" SessionStart "the third compaction: still one SessionStart object"
if has "$c" "compacted" && has "$c" "RULE-ALPHA"; then h_ok "the third compaction: the compact step's own injection is still there"; else h_fail "the third compaction: the compact injection is missing"; fi
if has "$c" "fresh session" && has "$c" "3 times"; then h_ok "the third compaction: the advice is folded in and names the count"; else h_fail "the third compaction: no fresh-session advice"; fi
h_assert_eq "$(cat "$home/.claude/bbd-apparatus/state/compactions/s-c")" 3 "the third compaction: the count is 3"
start c4 "$home" s-c compact claude-opus-5-5 "$latest_cli (Claude Code)"
if has "$(ctx c4)" "fresh session"; then h_fail "the fourth compaction: the advice was repeated"; else h_ok "the fourth compaction: the advice is not repeated in this session"; fi
if has "$(ctx c4)" "compacted"; then h_ok "the fourth compaction: the compact injection still runs"; else h_fail "the fourth compaction: the compact injection stopped"; fi
start c-resume "$home" s-c resume claude-opus-5-5 "$latest_cli (Claude Code)"
if has "$(ctx c-resume)" "fresh session"; then h_fail "a resume of the compacted session: the advice was repeated"; else h_ok "a resume of the compacted session: nothing more is said"; fi
start c-other "$home" s-other compact claude-opus-5-5 "$latest_cli (Claude Code)"
if has "$(ctx c-other)" "fresh session"; then h_fail "another session's first compaction: advice leaked across sessions"; else h_ok "another session's first compaction: no advice"; fi

# 6. Fresh-session advice when the context is past sixty percent of the model's
# window, on resume or fork where the harness reports it; once per session; never
# for a model whose window is unknown.
home=$(newhome context)
start ctx-low "$home" s-x resume claude-opus-5-5 "$latest_cli (Claude Code)" context_tokens=100000
h_assert_empty "$(h_run_out ctx-low)" "context at ten percent: nothing is said"
start ctx-high "$home" s-x fork claude-opus-5-5 "$latest_cli (Claude Code)" context_tokens=700000
h_assert_hook_run ctx-high "context past sixty percent"
c=$(ctx ctx-high)
if has "$c" "fresh session" && has "$c" "70 percent"; then h_ok "context past sixty percent: the advice names the share used"; else h_fail "context past sixty percent: no advice"; fi
start ctx-again "$home" s-x resume claude-opus-5-5 "$latest_cli (Claude Code)" context_tokens=800000
h_assert_empty "$(h_run_out ctx-again)" "context still high: not said twice in one session"
start ctx-unknown "$home" s-y resume some-other-model "$latest_cli (Claude Code)" context_tokens=900000000
h_assert_empty "$(h_run_out ctx-unknown)" "an unknown model's window: no advice from a guess"

# 7. A stop is honoured: a stop on model notices in notices.json leaves the version
# notice; a marker that turns notices off silences everything.
home=$(newhome stop)
mkdir -p "$home/.claude/bbd-apparatus/state"
printf '%s\n' '{"schema": 1, "said": {}, "stop": ["model"]}' >"$home/.claude/bbd-apparatus/state/notices.json"
start stop "$home" s-s1 startup claude-opus-5 "2.0.0 (Claude Code)"
c=$(ctx stop)
if has "$c" "2.0.0"; then h_ok "a stop on model notices: the version notice still comes"; else h_fail "a stop on model notices: the version notice was lost"; fi
if has "$c" "$newest_opus"; then h_fail "a stop on model notices: the model notice was said anyway"; else h_ok "a stop on model notices: no model notice"; fi
python3 -c 'import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["notices"]=False; json.dump(d, open(p,"w"))' "$repo/.apparatus/vault.json"
git -C "$repo" add .apparatus/vault.json
h_git -C "$repo" commit -q -m "chore: notices off"
home=$(newhome marker-off)
start marker-off "$home" s-m1 startup claude-opus-5 "2.0.0 (Claude Code)"
h_assert_hook_run marker-off "the marker turns notices off"
h_assert_empty "$(h_run_out marker-off)" "the marker turns notices off: nothing is said"
git -C "$repo" checkout -q HEAD~1 -- .apparatus/vault.json
h_git -C "$repo" commit -q -m "chore: notices back on"

# 8. Clear and fork run the same step as startup and resume: exit 0, hook JSON or
# nothing, and the once-per-home record keeps a repeat quiet.
home=$(newhome sources)
start clear "$home" s-clear clear claude-opus-5 "2.0.0 (Claude Code)"
h_assert_hook_run clear "a clear"
if has "$(ctx clear)" "$newest_opus"; then h_ok "a clear: the notices run"; else h_fail "a clear: no notices"; fi
start fork "$home" s-fork fork claude-opus-5 "2.0.0 (Claude Code)"
h_assert_hook_run fork "a fork"
h_assert_empty "$(h_run_out fork)" "a fork after the clear said it: quiet"

# 9. A token shape in the transcript or the rules never reaches stdout, stderr or
# the state directory.
body=$(printf 'T%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)
token="bbdt""_$body"
home=$(newhome token)
transcript s-tok 2.1.100 "$token"
printf '%s\n' "RULE-GAMMA: the token is $token" >>"$repo/RULES.md"
start tok-resume "$home" s-tok resume claude-opus-5 "2.0.0 (Claude Code)"
start tok-compact "$home" s-tok compact claude-opus-5 "2.0.0 (Claude Code)"
h_assert_hook_run tok-compact "a compaction with a token in the rules"
if grep -rq "$body" "$tmp/run/tok-resume.out" "$tmp/run/tok-resume.err" "$tmp/run/tok-compact.out" \
    "$tmp/run/tok-compact.err" "$home/.claude/bbd-apparatus/state" 2>/dev/null; then
  h_fail "a token near the step reached stdout, stderr or the state directory"
else h_ok "a token near the step is nowhere on stdout, stderr or in the state directory"; fi
git -C "$repo" checkout -q -- RULES.md

# 10. No network of its own: the step's code names no HTTP client, registry or URL
# fetch, and every run above made no remote git call beyond the bootstrap's fetch.
h_assert_empty "$(net_beyond_bootstrap)" "no run made a remote git call beyond the bootstrap's fetch"
h_assert_empty "$(grep -n -i -E 'urllib|http\.client|requests|curl |wget |registry\.npmjs|socket\.' \
  "$root/launcher/events/session-start.sh" "$root/lib/notices.py" 2>/dev/null)" "the step's code holds no network client"

h_done
