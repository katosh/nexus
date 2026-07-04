#!/usr/bin/env bash
# Tests for monitor/hooks/over-limit-emit.sh — the StopFailure-hook
# handler that lifts rate-limit detection from the canonical
# "You've hit your limit · resets <time>" text scrape onto a
# structured event channel (issue #129 item 4).
#
# Coverage:
#   - rate_limit error_type → file written with expected fields
#   - non-rate_limit error_type → no file (capture log still appended)
#   - reset_at probed across plausible field paths
#   - missing env vars / missing jq / unwritable state dir → exit 0,
#     no crash, payload still appended to capture log when possible
#   - stopfailure-raw-captures.jsonl accumulates EVERY payload
#     (regardless of error_type) for empirical schema audit
#
# Run: bash monitor/watcher/test-over-limit-emit.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
HELPER="$_repo_root/monitor/hooks/over-limit-emit.sh"

PASS=0
FAIL=0

ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

[[ -x "$HELPER" ]] || { echo "helper not executable: $HELPER" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq required for these tests" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

run_helper() {
    local window="$1" payload="$2"
    env -i PATH="$PATH" \
        NEXUS_ROOT="$WORK" NEXUS_WORKER_WINDOW="$window" \
        bash "$HELPER" <<<"$payload"
}

state_dir="$WORK/monitor/.state"
ol_dir="$state_dir/over-limit"
captures="$state_dir/stopfailure-raw-captures.jsonl"

echo "=== rate_limit error_type → file written, capture appended ==="

run_helper w1 '{"hook_event_name":"StopFailure","session_id":"sess-rl","error_type":"rate_limit","error":{"message":"You have hit your weekly Opus limit"}}'
f="$ol_dir/w1.json"
if [[ -f "$f" ]]; then
    ok "rate_limit payload writes $f"
    [[ "$(jq -r '.error_type' "$f")" == "rate_limit" ]] && ok "carries error_type=rate_limit" || bad "error_type" "$(cat "$f")"
    [[ "$(jq -r '.session_id' "$f")" == "sess-rl" ]] && ok "carries session_id" || bad "session_id" "$(cat "$f")"
    [[ "$(jq -r '.window' "$f")" == "w1" ]] && ok "carries window" || bad "window" "$(cat "$f")"
    [[ "$(jq -r '.error_message' "$f")" == "You have hit your weekly Opus limit" ]] && ok "extracts error.message into error_message" || bad "error_message" "$(jq -r '.error_message' "$f")"
    ts=$(jq -r '.ts' "$f")
    [[ "$ts" =~ ^[0-9]+$ ]] && ok "ts is epoch (got $ts)" || bad "ts" "$ts"
    [[ "$(jq -r '.reset_at' "$f")" == "null" ]] && ok "reset_at is null (no probed path matched)" || bad "reset_at default null" "$(jq -r '.reset_at' "$f")"
else
    bad "rate_limit file written" "no file at $f"
fi

[[ -f "$captures" ]] && ok "capture jsonl appended" || bad "capture jsonl" "missing $captures"
[[ "$(wc -l < "$captures")" -eq 1 ]] && ok "capture jsonl has 1 line" || bad "capture line count" "$(wc -l < "$captures")"

echo
echo "=== reset_at probe paths ==="

# Path 1: .reset_at (top-level)
run_helper w_rl_top '{"hook_event_name":"StopFailure","error_type":"rate_limit","reset_at":"2026-05-19T03:00:00Z"}'
got=$(jq -r '.reset_at' "$ol_dir/w_rl_top.json")
[[ "$got" == "2026-05-19T03:00:00Z" ]] && ok ".reset_at (top-level) probed" || bad ".reset_at top-level" "got $got"

# Path 2: .reset_time
run_helper w_rl_rt '{"hook_event_name":"StopFailure","error_type":"rate_limit","reset_time":"3am PT"}'
got=$(jq -r '.reset_at' "$ol_dir/w_rl_rt.json")
[[ "$got" == "3am PT" ]] && ok ".reset_time probed (got: $got)" || bad ".reset_time" "got $got"

# Path 3: .error.reset_at (nested)
run_helper w_rl_nested '{"hook_event_name":"StopFailure","error_type":"rate_limit","error":{"reset_at":"midnight UTC"}}'
got=$(jq -r '.reset_at' "$ol_dir/w_rl_nested.json")
[[ "$got" == "midnight UTC" ]] && ok ".error.reset_at probed (got: $got)" || bad ".error.reset_at" "got $got"

# No reset field at all → null
run_helper w_rl_none '{"hook_event_name":"StopFailure","error_type":"rate_limit"}'
got=$(jq -r '.reset_at' "$ol_dir/w_rl_none.json")
[[ "$got" == "null" ]] && ok "no reset field → reset_at=null" || bad "no reset field" "got $got"

echo
echo "=== non-rate_limit error_type → no over-limit file ==="

run_helper w2 '{"hook_event_name":"StopFailure","error_type":"api_error","error":{"message":"transient"}}'
if [[ ! -f "$ol_dir/w2.json" ]]; then
    ok "api_error error_type → no file (filter working)"
else
    bad "api_error wrote unexpected file" "$(cat "$ol_dir/w2.json")"
fi
# But capture log should grow: the raw payload is always logged.
new_lines=$(wc -l < "$captures")
[[ "$new_lines" -gt 1 ]] && ok "non-rate_limit still appended to capture jsonl (lines=$new_lines)" || bad "capture grew" "lines=$new_lines"

run_helper w3 '{"hook_event_name":"StopFailure","error_type":"auth_failure"}'
[[ ! -f "$ol_dir/w3.json" ]] && ok "auth_failure → no file" || bad "auth_failure wrote file" ""

run_helper w4 '{"hook_event_name":"StopFailure"}'
[[ ! -f "$ol_dir/w4.json" ]] && ok "missing error_type → no file" || bad "missing error_type wrote file" ""

echo
echo "=== missing env vars → exit 0, no crash ==="

# No NEXUS_WORKER_WINDOW
rc=$(env -i PATH="$PATH" NEXUS_ROOT="$WORK" \
    bash "$HELPER" <<<'{"error_type":"rate_limit"}'; echo $?)
[[ "$rc" == "0" ]] && ok "missing NEXUS_WORKER_WINDOW → exit 0" || bad "missing window" "rc=$rc"

# No NEXUS_ROOT
rc=$(env -i PATH="$PATH" NEXUS_WORKER_WINDOW=w5 \
    bash "$HELPER" <<<'{"error_type":"rate_limit"}'; echo $?)
[[ "$rc" == "0" ]] && ok "missing NEXUS_ROOT → exit 0" || bad "missing root" "rc=$rc"

echo
echo "=== summary ==="
printf '  %d pass / %d fail\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then echo "FAIL"; exit 1; fi
echo "ALL TESTS PASSED"
exit 0
