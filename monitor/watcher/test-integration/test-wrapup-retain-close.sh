#!/usr/bin/env bash
# Integration scenario: spawn → busy → idle → wrap-up → retain → close.
#
# Pass B scenario 2/4 for your-org/nexus-code#78. The wrap-up matcher
# (`_idle_window_wrap_up_report`), the retain-overlay
# (`_idle_window_retain_event` + the suppression branch in
# `list_really_idle_workers`), and the disappearance-prune that drops
# a window once tmux loses it all have unit-level coverage in the
# fast suite. This scenario lifts them from "helpers behave correctly
# in isolation" to "the real poll loop emits the expected idle-pool
# rows when a worker walks the wrap-up → retain → close lifecycle".
#
# Flow exercised:
#
#   1. Spawn a worker that renders the busy spinner for 3 s, then
#      transitions to idle. The watcher's startup sweep + first few
#      polls see `state=busy` and stamp engagement-log accordingly.
#   2. After the stub goes idle, the next poll's age computation
#      (`now - last_engagement`) crosses the
#      `MONITOR_IDLE_THRESHOLD_SECONDS` floor (test-knob is 2 s) and
#      `list_really_idle_workers` emits a `no-wrap-up` row. The watcher
#      archives the emit under `monitor/.state/diffs/*.md`.
#   3. Inject a `wrap-up` action-log row that names the worker window
#      directly (`{"event":"wrap-up","window":"<name>","report":...}`).
#      The matcher picks it up; the next emit reclassifies the row as
#      `wrapped`.
#   4. Inject a `window-retain` row with reason `wrap-up-YYYY-MM-DD` —
#      the same reason that `ng wrap-up` auto-stamps. The next emit
#      converts the `wrapped` row to `retained` and renders the
#      `(N retained windows suppressed: ...)` footer.
#   5. `tmux kill-window` on the worker. Subsequent polls don't
#      enumerate it; the row stays gone.
#
# Why inject action-log rows directly instead of driving `ng wrap-up`:
# the watcher's classifier consumes the action-log alone (issue body's
# "the watcher only consumes the action-log row"). Driving the verb
# end-to-end would pull in `gh`, `upload-asset.sh`, and the config
# bot-identity surface — all out-of-scope for what this scenario
# asserts.
#
# Note: the issue body sketch references injecting a `window-close`
# action-log row in the final step. No such event exists in the
# current monitor surface (cmd_wrap_up writes `wrap-up` + auto
# `window-retain`; there is no `window-close` verb), and the
# orchestrator task framing clarifies the close step as a mechanical
# `tmux kill-window`. This scenario implements the mechanical path
# and asserts disappearance via the tmux window list.
#
# Run: RUN_INTEGRATION=1 bash monitor/watcher/test-integration/test-wrapup-retain-close.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_harness.sh
. "$_self_dir/_harness.sh"
# shellcheck source=../_test_helpers.sh
. "$_self_dir/../_test_helpers.sh"

harness_skip_if_disabled
harness_setup

# Rename the harness session to `0` so the watcher's
# `_idle_pane_state_line` call resolves against this server. The probe
# passes pane-state.sh the bare window index, which pane-state.sh
# transforms to `0:<index>` before handing to tmux. Production matches
# because the operator's nexus tmux server names its session `0`; the
# harness's random session name `nexus-integ-<pid>-<rand>` would make
# every watcher-side classification report `state=absent`. `-L
# $HARNESS_SOCKET` keeps the dedicated socket so renaming to `0` cannot
# collide with the operator's live session.
"$HARNESS_TMUX" rename-session -t "$HARNESS_SESSION" 0
HARNESS_SESSION=0

# Knobs. Threshold low so we don't wait the production-default 60 s for
# idle-pool entry; interval low so the loop turns fast enough for the
# wait_for budgets. Total scenario runtime ~12-15 s.
SCENARIO_INTERVAL_S=1
SCENARIO_THRESHOLD_S=2
WORKER_NAME=wrapup-worker
RETAIN_REASON="wrap-up-$(date -u +%Y-%m-%d)"

echo "=== harness ==="
echo "  HARNESS_DIR=$HARNESS_DIR"
echo "  HARNESS_SESSION=$HARNESS_SESSION"
echo "  threshold=${SCENARIO_THRESHOLD_S}s interval=${SCENARIO_INTERVAL_S}s"
echo "  worker=$WORKER_NAME retain_reason=$RETAIN_REASON"

