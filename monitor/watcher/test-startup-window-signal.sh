#!/usr/bin/env bash
# Regression test for the startup-window signal gap (issue #405
# post-review, finding B1).
#
# main.sh installs its cleanup trap early:
#     trap 'release_pidfile; release_lock; release_instance_lock; …' EXIT
# and the scheduler's cooperative INT/TERM handlers only much later
# (_scheduler_install_signal_handlers). Bash RESUMES execution after a
# non-exiting signal trap, so when INT/TERM were hung directly on the
# release chain, a signal landing in the startup window — after
# acquire_instance_lock, before the scheduler handlers — ran every
# release (instance flock dropped, cross-host beacon deleted, pidfile
# removed) and then CONTINUED the startup as a fully unguarded watcher:
# a second cockpit could acquire the "freed" flock and coexist. The fix
# makes the pre-scheduler INT/TERM handlers log-then-exit (130/143) so
# the EXIT trap carries the cleanup exactly once.
#
# Strategy: run the REAL main.sh in an isolated nexus tree (fast config
# shim, stub gh/mint-token) with a BEACON-GATED tmux stub: it is
# instant until the instance beacon exists (i.e. until main.sh is past
# acquire_instance_lock and inside the startup window), then its next
# invocation — snapshot_local's `tmux list-windows`, called for the
# first-run baseline BEFORE the scheduler installs its handlers —
# touches a hold marker and sleeps, pinning main.sh deterministically
# inside the window while the test lands the signal. No test seam in
# main.sh needed.
#
# Assertions per signal (TERM → 143, INT → 130):
#   - the process EXITS (pre-fix it kept running unguarded → timeout)
#   - exit code matches the trap's explicit exit (128+sig)
#   - the EXIT trap ran: beacon + lockfile + pidfile all removed
#     (a default-action kill would leave the beacon behind)
#   - the instance flock is re-acquirable (succession path open)
#   - the startup-window exit is logged exactly once (no double run)
# Plus a source-level pin that the release chain is never re-hung on
# INT/TERM.
#
# Run: bash monitor/watcher/test-startup-window-signal.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail
# Job control ON: without it bash starts async children with SIGINT set
# to SIG_IGN, and a signal ignored at shell entry cannot be trapped —
# main.sh's INT handler would silently never install and case 2 would
# test nothing. With -m each background job gets its own process group
# and default signal dispositions.
set -m

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_src_root=$(cd "$_test_dir/../.." && pwd)

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$(( FAIL + 1 )); }

