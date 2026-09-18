#!/usr/bin/env bash
# Tests for your-org/nexus-code#677 — the idle-probe classification audit trail
# in monitor/watcher/_idle_probe.sh.
#
# The defect: every classification this probe computes was rendered into the
# orchestrator's row and then DISCARDED. Nothing wrote it to
# `action-log.jsonl`. So no detector's accuracy was auditable after the fact —
# the `#665` base rate (11 false positives, 0 true) exists ONLY because an
# operator watched emits scroll past and tallied by hand.
#
# These assertions are deliberately BEHAVIOURAL: they read the bytes back off
# disk and parse them with jq. `#685` is filed about exactly the opposite —
# an emit guarded by `( … ) 2>/dev/null || true` whose regression is silent
# because the only coverage is a source assertion. This trail is best-effort
# for the same (correct) reason, so it needs the stronger test to compensate.
#
# Run: bash monitor/watcher/test-idle-classification.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0; FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n         want: %q\n          got: %q\n' "$label" "$want" "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    if [[ -n "$needle" ]] && grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n         want: %s\n         in: %s\n' "$label" "$needle" "$hay" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/.state"; mkdir -p "$STATE_DIR"; export STATE_DIR
LOG="$STATE_DIR/action-log.jsonl"

# Source the real module. `_idle_probe.sh` is a function library; sourcing it
# defines the helpers without running the probe.
# shellcheck source=monitor/watcher/_idle_probe.sh
source "$_test_dir/_idle_probe.sh" >/dev/null 2>&1 || {
    echo "FAIL: could not source _idle_probe.sh" >&2; exit 1; }

# `grep -c` prints `0` on no match AND exits 1 — `&& grep -c … || echo 0`
# yielded "0\n0" for a log that exists with no rows yet (#725).
rows() {
    if [[ -f "$LOG" ]]; then grep -c '"event":"idle-classification"' "$LOG" || true
    else echo 0
    fi
}
last() { grep '"event":"idle-classification"' "$LOG" | tail -1; }

echo "=== #677: a classification reaches disk, with its fields ==="

_idle_record_classification "w1" "paste-unconfirmed" "paste 335s ago; no UserPromptSubmit"
assert_eq "a classification is APPENDED to the action log" "$(rows)" "1"

# Field-level, parsed — not a substring match on the raw line. A row that
# lands with the wrong shape is the same as no row for anyone querying it.
_r=$(last)
assert_eq "…carrying the window"        "$(jq -r '.window' <<<"$_r")" "w1"
assert_eq "…carrying the class"         "$(jq -r '.cls'    <<<"$_r")" "paste-unconfirmed"
assert_eq "…carrying the detail"        "$(jq -r '.detail' <<<"$_r")" "paste 335s ago; no UserPromptSubmit"
assert_eq "…agent is the watcher"       "$(jq -r '.agent'  <<<"$_r")" "watcher"
assert_eq "…event name is stable"       "$(jq -r '.event'  <<<"$_r")" "idle-classification"
assert_eq "…and a first sighting records prev as '-'" "$(jq -r '.prev' <<<"$_r")" "-"
assert_contains "…and it carries a timestamp" "$(jq -r '.ts' <<<"$_r")" "-"

echo "=== #677: TRANSITION-only — the property that makes firings countable ==="

# The same class on subsequent cycles must NOT append. A window sitting
# `no-wrap-up` for six hours would otherwise write thousands of identical rows,
# and the log would answer "what was the state" while being useless for "how
# often did this fire" — which is the question the issue exists to answer.
_idle_record_classification "w1" "paste-unconfirmed" "paste 340s ago"
_idle_record_classification "w1" "paste-unconfirmed" "paste 380s ago"
_idle_record_classification "w1" "paste-unconfirmed" "paste 420s ago"
assert_eq "three more cycles in the SAME class append NOTHING" "$(rows)" "1"

# …and a real change does append, carrying what it came FROM. Without this
# control the suppression above would be satisfied by a function that never
# writes anything at all.
_idle_record_classification "w1" "wrapped" "wrap-up at 11:28"
assert_eq "CONTROL: a genuine transition DOES append" "$(rows)" "2"
_r=$(last)
assert_eq "…the new class"    "$(jq -r '.cls'  <<<"$_r")" "wrapped"
assert_eq "…and the class it came FROM" "$(jq -r '.prev' <<<"$_r")" "paste-unconfirmed"

