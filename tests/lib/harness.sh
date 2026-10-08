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
      # H_FAKE_GIT_FETCH=fail makes every fetch and clone fail as if offline;
      # =hang makes it sleep H_FAKE_GIT_HANG seconds (default 20), longer than any
      # bound under test. exec, so a kill of this pid reaches the sleep itself.
      cat <<'SH'
sub="" skip=""
for a in "$@"; do
  if [ -n "$skip" ]; then skip=""; continue; fi
  case "$a" in -C|-c) skip=1 ;; -*) ;; *) sub=$a; break ;; esac
done
case "$sub" in fetch|clone)
  case "${H_FAKE_GIT_FETCH:-}" in
    fail) echo "fatal: unable to access the remote (fake offline)" >&2; exit 128 ;;
    hang) exec sleep "${H_FAKE_GIT_HANG:-20}" ;;
  esac ;;
esac
SH
      # The launcher's URL is fixed and it ignores the home's git config, so the
      # fake git itself sends that URL to the local stand-in, and no test can ever
      # reach the real repository. The call log keeps the URL as the launcher wrote it.
      printf 'from=%q\nto=%q\n' "$H_APPARATUS_URL" "file://$tmp/apparatus.git"
      cat <<'SH'
args=()
for a in "$@"; do
  if [ "$a" = "$from" ]; then args+=("$to"); else args+=("$a"); fi
done
set -- ${args[@]+"${args[@]}"}
SH
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