WORK=$(mktemp -d -t nexus-startup-sig-XXXXXX)
MAIN_PID=""
cleanup() {
    if [[ -n "$MAIN_PID" ]] && kill -0 "$MAIN_PID" 2>/dev/null; then
        kill -9 "$MAIN_PID" 2>/dev/null
        wait "$MAIN_PID" 2>/dev/null
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

ROOT="$WORK/nexus"
mkdir -p "$ROOT/monitor/watcher" "$ROOT/config" "$ROOT/monitor/.state" "$WORK/bin"

# Mirror the watcher tree (main.sh + every helper it sources, including
# the `../` monitor-level libs) into the isolated root.
cp "$_test_dir"/*.sh "$ROOT/monitor/watcher/"
cp "$_src_root/monitor/"*.sh "$ROOT/monitor/" 2>/dev/null || true
chmod +x "$ROOT/monitor/watcher/main.sh"

# Fast config shim: nexus.root → fixture root, every other key → its
# passed default. Startup must reach the baseline init quickly.
cat > "$ROOT/config/load.sh" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "nexus.root" ]]; then
    printf '%s\n' "$ROOT"
else
    printf '%s\n' "\${2:-}"
fi
exit 0
EOF
chmod +x "$ROOT/config/load.sh"

STATE="$ROOT/monitor/.state"
BEACON="$STATE/nexus-instance.heartbeat"
INSTLOCK="$STATE/nexus-instance.lock"
LOCKFILE="$STATE/watcher.lock"
PIDFILE="$STATE/watcher.pid"
HOLD_MARKER="$WORK/hold-active"
HOLD_SECS=4

# Beacon-gated tmux stub (see header). Instant while the beacon is
# absent; once main.sh has published it (inside the startup window) the
# next call marks the hold and sleeps.
cat > "$WORK/bin/tmux" <<EOF
#!/usr/bin/env bash
if [[ -e "$BEACON" ]]; then
    touch "$HOLD_MARKER"
    sleep $HOLD_SECS
fi
exit 0
EOF
cat > "$WORK/bin/gh" <<'G'
#!/bin/bash
echo '{"data":{"search":{"nodes":[]}}}'
G
cat > "$WORK/bin/mint-token.sh" <<'M'
#!/bin/bash
printf 'fake-token\n'
M
chmod +x "$WORK/bin/tmux" "$WORK/bin/gh" "$WORK/bin/mint-token.sh"

# Poll for <path> to exist within <secs>. rc 0 iff it appeared.
wait_for_file() {
    local path="$1" secs="$2" i=0
    local ticks=$(( secs * 20 ))
    while (( i++ < ticks )); do
        [[ -e "$path" ]] && return 0
        sleep 0.05
    done
    [[ -e "$path" ]]
}

run_case() {
    local sig="$1" expected_rc="$2"
    local log="$WORK/watcher-$sig.log"
    rm -rf "$STATE"; mkdir -p "$STATE"
    rm -f "$HOLD_MARKER"

    PATH="$WORK/bin:$PATH" \
    NEXUS_ROOT="$ROOT" \
    MINT_TOKEN_BIN="$WORK/bin/mint-token.sh" \
    MINT_JWT_BIN="$WORK/bin/mint-token.sh" \
    MONITOR_TARGET=nonexistent \
      bash "$ROOT/monitor/watcher/main.sh" >/dev/null 2>"$log" &
    MAIN_PID=$!

    if ! wait_for_file "$BEACON" 30; then
        fail "$sig: beacon never appeared — main.sh did not reach acquire_instance_lock (log tail: $(tail -3 "$log" 2>/dev/null | tr '\n' ' '))"
        kill -9 "$MAIN_PID" 2>/dev/null; wait "$MAIN_PID" 2>/dev/null; MAIN_PID=""
        return
    fi
    if ! wait_for_file "$HOLD_MARKER" 15; then
        fail "$sig: hold marker never appeared — snapshot_local's tmux call not reached inside the window"
        kill -9 "$MAIN_PID" 2>/dev/null; wait "$MAIN_PID" 2>/dev/null; MAIN_PID=""
        return
    fi
    pass "$sig: main.sh held inside the startup window (beacon published, baseline tmux call pinned)"

    kill -s "$sig" "$MAIN_PID" 2>/dev/null

    # Bash defers the trap until the foreground pipeline (the held tmux
    # stub, ≤ HOLD_SECS) completes, then must exit promptly. Pre-fix,
    # the process survived the trap and kept starting up — caught here
    # as a liveness timeout.
    local deadline=$(( SECONDS + HOLD_SECS + 11 ))
    while kill -0 "$MAIN_PID" 2>/dev/null && (( SECONDS < deadline )); do
        sleep 0.1
    done
    if kill -0 "$MAIN_PID" 2>/dev/null; then
        fail "$sig: watcher STILL RUNNING after the startup-window signal (unguarded-instance regression — pre-fix behavior)"
        kill -9 "$MAIN_PID" 2>/dev/null; wait "$MAIN_PID" 2>/dev/null; MAIN_PID=""
        return
    fi
    wait "$MAIN_PID" 2>/dev/null; local rc=$?
    MAIN_PID=""
    if (( rc == expected_rc )); then
        pass "$sig: exited with rc $rc (trap's explicit exit)"
    else
        fail "$sig: exit rc $rc != expected $expected_rc"
    fi

    # The EXIT trap must have carried the cleanup: a default-action kill
    # (trap never ran) would leave the beacon behind.
    [[ ! -e "$BEACON" ]]   && pass "$sig: cross-host beacon removed by the EXIT trap" \
                           || fail "$sig: beacon still present — EXIT trap did not run"
    [[ ! -e "$LOCKFILE" ]] && pass "$sig: watcher.lock released" \
                           || fail "$sig: watcher.lock still present"
    [[ ! -e "$PIDFILE" ]]  && pass "$sig: pidfile released" \
                           || fail "$sig: pidfile still present"
    if ( exec {fd}<>"$INSTLOCK"; flock -n "$fd" ); then
        pass "$sig: instance flock re-acquirable (succession path open)"
    else
        fail "$sig: instance flock still held after exit"
    fi
    local n
    n=$(grep -c "watcher exiting on SIG${sig} during startup" "$log" 2>/dev/null)
    if [[ "$n" == "1" ]]; then
        pass "$sig: startup-window exit logged exactly once"
    else
        fail "$sig: startup-window exit log line count=$n (expected 1); log tail: $(tail -3 "$log" 2>/dev/null | tr '\n' ' ')"
    fi
}

echo '=== case 1: SIGTERM in the startup window → exit 143 + cleanup ==='
run_case TERM 143

echo '=== case 2: SIGINT in the startup window → exit 130 + cleanup ==='
run_case INT 130

echo '=== case 3: source pin — release chain never re-hung on INT/TERM ==='
if grep -qE "trap 'release_pidfile[^']*' EXIT (INT|TERM)" "$_test_dir/main.sh"; then
    fail "main.sh hangs the release chain directly on INT/TERM again (B1 regression)"
else
    pass "release chain bound to EXIT only; INT/TERM handlers exit"
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