# Flapping is the signal the issue most wants countable: back to the old class
# is itself a transition, not a no-op.
_idle_record_classification "w1" "paste-unconfirmed" "resurfaced"
assert_eq "flapping back is a transition, not a no-op" "$(rows)" "3"

echo "=== #677: per-window, and pruned with the window ==="

_idle_record_classification "w2" "no-wrap-up" "idle 142s"
assert_eq "a second window is tracked independently" "$(rows)" "4"
_idle_record_classification "w2" "no-wrap-up" "idle 200s"
assert_eq "…and deduped independently" "$(rows)" "4"

# The stamp is per-window state and must die with the window (issue #61's
# disappearance prune), or a resumed window-name inherits the prior life's
# class and its first real classification is silently swallowed as "no change".
assert_eq "the stamp exists while the window does" \
    "$( [[ -f "$(_idle_class_stamp_path w2)" ]] && echo yes || echo no )" "yes"
_idle_class_stamp_drop "w2"
assert_eq "…and is dropped by the prune helper" \
    "$( [[ -f "$(_idle_class_stamp_path w2)" ]] && echo yes || echo no )" "no"
_idle_record_classification "w2" "no-wrap-up" "idle 260s"
assert_eq "…so a resumed window re-records rather than being swallowed" "$(rows)" "5"

echo "=== #677: best-effort — it must never break the probe ==="

# The trail is deliberately best-effort: a probe that stopped rendering rows
# because its audit log failed would be a far worse defect than the missing
# trail. Assert the FAILURE path is survivable, both in rc and in effect.
( STATE_DIR="" ; _idle_record_classification "w3" "wrapped" "x" )
assert_eq "an unset STATE_DIR returns 0 (never flips the caller's rc)" "$?" "0"
_idle_record_classification "" "wrapped" "x"
assert_eq "an empty window returns 0" "$?" "0"
_idle_record_classification "w4" "" "x"
assert_eq "an empty class returns 0" "$?" "0"
assert_eq "…and none of those wrote a row" "$(rows)" "5"

# A failed APPEND must not advance the stamp — otherwise the transition is
# recorded as done while nothing reached disk, which is this issue's own
# defect (a decision with no trace) reintroduced inside its fix.
chmod a-w "$LOG"
_idle_record_classification "w5" "idle-too-long" "x"
chmod u+w "$LOG"
assert_eq "a failed append leaves NO stamp, so the next cycle retries" \
    "$( [[ -f "$(_idle_class_stamp_path w5)" ]] && echo yes || echo no )" "no"
_idle_record_classification "w5" "idle-too-long" "x"
assert_eq "…and the retry does land" "$(rows)" "6"

echo "=== #677: the render chokepoint is wired ==="

# WIRING, and it is weaker than the assertions above — said plainly rather than
# dressed up. What is checkable cheaply is that the recorder is called at the
# single render chokepoint every classification passes through, rather than in
# individual `cls=` arms where a later arm could silently escape the log.
_probe_src=$(cat "$_test_dir/_idle_probe.sh")
assert_contains "the recorder is called before the row is printed" \
    "$_probe_src" '_idle_record_classification "$name" "$cls" "$detail"'
assert_contains "the stamp is pruned on window disappearance" \
    "$_probe_src" '_idle_class_stamp_drop "$stale"'
# Exactly ONE call site. Two would mean an arm-local emit crept back in, which
# is how a classification escapes the trail without any test noticing.
_n_calls=$(grep -c '^\s*_idle_record_classification "' <<<"$_probe_src" || true)
assert_eq "exactly one call site (a chokepoint, not per-arm emits)" "$_n_calls" "1"

# ---- assertion-count floor ---------------------------------------------
# A missing assert_* helper exits rc 127 and is counted by nothing.
MIN_ASSERTIONS=27
if (( PASS + FAIL < MIN_ASSERTIONS )); then
    echo "FAIL: only $((PASS + FAIL)) assertions executed; expected >= $MIN_ASSERTIONS." >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && { echo "ALL TESTS PASSED"; exit 0; }
exit 1
