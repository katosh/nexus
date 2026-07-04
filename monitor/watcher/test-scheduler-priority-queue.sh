#!/usr/bin/env bash
# Unit tests for monitor/watcher/_scheduler.sh — the Option A
# single-loop priority-queue scheduler (issue #169, branch
# operator/scheduler-impl-a-priority-queue).
#
# Covers the surfaces enumerated in the bake-off brief:
#
#   1. Basic cadence: a task with interval 10 fires at 10, 20, 30
#      under an injected clock.
#   2. Soonest-sleep: two tasks at intervals 10 and 25 — the loop
#      always sleeps to the nearer next-fire.
#   3. Adaptive override: `_schedule_override` shortens cadence for a
#      duration then auto-expires back to base.
#   4. Back-pressure (skip-until): `_schedule_skip_until` defers one
#      task without affecting others' cadence.
#   5. Back-pressure (rc=75): a task returning EX_TEMPFAIL gets its
#      next interval doubled once; the following healthy fire
#      returns to base.
#   6. Drift catch-up: a task whose execution overruns its interval
#      reschedules to `now+1`, not into the past — no tight spin.
#   7. Force-fire: `_schedule_fire_now` ignores `next_fire`.
#   8. Iteration order: ticks are sorted by task name (reproducible
#      regardless of registration order).
#   9. SIGTERM during sleep (slow-gated, SLOW_TESTS=1) — terminates
#      within `MONITOR_SCHEDULER_MAX_SLEEP + 1` seconds.
#
# Run: bash monitor/watcher/test-scheduler-priority-queue.sh
# Slow: SLOW_TESTS=1 bash monitor/watcher/test-scheduler-priority-queue.sh
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
        pass "$label (got $got)"
    else
        fail "$label" "got $got, want $want"
    fi
}

# Source the module under test once. Subsequent scenarios re-use the
# loaded helpers and call _scheduler_reset_for_tests between cases.
# shellcheck source=_scheduler.sh
source "$_test_dir/_scheduler.sh"

# ---- (1) basic cadence: 10 → 10, 20, 30 ---------------------------------

echo '=== (1) interval-10 task fires at 10, 20, 30 ==='
_scheduler_reset_for_tests

fire_count_basic=0
basic_task() { fire_count_basic=$(( fire_count_basic + 1 )); return 0; }

NEXUS_TEST_NOW=1000
_schedule_task basic 10 basic_task --class cheap

# First tick at t=1000 fires immediately (next_fire seeded at 0).
_scheduler_tick
assert_eq "first fire at t=1000" "$fire_count_basic" "1"
assert_eq "next_fire post-first" "${TASK_NEXT_FIRE[basic]}" "1010"

# t=1005: not yet due. No fire.
NEXUS_TEST_NOW=1005
_scheduler_tick
assert_eq "no fire at t=1005" "$fire_count_basic" "1"
assert_eq "next_fire still 1010" "${TASK_NEXT_FIRE[basic]}" "1010"

# t=1010: due. Fire, next=1020.
NEXUS_TEST_NOW=1010
_scheduler_tick
assert_eq "fire at t=1010" "$fire_count_basic" "2"
assert_eq "next_fire = 1020" "${TASK_NEXT_FIRE[basic]}" "1020"

# t=1020: due. Fire, next=1030.
NEXUS_TEST_NOW=1020
_scheduler_tick
assert_eq "fire at t=1020" "$fire_count_basic" "3"
assert_eq "next_fire = 1030" "${TASK_NEXT_FIRE[basic]}" "1030"

# t=1030: due. Fire, next=1040.
NEXUS_TEST_NOW=1030
_scheduler_tick
assert_eq "fire at t=1030" "$fire_count_basic" "4"
assert_eq "next_fire = 1040" "${TASK_NEXT_FIRE[basic]}" "1040"

# ---- (2) two tasks: scheduler sleeps to the nearer one ------------------

echo
echo '=== (2) two-task soonest-sleep ==='
_scheduler_reset_for_tests
_schedule_task fast 10 basic_task
_schedule_task slow 25 basic_task

NEXUS_TEST_NOW=1000
# Both fire at t=1000 (seeded next_fire=0).
_scheduler_tick
assert_eq "fast next_fire after t=1000" "${TASK_NEXT_FIRE[fast]}" "1010"
assert_eq "slow next_fire after t=1000" "${TASK_NEXT_FIRE[slow]}" "1025"

