#!/usr/bin/env bash
# Unit tests for the crash-loop guard helpers in _lib.sh.
#
# Covers:
#   - Below-limit respawns are allowed; history grows.
#   - Above-limit respawns are blocked; history does NOT grow when blocked.
#   - Old history entries (older than the window) drop out, releasing the guard.
#   - _respawn_loop_reset clears the file.
#
# Run directly: ./monitor/watcher/test-respawn-loop-guard.sh

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=_lib.sh
source "$_script_dir/_lib.sh"

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$(( FAIL + 1 )); }
pass() { echo "ok:   $*"; PASS=$(( PASS + 1 )); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
HIST="$WORK/respawn-history.txt"

# --- 1: under limit — allowed ---------------------------------------------

reason=$(_respawn_loop_check "$HIST" 120 3 "test")
rc=$?
if (( rc == 0 )) && [[ -z "$reason" ]] && [[ $(wc -l < "$HIST") -eq 1 ]]; then
    pass "first respawn allowed; history has 1 entry"
else
    fail "first respawn: rc=$rc reason='$reason' lines=$(wc -l < "$HIST" 2>/dev/null)"
fi

reason=$(_respawn_loop_check "$HIST" 120 3 "test")
rc=$?
if (( rc == 0 )) && [[ $(wc -l < "$HIST") -eq 2 ]]; then
    pass "second respawn allowed; history has 2 entries"
else
    fail "second respawn: rc=$rc lines=$(wc -l < "$HIST")"
fi

# --- 2: at limit — third blocked ------------------------------------------
# Per `_respawn_loop_check` semantics: count >= limit ⇒ block. With 2
# entries in the window already, the third call sees count=2 (both
# in-window), which is < limit=3 → still allowed. The FOURTH call
# sees count=3 → blocked. Test that path explicitly.

reason=$(_respawn_loop_check "$HIST" 120 3 "test")
rc=$?
if (( rc == 0 )) && [[ $(wc -l < "$HIST") -eq 3 ]]; then
    pass "third respawn allowed (count was 2 < limit=3); history has 3 entries"
else
    fail "third respawn: rc=$rc lines=$(wc -l < "$HIST")"
fi

reason=$(_respawn_loop_check "$HIST" 120 3 "test")
rc=$?
if (( rc == 1 )) && [[ "$reason" == *"3 respawns"* ]] && [[ $(wc -l < "$HIST") -eq 3 ]]; then
    pass "fourth respawn blocked; reason mentions count; history did NOT grow"
else
    fail "fourth respawn: rc=$rc reason='$reason' lines=$(wc -l < "$HIST")"
fi

# --- 3: aging out — entries older than window release the guard -----------
# Forge a history with 3 timestamps, all older than the window. Next
# call should be allowed because count of in-window entries is 0.

now=$(date +%s)
old=$(( now - 200 ))
{ echo "$old test"; echo "$old test"; echo "$old test"; } > "$HIST"

reason=$(_respawn_loop_check "$HIST" 120 3 "test")
rc=$?
if (( rc == 0 )) && [[ $(wc -l < "$HIST") -eq 4 ]]; then
    pass "old entries fall out of window; respawn allowed"
else
    fail "post-age-out: rc=$rc reason='$reason' lines=$(wc -l < "$HIST")"
fi

# --- 4: reset clears the history ------------------------------------------

_respawn_loop_reset "$HIST"
if [[ -f "$HIST" ]] && [[ $(wc -c < "$HIST") -eq 0 ]]; then
    pass "_respawn_loop_reset truncates the history file"
else
    fail "reset: file size=$(wc -c < "$HIST" 2>/dev/null)"
fi

# Reset on a missing file is a no-op (safe to call before the first
# respawn).
rm -f "$HIST"
_respawn_loop_reset "$HIST"
if [[ ! -f "$HIST" ]]; then
    pass "_respawn_loop_reset on missing file is a no-op"
else
    fail "reset on missing file created the file"
fi

# --- 5: malformed history line is ignored, not crash ----------------------

cat > "$HIST" <<'EOF'
not-a-number test
12345abc test
EOF
reason=$(_respawn_loop_check "$HIST" 120 3 "test")
rc=$?
# With awk filter `$1 ~ /^[0-9]+$/`, both malformed lines are skipped
# (count=0). The fresh entry is appended → 3 lines now.
if (( rc == 0 )) && [[ $(wc -l < "$HIST") -eq 3 ]]; then
    pass "malformed entries ignored; valid append still happens"
else
    fail "malformed: rc=$rc lines=$(wc -l < "$HIST")"
fi

# --- 6: slow-grind consecutive-failure counter (issue #77) ----------------
# The asymmetric counterpart. Test the helpers' state shape, then
# simulate the regression-4 1-per-60 s slow-grind scenario and assert
# the burst-limit guard does NOT trip while the new counter does.

COUNTER="$WORK/respawn-consecutive-failures.txt"

# 6a — missing file reads as count=0
count=$(_respawn_consec_get_count "$COUNTER")
if [[ "$count" -eq 0 ]]; then
    pass "consec-counter missing file → count=0"
else
    fail "consec-counter missing: count=$count"
fi

# 6b — _respawn_consec_check below the limit returns rc=1 (not tripped)
reason=$(_respawn_consec_check "$COUNTER" 5)
rc=$?
if (( rc == 1 )) && [[ -z "$reason" ]]; then
    pass "consec-check below limit returns rc=1, empty reason"
else
    fail "consec-check below limit: rc=$rc reason='$reason'"
fi

# 6c — record_failure increments and persists shape
_respawn_consec_record_failure "$COUNTER"
_respawn_consec_record_failure "$COUNTER"
count=$(_respawn_consec_get_count "$COUNTER")
if [[ "$count" -eq 2 ]] \
   && grep -q '^count=2$' "$COUNTER" \
   && grep -q '^last_failure_ts=[0-9]\+$' "$COUNTER"; then
    pass "consec-counter records two failures; file shape preserved"
else
    fail "consec-counter record: count=$count file:$(tr '\n' ' ' < "$COUNTER")"
fi

# 6d — reset clears the file
_respawn_consec_reset "$COUNTER"
count=$(_respawn_consec_get_count "$COUNTER")
if [[ ! -f "$COUNTER" ]] && [[ "$count" -eq 0 ]]; then
    pass "consec-reset removes file; count reads as 0"
else
    fail "consec-reset: file=$([[ -f "$COUNTER" ]] && echo present || echo absent) count=$count"
fi

# 6e — reset on a missing file is a no-op
_respawn_consec_reset "$COUNTER"
if [[ ! -f "$COUNTER" ]]; then
    pass "consec-reset on missing file is a no-op"
else
    fail "consec-reset on missing file created the file"
fi

# 6f — malformed count line reads as 0, no crash
printf 'count=garbage\nlast_failure_ts=abc\n' > "$COUNTER"
count=$(_respawn_consec_get_count "$COUNTER")
if [[ "$count" -eq 0 ]]; then
    pass "consec-counter malformed file → count=0"
else
    fail "consec-counter malformed: count=$count"
fi
rm -f "$COUNTER"

# 6g — at-limit returns rc=0 (tripped) and a human-readable reason
for _ in 1 2 3 4 5; do
    _respawn_consec_record_failure "$COUNTER"
done
reason=$(_respawn_consec_check "$COUNTER" 5)
rc=$?
if (( rc == 0 )) \
   && [[ "$reason" == *"5 consecutive failed respawns"* ]] \
   && [[ "$reason" == *"limit=5"* ]]; then
    pass "consec-check at limit returns rc=0 and a descriptive reason"
else
    fail "consec-check at limit: rc=$rc reason='$reason'"
fi
rm -f "$COUNTER"

# 6h — regression #72 scenario: ~1-per-minute slow grind for 25 minutes.
# Burst-limit guard (3 in 120 s window) must NOT trip; slow-grind
# counter (limit=5) must trip on the 5th consecutive failure.
#
# Cadence note: issue #72 regression 4 reported failures "spaced
# > 60 s apart". The burst window default is 120 s with limit=3, so
# the worst-case cadence the burst guard *barely* covers is ~60 s
# (entries at -120, -60, 0 ⇒ count=3 ⇒ blocked). A cadence slightly
# above that — modelled here as 65 s — evades the burst guard
# indefinitely (entries at -130, -65, 0 ⇒ count=2 ⇒ allowed). This
# is the exact slide-under-cadence the slow-grind axis exists to
# catch.
#
# Strategy: forge `respawn-history.txt` with timestamps the burst
# guard sees (every entry is allowed because no 3 fall inside any
# 120 s window). For each forged entry that corresponds to a FAILED
# respawn, also call `_respawn_consec_record_failure`. After 25 such
# failures (~27 min @ 65 s cadence), assert the burst guard would
# still allow another respawn while the slow-grind guard is tripped.

rm -f "$HIST" "$COUNTER"
sim_now=$(date +%s)
cadence=65
> "$HIST"
for i in $(seq 0 24); do
    ts=$(( sim_now - (24 - i) * cadence ))
    echo "$ts slow-grind-sim" >> "$HIST"
    _respawn_consec_record_failure "$COUNTER"
done

# Count entries inside the burst window (last 120 s). With a 65 s
# cadence the most recent two entries fall inside (-65, 0); the
# third (-130) lies outside. So the count is 2 < limit=3 → allowed.
cutoff=$(( sim_now - 120 ))
in_window=$(awk -v c="$cutoff" '$1 >= c {n++} END {print n+0}' "$HIST")
if (( in_window == 2 )); then
    pass "slow-grind: burst window contains exactly 2 entries (under limit=3)"
else
    fail "slow-grind: burst-window count=$in_window (expected 2)"
fi

# Burst-limit guard must allow another respawn (count=2 < limit=3).
reason=$(_respawn_loop_check "$HIST" 120 3 "slow-grind-probe")
rc=$?
if (( rc == 0 )) && [[ -z "$reason" ]]; then
    pass "slow-grind: burst-limit guard ALLOWS respawn (slides under cadence)"
else
    fail "slow-grind: burst-limit guard blocked unexpectedly rc=$rc reason='$reason'"
fi

# Slow-grind counter must be tripped (25 >> 5).
count=$(_respawn_consec_get_count "$COUNTER")
reason=$(_respawn_consec_check "$COUNTER" 5)
rc=$?
if (( rc == 0 )) \
   && [[ "$count" -ge 5 ]] \
   && [[ "$reason" == *"consecutive failed respawns"* ]]; then
    pass "slow-grind: consec-counter TRIPS at count=$count (limit=5)"
else
    fail "slow-grind: consec-counter did not trip rc=$rc count=$count reason='$reason'"
fi

# A successful new-window in the middle of the grind would reset
# the counter. Verify: reset, then check the guard re-arms (rc=1).
_respawn_consec_reset "$COUNTER"
reason=$(_respawn_consec_check "$COUNTER" 5)
rc=$?
if (( rc == 1 )) && [[ -z "$reason" ]]; then
    pass "slow-grind: a successful respawn (reset) re-arms the guard"
else
    fail "slow-grind: reset didn't re-arm rc=$rc reason='$reason'"
fi

# --- summary --------------------------------------------------------------

echo
echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
