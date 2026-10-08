#!/usr/bin/env bash
# The Stop ship step's HTTP door and its queue (docs/ingest-contract.md and
# docs/launcher-contract.md section 10), against a stand-in store on 127.0.0.1 that
# this test starts. Each case plants its failure first: no ingest URL, a refused
# token, a store error, a longer copy already stored, a body too large, a redirect, a
# secret the redactor missed, a failing self-test and a transcript that is gone. In
# every case the turn exits 0, the queue keeps what has not been stored, and the
# token never leaves the request's Authorization header.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

h_fake_bin git
src=$(h_fake_apparatus)
boot=$(h_bootstrap)
home=$(h_fake_home h1)
repo=$(h_fake_repo vault)
h_mark "$repo" tenant-a
base="$home/.claude/bbd-apparatus"
queue="$base/queue"
fixture="$(h_repo_root)/tests/fixtures/transcripts/11111111-2222-4333-8444-555555555551.jsonl"

# The token is assembled at run time, so its shape never appears in a tracked file.
body=$(printf 'T%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)
token="bbdt""_$body"

# The stand-in store, stopped when the test exits.
store="$H_TMP/store"
mkdir -p "$store"
python3 "$(h_repo_root)/tests/lib/fake_store.py" "$store" 2>"$store.stderr" &
store_pid=$!
trap 'kill "$store_pid" 2>/dev/null; wait "$store_pid" 2>/dev/null; h_cleanup' EXIT
# A cold python on a CI runner can take several seconds to start. The address is
# read only once the store has written its port: read too early, it would be
# http://127.0.0.1: with no port, and every post would be refused.
for _ in $(seq 1 300); do [ -s "$store/port" ] && break; sleep 0.1; done
if [ ! -s "$store/port" ]; then
  h_fail "the stand-in store did not start within 30 seconds"
  h_done
fi
url="http://127.0.0.1:$(cat "$store/port")"
answer() { printf '%s\n' "$1" >"$store/status"; }
requests() { awk 'END { print NR }' "$store/requests.jsonl" 2>/dev/null || echo 0; }
forget_requests() { : >"$store/requests.jsonl"; }
: >"$store/requests.jsonl"
# The paths the store was asked for, one per line.
paths() { python3 -c 'import json,sys
for l in open(sys.argv[1]): print(json.loads(l)["path"])' "$store/requests.jsonl" 2>/dev/null; }

# A transcript for SESSION, copied from the fixture; with a second argument, that
# text is added as an assistant turn.
transcript() {
  local sid=$1 extra=${2:-} t="$H_TMP/transcripts/$1.jsonl"
  mkdir -p "$H_TMP/transcripts"
  cp "$fixture" "$t"
  if [ -n "$extra" ]; then
    python3 -c 'import json,sys
print(json.dumps({"type": "assistant", "timestamp": "2026-01-05T10:10:00.000Z", "cwd": "/srv/projects/demo-notes",
  "message": {"role": "assistant", "content": [{"type": "text", "text": sys.argv[1]}]}}))' "$extra" >>"$t"
  fi
  printf '%s\n' "$t"
}

# ship NAME SESSION [VAR=value ...]: one Stop ship turn of SESSION, from the plugin.
# The first ship run after which the store stopped taking connections, recorded once,
# so a failure on a CI runner names the case that took the store down.
store_lost=""
store_listens() {
  python3 -c 'import socket,sys; s=socket.create_connection(("127.0.0.1", int(sys.argv[1])), 2); s.close()' \
    "$(cat "$store/port")" 2>/dev/null
}
ship() {
  local name=$1 sid=$2
  shift 2
  if [ -z "$store_lost" ] && ! store_listens; then
    store_lost="before $name"
    echo "diagnostic: the stand-in store stopped listening before the run named $name"
    ps -o pid=,ppid=,stat=,command= -p "$store_pid" 2>/dev/null | sed 's/^/diagnostic: store process: /'
  fi
  h_hook_json Stop cwd="$repo" session_id="$sid" transcript_path="$H_TMP/transcripts/$sid.jsonl" \
    | h_launch "$name" "$home" "$@" -- "$boot" stop-ship plugin
}

queued() { [ -f "$queue/$1.json" ]; }
field() { h_json_field "$2" <"$queue/$1.json"; }
status() { [ -f "$base/state/ship-status.json" ] && h_json_field status <"$base/state/ship-status.json"; }
# How many notices are recorded under KEY (0 or 1: a notice is recorded once).
notices() { python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
print(1 if sys.argv[2] in d.get("pending", {}) else 0)' "$base/state/notices.json" "$1"; }

# 1. A token and no ingest URL: the store is not connected yet. Render and post-scan
# still run, so both witnesses are exercised; the pointer stays; nothing is sent.
h_tenant_env "$home" tenant-a "BBD_TOKEN=$token" "BBD_CHANNEL=stable"
transcript s1 >/dev/null
answer 201
ship no-url s1
h_assert_hook_run no-url "no ingest URL"
if queued s1; then h_ok "no ingest URL: the pointer stays queued"; else h_fail "no ingest URL: the pointer was dropped"; fi
h_assert_eq "$(status)" "store-not-connected" "no ingest URL: the state says store-not-connected"
h_assert_eq "$(requests)" 0 "no ingest URL: nothing was sent"
sha=$(git -C "$base/checkout-stable" rev-parse HEAD)
if [ -f "$base/state/selftest-$sha.ok" ]; then h_ok "no ingest URL: the self-test ran and is cached for this checkout"
else h_fail "no ingest URL: no cached self-test for this checkout"; fi
h_assert_empty "$(ls "$base/state/outbox" 2>/dev/null)" "no ingest URL: no rendered copy is left behind"
h_assert_eq "$(notices store-not-connected)" 1 "no ingest URL: a notice is recorded on a tenant channel"
grep -c 'self-test passed' "$base/state/launcher.log" >"$H_TMP/selftest-runs.1" 2>/dev/null
ship no-url-2 s1
h_assert_eq "$(grep -c 'self-test passed' "$base/state/launcher.log")" "$(cat "$H_TMP/selftest-runs.1")" \
  "the self-test runs once per checkout, not once per turn"
# The fetch stamp is renewed so this turn does not fetch, which would reset the edit.
printf '\n# edited in place\n' >>"$base/checkout-stable/lib/redact.py"
date +%s >"$base/state/fetch.stamp"
ship no-url-3 s1
git -C "$base/checkout-stable" checkout -q -- lib/redact.py
h_assert_eq "$(grep -c 'self-test passed' "$base/state/launcher.log")" "$(($(cat "$H_TMP/selftest-runs.1") + 1))" \
  "a redactor edited in place after its pass is tested again"

# The maintainers' own tenant runs on next while the store is built: no notice.
home_next=$(h_fake_home next)
h_tenant_env "$home_next" tenant-a "BBD_TOKEN=$token" "BBD_CHANNEL=next"
h_hook_json Stop cwd="$repo" session_id=s1 transcript_path="$H_TMP/transcripts/s1.jsonl" \
  | h_launch no-url-next "$home_next" -- "$boot" stop-ship plugin
h_assert_eq "$(h_json_field status <"$home_next/.claude/bbd-apparatus/state/ship-status.json")" "store-not-connected" \
  "no ingest URL on next: the state says store-not-connected"
if [ -f "$home_next/.claude/bbd-apparatus/state/notices.json" ] \
    && grep -q store-not-connected "$home_next/.claude/bbd-apparatus/state/notices.json"; then
  h_fail "no ingest URL on next: a notice was recorded"
else h_ok "no ingest URL on next: no notice"; fi

# 2. The URL appears: the next turn drains the queue and posts this session too, with
# the contract's headers and the bearer token.
h_tenant_env "$home" tenant-a "BBD_TOKEN=$token" "BBD_CHANNEL=stable" "BBD_INGEST_URL=$url"
transcript s2 >/dev/null
forget_requests
ship url-up s2
h_assert_hook_run url-up "store connected"
h_assert_eq "$(paths | sort | tr '\n' ' ')" "/v1/captures/s1 /v1/captures/s2 " "store connected: the queued session and this one were posted"
if queued s1 || queued s2; then h_fail "store connected: a stored session is still queued"; else h_ok "store connected: the queue is drained"; fi
h_assert_eq "$(status)" "shipped" "store connected: the state says shipped"
redactor_sha=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$src/lib/redact.py")
PYTHONDONTWRITEBYTECODE=1 python3 "$(h_repo_root)/bin/apparatus" render "$H_TMP/transcripts/s2.jsonl" >"$H_TMP/s2.expected.md"
python3 - "$store/requests.jsonl" "$token" "$redactor_sha" "$H_TMP/s2.expected.md" >"$H_TMP/headers.check" <<'PY'
import json, sys
reqs = [json.loads(l) for l in open(sys.argv[1])]
token, rsha, expected = sys.argv[2], sys.argv[3], open(sys.argv[4], encoding="utf-8").read()
r = [x for x in reqs if x["path"] == "/v1/captures/s2"][0]
h = {k.lower(): v for k, v in r["headers"].items()}
print("method", r["method"] == "POST")
print("bearer", h.get("authorization") == "Bearer " + token)
print("where", h.get("x-capture-where") == "desktop")
print("bytes", h.get("x-capture-bytes") == str(len(r["body"].encode("utf-8"))))
print("redactor", h.get("x-redactor") == rsha)
print("body", r["body"] == expected)
print("redacted", "[REDACTED:" in r["body"])
others = [v for k, v in h.items() if k != "authorization"]
print("token-only-in-auth", all(token not in x["body"] for x in reqs) and all(token not in v for v in others))
PY
for check in method bearer where bytes redactor body redacted token-only-in-auth; do
  h_assert_eq "$(awk -v c="$check" '$1 == c {print $2}' "$H_TMP/headers.check")" True "store connected: request $check"
done

# 3. The store refuses the token: the entry is kept and a notice is recorded once.
answer 401
transcript s3 >/dev/null
ship refused s3
h_assert_hook_run refused "token refused"
if queued s3; then h_ok "token refused: the entry is kept"; else h_fail "token refused: the entry was dropped"; fi
h_assert_eq "$(field s3 attempts)" 1 "token refused: the attempt is counted"
h_assert_eq "$(notices token-refused)" 1 "token refused: a notice is recorded"
at1=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pending"]["token-refused"]["at"])' "$base/state/notices.json")
sleep 1
answer 403
ship refused-2 s3
at2=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pending"]["token-refused"]["at"])' "$base/state/notices.json")
h_assert_eq "$at2" "$at1" "token refused again (403): the notice is not recorded a second time"
h_assert_eq "$(field s3 attempts)" 2 "token refused again: the attempt is counted"

# 4. A store error keeps the entry.
answer 503
ship store-down s3
if queued s3; then h_ok "store error (503): the entry is kept"; else h_fail "store error (503): the entry was dropped"; fi
h_assert_eq "$(status)" "kept" "store error: the state says kept"

# 5. A body too large keeps the entry and records a notice for that session.
answer 413
ship too-large s3
if queued s3; then h_ok "too large (413): the entry is kept"; else h_fail "too large (413): the entry was dropped"; fi
h_assert_eq "$(notices too-large:s3)" 1 "too large (413): a notice is recorded for the session"

# 6. A redirect is not followed: the bearer token would go wherever it points. A
# 302 is the case that matters, because urllib on its own follows it and resends
# the Authorization header.
answer 302
forget_requests
ship redirect s3
h_assert_eq "$(paths | tr '\n' ' ')" "/v1/captures/s3 " "a redirect is not followed"
if queued s3; then h_ok "a redirect: the entry is kept"; else h_fail "a redirect: the entry was dropped"; fi

# 7. The store already holds a longer copy: the entry is dropped.
answer 409
ship longer-held s3
if queued s3; then h_fail "a longer copy held (409): the entry is still queued"; else h_ok "a longer copy held (409): the entry is dropped"; fi

# 8. The token appears in no output, log, state file or process argument. The store
# holds its answer for a moment so the process list is read while a post is in flight.
answer 201
printf '2\n' >"$store/delay"
transcript s4 >/dev/null
( ship in-flight s4 ) &
job=$!
: >"$H_TMP/ps.txt"
for _ in $(seq 1 30); do ps -A -o args= >>"$H_TMP/ps.txt" 2>/dev/null; sleep 0.1; done
wait "$job"
rm -f "$store/delay"
h_assert_eq "$(paths | grep -c /v1/captures/s4)" 1 "the in-flight post reached the store"
if grep -q "$body" "$H_TMP/ps.txt"; then h_fail "the token appeared in a process argument"
else h_ok "the token appears in no process argument"; fi
if grep -rq "$body" "$H_TMP/run" "$base/state" "$base/queue" "$base/quarantine" 2>/dev/null; then
  h_fail "the token appeared in a launcher's output, log or state"
else h_ok "the token appears in no stdout, stderr, log, queue or state file"; fi

# 9. A secret the redactor misses is caught by the post-scan: the rendered copy goes
# to quarantine, a notice is recorded, and nothing is posted.
survivor_body=$(printf 'A%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30)
transcript s5 "the value gh""p_${survivor_body}_tail showed up" >/dev/null
forget_requests
ship survivor s5
h_assert_hook_run survivor "a secret survives redaction"
h_assert_eq "$(requests)" 0 "a secret survives redaction: nothing is posted"
if [ -f "$base/quarantine/s5.md" ]; then h_ok "a secret survives redaction: the rendered copy is quarantined"
else h_fail "a secret survives redaction: nothing in quarantine"; fi
h_assert_eq "$(notices quarantine:s5)" 1 "a secret survives redaction: a notice is recorded"
if queued s5; then h_fail "a secret survives redaction: the entry is still queued"; else h_ok "a secret survives redaction: the entry is dropped"; fi
h_assert_empty "$(ls "$base/state/outbox" 2>/dev/null)" "a secret survives redaction: no rendered copy outside quarantine"

# The same secret next to a NUL byte (a tool printed a binary file): the post-scan
# would skip the copy as binary, so the ship step removes NUL bytes first.
transcript s8 >/dev/null
python3 -c 'import json,sys
print(json.dumps({"type": "assistant", "timestamp": "2026-01-05T10:10:00.000Z", "cwd": "/srv/projects/demo-notes",
  "message": {"role": "assistant", "content": [{"type": "text", "text": "binary:\x00 and " + sys.argv[1]}]}}))' \
  "gh""p_${survivor_body}_tail" >>"$H_TMP/transcripts/s8.jsonl"
forget_requests
ship survivor-nul s8
h_assert_eq "$(requests)" 0 "a secret beside a NUL byte: nothing is posted"
if [ -f "$base/quarantine/s8.md" ]; then h_ok "a secret beside a NUL byte: the rendered copy is quarantined"
else h_fail "a secret beside a NUL byte: nothing in quarantine"; fi

# A later turn refreshes the pointer while its copy is in flight: the store stores
# the earlier copy, and the entry stays queued so the later turn is sent too.
transcript s9 >/dev/null
cat >"$store/hook" <<EOF
python3 -c 'import json,os,sys; p=sys.argv[1]; d=json.load(open(p)); json.dump(d, open(p+".new","w")); os.replace(p+".new", p)' "$queue/s9.json"
EOF
ship refreshed s9
if [ -f "$store/hook.ran" ]; then h_ok "a refresh during a send: the planted refresh ran"; else h_fail "a refresh during a send: the planted refresh never ran"; fi
if queued s9; then h_ok "a refresh during a send: the entry stays for the later turn"
else h_fail "a refresh during a send: the entry was dropped and the later turn lost"; fi
ship refreshed-2 s9
if queued s9; then h_fail "the next turn: the entry is still queued"; else h_ok "the next turn sends it and drops it"; fi

# 10. A transcript gone by drain time is a loss: a notice, and the entry dropped. The
# session that is firing keeps its pointer even with no transcript on disk yet.
python3 -c 'import json,sys; json.dump({"session_id": "gone", "transcript_path": sys.argv[1], "where": "desktop",
  "first_seen": "2026-01-01T00:00:00Z", "attempts": 0}, open(sys.argv[2], "w"))' "$H_TMP/transcripts/gone.jsonl" "$queue/gone.json"
ship loss nofile
h_assert_hook_run loss "a transcript gone at drain time"
if queued gone; then h_fail "a transcript gone: the entry is still queued"; else h_ok "a transcript gone: the entry is dropped"; fi
h_assert_eq "$(notices loss:gone)" 1 "a transcript gone: a loss notice is recorded"
if queued nofile; then h_ok "the firing session keeps its pointer while its transcript is not on disk"
else h_fail "the firing session's pointer was dropped"; fi
rm -f "$queue/nofile.json"

# 11. At most five queued entries per firing: the firing session first, then the five
# oldest.
# Oldest means first seen: the entries are written so that their names and the order
# they were created in both run the other way, and neither can pass for it.
forget_requests
for n in 1 2 3 4 5 6 7; do
  transcript "old$n" >/dev/null
  python3 -c 'import json,sys; json.dump({"session_id": sys.argv[1], "transcript_path": sys.argv[2], "where": "cloud",
    "first_seen": "2026-01-0%sT00:00:00Z" % (8 - int(sys.argv[3])), "attempts": 0}, open(sys.argv[4], "w"))' \
    "old$n" "$H_TMP/transcripts/old$n.jsonl" "$n" "$queue/old$n.json"
  sleep 0.01