soonest=$(_scheduler_soonest_next_fire "$NEXUS_TEST_NOW")
assert_eq "soonest after t=1000 is fast=1010" "$soonest" "1010"

NEXUS_TEST_NOW=1010
_scheduler_tick
assert_eq "fast next_fire after t=1010" "${TASK_NEXT_FIRE[fast]}" "1020"
assert_eq "slow next_fire after t=1010" "${TASK_NEXT_FIRE[slow]}" "1025"

soonest=$(_scheduler_soonest_next_fire "$NEXUS_TEST_NOW")
assert_eq "soonest after t=1010 is fast=1020" "$soonest" "1020"

NEXUS_TEST_NOW=1020
_scheduler_tick
soonest=$(_scheduler_soonest_next_fire "$NEXUS_TEST_NOW")
assert_eq "soonest at t=1020 is slow=1025" "$soonest" "1025"

NEXUS_TEST_NOW=1025
_scheduler_tick
assert_eq "slow fires at t=1025, next=1050" "${TASK_NEXT_FIRE[slow]}" "1050"

# ---- (3) adaptive override: tighten for a window, then expire -----------

echo
echo '=== (3) adaptive override applies + expires ==='
_scheduler_reset_for_tests

fire_count_adapt=0
adapt_task() { fire_count_adapt=$(( fire_count_adapt + 1 )); return 0; }

NEXUS_TEST_NOW=1000
_schedule_task adapt 60 adapt_task

# Initial fire at t=1000 (seeded). Override after that: 5s cadence
# for the next 20 seconds.
_scheduler_tick
assert_eq "adapt fires once at t=1000" "$fire_count_adapt" "1"
assert_eq "adapt next_fire pre-override" "${TASK_NEXT_FIRE[adapt]}" "1060"

_schedule_override adapt 5 20
# Override pulls next_fire forward to 1005.
assert_eq "override pulled next_fire to 1005" "${TASK_NEXT_FIRE[adapt]}" "1005"

NEXUS_TEST_NOW=1005
_scheduler_tick
assert_eq "fire under override at t=1005" "$fire_count_adapt" "2"
assert_eq "next_fire under override = 1010" "${TASK_NEXT_FIRE[adapt]}" "1010"

NEXUS_TEST_NOW=1010
_scheduler_tick
assert_eq "fire under override at t=1010" "$fire_count_adapt" "3"
assert_eq "next_fire under override = 1015" "${TASK_NEXT_FIRE[adapt]}" "1015"

NEXUS_TEST_NOW=1015
_scheduler_tick
assert_eq "fire under override at t=1015" "$fire_count_adapt" "4"
assert_eq "next_fire under override = 1020" "${TASK_NEXT_FIRE[adapt]}" "1020"

# Override expires at t = 1000 + 20 = 1020. The fire AT 1020 should
# happen under base cadence again (override window is [1000, 1020),
# half-open — `> now` check in _scheduler_next_fire).
NEXUS_TEST_NOW=1020
_scheduler_tick
assert_eq "fire at t=1020 (override boundary)" "$fire_count_adapt" "5"
# anchor = 1020, base = 60 → next = 1080.
assert_eq "next_fire back to base = 1080" "${TASK_NEXT_FIRE[adapt]}" "1080"

# Override fields cleared.
if [[ -z "${TASK_OVERRIDE_TIL[adapt]:-}" && -z "${TASK_OVERRIDE_INT[adapt]:-}" ]]; then
    pass "override fields auto-cleared after expiry"
else
    fail "override fields not cleared" \
        "TIL=${TASK_OVERRIDE_TIL[adapt]:-} INT=${TASK_OVERRIDE_INT[adapt]:-}"
fi

# ---- (4) back-pressure: skip-until defers one task ----------------------

echo
echo '=== (4) skip-until back-pressure ==='
_scheduler_reset_for_tests

fire_count_a=0; fire_count_b=0
task_a() { fire_count_a=$(( fire_count_a + 1 )); return 0; }
task_b() { fire_count_b=$(( fire_count_b + 1 )); return 0; }

NEXUS_TEST_NOW=1000
_schedule_task task_a 10 task_a
_schedule_task task_b 10 task_b

_scheduler_tick   # both fire at t=1000
assert_eq "a fires at t=1000" "$fire_count_a" "1"
assert_eq "b fires at t=1000" "$fire_count_b" "1"

