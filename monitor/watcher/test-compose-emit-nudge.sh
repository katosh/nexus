#!/usr/bin/env bash
# Unit tests for the compose_emit nudge hook (issue: deliveries→paste
# latency 52 s end-to-end against the operator-reported comment on
# 2026-05-27).
#
# Failure mode without the hook: deliveries_poll fires every 15 s and
# appends to a durable queue (PR #186), but compose_emit drains that
# queue only every MONITOR_INTERVAL (~60 s). A delivery that lands one
# second after compose_emit's last tick sits in the queue for the full
# 60 s window before being pasted. Total observed latency from comment-
# creation to orchestrator-paste was ~52 s in the trigger comment
# 4559632841.
#
# Fix shape: a post-tick hook in main.sh observes
#   - `$STATE_DIR/deliveries-queue.lines` mtime (append by snapshot_deliveries)
#   - `<stage>/github_poll.out` mtime + size (atomic-replace by snapshot_github)
# and pulls compose_emit forward via `_schedule_fire_now compose_emit` +
# `_schedule_override compose_emit 5 60` whenever new bytes arrive. The
# override is the same primitive used by `_v2_task_target_window_probe`
# on rc=2 (target-absent respawn path) — proven shape (#172 / scheduler
# test suite §8d).
#
# These tests FAIL on the pre-fix code because `_compose_nudge.sh` and
# `_compose_emit_nudge_check` do not exist.
#
# Run: bash monitor/watcher/test-compose-emit-nudge.sh
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

# Source the modules under test.
# shellcheck source=_scheduler.sh
source "$_test_dir/_scheduler.sh"
# shellcheck source=_compose_nudge.sh
source "$_test_dir/_compose_nudge.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
queue_file="$WORK/deliveries-queue.lines"
gh_out_file="$WORK/github_poll.out"

# Helper: stamp a file's mtime to a precise epoch (portable; tests should
# not depend on `touch -d @epoch` availability everywhere).
stamp_mtime() {
    local f="$1" epoch="$2"
    # GNU coreutils touch accepts `-d @<epoch>`.
    touch -d "@${epoch}" "$f" 2>/dev/null || \
        touch -t "$(date -d "@${epoch}" +%Y%m%d%H%M.%S 2>/dev/null)" "$f"
}

dummy_compose_emit() { return 0; }

# ============================================================
# (1) latency-regression: queue append → nudge fires + override applied
# ============================================================
#
# This is the core failure-vs-fix contrast. Under the pre-fix watcher,
# compose_emit's next_fire stays at base + cadence (e.g., 60 s from
# anchor) regardless of queue state. With the hook, a fresh queue mtime
# pulls next_fire forward and applies the 5 s-for-60 s override, so the
# next tick fires compose_emit within the override interval rather than
# at the 60 s base cadence.

echo '=== (1) queue mtime advance → nudge fires compose_emit ==='
_compose_nudge_reset_for_tests
_scheduler_reset_for_tests
NEXUS_TEST_NOW=1000
_schedule_task compose_emit 60 dummy_compose_emit --class medium

# Simulate steady state: compose_emit fired at t=1000; next due at 1060.
TASK_NEXT_FIRE[compose_emit]=1060

# snapshot_deliveries appends to queue at t=1001.
printf 'issue=42 id=99 author=operator\n  body: hello\n' > "$queue_file"
stamp_mtime "$queue_file" 1001

NEXUS_TEST_NOW=1001
_compose_emit_nudge_check "$queue_file" "$gh_out_file"
nudge_rc=$?

assert_eq "nudge fired on queue advance" "$nudge_rc" "0"
assert_eq "next_fire forced to 0" "${TASK_NEXT_FIRE[compose_emit]}" "0"
assert_eq "override interval = 5" "${TASK_OVERRIDE_INT[compose_emit]:-0}" "5"
assert_eq "override TIL = now + 60" "${TASK_OVERRIDE_TIL[compose_emit]:-0}" "1061"

