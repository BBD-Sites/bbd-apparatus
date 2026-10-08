#!/usr/bin/env bash
# The redactor, the renderer and the post-scan, ported from the maintainers' own
# ingest tooling, behave exactly as the originals: the self-test passes (and is
# seen to fail when a pattern is broken), every fixture transcript renders byte for
# byte as the original renderer rendered it, and the post-scan quarantines a
# surviving secret and leaves a clean file alone.
#
# Planted values are assembled at run time and never printed, so a failing run
# cannot repeat a secret shape into a public CI log.
set -u
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
h_init

repo=$(h_repo_root)
app="$repo/bin/apparatus"
tmp=$(h_tmpdir)
# Keep interpreter caches out of the work tree under test.
export PYTHONDONTWRITEBYTECODE=1

# --- Witness 1: the self-test -------------------------------------------------
out=$(python3 "$app" selftest 2>&1); rc=$?
h_assert_eq "$rc" "0" "selftest exits 0"
case "$out" in "SELF-TEST PASSED:"*) h_ok "selftest reports a pass" ;;
  *) h_fail "selftest did not report a pass" ;; esac
python3 "$app" redact --self-test >/dev/null 2>&1; rc=$?
h_assert_eq "$rc" "0" "redact --self-test exits 0"

# A gate never seen to fail is not a gate: break one pattern in a copy and the
# self-test must refuse it.
cp -R "$repo/bin" "$repo/lib" "$tmp/"
python3 - "$tmp/lib/redact.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'r"gh[pousr]_[A-Za-z0-9]{20,}\\b"'
assert old in s, "pattern to break not found"
open(p, "w").write(s.replace(old, 'r"gh[pousr]_NEVER_MATCHES"'))
PY
python3 "$tmp/bin/apparatus" selftest >/dev/null 2>&1; rc=$?
h_assert_eq "$rc" "1" "selftest fails closed when a pattern is broken"
rm -rf "${tmp:?}/bin" "${tmp:?}/lib"

