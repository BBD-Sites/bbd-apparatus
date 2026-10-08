#!/usr/bin/env bash
# Shared helpers for tests/test-*.sh. Source it; it defines functions and sets
# nothing else. Plain bash 3.2 and POSIX tools, because the tests must run on a
# stock Mac (no jq, no GNU coreutils) as well as on the Linux CI runner.

# The neutral identity every commit carries, including the ones tests make, so a
# fake repository never borrows the machine's own git identity.
H_GIT_NAME="apparatus maintainers"
H_GIT_EMAIL="apparatus-maintainers@users.noreply.github.com"

H_TMP=""
H_FAILS=0

# The repository under test, found from this file rather than the caller's cwd.
h_repo_root() {
  (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
}

# One temp directory per test process, removed on exit. Call h_init once at the top
# of a test, in the test's own shell: helpers are often called inside $(...), and a
# directory or trap made in that subshell would vanish with it. H_TMP_ROOT lets a
# run keep its scratch somewhere inspectable; the default is outside any work tree,
# which tests of the "refuse a tracked location" rule depend on.
h_init() {
  local root=${H_TMP_ROOT:-${TMPDIR:-/tmp}}
  mkdir -p "$root"
  H_TMP=$(mktemp -d "$root/apparatus-test.XXXXXX")
  H_TMP=$(cd "$H_TMP" && pwd -P)
  trap 'h_cleanup' EXIT
}

h_tmpdir() {
  if [ -z "$H_TMP" ]; then
    echo "harness: call h_init before any helper" >&2
    exit 1
  fi
  printf '%s\n' "$H_TMP"
}

h_cleanup() {
  if [ -n "$H_TMP" ] && [ -z "${H_KEEP_TMP:-}" ]; then
    rm -rf "$H_TMP"
  fi
}

# git with the neutral identity, for every commit a test makes.
h_git() {
  git -c user.name="$H_GIT_NAME" -c user.email="$H_GIT_EMAIL" \
      -c init.defaultBranch=main -c commit.gpgsign=false "$@"
}

# h_fake_repo NAME: a work tree at $H_TMP/NAME with one commit on main, pushed to a
# local bare remote at $H_TMP/NAME.git, so fetch and push can be exercised with no
# network. Prints the work tree path.
h_fake_repo() {
  local name=$1 tmp work bare
  tmp=$(h_tmpdir)
  work="$tmp/$name"
  bare="$tmp/$name.git"
  h_git init -q --bare "$bare"
  h_git init -q "$work"
  # Older git ignores init.defaultBranch; naming the branch explicitly keeps the
  # tests independent of the git version on the runner.
  git -C "$work" symbolic-ref HEAD refs/heads/main
  git -C "$work" config user.name "$H_GIT_NAME"
  git -C "$work" config user.email "$H_GIT_EMAIL"
  git -C "$work" config commit.gpgsign false
  printf '%s\n' "$name" >"$work/README.md"
  git -C "$work" add README.md
  h_git -C "$work" commit -q -m "chore: seed $name"
  git -C "$work" remote add origin "$bare"
  git -C "$work" push -q -u origin main 2>/dev/null
  printf '%s\n' "$work"
}

# h_fake_bin NAME: puts a NAME on PATH that appends its arguments, one call per line,
# to $H_TMP/calls/NAME.log. A fake git then runs the real git, so tests can assert
# which git calls happened (for example, that no fetch was attempted) without
# losing git's behaviour. A fake claude prints $H_FAKE_CLAUDE_STDOUT and exits with
# $H_FAKE_CLAUDE_EXIT (default 0), so tests never reach a real account.
h_fake_bin() {
  local name=$1 tmp real=""
  tmp=$(h_tmpdir)
  mkdir -p "$tmp/bin" "$tmp/calls"
  if [ "$name" = "git" ]; then
    real=$(h_real_bin git)
  fi
  {
    echo '#!/usr/bin/env bash'
    printf 'log=%q\n' "$tmp/calls/$name.log"
    cat <<'SH'
line=""
for a in "$@"; do line="$line$(printf "%q " "$a")"; done
printf "%s\n" "${line% }" >>"$log"
SH
    if [ -n "$real" ]; then
      printf 'exec %q "$@"\n' "$real"
    else
      cat <<'SH'
[ -n "${H_FAKE_CLAUDE_STDOUT:-}" ] && printf "%s\n" "$H_FAKE_CLAUDE_STDOUT"
exit "${H_FAKE_CLAUDE_EXIT:-0}"
SH
    fi
  } >"$tmp/bin/$name"
  chmod +x "$tmp/bin/$name"
  case ":$PATH:" in
    *":$tmp/bin:"*) ;;
    *) PATH="$tmp/bin:$PATH"; export PATH ;;
  esac
}

# The real binary behind a name, skipping this harness's own fakes, so a fake never
# execs itself.
h_real_bin() {
  local name=$1 tmp dir
  tmp=$(h_tmpdir)
  local IFS=:
  for dir in $PATH; do
    [ "$dir" = "$tmp/bin" ] && continue
    if [ -x "$dir/$name" ]; then
      printf '%s\n' "$dir/$name"
      return 0
    fi
  done
  return 1
}

# h_calls NAME: every recorded call of a fake, one per line (empty if none).
h_calls() {
  local tmp
  tmp=$(h_tmpdir)
  [ -f "$tmp/calls/$1.log" ] && cat "$tmp/calls/$1.log"
  return 0
}

# h_hook_json EVENT [key=value ...]: prints the JSON a Claude Code hook receives on
# stdin, to pipe into a launcher. The common fields default to fresh values; any
# key=value overrides one or adds an event field (prompt, source, model,
# last_assistant_message, stop_reason). python3 does the quoting because stock macOS
# has no jq and hand-built JSON breaks on a quote in a prompt.
h_hook_json() {
  local event=$1
  shift
  local tmp
  tmp=$(h_tmpdir)
  python3 - "$event" "$tmp" "$@" <<'PY'
import json, sys, uuid
event, tmp, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
sid = str(uuid.uuid4())
doc = {
    "session_id": sid,
    "prompt_id": str(uuid.uuid4()),
    "transcript_path": "%s/transcripts/%s.jsonl" % (tmp, sid),
    "cwd": tmp,
    "hook_event_name": event,
}
for pair in pairs:
    key, sep, value = pair.partition("=")
    if not sep:
        sys.exit("h_hook_json: expected key=value, got %r" % pair)
    doc[key] = value
print(json.dumps(doc))
PY
}

# h_json_field FIELD: reads JSON on stdin and prints one top-level field.
h_json_field() {
  python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print("" if v is None else v)' "$1"
}

# Assertions record a failure and keep going, so one run reports every broken case.
h_fail() {
  printf 'not ok: %s\n' "$*"
  H_FAILS=$((H_FAILS + 1))
}

h_ok() {
  printf 'ok: %s\n' "$*"
}

h_assert_eq() {
  if [ "$1" = "$2" ]; then h_ok "$3"; else h_fail "$3 (expected [$2], got [$1])"; fi
}

h_assert_empty() {
  if [ -z "$1" ]; then h_ok "$2"; else h_fail "$2"; printf '%s\n' "$1" | sed 's/^/    /'; fi
}

h_assert_nonempty() {
  if [ -n "$1" ]; then h_ok "$2"; else h_fail "$2 (got nothing)"; fi
}

# Ends a test: non-zero if any assertion failed, which tests/run.sh reports as FAIL.
h_done() {
  if [ "$H_FAILS" -gt 0 ]; then
    printf '%s assertion(s) failed\n' "$H_FAILS"
    exit 1
  fi
  exit 0
}