# ============================================================
# (2) idempotent: a second tick with unchanged mtime is a no-op
# ============================================================
#
# Catches the "every tick re-nudges, override TIL slides forward forever"
# bug. The hook must remember the last-seen mtime and only fire when it
# advances.

echo
echo '=== (2) unchanged mtime → no re-nudge ==='
# Continue from (1)'s state: last_queue_mtime=1001 already stored.
TASK_NEXT_FIRE[compose_emit]=1010
unset 'TASK_OVERRIDE_INT[compose_emit]'
unset 'TASK_OVERRIDE_TIL[compose_emit]'
# Same file, same mtime → no new event.
_compose_emit_nudge_check "$queue_file" "$gh_out_file"
second_rc=$?

assert_eq "second call returns rc=1 (no nudge)" "$second_rc" "1"
assert_eq "next_fire untouched on no-op" "${TASK_NEXT_FIRE[compose_emit]}" "1010"
assert_eq "override not re-applied" "${TASK_OVERRIDE_INT[compose_emit]:-0}" "0"

# ============================================================
# (3) drain pattern: queue file gone → no nudge until new append
# ============================================================
#
# `_v2_task_compose_emit` drains by renaming the queue file. After
# drain, the file is absent. The hook must treat absence as "no new
# events" (mtime 0 ≤ last_seen).

echo
echo '=== (3) post-drain (queue absent) → no nudge until new event ==='
_compose_nudge_reset_for_tests
_scheduler_reset_for_tests
NEXUS_TEST_NOW=2000
_schedule_task compose_emit 60 dummy_compose_emit --class medium

# Initial nudge from a queue append at t=2000.
printf 'issue=9 id=99 author=operator\n  body: pre-drain\n' > "$queue_file"
stamp_mtime "$queue_file" 2000
_compose_emit_nudge_check "$queue_file" "$gh_out_file"
assert_eq "pre-drain nudge fired" "${TASK_NEXT_FIRE[compose_emit]}" "0"

# Drain removes the queue file.
rm -f "$queue_file"
unset 'TASK_OVERRIDE_TIL[compose_emit]'
unset 'TASK_OVERRIDE_INT[compose_emit]'
TASK_NEXT_FIRE[compose_emit]=2060

_compose_emit_nudge_check "$queue_file" "$gh_out_file"
post_drain_rc=$?
assert_eq "post-drain no-op (file absent)" "$post_drain_rc" "1"
assert_eq "next_fire unchanged" "${TASK_NEXT_FIRE[compose_emit]}" "2060"

# New event after drain → re-creates queue with fresher mtime.
printf 'issue=10 id=100 author=operator\n  body: post-drain\n' > "$queue_file"
stamp_mtime "$queue_file" 2010
_compose_emit_nudge_check "$queue_file" "$gh_out_file"
new_nudge_rc=$?

assert_eq "new event after drain → nudge fires" "$new_nudge_rc" "0"
assert_eq "next_fire forced again" "${TASK_NEXT_FIRE[compose_emit]}" "0"

# ============================================================
# (4) github_poll: empty fire → no nudge; non-empty → nudge
# ============================================================
#
# github_poll.out is replaced atomically every fire — mtime updates even
# when the helper produced zero bytes. Without a size guard, every 600 s
# github_poll cycle would nudge compose_emit. Test that an empty fire is
# ignored and the next non-empty fire still nudges.

echo
echo '=== (4) github_poll empty vs non-empty ==='
_compose_nudge_reset_for_tests
_scheduler_reset_for_tests
NEXUS_TEST_NOW=3000
_schedule_task compose_emit 60 dummy_compose_emit --class medium
TASK_NEXT_FIRE[compose_emit]=3060

# Empty github_poll output (helper produced nothing this cycle).
: > "$gh_out_file"
stamp_mtime "$gh_out_file" 3001
_compose_emit_nudge_check "/does/not/exist" "$gh_out_file"
empty_rc=$?

