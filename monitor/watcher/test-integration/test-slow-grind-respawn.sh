#!/usr/bin/env bash
# Integration scenario: slow-grind respawn guard end-to-end.
#
# Pass B scenario 1/4 for your-org/nexus-code#78. The PR #80 substrate
# (consec-failure counter, cooldown stamp, re-arm) has unit-level
# coverage in `test-respawn-loop-guard.sh`. This scenario lifts that
# from "helpers behave correctly when called in isolation" to "the
# real main.sh poll loop walks the transitions correctly when
# `tmux new-window` keeps failing".
#
# Flow exercised:
#
#   1. Target window absent → main.sh calls `respawn_agent` →
#      `tmux new-window` fails (PATH-shadow wrapper, toggled by a flag
#      file). `_respawn_consec_record_failure` bumps the counter.
#   2. Counter crosses `MONITOR_RESPAWN_CONSECUTIVE_FAILURE_LIMIT` →
#      `_respawn_consec_check` trips → stamp file + log line.
#   3. Subsequent polls (within cooldown) skip the respawn path and
#      log `respawn paused: slow-grind cooldown active`.
#   4. Cooldown elapses → main.sh logs `cooldown elapsed; re-arming
#      guard`, removes the stamp, resets the counter.
#   5. Fail flag is dropped before re-arm → next attempt's
#      `tmux new-window` succeeds → `orchestrator` window appears, counter
#      stays cleared.
#
# This is the EXACT 1-per-minute slow-grind regression the issue #77
# substrate was added to catch (the burst-limit guard slides under
# the cadence). The unit suite asserts the helpers' state shape; the
# integration suite asserts the real loop's wiring around them.
#
# Run: RUN_INTEGRATION=1 bash monitor/watcher/test-integration/test-slow-grind-respawn.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_harness.sh
. "$_self_dir/_harness.sh"
# shellcheck source=../_test_helpers.sh
. "$_self_dir/../_test_helpers.sh"

harness_skip_if_disabled
harness_setup

# Knobs. The cooldown override lets the scenario finish in ~15 s
# instead of the production-default 10 min. Limit is small enough
# that ~3 fast poll cycles cross it; large enough that startup races
# don't accidentally trip it. Interval pins to 1 s so the loop turns
# fast enough for the scenario to complete inside its wait_for budgets.
SCENARIO_LIMIT=3
SCENARIO_COOLDOWN_S=4
SCENARIO_INTERVAL_S=1
TMUX_FAIL_FLAG="$HARNESS_DIR/.tmux-fail-new-window"

echo "=== harness ==="
echo "  HARNESS_DIR=$HARNESS_DIR"
echo "  HARNESS_SESSION=$HARNESS_SESSION"
echo "  consec_limit=$SCENARIO_LIMIT cooldown=${SCENARIO_COOLDOWN_S}s interval=${SCENARIO_INTERVAL_S}s"

# ---------------------------------------------------------------------------
# Failure-injecting tmux wrapper. Overwrites the harness's default
# wrapper. Fails `tmux new-window` when the flag file is present;
# routes every other call to the real tmux on the harness socket.
# Keeping the routing identical to the harness's wrapper means the
# only behavioural difference under test is the `new-window`
# rejection — exactly the failure mode the slow-grind guard exists
# to catch.
#
# Resolve real tmux by searching default system paths — harness_setup
# already prepended $HARNESS_BIN to PATH so `command -v tmux` would
# resolve to the wrapper itself (infinite exec loop). The harness's
# own wrapper resolves real tmux before shadowing PATH; we don't have
# that luxury here because we're called AFTER setup, so do the lookup
# against an explicit clean path.
# ---------------------------------------------------------------------------
real_tmux=$(PATH=/usr/local/bin:/usr/bin:/bin command -v tmux)
if [[ -z "$real_tmux" ]]; then
    echo "FAIL: could not resolve real tmux on a clean PATH" >&2
    th_summary_and_exit
fi
cat > "$HARNESS_BIN/tmux" <<TMUXWRAP
#!/usr/bin/env bash
if [[ "\${1:-}" == "new-window" && -f "$TMUX_FAIL_FLAG" ]]; then
    echo "tmux: new-window forced failure by integration harness" >&2
    exit 1
fi
exec "$real_tmux" -L "$HARNESS_SOCKET" "\$@"
TMUXWRAP
chmod +x "$HARNESS_BIN/tmux"

# ---------------------------------------------------------------------------
# `gh` stub. The watcher's startup sweep + `github_poll` /
# `deliveries_poll` tasks fan out to `gh api graphql`. We don't
# want real API calls; a no-op stub leaves the GitHub axis inert
# so the assertions stay scoped to slow-grind transitions.
# ---------------------------------------------------------------------------
cat > "$HARNESS_BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
# Empty success. The watcher absorbs an empty snapshot as "nothing
# eligible" and moves on.
exit 0
GHSTUB
chmod +x "$HARNESS_BIN/gh"

