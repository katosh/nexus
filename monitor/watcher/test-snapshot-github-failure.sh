#!/usr/bin/env bash
# Mock-gh unit tests for the detect-and-react path in
# monitor/watcher/_github.sh: rate-limit sentinel emit, per-surface
# backoff short-circuit, backoff expiry, and unknown-error logging.
#
# Run: bash monitor/watcher/test-snapshot-github-failure.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: shadow `gh` with a bash function whose behaviour is
# selected via env vars (MOCK_GH_MODE, MOCK_GH_STDERR). The
# unit-under-test calls gh inside a $(...) command substitution that
# captures its stdout and routes its stderr to a tempfile via
# 2>"$_err". When MOCK_GH_MODE=fail, the mock writes a canned body to
# stderr and exits 1 — exercising _watcher_handle_graphql_failure.
# When MOCK_GH_MODE=ok, the mock prints an empty search response and
# exits 0 — exercising the happy path after backoff expiry.
#
# `date` is also shadowed for the expiry test: setting MOCK_DATE_NOW
# overrides `date +%s` so the test can advance time past
# (reset + 30 s) without sleeping. The shadow is selective —
# `date -Is`, `date -d "@<epoch>" -Is`, etc. fall through to the real
# binary so log timestamps remain readable.

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
assert_file_exists() {
    local label="$1" path="$2"
    if [[ -f "$path" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — missing file: %s\n' "$label" "$path" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_file_absent() {
    local label="$1" path="$2"
    if [[ ! -e "$path" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — unexpected file: %s\n' "$label" "$path" >&2
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
export STATE_DIR REPO USER_LOGIN

# Source the unit under test.
. "$_test_dir/_github.sh"

# Real GitHub graphql_rate_limit body (verbatim shape; epoch + ISO
# stripped to placeholders so the test is portable). The unit-under-
# test classifies on the `"type":"RATE_LIMIT"` /
# `"code":"graphql_rate_limit"` substring; reset epoch is parsed from
# `extensions.reset_at_epoch` if present.
RATE_LIMIT_BODY='{
  "errors": [
    {
      "type": "RATE_LIMIT",
      "code": "graphql_rate_limit",
      "message": "API rate limit exceeded for installation ID 124868979.",
      "extensions": {
        "reset_at_epoch": 1893456000,
        "reset_at": "2030-01-01T00:00:00Z"
      }
    }
  ]
}'
TRANSIENT_BODY='{"message":"connection reset"}'
# gh CLI flattens rate-limit errors into a human-readable text form
# (no JSON) when it handles the GraphQL error itself before printing.
# This is the production signature actually observed on 2026-05-01;
# the JSON body above is only emitted on the rare "raw GraphQL error"
# path. Both must classify as rate-limit.
GH_CLI_RATE_LIMIT_TEXT='gh: API rate limit already exceeded for installation ID 124868979.'

# Counter file the mock bumps on every invocation. Tests use this to
# assert the unit actually called (or did not call) gh.
GH_CALL_COUNT="$WORK/gh-call-count"
printf '0\n' > "$GH_CALL_COUNT"

gh_call_count() { cat "$GH_CALL_COUNT"; }

gh() {
    local n; n=$(<"$GH_CALL_COUNT"); printf '%d\n' $(( n + 1 )) > "$GH_CALL_COUNT"
    case "${MOCK_GH_MODE:-fail}" in
        fail-rate-limit)
            printf '%s' "$RATE_LIMIT_BODY" >&2
            return 1
            ;;
        fail-transient)
            printf '%s' "$TRANSIENT_BODY" >&2
            return 1
            ;;
        fail-rate-limit-cli)
            printf '%s\n' "$GH_CLI_RATE_LIMIT_TEXT" >&2
            return 1
            ;;
        ok)
            printf '%s' '{"data":{"search":{"nodes":[]}}}'
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
# bash-function shadow above, so intercept it here: strip the
# `-k <k>` flag + the duration, then run the remaining argv (`gh …`)
# so the existing mock keeps serving. Set MOCK_GH_TIMEOUT=term to
# simulate a SIGTERM timeout (exit 124) or =kill for the SIGKILL
# backstop (exit 137) — without ever invoking gh (mirrors a hung call
# that produced no usable output).
timeout() {
    while [[ "${1:-}" == -* ]]; do
        case "$1" in
            -k|--kill-after) shift 2 ;;
            *)               shift ;;
        esac
    done
    shift   # drop the duration argument
    case "${MOCK_GH_TIMEOUT:-}" in
        term) return 124 ;;
        kill) return 137 ;;
    esac
    "$@"
}
export -f timeout

