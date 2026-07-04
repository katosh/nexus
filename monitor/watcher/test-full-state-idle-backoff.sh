#!/usr/bin/env bash
# Unit tests for the adaptive full-state heartbeat idle backoff
# (emit/exemption fidelity, Defect A). Two layers:
#
#   1. The pure helper `_full_state_effective_floor` (in _emit_dedup.sh):
#      the effective safety floor grows with sustained no-change idle,
#      capped at the max, and snaps back to base when idle resets. Config
#      toggles (enabled=false, max<=base) restore the fixed-floor floor.
#
#   2. The suppression DECISION main.sh drives from it: reproduce the
#      compose_emit conditional inline (as test-full-state-suppression does)
#      to prove that a long idle streak stretches the effective gap so a
#      heartbeat that WOULD emit at the base floor is now suppressed — i.e.
#      the heartbeat cadence actually rarefies under sustained idle — while
#      the change-triggered path is untouched.
#
# Run: bash monitor/watcher/test-full-state-idle-backoff.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_emit_dedup.sh
source "$_test_dir/_emit_dedup.sh"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- 1. pure effective-floor curve (base=900, max=3600) -----------------
echo "=== effective floor: default backoff curve (base 900, max 3600) ==="
export MONITOR_FULL_STATE_SAFETY_FLOOR_SECONDS=900
export MONITOR_FULL_STATE_IDLE_BACKOFF_ENABLED=true
export MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS=3600

assert_eq "idle 0s → base"          "$(_full_state_effective_floor 0)"     900
assert_eq "idle 899s → base"        "$(_full_state_effective_floor 899)"   900
assert_eq "idle 1799s → base"       "$(_full_state_effective_floor 1799)"  900
assert_eq "idle 1800s → 1800 tier"  "$(_full_state_effective_floor 1800)"  1800
assert_eq "idle 3599s → 1800 tier"  "$(_full_state_effective_floor 3599)"  1800
assert_eq "idle 3600s → 3600 cap"   "$(_full_state_effective_floor 3600)"  3600
assert_eq "idle 999999s → capped"   "$(_full_state_effective_floor 999999)" 3600
# Monotone non-decreasing (a stretch never shrinks as idle grows).
prev=0
mono_ok=1
for d in 0 600 1200 1800 2400 3600 7200 100000; do
    cur=$(_full_state_effective_floor "$d")
    (( cur >= prev )) || mono_ok=0
    prev=$cur
done
assert_eq "curve is monotone non-decreasing" "$mono_ok" 1

echo "=== effective floor: disabled / degenerate configs return base ==="
MONITOR_FULL_STATE_IDLE_BACKOFF_ENABLED=false
assert_eq "disabled → base at idle 0"    "$(_full_state_effective_floor 0)"     900
assert_eq "disabled → base at idle 1e6"  "$(_full_state_effective_floor 1000000)" 900
MONITOR_FULL_STATE_IDLE_BACKOFF_ENABLED=true
MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS=900   # max<=base disables stretch
assert_eq "max<=base → base at idle 1e6" "$(_full_state_effective_floor 1000000)" 900
MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS=600   # max<base
assert_eq "max<base → base at idle 1e6"  "$(_full_state_effective_floor 1000000)" 900
MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS=3600

echo "=== effective floor: non-power-of-two max clamps, never overshoots ==="
MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS=3000
assert_eq "max 3000: idle 1800 → 1800"   "$(_full_state_effective_floor 1800)"  1800
assert_eq "max 3000: idle huge → ≤max"   "$(_full_state_effective_floor 999999)" 1800
MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS=3600

# ---- 2. suppression decision uses the effective floor -------------------
# Reproduce main.sh's compose_emit conditional: a heartbeat is SUPPRESSED
# when (now - last_emit_mtime) < effective_floor, and EMITTED otherwise.
# The idle streak (now - anchor) selects the floor. This is the behaviour
# that rarefies the heartbeat on a quiet night.
echo "=== suppression decision: sustained idle stretches the gap ==="
decide() {   # decide <age_since_last_emit> <idle_streak> -> emit|suppress
    local age="$1" idle="$2" floor
    floor=$(_full_state_effective_floor "$idle")
    if (( age < floor )); then echo suppress; else echo emit; fi
}
# A 20-minute gap on a FRESH streak (idle just began) → base floor 900 →
# 1200 >= 900 → the heartbeat EMITS (responsive early).
assert_eq "gap 1200s, fresh streak → emit"          "$(decide 1200 300)"   emit
# The SAME 20-minute gap once idle has persisted an hour → floor 3600 →
# 1200 < 3600 → SUPPRESSED. The heartbeat has rarefied.
assert_eq "gap 1200s, hour-long idle → suppress"    "$(decide 1200 3700)"  suppress
# It still fires eventually — a gap past the stretched floor emits (the
# liveness heartbeat is never disabled).
assert_eq "gap 3700s, hour-long idle → emit"        "$(decide 3700 3700)"  emit
# Backoff OFF reproduces the fixed 900 floor regardless of idle.
MONITOR_FULL_STATE_IDLE_BACKOFF_ENABLED=false
assert_eq "backoff off: gap 1200s, long idle → emit" "$(decide 1200 3700)" emit
MONITOR_FULL_STATE_IDLE_BACKOFF_ENABLED=true

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then echo "ALL TESTS PASSED"; exit 0; else echo "TESTS FAILED"; exit 1; fi