done
transcript s6 >/dev/null
ship drain-cap s6
h_assert_eq "$(paths | tr '\n' ' ')" "/v1/captures/s6 /v1/captures/old7 /v1/captures/old6 /v1/captures/old5 /v1/captures/old4 /v1/captures/old3 " \
  "a firing sends its own session, then drains the five first seen, oldest first"
h_assert_eq "$(cd "$queue" && printf '%s\n' *.json | sort | tr '\n' ' ')" "old1.json old2.json " "the newer entries wait for the next firing"
h_assert_eq "$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r["path"].endswith("/old7"): print({k.lower(): v for k, v in r["headers"].items()}["x-capture-where"])' "$store/requests.jsonl")" \
  "cloud" "a drained entry is sent with where its own session ran"

# 11b. A store that hangs on the old entries: the firing session is posted first, and
# reaches the store long before the step's 120-second bound, whatever the old ones
# do; the old ones are kept, and no post is started that could not finish inside the
# bound. Five old ready entries each hang past the post timeout.
# They were first seen before the two entries left by case 11, so they are the
# five oldest.
forget_requests
for n in 1 2 3 4 5; do
  transcript "hang$n" >/dev/null
  python3 -c 'import json,sys; json.dump({"session_id": sys.argv[1], "transcript_path": sys.argv[2], "where": "desktop",
    "first_seen": "2026-01-0%sT00:00:00Z" % sys.argv[3], "attempts": 0}, open(sys.argv[4], "w"))' \
    "hang$n" "$H_TMP/transcripts/hang$n.jsonl" "$n" "$queue/hang$n.json"
