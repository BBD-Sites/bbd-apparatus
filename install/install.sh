#!/usr/bin/env bash
# install/install.sh: the one command that puts the apparatus on every account home of
# a machine. Run from a checkout of this repository (it reads the published signers file
# and the redactor from the checkout it sits in):
#
#   bash install/install.sh --home DIR [--home DIR ...] --tenant ID \
#       --channel next|stable --token-file FILE
#   bash install/install.sh --uninstall --home DIR [--home DIR ...]
#
# The token is read from FILE, or from stdin when FILE is `-`. It is never taken as an
# argument (a process listing would show it), never printed, never logged, and never
# put in the environment of the `claude` commands this script runs. The summary shows
# the first six hex digits of its sha256, so the person can tell which token landed.
#
# Before any home: the excluded-homes record is read from the LOGIN home, the one the
# directory service names for the account (`dscl . -read /Users/<user> NFSHomeDirectory`
# on a Mac, the passwd entry elsewhere), never from $HOME, because a session in a
# secondary account home runs with HOME rewritten to that home. The record is
# <login home>/.claude/bbd-apparatus/excluded-homes, one absolute home path per line
# (an empty file means no home is excluded). With no record there, or no login home,
# EVERY home is refused: an installer that cannot see the seal must not install.
#
# Per home, with HOME and CLAUDE_CONFIG_DIR set to that home, in this order, and the
# home is refused with nothing written if any step fails:
#   1. the home is not listed, and not under a path listed, in that record;
#   2. <home>/.claude is not inside a git work tree, so tenant.env can never be tracked;
#   3. the redactor self-test passes in this checkout;
#   4. <home>/.claude/bbd-apparatus/allowed_signers is written from
#      plugin/allowed_signers (nothing installs while that file is missing or empty);
#   5. `claude plugin marketplace add <https URL>` unless the marketplace is known;
#   6. `claude plugin install bbd@bbd-apparatus --scope user` unless already enabled,
#      then enabledPlugins["bbd@bbd-apparatus"] must read true in settings.json;
#   7. autoUpdate: true on the marketplace's extraKnownMarketplaces entry in
#      settings.json (the key the docs give; the tenant template sets the same one);
#   8. tenant.env (0600, in a 0700 directory) with BBD_TENANT, BBD_TOKEN and
#      BBD_CHANNEL; BBD_INGEST_URL is left out until the store exists (task 3.1).
# A second run on an installed home changes nothing and says so. --uninstall reverses
# the enablement, removes the marketplace, tenant.env and the signers copy, and leaves
# the checkout, the queue and the state directory (pointer records only) in place.
#
# One line per home on stdout: `installed <home>`, `unchanged <home>: ...`,
# `refused <home>: <why>`, `removed <home>: ...`. Exit 0 when every home was installed
# or already was, 1 when any home was refused, 2 on a usage error. bash 3.2, git and
# python3 only, like everything else here.
set -u
umask 077

MARKETPLACE_URL="https://github.com/BBD-Sites/bbd-apparatus.git"
MARKETPLACE_NAME="bbd-apparatus"
MARKETPLACE_REPO="BBD-Sites/bbd-apparatus"
PLUGIN_ID="bbd@bbd-apparatus"
TOKEN_SHAPE='^bbdt_[A-Za-z0-9]{40}$'

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 2
checkout=$(cd "$here/.." && pwd -P) || exit 2

usage() {
  cat >&2 <<EOF
usage: bash install/install.sh --home DIR [--home DIR ...] --tenant ID --channel next|stable --token-file FILE
       bash install/install.sh --uninstall --home DIR [--home DIR ...]

  --home DIR         an account home (the directory that holds .claude); repeatable
  --tenant ID        the tenant id (letters, digits, . _ -; up to 64 characters)
  --channel NAME     next or stable
  --token-file FILE  the tenant token, read from FILE, or from stdin when FILE is -
  --uninstall        reverse the plugin enablement and remove tenant.env per home
EOF
  exit 2
}

die() {
  printf 'install: %s\n' "$*" >&2
  exit 2
}

# ---------------------------------------------------------------------------------
# Arguments.
homes=()
tenant=""
channel=""
token_file=""
uninstall=""
while [ $# -gt 0 ]; do
  case "$1" in
    --home) [ $# -ge 2 ] || usage; homes+=("$2"); shift 2 ;;
    --tenant) [ $# -ge 2 ] || usage; tenant=$2; shift 2 ;;
    --channel) [ $# -ge 2 ] || usage; channel=$2; shift 2 ;;
    --token-file) [ $# -ge 2 ] || usage; token_file=$2; shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    -h|--help) usage ;;
    *) printf 'install: unknown option: %s\n' "$1" >&2; usage ;;
  esac
