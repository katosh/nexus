#!/usr/bin/env bash
# REAL-headless-launch regression test for monitor/watcher/launcher.sh
# (your-org/nexus-code #292 follow-up).
#
# THE BUG this pins: the #292 watcher-supervision launcher closed the
# single-flight restart-lock fd in the spawned watcher with
#
#     "$_script_dir/main.sh" --target "$TARGET" ... \
#         ${_RESTART_LOCK_FD:+${_RESTART_LOCK_FD}>&-} &
#
# `${_RESTART_LOCK_FD:+${_RESTART_LOCK_FD}>&-}` is a PARAMETER EXPANSION,
# not a redirection. Bash scans a command's words for redirection
# operators BEFORE expansion, so a word like `10>&-` synthesised by the
# expansion is NOT re-tokenized as a redirect — it is passed to main.sh
# as a positional ARGUMENT. main.sh then dies with
# `main.sh: unknown flag: 10>&-`, so the #292 feature was non-functional:
# the watcher crashed at startup. The unit suite missed it because nothing
# performed a REAL launcher.sh -> main.sh headless spawn (the existing
# test-launcher-pidfile.sh stub ignores argv, so the bad arg slipped by).
#
# THE FIX: emit the brace-form `{_RESTART_LOCK_FD}>&-` as a LITERAL
# redirection word in the source (branching on whether the fd is set,
# since a redirect cannot be made conditional via expansion).
#
# What this test asserts about a REAL headless launch (isolated tree):
#   1. launcher.sh exits 0 (the spawn took).
#   2. The spawned main.sh started CLEANLY — its log has NO `unknown flag`,
#      the early heartbeat + pidfile were published, the process is alive.
#   3. The restart-lock fd was CLOSED in the child (the ORIGINAL INTENT):
#      the child's own /proc/<pid>/fd shows no fd pointing at the lock,
#      AND a subsequent `flock -w` on the lock acquires (the deadlock the
#      close exists to prevent).
#   4. MUTATION CHECK: a copy of launcher.sh reverted to the broken
#      `${_RESTART_LOCK_FD:+...}` expansion FAILS this test with the exact
#      `unknown flag: <fd>>&-` signature and a dead child.
#
# SAFETY — full isolation (this launches a REAL watcher process):
#   * Every path the launcher honors is rooted at a per-case `mktemp -d`;
#     the live monitor/.state is never touched.
#   * main.sh is a faithful STUB (publish heartbeat+pid, then parse argv
#     exactly like the real main.sh, then idle) — never the real watcher,
#     so no config sourcing, no tmux paste, no GitHub writes.
#   * tmux is stubbed to a no-op: the launcher's window work hits the stub,
#     never a real server / the live orchestrator window.
#   * The spawned child is setsid'd (its own process group); cleanup reaps
#     the whole group by the RECORDED pid via th_kill_fixture_pid (fixture-
#     root guarded against PID recycling). No pkill/pgrep anywhere.
#
# Run: bash monitor/watcher/test-launcher-headless.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_real_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REAL_LAUNCHER="$_real_test_dir/launcher.sh"

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$(( FAIL + 1 )); }
pass() { echo "ok:   $*"; PASS=$(( PASS + 1 )); }

# th_kill_fixture_pid (PID-recycling-safe, fixture-root-guarded cleanup).
# shellcheck source=_test_helpers.sh
. "$_real_test_dir/_test_helpers.sh"

# Track spawned-child pids for the EXIT trap so no headless stub watcher
# ever outlives the test, even on an early failure/abort.
declare -a SPAWNED_PIDS=()
declare -a WORK_DIRS=()
reap_all() {
    local i
    for i in "${!SPAWNED_PIDS[@]}"; do
        # Skip pids already reaped mid-test (their /proc entry is gone, and
        # the helper's `< /proc/<pid>/cmdline` would leak a shell redirect
        # error). --group: the child is setsid'd and leads its own group.
        kill -0 "${SPAWNED_PIDS[i]}" 2>/dev/null || continue
        th_kill_fixture_pid "${SPAWNED_PIDS[i]}" "${WORK_DIRS[i]}" TERM --group
    done
}
trap reap_all EXIT