# ---------------------------------------------------------------------------
# Config stub. Mirrors the slow-grind scenario's `config/load.sh`
# pattern — main.sh resolves every knob through this script, so we
# enumerate what it asks for and echo `$default` for anything else.
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
    monitor.respawn_consecutive_failure_limit)        echo "999" ;;
    monitor.respawn_slow_grind_cooldown_seconds)      echo "9999" ;;
    monitor.watcher.auto_unstick)                     echo "false" ;;
    monitor.watcher.ratelimit_probe)                  echo "false" ;;
    monitor.full_state_emit_interval_seconds)         echo "0" ;;
    monitor.deliveries.asset_enabled)                 echo "false" ;;
    monitor.deliveries.bot_mention_enabled)           echo "false" ;;
    monitor.mentions_enabled)                         echo "false" ;;
    monitor.idle_threshold_seconds)                   echo "$SCENARIO_THRESHOLD_S" ;;
    monitor.idle_pool_spawn_grace_seconds)            echo "0" ;;
    monitor.idle_close_hours)                         echo "24" ;;
    monitor.retain_ttl_seconds)                       echo "86400" ;;
    github.repo)                                      echo "fixture/wrapup-retain-close" ;;
    github.user_login)                                echo "test-user" ;;
    github.bot_login)                                 echo "" ;;
    *) echo "\$default" ;;
esac
CFGSTUB
chmod +x "$HARNESS_DIR/config/load.sh"

# ---------------------------------------------------------------------------
# `gh` stub. Snapshot calls fan out through `gh api graphql`; a silent
# success leaves the GitHub axis inert so the assertions stay scoped to
# idle-pool transitions.
# ---------------------------------------------------------------------------
cat > "$HARNESS_BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
exit 0
GHSTUB
chmod +x "$HARNESS_BIN/gh"

# ---------------------------------------------------------------------------
# Mirror the watcher tree into the fake nexus root so main.sh's
# `_script_dir/../config/load.sh` lookup hits the stubbed config. The
# helpers are pure-function source files — a cp is sufficient. Also copy
# pane-state.sh: `_idle_pane_state_line` resolves it via
# $NEXUS_ROOT/monitor/pane-state.sh.
# ---------------------------------------------------------------------------
mkdir -p "$HARNESS_DIR/monitor/watcher"
for f in main.sh _lib.sh _github.sh _deliveries.sh _mentions.sh \
         _unstick.sh _idle_probe.sh _over_limit.sh; do
    cp "$HARNESS_REPO_ROOT/monitor/watcher/$f" \
       "$HARNESS_DIR/monitor/watcher/$f"
done
cp "$HARNESS_REPO_ROOT/monitor/pane-state.sh" "$HARNESS_DIR/monitor/pane-state.sh"

# ---------------------------------------------------------------------------
# Pre-create the orchestrator target window. `orchestrator` exists as
# a plain sleeper so the watcher's poll-level "target window absent"
# branch never fires — we don't want respawn machinery interfering
# with the idle-pool assertions. Paste-to-target will still log
# "paste submitted but signature not visible" (the sleeper doesn't
# render a Claude REPL); the emit still archives, which is what we
# read in the assertions.
# ---------------------------------------------------------------------------
"$HARNESS_TMUX" new-window -d -t "${HARNESS_SESSION}:" \
    -n orchestrator -c "$HARNESS_DIR" 'sleep 36000'

# ---------------------------------------------------------------------------
# Spawn the worker. 3 s busy spinner, then idle, holding the idle render
# for 60 s — plenty of time for the wrap-up → retain → close assertions.
# ---------------------------------------------------------------------------
echo
echo "=== spawn worker ==="
win=$(harness_spawn_worker "$WORKER_NAME" \
    "STUB_CLAUDE_BUSY_SECONDS=3" \
    "STUB_CLAUDE_HOLD_SECONDS=60")
[[ "$win" =~ ^[0-9]+$ ]] || {
    echo "  FAIL: spawn returned non-numeric window index: $win" >&2
    th_summary_and_exit
}
echo "  worker at window=$win"

# ---------------------------------------------------------------------------
# Launch the watcher in the background. Same env-knob bundle the
# slow-grind scenario uses; threshold + grace overrides are the only
# scenario-specific deltas.
# ---------------------------------------------------------------------------
WATCHER_LOG="$HARNESS_DIR/watcher.log"
WATCHER_PID_FILE="$HARNESS_DIR/watcher.pid"
STATE_DIR="$HARNESS_STATE_DIR"
ACTION_LOG="$STATE_DIR/action-log.jsonl"
DIFF_DIR="$STATE_DIR/diffs"

