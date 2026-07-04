#!/usr/bin/env bash
# Mock-gh unit tests for the GraphQL bucket-floor gate
# (`_graphql_polling_gate` + `_graphql_gate_alert` in
# monitor/watcher/_github.sh).
#
# Run: bash monitor/watcher/test-graphql-gate.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: the gate calls `gh api /rate_limit` directly and parses
# `.resources.graphql.remaining` from the response. We shadow `gh`
# with a bash function that branches on env vars to canned bodies.
# `MINT_TOKEN_BIN` is pointed at a stub that emits a fake token (so
# we can assert the unit prefers the bot installation token without
# actually minting one). `date +%s` is shadowed so the alert
# rate-limit window can be advanced without sleeping.

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
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_file_exists() {
    local label="$1" path="$2"
    if [[ -f "$path" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — missing file: %s\n' "$label" "$path" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/state"
mkdir -p "$STATE_DIR"
REPO="your-org/your-nexus"
USER_LOGIN="operator"

# Stub mint-token.sh so the gate's preferred path emits a fake token
# without minting. The stub is executable — required so the gate's
# `[[ -x "$MINT_TOKEN_BIN" ]]` guard succeeds.
MINT_TOKEN_BIN="$WORK/mint-token-stub.sh"
cat > "$MINT_TOKEN_BIN" <<'STUB'
#!/usr/bin/env bash
echo "fake-installation-token"
STUB
chmod +x "$MINT_TOKEN_BIN"

export STATE_DIR REPO USER_LOGIN MINT_TOKEN_BIN

# Source the unit under test.
. "$_test_dir/_github.sh"

# Counter file the mock bumps on every gh invocation. Tests use this
# to assert whether the gate actually probed (or short-circuited).
GH_CALL_COUNT="$WORK/gh-call-count"
printf '0\n' > "$GH_CALL_COUNT"
gh_call_count() { cat "$GH_CALL_COUNT"; }

# Mock gh. MOCK_GH_REMAINING controls .resources.graphql.remaining;
# MOCK_GH_MODE switches between "ok" (well-formed JSON), "malformed"
# (JSON without graphql.remaining), "http-error" (gh exits non-zero
# with stderr noise), and "empty" (gh exits 0 with no stdout).
gh() {
    local n; n=$(<"$GH_CALL_COUNT"); printf '%d\n' $(( n + 1 )) > "$GH_CALL_COUNT"
    # The gate calls only `gh api /rate_limit` (with optional GH_TOKEN
    # env). The shape we emit mirrors the real /rate_limit response.
    case "${MOCK_GH_MODE:-ok}" in
        ok)
            local remaining="${MOCK_GH_REMAINING:-5000}"
            cat <<JSON
{
  "resources": {
    "core":    {"limit": 5000, "remaining": 4990, "used": 10},
    "graphql": {"limit": 5000, "remaining": $remaining, "used": $(( 5000 - remaining ))},
    "search":  {"limit": 30,   "remaining": 30,   "used": 0}
  }
}
JSON
            return 0
            ;;
        malformed)
            cat <<'JSON'
{"resources":{"core":{"limit":5000,"remaining":4990,"used":10}}}
JSON
            return 0
            ;;
        http-error)
            printf '%s\n' 'gh: HTTP 502: bad gateway' >&2
            return 1
            ;;
        empty)
            return 0
            ;;
        *)
            printf 'unknown MOCK_GH_MODE: %s\n' "${MOCK_GH_MODE:-}" >&2
            return 1
            ;;
    esac
}
export -f gh

# `timeout` shadow (issue #367). `_snapshot_graphql` wraps each gh call
# in `timeout -k <k> <s> gh …`; the real binary can't exec the `gh`
# bash-function shadow above, so intercept it: strip the `-k <k>` flag
# and the duration, then run the remaining argv (`gh …`) so the mock
# keeps serving fixtures (without this, the real gh runs and returns
# empty, making positive assertions silently fail).
timeout() {
    while [[ "${1:-}" == -* ]]; do
        case "$1" in
            -k|--kill-after) shift 2 ;;
            *)               shift ;;
        esac
    done
    shift   # drop the duration argument
    "$@"
}
export -f timeout

# Selective `date` shadow. Only intercepts `date +%s`; passes the
# rest through so log-line timestamps (`date -Is`) still work.
date() {
    if [[ "${1:-}" == "+%s" && -n "${MOCK_DATE_NOW:-}" ]]; then
        printf '%s\n' "$MOCK_DATE_NOW"
    else
        command date "$@"
    fi
}
export -f date

reset_state() {
    rm -rf "$STATE_DIR"
    mkdir -p "$STATE_DIR"
    printf '0\n' > "$GH_CALL_COUNT"
    unset MOCK_DATE_NOW
}

# ---- Test 1: healthy bucket → run ---------------------------------------

echo '=== remaining > threshold → run ==='
reset_state
GRAPHQL_THRESHOLD=200 MOCK_GH_MODE=ok MOCK_GH_REMAINING=4500 \
    _graphql_polling_gate
rc=$?
assert_eq "remaining=4500, threshold=200 → returns 0 (run)" "$rc" "0"
assert_eq "exactly one gh probe issued"                     "$(gh_call_count)" "1"

# ---- Test 2: bucket below threshold → skip + alert log -----------------

