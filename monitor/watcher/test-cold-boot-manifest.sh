#!/usr/bin/env bash
# Cold-boot dropped-worker manifest — the ON-WAKE delivery surface
# (your-org/nexus-code#651).
#
# A cold boot (`./watcher` without `--continue`) resurrects no worker
# agents and leaves a manifest of what it dropped. The PRIMARY delivery is
# the situation report pasted into the freshly spawned orchestrator
# (covered in test-spawn-fresh-orchestrator.sh). This suite covers the
# BACKSTOP: `monitor/watcher/bootstrap.sh`, which agent-prompt.md makes
# the first action of every orchestrator wake, prints the manifest on
# stdout — the channel that already carries missed diffs into context.
#
# The backstop is what covers every way an orchestrator can arrive at
# turn 1 that ISN'T a recovery spawn: the watcher's own absent-target
# respawn (a different prompt renderer), an operator-started session, or a
# recovery spawn whose paste failed. Without it the manifest is written
# and never read in exactly those cases.
#
# Cases:
#   1. Pending manifest → printed on STDOUT (not stderr: stdout is the
#      context feed) and marked delivered.
#   2. Already delivered → not reprinted (a settled question stays shut).
#   3. A NEW cold boot's manifest → pending again, no marker bookkeeping.
#   4. No manifest → stdout carries nothing extra (the common case is
#      silent; every wake goes through here).
#
# Hermetic: NEXUS_ROOT/NEXUS_STATE_DIR pin everything to a tmpdir and the
# launcher is stubbed, so no real watcher is ever spawned.
#
# Run: bash monitor/watcher/test-cold-boot-manifest.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BOOTSTRAP="$_test_dir/bootstrap.sh"
HELPERS="$_test_dir/../_dropped_manifest.sh"

export MONITOR_INTERVAL=60
export MONITOR_TARGET=orchestrator

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$(( FAIL + 1 )); }
pass() { echo "ok:   $*"; PASS=$(( PASS + 1 )); }

# Guard the guard first. Every assertion below is meaningless if the
# helper file cannot be sourced: bootstrap.sh would call an undefined
# function, that is rc 127, and rc 127 reads as "nothing pending" —
# indistinguishable from a correct no-op, and counted by nothing.
if [[ -r "$HELPERS" ]] \
   && bash -c 'source "$1" && declare -F _dropped_manifest_deliver >/dev/null' _ "$HELPERS"; then
    pass "monitor/_dropped_manifest.sh exists and defines _dropped_manifest_deliver"
else
    echo "FATAL: $HELPERS missing or does not define the delivery helper" >&2
    exit 1
fi

