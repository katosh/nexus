#!/usr/bin/env bash
# PID-file orphan-detection tests for monitor/watcher/launcher.sh
# (issue #96). The pre-#96 launcher used `pgrep -f
# 'bash.*monitor/watcher/main\.sh'`, which matched the global process
# table and false-positive'd on worker `claude` processes whose argv
# text quoted the watcher path (issues #57, #96 repro 2026-05-13).
# The replacement reads `monitor/.state/watcher.pid` and consults
# `kill -0` on its content. These tests pin the new semantics:
#
#   1. Live PID file (writer process alive) → launcher refuses.
#   2. Stale PID file (writer process dead)  → launcher proceeds,
#      removes the stale file.
#   3. Garbage PID file (non-numeric content) → launcher proceeds,
#      removes the file (no crash on regex/kill-0 mismatch).
#   4. NO PID file + a worker process whose argv contains both `bash`
#      and `monitor/watcher/main.sh` is alive → launcher proceeds.
#      This is the regression test for the false-positive class
#      that motivated #96.
#
# Hermetic: NEXUS_ROOT is irrelevant because launcher.sh derives its
# PID file path from its own script location. We override that via a
# per-case isolated copy of launcher.sh sitting at the correct
# `<root>/monitor/watcher/launcher.sh` depth relative to a tmpdir;
# `tmux` and (for case 4 sanity) `pgrep` resolve via PATH; tmux is
# stubbed to no-op so the launcher's downstream window work doesn't
# touch a real server.
#
# Run: bash monitor/watcher/test-launcher-pidfile.sh
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