# Selective `date` shadow. Only intercepts `date +%s`; passes the rest
# through to the real binary so ISO formatting and `date -d "@<epoch>"`
# still work for log lines and reset_iso rendering.
date() {
    if [[ "${1:-}" == "+%s" && -n "${MOCK_DATE_NOW:-}" ]]; then
        printf '%s\n' "$MOCK_DATE_NOW"
    else
        command date "$@"
    fi
}
export -f date

# ---- Test 1: rate-limit sentinel + backoff state ------------------------

echo '=== rate-limit response: emits sentinel, writes state ==='
MOCK_GH_MODE=fail-rate-limit
unset MOCK_DATE_NOW

out=$(_snapshot_issue_comments "" 2>/dev/null)
rc=$?
assert_eq "_snapshot_issue_comments returns 0 on rate-limit"     "$rc" "0"
assert_contains "stdout has watcher_alert= sentinel header"      "$out" "watcher_alert=rate-limit surface=issue_comments"
assert_contains "stdout has reset epoch (parsed from body)"      "$out" "reset=1893456000"
assert_contains "stdout has body: continuation line"             "$out" "  body: GraphQL bucket exhausted"
assert_contains "stdout body cites the surface"                  "$out" "suppressing issue_comments snapshot until"

# Exactly one sentinel header per (surface, reset) — the line shape is
# "watcher_alert=rate-limit surface=...". Counting that prefix is the
# right dedup unit.
sentinel_count=$(grep -c '^watcher_alert=rate-limit ' <<<"$out" || true)
assert_eq "exactly one watcher_alert= line emitted"              "$sentinel_count" "1"

assert_file_exists "backoff state file written"                  "$STATE_DIR/graphql-backoff-issue_comments"
backoff_epoch=$(<"$STATE_DIR/graphql-backoff-issue_comments")
assert_eq "backoff file holds parsed reset epoch"                "$backoff_epoch" "1893456000"

assert_file_exists "alert-emitted flag file written"             "$STATE_DIR/graphql-alert-emitted-issue_comments-1893456000"

assert_file_exists "watcher-alerts.log written"                  "$STATE_DIR/watcher-alerts.log"
log_lines=$(wc -l < "$STATE_DIR/watcher-alerts.log" | tr -d ' ')
assert_eq "exactly one log line on first detection"              "$log_lines" "1"
log_body=$(<"$STATE_DIR/watcher-alerts.log")
assert_contains "log line classifies as graphql_rate_limit"      "$log_body" "graphql_rate_limit"
assert_contains "log line names the surface"                     "$log_body" "issue_comments"

# ---- Test 2: backoff short-circuits subsequent calls --------------------

echo '=== second call within backoff window: no gh call, no new emit ==='
MOCK_GH_MODE=fail-rate-limit
# Pin "now" inside the backoff window. reset=1893456000 is in 2030;
# pinning to 1893455000 keeps us 1000 s before reset (well within the
# 30 s grace).
MOCK_DATE_NOW=1893455000
calls_before=$(gh_call_count)
out2=$(_snapshot_issue_comments "" 2>/dev/null)
rc2=$?
calls_after=$(gh_call_count)
assert_eq "_snapshot_issue_comments returns 0 during backoff"    "$rc2" "0"
assert_eq "stdout empty during backoff (no re-emit)"             "$out2" ""
assert_eq "no new gh call during backoff"                        "$calls_after" "$calls_before"

log_lines_after=$(wc -l < "$STATE_DIR/watcher-alerts.log" | tr -d ' ')
assert_eq "no new log line during backoff"                       "$log_lines_after" "1"

# ---- Test 3: backoff expires past reset+30 s ----------------------------

