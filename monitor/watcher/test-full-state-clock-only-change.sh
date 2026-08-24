#!/usr/bin/env bash
# A clock-only reclassification is NOT a state change — your-org/nexus-code#658.
#
# The defect: the full-state canonical includes the `workspace:` tally
# line, whose counts are a derived summary of the per-window rows. A
# window crossing MONITOR_IDLE_CLOSE_HOURS moves one unit from `idle` to
# `idle-too-long` while NOTHING happens on the board. That registered as
# a genuine canonical change, so it (a) emitted immediately, bypassing
# the adaptive idle backoff, and (b) reset the idle-streak anchor,
# discarding an accumulated floor of 28800s and forcing the whole
# doubling ladder to re-climb.
#
# `_emit_volatile_strip` already established the principle — it strips
# every duration AND one bare tally count (`N awaiting-input`) — and
# applied it to exactly one of the eleven counters on that line.
#
# WHY THIS SURVIVED: `test-full-state-suppression.sh` and
# `test-full-state-emit-noise.sh` both hold the clock still. The only
# test that can catch this one is a test that advances ONLY the clock,
# which is what every case below does.
#
# Run: bash monitor/watcher/test-full-state-clock-only-change.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_emit_dedup.sh
source "$_test_dir/_emit_dedup.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

strip() { printf '%s\n' "$1" | _emit_volatile_strip; }

# same <label> <a> <b>   — the two canonicals must be INDISTINGUISHABLE
same() {
    if [[ "$(strip "$2")" == "$(strip "$3")" ]]; then pass "$1"
    else
        fail "$1 — canonicals differ:"
        diff <(strip "$2") <(strip "$3") | sed 's/^/      /' >&2
    fi
}
# differs <label> <a> <b> — the two canonicals must be DISTINCT
differs() {
    if [[ "$(strip "$2")" != "$(strip "$3")" ]]; then pass "$1"
    else fail "$1 — canonicals are identical but should differ"; fi
}

# tally <busy> <idle> <too_long> <absent> <over> <interrupted>
tally() {
    printf 'workspace: %s busy | %s idle | 0 retained | %s idle-too-long | %s pane-absent | %s over-limit | 0 orphan-async | %s interrupted | 0 parked-skeptic | 0 idle-children | 0 awaiting-input' \
        "$1" "$2" "$3" "$4" "$5" "$6"
}
# canonical <tally> <w1_age> <w1_state>
canonical() {
    printf '%s\n--- workspace snapshot ---\n  - w1 idle %ss (state=%s)\n  - w2 idle 4000s (state=empty)\n  - w3 (active, state=busy)\n' \
        "$1" "$2" "$3"
}

# ---------------------------------------------------------------------------
echo "=== case 1: THE DEFECT — a window crosses idle-too-long, nothing else ==="
# Only the clock moved: w1 aged past the 24h threshold. Its row keeps the
# same state and only its age changed (already stripped); the tally moves
# one unit idle → idle-too-long.
BEFORE=$(canonical "$(tally 10 1 0 0 0 0)" 86399 empty)
AFTER=$( canonical "$(tally 10 0 1 0 0 0)" 86401 empty)
same "clock-only idle-too-long crossing is NOT a canonical change" "$BEFORE" "$AFTER"

echo "=== case 2: the same for every other clock-derived bucket ==="
# Whichever bucket a future threshold moves a window into, a pure
# reclassification with no row change must stay invisible.
same "any idle / idle-too-long split of the same total is invisible" \
    "$(canonical "$(tally 10 3 0 0 0 0)" 500 empty)" \
    "$(canonical "$(tally 10 2 1 0 0 0)" 900 empty)"
same "…including the whole idle population crossing at once" \
    "$(canonical "$(tally 10 3 0 0 0 0)" 500 empty)" \
    "$(canonical "$(tally 10 0 3 0 0 0)" 900 empty)"
# …but a window ENTERING or LEAVING the idle population is an EVENT, not
# a clock tick, and the sum moves. This is what stops the fold from
# degenerating into "the tally no longer carries anything".
differs "a worker JOINING the idle population surfaces" \
    "$(canonical "$(tally 10 1 0 0 0 0)" 500 empty)" \
    "$(canonical "$(tally  9 2 0 0 0 0)" 500 empty)"
differs "a worker LEAVING the idle population surfaces" \
    "$(canonical "$(tally 10 3 0 0 0 0)" 500 empty)" \
    "$(canonical "$(tally 11 2 0 0 0 0)" 500 empty)"

echo "=== case 3: ages alone, tally identical (the pre-existing guarantee) ==="
same "per-window ages advance, nothing else" \
    "$(canonical "$(tally 10 1 0 0 0 0)" 100 empty)" \
    "$(canonical "$(tally 10 1 0 0 0 0)" 99999 empty)"

# ---------------------------------------------------------------------------
echo "=== case 4: POSITIVE CONTROLS — actionable transitions still punch through ==="
# #658 is explicit that pane-absent / over-limit / interrupted must still
# surface. They do, because they move a ROW's state=, which is identity,
# not a clock bucket. If these ever pass, the fix has gone too far and the
# board has become blind.
BASE=$(canonical "$(tally 10 1 0 0 0 0)" 5000 empty)
differs "state=empty → state=absent surfaces" \
    "$BASE" "$(canonical "$(tally 10 0 0 1 0 0)" 5000 absent)"