echo
echo "=== launch watcher (background) ==="
(
    export PATH="$HARNESS_BIN:$PATH"
    export NEXUS_ROOT="$HARNESS_DIR"
    export MONITOR_INTERVAL="$SCENARIO_INTERVAL_S"
    export MONITOR_IDLE_THRESHOLD_SECONDS="$SCENARIO_THRESHOLD_S"
    export MONITOR_IDLE_POOL_SPAWN_GRACE_SECONDS=0
    export MONITOR_AUTO_UNSTICK=false
    export AGENT_MISSING_RESPAWN_DELAY=0
    export MONITOR_RESPAWN_LOOP_LIMIT=999
    export MONITOR_RESPAWN_CONSECUTIVE_FAILURE_LIMIT=999
    export MONITOR_FULL_STATE_EMIT_INTERVAL_SECONDS=0
    cd "$HARNESS_DIR"
    exec bash "$HARNESS_DIR/monitor/watcher/main.sh" --target orchestrator
) > "$WATCHER_LOG" 2>&1 &
echo $! > "$WATCHER_PID_FILE"
echo "  watcher pid=$(cat "$WATCHER_PID_FILE")"

# Chain teardown: kill the watcher before harness_teardown rips the
# tmux server out from under it. Same pattern as test-slow-grind.
cleanup() {
    if [[ -f "$WATCHER_PID_FILE" ]]; then
        local pid
        pid=$(cat "$WATCHER_PID_FILE")
        kill "$pid" 2>/dev/null || true
        sleep 0.2
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    harness_teardown
}
set +m
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Predicates. Functions (not inline bash -c) so wait_for can call them
# without losing scope.
# ---------------------------------------------------------------------------
pane_state_is() {
    local expected="$1" out
    # pane-state.sh takes `<session>:<window-INDEX>` — names are
    # rejected (see usage block). $win is the 0-based index returned
    # by harness_spawn_worker.
    out=$(PATH="$HARNESS_BIN:$PATH" \
        "$HARNESS_REPO_ROOT/monitor/pane-state.sh" \
        "${HARNESS_SESSION}:${win}" 2>/dev/null) || return 1
    grep -q "state=${expected}" <<<"$out"
}

# Search archived emits + the watcher log for a needle. Archives live
# under $DIFF_DIR/*.md — one per emit-bearing cycle. The watcher log
# carries the bare "emit archive=<basename> reason=..." lines, useful
# for cross-referencing which cycle's archive contains a given match.
emits_contain() {
    local needle="$1"
    [[ -d "$DIFF_DIR" ]] || return 1
    grep -rqF -- "$needle" "$DIFF_DIR" 2>/dev/null
}

worker_window_absent() {
    ! "$HARNESS_TMUX" list-windows -t "$HARNESS_SESSION" \
        -F '#{window_name}' 2>/dev/null | grep -qxF "$WORKER_NAME"
}

# ---------------------------------------------------------------------------
# Inject helpers. Write action-log JSONL directly with jq — same shape
# as `cmd_log_action` produces. Skipping the verb avoids pulling in
# config/bot-identity surface; the watcher's classifier reads the raw
# JSONL identically either way.
# ---------------------------------------------------------------------------
inject_wrap_up() {
    local report
    report="nexus_$(date -u +%Y-%m-%d_%H%M%S)_${WORKER_NAME}.md"
    mkdir -p "$STATE_DIR"
    jq -cn \
        --arg ts "$(date -Is)" \
        --arg w "$WORKER_NAME" \
        --arg r "$report" \
        '{ts:$ts, agent:"monitor", event:"wrap-up", window:$w, report:$r}' \
        >> "$ACTION_LOG"
}

inject_retain() {
    mkdir -p "$STATE_DIR"
    jq -cn \
        --arg ts "$(date -Is)" \
        --arg w "$WORKER_NAME" \
        --arg reason "$RETAIN_REASON" \
        '{ts:$ts, agent:"monitor", event:"window-retain", window:$w, reason:$reason}' \
        >> "$ACTION_LOG"
}

# ---------------------------------------------------------------------------
# Phase 1: worker spawns busy. pane-state.sh recognises the spinner
# frame within ~3 s; give it 6 s of budget to absorb the cold-start gap
# between `tmux new-window` and the stub's first frame reaching the
# pty buffer.
# ---------------------------------------------------------------------------
echo
echo "=== phase 1: worker busy ==="
wait_for "pane-state reports busy" 6 -- pane_state_is busy

# ---------------------------------------------------------------------------
# Phase 2: stub clears the spinner, idle frame settles. ~3 s busy + a
# few hundred ms for the redraw to land + the next poll cadence.
# ---------------------------------------------------------------------------
echo
echo "=== phase 2: spinner clears → idle ==="
wait_for "pane-state reports idle after spinner clears" 8 -- pane_state_is idle