assert_eq "empty github_poll.out → no nudge" "$empty_rc" "1"
assert_eq "next_fire unchanged" "${TASK_NEXT_FIRE[compose_emit]}" "3060"

# Subsequent fire produces real bytes — mtime must advance past the
# previously-stored last_seen value for the nudge to fire.
printf 'issue=11 id=22 author=operator\n  body: gh-event\n' > "$gh_out_file"
stamp_mtime "$gh_out_file" 3002
_compose_emit_nudge_check "/does/not/exist" "$gh_out_file"
gh_rc=$?

assert_eq "non-empty github_poll.out → nudge" "$gh_rc" "0"
assert_eq "next_fire forced to 0" "${TASK_NEXT_FIRE[compose_emit]}" "0"

# ============================================================
# (5) repeated nudges within window — latest override TIL wins, no leak
# ============================================================
#
# `_schedule_override` documents stacking semantics as "latest wins". The
# hook can fire on consecutive ticks if the queue keeps growing; verify
# the override TIL advances forward (newer end time) rather than
# accumulating duplicate state.

echo
echo '=== (5) consecutive nudges — latest TIL wins, no stale state ==='
_compose_nudge_reset_for_tests
_scheduler_reset_for_tests
NEXUS_TEST_NOW=4100
_schedule_task compose_emit 60 dummy_compose_emit --class medium

printf 'issue=1 id=1 author=operator\n  body: a\n' > "$queue_file"
stamp_mtime "$queue_file" 4100
_compose_emit_nudge_check "$queue_file" "$gh_out_file"
first_til=${TASK_OVERRIDE_TIL[compose_emit]:-0}

NEXUS_TEST_NOW=4103
# Append more (queue file mtime advances).
printf 'issue=2 id=2 author=operator\n  body: b\n' >> "$queue_file"
stamp_mtime "$queue_file" 4103
_compose_emit_nudge_check "$queue_file" "$gh_out_file"
second_til=${TASK_OVERRIDE_TIL[compose_emit]:-0}

assert_eq "first override TIL = now1 + 60" "$first_til" "4160"
assert_eq "second override TIL = now2 + 60 (advanced)" "$second_til" "4163"

# Verify the override interval is still 5 (not multiplied or accumulated).
assert_eq "override interval still 5" "${TASK_OVERRIDE_INT[compose_emit]:-0}" "5"

# ============================================================
# (6) integration: tick-driven latency-regression
# ============================================================
#
# End-to-end (clock-injected): a comment arrives just after compose_emit
# fires its base-cadence cycle. Without the nudge the next compose_emit
# is +60 s away. With the nudge, compose_emit re-fires within the 5 s
# override interval. Assert the actual number of compose_emit fires in
# a 15 s wall-clock-equivalent window is ≥ 2 (force-fire on the next
# tick + at least one follow-up under the 5 s override).

echo
echo '=== (6) end-to-end: nudge yields ≥2 compose_emit fires in 15 s ==='
_compose_nudge_reset_for_tests
_scheduler_reset_for_tests

emit_fires=0
counted_emit() { emit_fires=$(( emit_fires + 1 )); return 0; }

NEXUS_TEST_NOW=5000
_schedule_task compose_emit 60 counted_emit --class medium

# Tick 1: compose_emit fires (next_fire seeded at 0). next_fire = 5060.
_scheduler_tick
assert_eq "tick 1 fires compose_emit" "$emit_fires" "1"
assert_eq "tick 1 next_fire = 5060" "${TASK_NEXT_FIRE[compose_emit]}" "5060"

# t=5001: queue gets a new event.
printf 'issue=42 id=99 author=operator\n  body: x\n' > "$queue_file"
stamp_mtime "$queue_file" 5001
NEXUS_TEST_NOW=5001
_compose_emit_nudge_check "$queue_file" "$gh_out_file"

