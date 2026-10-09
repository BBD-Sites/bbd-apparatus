#!/usr/bin/env bash
# The one-command installer (install/install.sh), run against fake account homes with
# a fake `claude` on PATH that records its calls and writes the files the real CLI
# writes for the four plugin commands the installer uses. Nothing here reaches a real
# home or a real account: every home is a directory under the test's temp directory,
# and the installer is run under `env -i` with a fake login home.
#
# What is proved: an install writes the signers copy, enables the plugin at user scope
# and verifies it, turns the marketplace's autoUpdate on in the home's settings, and
# writes tenant.env (0600, in a 0700 directory) with BBD_TENANT, BBD_TOKEN and
# BBD_CHANNEL and nothing else; the token is never on stdout, on stderr, in any file
# the installer leaves, or in the environment of any `claude` it runs; a second run
# changes nothing and says so; it refuses a home whose config is inside a git work
# tree, a checkout with no signers file (or an empty one), a redactor self-test that
# fails, a plugin the CLI did not enable, and a home listed in the LOGIN home's
# excluded-homes record; the record is read from the login home the directory service
# names, never from $HOME (a session in a secondary account home rewrites HOME), and
# with no record there every home is refused, so the seal fails closed; and
# --uninstall reverses the enablement, removes the marketplace and tenant.env, and
# leaves the vault repository alone.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

root=$(h_repo_root)
installer="$root/install/install.sh"
tmp=$(h_tmpdir)
URL="https://github.com/BBD-Sites/bbd-apparatus.git"
PID="bbd@bbd-apparatus"

if [ ! -f "$installer" ]; then
  h_fail "install/install.sh exists"
  h_done
fi

# A fake claude. It logs every call like h_fake_bin does, saves its environment per
# call (so the test can see the token never reached it), and writes what the real CLI
# writes: known_marketplaces.json and the settings' extraKnownMarketplaces entry on a
# marketplace add; enabledPlugins and installed_plugins.json on an install; the
# reverse on uninstall and marketplace remove. H_FAKE_CLAUDE_FAIL=marketplace-add or
# install makes that command fail; =install-silent makes install exit 0 and write
# nothing, the case the installer's own verification is for.
make_fake_claude() {
  mkdir -p "$tmp/bin" "$tmp/calls" "$tmp/claude-env"
  {
    echo '#!/usr/bin/env bash'
    printf 'log=%q\nenvdir=%q\n' "$tmp/calls/claude.log" "$tmp/claude-env"
    cat <<'SH'
line=""
for a in "$@"; do line="$line$(printf "%q " "$a")"; done
printf "%s\n" "${line% }" >>"$log"
env >"$envdir/env.$$"
cmd=""
case "$1 $2 ${3:-}" in
  "plugin marketplace add") cmd=marketplace-add; arg=${4:-} ;;
  "plugin marketplace remove") cmd=marketplace-remove; arg=${4:-} ;;
  "plugin install "*) cmd=install; arg=$3
    [ "${4:-}" = "--scope" ] && [ "${5:-}" = "user" ] || { echo "fake claude: install without --scope user" >&2; exit 2; } ;;
  "plugin uninstall "*) cmd=uninstall; arg=$3
    [ "${4:-}" = "--scope" ] && [ "${5:-}" = "user" ] || { echo "fake claude: uninstall without --scope user" >&2; exit 2; } ;;
  *) echo "fake claude: unexpected command: $*" >&2; exit 2 ;;
esac
python3 - "$cmd" "$arg" <<'PY'
import json, os, sys, time
cmd, arg = sys.argv[1], sys.argv[2]
cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.environ["HOME"], ".claude")
settings_p = os.path.join(cfg, "settings.json")
plugins_d = os.path.join(cfg, "plugins")
known_p = os.path.join(plugins_d, "known_marketplaces.json")
inst_p = os.path.join(plugins_d, "installed_plugins.json")
fail = os.environ.get("H_FAKE_CLAUDE_FAIL", "")
now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

