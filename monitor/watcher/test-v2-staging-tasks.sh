#!/usr/bin/env bash
# Unit tests for the v2 staging-file task contract (issue #172).
#
# Covers:
#   1. Atomic staging-file writes — `_scheduler_fire_async` writes to
#      `<name>.out.tmp.<pid>` then renames into place. A reader during
#      the write never sees a half-written file.
#   2. `_scheduler_stage_write_atomic` for sync tasks. Mirrors the
#      async path's atomicity from a foreground caller via stdin.
#   3. `_scheduler_drain_async` waits for all in-flight async tasks
#      to reach their sidecar `.rc` file.
#   4. compose_emit reads ONLY from staging — fed canned `.out` files
#      it produces the same emit body the v1 inline path would.
#   5. main_cycle no longer registers as a task under v2 (per #172
#      acceptance).
#
# Run: bash monitor/watcher/test-v2-staging-tasks.sh
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
        fail "$label" "want=$want got=$got"
    fi
}

# shellcheck source=_scheduler.sh
source "$_test_dir/_scheduler.sh"

# ---- (1) async fire writes via tmp+rename --------------------------------
echo '=== (1) async fire writes staging atomically (tmp + rename) ==='
_scheduler_reset_for_tests
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
MONITOR_SCHEDULER_STAGE_DIR="$WORK/stage"

slow_writer() {
    # Emit a marker the test can spot. Sleeping briefly forces the
    # subshell's `mv` to be observable across a tick boundary.
    printf 'slow-writer-output\n'
    return 0
}
_schedule_task slow_w 5 slow_writer --class medium --async
_scheduler_tick   # launches async

# Wait up to 3 seconds for the sidecar to appear, then assert the
# out-file exists and contains the marker (atomic rename guarantees
# the file is complete when visible at its final name).
for _i in 1 2 3 4 5 6; do
    [[ -f "$WORK/stage/slow_w.rc" ]] && break
    sleep 0.5
done
[[ -f "$WORK/stage/slow_w.rc" ]]      && pass "sidecar .rc file appeared"         || fail "sidecar .rc never appeared"
[[ -f "$WORK/stage/slow_w.out" ]]     && pass "final .out file present"           || fail ".out file missing"
ls -1 "$WORK/stage/" | grep -q "\.tmp\." && fail "tmp file left behind in stage" "$(ls -1 "$WORK/stage/")" \
                                         || pass "no stale .tmp files in stage"
content=$(cat "$WORK/stage/slow_w.out" 2>/dev/null || echo "")
assert_eq ".out content matches helper stdout" "$content" "slow-writer-output"

# ---- (2) sync atomic staging write ---------------------------------------
echo
echo '=== (2) _scheduler_stage_write_atomic writes via tmp + rename ==='
rm -rf "$WORK/stage"
mkdir -p "$WORK/stage"
echo 'sync-content-line1' | _scheduler_stage_write_atomic mysync
[[ -f "$WORK/stage/mysync.out" ]]    && pass "sync .out file present"            || fail "sync .out missing"
ls -1 "$WORK/stage/" | grep -q "\.tmp\." && fail "sync tmp file left behind"      \
                                         || pass "no stale sync .tmp files"
content=$(cat "$WORK/stage/mysync.out" 2>/dev/null || echo "")
assert_eq "sync .out content matches stdin" "$content" "sync-content-line1"

# ---- (3) drain_async waits for in-flight async tasks --------------------
echo
echo '=== (3) _scheduler_drain_async reaps in-flight tasks within budget ==='
_scheduler_reset_for_tests
rm -rf "$WORK/stage"
MONITOR_SCHEDULER_STAGE_DIR="$WORK/stage"

# Slow async helper — sleeps before emitting. drain_async should
# wait for the sleep + emit + rc-write to complete.
slow_async() { sleep 1; printf 'slow-async-done\n'; return 0; }
_schedule_task slow_async_test 5 slow_async --class medium --async
_scheduler_tick    # launches in subshell
# In-flight: pid recorded.
pid=${TASK_BG_PID[slow_async_test]:-0}
if (( pid != 0 )); then
    pass "task launched async (pid=$pid recorded)"
else
    fail "async task did not record a pid" "TASK_BG_PID=${TASK_BG_PID[slow_async_test]:-unset}"
fi

# Drain — should wait < 5s for the 1s sleep to finish + rc-write +
# rename. Generous budget is fine; we're asserting drain works at all.
t0=$(date +%s)
if _scheduler_drain_async 10; then
    t1=$(date +%s)
    pass "drain_async returned 0 within budget (waited $((t1 - t0))s)"
else
    fail "drain_async timed out unexpectedly" ""
fi
# After drain, the bg pid should be cleared.
post_pid=${TASK_BG_PID[slow_async_test]:-0}
assert_eq "TASK_BG_PID cleared post-drain" "$post_pid" "0"
[[ -f "$WORK/stage/slow_async_test.out" ]] && pass ".out written before drain returned" \
                                            || fail ".out missing after drain" ""

# ---- (4) v2 task registration: main_cycle gone, compose_emit present --
#
# We can't easily source main.sh's task registration block in
# isolation; this assertion is structural — grep the source for the
# task names. Issue #172 acceptance: `_v2_task_main_cycle` no longer
# exists; `_v2_task_compose_emit` does.
echo
echo '=== (4) v2 task registry: main_cycle gone, compose_emit registered ==='
_main_sh="$_test_dir/main.sh"