done
printf '/v1/captures/hang 25\n' >"$store/slow"
transcript s10 >/dev/null
start=$(date +%s)
( ship hanging-store s10 ) &
job=$!
reached=""
while kill -0 "$job" 2>/dev/null; do
  if [ -z "$reached" ] && paths | grep -qx /v1/captures/s10; then reached=$(($(date +%s) - start)); fi
  sleep 0.5
done
wait "$job"
[ -n "$reached" ] || { paths | grep -qx /v1/captures/s10 && reached=$(($(date +%s) - start)); }
total=$(($(date +%s) - start))
rm -f "$store/slow"
h_assert_hook_run hanging-store "a store that hangs on the old entries"
h_assert_eq "$(paths | head -n 1)" "/v1/captures/s10" "a hanging store: the firing session is posted first"
if [ -n "$reached" ] && [ "$reached" -le 30 ]; then h_ok "a hanging store: the firing session reached the store in ${reached}s"
else h_fail "a hanging store: the firing session reached the store late or never (${reached:-never})"; fi
if queued s10; then h_fail "a hanging store: the firing session is still queued"; else h_ok "a hanging store: the firing session is stored and dropped"; fi
h_assert_eq "$(cd "$queue" && printf '%s\n' hang*.json | sort | tr '\n' ' ')" "hang1.json hang2.json hang3.json hang4.json hang5.json " \
  "a hanging store: the old entries are kept"
