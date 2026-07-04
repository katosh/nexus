#!/usr/bin/env bash
# Bootstrap-race serialization tests (issue #43).
#
# Two cases:
#
#   1. Concurrent bootstrap.sh invocations against a stale heartbeat
#      fire the launcher exactly once. Today's bootstrap.sh had no
#      lock, so N racing agents all saw "watcher dead" before any
#      wrote a fresh heartbeat and each spawned a watcher.
#   2. The bootstrap.sh flock releases cleanly on script exit;
#      sequential invocations do not deadlock and re-acquire the
#      lock on the second call.
#
# Launcher-side orphan detection (formerly cases 2/4 here, regression
# tests for #57's pgrep-based guard) now lives in
# `test-launcher-pidfile.sh`. The PID-file mechanism that replaced the
# pgrep check (issue #96) is immune to the argv false-positive class
# entirely, so the foreign-shell-argv regression test moved with it.
#
# Hermetic: NEXUS_ROOT pins everything (state, reports) to a tmpdir,
# BOOTSTRAP_LAUNCHER_BIN stubs the launcher so we never spawn a real
# watcher, and MONITOR_INTERVAL bypasses the config loader.
#
# Run: bash monitor/watcher/test-bootstrap-race.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BOOTSTRAP="$_test_dir/bootstrap.sh"
LAUNCHER="$_test_dir/launcher.sh"

# Bypass config/load.sh — bootstrap.sh and launcher.sh consult it only
# for INTERVAL / TARGET, both of which we pin explicitly.
export MONITOR_INTERVAL=60
export MONITOR_TARGET=orchestrator

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$(( FAIL + 1 )); }
pass() { echo "ok:   $*"; PASS=$(( PASS + 1 )); }

# --- per-case fixture builders ------------------------------------------
#
# Functions write their outputs into globals (rather than via `$()`
# capture) because `$()` runs in a subshell and would lose any `export`
# performed inside.

# Pin NEXUS_ROOT (state + reports) to a tmpdir and seed a stale
# heartbeat for a non-existent pid so _watcher_alive returns DEAD
# without needing tmux at all (the pid check fires before the
# tmux-window check in _lib.sh).
build_state_dir() {
    local work="$1"
    export NEXUS_ROOT="$work"
    export NEXUS_STATE_DIR="$work/monitor/.state"
    mkdir -p "$NEXUS_STATE_DIR" "$work/reports"
    local hb="$NEXUS_STATE_DIR/watcher-heartbeat"
    cat > "$hb" <<EOF
pid=999999
ts=$(date -Is)
target=orchestrator
EOF
    # Backdate well past any sensible 2*interval cutoff so bucket=DEAD.
    touch -d '-10 minutes' "$hb"
}

# Materialize a fake launcher that appends one line per invocation to
# a per-case counter file. `delay` widens the lock-holder window so
# losing racers reliably hit the contention path. Sets globals
# BOOTSTRAP_LAUNCHER_BIN and LAUNCHER_COUNTER.
build_stub_launcher() {
    local work="$1" delay="$2"
    local stub="$work/stub-launcher.sh"
    LAUNCHER_COUNTER="$work/launcher-count.log"
    : > "$LAUNCHER_COUNTER"
    # `flock 200` serializes the append so concurrent racers can't
    # interleave writes. $counter is baked at write-time; $$ is escaped
    # so the stub records the caller's pid at run-time.
    cat > "$stub" <<EOF
#!/usr/bin/env bash
sleep $delay
(
    flock 200
    echo "call \$\$" >> "$LAUNCHER_COUNTER"
) 200>>"$LAUNCHER_COUNTER"
EOF
    chmod +x "$stub"
    export BOOTSTRAP_LAUNCHER_BIN="$stub"
}

cleanup_case() {
    local work="$1"
    unset NEXUS_ROOT NEXUS_STATE_DIR BOOTSTRAP_LAUNCHER_BIN
    rm -rf "$work"
}

# --- Case 1: race → exactly one launcher invocation ---------------------
echo '=== case 1: 3 concurrent bootstraps fire launcher exactly once ==='

WORK1=$(mktemp -d -t nexus-bootstrap-race-1-XXXXXX)
build_state_dir "$WORK1"
build_stub_launcher "$WORK1" 0.5
COUNTER1="$LAUNCHER_COUNTER"

(bash "$BOOTSTRAP" >/dev/null 2>"$WORK1/r1.err") &
(bash "$BOOTSTRAP" >/dev/null 2>"$WORK1/r2.err") &
(bash "$BOOTSTRAP" >/dev/null 2>"$WORK1/r3.err") &
wait

count=$(wc -l < "$COUNTER1")
if (( count == 1 )); then
    pass "launcher invoked exactly once across 3 racers (got $count)"
else
    fail "launcher invoked $count times across 3 racers (expected 1)"
    echo "  --- r1.err ---" >&2; cat "$WORK1/r1.err" >&2 || true
    echo "  --- r2.err ---" >&2; cat "$WORK1/r2.err" >&2 || true
    echo "  --- r3.err ---" >&2; cat "$WORK1/r3.err" >&2 || true
fi

# Two of the three should have logged the skip message — verify the
# losers took the lock-contention exit path, not some other error.
skipped=$(cat "$WORK1"/r*.err | grep -c "another agent is bootstrapping" || true)
if (( skipped == 2 )); then
    pass "two losers logged the lock-contention skip"
else
    fail "expected 2 lock-skip log lines; got $skipped"
fi

cleanup_case "$WORK1"

# --- Case 2: lock release on exit — sequential runs both fire ----------
echo '=== case 2: bootstrap.sh releases the lock on exit ==='

WORK2=$(mktemp -d -t nexus-bootstrap-race-2-XXXXXX)
build_state_dir "$WORK2"
build_stub_launcher "$WORK2" 0
COUNTER2="$LAUNCHER_COUNTER"

# Two sequential runs. If the lock weren't released between them, the
# second invocation would log the skip message and not call the
# launcher. With proper fd-close-on-exit cleanup, both fire.
bash "$BOOTSTRAP" >/dev/null 2>"$WORK2/r1.err"
rc1=$?
bash "$BOOTSTRAP" >/dev/null 2>"$WORK2/r2.err"
rc2=$?

if (( rc1 == 0 )) && (( rc2 == 0 )); then
    pass "both sequential bootstraps exited rc=0 (no deadlock)"
else
    fail "bootstrap rc: first=$rc1 second=$rc2 (expected 0/0)"
fi

count=$(wc -l < "$COUNTER2")
if (( count == 2 )); then
    pass "launcher invoked twice (lock released between runs)"
else
    fail "launcher invoked $count times across 2 sequential runs (expected 2)"
    echo "  --- r1.err ---" >&2; cat "$WORK2/r1.err" >&2 || true
    echo "  --- r2.err ---" >&2; cat "$WORK2/r2.err" >&2 || true
fi

cleanup_case "$WORK2"

# --- summary ------------------------------------------------------------

echo
echo "passed=$PASS failed=$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
else
    exit 1
fi
