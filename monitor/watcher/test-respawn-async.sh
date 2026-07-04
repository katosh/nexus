#!/usr/bin/env bash
# Unit tests for monitor/watcher/_respawn_async.sh — the async wrapper
# around respawn_agent (issue #171). Asserts:
#
#   1. State-dir resolution honours $STATE_DIR.
#   2. Fresh state: in_flight=false, reap returns nothing.
#   3. Launch in background: returns rc=0, pid file written, child
#      running, in_flight=true.
#   4. Re-launch while in flight is refused (rc=1).
#   5. Child writes sidecar rc; reap returns it and clears state files.
#   6. Stale pidfile (kill -0 fails, no rc file) is swept by
#      in_flight() so next launch proceeds.
#   7. The scheduler can keep ticking during a long async respawn —
#      assert fast-cadence work continues while the respawn is in
#      flight (the load-bearing invariant from issue #171). Real-time
#      slow-gated like the scheduler's (8c) test.
#
# Run: bash monitor/watcher/test-respawn-async.sh
# Slow: SLOW_TESTS=1 bash monitor/watcher/test-respawn-async.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0
FAIL=0

pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() {
    printf '  FAIL: %s\n' "$1" >&2
    [[ $# -ge 2 ]] && printf '         %s\n' "$2" >&2
    FAIL=$(( FAIL + 1 ))
}

assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        pass "$label"
    else
        fail "$label" "got=$got want=$want"
    fi
}

# Source the module under test. Subsequent scenarios reset state via
# fresh STATE_DIRs.
# shellcheck source=_respawn_async.sh
source "$_test_dir/_respawn_async.sh"

# ---- (1) state dir honours $STATE_DIR ----------------------------------

echo '=== (1) _respawn_async_state_dir resolves under $STATE_DIR ==='
WORK=$(mktemp -d -t respawn-async-test-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/state"
mkdir -p "$STATE_DIR"
assert_eq "state_dir resolves under STATE_DIR" \
    "$(_respawn_async_state_dir)" "$STATE_DIR/respawn-bg"

# ---- (2) fresh state: nothing in flight, nothing to reap ---------------

echo
echo '=== (2) fresh state: in_flight=false, reap=nothing ==='
if _respawn_async_in_flight; then
    fail "in_flight=true on fresh state"
else
    pass "in_flight=false on fresh state"
fi
if reap_out=$(_respawn_async_reap); then
    fail "reap returned rc=0 on fresh state" "stdout='$reap_out'"
else
    pass "reap returned rc=1 on fresh state"
fi

# ---- (3) launch backgrounds; pid file is written; in_flight=true -------

echo
echo '=== (3) _respawn_async_launch backgrounds respawn_agent ==='
# respawn_agent stub: sleep N seconds (controlled per test), then exit
# with the rc baked in via $STUB_RESPAWN_RC.
respawn_agent() {
    sleep "${STUB_RESPAWN_SLEEP:-1}"
    return "${STUB_RESPAWN_RC:-0}"
}
STUB_RESPAWN_SLEEP=2
STUB_RESPAWN_RC=0

if _respawn_async_launch "test-target"; then
    pass "launch returned rc=0"
else
    fail "launch returned non-zero"
fi
pid_file="$STATE_DIR/respawn-bg/pid"
if [[ -f "$pid_file" ]]; then
    pass "pid file present after launch"
else
    fail "pid file absent after launch"
fi
launched_pid=$(cat "$pid_file" 2>/dev/null)
if [[ "$launched_pid" =~ ^[0-9]+$ ]] && kill -0 "$launched_pid" 2>/dev/null; then
    pass "launched pid ($launched_pid) is alive"
else
    fail "launched pid not alive" "pid='$launched_pid'"
fi
if _respawn_async_in_flight; then
    pass "in_flight=true while subshell running"
else
    fail "in_flight=false while subshell still running"
fi

# ---- (4) re-launch while in flight is refused --------------------------

echo
echo '=== (4) re-launch while in flight refused ==='
if _respawn_async_launch "test-target"; then
    fail "second launch returned rc=0 (should be refused)"
else
    pass "second launch refused (rc=1) while prior run in flight"
fi

# ---- (5) reap after subshell exits --------------------------------------

echo
echo '=== (5) reap after subshell completes ==='
# Wait for the subshell to write its rc file. The first sleep is the
# stub's 2 s body; allow a generous buffer for bash exec.
wait "$launched_pid" 2>/dev/null || true
sleep 0.2
rc_file="$STATE_DIR/respawn-bg/rc"
if [[ -f "$rc_file" ]]; then
    pass "rc file present after subshell exit"
else
    fail "rc file absent after subshell exit"
fi
if _respawn_async_in_flight; then
    fail "in_flight=true after rc-file present"
else
    pass "in_flight=false after rc-file present"
fi
if reap_rc=$(_respawn_async_reap); then
    assert_eq "reap returns child rc" "$reap_rc" "0"
else
    fail "reap returned rc=1 after completion (expected rc=0)"
fi
if [[ -f "$rc_file" ]]; then
    fail "rc file still present after reap"
else
    pass "rc file cleaned up by reap"
fi
if [[ -f "$pid_file" ]]; then
    fail "pid file still present after reap"
else
    pass "pid file cleaned up by reap"
fi

# ---- (5b) reap propagates non-zero child rc ---------------------------

echo
echo '=== (5b) reap propagates non-zero child rc ==='
STUB_RESPAWN_SLEEP=0
STUB_RESPAWN_RC=3
_respawn_async_launch "test-target"
launched_pid=$(cat "$pid_file" 2>/dev/null)
wait "$launched_pid" 2>/dev/null || true
sleep 0.2
if reap_rc=$(_respawn_async_reap); then
    assert_eq "reap returns child rc=3" "$reap_rc" "3"
else
    fail "reap returned no rc"
fi

# ---- (6) stale pidfile (kill -0 fails) is swept ------------------------

echo
echo '=== (6) stale pidfile swept by in_flight ==='
mkdir -p "$STATE_DIR/respawn-bg"
# Choose a pid that almost certainly does not exist (max-ish + 1).
# kernel pid max on linux is typically 2^22 = 4194304; pick higher.
printf '%s\n' "99999999" > "$pid_file"
if _respawn_async_in_flight; then
    fail "in_flight=true with stale pidfile pointing at nonexistent pid"
else
    pass "in_flight=false with stale pid; pidfile swept"
fi
if [[ -f "$pid_file" ]]; then
    fail "stale pidfile not cleaned up by in_flight"
else
    pass "stale pidfile cleaned up by in_flight"
fi

# ---- (6b) launch proceeds after stale pidfile sweep -------------------

echo
echo '=== (6b) launch proceeds after stale pidfile sweep ==='
# Re-stage stale pidfile, then ensure launch succeeds.
mkdir -p "$STATE_DIR/respawn-bg"
printf '%s\n' "99999999" > "$pid_file"
STUB_RESPAWN_SLEEP=0
STUB_RESPAWN_RC=0
if _respawn_async_launch "test-target"; then
    pass "launch succeeds after stale pidfile sweep"
else
    fail "launch refused after stale pidfile sweep"
fi
launched_pid=$(cat "$pid_file" 2>/dev/null)
wait "$launched_pid" 2>/dev/null || true
sleep 0.2
_respawn_async_reap >/dev/null || true

# ---- (6c) issue #203: --replace cancels an in-flight async respawn ----
#
# An intentional `launcher.sh --replace` must CANCEL the in-flight
# respawn subshell the replaced watcher backgrounded — otherwise the
# orphan later fires a kill-then-spawn against whatever now occupies the
# orchestrator window (the catastrophe class). `_respawn_async_cancel`
# is the seam launcher.sh calls.

echo
echo '=== (6c) _respawn_async_cancel kills an in-flight respawn + clears sentinel ==='
STUB_RESPAWN_SLEEP=30   # long enough that cancel must actively kill it
STUB_RESPAWN_RC=0
_respawn_async_launch "test-target"
cancel_pid=$(cat "$pid_file" 2>/dev/null)
start_file="$STATE_DIR/respawn-bg/start"
if [[ -f "$start_file" ]]; then
    pass "start-time fingerprint recorded at launch"
else
    fail "start-time fingerprint NOT recorded at launch"
fi
if _respawn_async_in_flight; then
    pass "in_flight=true before cancel"
else
    fail "in_flight=false before cancel (subshell should be running)"
fi
if _respawn_async_cancel; then
    pass "cancel returned rc=0 (cancelled a live respawn)"
else
    fail "cancel returned rc=1 (should have found a live respawn)"
fi
if [[ "$cancel_pid" =~ ^[0-9]+$ ]] && kill -0 "$cancel_pid" 2>/dev/null; then
    fail "cancelled respawn subshell ($cancel_pid) is still alive"
    kill -9 "$cancel_pid" 2>/dev/null || true
else
    pass "cancelled respawn subshell is dead"
fi
if [[ -f "$pid_file" || -f "$STATE_DIR/respawn-bg/rc" || -f "$start_file" ]]; then
    fail "cancel did not clear the respawn-bg sentinel files"
else
    pass "cancel cleared the respawn-bg sentinel files"
fi
if _respawn_async_in_flight; then
    fail "in_flight=true after cancel"
else
    pass "in_flight=false after cancel"
fi
# cancel on an empty state dir returns rc=1 (nothing to cancel).
if _respawn_async_cancel; then
    fail "cancel returned rc=0 with nothing in flight"
else
    pass "cancel returned rc=1 when nothing in flight"
fi

# ---- (6d) issue #203: PID-reuse fingerprint defeats a false in-flight --
#
# `respawn-bg/` survives a watcher restart by design, so after a PID
# namespace reset the recorded pid can be recycled by an unrelated live
# process. A bare `kill -0` would then read a false "in flight" — and
# the --replace cancel above would signal a stranger. The start-time
# fingerprint guards both.

echo
echo '=== (6d) PID-reuse fingerprint: mismatched start-time reads NOT-in-flight ==='
# A real, live, long-lived process to stand in for the "recycled PID".
sleep 120 &
reuse_pid=$!
real_start=$(_respawn_async_pid_starttime "$reuse_pid" 2>/dev/null || true)
if [[ "$real_start" =~ ^[0-9]+$ ]]; then
    pass "_respawn_async_pid_starttime returns a numeric fingerprint for a live pid"
else
    fail "_respawn_async_pid_starttime gave no fingerprint" "got='$real_start'"
fi
mkdir -p "$STATE_DIR/respawn-bg"
rm -f "$STATE_DIR/respawn-bg/rc"
printf '%s\n' "$reuse_pid" > "$pid_file"
# Fingerprint that deliberately does NOT match the live pid's start.
printf '%s\n' "$(( real_start + 123456 ))" > "$start_file"
if _respawn_async_in_flight; then
    fail "in_flight=true despite start-time mismatch (PID-reuse not detected)"
else
    pass "in_flight=false on start-time mismatch (PID-reuse detected as stale)"
fi
if [[ -f "$pid_file" || -f "$start_file" ]]; then
    fail "PID-reuse sweep did not clear the stale sentinel"
else
    pass "PID-reuse sweep cleared the stale sentinel"
fi
# Matching fingerprint on the same live pid reads in-flight (positive).
printf '%s\n' "$reuse_pid" > "$pid_file"
printf '%s\n' "$real_start" > "$start_file"
if _respawn_async_in_flight; then
    pass "in_flight=true when start-time fingerprint matches the live pid"
else
    fail "in_flight=false even though the fingerprint matches the live pid"
fi
kill -9 "$reuse_pid" 2>/dev/null || true
rm -f "$pid_file" "$start_file" "$STATE_DIR/respawn-bg/rc"

# ---- (7) scheduler keeps ticking during long async respawn -------------
# Slow-gated: ~4 s wall, exercises the load-bearing invariant from
# issue #171 — the scheduler must NOT block while respawn_agent is in
# flight. Mirrors test-scheduler-priority-queue.sh (8c)'s pattern.

echo
echo '=== (7) scheduler ticks fire fast tasks during async respawn (slow-gated) ==='
if [[ "${SLOW_TESTS:-0}" != "1" ]]; then
    echo "  SKIP: set SLOW_TESTS=1 (~4s wall-clock) to enable"
else
    # Re-source the scheduler so we can drive ticks.
    # shellcheck source=_scheduler.sh
    source "$_test_dir/_scheduler.sh"
    _scheduler_reset_for_tests
    unset NEXUS_TEST_NOW   # real clock — async timing must align
    export MONITOR_SCHEDULER_STAGE_DIR=$(mktemp -d -t respawn-async-sched-XXXXXX)
    cleanup_sched_stage() { rm -rf "$MONITOR_SCHEDULER_STAGE_DIR"; }
    trap 'cleanup_sched_stage; rm -rf "$WORK"' EXIT

    # Stub respawn_agent: 3 s body (simulates the real ~22 s dance).
    respawn_agent() { sleep 3; return 0; }

    # Fast task: counts ticks while the long respawn is in flight.
    fast_fires=0
    fast_task() { fast_fires=$(( fast_fires + 1 )); return 0; }

    # Probe task: fires every 2 s like the real target_window probe.
    # Doesn't itself touch the async wrapper here — we're proving the
    # SCHEDULER keeps ticking; the wrapper proves itself in (3)-(5).
    probe_fires=0
    probe_task() { probe_fires=$(( probe_fires + 1 )); return 0; }

    _schedule_task fast 1 fast_task --class cheap
    _schedule_task probe 2 probe_task --class cheap

    # Launch the long async respawn directly (bypassing the scheduler
    # — this is the call shape main.sh uses inside the rc=2 branch).
    _respawn_async_launch "test-target"
    respawn_pid=$(cat "$pid_file" 2>/dev/null)

    # Tick every ~0.6 s for ~4 s. fast/probe must keep firing.
    start_wall=$(date +%s)
    for i in 1 2 3 4 5 6 7; do
        sleep 0.6
        _scheduler_tick
    done
    elapsed_wall=$(( $(date +%s) - start_wall ))

    if (( fast_fires >= 3 )); then
        pass "fast task fired ≥ 3 times during 3 s respawn (got $fast_fires in ${elapsed_wall}s)"
    else
        fail "fast task starved by sync work" "fired=$fast_fires expected ≥ 3"
    fi
    if (( probe_fires >= 1 )); then
        pass "probe task fired ≥ 1 time during 3 s respawn (got $probe_fires)"
    else
        fail "probe task starved" "fired=$probe_fires expected ≥ 1"
    fi

    # The respawn should have completed by now; reap clears state.
    wait "$respawn_pid" 2>/dev/null || true
    sleep 0.3
    if reap_rc=$(_respawn_async_reap); then
        assert_eq "post-scheduler reap returns rc=0" "$reap_rc" "0"
    else
        fail "respawn never reaped"
    fi

    cleanup_sched_stage
    trap 'rm -rf "$WORK"' EXIT
fi

# ---- summary ------------------------------------------------------------

echo
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d)\n' "$PASS"
    exit 0
else
    printf 'TESTS FAILED: %d passed, %d failed\n' "$PASS" "$FAIL" >&2
    exit 1
fi