# B back-pressures itself for 120s.
_schedule_skip_until task_b $(( NEXUS_TEST_NOW + 120 ))
assert_eq "b next_fire deferred to 1120" "${TASK_NEXT_FIRE[task_b]}" "1120"

# Advance through the deferral window. A fires every 10s; B never.
for t in 1010 1020 1030 1040 1050 1060 1070 1080 1090 1100 1110; do
    NEXUS_TEST_NOW=$t
    _scheduler_tick
done
assert_eq "a fired 12x through t=1110" "$fire_count_a" "12"
assert_eq "b did not fire during deferral" "$fire_count_b" "1"

# At t=1120 B is due again.
NEXUS_TEST_NOW=1120
_scheduler_tick
assert_eq "b fires at t=1120 (deferral expired)" "$fire_count_b" "2"

# ---- (5) back-pressure: rc=75 doubles interval once ---------------------

echo
echo '=== (5) rc=75 doubles interval, recovery on next healthy fire ==='
_scheduler_reset_for_tests

_rc_state=0
rc_pressured_task() { return "$_rc_state"; }

NEXUS_TEST_NOW=1000
_schedule_task gh 60 rc_pressured_task

# First fire is rc=75: interval doubles to 120, next = 1000 + 120.
_rc_state=75
_scheduler_tick
assert_eq "rc=75 doubled next_fire to 1120" "${TASK_NEXT_FIRE[gh]}" "1120"

# t=1120: healthy fire (rc=0). Next interval back to base 60.
NEXUS_TEST_NOW=1120
_rc_state=0
_scheduler_tick
assert_eq "healthy fire restores base cadence: next=1180" "${TASK_NEXT_FIRE[gh]}" "1180"

# Cap: repeated rc=75 stops at 4× base (240s for base 60).
_scheduler_reset_for_tests
NEXUS_TEST_NOW=2000
_schedule_task gh 60 rc_pressured_task
_rc_state=75
_scheduler_tick
assert_eq "first rc=75 fire: next=2120" "${TASK_NEXT_FIRE[gh]}" "2120"
NEXUS_TEST_NOW=2120
_scheduler_tick
# Override is not active; base=60. Each rc=75 doubles base interval
# *for that fire only*. So this fire computes: interval=60*2=120,
# capped at 240 → 120 → next=2240. The cap matters only if a prior
# override stretched the base; verify the cap with an override too.
assert_eq "second rc=75 fire: next=2240" "${TASK_NEXT_FIRE[gh]}" "2240"

# With an active override raising the cadence, rc=75 still caps at
# base * 4.
_scheduler_reset_for_tests
NEXUS_TEST_NOW=3000
_schedule_task gh 60 rc_pressured_task
# Override raises cadence to 200s for 1h; rc=75 then doubles to 400
# which is past the 4×60=240 cap.
_schedule_override gh 200 3600
_rc_state=75
# Override pulled next_fire to 3000+200=3200; but we're forcing-fire
# in this case to exercise the doubling.
_schedule_fire_now gh
_scheduler_tick
# anchor=3000, override-interval=200, doubled to 400, capped at 240.
# next = 3000 + 240 = 3240.
assert_eq "rc=75 with override caps at base*4 = next=3240" "${TASK_NEXT_FIRE[gh]}" "3240"

# ---- (6) drift catch-up: long task → next = now+1 -----------------------

echo
echo '=== (6) drift catch-up ==='
_scheduler_reset_for_tests

drift_count=0
drift_task() {
    drift_count=$(( drift_count + 1 ))
    # Simulate a task that took 25 seconds to run by advancing the
    # injected clock from inside the task body. Real watchers don't
    # do this, but for the test the synthetic clock is the cheapest
    # way to model overrun.
    NEXUS_TEST_NOW=$(( NEXUS_TEST_NOW + 25 ))
    return 0
}

NEXUS_TEST_NOW=1000
_schedule_task drift 10 drift_task