WORK=$(mktemp -d -t nexus-coldboot-manifest-XXXXXX)
FAUX_PID=""
cleanup() {
    if [[ -n "$FAUX_PID" ]] && kill -0 "$FAUX_PID" 2>/dev/null; then
        # Identity-checked: after a PID-space wrap a blind kill would
        # signal whatever innocent process recycled the number.
        if grep -qa "$WORK" "/proc/$FAUX_PID/cmdline" 2>/dev/null; then
            kill "$FAUX_PID" 2>/dev/null
        fi
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

export NEXUS_ROOT="$WORK"
export NEXUS_STATE_DIR="$WORK/monitor/.state"
mkdir -p "$NEXUS_STATE_DIR/diffs" "$WORK/reports" "$WORK/faux/monitor/watcher"

# A heartbeat whose pid is alive AND argv-identifies as a watcher, so
# `_watcher_alive` reports healthy and bootstrap.sh's respawn branch (and
# with it the real bootstrap-recover call) never fires. Same faux-process
# trick test-bootstrap-recover.sh uses.
printf '#!/usr/bin/env bash\nsleep 120\n' > "$WORK/faux/monitor/watcher/main.sh"
chmod +x "$WORK/faux/monitor/watcher/main.sh"
bash "$WORK/faux/monitor/watcher/main.sh" &
FAUX_PID=$!
sleep 0.2
printf 'pid=%d\nts=%s\ntarget=orchestrator\n' "$FAUX_PID" "$(date -Is)" \
    > "$NEXUS_STATE_DIR/watcher-heartbeat"

# Belt and braces: if liveness ever reads dead here, the launcher is a
# no-op stub rather than a real watcher spawn.
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/stub-launcher.sh"
chmod +x "$WORK/stub-launcher.sh"
export BOOTSTRAP_LAUNCHER_BIN="$WORK/stub-launcher.sh"

MANIFEST="$NEXUS_STATE_DIR/cold-boot-dropped-workers.md"
MARKER="$NEXUS_STATE_DIR/cold-boot-dropped-workers.delivered"

run_bootstrap() {
    BOOT_OUT=$(bash "$BOOTSTRAP" 2>"$WORK/stderr.txt")
    BOOT_RC=$?
    BOOT_ERR=$(<"$WORK/stderr.txt")
}

# --- case 1: pending manifest is delivered on stdout ------------------------
echo '=== case 1: pending manifest → printed on stdout, marked delivered ==='
cat > "$MANIFEST" <<'EOF'
# Cold boot dropped 1 worker agent(s)

### `operator/638-thing`
- session-id: `feedface-0000-1111-2222-333344445555`
- re-spawn with: `monitor/spawn-worker.sh --resume operator/638-thing`
EOF
run_bootstrap
if (( BOOT_RC == 0 )) \
   && [[ "$BOOT_OUT" == *"Cold boot dropped 1 worker agent(s)"* ]] \
   && [[ "$BOOT_OUT" == *"feedface-0000-1111-2222-333344445555"* ]] \
   && [[ "$BOOT_OUT" == *"--resume operator/638-thing"* ]]; then
    pass "manifest delivered on STDOUT (the on-wake context feed), verbatim and actionable"
else
    fail "rc=$BOOT_RC stdout='$BOOT_OUT' stderr='$BOOT_ERR'"
fi
if [[ "$BOOT_ERR" != *"feedface-0000"* ]]; then
    pass "manifest body did NOT go to stderr (stderr is the status channel; context belongs on stdout)"
else
    fail "manifest leaked onto stderr: $BOOT_ERR"
fi
if [[ -f "$MARKER" ]] && [[ -s "$MANIFEST" ]]; then
    pass "delivery marker written; manifest itself survives as the audit record"
else
    fail "marker=$([[ -f "$MARKER" ]] && echo yes || echo no) manifest=$([[ -s "$MANIFEST" ]] && echo kept || echo GONE)"
fi

# --- case 2: already delivered → not reprinted ------------------------------
echo '=== case 2: already-delivered manifest → not reprinted ==='
run_bootstrap
if (( BOOT_RC == 0 )) && [[ "$BOOT_OUT" != *"Cold boot dropped"* ]]; then
    pass "second wake does not re-deliver (the orchestrator is not re-asked a settled question every turn)"
else
    fail "re-delivered: '$BOOT_OUT'"
fi

# --- case 3: a NEW cold boot re-arms delivery -------------------------------
echo '=== case 3: a new cold boot rewrites the manifest → pending again ==='
sleep 1     # mtime granularity: the rewrite must be strictly newer
cat > "$MANIFEST" <<'EOF'
# Cold boot dropped 2 worker agent(s)

### `operator/700-second-boot`
EOF
run_bootstrap
if [[ "$BOOT_OUT" == *"Cold boot dropped 2 worker agent(s)"* ]] \
   && [[ "$BOOT_OUT" == *"operator/700-second-boot"* ]]; then
    pass "a later cold boot's manifest is delivered again (newer-than-marker; nothing to remember to reset)"
else
    fail "second cold boot not delivered: '$BOOT_OUT'"
fi

# --- case 4: no manifest → silent -------------------------------------------
echo '=== case 4: no manifest → nothing extra on stdout ==='
rm -f "$MANIFEST" "$MARKER"
run_bootstrap
if (( BOOT_RC == 0 )) && [[ "$BOOT_OUT" != *"Cold boot dropped"* ]]; then
    pass "no manifest → the on-wake path is unchanged and silent"
else
    fail "rc=$BOOT_RC stdout='$BOOT_OUT'"
fi
# An EMPTY manifest file is not a drop either — `-s` guards the delivery,
# so a truncated write can never surface as a contentless scare.
: > "$MANIFEST"
run_bootstrap
if [[ "$BOOT_OUT" != *"Cold boot"* ]] && [[ ! -f "$MARKER" ]]; then
    pass "an EMPTY manifest is not delivered (a truncated write is not a report of nothing)"
else
    fail "empty manifest delivered: '$BOOT_OUT'"
fi

echo
echo "passed=$PASS failed=$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
