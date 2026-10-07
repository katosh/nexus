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
#
#    THE STREAM IS GATED, NOT TIMED (your-org/nexus-code#1667). It used to be
#    a bare ~6 s drip (10 tokens × 600 ms) against a 15 s busy wait — and
#    under host load one pane-state.sh poll took 5–10 s (load 72–82 on 36
#    cores), so the stream ended between two polls and "goes busy" read RED on
#    candidate and control alike. No drip length fixes that for every load, so
#    the mock now HOLDS the stream open after the last token (`hold_file`)
#    until this scenario has classified the pane busy, then releases it. The
#    busy verdict is still a live pane-state classification of the pane while
#    the mock is provably mid-stream: the hold only ends on the release file,
#    which is created AFTER the busy wait, and step 3b proves from the mock's
#    own log that the file — not the bound — ended it.
#
#    Chosen bounds: BUSY_WAIT_S=60 (≥6 polls at the worst measured 10 s/poll;
#    a green run costs one poll), HOLD_MAX_S=150 (the mock's safety release,
#    > BUSY_WAIT_S + the boot-to-idle margin, so it cannot fire first on a run
#    that goes busy; it only bounds a scenario that died before releasing).
BUSY_WAIT_S=60
HOLD_MAX_S=150
RELEASE="$CCH_DIR/release-stream"
cch_control "$(printf '{"mode":"text","drip_ms":600,"text":"MOCK BUSY DONE token stream one two three four five","hold_file":"%s","hold_max_s":%d}' "$RELEASE" "$HOLD_MAX_S")"
cch_send "$win" "say hi"

# 3. The in-flight (held) request renders the `↑ N tokens` spinner
#    that pane-state recognises as busy.
wait_for "goes busy during stream" "$BUSY_WAIT_S" -- cch_state_is "$win" busy
: > "$RELEASE"

# 3b. The busy observation happened while the stream was OPEN: the mock
#     reports the hold ended by the release file, never by its bound. Poll
#     briefly — the mock checks the file every 100 ms.
hold_line=""
for _i in $(seq 1 40); do
    hold_line=$(grep -m1 -E '\(hold (released by file|bound .* expired)' "$CCH_LOG" 2>/dev/null) && break
    sleep 0.25
done
case "$hold_line" in
    *"released by file"*)
        echo "  PASS: stream stayed open until released after the busy wait (mock: ${hold_line#"${hold_line%%[! ]*}"})"; PASS=$(( PASS + 1 )) ;;
    *)
        echo "  FAIL: the mock's hold was not ended by the release file (got: '${hold_line:-<no hold line>}') — busy was not observed mid-stream" >&2
        FAIL=$(( FAIL + 1 )) ;;
esac

# 4. Stream completes -> back to idle, and the canned text rendered.
wait_for "returns to idle after stream" 30 -- cch_state_is "$win" idle
pane=$(cch_capture "$win")
assert_contains "mock response rendered in pane" "$pane" "MOCK BUSY DONE"

# 5. Mock actually served the turn (boot warm-up + this prompt).
req_count=$(grep -c 'POST /v1/messages' "$CCH_LOG" 2>/dev/null) || req_count=0
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