_scheduler_tick
# anchor (post-fire clock) = 1025, candidate = 1025 + 10 = 1035 > 1025,
# but the catch-up rule kicks in only when candidate <= now. So next
# = 1035 (no catch-up; the next tick will be at 1035, not "now+1").
# Wait — let me re-check: anchor = last_fire = post-fire clock = 1025.
# now (inside _scheduler_next_fire) = 1025. candidate = 1025 + 10 =
# 1035. 1035 > 1025, so no catch-up clamp. next = 1035. That's
# correct — the long task delayed the schedule, but the schedule
# still moves forward by the base interval. No tight spin.
assert_eq "drift overrun → next = anchor + interval = 1035" "${TASK_NEXT_FIRE[drift]}" "1035"

# Now simulate a much longer overrun: 60 seconds with a 10-second
# interval. anchor = post-fire = 1085, candidate = 1085 + 10 = 1095.
# Again no clamp; the catch-up clamp only kicks in when the prior
# next_fire was so old that anchor+interval <= now (which doesn't
# happen when we use post-fire time as the anchor).
NEXUS_TEST_NOW=1025
drift_task() {
    drift_count=$(( drift_count + 1 ))
    NEXUS_TEST_NOW=$(( NEXUS_TEST_NOW + 60 ))
    return 0
}
# Ensure the task is due.
_schedule_fire_now drift
_scheduler_tick
# anchor (post-fire) = 1025 + 60 = 1085, candidate = 1095.
assert_eq "60s overrun → next = 1095" "${TASK_NEXT_FIRE[drift]}" "1095"

# Verify the catch-up clamp with a synthetic anchor in the past.
# Manually backdate last_fire and call _scheduler_next_fire to drive
# the candidate into the past.
_scheduler_reset_for_tests
NEXUS_TEST_NOW=2000
_schedule_task drift 10 drift_task
TASK_LAST_FIRE[drift]=1500   # anchor far behind now → candidate = 1510 < 2000
next=$(_scheduler_next_fire drift 0)
assert_eq "overdue candidate clamps to now+1 = 2001" "$next" "2001"

# ---- (7) force-fire ignores next_fire -----------------------------------

echo
echo '=== (7) _schedule_fire_now ==='
_scheduler_reset_for_tests

forced_count=0
forced_task() { forced_count=$(( forced_count + 1 )); return 0; }

NEXUS_TEST_NOW=5000
_schedule_task forced 600 forced_task   # long base interval

_scheduler_tick   # first fire (seeded next=0)
assert_eq "forced fires initially" "$forced_count" "1"
assert_eq "next_fire = 5600 (long base)" "${TASK_NEXT_FIRE[forced]}" "5600"

# Don't advance the clock; force-fire should still make it fire.
_schedule_fire_now forced
_scheduler_tick
assert_eq "forced fires after _schedule_fire_now" "$forced_count" "2"

# ---- (8) iteration order is sorted by name ------------------------------

echo
echo '=== (8) iteration order is reproducible (name-sorted) ==='
_scheduler_reset_for_tests

NEXUS_TEST_NOW=7000
order_log=""
log_fire() { order_log="${order_log}${1};"; }
zebra_task()  { log_fire "zebra";  }
alpha_task()  { log_fire "alpha";  }
mango_task()  { log_fire "mango";  }

# Register out of order. The tick should still iterate alphabetically.
_schedule_task zebra 10 zebra_task
_schedule_task alpha 10 alpha_task
_schedule_task mango 10 mango_task

_scheduler_tick
assert_eq "fired in name-sorted order" "$order_log" "alpha;mango;zebra;"
assert_eq "_SCHEDULER_FIRED_THIS_TICK count" \
    "${#_SCHEDULER_FIRED_THIS_TICK[@]}" "3"
assert_eq "_SCHEDULER_FIRED_THIS_TICK[0]" \
    "${_SCHEDULER_FIRED_THIS_TICK[0]}" "alpha"

# ---- (8b) enable/disable gate -------------------------------------------

echo
echo '=== (8b) _schedule_disable suspends a task without unregistering ==='
_scheduler_reset_for_tests
NEXUS_TEST_NOW=8000
suspended_count=0
sus_task() { suspended_count=$(( suspended_count + 1 )); return 0; }
_schedule_task sus 5 sus_task
_scheduler_tick
assert_eq "sus fires on first tick" "$suspended_count" "1"

_schedule_disable sus
NEXUS_TEST_NOW=8005
_scheduler_tick
assert_eq "sus does not fire while disabled" "$suspended_count" "1"
soonest=$(_scheduler_soonest_next_fire "$NEXUS_TEST_NOW")
# Only disabled task → soonest defaults to now+1.
assert_eq "soonest skips disabled tasks" "$soonest" "8006"