# h_calls_reset NAME: forget a fake's recorded calls, so a test can assert on only
# the calls one step made.
h_calls_reset() {
  local tmp
  tmp=$(h_tmpdir)
  mkdir -p "$tmp/calls"
  : >"$tmp/calls/$1.log"
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
try:
    print(json.dumps(doc))
    sys.stdout.flush()
except BrokenPipeError:
    # A launcher that refuses early never reads its stdin; that is not an error here.
    sys.stdout = None
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

# ---------------------------------------------------------------------------------
# Launcher helpers. The bootstrap is run exactly as shipped: its URL is fixed, so the
# fake git maps that URL to a local bare repository, and every launch runs under
# `env -i`, so nothing from the machine running the tests (its own Claude Code
# variables, its real home and config) reaches the launcher.

H_APPARATUS_URL="https://github.com/BBD-Sites/bbd-apparatus.git"

# The bootstrap under test, as the plugin ships it.
h_bootstrap() {
  printf '%s\n' "$(h_repo_root)/plugin/launcher/bbd-launch.sh"
}

# h_fake_apparatus: a stand-in for the public apparatus repository, built from this
# working copy's launcher/, lib/, bin/, text/ and data/, with branches stable and next on a bare
# remote at $H_TMP/apparatus.git. Prints the source work tree. It installs the fake
# git first, because only the fake git sends the launcher's URL to the stand-in.
h_fake_apparatus() {
  local tmp src bare repo
  h_fake_bin git
  tmp=$(h_tmpdir)
  repo=$(h_repo_root)
  src="$tmp/apparatus-src"
  bare="$tmp/apparatus.git"
  h_git init -q --bare "$bare"
  h_git init -q "$src"
  git -C "$src" symbolic-ref HEAD refs/heads/stable
  (cd "$repo" && tar cf - --exclude __pycache__ launcher lib bin text data) | (cd "$src" && tar xf -)
  h_git -C "$src" add -A
  h_git -C "$src" commit -q -m "feat: apparatus"
  git -C "$src" push -q "$bare" stable:stable stable:next
  printf '%s\n' "$src"
}

# h_apparatus_file PATH CONTENT [BRANCH]: commit CONTENT at PATH in the fake
# apparatus and force-push it to BRANCH (default stable). Force, so a test can also
# publish history that does not descend from what a checkout holds.
h_apparatus_file() {
  local path=$1 content=$2 branch=${3:-stable} src
  src="$(h_tmpdir)/apparatus-src"
  mkdir -p "$(dirname "$src/$path")"
  printf '%s\n' "$content" >"$src/$path"
  chmod +x "$src/$path"
  h_git -C "$src" add -A
  h_git -C "$src" commit -q -m "test: $path"
  git -C "$src" push -q -f "$(h_tmpdir)/apparatus.git" "HEAD:refs/heads/$branch"
}

# h_plant_event TAG EVENT [BRANCH]: replace EVENT's script in the fake apparatus with
# one that appends "TAG EVENT ROOT WHERE" to $H_SENTINEL, so a test can see which
# checkout ran, for which project, and that it ran at all.
h_plant_event() {
  h_apparatus_file "launcher/events/$2.sh" "#!/usr/bin/env bash
printf '%s %s %s %s\\n' '$1' \"\$BBD_EVENT\" \"\$BBD_PROJECT_ROOT\" \"\$BBD_WHERE\" >>\"\$H_SENTINEL\"
exit 0" "${3:-stable}"
}

# h_fake_home NAME: an account home at $H_TMP/NAME with an empty .claude. Prints its
# path.
h_fake_home() {
  local home
  home="$(h_tmpdir)/$1"
  mkdir -p "$home/.claude"
  printf '%s\n' "$home"
}

# h_mark REPO TENANT [CHANNEL]: commit the vault marker in REPO (and push it), so
# every worktree of REPO carries it.
h_mark() {
  local repo=$1 tenant=$2 channel=${3:-stable}
  mkdir -p "$repo/.apparatus"
  python3 -c 'import json,sys; print(json.dumps({"schema": 1, "tenant": sys.argv[1], "channel": sys.argv[2], "rules": "RULES.md"}))' \
    "$tenant" "$channel" >"$repo/.apparatus/vault.json"
  git -C "$repo" add .apparatus/vault.json
  h_git -C "$repo" commit -q -m "chore: vault marker"
  git -C "$repo" push -q origin HEAD 2>/dev/null
}

# h_tenant_env HOME TENANT [LINE...]: the config file an install writes, 0600.
h_tenant_env() {
  local home=$1 tenant=$2 dir
  shift 2
  dir="$home/.claude/bbd-apparatus"
  mkdir -p "$dir"
  chmod 700 "$dir"
  { printf 'BBD_TENANT=%s\n' "$tenant"; for l in "$@"; do printf '%s\n' "$l"; done; } >"$dir/tenant.env"
  chmod 600 "$dir/tenant.env"
}

# h_launch NAME HOME [VAR=value ...] -- SCRIPT [ARG...]: run a launcher as Claude
# Code would, with stdin passed through, in a clean environment holding only PATH,
# HOME, TMPDIR, H_SENTINEL and the VARs given. Saves $H_TMP/run/NAME.out, .err,
# .code and .secs (wall time).
h_launch() {
  local name=$1 home=$2 tmp start vars=()
  shift 2
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do vars+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  tmp=$(h_tmpdir)
  mkdir -p "$tmp/run"
  start=$(date +%s)
  env -i PATH="$PATH" HOME="$home" TMPDIR="${TMPDIR:-/tmp}" LANG=C GIT_CONFIG_NOSYSTEM=1 \
    H_SENTINEL="$tmp/sentinel.log" ${vars[@]+"${vars[@]}"} "${BASH:-bash}" "$@" \
    >"$tmp/run/$name.out" 2>"$tmp/run/$name.err"
  echo $? >"$tmp/run/$name.code"
  echo $(($(date +%s) - start)) >"$tmp/run/$name.secs"
}

h_run_out() { cat "$(h_tmpdir)/run/$1.out"; }
h_run_code() { cat "$(h_tmpdir)/run/$1.code"; }
h_run_secs() { cat "$(h_tmpdir)/run/$1.secs"; }

# The planted events' record (empty if no checkout code ran).
h_sentinel() {
  local f
  f="$(h_tmpdir)/sentinel.log"
  [ -f "$f" ] && cat "$f"
  return 0
}

h_sentinel_reset() { : >"$(h_tmpdir)/sentinel.log"; }

# h_assert_hook_run NAME LABEL: exit 0, and stdout is empty or one JSON object, the
# only things a hook may print.
h_assert_hook_run() {
  local name=$1 label=$2 out
  h_assert_eq "$(h_run_code "$name")" 0 "$label: exits 0"
  out=$(h_run_out "$name")
  if [ -z "$out" ]; then
    h_ok "$label: prints nothing on stdout"
  elif printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if isinstance(d, dict) else 1)' 2>/dev/null; then
    h_ok "$label: prints only hook JSON on stdout"
  else
    h_fail "$label: printed something other than hook JSON on stdout"
  fi
}

# h_net_calls: recorded git calls that reach a remote or write a repository.
h_net_calls() {
  h_calls git | grep -E '(^| )(fetch|clone|pull|push|ls-remote|commit|init)( |$)' || true
}
