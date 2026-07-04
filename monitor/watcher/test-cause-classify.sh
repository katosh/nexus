#!/usr/bin/env bash
# Tests for monitor/hooks/_cause_classify.sh — the pure StopFailure
# cause classifier that maps an (error_token, last_message) pair to a
# `<category>\t<recovery>` verdict. The mapping decides paste-vs-
# respawn-vs-operator recovery for an interrupted-mid-turn worker.
#
# Coverage:
#   - every observed production error token (server_error,
#     model_not_found, "unknown"→message probe) → correct verdict
#   - rate_limit short-circuits to `none` (over-limit-emit owns it)
#   - message-text fallback when the token is absent/unknown
#   - case-insensitivity
#   - the optimistic default (paste) for a truly unrecognised failure
#   - mutation guards: a wrong mapping would flip recovery and fail
#
# Run: bash monitor/watcher/test-cause-classify.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
LIB="$_repo_root/monitor/hooks/_cause_classify.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

[[ -r "$LIB" ]] || { echo "lib not readable: $LIB" >&2; exit 1; }
# shellcheck source=/dev/null
. "$LIB"

# expect <desc> <error> <last_msg> <expected category:recovery>
expect() {
    local desc="$1" err="$2" msg="$3" want="$4"
    local got
    got=$(cause_classify_error "$err" "$msg")
    got="${got//$'\t'/:}"
    if [[ "$got" == "$want" ]]; then
        ok "$desc → $got"
    else
        bad "$desc" "want=$want got=$got"
    fi
}

echo "=== structured token mapping (production-observed tokens) ==="
expect "server_error (HTTP 500/529)"      "server_error"     "API Error: 500 Internal server error." "transient:paste"
expect "overloaded_error"                 "overloaded_error" ""                                       "transient:paste"
expect "api_error generic"                "api_error"        ""                                       "transient:paste"
expect "model_not_found → respawn"        "model_not_found"  "There's an issue with the selected model" "config:respawn"
expect "authentication_error → operator"  "authentication_error" ""                                   "auth:operator"
expect "rate_limit short-circuits"        "rate_limit"       "You've hit your limit"                  "rate_limit:none"

echo "=== message-text fallback when token absent/unknown ==="
expect "unknown token + 500 message"      "unknown" "API Error: 500 Internal server error. server-side issue" "transient:paste"
expect "unknown token + 529 overloaded"   "unknown" "API Error: 529 Overloaded. This is a server-side issue"  "transient:paste"
expect "unknown token + 400 thinking-block" "unknown" "API Error: 400 messages.1: thinking blocks cannot be"  "conversation:respawn"
expect "unknown token + model message"    "unknown" "selected model may not exist or you may not have access to it" "config:respawn"
expect "empty token + rate-limit message" ""        "You have hit your usage limit"                          "rate_limit:none"

echo "=== case-insensitivity ==="
expect "uppercase SERVER_ERROR"           "SERVER_ERROR" ""  "transient:paste"
expect "mixed Model_Not_Found"            "Model_Not_Found" "" "config:respawn"

echo "=== optimistic default for unrecognised failure ==="
expect "wholly unknown → paste default"   "weird_new_error" "some message with no signal" "unknown:paste"
expect "both empty → paste default"       "" ""                                           "unknown:paste"

echo "=== mutation guards (a flipped mapping must fail) ==="
# model_not_found must NOT be paste-recoverable (a resume re-runs the
# doomed turn). If someone changes config→paste, this fails.
got=$(cause_classify_error "model_not_found" ""); got="${got//$'\t'/:}"
[[ "$got" != "config:paste" && "$got" == "config:respawn" ]] \
    && ok "model_not_found is respawn, never paste" \
    || bad "model_not_found mutation guard" "$got"
# server_error must NOT escalate to operator (it's a transient blip).
got=$(cause_classify_error "server_error" ""); got="${got//$'\t'/:}"
[[ "$got" == "transient:paste" ]] \
    && ok "server_error stays transient:paste (no operator escalation)" \
    || bad "server_error mutation guard" "$got"

echo
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED ($PASS)"
    exit 0
else
    echo "FAILED: $FAIL (passed $PASS)" >&2
    exit 1
fi