_schedule_enable sus
_schedule_fire_now sus
_scheduler_tick
assert_eq "sus fires after re-enable + force-fire" "$suspended_count" "2"

# ---- (8d) target-window probe force-fires compose_emit on rc=2 ---------
#
# Behaviour-level test for the post-#172 probe pattern: a 2 s probe
# task that detects target-window absence (mock rc=2) must
# force-fire `compose_emit` (`next_fire=0`) AND apply a temporary
# cadence override so subsequent compose_emit ticks converge faster
# on the freshly respawned orchestrator. Pure clock-injected; no
# real tmux dependency. Pre-#172 this test asserted the same shape
# against `main_cycle` (now removed).

echo
echo '=== (8d) target_window probe force-fires + overrides compose_emit ==='
_scheduler_reset_for_tests
NEXUS_TEST_NOW=20000

compose_emit_fires=0
_test_compose_emit() { compose_emit_fires=$(( compose_emit_fires + 1 )); return 0; }

# Mock probe — always reports target absent (rc=2 path). Force-
# fires compose_emit and applies a 5s-for-60s override exactly as
# the production `_v2_task_target_window_probe` does.
target_absent_probe() {
    _schedule_fire_now compose_emit
    _schedule_override compose_emit 5 60
    return 0
}

_schedule_task compose_emit 60 _test_compose_emit --class medium
_schedule_task target_window 2 target_absent_probe --class cheap

# Tick #1 at t=20000. Iteration order is name-sorted, so compose_emit
# fires BEFORE target_window. After this tick:
#   - compose_emit fires=1, next_fire = 20000+60 = 20060.
#   - target_window fires: force-fires compose_emit (next_fire=0) and
#     stamps the override window (TIL=20060, INT=5).
_scheduler_tick
assert_eq "tick #1: compose_emit fired" "$compose_emit_fires" "1"
assert_eq "tick #1: probe forced compose_emit next_fire=0" "${TASK_NEXT_FIRE[compose_emit]}" "0"
assert_eq "tick #1: override TIL = now + 60" "${TASK_OVERRIDE_TIL[compose_emit]:-0}" "20060"
assert_eq "tick #1: override interval = 5" "${TASK_OVERRIDE_INT[compose_emit]:-0}" "5"

# Tick #2 at t=20002 (advance 2s). compose_emit is due (next_fire=0).
# After this tick:
#   - compose_emit fires=2, anchor=20002, interval=5 (override) → next=20007.
#   - target_window also fires (next_fire was 20002), re-applies
#     force-fire + override (idempotent: TIL = 20002+60 = 20062).
NEXUS_TEST_NOW=20002
_scheduler_tick
assert_eq "tick #2: compose_emit fired under force" "$compose_emit_fires" "2"
assert_eq "tick #2: probe re-forced next_fire=0" "${TASK_NEXT_FIRE[compose_emit]}" "0"
assert_eq "tick #2: override TIL refreshed = now + 60" "${TASK_OVERRIDE_TIL[compose_emit]:-0}" "20062"

NEXUS_TEST_NOW=20004
_scheduler_tick
assert_eq "tick #3: compose_emit fired again" "$compose_emit_fires" "3"
assert_eq "tick #3: probe still forcing next_fire=0" "${TASK_NEXT_FIRE[compose_emit]}" "0"
assert_eq "tick #3: override active throughout" "${TASK_OVERRIDE_TIL[compose_emit]:-0}" "20064"

if (( compose_emit_fires == 3 )); then
    pass "compose_emit reached 3 fires in 4 s of force-fire windows (vs 1 at base interval)"
else
    fail "compose_emit did not reach 3 fires" "got=$compose_emit_fires"
fi

# Recovery: replace the probe with one that returns rc=0 (no force).
target_present_probe() { return 0; }
_schedule_task target_window 2 target_present_probe --class cheap

NEXUS_TEST_NOW=20065
_scheduler_tick
assert_eq "recovery: override cleared after expiry" "${TASK_OVERRIDE_TIL[compose_emit]:-0}" "0"
assert_eq "recovery: compose_emit back to base interval (next=20125)" "${TASK_NEXT_FIRE[compose_emit]}" "20125"

