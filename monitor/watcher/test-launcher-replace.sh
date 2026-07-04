#!/usr/bin/env bash
# `--replace` tests for monitor/watcher/launcher.sh (issue #106).
#
# Issue #106 (2026-05-13): `tmux kill-window -t watcher` does not
# kill the watcher main.sh process — it detaches from the pane and
# survives as a PPID=1 orphan. The PID-file refuse-to-spawn guard
# from #96 catches the orphan on next launch, but offers the
# operator no in-band way to clear it. `--replace` adds that:
# SIGTERM, wait up to 5s for graceful exit (the watcher's
# EXIT/INT/TERM trap releases the pidfile + lock), escalate to
# SIGKILL otherwise, and clean the pidfile so the launcher can
# proceed.
#
# Cases pinned here:
#   A. Live PID file + launcher WITHOUT --replace → refuses, leaves
#      file (regression-check for the existing #96 behavior).
#   B. Live PID file + launcher WITH --replace → SIGTERM exits the
#      process within the grace window, pidfile cleaned, launcher
#      proceeds.
#   C. Stubborn process (traps SIGTERM and ignores it) + launcher
#      WITH --replace → after the ~5s grace window, SIGKILL fires,
#      pidfile cleaned, launcher proceeds.
#   D. Stale PID file (process already dead) + launcher WITH
#      --replace → existing stale-cleanup path; MUST NOT delay 5s
#      waiting on a dead pid.
#
# Hermetic: same tmpdir + symlink-free copy + stub tmux + stub
# config/load.sh pattern as test-launcher-pidfile.sh. We share
# nothing with the real `monitor/.state/` so the running watcher
# (if any) is untouched.
#
# Run: bash monitor/watcher/test-launcher-replace.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_real_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REAL_LAUNCHER="$_real_test_dir/launcher.sh"

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$(( FAIL + 1 )); }
pass() { echo "ok:   $*"; PASS=$(( PASS + 1 )); }

# th_kill_fixture_pid / th_kill_own_child (PID-recycling-safe cleanup).
# shellcheck source=_test_helpers.sh
. "$_real_test_dir/_test_helpers.sh"

# Mirror the synthetic layout from test-launcher-pidfile.sh so the
# launcher's BASH_SOURCE-relative path resolution lands inside an
# isolated `<root>/monitor/.state/` tree. Sets globals WORK,
# LAUNCHER, PIDFILE, BIN.
build_case() {
    local label="$1"
    WORK=$(mktemp -d -t "nexus-launcher-replace-${label}-XXXXXX")
    mkdir -p "$WORK/monitor/watcher" "$WORK/monitor/.state" "$WORK/bin" "$WORK/config"
    cp "$REAL_LAUNCHER" "$WORK/monitor/watcher/launcher.sh"
    chmod +x "$WORK/monitor/watcher/launcher.sh"
    # launcher.sh sources _lib.sh for `_watcher_pid_is_live_watcher`
    # and _respawn_async.sh for `_respawn_async_cancel` (issue #203
    # --replace orphan-cancel guard).
    cp "$_real_test_dir/_lib.sh" "$WORK/monitor/watcher/_lib.sh"
    cp "$_real_test_dir/_respawn_async.sh" "$WORK/monitor/watcher/_respawn_async.sh"
    LAUNCHER="$WORK/monitor/watcher/launcher.sh"
    PIDFILE="$WORK/monitor/.state/watcher.pid"
    BIN="$WORK/bin"

    # Stub main.sh: the headless launcher setsid-launches this and then
    # verifies the self-published pidfile. Mirror the real contract —
    # publish pid, then idle. No `exec`: argv must stay
    # `bash .../monitor/watcher/main.sh` for the identity check.
    cat > "$WORK/monitor/watcher/main.sh" <<EOF
#!/usr/bin/env bash
echo \$\$ > "$WORK/monitor/.state/watcher.pid"
sleep 60
EOF
    chmod +x "$WORK/monitor/watcher/main.sh"

    cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$BIN/tmux"

    cat > "$WORK/config/load.sh" <<'EOF'
#!/usr/bin/env bash
echo "${2:-}"
EOF
    chmod +x "$WORK/config/load.sh"
}

cleanup_case() {
    # Reap any headless stub watcher the launcher spawned. Identity-
    # verified: several cases kill the stub mid-case, leaving the
    # pidfile naming a dead PID; after a PID-space wrap a blind kill
    # would signal whatever recycled the number (see the th_kill_*
    # header in _test_helpers.sh). The stub's argv carries the
    # $WORK-prefixed main.sh path, so the fixture-root check holds.
    local _p=''
    [[ -f "$PIDFILE" ]] && read -r _p < "$PIDFILE" 2>/dev/null
    [[ "$_p" =~ ^[0-9]+$ ]] && th_kill_fixture_pid "$_p" "$WORK"
    rm -rf "$WORK"
    unset WORK LAUNCHER PIDFILE BIN
}