# ---------------------------------------------------------------------------
# Minimal config loader. The watcher's `_cfg` shells out to
# `<nexus_root>/config/load.sh <dotted.key> [default]`. We materialize a
# stub that answers every key main.sh asks about. Anything not enumerated
# echoes the default — same contract as production `config/load.sh`.
# ---------------------------------------------------------------------------
mkdir -p "$HARNESS_DIR/config"
cat > "$HARNESS_DIR/config/load.sh" <<CFGSTUB
#!/usr/bin/env bash
key="\${1:-}"; default="\${2:-}"
case "\$key" in
    nexus.root)                                       echo "$HARNESS_DIR" ;;
    monitor.interval_seconds)                         echo "$SCENARIO_INTERVAL_S" ;;
    monitor.target_window)                            echo "orchestrator" ;;
    monitor.diff_retention_days)                      echo "7" ;;
    monitor.agent_dead_threshold)                     echo "999" ;;
    monitor.agent_missing_respawn_delay)              echo "0" ;;
    monitor.respawn_loop_window_seconds)              echo "120" ;;
    monitor.respawn_loop_limit)                       echo "999" ;;
    monitor.respawn_consecutive_failure_limit)        echo "$SCENARIO_LIMIT" ;;
    monitor.respawn_slow_grind_cooldown_seconds)      echo "$SCENARIO_COOLDOWN_S" ;;
    monitor.watcher.auto_unstick)                     echo "false" ;;
    monitor.watcher.ratelimit_probe)                  echo "false" ;;
    monitor.full_state_emit_interval_seconds)         echo "0" ;;
    monitor.deliveries.asset_enabled)                 echo "false" ;;
    monitor.deliveries.bot_mention_enabled)           echo "false" ;;
    monitor.mentions_enabled)                         echo "false" ;;
    github.repo)                                      echo "fixture/slow-grind" ;;
    github.user_login)                                echo "test-user" ;;
    github.bot_login)                                 echo "" ;;
    *) echo "\$default" ;;
esac
CFGSTUB
chmod +x "$HARNESS_DIR/config/load.sh"

# ---------------------------------------------------------------------------
# Mirror the watcher tree into the fake nexus root so main.sh resolves
# its helpers from a path that aligns with our stubbed `config/load.sh`.
# The helpers are pure-function source files, so a cp is sufficient —
# no patching needed. Matches the legacy `test-respawn-loop-integration.sh`
# pattern that pre-dated the test-integration harness.
# ---------------------------------------------------------------------------
mkdir -p "$HARNESS_DIR/monitor/watcher"
for f in main.sh _lib.sh _github.sh _deliveries.sh _mentions.sh \
         _unstick.sh _idle_probe.sh; do
    cp "$HARNESS_REPO_ROOT/monitor/watcher/$f" \
       "$HARNESS_DIR/monitor/watcher/$f"
done

# ---------------------------------------------------------------------------
# Engage the failure injection BEFORE launching the watcher so the
# very first poll-cycle respawn attempt fails (and we don't race).
# ---------------------------------------------------------------------------
touch "$TMUX_FAIL_FLAG"

# Watcher env. PATH-shadow puts our stubs (tmux, gh, claude) ahead of
# system bins. AUTO_UNSTICK off — the unstick path is orthogonal here
# and pokes at tmux capture-pane in ways that risk false positives.
WATCHER_LOG="$HARNESS_DIR/watcher.log"
WATCHER_PID_FILE="$HARNESS_DIR/watcher.pid"
STATE_DIR="$HARNESS_DIR/monitor/.state"
COUNTER="$STATE_DIR/respawn-consecutive-failures.txt"
TRIPPED="$STATE_DIR/respawn-slow-grind-tripped"

echo
echo "=== launch watcher (background) ==="
(
    export PATH="$HARNESS_BIN:$PATH"
    export NEXUS_ROOT="$HARNESS_DIR"
    export MONITOR_INTERVAL="$SCENARIO_INTERVAL_S"
    export MONITOR_AUTO_UNSTICK=false
    export AGENT_MISSING_RESPAWN_DELAY=0
    export MONITOR_RESPAWN_CONSECUTIVE_FAILURE_LIMIT="$SCENARIO_LIMIT"
    export MONITOR_RESPAWN_SLOW_GRIND_COOLDOWN_SECONDS="$SCENARIO_COOLDOWN_S"
    # Burst-limit guard set very high so it can't trip before
    # slow-grind does. The two axes are deliberately decoupled in
    # PR #80; this just keeps the scenario focused.
    export MONITOR_RESPAWN_LOOP_LIMIT=999
    export MONITOR_FULL_STATE_EMIT_INTERVAL_SECONDS=0
    cd "$HARNESS_DIR"
    exec bash "$HARNESS_DIR/monitor/watcher/main.sh" --target orchestrator
) > "$WATCHER_LOG" 2>&1 &
echo $! > "$WATCHER_PID_FILE"
echo "  watcher pid=$(cat "$WATCHER_PID_FILE")"

