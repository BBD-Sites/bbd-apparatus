#!/usr/bin/env bash
# calibrate.sh: prove the reader on the stored drafts before it is trusted, and again
# whenever reader-prompt.md or a draft changes. The rule: the reader must flag at least
# one line in every rejected draft and none in every accepted one. Each draft is read
# with the calibration asks and rules beside it, through the same reader.py the Stop
# gate runs, on the real `claude` on PATH (this costs a small model call per draft).
# Prints one line per draft and the date; exits 1 when the rule is broken. Record the
# run and its date in the pull request that changed the prompt or a draft.
#
#   bash reader/calibrate.sh [--model NAME] [--bound SECONDS]
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
model=haiku
bound=90
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model=${2:-haiku}; shift 2 ;;
    --bound) bound=${2:-90}; shift 2 ;;
    *) echo "usage: calibrate.sh [--model NAME] [--bound SECONDS]" >&2; exit 2 ;;
  esac
done
command -v claude >/dev/null 2>&1 || { echo "calibrate: no claude on PATH" >&2; exit 2; }

failed=0
read_one() { # FILE WANT
  local file=$1 want=$2 out status verdict count
  out=$(python3 "$here/reader.py" read \
    --draft "$file" --contract "$here/../text/reply-contract.md" \
    --rules "$here/calibration/rules.md" --asks "$here/calibration/asks.md" \
    --kind reply --bound "$bound" --model "$model")
  status=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')
  verdict=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("verdict",""))')
  count=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("count",0))')
  if [ "$status" != read ]; then
    printf 'FAIL %s: the reader did not answer in shape (%s)\n' "$(basename "$file")" "$status"
    failed=1
  elif [ "$verdict" = "$want" ]; then
    printf 'ok   %s: verdict %s, %s finding(s)\n' "$(basename "$file")" "$verdict" "$count"
  else
    printf 'FAIL %s: wanted %s, got %s with %s finding(s)\n' "$(basename "$file")" "$want" "$verdict" "$count"
    failed=1
  fi
  printf '%s' "$out" | python3 -c 'import json,sys
for f in json.load(sys.stdin).get("findings", []): print("     - " + f)'
}

for f in "$here"/calibration/rejected-*.md; do [ -f "$f" ] && read_one "$f" fix; done
for f in "$here"/calibration/accepted-*.md; do [ -f "$f" ] && read_one "$f" send; done
printf 'calibration run %s with model %s\n' "$(date -u +%Y-%m-%d)" "$model"
exit "$failed"