# --- Render parity with the original ------------------------------------------
fixtures="$repo/tests/fixtures/transcripts"
golden="$repo/tests/fixtures/golden"
n=0
for t in "$fixtures"/*.jsonl; do
  [ -f "$t" ] || continue
  base=$(basename "$t" .jsonl)
  LC_ALL=C python3 "$app" render "$t" >"$tmp/$base.md" 2>"$tmp/$base.err"; rc=$?
  if [ -f "$golden/$base.md" ]; then
    n=$((n + 1))
    h_assert_eq "$rc" "0" "render $base exits 0"
    if cmp -s "$tmp/$base.md" "$golden/$base.md"; then
      h_ok "render $base matches its golden file byte for byte"
    else
      h_fail "render $base differs from its golden file"
    fi
  else
    # A transcript with nothing to keep renders nothing, as the original wrote
    # no file for it.
    h_assert_eq "$rc" "3" "render $base (no turns) exits 3"
    h_assert_empty "$(cat "$tmp/$base.md")" "render $base (no turns) prints nothing"
  fi
done
if [ "$n" -ge 2 ]; then h_ok "$n golden files compared"; else h_fail "expected at least 2 golden files, found $n"; fi

# Where the original renderer is available (a maintainer's machine), render the
# fixtures with it again, so a change on either side is caught. Skipped elsewhere.
if [ -n "${APPARATUS_ORIGINAL_RENDERER:-}" ] && [ -f "$APPARATUS_ORIGINAL_RENDERER" ]; then
  if python3 - "$APPARATUS_ORIGINAL_RENDERER" "$fixtures" "$golden" <<'PY'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("original", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
bad = 0
for t in sorted(Path(sys.argv[2]).glob("*.jsonl")):
    g = Path(sys.argv[3]) / (t.stem + ".md")
    meta = mod.extract_session(t)
    if meta is None:
        bad += g.exists()
    elif not g.exists() or mod.render_markdown(meta).encode("utf-8") != g.read_bytes():
        bad += 1
sys.exit(1 if bad else 0)
PY
  then h_ok "the original renderer still produces every golden file"
  else h_fail "the original renderer no longer produces the golden files"
  fi
else
  echo "skip: APPARATUS_ORIGINAL_RENDERER not set, original renderer not rerun"
fi

# The golden files are redacted output, so the post-scan finds nothing in them.
out=$(python3 "$app" postscan --report-only "$golden" 2>&1); rc=$?
h_assert_eq "$rc" "0" "post-scan finds no secret shape in the golden files"

# --- Witness 2: the post-scan -------------------------------------------------
body=$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36)
survivor="gh""p_$body"

out_dir="$tmp/out"
mkdir -p "$out_dir/demo"
printf 'clean text, [REDACTED:github-token]\n' >"$out_dir/demo/clean.md"
printf 'leaked %s here\n' "$survivor" >"$out_dir/demo/survivor.md"
out=$(python3 "$app" postscan "$out_dir" 2>"$tmp/postscan.err"); rc=$?
h_assert_eq "$rc" "1" "post-scan exits 1 on a surviving secret"
h_assert_eq "$out" "$out_dir/demo/survivor.md" "post-scan prints the file name and nothing else"
case "$out$(cat "$tmp/postscan.err")" in *"$body"*) h_fail "post-scan printed the secret" ;;
  *) h_ok "post-scan never prints the matching text" ;; esac
if [ -f "$out_dir-quarantine/survivor.md" ] && [ ! -e "$out_dir/demo/survivor.md" ]; then
  h_ok "the survivor moved to <dir>-quarantine"
else
  h_fail "the survivor was not moved to <dir>-quarantine"
fi
if [ -f "$out_dir/demo/clean.md" ]; then h_ok "the clean file stayed in place"; else h_fail "the clean file was moved"; fi

out=$(python3 "$app" postscan "$out_dir" 2>&1); rc=$?
h_assert_eq "$rc" "0" "post-scan on clean files exits 0"
h_assert_empty "$out" "post-scan on clean files prints nothing"

printf 'again %s\n' "$survivor" >"$out_dir/demo/second.md"
python3 "$app" postscan --quarantine "$tmp/held" "$out_dir/demo/second.md" >/dev/null 2>&1; rc=$?
h_assert_eq "$rc" "1" "post-scan of one named file exits 1 on a hit"
if [ -f "$tmp/held/second.md" ]; then h_ok "--quarantine DIR receives the hit"; else h_fail "--quarantine DIR did not receive the hit"; fi

printf 'report %s\n' "$survivor" >"$out_dir/demo/report.md"
python3 "$app" postscan --report-only "$out_dir" >/dev/null 2>&1; rc=$?
h_assert_eq "$rc" "1" "--report-only still exits 1 on a hit"
if [ -f "$out_dir/demo/report.md" ]; then h_ok "--report-only moves nothing"; else h_fail "--report-only moved a file"; fi
rm -f "$out_dir/demo/report.md"

python3 "$app" postscan "$tmp/does-not-exist" >/dev/null 2>&1; rc=$?
h_assert_eq "$rc" "2" "post-scan of a missing path fails closed with exit 2"

# Same verdicts as the shell original (LC_ALL=C grep -lIE), shape by shape,
# including grep -I's rule that a file with a NUL byte is binary and skipped.
cmpdir="$tmp/compare"
mkdir -p "$cmpdir"
# Split with "" so no full shape is ever written in this file.
shapes=$(printf '%s\n' \
  "sk""-ant-$body" \
  "sk""-$body" \
  "gh""o_$body" \
  "AK""IA0000000000000000" \
  "xox""b-0000000000-aaaa" \
  "pat""-na1-0123456789abcdef" \
  "-----BEGIN EC PRIV""ATE KEY-----" \
  "sk-short" \
  "nothing secret here")
i=0
while IFS= read -r s; do
  i=$((i + 1))
  printf 'x %s y\n' "$s" >"$cmpdir/shape$i.md"
done <<SHAPES
$shapes
SHAPES
printf 'bin\000 %s\n' "$survivor" >"$cmpdir/binary.md"
re=$(cd "$repo/lib" && python3 -c 'import postscan; print(postscan.SECRET_RE)')
want=$(cd "$cmpdir" && LC_ALL=C grep -lIE "$re" ./* 2>/dev/null | sed 's#^\./##' | sort)
got=$(python3 "$app" postscan --report-only "$cmpdir" 2>/dev/null | sed 's#^.*/##' | sort)
h_assert_eq "$got" "$want" "post-scan agrees with grep -lIE on every planted shape"
h_assert_eq "$(printf '%s\n' "$got" | grep -c . || true)" "7" "post-scan flags the seven full shapes and nothing else"

h_done
