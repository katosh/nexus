#!/usr/bin/env bash
# Integration scenario: spawn → busy → idle → absent.
#
# The narrow but valuable subset of the issue body's first listed
# scenario ("Spawn → busy → wrap-up → idle → retain → close"). The
# wrap-up + retain + close transitions touch `monitor/ng wrap-up`
# and the orchestrator's action-log policy — those are Pass B; Pass
# A lands the tmux + stub-claude infrastructure and exercises the
# three transitions that have regressed the most often in
# production:
#
#   1. busy spinner present  → state=busy   (NOT absent)
#   2. spinner clears, idle  → state=idle
#   3. tmux kill-window      → state=absent
#
# Each transition catches a class of regression catalogued in
# your-org/nexus-code#72:
#   - The brand-new-window `pane-absent` false-positive that
#     PR #55 was meant to fix and that the operator session of
#     2026-05-12 still observed ~10 times.
#   - The empty-input misclassification when the spinner clears
#     in the same render cycle as the chevron repaints.
#   - The genuine `absent` case we MUST keep correctly detecting
#     so a window kill still triggers respawn.
#
# Run: RUN_INTEGRATION=1 bash monitor/watcher/test-integration/test-spawn-busy-idle-absent.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_harness.sh
. "$_self_dir/_harness.sh"
# shellcheck source=../_test_helpers.sh
. "$_self_dir/../_test_helpers.sh"

harness_skip_if_disabled
harness_setup

echo "=== harness ==="
echo "  HARNESS_DIR=$HARNESS_DIR"
echo "  HARNESS_SESSION=$HARNESS_SESSION"
echo "  HARNESS_SOCKET=$HARNESS_SOCKET"

# Spawn the worker. 4 s of busy spinner, then idle, then hold idle
# for 25 s — plenty of buffer for the assertions below.
echo
echo "=== spawn ==="
win=$(harness_spawn_worker test-worker \
    "STUB_CLAUDE_BUSY_SECONDS=4" \
    "STUB_CLAUDE_HOLD_SECONDS=25")
[[ "$win" =~ ^[0-9]+$ ]] || {
    echo "  FAIL: spawn returned non-numeric window index: $win" >&2
    th_summary_and_exit
}
echo "  spawned at window=$win"

# Predicate: pane-state.sh emits a `state=<x>` line; we grep for the
# expected state. Defined as a function (not an inline bash -c) so
# wait_for can invoke it without re-sourcing _harness.sh in a child
# shell — shell-function inheritance does NOT cross `bash -c`.
pane_state_is() {
    local expected="$1"
    local out
    out=$(PATH="$HARNESS_BIN:$PATH" \
        "$HARNESS_REPO_ROOT/monitor/pane-state.sh" \
        "${HARNESS_SESSION}:${win}" 2>/dev/null) || return 1
    grep -q "state=${expected}" <<<"$out"
}

# Probe 1: pane-state.sh should see `state=busy` within ~3 s. Allow
# 6 s — the first capture often hits the gap between `tmux
# new-window` returning and the stub's first `printf` reaching the
# pty buffer.
wait_for "pane-state reports busy" 6 -- pane_state_is busy

# Probe 2: hold the assertion for 2 s. Catches the post-`#55`
# residual where `state=absent` flapped mid-busy.
hold_false "pane-state never flips to absent during busy" 2 -- pane_state_is absent

# Probe 3: after the 4 s busy window, the stub transitions to idle.
# Allow up to 8 s — the spinner has to stop, the idle render has
# to land, and the next pane-state poll has to see it.
wait_for "pane-state reports idle after spinner clears" 8 -- pane_state_is idle

# Probe 4: kill the window. `state=absent` must fire because the
# window is gone — not the `empty` flap mid-render. Allow 3 s.
echo
echo "=== kill-window ==="
harness_tmux kill-window -t "${HARNESS_SESSION}:${win}"

wait_for "pane-state reports absent after kill-window" 3 -- pane_state_is absent

# Sanity dump for debugging. Cheap when everything passes; precious
# when a future regression flips one of the assertions.
if (( FAIL > 0 )); then
    echo
    echo "=== diagnostic dump (failure path) ==="
    echo "--- list-windows ---"
    harness_tmux list-windows -t "$HARNESS_SESSION" \
        -F '#{window_index}: #{window_name} active=#{window_active}' || true
    echo "--- pane-state ---"
    harness_pane_state "$win" || true
    echo "--- capture-pane ---"
    harness_capture "$win" | sed -n '1,40p' | cat -v || true
fi

th_summary_and_exit