def load(p, default):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default

def save(p, d):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=2)
        f.write("\n")

if cmd == "marketplace-add":
    if fail == "marketplace-add":
        sys.exit("fake claude: could not add the marketplace")
    name = "bbd-apparatus"
    source = {"source": "git", "url": arg}
    known = load(known_p, {})
    known[name] = {"source": source, "installLocation": os.path.join(plugins_d, "marketplaces", name), "lastUpdated": now}
    save(known_p, known)
    s = load(settings_p, {})
    s.setdefault("extraKnownMarketplaces", {})[name] = {"source": source}
    save(settings_p, s)
elif cmd == "install":
    known = load(known_p, {})
    if arg.split("@", 1)[1] not in known:
        sys.exit("fake claude: marketplace not found")
    if fail == "install":
        sys.exit("fake claude: install failed")
    if fail == "install-silent":
        sys.exit(0)
    s = load(settings_p, {})
    s.setdefault("enabledPlugins", {})[arg] = True
    save(settings_p, s)
    inst = load(inst_p, {"version": 2, "plugins": {}})
    inst.setdefault("plugins", {})[arg] = [{"scope": "user", "installPath": os.path.join(plugins_d, "cache", arg), "version": "3", "installedAt": now}]
    save(inst_p, inst)
elif cmd == "uninstall":
    s = load(settings_p, {})
    s.get("enabledPlugins", {}).pop(arg, None)
    save(settings_p, s)
    inst = load(inst_p, {"version": 2, "plugins": {}})
    inst.get("plugins", {}).pop(arg, None)
    save(inst_p, inst)
elif cmd == "marketplace-remove":
    known = load(known_p, {})
    known.pop(arg, None)
    save(known_p, known)
    s = load(settings_p, {})
    s.get("extraKnownMarketplaces", {}).pop(arg, None)
    save(settings_p, s)
PY
SH
  } >"$tmp/bin/claude"
  chmod +x "$tmp/bin/claude"
  case ":$PATH:" in
    *":$tmp/bin:"*) ;;
    *) PATH="$tmp/bin:$PATH"; export PATH ;;
  esac
}

# assert_absent PATH LABEL: nothing exists at PATH.
assert_absent() {
  if [ ! -e "$1" ]; then h_ok "$2"; else h_fail "$2 ($1 exists)"; fi
}

mode_of() {
  case "$(uname)" in
    Darwin) stat -f '%Lp' "$1" ;;
    *) stat -c '%a' "$1" ;;
  esac
}

# json_true FILE KEY...: 0 if the value at KEY... is exactly true.
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

# json_get FILE KEY...: the JSON value at KEY..., or "missing".
json_get() {
  python3 - "$@" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        doc = json.load(f)
except Exception:
    print("missing"); sys.exit(0)
for k in sys.argv[2:]:
    if not isinstance(doc, dict) or k not in doc:
        print("missing"); sys.exit(0)
    doc = doc[k]
print(json.dumps(doc, sort_keys=True))
PY
}

# tree_sum DIR: one checksum over every file's path, mode and content under DIR.
tree_sum() {
  (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s ' "$f" "$(mode_of "$f")"; cksum <"$f"
  done) | cksum
}

# run_install NAME [VAR=value ...] -- ARGS...: the installer under env -i, exactly as
# h_launch runs a launcher, with HOME set to a secondary account home (the shape a
# session in one of several account homes has) and the login home named through the
# installer's test-only override, so the record it reads must be the login home's.
run_install() {
  local name=$1
  shift
  h_launch "$name" "$invoking" BBD_INSTALL_LOGIN_HOME="$login" "$@"
}

