#!/usr/bin/env bash
# Unit tests for the agent-sandbox gate and the namespace-agnostic
# liveness fix (your-org/nexus-code#350), both in monitor/watcher/_lib.sh.
#
# Part 1 — the gate (`_nexus_in_sandbox`, `_nexus_no_sandbox_accepted`,
# `_nexus_sandbox_gate`):
#   - in-sandbox            → allow, silent, marker never written
#   - out, no flag/marker   → REFUSE (loud), marker NOT written
#   - out + flag            → allow + WARN + persist marker (auditable)
#   - out + prior marker    → allow + WARN (self-heal inherits acceptance)
#   - out + env opt-out     → allow + WARN, no marker (env-only channel)
#   - in-sandbox short-circuit ignores a stray flag (no marker)
#
# Part 2 — `_watcher_alive` no longer false-reports a live cross-pid-ns
# watcher as DEAD (Connor's split-topology failure):
#   - heartbeat fresh + pid-identity FAILS + instance flock FREE  → DEAD
#       (preserves the recycled-pid stale-heartbeat protection)
#   - heartbeat fresh + pid-identity FAILS + instance flock HELD  → ALIVE
#       (a live peer watcher in another namespace owns the state dir)
#
# Run: bash monitor/watcher/test-no-sandbox-gate.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$_test_dir/_lib.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

[[ -r "$LIB" ]] || { echo "lib not readable: $LIB" >&2; exit 1; }
# shellcheck source=/dev/null
. "$LIB"

fresh_state_dir() { mktemp -d -t nexus-gate-test-XXXXXX; }

# ===========================================================================
echo "=== Part 1: sandbox gate ==="

# Each case runs the gate in a SUBSHELL so env overrides (SANDBOX_*,
# NEXUS_I_ACCEPT_NO_SANDBOX) don't leak between cases. Capture rc + stderr.