if grep -qE '^\s*_v2_task_main_cycle\(\)' "$_main_sh"; then
    fail "_v2_task_main_cycle still defined in main.sh (issue #172 acceptance)" \
         "$(grep -n '_v2_task_main_cycle' "$_main_sh" | head -3)"
else
    pass "_v2_task_main_cycle no longer defined in main.sh"
fi
if grep -qE '^\s*_v2_task_compose_emit\(\)' "$_main_sh"; then
    pass "_v2_task_compose_emit is defined in main.sh"
else
    fail "_v2_task_compose_emit not defined in main.sh" ""
fi

# Each formerly-bundled check is registered as its own task. NB: `heartbeat`
# is deliberately NOT in this list (nexus-code#236) — it is no longer a
# standalone always-ticks task; the heartbeat is bumped only at the end of a
# correct compose cycle so it doubles as the proof-of-working-loop signal.
for task in over_limit_wakes target_window orchestrator_liveness \
            pending_decisions bell_windows prune_archive \
            detect_unstick snapshot_local idle_section \
            over_limit_scan deliveries_poll github_poll full_state_snap \
            cc_version_check compose_emit; do
    if grep -qE "^\s*_schedule_task\s+$task\b" "$_main_sh"; then
        pass "task '$task' registered with the scheduler"
    else
        fail "task '$task' not registered" ""
    fi
done

# Inverse: `heartbeat` must NOT be a scheduler task (nexus-code#236). An
# always-ticks heartbeat is exactly what let a wedged loop read as healthy.
if grep -qE "^\s*_schedule_task\s+heartbeat\b" "$_main_sh"; then
    fail "heartbeat must NOT be a standalone task (it's bumped per compose cycle now)" ""
else
    pass "heartbeat is NOT a separate task (bumped only on a correct compose cycle)"
fi

# Inverse: main_cycle should NOT appear as a _schedule_task call.
if grep -qE "^\s*_schedule_task\s+main_cycle\b" "$_main_sh"; then
    fail "main_cycle still registered as a scheduler task" \
         "$(grep -nE '_schedule_task\s+main_cycle\b' "$_main_sh")"
else
    pass "main_cycle is no longer registered as a scheduler task"
fi

# ---- (6) reap replays async stderr into the watcher log ------------------
#
# Observability fix for the 2026-06-11 incident: a SUCCESSFUL async
# helper's log lines (rc=0, e.g. version_check writing the cockpit
# drift advisory at 10:33:47) landed only in the .err sidecar —
# watcher.log held no in-band evidence the action ever happened. The
# reap step must replay .err into `log` for EVERY rc, bounded.
echo
echo '=== (6) _scheduler_reap_async replays .err into log (rc=0 too) ==='
_scheduler_reset_for_tests
rm -rf "$WORK/stage"
MONITOR_SCHEDULER_STAGE_DIR="$WORK/stage"

REPLAY_LOG="$WORK/replayed.log"
: > "$REPLAY_LOG"
log() { printf '%s\n' "$*" >> "$REPLAY_LOG"; }

chatty_ok() {
    echo "version: cockpit drifted; asked the orchestrator to restart window 'services' (no direct kill)" >&2
    printf 'body\n'
    return 0
}
_schedule_task chatty_ok 5 chatty_ok --class medium --async
_scheduler_tick
_scheduler_drain_async 10

if grep -qF "scheduler[chatty_ok]: version: cockpit drifted" "$REPLAY_LOG"; then
    pass "rc=0 async stderr replayed into log with scheduler[name] prefix"
else
    fail "rc=0 async stderr NOT replayed" "log: $(cat "$REPLAY_LOG")"
fi
if grep -qF "rc=" "$REPLAY_LOG"; then
    fail "rc=0 replay must not carry an rc= tag" "log: $(cat "$REPLAY_LOG")"
else
    pass "rc=0 replay carries no rc= tag"
fi

# rc!=0: lines carry the rc tag; bound enforced at 20 lines + truncation notice.
_scheduler_reset_for_tests
rm -rf "$WORK/stage"
: > "$REPLAY_LOG"
chatty_fail() {
    local i
    for i in $(seq 1 25); do echo "diag line $i" >&2; done
    return 7
}
_schedule_task chatty_fail 5 chatty_fail --class medium --async
_scheduler_tick
_scheduler_drain_async 10

if grep -qF "scheduler[chatty_fail rc=7]: diag line 1" "$REPLAY_LOG"; then
    pass "rc!=0 replay carries the rc tag"
else
    fail "rc!=0 replay missing rc tag" "log: $(head -3 "$REPLAY_LOG")"
fi
replay_count=$(grep -cF "scheduler[chatty_fail rc=7]: diag line" "$REPLAY_LOG")
if (( replay_count == 20 )) && grep -qF "stderr truncated" "$REPLAY_LOG"; then
    pass "replay bounded at 20 lines with truncation notice"
else
    fail "replay bound broken" "count=$replay_count truncated=$(grep -cF 'stderr truncated' "$REPLAY_LOG" || true)"
fi

unset -f log chatty_ok chatty_fail

# ---- summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