# ---- (8c) --async no-starvation (slow-gated, real-time) -----------------
#
# A long async task must NOT block fast-cadence tasks. Register a 1 s
# `fast` sync task and a 1 s `slow --async` task whose body sleeps 3 s
# real time. Drive the scheduler with real-time sleeps + real
# `nexus_clock()` (NOT injected) so the async subshell, the clock, and
# the reap path all share one timeline. Assert: fast fires ≥ 3 times
# during the 3 s window, slow does NOT double-launch while in flight,
# and slow's BG_PID reaches 0 after the async run completes.
#
# Slow-gated to keep the fast iteration loop sub-second. Uses ~4 s
# real wall-clock when enabled.

echo
echo '=== (8c) --async no-starvation (slow-gated; SLOW_TESTS=1 to enable) ==='
if [[ "${SLOW_TESTS:-0}" != "1" ]]; then
    echo "  SKIP: --async no-starvation (set SLOW_TESTS=1; ~4 s wall-clock)"
else
    _scheduler_reset_for_tests
    unset NEXUS_TEST_NOW   # use real clock so async subshell timeline aligns
    export MONITOR_SCHEDULER_STAGE_DIR=$(mktemp -d -t scheduler-async-XXXXXX)
    cleanup_async_stage() { rm -rf "$MONITOR_SCHEDULER_STAGE_DIR"; }
    trap 'cleanup_async_stage' EXIT

    fast_fires=0
    fast_async_task() { fast_fires=$(( fast_fires + 1 )); return 0; }
    slow_async_task() { sleep 3; return 0; }

    # slow_async interval is intentionally large (60 s) so the in-
    # flight guard is exercised by long-runtime-vs-not-yet-due
    # rather than by repeated near-instant re-fires. The first tick
    # launches the 3 s subshell; subsequent ticks have next_fire far
    # in the future, so they don't TRY to re-launch — exactly the
    # mode the watcher operates in (expensive tasks at 30-60 s
    # cadence whose helper sometimes runs > interval).
    _schedule_task fast_sync 1  fast_async_task --class cheap
    _schedule_task slow_async 60 slow_async_task --class expensive --async

    # Tick #1: both fire. slow launches in subshell; fast fires
    # synchronously.
    _scheduler_tick
    if (( ${TASK_BG_PID[slow_async]:-0} > 0 )); then
        pass "slow_async launched in subshell (pid=${TASK_BG_PID[slow_async]})"
    else
        fail "slow_async not in flight after first tick"
    fi
    assert_eq "fast_sync fired on tick #1" "$fast_fires" "1"

    # Tick every ~0.6 s for ~4 s total. fast_sync should fire each
    # tick (interval=1 s, real elapsed ≥ 1 s per tick). slow_async's
    # in-flight guard MUST suppress double-launch.
    slow_launches_during=0
    start_wall=$(date +%s)
    for i in 1 2 3 4 5 6; do
        sleep 0.6
        local_pid_before=${TASK_BG_PID[slow_async]:-0}
        _scheduler_tick
        local_pid_after=${TASK_BG_PID[slow_async]:-0}
        # A new launch is detected as: pid was 0 → now > 0.
        if (( local_pid_before == 0 && local_pid_after > 0 )); then
            slow_launches_during=$(( slow_launches_during + 1 ))
        fi
    done
    elapsed_wall=$(( $(date +%s) - start_wall ))

    if (( fast_fires >= 3 )); then
        pass "fast_sync fired ≥ 3 times during 3 s async window (got $fast_fires in ${elapsed_wall}s)"
    else
        fail "fast_sync starved by slow_async" "fired=$fast_fires expected ≥ 3"
    fi
    # First launch was on tick #1 (counted before this loop). During
    # the polling loop we should see AT MOST one additional launch —
    # specifically after the original 3 s slow_async run reaped.
    if (( slow_launches_during <= 1 )); then
        pass "slow_async respected in-flight guard (post-tick-1 launches=$slow_launches_during)"
    else
        fail "slow_async double-launched while in flight" \
             "post-tick-1 launches=$slow_launches_during (expected ≤ 1)"
    fi

    # Final reap check: after enough wall time, slow should have
    # completed and the BG_PID should be 0 (either reaped during a
    # tick or still pending if the timing was tight — try one extra
    # tick to flush).
    sleep 0.5
    _scheduler_tick
    if (( ${TASK_BG_PID[slow_async]:-0} == 0 )); then
        pass "slow_async BG_PID cleared after completion"
    else
        fail "slow_async BG_PID still set" \
             "pid=${TASK_BG_PID[slow_async]}"
    fi

    trap - EXIT
    cleanup_async_stage