echo '=== now > reset + 30 s: backoff cleaned up, gh called again ==='
MOCK_GH_MODE=ok
# Pin "now" to (reset + 60 s) — comfortably past the 30 s grace.
MOCK_DATE_NOW=$(( 1893456000 + 60 ))
calls_before=$(gh_call_count)
out3=$(_snapshot_issue_comments "" 2>/dev/null)
rc3=$?
calls_after=$(gh_call_count)
assert_eq "_snapshot_issue_comments returns 0 after expiry"      "$rc3" "0"
assert_eq "stdout empty (mock returned no eligible nodes)"       "$out3" ""
assert_eq "gh was called once after expiry"                      "$calls_after" "$(( calls_before + 1 ))"
assert_file_absent "backoff file removed after expiry"           "$STATE_DIR/graphql-backoff-issue_comments"
assert_file_absent "alert-emitted flag removed after expiry"     "$STATE_DIR/graphql-alert-emitted-issue_comments-1893456000"

# ---- Test 4: transient (non-rate-limit) failure: log only, no sentinel --

echo '=== transient failure: log line, no sentinel emit, no backoff ==='
unset MOCK_DATE_NOW
MOCK_GH_MODE=fail-transient
# Fresh STATE_DIR for clean assertions.
rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"
out4=$(_snapshot_issue_comments "" 2>/dev/null)
rc4=$?
assert_eq "_snapshot_issue_comments returns 0 on transient"      "$rc4" "0"
assert_eq "no sentinel emit for transient"                       "$out4" ""
assert_file_absent "no backoff file for transient"               "$STATE_DIR/graphql-backoff-issue_comments"
assert_file_exists "watcher-alerts.log written for transient"    "$STATE_DIR/watcher-alerts.log"
log_lines4=$(wc -l < "$STATE_DIR/watcher-alerts.log" | tr -d ' ')
assert_eq "exactly one log line for transient"                   "$log_lines4" "1"
log_body4=$(<"$STATE_DIR/watcher-alerts.log")
assert_contains "transient log line classified as graphql_failure" "$log_body4" "graphql_failure"
assert_not_contains "transient log line NOT classified as rate-limit" "$log_body4" "graphql_rate_limit"

# ---- Test 4b: gh-CLI flattened rate-limit text (no JSON) classifies ---

echo '=== gh-CLI text rate-limit: classify + sentinel + backoff ==='
unset MOCK_DATE_NOW
MOCK_GH_MODE=fail-rate-limit-cli
rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"
out4b=$(_snapshot_issue_comments "" 2>/dev/null)
rc4b=$?
assert_eq "_snapshot_issue_comments returns 0 on cli rate-limit"  "$rc4b" "0"
assert_contains "cli text emits rate-limit sentinel"              "$out4b" "watcher_alert=rate-limit surface=issue_comments"
assert_file_exists "cli text writes backoff file"                 "$STATE_DIR/graphql-backoff-issue_comments"
log4b=$(<"$STATE_DIR/watcher-alerts.log")
assert_contains "cli text logs as graphql_rate_limit"             "$log4b" "graphql_rate_limit"

# ---- Test 5: per-surface independence (pr_comments + new_issues) -------

echo '=== per-surface backoff: each surface has its own state ==='
rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"
MOCK_GH_MODE=fail-rate-limit
out_pr=$(_snapshot_pr_comments "" 2>/dev/null)
out_ni=$(_snapshot_new_issues "" 2>/dev/null)
assert_contains "pr_comments emits sentinel with its surface name" "$out_pr" "watcher_alert=rate-limit surface=pr_comments"
assert_contains "new_issues emits sentinel with its surface name"  "$out_ni" "watcher_alert=rate-limit surface=new_issues"
assert_file_exists "pr_comments backoff file"                    "$STATE_DIR/graphql-backoff-pr_comments"
assert_file_exists "new_issues backoff file"                     "$STATE_DIR/graphql-backoff-new_issues"