# ---------------------------------------------------------------------------
# Phase 3: idle-pool surfaces a `no-wrap-up` emit once age crosses
# threshold. With threshold=2 s and a 1 s poll cadence, this lands
# 2-3 polls after the stub goes idle.
# ---------------------------------------------------------------------------
echo
echo "=== phase 3: idle-pool surfaces no-wrap-up ==="
wait_for "watcher emits no-wrap-up row for $WORKER_NAME" \
    $(( SCENARIO_THRESHOLD_S + 8 )) -- \
    emits_contain "$WORKER_NAME idle"

# ---------------------------------------------------------------------------
# Phase 4: inject wrap-up action-log row. Next poll's classifier picks
# it up and the row reclassifies from `no-wrap-up` to `wrapped`.
# ---------------------------------------------------------------------------
echo
echo "=== phase 4: inject wrap-up → 'wrapped' emit ==="
inject_wrap_up
wait_for "watcher emits wrapped row for $WORKER_NAME" \
    $(( SCENARIO_INTERVAL_S * 6 )) -- \
    emits_contain "$WORKER_NAME wrapped up"

# ---------------------------------------------------------------------------
# Phase 5: inject window-retain action-log row with the same
# `wrap-up-YYYY-MM-DD` reason that `ng wrap-up`'s auto-retain stamps.
# Next poll the row goes from `wrapped` to `retained` and the
# `(N retained windows suppressed: ...)` footer renders with the
# reason in parens.
# ---------------------------------------------------------------------------
echo
echo "=== phase 5: inject window-retain → retained footer ==="
inject_retain
wait_for "watcher emits retained footer with $WORKER_NAME ($RETAIN_REASON)" \
    $(( SCENARIO_INTERVAL_S * 6 )) -- \
    emits_contain "$WORKER_NAME ($RETAIN_REASON)"
wait_for "retained footer header rendered" \
    $(( SCENARIO_INTERVAL_S * 4 )) -- \
    emits_contain "retained windows suppressed"

# ---------------------------------------------------------------------------
# Phase 6: operator-triggered close. `tmux kill-window` removes the
# worker from tmux's window list. The next poll's
# `_idle_list_worker_windows` doesn't enumerate it; the disappearance
# prune drops its engagement-log row; subsequent emits don't mention
# the window again.
# ---------------------------------------------------------------------------
echo
echo "=== phase 6: tmux kill-window → window absent ==="
"$HARNESS_TMUX" kill-window -t "${HARNESS_SESSION}:${WORKER_NAME}"
wait_for "worker window absent from tmux list-windows" 5 -- worker_window_absent

# Belt-and-suspenders: confirm the engagement-log row was pruned. The
# disappearance prune in `list_really_idle_workers` runs at the top of
# each cycle; give it a couple of polls to take effect.
engagement_row_pruned() {
    local elog="$STATE_DIR/engagement-log.tsv"
    [[ -f "$elog" ]] || return 0
    ! awk -F'\t' -v w="$WORKER_NAME" '$1 == w {found=1} END {exit !found}' \
        "$elog" >/dev/null 2>&1
}
wait_for "engagement-log row for $WORKER_NAME pruned after disappearance" \
    $(( SCENARIO_INTERVAL_S * 4 )) -- engagement_row_pruned

# ---------------------------------------------------------------------------
# Diagnostic dump on failure. Cheap when the test passes; precious on
# the next regression.
# ---------------------------------------------------------------------------
if (( FAIL > 0 )); then
    echo
    echo "=== diagnostic dump (failure path) ==="
    echo "--- list-windows ---"
    "$HARNESS_TMUX" list-windows -t "$HARNESS_SESSION" \
        -F '#{window_index}: #{window_name}' 2>/dev/null || true
    echo "--- action-log ---"
    cat "$ACTION_LOG" 2>/dev/null || echo "(no action-log)"
    echo "--- engagement-log ---"
    cat "$STATE_DIR/engagement-log.tsv" 2>/dev/null || echo "(no engagement-log)"
    echo "--- idle-state ---"
    cat "$STATE_DIR/idle-state.tsv" 2>/dev/null || echo "(no idle-state)"
    echo "--- diffs ---"
    ls -la "$DIFF_DIR/" 2>/dev/null || echo "(no diffs)"
    echo "--- archived emits (last 3) ---"
    if [[ -d "$DIFF_DIR" ]]; then
        ls -t "$DIFF_DIR/"*.md 2>/dev/null | head -3 | while read -r f; do
            echo "--- $f ---"
            cat "$f"
        done
    fi
    echo "--- watcher log (tail 100) ---"
    tail -100 "$WATCHER_LOG" 2>/dev/null || echo "(no log)"
fi

th_summary_and_exit