# Tick 2 at t=5002: force-fire pulls compose_emit forward.
NEXUS_TEST_NOW=5002
_scheduler_tick
assert_eq "tick 2 fires compose_emit under force" "$emit_fires" "2"
# next_fire = anchor 5002 + override interval 5 = 5007.
assert_eq "tick 2 next_fire under override = 5007" "${TASK_NEXT_FIRE[compose_emit]}" "5007"

# Tick 3 at t=5007: override-cadence re-fire.
NEXUS_TEST_NOW=5007
_scheduler_tick
assert_eq "tick 3 (override cadence) fires compose_emit" "$emit_fires" "3"
assert_eq "tick 3 next_fire = 5012" "${TASK_NEXT_FIRE[compose_emit]}" "5012"

# Tick 4 at t=5015: override-cadence again. By now without the nudge,
# next_fire would still be 5060 (base) and compose_emit would NOT have
# fired since 5000. With the nudge: ≥4 fires by t=5015.
NEXUS_TEST_NOW=5015
_scheduler_tick
if (( emit_fires >= 4 )); then
    pass "compose_emit fired ≥4 times by t=5015 (got $emit_fires; vs 1 without nudge)"
else
    fail "compose_emit did not reach 4 fires under override" "got $emit_fires"
fi

# ============================================================
# (7) requests_poll.out as a third nudge source (`#483` follow-up)
# ============================================================
#
# Without this source nothing pulls compose_emit forward for a newly
# filed request — a `reply: required` remote ask waits out the full
# 60 s compose cadence (and pre-#483, usually missed it entirely via
# the stage-overwrite race). Same mtime+size semantics as github_poll:
# empty rewrite → no nudge; non-empty → nudge. Two-arg calls (all the
# tests above) stay valid — the third source is optional.

echo
echo '=== (7) requests_poll.out: empty vs non-empty; back-compat ==='
_compose_nudge_reset_for_tests
_scheduler_reset_for_tests
NEXUS_TEST_NOW=6000
_schedule_task compose_emit 60 dummy_compose_emit --class medium
TASK_NEXT_FIRE[compose_emit]=6060
req_out_file="$WORK/requests_poll.out"

# Empty requests render (nothing due) — atomically rewritten every 10 s
# fire, mtime advances, size 0 → no nudge.
: > "$req_out_file"
stamp_mtime "$req_out_file" 6001
_compose_emit_nudge_check "/does/not/exist" "/does/not/exist" "$req_out_file"
req_empty_rc=$?
assert_eq "empty requests_poll.out → no nudge" "$req_empty_rc" "1"
assert_eq "next_fire unchanged" "${TASK_NEXT_FIRE[compose_emit]}" "6060"

# A due request renders → non-empty stage → nudge.
printf 'request=20260709T000000Z-w-ask origin=w kind=question priority=high\n    summary: please\n    file=/x.claimed.md\n' > "$req_out_file"
stamp_mtime "$req_out_file" 6002
_compose_emit_nudge_check "/does/not/exist" "/does/not/exist" "$req_out_file"
req_rc=$?
assert_eq "non-empty requests_poll.out → nudge" "$req_rc" "0"
assert_eq "next_fire forced to 0" "${TASK_NEXT_FIRE[compose_emit]}" "0"

# Post-paste truncation (main.sh consumes the stage after a delivered
# request body): mtime advances, size 0 → nudge goes quiet.
TASK_NEXT_FIRE[compose_emit]=6070
: > "$req_out_file"
stamp_mtime "$req_out_file" 6003
_compose_emit_nudge_check "/does/not/exist" "/does/not/exist" "$req_out_file"
req_trunc_rc=$?
assert_eq "post-paste truncated stage → no nudge" "$req_trunc_rc" "1"
assert_eq "next_fire unchanged after truncation" "${TASK_NEXT_FIRE[compose_emit]}" "6070"

# ============================================================
# summary
# ============================================================

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