fi

# ---- (9) SIGTERM during sleep (slow-gated) ------------------------------

echo
echo '=== (9) SIGTERM during sleep (slow-gated; SLOW_TESTS=1 to enable) ==='
if [[ "${SLOW_TESTS:-0}" != "1" ]]; then
    echo "  SKIP: SIGTERM-during-sleep test (set SLOW_TESTS=1; ~3s wall-clock)"
else
    # Spawn a subshell that:
    #   - source-loads the scheduler
    #   - registers one task that fires 120s in the future
    #   - calls _scheduler_sleep_until_next inside a trap-registering
    #     wrapper
    #   - prints a marker on exit so the parent can confirm clean shutdown
    # Send SIGTERM after ~0.5s; assert the subshell exited within
    # MONITOR_SCHEDULER_MAX_SLEEP + 1 seconds and reported the
    # shutdown rc=99.
    sleep_test=$(mktemp -t scheduler-sigterm-XXXXXX)
    cat > "$sleep_test" <<EOF
#!/usr/bin/env bash
set -uo pipefail
MONITOR_SCHEDULER_MAX_SLEEP=2
source "$_test_dir/_scheduler.sh"
_scheduler_install_signal_handlers
noop_task() { return 0; }
_schedule_task far_future 120 noop_task
TASK_NEXT_FIRE[far_future]=\$(( \$(date +%s) + 120 ))
_scheduler_sleep_until_next; rc=\$?
printf 'sleep-rc=%d shutdown=%d\n' "\$rc" "\$_scheduler_shutdown_requested"
EOF
    chmod +x "$sleep_test"
    "$sleep_test" > /tmp/scheduler-sigterm.out.$$ 2>&1 &
    child_pid=$!
    start_wall=$(date +%s)
    sleep 0.5
    kill -TERM "$child_pid" 2>/dev/null || true
    wait "$child_pid"; child_rc=$?
    elapsed_wall=$(( $(date +%s) - start_wall ))
    out=$(cat /tmp/scheduler-sigterm.out.$$ 2>/dev/null || true)
    rm -f "$sleep_test" /tmp/scheduler-sigterm.out.$$

    # Must exit cleanly within MAX_SLEEP + a small margin.
    if (( elapsed_wall <= 4 )); then
        pass "SIGTERM observed within MAX_SLEEP window (${elapsed_wall}s)"
    else
        fail "SIGTERM took ${elapsed_wall}s (expected <= 4s)" "$out"
    fi
    # Must observe shutdown=1 in the child output (the trap set the
    # flag; the post-sleep return propagated rc=99).
    if grep -q 'shutdown=1' <<<"$out"; then
        pass "shutdown flag set in child"
    else
        fail "child did not record shutdown=1" "$out"
    fi
    if grep -q 'sleep-rc=99' <<<"$out"; then
        pass "sleep_until_next returned rc=99 on shutdown"
    else
        fail "expected rc=99 from sleep_until_next" "$out"
    fi
fi

# ---- (10) async hang watchdog (#180 R4) ---------------------------------

echo
echo '=== (10a) watchdog budget = max(4 × interval, floor) ==='
_scheduler_reset_for_tests
MONITOR_SCHEDULER_ASYNC_TIMEOUT_FLOOR=300
noop_budget() { return 0; }
_schedule_task fastp 15  noop_budget --class medium --async   # 4×15=60  < floor → 300
_schedule_task slowp 600 noop_budget --class expensive --async # 4×600=2400 > floor → 2400
assert_eq "fast task floored at 300"      "$(_scheduler_async_timeout_budget fastp)" "300"
assert_eq "slow task uses 4×interval"     "$(_scheduler_async_timeout_budget slowp)" "2400"
MONITOR_SCHEDULER_ASYNC_TIMEOUT_FLOOR=0
assert_eq "floor=0 disables (budget 0)"   "$(_scheduler_async_timeout_budget fastp)" "0"
unset MONITOR_SCHEDULER_ASYNC_TIMEOUT_FLOOR