# Build an isolated tree mirroring the nexus layout
# (`<root>/monitor/watcher/launcher.sh` + `<root>/monitor/.state/`), with a
# FAITHFUL stub main.sh, a no-op tmux, and a stub config/load.sh. Copies the
# launcher under test in (optionally mutated by $1='broken'). Sets globals
# WORK, LAUNCHER, PIDFILE, HEARTBEAT, LOCKFILE, CHILDFDS, LOGFILE, BIN.
build_case() {
    local mode="${1:-fixed}"
    WORK=$(mktemp -d -t "nexus-launcher-headless-${mode}-XXXXXX")
    WORK_DIRS+=("$WORK")
    mkdir -p "$WORK/monitor/watcher" "$WORK/monitor/.state" "$WORK/bin" "$WORK/config"

    # Copy the real launcher into the synthetic tree at the canonical
    # depth (it resolves its own paths from BASH_SOURCE). For the mutation
    # case, revert ONLY the literal brace redirect back to the broken
    # parameter-expansion form — perl with \Q...\E keeps the swap exact and
    # free of sed metacharacter hazards (`{ } & + $`).
    if [[ "$mode" == broken ]]; then
        LC_ALL=C perl -0777 -pe \
            's/\Q2>&1 {_RESTART_LOCK_FD}>&- &\E/2>&1 \${_RESTART_LOCK_FD:+\${_RESTART_LOCK_FD}>&-} &/' \
            "$REAL_LAUNCHER" > "$WORK/monitor/watcher/launcher.sh"
    else
        cp "$REAL_LAUNCHER" "$WORK/monitor/watcher/launcher.sh"
    fi
    chmod +x "$WORK/monitor/watcher/launcher.sh"

    # launcher.sh sources _lib.sh for `_watcher_pid_is_live_watcher`
    # (the pidfile-verify identity check). Copy it to the canonical depth.
    cp "$_real_test_dir/_lib.sh" "$WORK/monitor/watcher/_lib.sh"

    # launcher.sh sources ../_log-mode.sh (nexus-code#509).
    cp "$_real_test_dir/../_log-mode.sh" "$WORK/monitor/_log-mode.sh"

    LAUNCHER="$WORK/monitor/watcher/launcher.sh"
    PIDFILE="$WORK/monitor/.state/watcher.pid"
    HEARTBEAT="$WORK/monitor/.state/watcher-heartbeat"
    LOCKFILE="$WORK/monitor/.state/watcher-restart.lock"
    CHILDFDS="$WORK/monitor/.state/child-open-fds.txt"
    LOGFILE="$WORK/monitor/.state/watcher.log"
    BIN="$WORK/bin"

    # FAITHFUL stub main.sh. Mirrors the real main.sh's LOAD-BEARING order
    # (main.sh:262-318): publish the early heartbeat, then the pidfile,
    # then parse argv — rejecting any unknown flag with the exact
    # `main.sh: unknown flag: <arg>` string and exit 1. That ordering is
    # what makes the bug observable: under the broken launcher the child
    # writes its pidfile/heartbeat (transiently) and THEN dies on the
    # `10>&-` argument. On a clean parse it records its own open fds (so
    # the fd-close intent is checkable) and idles. No `exec`: argv must stay
    # `bash .../monitor/watcher/main.sh ...` for the identity check.
    cat > "$WORK/monitor/watcher/main.sh" <<'EOF'
#!/usr/bin/env bash
_sd="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.state" 2>/dev/null && pwd)"
# Early heartbeat THEN pidfile (ordering load-bearing; see main.sh).
printf 'pid=%d\nts=%s\ntarget=%s\n' "$$" "stub" "${TARGET:-}" \
    > "$_sd/watcher-heartbeat.tmp" 2>/dev/null \
    && mv "$_sd/watcher-heartbeat.tmp" "$_sd/watcher-heartbeat" 2>/dev/null
printf '%d\n' "$$" > "$_sd/watcher.pid.tmp" 2>/dev/null \
    && mv "$_sd/watcher.pid.tmp" "$_sd/watcher.pid" 2>/dev/null || true
# argv parse — faithful to real main.sh: unknown flag is fatal.
while (( $# > 0 )); do
    case "$1" in
        --target) shift 2 ;;
        --once)   shift ;;
        *)        echo "main.sh: unknown flag: $1" >&2; exit 1 ;;
    esac
