#!/usr/bin/env bash
#
# Replay Docs/API-PLAYBOOK.md against a running server and check that every
# response still carries the status the document records.
#
# The commands and their expected statuses are read out of the document itself,
# so there is nothing here to keep in step with it. Editing the playbook changes
# what this script runs.
#
# This is not Scripts/smoke.sh. That one invents its own names, cleans up after
# itself, and is safe against a populated database. This one reproduces the
# document, which means fixed ids, which means it must start from an empty
# database and will TRUNCATE to get one.
#
# Usage:
#   Scripts/playbook-replay.sh [-y] [base-url]
#
#   -y            skip the confirmation prompt
#   base-url      defaults to $SMOKE_BASE_URL, then http://127.0.0.1:8080
#
set -uo pipefail

CONFIRMED=0
if [ "${1:-}" = "-y" ]; then CONFIRMED=1; shift; fi

BASE="${1:-${SMOKE_BASE_URL:-http://127.0.0.1:8080}}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$ROOT/Docs/API-PLAYBOOK.md"

DB_SERVICE="${PLAYBOOK_DB_SERVICE:-db}"
DB_USER="${PLAYBOOK_DB_USER:-company_directory}"
DB_NAME="${PLAYBOOK_DB_NAME:-company_directory}"

LOG="$(mktemp -t companydirectory-playbook-XXXXXX).log"

[ -r "$DOC" ] || { echo "playbook: cannot read $DOC" >&2; exit 2; }
command -v http >/dev/null || { echo "playbook: HTTPie (http) is not installed" >&2; exit 2; }

echo "playbook: $BASE"
echo "playbook: source $DOC"
echo "playbook: log $LOG"

# --- extraction -------------------------------------------------------------
#
# Inside a ```console block, a line starting with "$ " is a command. Its
# expected status is either the "-> NNN" annotation on the command line, or the
# first "HTTP/1.1 NNN" line that follows it in the block. A command with
# neither is reported and skipped rather than silently dropped.

EXTRACT="$(awk '
  /^```console$/ { inblock = 1; last = 0; next }
  /^```/         { inblock = 0; last = 0; next }
  !inblock       { next }

  /^\$ / {
    line = substr($0, 3)
    status = ""
    if (match(line, /→[ \t]*[0-9][0-9][0-9]/)) {
      status = substr(line, RSTART, RLENGTH)
      gsub(/[^0-9]/, "", status)
      line = substr(line, 1, RSTART - 1)
    }
    sub(/[ \t]+$/, "", line)
    n++
    cmd[n] = line
    expected[n] = status
    last = n
    next
  }

  # A status line belongs to the command immediately above it, in this block.
  # Scoping it that way stops an unannotated command soaking up a status line
  # from somewhere further down the document.
  /^HTTP\/1\.1 [0-9][0-9][0-9]/ {
    if (last > 0 && expected[last] == "") { split($0, f, " "); expected[last] = f[2] }
    next
  }

  END { for (i = 1; i <= n; i++) printf "%s\t%s\n", expected[i], cmd[i] }
' "$DOC")"

# Only HTTP calls are replayable. Anything else in a console block (Scripts/smoke.sh
# and its output, for instance) is listed as skipped.
REPLAYABLE="$(printf '%s\n' "$EXTRACT" | grep -E $'^[0-9]{3}\t.*\\bhttp ' || true)"
SKIPPED="$(printf '%s\n' "$EXTRACT" | grep -vE $'^[0-9]{3}\t.*\\bhttp ' | grep -v '^$' || true)"

TOTAL=$(printf '%s\n' "$REPLAYABLE" | grep -c . || true)
[ "$TOTAL" -gt 0 ] || { echo "playbook: extracted no commands — has the document's format changed?" >&2; exit 2; }

echo "playbook: $TOTAL commands extracted"
echo

# --- the destructive part ---------------------------------------------------

if [ "$CONFIRMED" -ne 1 ]; then
  if [ ! -t 0 ]; then
    echo "playbook: refusing to truncate without -y when stdin is not a terminal" >&2
    exit 2
  fi
  printf 'This TRUNCATEs employees and departments in "%s". Continue? [y/N] ' "$DB_NAME"
  read -r reply
  case "$reply" in [yY]*) ;; *) echo "playbook: aborted"; exit 1 ;; esac
fi

if ! (cd "$ROOT" && docker compose exec -T "$DB_SERVICE" \
        psql -U "$DB_USER" -d "$DB_NAME" -q \
        -c "TRUNCATE employees, departments RESTART IDENTITY CASCADE;") >>"$LOG" 2>&1; then
  echo "playbook: could not truncate — is the '$DB_SERVICE' service up?" >&2
  exit 2
fi
echo "  --    database truncated, identities restarted"

# --- replay -----------------------------------------------------------------

pass=0
fail=0

# The loop reads on fd 3. On stdin, the first http invocation would swallow the
# remaining commands and the replay would stop after one.
while IFS=$'\t' read -r want cmd <&3; do
  [ -n "$cmd" ] || continue

  # Point the command at the chosen base and force headers into the output.
  # A piped command must not gain --ignore-stdin: discarding the piped body is
  # the very trap the document warns about.
  run="${cmd//:8080/$BASE}"
  if [[ "$run" == *"| http "* ]]; then
    run="${run/| http /| http --print=HhBb --timeout 10 }"
  elif [[ "$run" == "http "* ]]; then
    run="http --print=HhBb --ignore-stdin --timeout 10 ${run#http }"
  fi

  {
    echo "=============================================================="
    echo "\$ $cmd"
    echo "  expecting $want"
  } >>"$LOG"

  out="$(eval "$run" 2>>"$LOG")"
  printf '%s\n\n' "$out" >>"$LOG"

  got="$(printf '%s\n' "$out" | grep -m1 '^HTTP/1\.1 ' | awk '{print $2}')"

  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    printf '  ok    %-3s  %s\n' "$got" "$cmd"
  else
    fail=$((fail + 1))
    printf '  FAIL  want %s got %-6s %s\n' "$want" "${got:-none}" "$cmd"
    printf '%s\n' "$out" | head -20 | sed 's/^/        /'
  fi
done 3<<<"$REPLAYABLE"

if [ -n "$SKIPPED" ]; then
  echo
  echo "playbook: not replayable, so not checked:"
  printf '%s\n' "$SKIPPED" | sed $'s/^[0-9]*\t*/        /'
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "playbook: $pass passed"
  exit 0
else
  echo "playbook: $pass passed, $fail failed — see $LOG"
  exit 1
fi