echo '=== (10b) injected clock: in-flight past budget is killed + re-armed ==='
_scheduler_reset_for_tests
export MONITOR_SCHEDULER_STAGE_DIR=$(mktemp -d -t scheduler-wd-XXXXXX)
MONITOR_SCHEDULER_LOG="$MONITOR_SCHEDULER_STAGE_DIR/sched.jsonl"
export MONITOR_SCHEDULER_LOG
MONITOR_SCHEDULER_ASYNC_TIMEOUT_FLOOR=100
export MONITOR_SCHEDULER_ASYNC_TIMEOUT_FLOOR
# Simulate a hung in-flight run by hand: a real background process the
# watchdog can actually kill, with TASK_BG_STARTED backdated past the
# budget. Using a live pid keeps the kill + wait path honest.
hang_task() { return 0; }
NEXUS_TEST_NOW=10000
_schedule_task hung 15 hang_task --class medium --async
sleep 600 & HUNG_PID=$!     # stand-in for a wedged gh call
TASK_BG_PID[hung]=$HUNG_PID
TASK_BG_STARTED[hung]=9800   # in-flight 200 s at NOW=10000; budget=max(60,100)=100
_scheduler_check_async_timeout hung 10000
if kill -0 "$HUNG_PID" 2>/dev/null; then
    fail "watchdog did not kill the hung child (pid=$HUNG_PID still alive)"
    kill "$HUNG_PID" 2>/dev/null || true
else
    pass "watchdog killed the hung child process"
fi
assert_eq "BG_PID cleared after kill"        "${TASK_BG_PID[hung]}"     "0"
assert_eq "last_rc recorded as 124 (timeout)" "${TASK_LAST_RC[hung]}"    "124"
if grep -q '"phase":"async-timeout"' "$MONITOR_SCHEDULER_LOG" 2>/dev/null; then
    pass "async-timeout telemetry row written"
else
    fail "no async-timeout telemetry row"
fi
# Re-arm: with BG_PID cleared and the task due, the next tick relaunches.
relaunched=0
hang_task() { relaunched=1; return 0; }
TASK_NEXT_FIRE[hung]=0
_scheduler_tick
# async launch is a subshell; the launch itself sets BG_PID again.
if (( ${TASK_BG_PID[hung]:-0} != 0 )); then
    pass "task re-armed and relaunched on next due tick"
    # reap the trivial relaunch
    wait "${TASK_BG_PID[hung]}" 2>/dev/null || true
else
    fail "task did not re-arm after watchdog kill"
fi
rm -rf "$MONITOR_SCHEDULER_STAGE_DIR"
unset MONITOR_SCHEDULER_STAGE_DIR MONITOR_SCHEDULER_LOG MONITOR_SCHEDULER_ASYNC_TIMEOUT_FLOOR NEXUS_TEST_NOW

echo '=== (10c) a completed-but-late run still reaps (not killed) ==='
_scheduler_reset_for_tests
export MONITOR_SCHEDULER_STAGE_DIR=$(mktemp -d -t scheduler-wd2-XXXXXX)
MONITOR_SCHEDULER_ASYNC_TIMEOUT_FLOOR=100
export MONITOR_SCHEDULER_ASYNC_TIMEOUT_FLOOR
done_task() { return 0; }
NEXUS_TEST_NOW=20000
_schedule_task latec 15 done_task --class medium --async
# Stage a completed run: rc sidecar present (child finished), but
# TASK_BG_STARTED backdated well past budget. The tick's reap must
# harvest it normally; the watchdog must NOT fire (reap clears BG_PID
# first, so check_async_timeout is never reached).
( : ) & DONE_PID=$!
wait "$DONE_PID" 2>/dev/null || true
TASK_BG_PID[latec]=$DONE_PID
TASK_BG_STARTED[latec]=19000   # 1000 s "in flight" but actually done
printf '0\n' > "$MONITOR_SCHEDULER_STAGE_DIR/latec.rc"
TASK_NEXT_FIRE[latec]=999999    # not due, so only the reap path runs
_scheduler_tick
assert_eq "completed run reaped to rc=0 (not 124)" "${TASK_LAST_RC[latec]}" "0"
assert_eq "BG_PID cleared by reap"                 "${TASK_BG_PID[latec]}"  "0"
rm -rf "$MONITOR_SCHEDULER_STAGE_DIR"
unset MONITOR_SCHEDULER_STAGE_DIR MONITOR_SCHEDULER_ASYNC_TIMEOUT_FLOOR NEXUS_TEST_NOW

# ---- summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
