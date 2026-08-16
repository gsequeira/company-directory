#!/usr/bin/env bash
#
# End-to-end smoke test against a *running* foobar server.
#
# This is NOT a substitute for `swift test`. The suite owns correctness and asserts far more than
# this does. This script covers the three things the suite cannot, because it drives the
# application in-process and reverts its migrations after every test:
#
#   1. That a real server is listening and its HTTP stack works.
#   2. That /health answers — it is registered outside the OpenAPI transport and has no test.
#   3. That the binary starts and migrates against a persistent database that already has rows.
#
# Safe to run against a database with data in it: every name is unique to this run, and anything
# created is deleted again on exit.
#
# Requires a running server. This script drives one; it does not start anything.
#
#   docker compose up -d --wait db      # the development database
#   swift run foobar serve              # in another terminal
#   Scripts/smoke.sh                    # then this
#
# Usage:
#   Scripts/smoke.sh                        # http://127.0.0.1:8080
#   Scripts/smoke.sh http://host:port       # somewhere else
#   SMOKE_LOG=/path/to/file Scripts/smoke.sh
#
# Exit status: 0 if every check passed, 1 otherwise.
#
# See Docs/API-PLAYBOOK.md for the manual version of this walk, with the responses written out.

set -u -o pipefail

BASE="${1:-${FOOBAR_BASE_URL:-http://127.0.0.1:8080}}"
API="$BASE/api"
RUN_ID="$$-$(date +%s)"
LOG="${SMOKE_LOG:-${TMPDIR:-/tmp}/foobar-smoke-$(date +%Y%m%d-%H%M%S).log}"

PASSED=0
FAILED=0
CREATED_DEPARTMENTS=()
CREATED_EMPLOYEES=()

# HTTPie reads stdin when it is not a terminal, which hangs in a script. `--ignore-stdin` is
# therefore mandatory here — except where a body is deliberately piped in, below.
HTTP=(http --ignore-stdin --timeout 10 --print=hb)

log() { printf '%s\n' "$*" >>"$LOG"; }

# request METHOD URL [args...] -> sets STATUS and BODY
request() {
    local raw
    raw="$("${HTTP[@]}" "$@" 2>&1)"
    STATUS="$(printf '%s' "$raw" | head -1 | awk '{print $2}')"
    BODY="$(printf '%s' "$raw" | awk 'f{print} /^\r?$/{f=1}')"
    log "--- $* -> ${STATUS:-no response}"
    log "$raw"
}

# request_with_body JSON METHOD URL [args...] — for bodies that cannot be expressed as key=value,
# such as the empty patch. Note the absence of --ignore-stdin: it would discard the pipe.
request_with_body() {
    local json="$1"; shift
    local raw
    raw="$(printf '%s' "$json" | http --timeout 10 --print=hb "$@" 2>&1)"
    STATUS="$(printf '%s' "$raw" | head -1 | awk '{print $2}')"
    BODY="$(printf '%s' "$raw" | awk 'f{print} /^\r?$/{f=1}')"
    log "--- $* (body: $json) -> ${STATUS:-no response}"
    log "$raw"
}

check() { # check LABEL EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then
        printf '  ok    %s\n' "$1"
        PASSED=$((PASSED + 1))
    else
        printf '  FAIL  %s — expected %s, got %s\n' "$1" "$2" "${3:-no response}"
        printf '        request and response written to %s\n' "$LOG"
        # Full detail on failure only. A log that prints everything every run is not read.
        printf '%s\n' "$BODY" | head -20 | sed 's/^/        /'
        FAILED=$((FAILED + 1))
    fi
}

json_field() { printf '%s' "$BODY" | python3 -c "import sys,json;print(json.load(sys.stdin)['$1'])" 2>/dev/null; }

cleanup() {
    local id
    for id in "${CREATED_EMPLOYEES[@]:-}"; do
        [ -n "$id" ] && http --ignore-stdin --timeout 10 DELETE "$API/employees/$id" >/dev/null 2>&1
    done
    for id in "${CREATED_DEPARTMENTS[@]:-}"; do
        [ -n "$id" ] && http --ignore-stdin --timeout 10 DELETE "$API/departments/$id" >/dev/null 2>&1
    done
}
trap cleanup EXIT

command -v http >/dev/null 2>&1 || { echo "smoke: HTTPie ('http') is not installed"; exit 1; }

echo "smoke: $BASE"
echo "smoke: log $LOG"
log "foobar smoke test against $BASE at $(date)"

# --- the server itself -------------------------------------------------------------------------

request GET "$BASE/health"
check "server is reachable and /health answers" 200 "$STATUS"

if [ "$STATUS" != "200" ]; then
    echo
    echo "smoke: the server is not answering; the remaining checks would only repeat this."
    echo "smoke: start it with 'swift run foobar serve' and try again."
    exit 1
fi

# --- departments -------------------------------------------------------------------------------

DEPT_NAME="smoke-dept-$RUN_ID"

request GET "$API/departments"
check "list departments" 200 "$STATUS"

request POST "$API/departments" "name=$DEPT_NAME"
check "create department" 201 "$STATUS"
DEPT_ID="$(json_field id)"
[ -n "$DEPT_ID" ] && CREATED_DEPARTMENTS+=("$DEPT_ID")

request POST "$API/departments" "name=$DEPT_NAME"
check "duplicate department conflicts" 409 "$STATUS"

request GET "$API/departments/$DEPT_ID"
check "read department" 200 "$STATUS"

request PATCH "$API/departments/$DEPT_ID" "name=$DEPT_NAME-renamed"
check "rename department" 200 "$STATUS"

request_with_body '{}' PATCH "$API/departments/$DEPT_ID" Content-Type:application/json
check "empty patch returns the department unchanged" 200 "$STATUS"

request GET "$API/departments/999999"
check "unknown department is not found" 404 "$STATUS"

# --- employees ---------------------------------------------------------------------------------

EMP_LAST="smoke-$RUN_ID"

request GET "$API/employees"
check "list employees" 200 "$STATUS"

request POST "$API/employees" "firstName=Ada" "lastName=$EMP_LAST"
check "create employee" 201 "$STATUS"
EMP_ID="$(json_field id)"
[ -n "$EMP_ID" ] && CREATED_EMPLOYEES+=("$EMP_ID")

request POST "$API/employees" "firstName=Ada" "lastName=$EMP_LAST"
check "duplicate employee conflicts" 409 "$STATUS"

request GET "$API/employees/$EMP_ID"
check "read employee" 200 "$STATUS"

request PATCH "$API/employees/$EMP_ID" "firstName=Augusta"
check "partial patch succeeds" 200 "$STATUS"
check "partial patch preserves the untouched field" "$EMP_LAST" "$(json_field lastName)"

request GET "$API/employees/999999"
check "unknown employee is not found" 404 "$STATUS"

# --- deletion, checked by reading back ----------------------------------------------------------

request DELETE "$API/employees/$EMP_ID"
check "delete employee" 204 "$STATUS"
CREATED_EMPLOYEES=()

request GET "$API/employees/$EMP_ID"
check "deleted employee is gone" 404 "$STATUS"

request DELETE "$API/departments/$DEPT_ID"
check "delete department" 204 "$STATUS"
CREATED_DEPARTMENTS=()

request GET "$API/departments/$DEPT_ID"
check "deleted department is gone" 404 "$STATUS"

# --- summary -------------------------------------------------------------------------------------

echo
if [ "$FAILED" -eq 0 ]; then
    echo "smoke: $PASSED passed"
    exit 0
else
    echo "smoke: $PASSED passed, $FAILED FAILED — see $LOG"
    exit 1
fi
