#!/usr/bin/env bash
# Integration test for the crash-loop guard wired through main.sh.
#
# Sets up a fake nexus root, brings up a dedicated tmux server on a
# fixture-private socket (so it can't pollute the live nexus tmux),
# and runs main.sh against a stub `claude` that exits 1 immediately.
# After the configured limit of respawns within the window, the
# guard should trip — verified by the presence of the
# `respawn-guard-tripped` sentinel, the entries in
# `respawn-history.txt`, and the watcher log.
#
# This test is timing-dependent (15-30 s wall-clock) and requires
# tmux on PATH. It is NOT picked up by name-pattern test runners
# that match `test-*.sh` automatically — invoke it manually from
# the watcher dir, or wire it into a CI job that has tmux available.
#
# Gated behind SLOW_TESTS=1 (issue #40) so the default fast suite
# stays under 10 s. CI / pre-push should opt in by exporting
# `SLOW_TESTS=1`; the fast iteration loop runs without it.
#
# Run directly: SLOW_TESTS=1 ./monitor/watcher/test-respawn-loop-integration.sh

set -euo pipefail

if [ "${SLOW_TESTS:-0}" != "1" ]; then
    echo "skipped: $(basename "$0") (set SLOW_TESTS=1 to enable; ~13s wall-clock)"
    exit 0
fi

_test_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
SRC=$(cd "$_test_dir/../.." && pwd)

F=$(mktemp -d -t nexus-respawn-integ-XXXXXX)
echo "FIXTURE=$F"
echo "SRC=$SRC"

mkdir -p "$F/config" "$F/monitor/watcher" "$F/.bin" "$F/reports" "$F/work"

# Copy the real watcher tree into the fixture so main.sh resolves its
# own helper sources cleanly. Glob the WHOLE `_*.sh` helper set rather
# than enumerating it: main.sh has accreted ~16 `source` lines over
# time (_scheduler.sh, _over_limit.sh, _orchestrator_liveness.sh,
# _cc_update.sh, …), and an enumerated copy list silently drifts —
# every uncopied source becomes a `command not found` no-op that
# guts a code path (e.g. the rc=2 respawn branch via _target_absent.sh,
# issue #174; the scheduler loop via _scheduler.sh). Globbing is
# drift-proof: a new `source` line is covered automatically.
cp "$SRC/monitor/watcher/main.sh"   "$F/monitor/watcher/main.sh"
cp "$SRC"/monitor/watcher/_*.sh     "$F/monitor/watcher/"
# main.sh also sources ../_cc-version.sh (one level up from watcher/).
cp "$SRC/monitor/_cc-version.sh"    "$F/monitor/_cc-version.sh"
chmod +x "$F/monitor/watcher/main.sh"

# Tiny config loader. Returns deterministic values for keys we
# care about; defaults for everything else.
cat > "$F/config/load.sh" <<'CFG'
#!/usr/bin/env bash
key="$1"; default="${2:-}"
case "$key" in
    nexus.root)                              echo "$NEXUS_ROOT_OVERRIDE" ;;
    monitor.interval_seconds)                echo "2" ;;
    monitor.target_window)                   echo "orchestrator" ;;
    monitor.diff_retention_days)             echo "7" ;;
    monitor.agent_dead_threshold)            echo "999" ;;
    monitor.agent_missing_respawn_delay)     echo "0" ;;
    monitor.respawn_loop_window_seconds)     echo "120" ;;
    monitor.respawn_loop_limit)              echo "3" ;;
    monitor.watcher.auto_unstick)            echo "false" ;;
    monitor.watcher.ratelimit_probe)         echo "false" ;;
    github.repo)                             echo "your-org/test-fixture" ;;
    github.user_login)                       echo "test-user" ;;
    *)                                       echo "$default" ;;
esac
CFG
chmod +x "$F/config/load.sh"
export NEXUS_ROOT_OVERRIDE="$F"

# Stub claude that exits non-zero immediately. Without remain-on-exit
# the tmux window dies on exit → next watcher cycle sees it absent
# → respawn fires → stub crashes again → loop. After 3 within 120 s,
# the guard should trip.
cat > "$F/.bin/claude" <<'CLAUDE'
#!/usr/bin/env bash
echo "[stub-claude crashed at $(date -Is)]" >> "$NEXUS_ROOT_OVERRIDE/claude-crashes.log"
exit 1
CLAUDE
chmod +x "$F/.bin/claude"
echo "(stub claude exits 1 immediately)"