echo '=== remaining < threshold → skip + alert ==='
reset_state
GRAPHQL_THRESHOLD=200 MOCK_GH_MODE=ok MOCK_GH_REMAINING=150 \
    _graphql_polling_gate
rc=$?
assert_eq "remaining=150, threshold=200 → returns 1 (skip)"      "$rc" "1"
assert_file_exists "watcher-alerts.log written for below-floor" "$STATE_DIR/watcher-alerts.log"
log_body=$(<"$STATE_DIR/watcher-alerts.log")
assert_contains "alert log classifies as below_floor"           "$log_body" "below_floor"
assert_contains "alert log cites graphql.remaining value"       "$log_body" "graphql.remaining=150"
assert_contains "alert log cites threshold value"               "$log_body" "threshold=200"

# ---- Test 3: malformed JSON → skip + log --------------------------------

echo '=== /rate_limit returns malformed JSON → skip ==='
reset_state
GRAPHQL_THRESHOLD=200 MOCK_GH_MODE=malformed \
    _graphql_polling_gate
rc=$?
assert_eq "malformed probe → returns 1 (skip)"               "$rc" "1"
assert_file_exists "alert log written for malformed JSON"   "$STATE_DIR/watcher-alerts.log"
log_body=$(<"$STATE_DIR/watcher-alerts.log")
assert_contains "alert log classifies as probe_malformed"   "$log_body" "probe_malformed"

# ---- Test 4: gh HTTP error → skip + log ---------------------------------

echo '=== /rate_limit returns HTTP error → skip ==='
reset_state
GRAPHQL_THRESHOLD=200 MOCK_GH_MODE=http-error \
    _graphql_polling_gate 2>/dev/null
rc=$?
assert_eq "http-error probe → returns 1 (skip)"             "$rc" "1"
assert_file_exists "alert log written for http error"      "$STATE_DIR/watcher-alerts.log"
log_body=$(<"$STATE_DIR/watcher-alerts.log")
assert_contains "alert log classifies as probe_failed"     "$log_body" "probe_failed"

# ---- Test 5: alert log throttled to one per 10 min per kind --------------

echo '=== alert log throttled (one per 10 min per kind) ==='
reset_state
MOCK_DATE_NOW=1000000000
GRAPHQL_THRESHOLD=200 MOCK_GH_MODE=ok MOCK_GH_REMAINING=10 \
    _graphql_polling_gate
log_lines_1=$(wc -l < "$STATE_DIR/watcher-alerts.log" | tr -d ' ')
assert_eq "first below-floor: 1 alert log line"             "$log_lines_1" "1"

# Same kind within 10 min → no new line.
MOCK_DATE_NOW=1000000300
GRAPHQL_THRESHOLD=200 MOCK_GH_MODE=ok MOCK_GH_REMAINING=10 \
    _graphql_polling_gate
log_lines_2=$(wc -l < "$STATE_DIR/watcher-alerts.log" | tr -d ' ')
assert_eq "second below-floor within 5 min: still 1 line"  "$log_lines_2" "1"

# Past the 10 min window → new line.
MOCK_DATE_NOW=1000000700
GRAPHQL_THRESHOLD=200 MOCK_GH_MODE=ok MOCK_GH_REMAINING=10 \
    _graphql_polling_gate
log_lines_3=$(wc -l < "$STATE_DIR/watcher-alerts.log" | tr -d ' ')
assert_eq "third below-floor past 10 min: 2 lines"          "$log_lines_3" "2"

# ---- Test 6: composes with per-surface backoff ---------------------------

# Sanity check that the gate runs upstream of `_graphql_backoff_active`.
# When the gate skips, _snapshot_* helpers never get a chance to run;
# when the gate passes, the per-surface backoff inside _snapshot_* is
# the only thing standing between snapshot_github and gh api graphql.
# We can't mock all the way down here without dragging the whole
# snapshot harness in, but we can verify the gate is order-independent
# of the backoff state (the gate must NOT consult per-surface backoff
# files; that's the surface-helper's job).

echo '=== gate is independent of per-surface backoff files ==='
reset_state
# Plant a per-surface backoff for issue_comments — the gate must not
# look at this file. Pass the gate with a healthy bucket; assert it
# returns 0 anyway.
printf '%s\n' "9999999999" > "$STATE_DIR/graphql-backoff-issue_comments"
GRAPHQL_THRESHOLD=200 MOCK_GH_MODE=ok MOCK_GH_REMAINING=4500 \
    _graphql_polling_gate
rc=$?
assert_eq "gate ignores per-surface backoff files (returns 0)" "$rc" "0"

# And per-surface backoff still works in isolation (regression
# tripwire — we're not breaking the existing _graphql_backoff_active
# behaviour).
_graphql_backoff_active issue_comments
rc=$?
assert_eq "_graphql_backoff_active still active for the surface" "$rc" "0"

# ---- Test 7: default threshold fallback when env unset ------------------

echo '=== unset threshold → default 200 ==='
reset_state
unset GRAPHQL_THRESHOLD
MOCK_GH_MODE=ok MOCK_GH_REMAINING=5000 _graphql_polling_gate
assert_eq "remaining=5000 with default threshold → run"     "$?" "0"

# Threshold default sanity: remaining=199 (1 below default 200) → skip.
reset_state
MOCK_GH_MODE=ok MOCK_GH_REMAINING=199 _graphql_polling_gate
assert_eq "remaining=199, default threshold → skip" "$?" "1"

# ---- summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
