#!/usr/bin/env bash
# Regression tests for the deliveries-channel overwrite race.
#
# Background: `_v2_task_deliveries_poll` fires every 15 s; `compose_emit`
# fires every 60 s (MONITOR_INTERVAL). Each task fire's stdout is captured
# by the scheduler to `<stage>/deliveries_poll.out` via atomic-replace,
# OVERWRITING the previous fire's output. A delivery seen by tick T is
# wiped on tick T+1 (cursor has advanced past it, so the next fire's
# stdout is empty). compose_emit's read at T+2 sees an empty file → the
# event never surfaces via the deliveries channel; only the 600 s GraphQL
# backstop eventually catches it.
#
# Fix shape: snapshot_deliveries appends each emit block to a persistent
# queue file (locked append). compose_emit drains the queue via
# rename-then-cat-then-rm. No event is lost across multiple fires.
#
# These tests exercise the queue mechanism directly. They FAIL on the
# pre-fix code because `_drain_deliveries_queue` does not yet exist and
# `snapshot_deliveries` does not populate the queue.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0
FAIL=0

assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         expected to find: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if ! grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         did NOT expect: %s\n' "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness ----

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/state"
mkdir -p "$STATE_DIR"
REPO="your-org/your-nexus"
USER_LOGIN="operator"
MINT_JWT_BIN="$WORK/mint-jwt-stub.sh"
cat > "$MINT_JWT_BIN" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'fake.jwt.value'
STUB
chmod +x "$MINT_JWT_BIN"

export STATE_DIR REPO USER_LOGIN MINT_JWT_BIN

. "$_test_dir/_github.sh"
. "$_test_dir/_deliveries.sh"

mkdir -p "$WORK/fixtures"
LIST_BODY="$WORK/fixtures/list.json"
LIST_HDR="$WORK/fixtures/list.hdr"
printf 'HTTP/2 200 \n\n' > "$LIST_HDR"

mk_detail() {
    local id="$1" event="$2" action="$3" payload="$4"
    cat > "$WORK/fixtures/${id}.json" <<JSON
{
  "id": ${id},
  "event": "${event}",
  "action": "${action}",
  "request": {
    "headers": {"X-GitHub-Event": "${event}"},
    "payload": ${payload}
  }
}
JSON
}

# Curl mock — same shape as test-snapshot-deliveries.sh.
curl() {
    local hdr_target="" body_target="" url="" status_w=0
    local prev=""
    for arg in "$@"; do
        case "$prev" in
            -D) hdr_target="$arg"; prev=""; continue ;;
            -o) body_target="$arg"; prev=""; continue ;;
            -w) status_w=1; prev=""; continue ;;
            -H) prev=""; continue ;;
        esac
        case "$arg" in
            -D|-o|-H|-w) prev="$arg" ;;
            -sS) ;;
            -*)  ;;
            http*) url="$arg" ;;
        esac
    done

    local code=200 src_hdr="" src_body=""
    case "$url" in
        *'/app/hook/deliveries?per_page='*)
            src_hdr="$LIST_HDR"; src_body="$LIST_BODY" ;;
        *'/app/hook/deliveries/'*)
            local id="${url##*/}"
            id="${id%%\?*}"
            src_body="$WORK/fixtures/${id}.json"
            if [[ ! -f "$src_body" ]]; then
                code=404
                src_body="$WORK/fixtures/.empty"
                printf '{"message":"Not Found"}' > "$src_body"
            fi
            src_hdr="$WORK/fixtures/.detail-hdr"
            printf 'HTTP/2 %s \n\n' "$code" > "$src_hdr"
            ;;
        *)
            code=404
            src_body="$WORK/fixtures/.empty"
            : > "$src_body"
            src_hdr="$WORK/fixtures/.detail-hdr"
            printf 'HTTP/2 %s \n\n' "$code" > "$src_hdr"
            ;;
    esac

    [[ -n "$hdr_target" ]] && cp "$src_hdr"  "$hdr_target"
    [[ -n "$body_target" ]] && cp "$src_body" "$body_target"
    (( status_w == 1 )) && printf '%s' "$code"
    return 0
}
export -f curl

reset_state() {
    rm -f "$STATE_DIR/last-delivery-cursor.txt" \
          "$STATE_DIR/processed-comments.txt" \
          "$STATE_DIR/deliveries-queue.lines" \
          "$STATE_DIR/deliveries-queue.lock"
}

# ============================================================
# Test 1 — race-condition regression
# ============================================================
#
# Tick 1: list contains delivery A. snapshot_deliveries emits A; cursor
#         advances to guid-A. Queue file now contains A's emit block.
# Tick 2: list still contains only delivery A. cursor=guid-A matches
#         first item; snapshot_deliveries emits NOTHING (no new events).
#         If the staging-file overwrite race were still in effect, the
#         emit would be lost. With the queue, A persists.
# Drain:  _drain_deliveries_queue returns A's emit block.
#
# On pre-fix code: _drain_deliveries_queue is undefined → drain output
# is empty → test fails.

echo '=== test 1: two ticks, first emits, second is empty — drain returns first event ==='
reset_state
cat > "$LIST_BODY" <<'JSON'
[
  {"id": 9001, "guid": "guid-9001", "event": "issue_comment", "action": "created"}
]
JSON
mk_detail 9001 issue_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/your-nexus"},
  "issue": {"number": 501, "pull_request": null},
  "comment": {"id": 99001, "user": {"login": "operator"}, "body": "race-test event A"}
}'

