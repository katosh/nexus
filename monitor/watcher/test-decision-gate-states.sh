#!/usr/bin/env bash
# test-decision-gate-states.sh — the coverage boundary of the
# pending-decisions pane gate, enforced as DATA (your-org/nexus-code#790).
#
# The gate (`bk_decision_row_actionable`, monitor/_bookkeeping.sh) has a
# permissive default arm by design: an unrecognised pane state EMITS,
# because silencing a genuine block is the harm this channel must never
# do. The cost of that polarity is that a NEW pane state gets its ruling
# by accident. This file removes the accident:
#
#   1. set(manifest states) == set(`pane-state.sh --states`)
#      → a state added to pane-state.sh with no ruling turns this red.
#   2. for every manifest row, the predicate agrees with the disposition
#      → the manifest cannot drift into prose that describes code that
#        no longer behaves that way.
#   3. the header block of pane-state.sh lists the same vocabulary as its
#      own `--states` array
#      → the human-readable contract and the machine-readable one cannot
#        disagree.
#   4. `queued=1` withholds against `blocked` — the state MOST likely to
#      be assumed unconditional, and the one whose emit is the negative
#      control everywhere else in this suite.
#   5. `blocked` emits. Asserted here as well as in
#      test-pending-decisions.sh: a fix that quietened the channel by
#      quietening everything would pass a "fewer rows" check and must
#      fail this one.
#
# Run: bash monitor/watcher/test-decision-gate-states.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_monitor_dir=$(cd "$_test_dir/.." && pwd)
MANIFEST="$_test_dir/decision-gate-states.manifest"
PANE_STATE="$_monitor_dir/pane-state.sh"
BOOKKEEPING="$_monitor_dir/_bookkeeping.sh"

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
assert_rc() {
    local label="$1" got="$2" want="$3"
    assert_eq "$label" "$got" "$want"
}

for f in "$MANIFEST" "$PANE_STATE" "$BOOKKEEPING"; do
    [[ -r "$f" ]] || { echo "test-decision-gate-states: missing $f" >&2; exit 2; }
done

# shellcheck disable=SC1090
. "$BOOKKEEPING"
declare -F bk_decision_row_actionable >/dev/null 2>&1 \
    || { echo "test-decision-gate-states: bk_decision_row_actionable not defined" >&2; exit 2; }

# ---- read the two sets --------------------------------------------------
# `bash "$PANE_STATE" --states` explicitly, not the ambient shell: this
# suite's Bash-tool caller is zsh on this host, and the script is bash.
declared=$(bash "$PANE_STATE" --states 2>/dev/null | sort)
[[ -n "$declared" ]] || { echo "test-decision-gate-states: pane-state.sh --states printed nothing" >&2; exit 2; }

manifest_rows=$(grep -v '^[[:space:]]*#' "$MANIFEST" | grep -v '^[[:space:]]*$')
manifest_states=$(cut -f1 <<<"$manifest_rows" | sort)

# Sanity-check the counts against an independent floor before asserting
# on them. A silently-empty enumeration reads as "the sets agree" (both
# empty), which is the confident-zero failure this repo keeps meeting.
declared_n=$(wc -l <<<"$declared")
manifest_n=$(wc -l <<<"$manifest_states")
echo "=== Test 1: the manifest covers exactly pane-state.sh's vocabulary ==="
if (( declared_n >= 10 )); then
    printf '  PASS: vocabulary is non-degenerate (%d states, floor 10)\n' "$declared_n"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: only %d states read from pane-state.sh --states — enumeration is suspect, refusing to compare\n' "$declared_n" >&2
    FAIL=$(( FAIL + 1 ))
fi
assert_eq "manifest row count == declared state count" "$manifest_n" "$declared_n"

missing=$(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$manifest_states"))
extra=$(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$manifest_states"))
if [[ -z "$missing" ]]; then
    printf '  PASS: every pane state has a ruling in the manifest\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: pane state(s) with NO ruling in the manifest:\n%s\n' "$(sed 's/^/    /' <<<"$missing")" >&2
    printf '    → rule on each in %s. `emit` unless the state positively\n' "$MANIFEST" >&2
    printf '      asserts something other than an operator is driving the pane.\n' >&2
    FAIL=$(( FAIL + 1 ))
fi
if [[ -z "$extra" ]]; then
    printf '  PASS: manifest names no state pane-state.sh cannot produce\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: manifest rules on state(s) pane-state.sh does not declare:\n%s\n' "$(sed 's/^/    /' <<<"$extra")" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 2: the predicate agrees with every row ------------------------
echo "=== Test 2: bk_decision_row_actionable agrees with each manifest row ==="
checked=0
while IFS=$'\t' read -r st disp why; do
    [[ -n "$st" ]] || continue
    checked=$(( checked + 1 ))
    bk_decision_row_actionable "$st" ""; rc=$?
    case "$disp" in
        emit)     assert_rc "state '$st' → emit"     "$rc" 0 ;;
        withhold) assert_rc "state '$st' → withhold" "$rc" 1 ;;
        *)  printf '  FAIL: manifest row for %q has disposition %q (want emit|withhold)\n' "$st" "$disp" >&2
            FAIL=$(( FAIL + 1 )) ;;
    esac
    [[ -n "$why" ]] \
        || { printf '  FAIL: manifest row for %q carries no rationale\n' "$st" >&2; FAIL=$(( FAIL + 1 )); }
