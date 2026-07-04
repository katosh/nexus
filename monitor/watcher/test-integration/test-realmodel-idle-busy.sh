#!/usr/bin/env bash
# test-realmodel-idle-busy.sh — first real-binary scenario.
#
# Boots the REAL `claude` binary against the auth-free mock backend
# (monitor/cc-harness/mock-backend.py) in an isolated tmux socket and
# walks it through idle -> busy -> idle -> absent, asserting the
# production monitor/pane-state.sh classifies each induced state and
# that an injected prompt round-trips to the mock's canned text.
#
# Unlike the stub-claude integration suite, this exercises the real
# boot / hook / tool-loop / pane-rendering surface with NO Anthropic
# auth and NO network egress. Gated on RUN_CC_HARNESS=1 (+ node + a
# resolvable claude binary); self-skips otherwise. See
# monitor/cc-harness/README.md.

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_self_dir/../_test_helpers.sh"
. "$_self_dir/../../cc-harness/_lib.sh"

cch_skip_if_disabled
cch_setup

echo "=== real-binary harness: idle -> busy -> idle -> absent ==="
echo "    claude:  $CLAUDE_BIN"
echo "    mock:    127.0.0.1:$CCH_MOCK_PORT"

win=$(cch_boot_worker w1)
[[ -n "$win" ]] || { echo "FAIL: worker window never appeared" >&2; exit 1; }

# 1. Boot completes -> idle prompt. The real binary needs a few seconds
#    to render its TUI, so poll generously.
wait_for "boots to idle" 30 -- cch_state_is "$win" idle

# 2. Inject a dripped response so a busy window is observable, then send
#    a prompt the watcher's way (send-keys text + Enter).
cch_control '{"mode":"text","drip_ms":600,"text":"MOCK BUSY DONE token stream one two three four five"}'
cch_send "$win" "say hi"

# 3. The in-flight (dripping) request renders the `↑ N tokens` spinner
#    that pane-state recognises as busy.
wait_for "goes busy during stream" 15 -- cch_state_is "$win" busy

# 4. Stream completes -> back to idle, and the canned text rendered.
wait_for "returns to idle after stream" 30 -- cch_state_is "$win" idle
pane=$(cch_capture "$win")
assert_contains "mock response rendered in pane" "$pane" "MOCK BUSY DONE"

# 5. Mock actually served the turn (boot warm-up + this prompt).
req_count=$(grep -c 'POST /v1/messages' "$CCH_LOG" 2>/dev/null || echo 0)
if (( req_count >= 1 )); then
    echo "  PASS: mock served $req_count /v1/messages request(s)"
    PASS=$(( PASS + 1 ))
else
    echo "  FAIL: mock served no /v1/messages requests" >&2
    FAIL=$(( FAIL + 1 ))
fi

# 6. Kill the inner claude -> pane goes absent (process-liveness gate).
cch_kill_claude "$win"
wait_for "absent after claude killed" 15 -- cch_state_is "$win" absent

th_summary_and_exit