# Tick 1
snapshot_deliveries 2>/dev/null >/dev/null
assert_eq "tick 1: cursor advanced to guid-9001" \
    "$(cat "$STATE_DIR/last-delivery-cursor.txt" 2>/dev/null)" "guid-9001"

# Tick 2 (same fixture; cursor at guid-9001 → no new events)
snapshot_deliveries 2>/dev/null >/dev/null

# Drain queue — must return A even though tick 2 emitted nothing.
drained=$(_drain_deliveries_queue 2>/dev/null)
assert_contains "drain contains event A after empty second tick" "$drained" "issue=501 id=99001 author=operator"
assert_contains "drain contains event A's body preview" "$drained" "race-test event A"

# ============================================================
# Test 2 — cumulative emit across three ticks
# ============================================================
#
# Ticks 1/2/3 each see one new delivery (cursor walks A → B → C). Drain
# at the end returns all three in delivery order.

echo '=== test 2: three ticks, three new events, drain returns all ==='
reset_state

# Tick 1: only A is listed.
cat > "$LIST_BODY" <<'JSON'
[
  {"id": 9101, "guid": "guid-9101", "event": "issue_comment", "action": "created"}
]
JSON
mk_detail 9101 issue_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/your-nexus"},
  "issue": {"number": 511, "pull_request": null},
  "comment": {"id": 99101, "user": {"login": "operator"}, "body": "cumulative event A"}
}'
snapshot_deliveries 2>/dev/null >/dev/null

# Tick 2: B added (newest-first), A still in list.
cat > "$LIST_BODY" <<'JSON'
[
  {"id": 9102, "guid": "guid-9102", "event": "issue_comment", "action": "created"},
  {"id": 9101, "guid": "guid-9101", "event": "issue_comment", "action": "created"}
]
JSON
mk_detail 9102 issue_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/your-nexus"},
  "issue": {"number": 512, "pull_request": null},
  "comment": {"id": 99102, "user": {"login": "operator"}, "body": "cumulative event B"}
}'
snapshot_deliveries 2>/dev/null >/dev/null

# Tick 3: C added.
cat > "$LIST_BODY" <<'JSON'
[
  {"id": 9103, "guid": "guid-9103", "event": "issue_comment", "action": "created"},
  {"id": 9102, "guid": "guid-9102", "event": "issue_comment", "action": "created"},
  {"id": 9101, "guid": "guid-9101", "event": "issue_comment", "action": "created"}
]
JSON
mk_detail 9103 issue_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/your-nexus"},
  "issue": {"number": 513, "pull_request": null},
  "comment": {"id": 99103, "user": {"login": "operator"}, "body": "cumulative event C"}
}'
snapshot_deliveries 2>/dev/null >/dev/null

drained=$(_drain_deliveries_queue 2>/dev/null)
assert_contains "drain contains event A" "$drained" "issue=511 id=99101 author=operator"
assert_contains "drain contains event B" "$drained" "issue=512 id=99102 author=operator"
assert_contains "drain contains event C" "$drained" "issue=513 id=99103 author=operator"

# ============================================================
# Test 3 — drain empties queue (idempotent on second call)
# ============================================================
#
# After a drain, subsequent drains return empty until a new event is
# appended. This is the contract compose_emit relies on to not
# re-surface the same event on every 60 s tick.

echo '=== test 3: second drain returns empty ==='
reset_state
cat > "$LIST_BODY" <<'JSON'
[
  {"id": 9201, "guid": "guid-9201", "event": "issue_comment", "action": "created"}
]
JSON
mk_detail 9201 issue_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/your-nexus"},
  "issue": {"number": 521, "pull_request": null},
  "comment": {"id": 99201, "user": {"login": "operator"}, "body": "drain-test event"}
}'
snapshot_deliveries 2>/dev/null >/dev/null

first_drain=$(_drain_deliveries_queue 2>/dev/null)
second_drain=$(_drain_deliveries_queue 2>/dev/null)
assert_contains "first drain returns event" "$first_drain" "id=99201"
assert_eq "second drain returns empty" "$second_drain" ""

# ============================================================
# Test 4 — events from a new fire show up in next drain
# ============================================================
#
# Drain. Then a NEW delivery arrives. snapshot_deliveries appends it.
# Next drain returns just that new event (not a re-surface of prior).

echo '=== test 4: drain → new event → drain returns only the new event ==='
reset_state
cat > "$LIST_BODY" <<'JSON'
[
  {"id": 9301, "guid": "guid-9301", "event": "issue_comment", "action": "created"}
]
JSON
mk_detail 9301 issue_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/your-nexus"},
  "issue": {"number": 531, "pull_request": null},
  "comment": {"id": 99301, "user": {"login": "operator"}, "body": "first event"}
}'
snapshot_deliveries 2>/dev/null >/dev/null
_drain_deliveries_queue 2>/dev/null >/dev/null

cat > "$LIST_BODY" <<'JSON'
[
  {"id": 9302, "guid": "guid-9302", "event": "issue_comment", "action": "created"},
  {"id": 9301, "guid": "guid-9301", "event": "issue_comment", "action": "created"}
]
JSON
mk_detail 9302 issue_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/your-nexus"},
  "issue": {"number": 532, "pull_request": null},
  "comment": {"id": 99302, "user": {"login": "operator"}, "body": "second event"}
}'
snapshot_deliveries 2>/dev/null >/dev/null

second_drain=$(_drain_deliveries_queue 2>/dev/null)
assert_contains "second drain contains new event" "$second_drain" "id=99302"
assert_not_contains "second drain does not re-surface drained event" "$second_drain" "id=99301"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