# Chain teardown: kill the watcher before harness_teardown rips the
# tmux server out from under it. `harness_setup` registered its own
# EXIT trap; we override here and call both handlers explicitly.
cleanup() {
    if [[ -f "$WATCHER_PID_FILE" ]]; then
        local pid
        pid=$(cat "$WATCHER_PID_FILE")
        kill "$pid" 2>/dev/null || true
        # Give the watcher a beat to release its flock + heartbeat
        # files before the tmpdir gets blown away.
        sleep 0.2
        kill -9 "$pid" 2>/dev/null || true
        # Reap the job to suppress bash's "Killed: ..." stderr line.
        wait "$pid" 2>/dev/null || true
    fi
    harness_teardown
}
# bash job-control prints a "Killed" line when a backgrounded subshell
# dies of a signal. Disable that for the rest of the script — the
# watcher always exits via signal at teardown, and the noise is just
# noise.
set +m
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Predicates. Functions (not inline bash -c) so wait_for can call them
# without losing scope.
# ---------------------------------------------------------------------------
counter_count() {
    [[ -f "$COUNTER" ]] || { echo 0; return; }
    awk -F= '$1=="count" {print $2; exit}' "$COUNTER" 2>/dev/null
}
counter_at_least() {
    local want="$1"
    local n
    n=$(counter_count)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    (( n >= want ))
}
log_grep() { grep -qF -- "$1" "$WATCHER_LOG" 2>/dev/null; }
tripped_absent() { [[ ! -f "$TRIPPED" ]]; }
counter_cleared() { [[ ! -f "$COUNTER" ]]; }
orch_window_exists() {
    "$HARNESS_TMUX" list-windows -t "$HARNESS_SESSION" \
        -F '#{window_name}' 2>/dev/null | grep -qxF orchestrator
}

# ---------------------------------------------------------------------------
# Phase 1: counter ramps to the limit, guard trips.
# ---------------------------------------------------------------------------
echo
echo "=== phase 1: counter ramps, guard trips ==="
# Counter ramps once per poll-with-failure. Allow a generous budget:
# startup-sweep (1 cycle) + N polls + some slack on slow CI.
wait_for "consec-counter reaches $SCENARIO_LIMIT" 20 -- \
    counter_at_least "$SCENARIO_LIMIT"
wait_for "slow-grind tripped stamp appears" 5 -- \
    test -f "$TRIPPED"
wait_for "watcher log records 'slow-grind tripped'" 5 -- \
    log_grep "slow-grind tripped"

# ---------------------------------------------------------------------------
# Phase 2: while the cooldown is active, respawn attempts are paused.
# ---------------------------------------------------------------------------
echo
echo "=== phase 2: cooldown active, respawns paused ==="
wait_for "watcher log shows 'respawn paused: slow-grind cooldown active'" 5 -- \
    log_grep "respawn paused: slow-grind cooldown active"

# ---------------------------------------------------------------------------
# Phase 3: drop the fail injection, wait for cooldown to elapse, watcher
# re-arms and successfully spawns the target window.
# ---------------------------------------------------------------------------
echo
echo "=== phase 3: clear fail flag, cooldown elapses, re-arm ==="
rm -f "$TMUX_FAIL_FLAG"
wait_for "watcher log shows 'cooldown elapsed; re-arming guard'" \
    $(( SCENARIO_COOLDOWN_S + 8 )) -- \
    log_grep "respawn slow-grind cooldown elapsed"
wait_for "tripped stamp removed after re-arm" 5 -- tripped_absent
wait_for "orchestrator window successfully spawned after re-arm" 10 -- \
    orch_window_exists
wait_for "consec-counter cleared after successful respawn" 5 -- \
    counter_cleared

# ---------------------------------------------------------------------------
# Diagnostic dump on failure. Cheap when the test passes; precious on
# the next regression.
# ---------------------------------------------------------------------------
if (( FAIL > 0 )); then
    echo
    echo "=== diagnostic dump (failure path) ==="
    echo "--- list-windows ---"
    "$HARNESS_TMUX" list-windows -t "$HARNESS_SESSION" \
        -F '#{window_index}: #{window_name}' || true
    echo "--- state dir ---"
    ls -la "$STATE_DIR" 2>/dev/null || echo "(state dir missing)"
    echo "--- counter ---"
    cat "$COUNTER" 2>/dev/null || echo "(no counter)"
    echo "--- tripped stamp ---"
    cat "$TRIPPED" 2>/dev/null || echo "(no stamp)"
    echo "--- watcher log (tail 80) ---"
    tail -80 "$WATCHER_LOG" 2>/dev/null || echo "(no log)"
fi

th_summary_and_exit