# The planted token is assembled at run time, so no token shape is ever committed.
body40=$(printf 'Q%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)
token="bbdt""_$body40"
tokfile="$tmp/token.txt"
(umask 077 && printf '%s\n' "$token" >"$tokfile")

make_fake_claude
login=$(h_fake_home login)
invoking=$(h_fake_home parall-homes/other)
record="$login/.claude/bbd-apparatus/excluded-homes"
homeA=$(h_fake_home home-a)
homeB=$(h_fake_home home-b)
# A vault repository, to show an uninstall leaves it alone.
vault=$(h_fake_repo vault)
vault_head=$(git -C "$vault" rev-parse HEAD)

# ---------------------------------------------------------------------------------
# 0. The seal fails closed. With no excluded-homes record at the login home, every
# home is refused and the line says where to create the record and what it holds; a
# record in the invoking HOME is not the login home's and counts for nothing.
mkdir -p "$invoking/.claude/bbd-apparatus"
printf '%s\n' "$homeA" >"$invoking/.claude/bbd-apparatus/excluded-homes"
run_install norecord -- "$installer" --home "$homeA" --home "$homeB" --tenant t-one --channel next --token-file "$tokfile"
h_assert_eq "$(h_run_code norecord)" 1 "no record: exits 1"
out=$(h_run_out norecord)
h_assert_eq "$(printf '%s\n' "$out" | grep -c '^refused ')" 2 "no record: every home is refused"
case "$out" in *"refused $homeA: "*"$record"*"one absolute"*) h_ok "no record: the line names the record to create and what it holds" ;; *) h_fail "no record: the line does not say where to create the record: $out" ;; esac
assert_absent "$homeA/.claude/bbd-apparatus" "no record: nothing written under home A"
assert_absent "$homeB/.claude/bbd-apparatus" "no record: nothing written under home B"
h_assert_empty "$(h_calls claude)" "no record: no claude call"
run_install nologin BBD_INSTALL_LOGIN_HOME="$tmp/nowhere" -- "$installer" --home "$homeA" --tenant t-one --channel next --token-file "$tokfile"
h_assert_eq "$(h_run_code nologin)" 1 "no login home: exits 1"
case "$(h_run_out nologin)" in *"refused $homeA: "*"login home"*) h_ok "no login home: refused, naming the login home" ;; *) h_fail "no login home: not refused: $(h_run_out nologin)" ;; esac
h_assert_empty "$(h_calls claude)" "no login home: no claude call"
run_install norecord-un -- "$installer" --uninstall --home "$homeA"
h_assert_eq "$(h_run_code norecord-un)" 1 "no record: an uninstall is refused too"

# An empty record at the login home means no home is excluded. The invoking HOME's
# record still names home A, and is ignored: home A installs.
mkdir -p "$login/.claude/bbd-apparatus"
: >"$record"

# ---------------------------------------------------------------------------------
# 1. Install on two homes.
run_install one -- "$installer" --home "$homeA" --home "$homeB" --tenant t-one --channel next --token-file "$tokfile"
h_assert_eq "$(h_run_code one)" 0 "install: exits 0 (the invoking HOME's record naming home A counts for nothing)"
out=$(h_run_out one)
h_assert_eq "$(printf '%s\n' "$out" | grep -c '^installed ')" 2 "install: one installed line per home"
case "$out" in *"installed $homeA"*) h_ok "install: names home A" ;; *) h_fail "install: does not name home A" ;; esac
case "$out" in *"installed $homeB"*) h_ok "install: names home B" ;; *) h_fail "install: does not name home B" ;; esac

for home in "$homeA" "$homeB"; do
  base="$home/.claude/bbd-apparatus"
  h_assert_eq "$(mode_of "$base")" 700 "install: $(basename "$home") state dir is 0700"
  h_assert_eq "$(mode_of "$base/tenant.env")" 600 "install: $(basename "$home") tenant.env is 0600"
  h_assert_eq "$(cat "$base/tenant.env")" "BBD_TENANT=t-one