differs "state=empty → state=over-limit surfaces" \
    "$BASE" "$(canonical "$(tally 10 0 0 0 1 0)" 5000 over-limit)"
differs "state=empty → state=user-typing surfaces" \
    "$BASE" "$(canonical "$(tally 10 0 0 0 0 1)" 5000 user-typing)"

echo "=== case 5: membership changes still punch through ==="
differs "a window disappearing surfaces" \
    "$BASE" \
    "$(printf '%s\n--- workspace snapshot ---\n  - w2 idle 4000s (state=empty)\n  - w3 (active, state=busy)\n' "$(tally 10 0 0 0 0 0)")"
differs "a window appearing surfaces" \
    "$BASE" \
    "$(printf '%s\n--- workspace snapshot ---\n  - w1 idle 5000s (state=empty)\n  - w2 idle 4000s (state=empty)\n  - w3 (active, state=busy)\n  - w4 (active, state=busy)\n' "$(tally 11 1 0 0 0 0)")"
differs "a window being RENAMED surfaces" \
    "$BASE" "$(printf '%s\n--- workspace snapshot ---\n  - wRENAMED idle 5000s (state=empty)\n  - w2 idle 4000s (state=empty)\n  - w3 (active, state=busy)\n' "$(tally 10 1 0 0 0 0)")"

echo "=== case 6: the tally LABELS are still fingerprinted ==="
# Only the counts are volatile. A schema change to the line — a new
# counter, a renamed one — must still register, otherwise the strip has
# stopped distinguishing a summary from its absence.
differs "a NEW counter on the tally line surfaces" \
    "$BASE" \
    "$(canonical "$(tally 10 1 0 0 0 0) | 0 quarantined" 5000 empty)"

echo "=== case 7: an UNKNOWN counter defaults to the SAFE side ==="
# Regression guard for the SHAPE of the fix, not just its effect — and the
# assertion that the first attempt at #658 got backwards.
#
# The first version stripped every count on the line generically. That put
# an unknown counter on the side of SILENCE, and it broke `pane-absent
# 1→0` — a worker dying — because a `poll-resurface` body carries no
# per-window rows, so the tally is the only place that count appears.
# `test-emit-dedup.sh` caught it; this suite did not, because it asserted
# the over-broad behaviour as the contract.
#
# The asymmetry is the whole design. An unlisted CLOCK-derived counter
# costs one noisy emit. An unlisted EVENT-derived counter costs a silent
# miss. Only one of those is recoverable, so the default must be "keep".
differs "an unknown future counter still SURFACES (keeps its count)" \
    "$(canonical "$(tally 10 1 0 0 0 0) | 3 some-future-bucket" 5000 empty)" \
    "$(canonical "$(tally 10 1 0 0 0 0) | 7 some-future-bucket" 5000 empty)"

echo "=== case 7b: THE REGRESSION — pane-absent on a row-less body (#664) ==="
# The exact shape test-emit-dedup.sh asserts, reproduced here so this
# suite owns its own failure. A poll-resurface body has NO per-window
# rows: the tally line is the sole carrier.
ROWLESS_A='workspace: 1 busy | 1 idle | 0 retained | 0 idle-too-long | 1 pane-absent | 0 over-limit | 0 orphan-async | 0 awaiting-input
--- pending decisions ---
window=w1 fp=abc kind=idle_prompt unresolved=false'
ROWLESS_B='workspace: 1 busy | 1 idle | 0 retained | 0 idle-too-long | 0 pane-absent | 0 over-limit | 0 orphan-async | 0 awaiting-input
--- pending decisions ---
window=w1 fp=abc kind=idle_prompt unresolved=false'
differs "pane-absent 1→0 surfaces with no per-window rows to fall back on" \
    "$ROWLESS_A" "$ROWLESS_B"
same "…while the same row-less body with only a clock crossing does not" \
    "$ROWLESS_A" \
    "$(printf '%s' "$ROWLESS_A" | sed 's/1 idle | 0 retained | 0 idle-too-long/0 idle | 0 retained | 1 idle-too-long/')"

echo "=== case 8: the awaiting-input scalar still collapses (#152) ==="
same "awaiting-input toggling 0↔1 is still invisible" \
    "$(canonical "$(tally 10 1 0 0 0 0)" 5000 empty)" \
    "$(printf 'workspace: 10 busy | 1 idle | 0 retained | 0 idle-too-long | 0 pane-absent | 0 over-limit | 0 orphan-async | 0 interrupted | 0 parked-skeptic | 0 idle-children | 1 awaiting-input\n--- workspace snapshot ---\n  - w1 idle 5000s (state=empty)\n  - w2 idle 4000s (state=empty)\n  - w3 (active, state=busy)\n')"

# ---------------------------------------------------------------------------
printf '\n=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then echo "ALL TESTS PASSED"; exit 0; fi
exit 1