# Build an isolated tree that mirrors the nexus layout
# (`<root>/monitor/watcher/launcher.sh` + `<root>/monitor/.state/`),
# stubs tmux as a no-op, and points the launcher at the stub via PATH.
# Sets globals WORK, LAUNCHER, PIDFILE, BIN.
build_case() {
    local label="$1"
    WORK=$(mktemp -d -t "nexus-launcher-pid-${label}-XXXXXX")
    mkdir -p "$WORK/monitor/watcher" "$WORK/monitor/.state" "$WORK/bin" "$WORK/config"
    # Symlink the real launcher into the synthetic tree so we test
    # the actual script. The launcher resolves its own paths from
    # BASH_SOURCE, so the symlink target must be the canonical
    # depth; `cd $(dirname …) && pwd` follows symlinks to the real
    # location, which would break our hermetic isolation. Copy
    # instead.
    cp "$REAL_LAUNCHER" "$WORK/monitor/watcher/launcher.sh"
    chmod +x "$WORK/monitor/watcher/launcher.sh"
    # launcher.sh now sources _lib.sh for `_watcher_pid_is_live_watcher`
    # (the PID-identity check). Copy it to the canonical depth so the
    # launcher's BASH_SOURCE-relative `source` resolves inside the
    # synthetic tree.
    cp "$_real_test_dir/_lib.sh" "$WORK/monitor/watcher/_lib.sh"
    # launcher.sh sources ../_log-mode.sh (nexus-code#509).
    cp "$_real_test_dir/../_log-mode.sh" "$WORK/monitor/_log-mode.sh"
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

    # Stub tmux: no-op every subcommand. The launcher's downstream
    # block (new-session, list-windows, new-window, send-keys, set-
    # window-option) all return 0 → "no window exists, create one,
    # success" without touching a real tmux server.
    cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$BIN/tmux"

    # Stub config/load.sh so the launcher's TARGET fallback resolves
    # without needing the real config tree. Reads `<key> <default>`
    # and prints the default; launcher only calls it with
    # `monitor.target_window orchestrator`.
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

# Run the launcher under the case's stubbed PATH; captures stdout
# and stderr to per-case files. Sets globals RC.
run_launcher() {
    PATH="$BIN:$PATH" "$LAUNCHER" >"$WORK/out" 2>"$WORK/err"
    RC=$?
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

# Spawn a process whose argv reads like a real watcher
# (`bash …/monitor/watcher/main.sh`) so the launcher's identity check
# recognises it. Sets global FAUX_PID. The script just sleeps; the
# point is the argv, not the body.
spawn_faux_watcher() {
    local fdir="$WORK/faux/monitor/watcher"
    mkdir -p "$fdir"
    printf '#!/usr/bin/env bash\nsleep 60\n' > "$fdir/main.sh"
    chmod +x "$fdir/main.sh"
    bash "$fdir/main.sh" &
    FAUX_PID=$!
    sleep 0.2   # let the kernel commit the cmdline
}

# --- Case 1: live PID file (real watcher) → launcher refuses ------------
echo '=== case 1: live PID file (watcher argv) → launcher refuses ==='

build_case 1

# A live process whose argv identifies it as the watcher — the only
# thing that should make the launcher refuse.
spawn_faux_watcher
LIVE_PID=$FAUX_PID
echo "$LIVE_PID" > "$PIDFILE"

run_launcher
if (( RC == 1 )) \
   && grep -q "watcher process $LIVE_PID is alive" "$WORK/err"; then
    pass "launcher refused (rc=1) when PID file's pid is alive"
else
    fail "rc=$RC, stderr did not mention live pid $LIVE_PID: $(cat "$WORK/err")"
fi
# Refusal must NOT delete the PID file — it's still owned by a live
# process, and a future operator's `kill` should find it.
if [[ -f "$PIDFILE" ]]; then
    pass "launcher left the PID file in place on refusal"
else
    fail "launcher unexpectedly removed the live PID file"
fi

kill "$LIVE_PID" 2>/dev/null || true
wait "$LIVE_PID" 2>/dev/null || true
cleanup_case

# --- Case 2: stale PID file (dead pid) → launcher proceeds --------------
echo '=== case 2: stale PID file (dead pid) → launcher proceeds + cleans ==='

build_case 2

# Spawn a child, capture its pid, reap it. The kernel won't recycle
# the pid immediately, so `kill -0 $dead_pid` reliably fails within
# this test's lifetime.
sleep 0 &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
# Defensive sanity: confirm the pid is in fact dead before asserting.
if kill -0 "$DEAD_PID" 2>/dev/null; then
    fail "test setup broken — pid $DEAD_PID still alive after wait"
else
    echo "$DEAD_PID" > "$PIDFILE"
    run_launcher
    if (( RC == 0 )); then
        pass "launcher exited 0 on stale PID file"
    else
        fail "launcher rc=$RC on stale PID file (expected 0); stderr: $(cat "$WORK/err")"
    fi
    assert_fresh_spawn "stale file superseded by a fresh headless spawn" "$DEAD_PID"
fi

cleanup_case

# --- Case 3: garbage PID file → launcher proceeds + cleans --------------
echo '=== case 3: garbage PID file → launcher proceeds + cleans ==='

build_case 3

# Non-numeric content: simulates a half-written / corrupted file or a
# manual edit. The launcher's numeric regex guard must reject it
# without invoking `kill -0` (which would otherwise emit "arguments
# must be process or job IDs" on stderr).
printf 'not a pid\n' > "$PIDFILE"

run_launcher
if (( RC == 0 )); then
    pass "launcher exited 0 on garbage PID file"
else
    fail "launcher rc=$RC on garbage PID file (expected 0); stderr: $(cat "$WORK/err")"
fi
assert_fresh_spawn "garbage file superseded by a fresh headless spawn"
# Confirm `kill: arguments…` never leaked through.
if grep -q "kill:" "$WORK/err"; then
    fail "launcher leaked a kill(1) error to stderr: $(cat "$WORK/err")"
else
    pass "launcher did not invoke kill on non-numeric content"
fi

cleanup_case

# --- Case 4: no PID file + foreign argv alive → launcher proceeds -------
echo '=== case 4: foreign worker argv must NOT false-positive (regression #57/#96) ==='

build_case 4

# Reproduce the false-positive fixture: a real bash process whose
# argv contains both `bash` and `monitor/watcher/main.sh` as text
# (the worker-prompt content that bit the orchestrator on 2026-05-13).
# Under the pre-#96 pgrep regex this would match; under the PID-file
# check, it's invisible (no PID file present).
mkdir -p "$WORK/worker-faux/monitor/watcher"
cat > "$WORK/worker-faux/monitor/watcher/main.sh" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$WORK/worker-faux/monitor/watcher/main.sh"

bash "$WORK/worker-faux/monitor/watcher/main.sh" &
WORKER_PID=$!
# Give the kernel a moment to commit the cmdline write.
sleep 0.2

# Sanity: confirm the fixture WOULD have matched the legacy pgrep
# pattern. If this fails the test setup is broken, not the launcher.
if ! pgrep -f 'bash.*monitor/watcher/main\.sh' >/dev/null 2>&1; then
    fail "fixture invisible to legacy pgrep regex — test setup broken"
    kill "$WORKER_PID" 2>/dev/null || true
    cleanup_case
else
    pass "fixture matches the legacy pgrep regex (reproduces the #57/#96 trap)"

    # Belt-and-suspenders: ensure no PID file exists.
    if [[ -f "$PIDFILE" ]]; then
        fail "test setup broken — PID file unexpectedly present"
    fi

    run_launcher
    if (( RC == 0 )) \
       && ! grep -q "watcher process" "$WORK/err"; then
        pass "launcher proceeds despite foreign worker argv (no false-positive refusal)"
    else
        fail "launcher refused or errored on foreign argv; rc=$RC stderr: $(cat "$WORK/err")"
    fi

    kill "$WORKER_PID" 2>/dev/null || true
    wait "$WORKER_PID" 2>/dev/null || true
    cleanup_case
fi

# --- Case 5: live PID file but pid is NOT a watcher → launcher proceeds --
echo '=== case 5: recycled PID (live, non-watcher) → launcher proceeds (incident 2026-06-07) ==='

# The incident: after a restart the PID namespace resets and the
# stale watcher.pid (the recurring `pid=13`) gets recycled to an
# unrelated live process. A bare `kill -0` succeeds against it and
# the launcher refuses forever, deadlocking recovery. The
# identity-validated check must treat that live-but-foreign pid as
# stale, remove the file, and proceed.
build_case 5

# A live process whose argv is NOT a watcher (a bare sleep) standing
# in for whatever recycled the low PID after the restart.
sleep 60 &
RECYCLED_PID=$!
echo "$RECYCLED_PID" > "$PIDFILE"

run_launcher
if (( RC == 0 )) && ! grep -q "is alive" "$WORK/err"; then
    pass "launcher proceeded (rc=0) on a live but non-watcher pid"
else
    fail "launcher refused on recycled pid $RECYCLED_PID; rc=$RC stderr: $(cat "$WORK/err")"
fi
assert_fresh_spawn "recycled-pid file superseded by a fresh headless spawn" "$RECYCLED_PID"
# Crucially, the launcher must NOT have signalled the recycled pid's
# current owner — it isn't ours to kill. The process must still live.
if kill -0 "$RECYCLED_PID" 2>/dev/null; then
    pass "launcher did not signal the recycled pid's current owner"
else
    fail "launcher killed the recycled pid $RECYCLED_PID — not ours to kill"
fi

kill "$RECYCLED_PID" 2>/dev/null || true
wait "$RECYCLED_PID" 2>/dev/null || true
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
