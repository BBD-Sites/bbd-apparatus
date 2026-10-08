#!/usr/bin/env bash
# Runs every tests/test-*.sh in its own process, so one test's traps, PATH changes
# and temp directories cannot leak into the next one.
set -u

here=$(cd "$(dirname "$0")" && pwd -P)
bash_bin=${BASH:-bash}
failed=0
ran=0

for t in "$here"/test-*.sh; do
  [ -f "$t" ] || continue
  name=$(basename "$t" .sh)
  ran=$((ran + 1))
  log=$(mktemp "${TMPDIR:-/tmp}/apparatus-run.XXXXXX")
  if "$bash_bin" "$t" >"$log" 2>&1; then
    printf 'PASS %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name"
    # The tail is enough to diagnose; tests never print secret values or deny-list
    # entries, so showing their output is safe in a public CI log.
    sed 's/^/    /' "$log" | tail -n 40
    failed=$((failed + 1))
  fi
  rm -f "$log"
done

if [ "$ran" -eq 0 ]; then
  echo "FAIL no tests found in $here"
  exit 1
fi

printf '%s run, %s failed\n' "$ran" "$failed"
[ "$failed" -eq 0 ]