# Spawn a process whose argv reads like a real watcher
# (`bash …/monitor/watcher/main.sh`) so the launcher's identity check
# (`_watcher_pid_is_live_watcher`) recognises it. $1 = optional body
# lines for the faux main.sh (default: `sleep 60`); pass a SIGTERM
# trap to model the stubborn-process case. Sets global FAUX_PID.
spawn_faux_watcher() {
    local body="${1:-sleep 60}"
    local fdir="$WORK/faux/monitor/watcher"
    mkdir -p "$fdir"
    printf '#!/usr/bin/env bash\n%s\n' "$body" > "$fdir/main.sh"
    chmod +x "$fdir/main.sh"
    bash "$fdir/main.sh" &
    FAUX_PID=$!
    sleep 0.2   # let the kernel commit the cmdline
}

# Run the launcher under the case's stubbed PATH, with whatever
# extra args the caller passes. Sets globals RC, DURATION (seconds,
# integer floor).
run_launcher() {
    local t0 t1
    t0=$(date +%s)
    PATH="$BIN:$PATH" "$LAUNCHER" "$@" >"$WORK/out" 2>"$WORK/err"
    RC=$?
    t1=$(date +%s)
    DURATION=$(( t1 - t0 ))
}

# Post-spawn pidfile contract: the headless launcher exits 0 only once
# the (stub) main.sh re-published a LIVE pid. Assert that, and that it
# is not the pid the case planted beforehand.
assert_fresh_spawn() {
    local label="$1" not_pid="${2:-}" p=''
    [[ -f "$PIDFILE" ]] && read -r p < "$PIDFILE" 2>/dev/null
    if [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null && [[ "$p" != "$not_pid" ]]; then
        pass "$label (fresh pid=$p)"
    else
        fail "$label — pidfile content: ${p:-absent}"
    fi
}

# --- Case A: live PID + NO --replace → refuses (regression) -------------
echo '=== case A: live PID + no --replace → launcher refuses (regression) ==='

build_case A

spawn_faux_watcher
LIVE_PID=$FAUX_PID
echo "$LIVE_PID" > "$PIDFILE"

run_launcher
if (( RC == 1 )) \
   && grep -q "watcher process $LIVE_PID is alive" "$WORK/err"; then
    pass "launcher refused (rc=1) without --replace when pid is alive"
else
    fail "rc=$RC, stderr: $(cat "$WORK/err")"
fi
if [[ -f "$PIDFILE" ]]; then
    pass "launcher left the PID file in place on refusal"
else
    fail "launcher unexpectedly removed the live PID file"
fi
# Sanity-check the refusal hint now points at --replace, not the
# bare manual-kill recipe from the pre-#106 message.
if grep -q -- "--replace" "$WORK/err"; then
    pass "refusal message mentions --replace"
else
    fail "refusal message did not mention --replace: $(cat "$WORK/err")"
fi

kill "$LIVE_PID" 2>/dev/null || true
wait "$LIVE_PID" 2>/dev/null || true
cleanup_case

# --- Case B: live PID + --replace → SIGTERM graceful exit ---------------
echo '=== case B: live PID + --replace → SIGTERM graceful exit ==='

build_case B

# A faux watcher with no SIGTERM trap exits on SIGTERM, so the
# launcher's SIGTERM should kill it within the first kill -0 poll
# tick (~0.5s in our loop). Verifies the fast-path: graceful exit +
# pidfile cleaned + rc=0 + did not consume the 5s grace budget.
spawn_faux_watcher
GRACE_PID=$FAUX_PID
echo "$GRACE_PID" > "$PIDFILE"

run_launcher --replace
if (( RC == 0 )); then
    pass "launcher exited 0 with --replace on live pid"
else
    fail "launcher rc=$RC with --replace; stderr: $(cat "$WORK/err")"
fi
if kill -0 "$GRACE_PID" 2>/dev/null; then
    fail "launcher did not kill the live pid $GRACE_PID"
    kill -9 "$GRACE_PID" 2>/dev/null || true
else
    pass "launcher killed the live pid $GRACE_PID"
fi
assert_fresh_spawn "pidfile re-published by the fresh headless spawn" "$GRACE_PID"
if grep -q "exited gracefully" "$WORK/err"; then
    pass "launcher logged graceful-exit path"
else
    fail "launcher did not log graceful exit; stderr: $(cat "$WORK/err")"
fi
# Fast path; must not hang on the full 5s grace.
if (( DURATION < 3 )); then
    pass "graceful kill completed in ${DURATION}s (< 3s)"
else
    fail "graceful kill took ${DURATION}s — should be near-instant"
fi

wait "$GRACE_PID" 2>/dev/null || true
cleanup_case

# --- Case C: stubborn process + --replace → SIGKILL after timeout -------
echo '=== case C: stubborn process + --replace → SIGKILL after timeout ==='

build_case C

# Spawn a faux watcher that traps SIGTERM and ignores it. The trap
# swallows the polite signal; only SIGKILL can terminate it. The
# launcher should poll up to 5s, observe the process still alive,
# escalate, and proceed. The argv still identifies it as a watcher
# (it runs `…/monitor/watcher/main.sh`) so the identity check fires.
spawn_faux_watcher 'trap "" TERM
sleep 60'
STUBBORN_PID=$FAUX_PID
echo "$STUBBORN_PID" > "$PIDFILE"

run_launcher --replace
if (( RC == 0 )); then
    pass "launcher exited 0 with --replace on stubborn pid"
else
    fail "launcher rc=$RC; stderr: $(cat "$WORK/err")"
fi
if kill -0 "$STUBBORN_PID" 2>/dev/null; then
    fail "stubborn pid $STUBBORN_PID still alive after launcher"
    kill -9 "$STUBBORN_PID" 2>/dev/null || true
else
    pass "stubborn pid $STUBBORN_PID was killed"
fi
assert_fresh_spawn "pidfile re-published after SIGKILL escalation" "$STUBBORN_PID"
if grep -q "sending SIGKILL" "$WORK/err"; then
    pass "launcher logged the SIGKILL escalation"
else
    fail "launcher did not log SIGKILL escalation; stderr: $(cat "$WORK/err")"
fi
# Must have actually waited the grace window — at least ~5s.
if (( DURATION >= 5 )); then
    pass "launcher waited grace window (${DURATION}s >= 5s)"
else
    fail "launcher returned in ${DURATION}s (< 5s) — grace window collapsed"
fi

wait "$STUBBORN_PID" 2>/dev/null || true
cleanup_case

# --- Case D: stale PID + --replace → no grace-window delay --------------
echo '=== case D: stale PID + --replace → no 5s delay ==='

build_case D

sleep 0 &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
if kill -0 "$DEAD_PID" 2>/dev/null; then
    fail "test setup broken — pid $DEAD_PID still alive after wait"
else
    echo "$DEAD_PID" > "$PIDFILE"
    run_launcher --replace
    if (( RC == 0 )); then
        pass "launcher exited 0 on stale PID file with --replace"
    else
        fail "launcher rc=$RC; stderr: $(cat "$WORK/err")"
    fi
    assert_fresh_spawn "stale file superseded by a fresh headless spawn" "$DEAD_PID"
    # The stale-cleanup path skips SIGTERM + the 5s grace wait. The
    # headless spawn-verify poll adds up to ~1s on top, so anything
    # well under the 5s grace (< 4s) proves the grace did not leak in.
    if (( DURATION < 4 )); then
        pass "stale-cleanup path was fast (${DURATION}s)"
    else
        fail "stale-cleanup took ${DURATION}s — grace window leaked in"
    fi
    # And must not log the kill messages.
    if grep -q "SIGTERM\|SIGKILL\|exited gracefully" "$WORK/err"; then
        fail "stale-cleanup leaked kill-path log lines: $(cat "$WORK/err")"
    else
        pass "stale-cleanup did not log kill-path messages"
    fi
fi

cleanup_case

# --- Case E: --replace cancels an in-flight async respawn (issue #203) --
echo '=== case E: --replace cancels an orphaned in-flight async respawn ==='

build_case E

# Stage an in-flight async-respawn sentinel: a live throwaway process
# standing in for the disowned respawn subshell the replaced watcher had
# backgrounded. An intentional `--replace` must CANCEL it (kill + clear
# the sentinel) so it cannot later fire a kill-then-spawn against the
# now-live orchestrator window — the 2026-06-11 catastrophe class.
mkdir -p "$WORK/monitor/.state/respawn-bg"
sleep 120 &
RESPAWN_BG_PID=$!
sleep 0.2   # let the kernel commit it before the launcher probes
echo "$RESPAWN_BG_PID" > "$WORK/monitor/.state/respawn-bg/pid"

spawn_faux_watcher
LIVE_PID=$FAUX_PID
echo "$LIVE_PID" > "$PIDFILE"

run_launcher --replace
if (( RC == 0 )); then
    pass "launcher exited 0 with --replace (Case E)"
else
    fail "launcher rc=$RC with --replace; stderr: $(cat "$WORK/err")"
fi
if kill -0 "$RESPAWN_BG_PID" 2>/dev/null; then
    fail "launcher did NOT cancel the in-flight respawn (pid $RESPAWN_BG_PID still alive)"
    kill -9 "$RESPAWN_BG_PID" 2>/dev/null || true
else
    pass "launcher cancelled the in-flight respawn subshell (orphan-clobber guard)"
fi
if [[ -e "$WORK/monitor/.state/respawn-bg/pid" ]]; then
    fail "launcher did not clear the respawn-bg sentinel"
else
    pass "launcher cleared the respawn-bg sentinel"
fi
if grep -q "cancelled an in-flight async respawn" "$WORK/err"; then
    pass "launcher logged the orphan-cancel"
else
    fail "launcher did not log the orphan-cancel; stderr: $(cat "$WORK/err")"
fi

kill "$LIVE_PID" 2>/dev/null || true
wait "$LIVE_PID" 2>/dev/null || true
cleanup_case

# --- summary ------------------------------------------------------------

echo
echo "passed=$PASS failed=$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
else
    exit 1
fi