if [ "$total" -le 125 ]; then h_ok "a hanging store: the step ended inside its bound (${total}s)"
else h_fail "a hanging store: the step ran ${total}s"; fi
rm -f "$queue"/hang*.json

# 11c. An entry queued for another tenant is never posted under this home's key.
forget_requests
transcript other1 >/dev/null
python3 -c 'import json,sys; json.dump({"session_id": "other1", "transcript_path": sys.argv[1], "where": "desktop",
  "first_seen": "2025-12-01T00:00:00Z", "attempts": 0, "tenant": "tenant-z", "project_root": "/elsewhere", "repo": "/elsewhere/.git"},
  open(sys.argv[2], "w"))' "$H_TMP/transcripts/other1.jsonl" "$queue/other1.json"
transcript s11 >/dev/null
ship other-tenant s11
if paths | grep -qx /v1/captures/other1; then h_fail "another tenant's entry was posted under this home's key"
else h_ok "another tenant's entry is not posted under this home's key"; fi
if queued other1; then h_ok "another tenant's entry stays queued"; else h_fail "another tenant's entry was dropped"; fi
if paths | grep -qx /v1/captures/s11; then h_ok "this tenant's session is still posted"; else h_fail "this tenant's session was not posted"; fi
rm -f "$queue/other1.json"