done
[ "${#homes[@]}" -gt 0 ] || usage

for tool in claude git python3; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"
done

token=""
if [ -z "$uninstall" ]; then
  if [ -z "$tenant" ] || [ -z "$channel" ] || [ -z "$token_file" ]; then usage; fi
  case "$tenant" in
    [A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9._-]*) [ "${#tenant}" -le 64 ] || die "the tenant id is longer than 64 characters" ;;
    *) die "the tenant id may hold letters, digits, . _ and - only" ;;
  esac
  case "$channel" in next|stable) ;; *) die "the channel is next or stable" ;; esac
  if [ "$token_file" = - ]; then
    token=$(cat) || die "could not read the token from stdin"
  else
    [ -r "$token_file" ] || die "cannot read the token file"
    token=$(cat -- "$token_file") || die "could not read the token file"
  fi
  # One line, in the shape the contract gives (docs/launcher-contract.md, section 9), so
  # the launcher's log masking and the redactor recognize it wherever it might appear.
  # The match is anchored and the shape admits no newline, so a second line fails it.
  if ! [[ "$token" =~ $TOKEN_SHAPE ]]; then
    die "the token is not one line in the bbdt_ shape; nothing was written"
  fi
fi

# The published signers file. Nothing installs while it is missing or empty: the
# launcher would then run unsigned heads on this home (design D40, task 7.46).
# Found once here; every home is then refused with the reason, so the summary still
# has one line per home.
signers_src="$checkout/plugin/allowed_signers"
checkout_problem=""
if [ ! -f "$signers_src" ] || ! grep -q '[^[:space:]]' "$signers_src" 2>/dev/null; then
  checkout_problem="no signers file at $signers_src (missing or empty); nothing installs while no signers file exists (plugin/allowed_signers, task 7.46)"
elif [ ! -f "$checkout/bin/apparatus" ]; then
  checkout_problem="no bin/apparatus in $checkout; run this from a checkout of the apparatus repository"
fi

# The login home: where the account's directory entry says it is, never $HOME. A
# session in a secondary account home runs with HOME set to that home, so a record
# kept under $HOME would be a different file in every home, and the login home's,
# the one that holds the seal, would never be consulted. The rule is the one the
# maintainers' own tooling states once (hooks/lib/_login-home.sh in their substrate:
# `dscl . -read /Users/$(id -un) NFSHomeDirectory`, taken when it names a directory);
# off a Mac the passwd entry answers instead. BBD_INSTALL_LOGIN_HOME is a test-only
# override so the suite can name a fake login home; it is still required to exist.
login_home() {
  local user h=""
  if [ -n "${BBD_INSTALL_LOGIN_HOME:-}" ]; then
    h=$BBD_INSTALL_LOGIN_HOME
  else
    user=$(id -un) || return 1
    if command -v dscl >/dev/null 2>&1; then
      h=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    fi
    if [ -z "$h" ]; then
      h=$(python3 -c 'import pwd, sys; print(pwd.getpwnam(sys.argv[1]).pw_dir)' "$user" 2>/dev/null)
    fi
  fi
  [ -n "$h" ] && [ -d "$h" ] || return 1
  (cd "$h" && pwd -P)
}

# The excluded homes: a standing record at the login home, read once before any home
# is touched. A record beats a flag that has to be retyped: the homes the person
# chooses to skip do not change between runs, and a forgotten flag is exactly the
# failure the exclusion exists to prevent. A missing record is not "none excluded";
# an empty file is. With no record, or no login home, every home is refused below,
# install or uninstall.
seal_problem=""
excluded_file=""
excluded=""
if login=$(login_home); then
  excluded_file="$login/.claude/bbd-apparatus/excluded-homes"
  if [ -f "$excluded_file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%$'\r'}
      case "$line" in ''|'#'*) continue ;; esac
      if resolved=$(cd "$line" 2>/dev/null && pwd -P); then line=$resolved; fi
      excluded="$excluded$line
"
    done <"$excluded_file"
  else
    seal_problem="no excluded-homes record at $excluded_file; create it there, holding one absolute path per line for every home that must never carry the apparatus (an empty file means none), then run again"
  fi
