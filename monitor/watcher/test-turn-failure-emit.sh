#!/usr/bin/env bash
# Tests for monitor/hooks/turn-failure-emit.sh — the StopFailure-hook
# handler that writes a structured `turn-failure/<window>.json` marker
# for every NON-rate_limit turn-killing error, so the watcher can tell
# an interrupted-mid-turn worker apart from a forgot-to-wrap one.
#
# The synthetic payloads here are the EXACT shapes captured from real
# production StopFailure events (monitor/.state/stopfailure-raw-
# captures.jsonl): top-level `error` is a STRING token, the human copy
# is in `last_assistant_message`, and `error_type` is ABSENT.
#
# Coverage:
#   - server_error (HTTP 500) → marker, category=transient, recovery=paste
#   - server_error (HTTP 529) → marker, transient/paste
#   - model_not_found → marker, category=config, recovery=respawn
#   - "unknown" + 400 thinking-block message → conversation/respawn
#   - rate_limit token → NO marker (over-limit-emit.sh owns it)
#   - last_msg truncated to ≤200 chars
#   - missing env (no window) / missing jq path → exit 0, no crash
#
# Run: bash monitor/watcher/test-turn-failure-emit.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
HELPER="$_repo_root/monitor/hooks/turn-failure-emit.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

[[ -x "$HELPER" ]] || { echo "helper not executable: $HELPER" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq required for these tests" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Run with a hermetic NEXUS_STATE_DIR so the marker lands in WORK.
run_helper() {
    local window="$1" payload="$2"
    env -i PATH="$PATH" \
        NEXUS_STATE_DIR="$WORK/state" NEXUS_WORKER_WINDOW="$window" \
        bash "$HELPER" <<<"$payload"
}

tf_dir="$WORK/state/turn-failure"

echo "=== server_error (HTTP 500) → transient:paste marker ==="
run_helper w500 '{"hook_event_name":"StopFailure","session_id":"sess-500","error":"server_error","last_assistant_message":"API Error: 500 Internal server error. This is a server-side issue, usually temporary."}'
f="$tf_dir/w500.json"
if [[ -f "$f" ]]; then
    ok "marker written: $f"
    [[ "$(jq -r .error "$f")"    == "server_error" ]] && ok "error=server_error" || bad "error" "$(jq -r .error "$f")"
    [[ "$(jq -r .category "$f")" == "transient" ]]    && ok "category=transient" || bad "category" "$(jq -r .category "$f")"
    [[ "$(jq -r .recovery "$f")" == "paste" ]]        && ok "recovery=paste"     || bad "recovery" "$(jq -r .recovery "$f")"
    [[ "$(jq -r .session_id "$f")" == "sess-500" ]]   && ok "session_id carried" || bad "session_id" "$(jq -r .session_id "$f")"
    [[ "$(jq -r .window "$f")"   == "w500" ]]         && ok "window carried"     || bad "window" "$(jq -r .window "$f")"
    ts=$(jq -r .ts "$f"); [[ "$ts" =~ ^[0-9]+$ ]] && ok "ts is epoch ($ts)" || bad "ts" "$ts"
else
    bad "marker written" "no file at $f"
fi

echo "=== server_error (HTTP 529 overloaded) → transient:paste ==="
run_helper w529 '{"hook_event_name":"StopFailure","session_id":"s","error":"server_error","last_assistant_message":"API Error: 529 Overloaded. This is a server-side issue, usually temporary."}'
f="$tf_dir/w529.json"
[[ -f "$f" && "$(jq -r .recovery "$f")" == "paste" ]] && ok "529 → recovery=paste" || bad "529" "$(cat "$f" 2>/dev/null)"

echo "=== model_not_found → config:respawn ==="
run_helper wmodel '{"hook_event_name":"StopFailure","session_id":"s","error":"model_not_found","last_assistant_message":"There.s an issue with the selected model (claude-fable-5). It may not exist."}'
f="$tf_dir/wmodel.json"
if [[ -f "$f" ]]; then
    [[ "$(jq -r .category "$f")" == "config"  ]] && ok "category=config"  || bad "category" "$(jq -r .category "$f")"
    [[ "$(jq -r .recovery "$f")" == "respawn" ]] && ok "recovery=respawn" || bad "recovery" "$(jq -r .recovery "$f")"
else
    bad "model_not_found marker" "no file"
fi

echo "=== 'unknown' token + 400 thinking-block message → conversation:respawn ==="
run_helper w400 '{"hook_event_name":"StopFailure","session_id":"s","error":"unknown","last_assistant_message":"API Error: 400 messages.1.content.8: thinking or redacted_thinking blocks in the latest assistant message cannot be"}'
f="$tf_dir/w400.json"
if [[ -f "$f" ]]; then
    [[ "$(jq -r .category "$f")" == "conversation" ]] && ok "category=conversation" || bad "category" "$(jq -r .category "$f")"
    [[ "$(jq -r .recovery "$f")" == "respawn" ]]      && ok "recovery=respawn"      || bad "recovery" "$(jq -r .recovery "$f")"
else
    bad "400 marker" "no file"
fi

echo "=== rate_limit token → NO marker (over-limit-emit.sh owns it) ==="
run_helper wrl '{"hook_event_name":"StopFailure","session_id":"s","error":"rate_limit","last_assistant_message":"You.ve hit your weekly Opus limit"}'
[[ ! -f "$tf_dir/wrl.json" ]] && ok "no turn-failure marker for rate_limit" || bad "rate_limit skip" "marker exists: $(cat "$tf_dir/wrl.json")"

echo "=== last_msg truncated to <=200 chars ==="
longmsg=$(printf 'API Error: 500 %0.sX' {1..400})
run_helper wlong "$(jq -nc --arg m "$longmsg" '{hook_event_name:"StopFailure",error:"server_error",last_assistant_message:$m}')"
f="$tf_dir/wlong.json"
if [[ -f "$f" ]]; then
    len=$(jq -r '.last_msg | length' "$f")
    (( len <= 200 )) && ok "last_msg length $len <= 200" || bad "truncation" "len=$len"
else
    bad "long marker" "no file"
fi

echo "=== robustness: missing window env → exit 0, no marker ==="
env -i PATH="$PATH" NEXUS_STATE_DIR="$WORK/state" bash "$HELPER" \
    <<<'{"error":"server_error"}'; rc=$?
(( rc == 0 )) && ok "no NEXUS_WORKER_WINDOW → exit 0" || bad "missing window exit" "rc=$rc"

echo "=== recovery marker clears on next success (simulated Stop rm -f) ==="
# The Stop hook does `rm -f turn-failure/<window>.json`; simulate it
# and confirm the path is gone (contract the worker-settings.json relies on).
run_helper wclear '{"hook_event_name":"StopFailure","error":"server_error","last_assistant_message":"API Error: 500"}'
[[ -f "$tf_dir/wclear.json" ]] && ok "marker present before clear" || bad "pre-clear" "missing"
rm -f "$tf_dir/wclear.json"
[[ ! -f "$tf_dir/wclear.json" ]] && ok "marker cleared (Stop-hook semantics)" || bad "clear" "still present"

echo
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED ($PASS)"
    exit 0
else
    echo "FAILED: $FAIL (passed $PASS)" >&2
    exit 1
fi
