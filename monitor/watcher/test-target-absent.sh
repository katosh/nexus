#!/usr/bin/env bash
# Unit tests for monitor/watcher/_target_absent.sh — the hoisted
# absent-detection decision tree (issue #174).
#
# Pre-#174 the body lived inline in the watcher's main loop. Hoisting
# it lets the `target_window` scheduler probe call it at 2 s cadence
# instead of waiting for whatever data-gather body was bundled with
# the absence check.
#
# Scenarios:
#   (1) below threshold: increment counter, no launch
#   (2) above threshold: launch async respawn, reset counter
#   (3) double-call while in flight: launch refused
#   (4) crash-loop guard fires: no launch, RESPAWN_TRIPPED stamp
#   (5) slow-grind cooldown active: no launch, log only
#   (6) prior async respawn returned non-zero: slow-grind tripped on
#       threshold crossing
#   (7) production default (delay=3): a single transient absent poll
#       NEVER launches; only the 4th consecutive one does
#       (incident 2026-06-02)
#   (8) re-verify gate aborts the launch when it finds evidence of a
#       live orchestrator; streak + anchor reset, action-log event
#   (9) re-verify abort is not sticky: a subsequent confirmed-absent
#       streak launches once the verify passes again
#
# Run: bash monitor/watcher/test-target-absent.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

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
        fail "$label" "got=$got want=$want"
    fi
}

# --- harness setup ------------------------------------------------------

