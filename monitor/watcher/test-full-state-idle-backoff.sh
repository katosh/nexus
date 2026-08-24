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

# ---- 1b. default backoff curve now caps at 7200 (watcher-emit-noise) ----
# The default idle_backoff_max was raised 3600 → 7200: once the
# discriminating fixes remove the misleading/redundant/no-op emits, the
# residual deep-idle heartbeat is a pure liveness proof, and halving its
# overnight rate is the operator-requested noise reduction. The extra
# doubling adds one step (3600 → 7200 at ≥2 h idle). CLAMP-SAFE: the
# orchestrator dead-threshold clamp is derived from the BASE floor +
# full_state_emit_interval, NOT this max, so the curve below changes
# nothing about the startup clamp arithmetic.
echo "=== effective floor: raised default curve (base 900, max 7200) ==="
export MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS=7200
assert_eq "idle 3599s → 1800 tier"   "$(_full_state_effective_floor 3599)"   1800
assert_eq "idle 3600s → 3600 tier"   "$(_full_state_effective_floor 3600)"   3600
assert_eq "idle 7199s → 3600 tier"   "$(_full_state_effective_floor 7199)"   3600
assert_eq "idle 7200s → 7200 cap"    "$(_full_state_effective_floor 7200)"   7200
assert_eq "idle 999999s → 7200 cap"  "$(_full_state_effective_floor 999999)" 7200
MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS=3600

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

# your-org/nexus-code#659. This block previously asserted
# `max 3000: idle huge → 1800` under the label "never overshoots" — it
# codified the defect as the contract. `max` is a CAP: the reachable
# ceiling must equal it EXACTLY, for any positive value, not only for the
# rungs `base * 2^k`. Assert the reachable ceiling, not the ladder shape;
# the old assertion could not fail for this reason because rounding DOWN
# also satisfies "≤ max".
echo "=== effective floor: a non-rung max is a TRUE CAP (#659) ==="
MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS=3000
assert_eq "max 3000: idle 1800 → 1800 (rung below the cap)" \
    "$(_full_state_effective_floor 1800)"   1800
assert_eq "max 3000: idle huge → EXACTLY max, not the rung below" \
    "$(_full_state_effective_floor 999999)" 3000

# The reported case, verbatim: an operator asking for 12 h got 8 h,
# permanently, at every quiet duration out to 55 h.
MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS=43200
assert_eq "max 43200: idle 28800 → 28800"          "$(_full_state_effective_floor 28800)"  28800
assert_eq "max 43200: idle 57599 → 28800"          "$(_full_state_effective_floor 57599)"  28800
assert_eq "max 43200: idle 57600 → 43200 (the ask)" "$(_full_state_effective_floor 57600)"  43200
assert_eq "max 43200: idle 999999 → 43200"         "$(_full_state_effective_floor 999999)" 43200

# The tightest possible non-rung: max one second above base. Under the old
# guard `eff * 2 <= max` this was unreachable for every input, because the
# first step already overshoots — so a cap just above the base was inert.
MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS=901
assert_eq "max 901 (base+1): idle huge → 901" "$(_full_state_effective_floor 999999)" 901

# Monotonicity must survive the change: the floor never decreases as idle
# grows, and never exceeds the cap. Swept across a non-rung max, which is
# the shape that had no such guarantee before.
MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS=43200
mono_ok=1; ceil_ok=1; prev=0
for d in 0 450 900 1800 3600 7200 14400 28800 43200 57600 86400 172800 999999; do
    cur=$(_full_state_effective_floor "$d")
    (( cur < prev ))   && mono_ok=0
    (( cur > 43200 ))  && ceil_ok=0
    prev="$cur"
done
assert_eq "non-rung max: floor is monotonic in idle" "$mono_ok" 1
assert_eq "non-rung max: floor never exceeds the cap" "$ceil_ok" 1

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