SESSION="nexus-respawn-test-$$"
# Use a dedicated tmux server to fully isolate from the live nexus
# tmux AND from concurrent runs of this test. `-L <name>` sockets
# always live under /tmp/tmux-$UID/ regardless of cwd, so the name
# itself must be unique per run: a fixed name ("tmux-sock") meant two
# gates running on the same box shared ONE server, and the first
# test's `kill-server` cleanup killed the other's in-flight session
# ("can't find session nexus-respawn-test-NNN" / "no server running").
SOCK_NAME="nexus-respawn-integ-$$"
TMUX_BIN_WRAPPER="$F/.bin/tmux"
mkdir -p "$F/.bin"
cat > "$TMUX_BIN_WRAPPER" <<TMUXWRAP
#!/usr/bin/env bash
exec /usr/bin/tmux -L "$SOCK_NAME" "\$@"
TMUXWRAP
chmod +x "$TMUX_BIN_WRAPPER"
# The fixture watcher keeps running inside the private server if this
# test dies mid-flight (set -e, runner timeout); EXIT-trap the server
# teardown so no orphan main.sh loop outlives the test.
trap '"$TMUX_BIN_WRAPPER" kill-server 2>/dev/null || true' EXIT
# Bring up the dedicated server. -L isolates its socket from the
# live nexus tmux. Set PATH and NEXUS_ROOT globally on this private
# server so every new window picks them up. Safe because -g here
# scopes to OUR socket only — the live nexus server is unaffected.
"$TMUX_BIN_WRAPPER" new-session -d -s "$SESSION" -c "$F"
"$TMUX_BIN_WRAPPER" setenv -g PATH "$F/.bin:$PATH"
"$TMUX_BIN_WRAPPER" setenv -g NEXUS_ROOT "$F"

# Run main.sh in a fresh window of the test session. Use a wrapper
# that sets fast interval + the override path and tees stderr.
cat > "$F/run-watcher.sh" <<RUN
#!/usr/bin/env bash
# Stub claude is FIRST on PATH; our tmux wrapper too so main.sh's
# tmux invocations route to the dedicated socket.
export PATH="$F/.bin:\$PATH"
export NEXUS_ROOT_OVERRIDE="$F"
export NEXUS_ROOT="$F"
export MONITOR_INTERVAL=2
export AGENT_MISSING_RESPAWN_DELAY=0
cd "$F"
bash "$F/monitor/watcher/main.sh" --target orchestrator > "$F/watcher-stderr.log" 2>&1
RUN
chmod +x "$F/run-watcher.sh"

# Wrap tmux so the watcher inside also sees the dedicated socket.
# The wrapper is FIRST on PATH so `tmux ...` from main.sh routes here.
first_win=$("$TMUX_BIN_WRAPPER" list-windows -t "$SESSION" -F '#{window_index}' | head -1)
"$TMUX_BIN_WRAPPER" send-keys -t "${SESSION}:${first_win}" "$F/run-watcher.sh" Enter

# Wait for the guard to trip — at 2 s interval, 3 respawns + cooldown
# should happen within ~15-20 s. Poll up to 60 s.
deadline=$(( $(date +%s) + 60 ))
state="$F/monitor/.state"
tripped=""
while (( $(date +%s) < deadline )); do
    if [[ -f "$state/respawn-guard-tripped" ]]; then
        tripped=$(cat "$state/respawn-guard-tripped")
        break
    fi
    sleep 1
done

echo "===== nexus-respawn-test session windows ====="
"$TMUX_BIN_WRAPPER" list-windows -t "$SESSION" -F '#{window_index}: #{window_name}'

echo "===== state dir ====="
ls -la "$state" 2>/dev/null || echo "(state dir missing)"

echo "===== respawn-history.txt ====="
cat "$state/respawn-history.txt" 2>/dev/null || echo "(no history)"

echo "===== respawn-guard-tripped ====="
cat "$state/respawn-guard-tripped" 2>/dev/null || echo "(NOT tripped — test FAILED)"

echo "===== watcher-stderr.log (tail 40) ====="
tail -40 "$F/watcher-stderr.log" 2>/dev/null || echo "(no log)"

echo "===== claude-crashes.log ====="
cat "$F/claude-crashes.log" 2>/dev/null || echo "(no crash log)"

# Cleanup. The private tmux server dies via the EXIT trap. Never
# glob-delete /tmp/nexus-orch-* here: this test never created those
# files (pre-#248 entry.sh did), so the old `rm -f
# /tmp/nexus-orch-launch-*` was deleting a concurrently-running
# test-entry.sh's fixtures — or, worse, a LIVE orchestrator launch
# file mid-respawn.

if [[ -n "$tripped" ]]; then
    echo
    echo "PASS: guard tripped at $tripped"
    exit 0
fi
echo
echo "FAIL: guard did not trip within deadline"
exit 1