else
  seal_problem="could not find the login home (the directory service names none for $(id -un)), so the excluded-homes record cannot be read; nothing was touched"
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/bbd-install.XXXXXX") || die "could not make a temp directory"
trap 'rm -rf "$work"' EXIT INT TERM HUP

# ---------------------------------------------------------------------------------
# Helpers.

# mask: the token shape replaced wherever it might appear in a command's output. The
# token is never given to any command run here, so this is a belt on top of braces.
mask() { sed -E 's/bbdt_[A-Za-z0-9]{40}/[token]/g'; }

# run_claude HOME CFG ARGS...: claude for one home, with that home's HOME and config
# dir set outright (an inherited CLAUDE_CONFIG_DIR would otherwise point every home's
# install at the invoking login's config). The token is a shell variable here, never
# exported, so it is not in claude's environment. Its output goes to a file; on
# failure the tail is shown, masked, on stderr.
run_claude() {
  local home=$1 cfg=$2 out="$work/claude.out"
  shift 2
  if env HOME="$home" CLAUDE_CONFIG_DIR="$cfg" claude "$@" </dev/null >"$out" 2>&1; then
    return 0
  fi
  printf 'install: claude %s failed for %s:\n' "$*" "$home" >&2
  tail -n 20 "$out" | mask | sed 's/^/    /' >&2
  return 1
}

# json_true FILE KEY...: 0 if FILE is JSON whose value at KEY... is exactly true.
json_true() {
  python3 - "$@" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        doc = json.load(f)
except Exception:
    sys.exit(1)
for k in sys.argv[2:]:
    if not isinstance(doc, dict) or k not in doc:
        sys.exit(1)
    doc = doc[k]
sys.exit(0 if doc is True else 1)
PY
}

# json_has FILE KEY...: 0 if FILE is JSON with a value at KEY....
json_has() {
  python3 - "$@" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        doc = json.load(f)
except Exception:
    sys.exit(1)
for k in sys.argv[2:]:
    if not isinstance(doc, dict) or k not in doc:
        sys.exit(1)
    doc = doc[k]
sys.exit(0)
PY
}

# settings_autoupdate SETTINGS: autoUpdate true on the marketplace's entry under
# extraKnownMarketplaces, keeping whatever source the CLI wrote there, and writing the
# tenant template's github source only when there is no entry at all. Prints changed
# or unchanged; exits 1 (printing why) when the file is not JSON, which is never
# overwritten. Atomic, and the file keeps its mode.
settings_autoupdate() {
  python3 - "$1" "$MARKETPLACE_NAME" "$MARKETPLACE_REPO" <<'PY'
import json, os, sys, tempfile
path, name, repo = sys.argv[1:4]
doc = {}
mode = 0o600
if os.path.exists(path):
    mode = os.stat(path).st_mode & 0o777
    try:
        with open(path, encoding="utf-8") as f:
            raw = f.read()
    except OSError:
        print("settings.json could not be read"); sys.exit(1)
    if raw.strip():
        try:
            doc = json.loads(raw)
        except ValueError:
            print("settings.json is not valid JSON, so it was left alone"); sys.exit(1)
if not isinstance(doc, dict):
    print("settings.json is not a JSON object, so it was left alone"); sys.exit(1)
mp = doc.get("extraKnownMarketplaces")
if not isinstance(mp, dict):
    mp = {}
    doc["extraKnownMarketplaces"] = mp
entry = mp.get(name)
if not isinstance(entry, dict):
    entry = {"source": {"source": "github", "repo": repo}}
    mp[name] = entry
if entry.get("autoUpdate") is True:
    print("unchanged"); sys.exit(0)
entry["autoUpdate"] = True
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".settings.")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
os.chmod(tmp, mode)
os.replace(tmp, path)
print("changed")
PY
}

# settings_forget SETTINGS: the uninstall's edit, removing the marketplace entry and
# any enablement of the plugin the CLI left behind. Prints changed or unchanged.
settings_forget() {
  python3 - "$1" "$MARKETPLACE_NAME" "$PLUGIN_ID" <<'PY'
import json, os, sys, tempfile
path, name, pid = sys.argv[1:4]
if not os.path.exists(path):
    print("unchanged"); sys.exit(0)
try:
    with open(path, encoding="utf-8") as f:
        raw = f.read()
    doc = json.loads(raw) if raw.strip() else {}
except Exception:
    print("settings.json is not valid JSON, so it was left alone"); sys.exit(1)
if not isinstance(doc, dict):
    print("unchanged"); sys.exit(0)
changed = False
for key, sub in (("extraKnownMarketplaces", name), ("enabledPlugins", pid)):
    d = doc.get(key)
    if isinstance(d, dict) and sub in d:
        del d[sub]
        changed = True
        if not d:
            del doc[key]
if not changed:
    print("unchanged"); sys.exit(0)
mode = os.stat(path).st_mode & 0o777
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".settings.")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
os.chmod(tmp, mode)
os.replace(tmp, path)
print("changed")
PY
}