# 12. A failing redactor self-test blocks every post and keeps the queue: nothing
# leaves the machine on a redactor that cannot prove itself.
h_apparatus_file lib/redact.py "$(cat "$src/lib/redact.py")

def self_test() -> int:  # planted by the test: a redactor that cannot prove itself
    return 1"
rm -f "$base/state/fetch.stamp"
transcript s7 >/dev/null
transcript keep1 >/dev/null
python3 -c 'import json,sys; json.dump({"session_id": "keep1", "transcript_path": sys.argv[1], "where": "desktop",
  "first_seen": "2025-12-01T00:00:00Z", "attempts": 0}, open(sys.argv[2], "w"))' "$H_TMP/transcripts/keep1.jsonl" "$queue/keep1.json"
forget_requests
ship selftest-fails s7
h_assert_hook_run selftest-fails "a failing self-test"
h_assert_eq "$(requests)" 0 "a failing self-test: nothing is posted"
if queued s7 && queued keep1; then h_ok "a failing self-test: the queue is kept"; else h_fail "a failing self-test: the queue was not kept"; fi
h_assert_eq "$(status)" "selftest-failed" "a failing self-test: the state says selftest-failed"
bad=$(git -C "$base/checkout-stable" rev-parse HEAD)
if [ -f "$base/state/selftest-$bad.ok" ]; then h_fail "a failing self-test was cached as a pass"
else h_ok "a failing self-test is not cached"; fi

# When anything failed, say whether the stand-in store was still alive and what it
# printed, so a failure on a CI runner can be told apart from a store that died.
if [ "$H_FAILS" -gt 0 ]; then
  ps -o pid=,ppid=,stat=,command= -p "$store_pid" 2>/dev/null | sed 's/^/diagnostic: store process at the end: /'
  if kill -0 "$store_pid" 2>/dev/null; then echo "diagnostic: the stand-in store was still running"
  else echo "diagnostic: the stand-in store had exited"; fi
  tail -n 20 "$store.stderr" 2>/dev/null | sed 's/^/diagnostic: store: /'
  tail -n 20 "$base/state/launcher.log" 2>/dev/null | sed 's/^/diagnostic: log: /'
fi

h_done
