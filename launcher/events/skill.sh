#!/usr/bin/env bash
# skill NAME: a skill's body, printed as plain text for the model to follow, from
# this checkout. The bootstrap passes the name alone (one word of [a-z0-9-]), so a
# skill that takes a value carries it in the name.
#
#   notices-stop-<kind>   record that the person does not want that kind of notice
#                         again (docs/launcher-contract.md section 12); kind is
#                         version, model, fresh-session or all. Prints one line that
#                         says it is off. An unknown kind is refused: nothing is
#                         printed, nothing is written, one line goes to the log.
#
#   read-draft            the reader, by hand (docs/launcher-contract.md section 13).
#                         The stub's one pre-approved command carries no arguments and
#                         the bootstrap reads no stdin for a skill, so a draft reaches
#                         this step through one file in the state directory, which the
#                         first run names. With no draft file: print how to give one
#                         (write the exact text to the file, then run the same command
#                         again). With one: run the reader on it (reader/reader.py)
#                         against the reply contract and the repository's rules file,
#                         print the verdict and the findings in plain text, write a
#                         receipt, and remove the file so the next run starts clean. A
#                         first line of "kind: copy" says the draft is copy the
#                         person's customers will read, and is not part of the draft.
#                         When the reader cannot run here (no `claude`, a timeout, a
#                         failure): print the assembled prompt, so the model hands it
#                         to a reader itself with the Agent tool.
#
# Every other name is a no-op. Stdout here is the body the model follows; it passes
# as it is.
# shellcheck source=../lib/common.sh
. "$BBD_CHECKOUT/launcher/lib/common.sh" || exit 0
trap 'exit 0' ERR INT TERM HUP

notices_stop() { # KIND
  local kind=$1 what
  case "$kind" in
    version|model|fresh-session|all) ;;
    *) bbd_log "notices-stop: unknown kind '$kind'; nothing written"; return 0 ;;
  esac
  # The stop is the person's, so it goes to the repository's .apparatus/notices.json
  # (written in the work tree, never committed here) and travels with their vault;
  # the home record stands in when that file cannot be used.
  if python3 "$BBD_CHECKOUT/lib/notices.py" stop "$BBD_BASE/state/notices.json" "$kind" "$BBD_PROJECT_ROOT" 2>>"$BBD_LOG"; then
    case "$kind" in
      all) what="Every keep-current notice is" ;;
      fresh-session) what="Fresh-session advice is" ;;
      *) what="The $kind notice is" ;;
    esac
    printf '%s\n' "$what now off for this account home. Tell the person that in one sentence, and say nothing more about it."
  fi
  return 0
}

read_draft() {
  local bound=60 draft_file receipts draft="" result="" kind first rules status verdict count
  case "${BBD_READER_BOUND:-}" in
    ''|*[!0-9]*) ;;
    *) if [ "$BBD_READER_BOUND" -ge 1 ] && [ "$BBD_READER_BOUND" -le 600 ]; then bound=$BBD_READER_BOUND; fi ;;
  esac
  draft_file=$BBD_BASE/state/draft.md
  receipts=$BBD_BASE/state/reader
  umask 077

  if [ ! -s "$draft_file" ]; then
    cat <<EOF
read-draft: no draft to read yet.

Write the exact text you are about to send, or the whole file the person will receive,
to this file (the Write tool is fine), then run the same command again:

    $draft_file

The reader reads that file, prints what it found, and removes the file. For copy the
person's own customers will read (a web page, an email to a customer), make the first
line of the file "kind: copy"; that line is not part of the draft.