# run_gate <state_dir> <flag> -- <env assignments...>
# Returns rc in GATE_RC and stderr in GATE_ERR.
#
# HERMETIC: clear the three gate-relevant vars FIRST (`env -u …`) so the
# case's own assignments in "$@" fully determine the environment,
# regardless of what the ambient shell or run-tests.sh exported (the
# runner exports NEXUS_I_ACCEPT_NO_SANDBOX=1, and an in-sandbox developer
# shell has SANDBOX_ACTIVE=1 — both would otherwise leak into the refuse
# cases). `env` applies -u before assignments, so an explicit
# `NEXUS_I_ACCEPT_NO_SANDBOX=1` in "$@" still wins.
run_gate() {
    local sd="$1" flag="$2"; shift 2
    [[ "${1:-}" == "--" ]] && shift
    local errf; errf=$(mktemp)
    set +e
    ( env -u SANDBOX_ACTIVE -u SANDBOX_PROJECT_DIR -u NEXUS_I_ACCEPT_NO_SANDBOX \
        "$@" bash -c '
        . "$0"
        _nexus_sandbox_gate "$1" "$2" "testctx"
    ' "$LIB" "$sd" "$flag" ) 2>"$errf"
    GATE_RC=$?
    set -e
    GATE_ERR=$(<"$errf"); rm -f "$errf"
}

# --- 1: in-sandbox → allow, silent, no marker ---
SD=$(fresh_state_dir)
run_gate "$SD" 0 -- SANDBOX_ACTIVE=1 SANDBOX_PROJECT_DIR="$SD"
if (( GATE_RC == 0 )) && [[ -z "$GATE_ERR" ]] && [[ ! -f "$SD/no-sandbox-accepted" ]]; then
    ok "in-sandbox → allow, silent, no marker"
else
    bad "in-sandbox" "rc=$GATE_RC err='$GATE_ERR' marker=$([[ -f "$SD/no-sandbox-accepted" ]] && echo yes || echo no)"
fi
rm -rf "$SD"

# --- 2: out, no flag, no marker → REFUSE (loud), no marker written ---
SD=$(fresh_state_dir)
run_gate "$SD" 0 -- SANDBOX_ACTIVE= SANDBOX_PROJECT_DIR=
if (( GATE_RC == 1 )) \
   && [[ "$GATE_ERR" == *"REFUSING to start the nexus outside the agent-sandbox"* ]] \
   && [[ "$GATE_ERR" == *"--i-accept-no-sandbox"* ]] \
   && [[ ! -f "$SD/no-sandbox-accepted" ]]; then
    ok "out + no flag → refuse (rc=1), loud, no marker"
else
    bad "out no flag" "rc=$GATE_RC marker=$([[ -f "$SD/no-sandbox-accepted" ]] && echo yes || echo no) err='$GATE_ERR'"
fi
rm -rf "$SD"

# --- 3: out + flag → allow + WARN + persist marker ---
SD=$(fresh_state_dir)
run_gate "$SD" 1 -- SANDBOX_ACTIVE= SANDBOX_PROJECT_DIR=
if (( GATE_RC == 0 )) \
   && [[ "$GATE_ERR" == *"WARNING — starting OUTSIDE the agent-sandbox"* ]] \
   && [[ -f "$SD/no-sandbox-accepted" ]] \
   && grep -q '^context: testctx' "$SD/no-sandbox-accepted" \
   && grep -q '^accepted_at: ' "$SD/no-sandbox-accepted"; then
    ok "out + flag → allow (rc=0), warn, marker persisted with metadata"
else
    bad "out + flag" "rc=$GATE_RC marker=$([[ -f "$SD/no-sandbox-accepted" ]] && cat "$SD/no-sandbox-accepted" || echo none) err='$GATE_ERR'"
fi
rm -rf "$SD"

# --- 4: out + prior marker, no flag → allow + WARN (self-heal inherits) ---
SD=$(fresh_state_dir)
printf 'accepted_at: earlier\ncontext: watcher\n' > "$SD/no-sandbox-accepted"
run_gate "$SD" 0 -- SANDBOX_ACTIVE= SANDBOX_PROJECT_DIR=
if (( GATE_RC == 0 )) && [[ "$GATE_ERR" == *"WARNING — starting OUTSIDE the agent-sandbox"* ]]; then
    ok "out + prior marker (no flag) → allow (rc=0), warn (persisted acceptance honoured)"
else
    bad "out + prior marker" "rc=$GATE_RC err='$GATE_ERR'"
fi
rm -rf "$SD"

# --- 5: out + env opt-out, no flag, no marker → allow + WARN, no marker ---
# The env var is a non-file acceptance channel; it must NOT create a marker.
SD=$(fresh_state_dir)
run_gate "$SD" 0 -- SANDBOX_ACTIVE= SANDBOX_PROJECT_DIR= NEXUS_I_ACCEPT_NO_SANDBOX=1
if (( GATE_RC == 0 )) \
   && [[ "$GATE_ERR" == *"WARNING — starting OUTSIDE the agent-sandbox"* ]] \
   && [[ ! -f "$SD/no-sandbox-accepted" ]]; then
    ok "out + env NEXUS_I_ACCEPT_NO_SANDBOX=1 → allow (rc=0), warn, no marker file"
else
    bad "out + env" "rc=$GATE_RC marker=$([[ -f "$SD/no-sandbox-accepted" ]] && echo yes || echo no) err='$GATE_ERR'"
fi
rm -rf "$SD"

# --- 6: in-sandbox short-circuits even with a stray flag → no marker ---
SD=$(fresh_state_dir)
run_gate "$SD" 1 -- SANDBOX_ACTIVE=1 SANDBOX_PROJECT_DIR="$SD"
if (( GATE_RC == 0 )) && [[ -z "$GATE_ERR" ]] && [[ ! -f "$SD/no-sandbox-accepted" ]]; then
    ok "in-sandbox + flag → no-op (flag ignored, no marker, no warning)"
else
    bad "in-sandbox + flag" "rc=$GATE_RC err='$GATE_ERR' marker=$([[ -f "$SD/no-sandbox-accepted" ]] && echo yes || echo no)"
fi
rm -rf "$SD"

# ===========================================================================
echo "=== Part 2: _watcher_alive is namespace-agnostic ==="

# Build a state dir with a FRESH heartbeat whose pid fails the identity
# check (a pid that is not a live main.sh). `_watcher_pid_is_live_watcher`
# returns false either because the pid is dead OR because it lives in
# another pid namespace — the same observable signal. We use a definitely-
# dead pid so the only variable is whether the instance flock is held.
write_fresh_heartbeat() {
    local sd="$1" pid="$2"
    mkdir -p "$sd"
    printf 'pid=%s\nts=%s\ntarget=orchestrator\n' "$pid" "$(date -Is 2>/dev/null || echo now)" \
        > "$sd/watcher-heartbeat"
}

# A pid that cannot be a live watcher. Pick a high pid that is not in use;
# fall back to a guaranteed-dead one by spawning `true` and reaping it.
DEAD_PID=$( bash -c 'echo $$' )   # the subshell's pid; it has already exited

# --- 7: fresh heartbeat + identity FAIL + flock FREE → DEAD (rc=2) ---
SD=$(fresh_state_dir)
write_fresh_heartbeat "$SD" "$DEAD_PID"
# No holder on nexus-instance.lock → _nexus_watcher_lock_held is false.
set +e
_watcher_alive "$SD" 60
RC=$?
set -e
if (( RC == 2 )); then
    ok "fresh heartbeat + dead pid + flock FREE → DEAD (rc=2) — recycled-pid protection preserved"
else
    bad "flock-free dead" "expected rc=2 got rc=$RC"
fi
rm -rf "$SD"

# --- 8: fresh heartbeat + identity FAIL + flock HELD → ALIVE (rc=0) ---
# Hold an exclusive flock on nexus-instance.lock from a background process
# (simulating a live peer watcher in another pid namespace), then probe.
SD=$(fresh_state_dir)
write_fresh_heartbeat "$SD" "$DEAD_PID"
LOCKF="$SD/nexus-instance.lock"
: > "$LOCKF"
# Hold an exclusive flock on the inode for the subshell's lifetime — the
# exact condition `_nexus_instance_lock_live` (and thus
# `_nexus_watcher_lock_held`) detects. A background subshell that opens an
# fd and flocks it, then sleeps, is the simplest faithful stand-in for a
# live peer watcher holding the instance lock in another pid namespace.
READY="$SD/holder.ready"
( exec {hfd}<>"$LOCKF"; flock -x "$hfd"; echo ready > "$READY"; sleep 30 ) &
HOLDER_PID=$!
# Wait until the holder has actually acquired the lock before probing.
for _ in $(seq 1 50); do [[ -f "$READY" ]] && break; sleep 0.1; done
set +e
_watcher_alive "$SD" 60
RC=$?
set -e
# Sanity: confirm the lock really is held (guards against a flaky setup
# that would make the test pass for the wrong reason).
HELD="no"; _nexus_watcher_lock_held "$SD" && HELD="yes"
kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
if (( RC == 0 )) && [[ "$HELD" == "yes" ]]; then
    ok "fresh heartbeat + cross-ns (identity-fail) + flock HELD → ALIVE (rc=0) — #350 fix"
elif [[ "$HELD" != "yes" ]]; then
    bad "flock-held alive" "test setup failed to hold the flock (HELD=$HELD); cannot validate"
else
    bad "flock-held alive" "expected rc=0 got rc=$RC (flock was held)"
fi
rm -rf "$SD"

# --- 9: control — same-ns healthy watcher path is unchanged ---
# A heartbeat naming THIS test process (a live `bash …test-no-sandbox-gate.sh`)
# fails the main.sh-argv identity check, so we can't easily fake a positive
# identity here without a real main.sh. Instead assert the inverse property
# the fix relies on: the flock probe is ONLY consulted on the identity-fail
# branch, so a missing heartbeat still short-circuits to rc=3 regardless of
# any flock.
SD=$(fresh_state_dir)
set +e
_watcher_alive "$SD" 60
RC=$?
set -e
if (( RC == 3 )); then
    ok "no heartbeat → rc=3 (missing), gate change does not perturb the absent-heartbeat path"
else
    bad "no heartbeat" "expected rc=3 got rc=$RC"
fi
rm -rf "$SD"

# ===========================================================================
echo
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED ($PASS)"
    exit 0
else
    echo "FAILED: $FAIL (passed $PASS)" >&2
    exit 1
fi