# is_excluded HOME: 0 if HOME is, or is under, a path in the excluded-homes file.
is_excluded() {
  local home=$1 ex
  [ -n "$excluded" ] || return 1
  while IFS= read -r ex; do
    [ -n "$ex" ] || continue
    case "$home" in "$ex"|"$ex"/*) return 0 ;; esac
  done <<EOF
$excluded
EOF
  return 1
}

# in_work_tree DIR: 0 if DIR (or, while it does not exist yet, its nearest existing
# parent) is inside a git work tree; 1 if git says it is not, or that there is no
# repository there at all; 2 if git could not answer (a repository it refuses to read,
# say), which the caller treats as a refusal, because "could not tell" is not "outside".
# Git is asked, not .git looked for, because a worktree's .git is a file.
in_work_tree() {
  local probe=$1 answer
  while [ ! -d "$probe" ] && [ "$probe" != / ]; do probe=$(dirname "$probe"); done
  answer=$(git -C "$probe" rev-parse --is-inside-work-tree 2>"$work/git.err")
  case "$answer" in
    true) return 0 ;;
    false) return 1 ;;
  esac
  if grep -qi 'not a git repository' "$work/git.err" 2>/dev/null; then return 1; fi
  return 2
}

any_refused=""
any_done=""
refuse() { printf 'refused %s: %s\n' "$1" "$2"; any_refused=1; }

# ---------------------------------------------------------------------------------
# install_home HOME
install_home() {
  local given=$1 home cfg base signers env_file wanted changed="" r tmpf
  home=$(cd "$given" 2>/dev/null && pwd -P) || { refuse "$given" "not a directory"; return; }
  cfg="$home/.claude"
  base="$cfg/bbd-apparatus"
  signers="$base/allowed_signers"
  env_file="$base/tenant.env"

  if [ -n "$seal_problem" ]; then
    refuse "$home" "$seal_problem"
    return
  fi
  if is_excluded "$home"; then
    refuse "$home" "excluded by $excluded_file; nothing was touched"
    return
  fi
  if [ -n "$checkout_problem" ]; then
    refuse "$home" "$checkout_problem"
    return
  fi
  in_work_tree "$cfg"
  case $? in
    0) refuse "$home" "$cfg is inside a git work tree, where tenant.env could be tracked; nothing was written"; return ;;
    2) refuse "$home" "git could not say whether $cfg is outside every git work tree; nothing was written"
       sed 's/^/    /' "$work/git.err" >&2; return ;;
  esac
  # The redactor self-test runs first, with nothing written yet, so a checkout whose
  # redactor fails leaves the home exactly as it was.
  if ! env HOME="$home" CLAUDE_CONFIG_DIR="$cfg" PYTHONDONTWRITEBYTECODE=1 \
      python3 "$checkout/bin/apparatus" selftest >"$work/selftest.out" 2>&1; then
    refuse "$home" "the redactor self-test failed in $checkout; nothing was written"
    tail -n 5 "$work/selftest.out" | mask | sed 's/^/    /' >&2
    return
  fi

  mkdir -p "$base" 2>/dev/null || { refuse "$home" "could not create $base"; return; }
  chmod 700 "$base"
  # Each file is written beside its target and renamed into place, so a reader never
  # sees a half-written file and the mode (0600 from the umask) is set before the name is.
  if ! cmp -s "$signers_src" "$signers" 2>/dev/null; then
    if ! { tmpf=$(mktemp "$base/.allowed_signers.XXXXXX") && cat "$signers_src" >"$tmpf" && mv -f "$tmpf" "$signers"; }; then
      rm -f "${tmpf:-}"; refuse "$home" "could not write $signers"; return
    fi
    changed=1
  fi

  if ! json_has "$cfg/plugins/known_marketplaces.json" "$MARKETPLACE_NAME"; then
    run_claude "$home" "$cfg" plugin marketplace add "$MARKETPLACE_URL" \
      || { refuse "$home" "claude plugin marketplace add failed; tenant.env was not written"; return; }
    changed=1
  fi
  if ! json_true "$cfg/settings.json" enabledPlugins "$PLUGIN_ID"; then
    run_claude "$home" "$cfg" plugin install "$PLUGIN_ID" --scope user \
      || { refuse "$home" "claude plugin install failed; tenant.env was not written"; return; }
    if ! json_true "$cfg/settings.json" enabledPlugins "$PLUGIN_ID"; then
      refuse "$home" "$PLUGIN_ID is not enabled in $cfg/settings.json after the install; tenant.env was not written"
      return
    fi
    changed=1
  fi

  r=$(settings_autoupdate "$cfg/settings.json") || { refuse "$home" "$r; tenant.env was not written"; return; }
  [ "$r" = changed ] && changed=1
  if ! json_true "$cfg/settings.json" extraKnownMarketplaces "$MARKETPLACE_NAME" autoUpdate; then
    refuse "$home" "autoUpdate did not read true in $cfg/settings.json after writing it; tenant.env was not written"
    return
  fi

  wanted=$(printf 'BBD_TENANT=%s\nBBD_TOKEN=%s\nBBD_CHANNEL=%s\n' "$tenant" "$token" "$channel")
  if [ ! -f "$env_file" ] || [ "$(cat "$env_file" 2>/dev/null)" != "$wanted" ]; then
    if ! { tmpf=$(mktemp "$base/.tenant.env.XXXXXX") && printf '%s\n' "$wanted" >"$tmpf" && mv -f "$tmpf" "$env_file"; }; then
      rm -f "${tmpf:-}"; refuse "$home" "could not write $env_file"; return
    fi
    changed=1
  fi
  chmod 600 "$env_file" 2>/dev/null

  any_done=1
  if [ -n "$changed" ]; then
    printf 'installed %s\n' "$home"
  else
    printf 'unchanged %s: already installed\n' "$home"
  fi
}

# uninstall_home HOME
uninstall_home() {
  local given=$1 home cfg base removed="" r f
  home=$(cd "$given" 2>/dev/null && pwd -P) || { refuse "$given" "not a directory"; return; }
  cfg="$home/.claude"
  base="$cfg/bbd-apparatus"
  if [ -n "$seal_problem" ]; then
    refuse "$home" "$seal_problem"
    return
  fi
  if is_excluded "$home"; then
    refuse "$home" "excluded by $excluded_file; nothing was touched"
    return
  fi
  if json_true "$cfg/settings.json" enabledPlugins "$PLUGIN_ID" \
      || json_has "$cfg/plugins/installed_plugins.json" plugins "$PLUGIN_ID"; then
    run_claude "$home" "$cfg" plugin uninstall "$PLUGIN_ID" --scope user \
      || { refuse "$home" "claude plugin uninstall failed"; return; }
    removed=1
  fi
  if json_has "$cfg/plugins/known_marketplaces.json" "$MARKETPLACE_NAME"; then
    run_claude "$home" "$cfg" plugin marketplace remove "$MARKETPLACE_NAME" \
      || { refuse "$home" "claude plugin marketplace remove failed"; return; }
    removed=1
  fi
  r=$(settings_forget "$cfg/settings.json") || { refuse "$home" "$r"; return; }
  [ "$r" = changed ] && removed=1
  if json_true "$cfg/settings.json" enabledPlugins "$PLUGIN_ID"; then
    refuse "$home" "$PLUGIN_ID is still enabled in $cfg/settings.json"
    return
  fi
  for f in "$base/tenant.env" "$base/allowed_signers"; do
    if [ -e "$f" ]; then rm -f "$f" && removed=1; fi
  done
  any_done=1
  if [ -n "$removed" ]; then
    printf 'removed %s: plugin, marketplace, tenant.env and the signers copy; the checkout, queue and state under %s are kept\n' "$home" "$base"
  else
    printf 'unchanged %s: nothing to remove\n' "$home"
  fi
}

for h in "${homes[@]}"; do
  if [ -n "$uninstall" ]; then uninstall_home "$h"; else install_home "$h"; fi
done

if [ -z "$uninstall" ] && [ -n "$any_done" ]; then
  fp=$(printf '%s' "$token" | python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:6])')
  printf 'token fingerprint %s (first six hex digits of its sha256)\n' "$fp"
fi

[ -z "$any_refused" ]