# ---- Test 6: hung graphql call (timeout) — fail fast, log, no wedge ----
#
# issue #367: a hung `gh api graphql` must NOT freeze the scheduler.
# `_snapshot_graphql` bounds it with `timeout`; on the timeout exit
# codes it appends a `graphql_timeout` marker to stderr, which
# `_watcher_handle_graphql_failure` classifies as a (non-rate-limit)
# `graphql_failure`: logs one throttled line, NO backoff, returns 0 so
# the scheduler continues to the next surface and retries next cycle.
echo '=== SIGTERM timeout (124): logs graphql_timeout, no backoff, returns 0 ==='
unset MOCK_DATE_NOW
rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
MOCK_GH_TIMEOUT=term
out6=$(_snapshot_issue_comments "" 2>/dev/null)
rc6=$?
assert_eq "_snapshot_issue_comments returns 0 on timeout (scheduler continues)" "$rc6" "0"
assert_eq "no sentinel emit for timeout"                         "$out6" ""
assert_file_absent "no backoff file for timeout (retry next cycle)" "$STATE_DIR/graphql-backoff-issue_comments"
assert_file_exists "watcher-alerts.log written for timeout"      "$STATE_DIR/watcher-alerts.log"
log6=$(<"$STATE_DIR/watcher-alerts.log")
assert_contains "timeout log line classified as graphql_failure" "$log6" "graphql_failure"
assert_contains "timeout log line carries the graphql_timeout marker" "$log6" "graphql_timeout"
assert_not_contains "timeout NOT classified as rate-limit"       "$log6" "graphql_rate_limit"

echo '=== timeout log is throttled (no second line within 10 min) ==='
out6b=$(_snapshot_issue_comments "" 2>/dev/null)
log_lines6=$(grep -c 'graphql_failure' "$STATE_DIR/watcher-alerts.log")
assert_eq "second timeout within 10 min is throttled"            "$log_lines6" "1"

echo '=== SIGKILL backstop (137) also classifies as graphql_timeout ==='
rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
MOCK_GH_TIMEOUT=kill
out6c=$(_snapshot_pr_comments "" 2>/dev/null)
rc6c=$?
assert_eq "_snapshot_pr_comments returns 0 on KILL backstop"     "$rc6c" "0"
log6c=$(<"$STATE_DIR/watcher-alerts.log")
assert_contains "KILL backstop logs graphql_timeout"             "$log6c" "graphql_timeout"
assert_contains "KILL backstop names the pr_comments surface"    "$log6c" "pr_comments"
unset MOCK_GH_TIMEOUT

# ---- mint-token failure surfaces a throttled WARN (#180 R4) -------------
#
# A failed/empty mint token skips the whole snapshot. Before R4 that
# happened silently; now snapshot_github leaves a WARN in
# watcher-alerts.log and never reaches gh.
echo '=== mint-token failure: WARN to alerts.log, gh not called, throttled ==='
MINT_WORK="$WORK/mint"
mkdir -p "$MINT_WORK"
ALERTS="$STATE_DIR/watcher-alerts.log"
: > "$ALERTS"
rm -f "$STATE_DIR/mint-token-last-warn"
printf '0\n' > "$GH_CALL_COUNT"

# Stub mint that fails (exit 1, empty stdout).
FAIL_MINT="$MINT_WORK/mint-fail.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAIL_MINT"
chmod +x "$FAIL_MINT"

MINT_TOKEN_BIN="$FAIL_MINT" snapshot_github 2>/dev/null
alerts_content=$(<"$ALERTS")
assert_contains "alerts.log carries the mint WARN" "$alerts_content" "WARN mint-token failed or returned empty"
assert_contains "WARN names the consequence"       "$alerts_content" "eligible comments will NOT surface"
assert_eq       "gh never called on mint failure"  "$(gh_call_count)" "0"

# Throttle: a second immediate failure within 10 min adds no new row.
warn_lines_1=$(grep -c 'WARN mint-token failed' "$ALERTS")
MINT_TOKEN_BIN="$FAIL_MINT" snapshot_github 2>/dev/null
warn_lines_2=$(grep -c 'WARN mint-token failed' "$ALERTS")
assert_eq "second failure within 10 min is throttled (no new WARN row)" "$warn_lines_2" "$warn_lines_1"

# An empty-but-success mint (exit 0, empty stdout) is treated the same.
: > "$ALERTS"; rm -f "$STATE_DIR/mint-token-last-warn"; printf '0\n' > "$GH_CALL_COUNT"
EMPTY_MINT="$MINT_WORK/mint-empty.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$EMPTY_MINT"   # prints nothing
chmod +x "$EMPTY_MINT"
MINT_TOKEN_BIN="$EMPTY_MINT" snapshot_github 2>/dev/null
assert_contains "empty-token mint also WARNs" "$(<"$ALERTS")" "WARN mint-token failed or returned empty"
assert_eq       "gh not called on empty token" "$(gh_call_count)" "0"

# ---- summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