BBD_TOKEN=$token
BBD_CHANNEL=next" "install: $(basename "$home") tenant.env carries tenant, token and channel only (no BBD_INGEST_URL yet)"
  if cmp -s "$base/allowed_signers" "$root/plugin/allowed_signers"; then
    h_ok "install: $(basename "$home") allowed_signers is the published file"
  else
    h_fail "install: $(basename "$home") allowed_signers differs from plugin/allowed_signers"
  fi
  if json_true "$home/.claude/settings.json" enabledPlugins "$PID"; then
    h_ok "install: $(basename "$home") plugin enabled at user scope"
  else
    h_fail "install: $(basename "$home") plugin not enabled in settings.json"
  fi
  if json_true "$home/.claude/settings.json" extraKnownMarketplaces bbd-apparatus autoUpdate; then
    h_ok "install: $(basename "$home") marketplace autoUpdate is true"
  else
    h_fail "install: $(basename "$home") marketplace autoUpdate is not true"
  fi
  h_assert_eq "$(json_get "$home/.claude/settings.json" extraKnownMarketplaces bbd-apparatus source)" \
    "$(json_get "$home/.claude/plugins/known_marketplaces.json" bbd-apparatus source)" \
    "install: $(basename "$home") the marketplace source the CLI wrote is kept beside autoUpdate"
done

calls=$(h_calls claude)
h_assert_eq "$(printf '%s\n' "$calls" | grep -c .)" 4 "install: four claude calls for two homes"
h_assert_eq "$(printf '%s\n' "$calls" | sed -n 1p)" "plugin marketplace add $URL" "install: the marketplace is added by its https URL first"
h_assert_eq "$(printf '%s\n' "$calls" | sed -n 2p)" "plugin install $PID --scope user" "install: then the plugin at user scope"
homes_seen=$(grep -l "^HOME=$homeA\$" "$tmp"/claude-env/env.* | wc -l | tr -d ' ')
h_assert_eq "$homes_seen" 2 "install: claude ran twice under home A's HOME"
cfg_seen=$(grep -l "^CLAUDE_CONFIG_DIR=$homeA/.claude\$" "$tmp"/claude-env/env.* | wc -l | tr -d ' ')
h_assert_eq "$cfg_seen" 2 "install: and with CLAUDE_CONFIG_DIR set to that home's .claude"

# The token: in tenant.env and the token file, and nowhere else.
token_elsewhere() {
  grep -rl -F -e "$token" "$tmp" 2>/dev/null | grep -v -e '/tenant.env$' -e '/token.txt$' || true
}
h_assert_empty "$(token_elsewhere)" "install: the token is in no file but tenant.env (stdout, stderr and claude's environment included)"
h_assert_empty "$(grep -l '^BBD_TOKEN=' "$tmp"/claude-env/env.* 2>/dev/null || true)" "install: no claude ran with BBD_TOKEN in its environment"
case "$(h_run_out one)$(cat "$tmp/run/one.err")" in
  *"$body40"*) h_fail "install: the token body reached stdout or stderr" ;;
  *) h_ok "install: stdout and stderr carry no token" ;;
esac

# ---------------------------------------------------------------------------------
# 2. A second run changes nothing and says so.
sumA=$(tree_sum "$homeA/.claude")
h_calls_reset claude
run_install two -- "$installer" --home "$homeA" --home "$homeB" --tenant t-one --channel next --token-file "$tokfile"
h_assert_eq "$(h_run_code two)" 0 "rerun: exits 0"
h_assert_eq "$(h_run_out two | grep -c '^unchanged .*already installed')" 2 "rerun: says each home is already installed"
h_assert_empty "$(h_calls claude)" "rerun: no claude call"
h_assert_eq "$(tree_sum "$homeA/.claude")" "$sumA" "rerun: nothing under the home's .claude changed"