WORK=$(mktemp -d -t target-absent-test-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

STATE_DIR="$WORK/state"
mkdir -p "$STATE_DIR"

# Globals the helper reads. Mirrored from main.sh's top-level defaults
# so the helper sees the same shape it would in production.
TARGET="orchestrator"
AGENT_MISSING_RESPAWN_DELAY=0
RESPAWN_SLOW_GRIND_TRIPPED="$STATE_DIR/respawn-slow-grind-tripped"
RESPAWN_SLOW_GRIND_COOLDOWN=300
RESPAWN_CONSEC_COUNTER="$STATE_DIR/respawn-consecutive-failures.txt"
RESPAWN_CONSEC_LIMIT=5
RESPAWN_HISTORY="$STATE_DIR/respawn-history.txt"
RESPAWN_LOOP_WINDOW=600
RESPAWN_LOOP_LIMIT=10
RESPAWN_TRIPPED="$STATE_DIR/respawn-tripped"
_monitor_dir="$WORK/monitor"
mkdir -p "$_monitor_dir"

missing_target_polls=0
missing_target_since=0

# Log to a file we can grep — the helper calls `log` for transitions.
LOG_FILE="$WORK/log"
: > "$LOG_FILE"
log() { printf '%s\n' "$*" >> "$LOG_FILE"; }

# Stub `_respawn_async_launch`: records the call (so tests can assert),
# AND writes the pid file + rc file the way the real subshell would —
# minus the real respawn_agent work. Tests control the simulated rc
# via $STUB_LAUNCH_RC. The real `_respawn_async_in_flight` /
# `_respawn_async_reap` are used (from _respawn_async.sh) so we
# exercise the actual sidecar `.rc` machinery.
# shellcheck source=_respawn_async.sh
source "$_test_dir/_respawn_async.sh"

LAUNCH_CALLS=0
STUB_LAUNCH_RC=0
STUB_LAUNCH_SLEEP=0
_respawn_async_launch() {
    LAUNCH_CALLS=$(( LAUNCH_CALLS + 1 ))
    if _respawn_async_in_flight; then
        return 1
    fi
    local dir
    dir=$(_respawn_async_state_dir)
    mkdir -p "$dir" 2>/dev/null
    rm -f "$dir/rc" "$dir/pid" 2>/dev/null
    (
        sleep "$STUB_LAUNCH_SLEEP"
        printf '%s\n' "$STUB_LAUNCH_RC" > "$dir/rc"
    ) &
    printf '%s\n' "$!" > "$dir/pid"
    return 0
}

# Stub the consec / loop / sandbox-notify dependencies. The real ones
# live in `_respawn.sh` / shell builtins; we want the helper under
# test, not the entire support stack.
_respawn_consec_check() {
    # Args: <counter-file> <limit>. Returns 0 + reason on stdout if
    # threshold crossed. Reads the counter from disk.
    local counter_file="$1" limit="$2"
    [[ -f "$counter_file" ]] || return 1
    local val
    val=$(cat "$counter_file" 2>/dev/null || echo 0)
    [[ "$val" =~ ^[0-9]+$ ]] || val=0
    if (( val >= limit )); then
        printf 'consec=%s >= limit=%s\n' "$val" "$limit"
        return 0
    fi
    return 1
}
_respawn_consec_reset() {
    : > "$1"
}
_respawn_consec_record_failure() {
    local f="$1"
    local v
    v=$(cat "$f" 2>/dev/null || echo 0)
    [[ "$v" =~ ^[0-9]+$ ]] || v=0
    printf '%s\n' $(( v + 1 )) > "$f"
}
_respawn_loop_check() {
    # Args: <history> <window> <limit> <tag>. Returns 0 + empty
    # stdout if allowed, rc=1 + reason on stdout if tripped.
    # Tests toggle via $STUB_LOOP_TRIPPED.
    if [[ "${STUB_LOOP_TRIPPED:-0}" == "1" ]]; then
        printf 'crash-loop suspected: 11 in 60s\n'
        return 1
    fi
    return 0
}
# Stub the pre-launch re-verification (the real implementation lives
# in _respawn.sh and is unit-tested by test-respawn.sh). Tests toggle
# the verdict via $STUB_VERIFY_RC / $STUB_VERIFY_REASON; default is
# "proceed" so the pre-existing scenarios keep their semantics.
# Call-count bookkeeping goes through a marker file because the
# caller invokes the verify inside a command substitution (subshell)
# — a plain counter variable would never propagate back.
STUB_VERIFY_RC=0
STUB_VERIFY_REASON="verified-absent"
VERIFY_CALLS_FILE="$WORK/verify-calls"
verify_call_count() { wc -l < "$VERIFY_CALLS_FILE" 2>/dev/null | tr -d ' ' || echo 0; }
_respawn_verify_target_absent() {
    echo "called target=$1 streak_start=${2:-}" >> "$VERIFY_CALLS_FILE"
    printf '%s' "$STUB_VERIFY_REASON"
    return "$STUB_VERIFY_RC"
}
sandbox-notify() { return 0; }

# Source the helper under test AFTER the stubs above so its
# function calls resolve to our stubs.
# shellcheck source=_target_absent.sh
source "$_test_dir/_target_absent.sh"

# Helper: reset all per-scenario state.
reset_state() {
    missing_target_polls=0
    missing_target_since=0
    LAUNCH_CALLS=0
    : > "$VERIFY_CALLS_FILE"
    rm -f "$STATE_DIR"/* 2>/dev/null
    rm -rf "$STATE_DIR/respawn-bg" 2>/dev/null
    : > "$LOG_FILE"
    STUB_LOOP_TRIPPED=0
    STUB_LAUNCH_RC=0
    STUB_LAUNCH_SLEEP=0
    STUB_VERIFY_RC=0
    STUB_VERIFY_REASON="verified-absent"
}

# ---- (1) below threshold: increment, no launch -------------------------

echo '=== (1) AGENT_MISSING_RESPAWN_DELAY=2 ⇒ first two observations don'\''t launch ==='
reset_state
AGENT_MISSING_RESPAWN_DELAY=2

_watcher_handle_target_absent_observation
assert_eq "first obs increments counter to 1" "$missing_target_polls" "1"
assert_eq "first obs does NOT launch" "$LAUNCH_CALLS" "0"

_watcher_handle_target_absent_observation
assert_eq "second obs increments counter to 2" "$missing_target_polls" "2"
assert_eq "second obs does NOT launch (counter == delay)" "$LAUNCH_CALLS" "0"

_watcher_handle_target_absent_observation
# Now counter=3, > delay=2 → should launch and reset.
assert_eq "third obs launches respawn" "$LAUNCH_CALLS" "1"
assert_eq "third obs resets counter (tentative)" "$missing_target_polls" "0"

# Reap so subsequent scenarios start clean.
wait 2>/dev/null || true
sleep 0.2
_respawn_async_reap >/dev/null || true

# ---- (2) above threshold (delay=0): first obs launches ----------------

echo
echo '=== (2) AGENT_MISSING_RESPAWN_DELAY=0 ⇒ first obs launches ==='
reset_state
AGENT_MISSING_RESPAWN_DELAY=0

_watcher_handle_target_absent_observation
assert_eq "counter post-launch (tentative reset)" "$missing_target_polls" "0"
assert_eq "launched once" "$LAUNCH_CALLS" "1"

# ---- (3) double-call while in flight: launch refused -----------------

echo
echo '=== (3) re-call while subshell in flight ⇒ launch deferred ==='
# Don't reset state — the launch from (2) is still in flight (sleep 0
# above means it likely completed; bump the sleep here).
reset_state
STUB_LAUNCH_SLEEP=2

_watcher_handle_target_absent_observation
sleep 0.1   # let the subshell get going
if _respawn_async_in_flight; then
    pass "subshell is in flight after first launch"
else
    fail "subshell not in flight (test timing race)"
fi
assert_eq "first call launched" "$LAUNCH_CALLS" "1"

_watcher_handle_target_absent_observation
assert_eq "second call did NOT launch (in-flight guard)" "$LAUNCH_CALLS" "1"
# The "deferred" log line is the contract surface.
if grep -q "launch deferred" "$LOG_FILE"; then
    pass "log records 'launch deferred (in flight)'"
else
    fail "log missing 'launch deferred' line" "$(cat "$LOG_FILE")"
fi

# Wait for the in-flight subshell to finish + reap so subsequent
# scenarios start clean.
respawn_pid=$(cat "$STATE_DIR/respawn-bg/pid" 2>/dev/null)
[[ "$respawn_pid" =~ ^[0-9]+$ ]] && wait "$respawn_pid" 2>/dev/null || true
sleep 0.3
_respawn_async_reap >/dev/null || true

# ---- (4) crash-loop guard fires: no launch ---------------------------

echo
echo '=== (4) _respawn_loop_check tripped ⇒ no launch, RESPAWN_TRIPPED stamped ==='
reset_state
STUB_LOOP_TRIPPED=1

_watcher_handle_target_absent_observation
assert_eq "crash-loop guard prevents launch" "$LAUNCH_CALLS" "0"
if [[ -f "$RESPAWN_TRIPPED" ]]; then
    pass "RESPAWN_TRIPPED stamp written on first tripped observation"
else
    fail "RESPAWN_TRIPPED stamp missing"
fi
if grep -q "respawn blocked:" "$LOG_FILE"; then
    pass "log records 'respawn blocked: ...'"
else
    fail "log missing 'respawn blocked' line"
fi

# Second observation while still tripped: NO new RESPAWN_TRIPPED write
# (the "notify once on transition" guard).
trip_mtime_before=$(date +%s -r "$RESPAWN_TRIPPED" 2>/dev/null || echo 0)
sleep 1   # ensure mtime resolution would distinguish a re-write
_watcher_handle_target_absent_observation
trip_mtime_after=$(date +%s -r "$RESPAWN_TRIPPED" 2>/dev/null || echo 0)
assert_eq "RESPAWN_TRIPPED mtime unchanged on second tripped obs" \
    "$trip_mtime_before" "$trip_mtime_after"

# ---- (5) slow-grind cooldown active: no launch ----------------------

echo
echo '=== (5) RESPAWN_SLOW_GRIND_TRIPPED stamp fresh ⇒ launch paused ==='
reset_state
date -Is > "$RESPAWN_SLOW_GRIND_TRIPPED"   # fresh stamp = cooldown active

_watcher_handle_target_absent_observation
assert_eq "slow-grind cooldown blocks launch" "$LAUNCH_CALLS" "0"
if grep -q "slow-grind cooldown active" "$LOG_FILE"; then
    pass "log records 'slow-grind cooldown active'"
else
    fail "log missing 'slow-grind cooldown active' line"
fi

# ---- (5b) slow-grind cooldown elapsed: re-arm + launch --------------

echo
echo '=== (5b) RESPAWN_SLOW_GRIND_TRIPPED stale ⇒ re-arm, launch fires ==='
reset_state
# Stamp 10s old; cooldown=5 → elapsed.
RESPAWN_SLOW_GRIND_COOLDOWN=5
touch -t "$(date -d '10 seconds ago' +%Y%m%d%H%M.%S 2>/dev/null || date +%Y%m%d%H%M.%S)" \
    "$RESPAWN_SLOW_GRIND_TRIPPED" 2>/dev/null \
    || date -Is -d '-10 seconds' > "$RESPAWN_SLOW_GRIND_TRIPPED"
# Re-stamp by overwriting; portability: just use date -Is from past.
date -Is -d '-10 seconds' > "$RESPAWN_SLOW_GRIND_TRIPPED" 2>/dev/null \
    || date -Is > "$RESPAWN_SLOW_GRIND_TRIPPED"
# Force the mtime to be at least cooldown+5 seconds ago.
touch -d "$(date -d '-10 seconds' '+%Y-%m-%d %H:%M:%S')" "$RESPAWN_SLOW_GRIND_TRIPPED" 2>/dev/null || true

_watcher_handle_target_absent_observation
if [[ -f "$RESPAWN_SLOW_GRIND_TRIPPED" ]]; then
    fail "RESPAWN_SLOW_GRIND_TRIPPED stamp NOT cleared after re-arm"
else
    pass "RESPAWN_SLOW_GRIND_TRIPPED cleared after cooldown elapsed"
fi
assert_eq "launch fires after re-arm" "$LAUNCH_CALLS" "1"

# Reset cooldown for any subsequent scenario.
RESPAWN_SLOW_GRIND_COOLDOWN=300

# Wait for subshell.
respawn_pid=$(cat "$STATE_DIR/respawn-bg/pid" 2>/dev/null)
[[ "$respawn_pid" =~ ^[0-9]+$ ]] && wait "$respawn_pid" 2>/dev/null || true
sleep 0.2
_respawn_async_reap >/dev/null || true

# ---- (6) reap of prior non-zero subshell triggers slow-grind --------

echo
echo '=== (6) prior async rc!=0 + consec ≥ limit ⇒ slow-grind tripped ==='
reset_state
# Pre-stage a completed subshell rc file with non-zero rc, plus a
# consec counter at threshold.
mkdir -p "$STATE_DIR/respawn-bg"
printf '3\n' > "$STATE_DIR/respawn-bg/rc"
printf '99999999\n' > "$STATE_DIR/respawn-bg/pid"   # stale pid; reap tolerates
printf '%s\n' "$RESPAWN_CONSEC_LIMIT" > "$RESPAWN_CONSEC_COUNTER"

_watcher_handle_target_absent_observation
if [[ -f "$RESPAWN_SLOW_GRIND_TRIPPED" ]]; then
    pass "RESPAWN_SLOW_GRIND_TRIPPED stamped on threshold-crossing reap"
else
    fail "RESPAWN_SLOW_GRIND_TRIPPED stamp missing after non-zero reap"
fi
if grep -q "slow-grind tripped:" "$LOG_FILE"; then
    pass "log records 'slow-grind tripped: ...'"
else
    fail "log missing 'slow-grind tripped' line"
fi
# The fresh slow-grind stamp now gates the launch attempt this same
# observation → no launch fires.
assert_eq "slow-grind stamp blocks same-obs launch" "$LAUNCH_CALLS" "0"

# ---- (7) production default (delay=3): transient absent never launches

echo
echo '=== (7) AGENT_MISSING_RESPAWN_DELAY=3 (production default) ⇒ a single transient absent poll never launches ==='
reset_state
AGENT_MISSING_RESPAWN_DELAY=3

# A single transient absent observation — the incident-2026-06-02
# trigger — must not launch anything.
_watcher_handle_target_absent_observation
assert_eq "single transient absent poll does NOT launch" "$LAUNCH_CALLS" "0"
assert_eq "streak counter is 1" "$missing_target_polls" "1"
if (( missing_target_since > 0 )); then
    pass "streak-start anchor stamped on first absent observation"
else
    fail "missing_target_since not stamped on first absent observation"
fi

# Window comes back (probe resets the counter, as main.sh's
# _v2_task_target_window_probe does on rc=0).
missing_target_polls=0
missing_target_since=0

# A genuine death: 4 consecutive absent observations → exactly one launch.
_watcher_handle_target_absent_observation
_watcher_handle_target_absent_observation
_watcher_handle_target_absent_observation
assert_eq "three consecutive absent polls still do NOT launch" "$LAUNCH_CALLS" "0"
_watcher_handle_target_absent_observation
assert_eq "fourth consecutive absent poll launches the respawn" "$LAUNCH_CALLS" "1"
assert_eq "re-verify gate consulted before the launch" "$(verify_call_count)" "1"
assert_eq "counter reset after launch" "$missing_target_polls" "0"

# Reap so subsequent scenarios start clean.
respawn_pid=$(cat "$STATE_DIR/respawn-bg/pid" 2>/dev/null)
[[ "$respawn_pid" =~ ^[0-9]+$ ]] && wait "$respawn_pid" 2>/dev/null || true
sleep 0.2
_respawn_async_reap >/dev/null || true

# ---- (8) re-verify abort: no launch, streak reset, audit trail --------

echo
echo '=== (8) re-verify finds a live orchestrator ⇒ launch aborted, streak reset ==='
reset_state
AGENT_MISSING_RESPAWN_DELAY=0
STUB_VERIFY_RC=1
STUB_VERIFY_REASON="orchestrator-process-alive pane_pid=1234 window_id=@7 was_named=claude (renamed back to orchestrator)"

_watcher_handle_target_absent_observation
assert_eq "verify-abort prevents the launch" "$LAUNCH_CALLS" "0"
assert_eq "verify was consulted" "$(verify_call_count)" "1"
assert_eq "streak counter reset after verify-abort" "$missing_target_polls" "0"
assert_eq "streak-start anchor reset after verify-abort" "$missing_target_since" "0"
if grep -q "respawn aborted by re-verify: orchestrator-process-alive" "$LOG_FILE"; then
    pass "log records 'respawn aborted by re-verify: ...' with the reason"
else
    fail "log missing the re-verify abort line" "$(cat "$LOG_FILE")"
fi

# A second absent observation while the verify still says alive:
# same abort, still no launch (the gate is not sticky-open).
_watcher_handle_target_absent_observation
assert_eq "second observation under verify-abort still does NOT launch" "$LAUNCH_CALLS" "0"

# ---- (9) re-verify abort is not sticky: passes ⇒ launch ----------------

echo
echo '=== (9) verify-abort clears ⇒ next confirmed-absent streak launches ==='
# Don't reset: continue from scenario (8) where the verify aborted.
# The orchestrator now genuinely dies: the verify starts passing.
STUB_VERIFY_RC=0
STUB_VERIFY_REASON="verified-absent"

_watcher_handle_target_absent_observation
assert_eq "launch fires once the re-verify passes (delay=0)" "$LAUNCH_CALLS" "1"
if grep -q "re-verify=verified-absent" "$LOG_FILE"; then
    pass "launch log line carries the re-verify verdict"
else
    fail "launch log line missing the re-verify verdict" "$(cat "$LOG_FILE")"
fi

# Reap.
respawn_pid=$(cat "$STATE_DIR/respawn-bg/pid" 2>/dev/null)
[[ "$respawn_pid" =~ ^[0-9]+$ ]] && wait "$respawn_pid" 2>/dev/null || true
sleep 0.2
_respawn_async_reap >/dev/null || true

# ---- summary ----------------------------------------------------------

echo
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d)\n' "$PASS"
    exit 0
else
    printf 'TESTS FAILED: %d passed, %d failed\n' "$PASS" "$FAIL" >&2
    exit 1
fi