Act on what comes back: a quoted RESTATE line is spelled out or cut; a quoted CHAIN line
is cut; a lost phrase or hedge is restored in the person's words; a CLAIMS question goes
to the person, not into the draft as a fact; an ANSWERED line gets its answer under its
number; a READING line is said plainly; a CONTRACT line is fixed. Then read the changed
text again, the same way: the reader reads exact text, and an edit after the reading is
unread. Send when the verdict is send.
EOF
    return 0
  fi

  draft=$(mktemp "$BBD_BASE/state/draft.XXXXXX" 2>/dev/null) || return 0
  result=$(mktemp "$BBD_BASE/state/verdict.XXXXXX" 2>/dev/null) || { rm -f "$draft"; return 0; }
  # shellcheck disable=SC2064  # the paths are fixed when the trap is set
  trap "rm -f '$draft' '$result' 2>/dev/null; exit 0" EXIT

  kind=reply
  first=$(head -n 1 "$draft_file" 2>/dev/null | tr -d '\r' | sed -e 's/[[:space:]]*$//')
  if [ "$first" = "kind: copy" ]; then
    kind=copy
    tail -n +2 "$draft_file" >"$draft" 2>/dev/null
  else
    cat "$draft_file" >"$draft" 2>/dev/null
  fi
  # The file is consumed whatever happens next, so a stale draft is never read twice.
  rm -f "$draft_file" 2>/dev/null

  rules=/nonexistent
  [ -n "${BBD_RULES:-}" ] && [ -s "$BBD_PROJECT_ROOT/$BBD_RULES" ] && rules=$BBD_PROJECT_ROOT/$BBD_RULES

  python3 "$BBD_CHECKOUT/reader/reader.py" read \
    --draft "$draft" --contract "$BBD_CHECKOUT/text/reply-contract.md" \
    --rules "$rules" --kind "$kind" --bound "$bound" >"$result" 2>>"$BBD_LOG"
  # jget KEY: one field of the reader's JSON answer.
  jget() {
    python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {}
v = d.get(sys.argv[2], "") if isinstance(d, dict) else ""
sys.stdout.write(str(v))' "$result" "$1" 2>>"$BBD_LOG"
  }
  status=$(jget status)
  verdict=$(jget verdict)
  count=$(jget count)
  [ -n "$status" ] || status=failed
  [ "$verdict" = fix ] || verdict=send

  python3 "$BBD_CHECKOUT/lib/receipt.py" write "$receipts" "$draft" "session=skill" "kind=$kind" \
    "status=$status" "verdict=$verdict" "findings=${count:-0}" "blocked=0" \
    >/dev/null 2>>"$BBD_LOG" || bbd_log "skill read-draft: the receipt could not be written"

  case "$status" in
    read|unparseable|empty)
      python3 -c 'import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
if d.get("verdict") == "fix":
    print("read-draft verdict: fix. The reader found %d thing(s):" % d.get("count", 0))
    print()
    for f in d.get("findings", []):
        print("- " + f)
    print()
    print("Fix each one in the text, then read the changed text again the same way before you send it.")
elif d.get("status") == "read":
    print("read-draft verdict: send. The reader could restate every line, found nothing the person did not ask for, and no claim without a source. Send it as it is.")
else:
    print("read-draft verdict: send. The reader answered out of shape, so nothing was flagged; send it, or read it again if you changed anything.")' "$result" 2>>"$BBD_LOG"
      ;;
    *)
      bbd_log "skill read-draft: the reader could not run here ($status); the prompt was handed back"
      cat <<EOF
read-draft: the reader could not run here ($status). Hand it to a reader yourself: start one
with the Agent tool (a small, cheap model is enough), paste the whole prompt below as its
task, with nothing added, and act on what it returns: a quoted RESTATE line is spelled
out or cut; a quoted CHAIN line is cut; a lost phrase or hedge is restored in the person's
words; a CLAIMS question goes to the person, not into the draft as a fact; an ANSWERED
line gets its answer under its number; a READING line is said plainly; a CONTRACT line is
fixed. Then read the changed text again before you send it.

EOF
      python3 "$BBD_CHECKOUT/reader/reader.py" prompt \
        --draft "$draft" --contract "$BBD_CHECKOUT/text/reply-contract.md" \
        --rules "$rules" --kind "$kind" 2>>"$BBD_LOG"
      ;;
  esac
  return 0
}

name=${1:-}
case "$name" in
  notices-stop-*) notices_stop "${name#notices-stop-}" ;;
  read-draft) read_draft ;;
esac
exit 0