# A changed channel rewrites tenant.env and nothing else.
run_install three -- "$installer" --home "$homeA" --tenant t-one --channel stable --token-file "$tokfile"
h_assert_eq "$(h_run_code three)" 0 "channel change: exits 0"
case "$(h_run_out three)" in *"installed $homeA"*) h_ok "channel change: says installed" ;; *) h_fail "channel change: did not say installed" ;; esac
h_assert_eq "$(sed -n 3p "$homeA/.claude/bbd-apparatus/tenant.env")" "BBD_CHANNEL=stable" "channel change: tenant.env carries the new channel"
h_assert_eq "$(mode_of "$homeA/.claude/bbd-apparatus/tenant.env")" 600 "channel change: tenant.env is still 0600"
h_assert_empty "$(h_calls claude)" "channel change: no claude call"

# ---------------------------------------------------------------------------------
# 3. Refusals. Each leaves the home untouched and runs no claude.
h_calls_reset claude

# a. The home's config is inside a git work tree.
homeC="$vault/home-c"
mkdir -p "$homeC/.claude"
run_install wt -- "$installer" --home "$homeC" --tenant t-one --channel next --token-file "$tokfile"
h_assert_eq "$(h_run_code wt)" 1 "work tree: exits 1"
case "$(h_run_out wt)" in *"refused $homeC"*"work tree"*) h_ok "work tree: refused, and says why" ;; *) h_fail "work tree: not refused as inside a work tree: $(h_run_out wt)" ;; esac
assert_absent "$homeC/.claude/bbd-apparatus" "work tree: nothing written"
h_assert_empty "$(h_calls claude)" "work tree: no claude call"

# b. A home in the login home's excluded-homes record, and a home under one, while
# HOME is a secondary account home that holds no such record.
homeD=$(h_fake_home home-d)
homeE=$(h_fake_home home-e)
mkdir -p "$homeD/sub/.claude"
rm -f "$invoking/.claude/bbd-apparatus/excluded-homes"
printf '# the homes the person chooses to skip\n%s\n' "$homeD" >"$record"
run_install ex -- "$installer" --home "$homeD" --home "$homeD/sub" --home "$homeE" --tenant t-one --channel next --token-file "$tokfile"
h_assert_eq "$(h_run_code ex)" 1 "excluded: exits 1 when any home is refused"
out=$(h_run_out ex)
case "$out" in *"refused $homeD:"*"excluded"*) h_ok "excluded: the listed home is refused as excluded" ;; *) h_fail "excluded: listed home not refused: $out" ;; esac
case "$out" in *"refused $homeD/sub:"*"excluded"*) h_ok "excluded: a home under a listed one is refused too" ;; *) h_fail "excluded: home under a listed one not refused: $out" ;; esac
case "$out" in *"installed $homeE"*) h_ok "excluded: the other home in the same run is installed" ;; *) h_fail "excluded: the other home was not installed: $out" ;; esac
assert_absent "$homeD/.claude/bbd-apparatus" "excluded: nothing written under the excluded homes"
assert_absent "$homeD/sub/.claude/bbd-apparatus" "excluded: nothing written under the excluded homes"
h_assert_empty "$(grep -l "^HOME=$homeD" "$tmp"/claude-env/env.* 2>/dev/null || true)" "excluded: no claude ran under an excluded home"