done
# Clean start: snapshot our own open fds (symlink targets) so the test can
# confirm the restart-lock fd was closed in this child, then idle.
for _fd in /proc/$$/fd/*; do readlink "$_fd" 2>/dev/null; done > "$_sd/child-open-fds.txt"
sleep 120
EOF
    chmod +x "$WORK/monitor/watcher/main.sh"

    # Stub tmux: no-op every subcommand so the launcher's window block
    # (new-session/list-windows/new-window/send-keys/...) all "succeed"
    # without a real server.
    printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/tmux"
    chmod +x "$BIN/tmux"

    # Stub config/load.sh: echo the supplied default. The launcher calls it
    # only as `monitor.target_window orchestrator` (plus knob lookups).
    printf '#!/usr/bin/env bash\necho "${2:-}"\n' > "$WORK/config/load.sh"
    chmod +x "$WORK/config/load.sh"
}

# Run the launcher under the case's stubbed PATH; capture rc + the child
# pid the launcher verified. Sets globals RC, CHILD_PID.
run_launcher() {
    PATH="$BIN:$PATH" "$LAUNCHER" --target headless-test >"$WORK/out" 2>"$WORK/err"
    RC=$?
    CHILD_PID=''
    [[ -f "$PIDFILE" ]] && read -r CHILD_PID < "$PIDFILE" 2>/dev/null
    [[ "$CHILD_PID" =~ ^[0-9]+$ ]] && SPAWNED_PIDS+=("$CHILD_PID")
}

# ======================================================================
# Case 1: the REAL fix — a clean headless launch.
# ======================================================================
echo '=== case 1: REAL headless launch via launcher.sh starts main.sh cleanly ==='
build_case fixed
run_launcher

# 1. launcher reports a successful spawn.
if (( RC == 0 )); then
    pass "launcher.sh exited 0 (spawn took)"
else
    fail "launcher.sh rc=$RC (expected 0); stderr: $(cat "$WORK/err"); log: $(cat "$LOGFILE" 2>/dev/null)"
fi

# 2a. No `unknown flag` anywhere in the spawned watcher's log — the direct
#     fingerprint of the bug.
if [[ -f "$LOGFILE" ]] && grep -q "unknown flag" "$LOGFILE"; then
    fail "spawned main.sh logged an 'unknown flag' (the #292 bug): $(cat "$LOGFILE")"
else
    pass "spawned main.sh log is free of 'unknown flag'"
fi

# 2b. Early heartbeat + pidfile published.
if [[ -f "$HEARTBEAT" ]] && grep -q "^pid=" "$HEARTBEAT"; then
    pass "early heartbeat published"
else
    fail "early heartbeat missing/malformed: $(cat "$HEARTBEAT" 2>/dev/null || echo absent)"
fi

# 2c. The spawned watcher is ALIVE and its argv identifies it as main.sh.
if [[ "$CHILD_PID" =~ ^[0-9]+$ ]] && kill -0 "$CHILD_PID" 2>/dev/null \
   && tr '\0' ' ' < "/proc/$CHILD_PID/cmdline" 2>/dev/null | grep -q "monitor/watcher/main.sh"; then
    pass "spawned watcher (pid=$CHILD_PID) is alive with a main.sh argv"
else
    fail "spawned watcher not alive / wrong argv; pid=${CHILD_PID:-absent}"
fi

# 3a. ORIGINAL INTENT — the restart-lock fd was CLOSED in the child. The
#     child snapshotted its own open-fd symlink targets; none may be the
#     restart lock.
if [[ -f "$CHILDFDS" ]]; then
    if grep -qxF "$LOCKFILE" "$CHILDFDS"; then
        fail "restart-lock fd LEAKED into the child (deadlock regression): $(cat "$CHILDFDS")"
    else
        pass "restart-lock fd is absent from the child's open fds (closed as intended)"
    fi
else
    fail "child never recorded its open fds (did it start cleanly?)"
fi

# 3b. Deadlock-avoidance, end to end: with the launcher PARENT exited and
#     the child's copy closed, the lock must be ACQUIRABLE by a fresh
#     waiter. If the child had inherited+held the fd, this would time out.
if flock -w 2 "$LOCKFILE" -c 'exit 0' 2>/dev/null; then
    pass "restart lock is acquirable after launch (no inherited-fd deadlock)"
else
    fail "restart lock is still held — the child kept the inherited fd (deadlock the close prevents)"
fi

# Reap before the next case so only one stub watcher is ever alive.
th_kill_fixture_pid "$CHILD_PID" "$WORK" TERM --group
sleep 0.3

# ======================================================================
# Case 2: MUTATION CHECK — restoring the broken expansion form must make
# this very test fail with the bug's signature. Proves the test has teeth.
# ======================================================================
echo '=== case 2: mutation — broken ${_RESTART_LOCK_FD:+...} expansion reproduces the crash ==='
build_case broken

# Sanity: the mutation actually changed the spawn line back to the
# expansion form (guards against a silent perl no-op if the source drifts).
if grep -q '${_RESTART_LOCK_FD:+${_RESTART_LOCK_FD}>&-}' "$LAUNCHER"; then
    pass "mutation applied (broken parameter-expansion form present in launcher copy)"
else
    fail "mutation did NOT apply — perl swap matched nothing; the redirect source may have drifted"
fi

run_launcher

# The broken launcher passes `<fd>>&-` as an argument; the faithful stub
# rejects it exactly like real main.sh. The bug's fingerprint:
if [[ -f "$LOGFILE" ]] && grep -Eq "main\.sh: unknown flag: [0-9]+>&-" "$LOGFILE"; then
    pass "broken form logs 'unknown flag: <fd>>&-' (bug reproduced) — test catches the #292 regression"
else
    fail "broken form did NOT produce the 'unknown flag: <fd>>&-' signature; log: $(cat "$LOGFILE" 2>/dev/null || echo absent)"
fi

# And the consequence: the watcher is NOT alive (it crashed at startup),
# and the launcher reports the spawn did not stick (rc != 0).
if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
    fail "broken form left a live watcher (pid=$CHILD_PID) — expected it to have crashed"
else
    pass "broken form: spawned watcher is dead (crashed at startup, as #292 did live)"
fi
if (( RC != 0 )); then
    pass "broken form: launcher.sh reports spawn failure (rc=$RC)"
else
    fail "broken form: launcher.sh returned 0 despite the crashed child"
fi

# ======================================================================
echo
echo "passed=$PASS failed=$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
else
    exit 1
fi