done <<<"$manifest_rows"
assert_eq "every declared state was actually exercised" "$checked" "$declared_n"

# ---- Test 3: header contract == --states array --------------------------
#
# The header's `state=<a|b|c…>` block is what a human reads (and what
# CLAUDE.md quotes). Parse it and require set-equality with the array, so
# the documentation cannot rot away from the data.
echo "=== Test 3: pane-state.sh header block lists the same vocabulary ==="
header_states=$(
    awk '
        /^#   state=</ { grab = 1 }
        grab { line = line $0; if (/>/ && !/^#   state=<[^>]*$/) { print line; exit } }
        grab && /> \\$/ { print line; exit }
    ' "$PANE_STATE" \
    | sed -e 's/^#[[:space:]]*state=<//' -e 's/>.*$//' -e 's/#//g' -e 's/[[:space:]]//g' \
    | tr '|' '\n' | grep -v '^$' | sort -u
)
header_n=$(printf '%s\n' "$header_states" | grep -c . || true)
if (( header_n >= 10 )); then
    printf '  PASS: header block parsed to a non-degenerate list (%d)\n' "$header_n"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: header block parsed to %d states — parser or header is broken (got: %s)\n' \
        "$header_n" "$(tr '\n' ' ' <<<"$header_states")" >&2
    FAIL=$(( FAIL + 1 ))
fi
if [[ "$header_states" == "$declared" ]]; then
    printf '  PASS: header vocabulary == --states vocabulary\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: header and --states disagree.\n    header-only: %s\n    array-only:  %s\n' \
        "$(comm -23 <(printf '%s\n' "$header_states") <(printf '%s\n' "$declared") | tr '\n' ' ')" \
        "$(comm -13 <(printf '%s\n' "$header_states") <(printf '%s\n' "$declared") | tr '\n' ' ')" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 4: queued=1 is orthogonal and withholds -----------------------
echo "=== Test 4: queued=1 withholds regardless of state (nexus-code#607) ==="
bk_decision_row_actionable blocked "1"; assert_rc "blocked + queued=1 → withhold" "$?" 1
bk_decision_row_actionable idle    "1"; assert_rc "idle + queued=1 → withhold"    "$?" 1
bk_decision_row_actionable blocked "";  assert_rc "blocked without queued → EMIT"  "$?" 0
# `queued` is a token, not a state: it must not have leaked into the
# vocabulary (a manifest row for it would mean the two axes got confused).
if grep -qx 'queued' <<<"$declared"; then
    printf '  FAIL: `queued` appears in the state vocabulary — it is an orthogonal token\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: `queued` is not a state (orthogonal token, tested separately)\n'; PASS=$(( PASS + 1 ))
fi

# ---- Test 5: the guard has not silenced everything ----------------------
#
# A fix that made the channel quiet by making it mute would satisfy every
# "fewer rows" check. Pin the floor: a MAJORITY of the vocabulary must
# still emit, and the three states that mean "a human is the only way
# forward" must be among them.
echo "=== Test 5: the gate did not silence the channel ==="
emit_n=$(awk -F'\t' '$2 == "emit"' <<<"$manifest_rows" | grep -c . || true)
withhold_n=$(awk -F'\t' '$2 == "withhold"' <<<"$manifest_rows" | grep -c . || true)
assert_eq "emit + withhold accounts for every row" "$(( emit_n + withhold_n ))" "$manifest_n"
if (( emit_n > withhold_n )); then
    printf '  PASS: most states still emit (%d emit vs %d withhold)\n' "$emit_n" "$withhold_n"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %d emit vs %d withhold — the gate has become a mute switch\n' "$emit_n" "$withhold_n" >&2
    FAIL=$(( FAIL + 1 ))
fi
for st in blocked idle absent; do
    bk_decision_row_actionable "$st" ""
    assert_rc "load-bearing 'needs a human' state '$st' still emits" "$?" 0
done

# ---- Test 6: an unheard-of state emits (the default arm) ----------------
echo "=== Test 6: default arm EMITS for a state nobody has ruled on ==="
bk_decision_row_actionable "some-future-state-nobody-declared" ""
assert_rc "unknown-to-the-gate state emits rather than vanishing" "$?" 0
bk_decision_row_actionable "" ""
assert_rc "empty state token emits rather than vanishing" "$?" 0

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