# c. No signers file, or an empty one, in the checkout the installer runs from.
copy_checkout() {
  local dst="$tmp/$1"
  mkdir -p "$dst"
  (cd "$root" && tar cf - --exclude __pycache__ install bin lib plugin) | (cd "$dst" && tar xf -)
  printf '%s\n' "$dst"
}
nosig=$(copy_checkout copy-nosigners)
rm -f "$nosig/plugin/allowed_signers"
homeF=$(h_fake_home home-f)
h_calls_reset claude
run_install nosig -- "$nosig/install/install.sh" --home "$homeF" --tenant t-one --channel next --token-file "$tokfile"
h_assert_eq "$(h_run_code nosig)" 1 "no signers: exits 1"
case "$(h_run_out nosig)$(cat "$tmp/run/nosig.err")" in *"allowed_signers"*) h_ok "no signers: refused, naming the file" ;; *) h_fail "no signers: refusal does not name allowed_signers" ;; esac
assert_absent "$homeF/.claude/bbd-apparatus" "no signers: nothing written"
h_assert_empty "$(h_calls claude)" "no signers: no claude call"
emptysig=$(copy_checkout copy-emptysigners)
: >"$emptysig/plugin/allowed_signers"
run_install emptysig -- "$emptysig/install/install.sh" --home "$homeF" --tenant t-one --channel next --token-file "$tokfile"
h_assert_eq "$(h_run_code emptysig)" 1 "empty signers: exits 1"
assert_absent "$homeF/.claude/bbd-apparatus" "empty signers: nothing written"
h_assert_empty "$(h_calls claude)" "empty signers: no claude call"

# d. The redactor self-test fails in the checkout.
bad=$(copy_checkout copy-badredact)
printf 'def self_test():\n    return 1\n' >"$bad/lib/redact.py"
homeG=$(h_fake_home home-g)
run_install bad -- "$bad/install/install.sh" --home "$homeG" --tenant t-one --channel next --token-file "$tokfile"
h_assert_eq "$(h_run_code bad)" 1 "self-test fails: exits 1"
case "$(h_run_out bad)" in *"refused $homeG:"*"self-test"*) h_ok "self-test fails: refused, naming the self-test" ;; *) h_fail "self-test fails: not refused: $(h_run_out bad)" ;; esac
assert_absent "$homeG/.claude/bbd-apparatus/tenant.env" "self-test fails: no tenant.env"
h_assert_empty "$(h_calls claude)" "self-test fails: no claude call (the self-test runs before anything is enabled)"

# e. The CLI returns success but did not enable the plugin.
homeH=$(h_fake_home home-h)
run_install silent H_FAKE_CLAUDE_FAIL=install-silent -- "$installer" --home "$homeH" --tenant t-one --channel next --token-file "$tokfile"
h_assert_eq "$(h_run_code silent)" 1 "not enabled: exits 1"
case "$(h_run_out silent)" in *"refused $homeH:"*"not enabled"*) h_ok "not enabled: refused, saying the plugin is not enabled" ;; *) h_fail "not enabled: not refused: $(h_run_out silent)" ;; esac
assert_absent "$homeH/.claude/bbd-apparatus/tenant.env" "not enabled: no tenant.env"

# f. The marketplace add fails.
homeI=$(h_fake_home home-i)
run_install mpfail H_FAKE_CLAUDE_FAIL=marketplace-add -- "$installer" --home "$homeI" --tenant t-one --channel next --token-file "$tokfile"
h_assert_eq "$(h_run_code mpfail)" 1 "marketplace add fails: exits 1"
case "$(h_run_out mpfail)" in *"refused $homeI:"*) h_ok "marketplace add fails: refused" ;; *) h_fail "marketplace add fails: not refused: $(h_run_out mpfail)" ;; esac
assert_absent "$homeI/.claude/bbd-apparatus/tenant.env" "marketplace add fails: no tenant.env"

# ---------------------------------------------------------------------------------
# 4. The token from stdin, and the usage errors.
homeJ=$(h_fake_home home-j)
printf '%s\n' "$token" | run_install stdin -- "$installer" --home "$homeJ" --tenant t-one --channel stable --token-file -
h_assert_eq "$(h_run_code stdin)" 0 "token on stdin: exits 0"
h_assert_eq "$(sed -n 2p "$homeJ/.claude/bbd-apparatus/tenant.env")" "BBD_TOKEN=$token" "token on stdin: tenant.env carries it"

run_install u1 -- "$installer" --home "$homeJ" --channel next --token-file "$tokfile"
h_assert_eq "$(h_run_code u1)" 2 "usage: no --tenant is a usage error"
run_install u2 -- "$installer" --home "$homeJ" --tenant t-one --channel beta --token-file "$tokfile"
h_assert_eq "$(h_run_code u2)" 2 "usage: a channel other than next or stable is a usage error"
run_install u3 -- "$installer" --home "$homeJ" --tenant t-one --channel next --token "$token"
h_assert_eq "$(h_run_code u3)" 2 "usage: the token is never taken as an argument"
run_install u4 -- "$installer" --tenant t-one --channel next --token-file "$tokfile"
h_assert_eq "$(h_run_code u4)" 2 "usage: no --home is a usage error"
run_install u5 -- "$installer" --home "$homeJ" --tenant t-one --channel next --token-file "$tmp/no-such-file"
h_assert_eq "$(h_run_code u5)" 2 "usage: an unreadable token file is a usage error"
printf 'not-a-token\n' | run_install u6 -- "$installer" --home "$homeJ" --tenant t-one --channel next --token-file -
h_assert_eq "$(h_run_code u6)" 2 "usage: a token not in the bbdt_ shape is refused"

# ---------------------------------------------------------------------------------
# 5. Uninstall reverses the enablement and removes tenant.env; the vault is untouched.
h_calls_reset claude
run_install un -- "$installer" --uninstall --home "$homeA"
h_assert_eq "$(h_run_code un)" 0 "uninstall: exits 0"
case "$(h_run_out un)" in *"removed $homeA"*) h_ok "uninstall: says removed" ;; *) h_fail "uninstall: did not say removed: $(h_run_out un)" ;; esac
assert_absent "$homeA/.claude/bbd-apparatus/tenant.env" "uninstall: tenant.env is gone"
assert_absent "$homeA/.claude/bbd-apparatus/allowed_signers" "uninstall: the signers copy is gone"
h_assert_eq "$(json_get "$homeA/.claude/settings.json" enabledPlugins "$PID")" missing "uninstall: the plugin is no longer enabled"
h_assert_eq "$(json_get "$homeA/.claude/settings.json" extraKnownMarketplaces bbd-apparatus)" missing "uninstall: the marketplace entry is gone from settings"
h_assert_eq "$(json_get "$homeA/.claude/plugins/known_marketplaces.json" bbd-apparatus)" missing "uninstall: the marketplace is no longer known"
calls=$(h_calls claude)
h_assert_eq "$(printf '%s\n' "$calls" | sed -n 1p)" "plugin uninstall $PID --scope user" "uninstall: the plugin is uninstalled at user scope"
h_assert_eq "$(printf '%s\n' "$calls" | sed -n 2p)" "plugin marketplace remove bbd-apparatus" "uninstall: then the marketplace is removed"
h_calls_reset claude
run_install un2 -- "$installer" --uninstall --home "$homeA"
h_assert_eq "$(h_run_code un2)" 0 "uninstall again: exits 0"
case "$(h_run_out un2)" in *"unchanged $homeA"*"nothing to remove"*) h_ok "uninstall again: says there is nothing to remove" ;; *) h_fail "uninstall again: unexpected output: $(h_run_out un2)" ;; esac
h_assert_empty "$(h_calls claude)" "uninstall again: no claude call"
# An excluded home is not touched by an uninstall either.
run_install unex -- "$installer" --uninstall --home "$homeD"
h_assert_eq "$(h_run_code unex)" 1 "uninstall: an excluded home is refused"

h_assert_eq "$(git -C "$vault" rev-parse HEAD)" "$vault_head" "vault: HEAD unchanged through install and uninstall"
h_assert_empty "$(git -C "$vault" status --porcelain --untracked-files=all -- . ':!home-c')" "vault: work tree unchanged"

# Finally, the whole scratch tree: the token is still only in tenant.env and the token file.
h_assert_empty "$(token_elsewhere)" "the token is in no file the installer left, across every run"

h_done
