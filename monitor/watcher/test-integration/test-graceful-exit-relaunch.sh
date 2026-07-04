#!/usr/bin/env bash
# Integration scenario: graceful claude exit → operator (or loop
# wrapper) relaunches.
#
# Pass B scenario 3/4 for your-org/nexus-code#78. Exercises the
# tmux `remain-on-exit on` + manual-relaunch path that production
# `spawn-worker.sh` already wires (default branch), plus the
# `monitor/claude-loop.sh` opt-in wrapper from PR `#82` that
# auto-recycles `claude --continue` against the same window as long
# as a `window-retain` action-log row keeps the lifecycle live.
#
# Two failure modes this catches in lockstep with `pane-state.sh`'s
# liveness gate:
#
#   1. A stub claude that exits cleanly mid-busy without clearing the
#      pane leaves the spinner + chevron in tmux's capture buffer;
#      `_detect_busy` then keeps reporting `state=busy` against a
#      dead pane. The stub's `EXIT_AFTER_BUSY=1` branch clears the
#      pane to mirror real claude's exit prompt — this scenario asserts
#      `state=absent` on the cleared dead pane, locking that contract
#      in.
#   2. The loop wrapper's `--retain-ttl-seconds` + `--max-restarts` +
#      stop-sentinel gates must close cleanly. We seed a `window-retain`
#      row, let the wrapper recycle once, then drop the stop sentinel
#      so the loop terminates on intent rather than racing teardown.
#
# Flow:
#
#   Phase A — production default (remain-on-exit on, no wrapper)
#     1. Spawn stub: BUSY=3 EXIT_AFTER_BUSY=1
#     2. Set `remain-on-exit on` (matches spawn-worker.sh:318)
#     3. wait_for state=busy            (3 s window)
#     4. wait_for state=absent          (claude exited clean)
#     5. window still listed            (remain-on-exit preserved pane)
#     6. respawn-pane runs stub again   (operator relaunch)
#     7. wait_for state=busy            (worker is back)
#
#   Phase B — loop-wrapper auto-recycle (issue #75 / PR #82)
#     1. Inject `window-retain` action-log row.
#     2. Spawn launcher: claude-loop.sh wrapping the stub
#        (BUSY=2 EXIT_AFTER_BUSY=1, backoff_base=1).
#     3. wait_for state=busy            (first claude run)
#     4. wait_for restart log line      (wrapper observed exit + slept)
#     5. wait_for state=busy            (second claude run, auto-relaunch)
#     6. window still listed.
#     7. assert action-log retain row unchanged (the recycle didn't
#        clobber the lifecycle anchor).
#     8. Drop the stop-sentinel so the wrapper exits cleanly on its
#        next iteration rather than racing teardown.
#
# Run:
#   RUN_INTEGRATION=1 bash monitor/watcher/test-integration/test-graceful-exit-relaunch.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_harness.sh
. "$_self_dir/_harness.sh"
# shellcheck source=../_test_helpers.sh
. "$_self_dir/../_test_helpers.sh"

harness_skip_if_disabled
harness_setup

echo "=== harness ==="
echo "  HARNESS_DIR=$HARNESS_DIR"
echo "  HARNESS_SESSION=$HARNESS_SESSION"
echo "  HARNESS_SOCKET=$HARNESS_SOCKET"

# Predicates. Defined as functions so wait_for can call them without
# losing the harness env (shell functions don't survive `bash -c`).
pane_state_is() {
    local win="$1" expected="$2"
    local out
    out=$(PATH="$HARNESS_BIN:$PATH" \
        "$HARNESS_REPO_ROOT/monitor/pane-state.sh" \
        "${HARNESS_SESSION}:${win}" 2>/dev/null) || return 1
    grep -q "state=${expected}" <<<"$out"
}

window_exists() {
    local win="$1"
    "$HARNESS_TMUX" list-windows -t "$HARNESS_SESSION" \
        -F '#{window_index}' 2>/dev/null | grep -qxF "$win"
}

# ---------------------------------------------------------------------------
# Phase A: production default — remain-on-exit + manual relaunch.
# ---------------------------------------------------------------------------
echo
echo "=== phase A: graceful exit → remain-on-exit → operator relaunch ==="
winA=$(harness_spawn_worker graceful-exit-A \
    "STUB_CLAUDE_BUSY_SECONDS=3" \
    "STUB_CLAUDE_HOLD_SECONDS=20" \
    "STUB_CLAUDE_EXIT_AFTER_BUSY=1")
[[ "$winA" =~ ^[0-9]+$ ]] || {
    echo "  FAIL: spawn returned non-numeric window index: $winA" >&2
    th_summary_and_exit
}
echo "  spawned phase-A worker at window=$winA"

# Mirror spawn-worker.sh:318. The harness's `harness_spawn_worker`
# doesn't set this option by default — production sets it on every
# spawn so a graceful claude exit leaves the pane scroll-readable
# instead of tearing the window down.
harness_tmux set-window-option -t "${HARNESS_SESSION}:${winA}" \
    remain-on-exit on

wait_for "phase A: state=busy during stub spinner" 6 -- \
    pane_state_is "$winA" busy

# The stub exits after 3 s of busy. With `remain-on-exit on` and the
# pane cleared by the stub's EXIT_AFTER_BUSY branch, the dead pane has
# no chevron + no live claude → `state=absent`. Generous budget (10 s)
# accounts for the busy phase still in progress when this wait starts.
wait_for "phase A: state=absent after graceful claude exit" 10 -- \
    pane_state_is "$winA" absent
wait_for "phase A: window still listed (remain-on-exit preserved pane)" 2 -- \
    window_exists "$winA"

# Operator relaunch. `respawn-pane -k` kills any leftover proc in the
# pane slot and starts a fresh command — the manual recovery surface
# the issue body sketch calls out. -c re-sets the workdir for the new
# process. Force PATH so the stub resolves to our shim (the session
# env from setenv -g is unreliable across windows; see the note in
# harness_spawn_worker).
echo
echo "=== phase A: operator relaunch via respawn-pane ==="
harness_tmux respawn-pane -k -t "${HARNESS_SESSION}:${winA}" \
    "exec env PATH=$HARNESS_BIN:\$PATH STUB_CLAUDE_BUSY_SECONDS=8 STUB_CLAUDE_HOLD_SECONDS=20 $HARNESS_BIN/claude"
wait_for "phase A: state=busy after operator relaunch" 8 -- \
    pane_state_is "$winA" busy

# Clean up phase A before phase B brings up its own window.
harness_tmux kill-window -t "${HARNESS_SESSION}:${winA}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Phase B: loop-wrapper auto-recycle. Pairs with PR #82's substrate;
# validates that a graceful claude exit + a fresh `window-retain` row
# is enough for the wrapper to bring claude back without operator
# intervention, AND that the recycle doesn't clobber the lifecycle
# anchor the watcher's wrap-up matcher will key on.
# ---------------------------------------------------------------------------
echo
echo "=== phase B: loop wrapper auto-recycles claude ==="

LOOP_STATE_DIR="$HARNESS_DIR/monitor/.state"
ACTION_LOG="$LOOP_STATE_DIR/action-log.jsonl"
mkdir -p "$LOOP_STATE_DIR"

# Inject the retain row BEFORE the wrapper boots: its first
# post-claude-exit gate consults `_latest_retain_epoch` and bails
# (`no-retain-event`) if the row is missing. Use jq when available
# (matches the format the production wrap-up path emits); regex
# fallback otherwise.
RETAIN_NOTE="phase-B-test"
if command -v jq >/dev/null 2>&1; then
    jq -cn --arg ts "$(date -Is)" --arg w "graceful-exit-B" --arg note "$RETAIN_NOTE" \
        '{ts:$ts, agent:"monitor", event:"window-retain", window:$w, note:$note}' \
        >> "$ACTION_LOG"
else
    printf '{"ts":"%s","agent":"monitor","event":"window-retain","window":"graceful-exit-B","note":"%s"}\n' \
        "$(date -Is)" "$RETAIN_NOTE" >> "$ACTION_LOG"
fi
retain_row_before=$(grep '"window":"graceful-exit-B"' "$ACTION_LOG" 2>/dev/null | tail -1)

PROMPT_TMP="$HARNESS_DIR/loop-prompt.txt"
echo "phase B test prompt — graceful-exit-relaunch" > "$PROMPT_TMP"
LOOP_STDERR="$HARNESS_DIR/loop-stderr.log"

# Launcher: ensures PATH includes $HARNESS_BIN so claude-loop.sh's bare
# `claude` invocation resolves to the stub. The wrapper's stderr is
# redirected to a file so the pane stays clean for state assertions —
# the wrapper's `restart #N` log line is the signal we grep for.
LOOP_LAUNCHER="$HARNESS_DIR/loop-launcher-B.sh"
cat > "$LOOP_LAUNCHER" <<LAUNCHER
#!/usr/bin/env bash
export PATH="$HARNESS_BIN:\$PATH"
export STUB_CLAUDE_BUSY_SECONDS=2
export STUB_CLAUDE_HOLD_SECONDS=0
export STUB_CLAUDE_EXIT_AFTER_BUSY=1
export NEXUS_ROOT="$HARNESS_DIR"
exec "$HARNESS_REPO_ROOT/monitor/claude-loop.sh" \\
    --window graceful-exit-B \\
    --prompt-file "$PROMPT_TMP" \\
    --state-dir "$LOOP_STATE_DIR" \\
    --backoff-base 1 \\
    --max-restarts 3 \\
    --retain-ttl-seconds 600 \\
    2>>"$LOOP_STDERR"
LAUNCHER
chmod +x "$LOOP_LAUNCHER"

harness_tmux new-window -d \
    -t "${HARNESS_SESSION}:" \
    -n graceful-exit-B \
    -c "$HARNESS_DIR" \
    "$LOOP_LAUNCHER"
harness_tmux set-window-option -t "${HARNESS_SESSION}:graceful-exit-B" \
    remain-on-exit on

winB=$("$HARNESS_TMUX" list-windows -t "$HARNESS_SESSION" \
    -F '#{window_name} #{window_index}' \
    | awk '$1=="graceful-exit-B" {print $2; exit}')
[[ "$winB" =~ ^[0-9]+$ ]] || {
    echo "  FAIL: phase B spawn returned non-numeric window index: $winB" >&2
    th_summary_and_exit
}
echo "  spawned phase-B worker at window=$winB"

# First claude run, busy spinner rendering. Budget covers the wrapper's
# startup overhead + the stub reaching its first render.
wait_for "phase B: state=busy on first claude invocation" 8 -- \
    pane_state_is "$winB" busy

# Wrapper observes the stub exit, checks the retain row (present), sleeps
# backoff (~1 s), restarts. The `restart #1` line is the canonical
# signal — it only fires once the wrapper has cleared all gates and is
# about to exec claude again. Budget covers BUSY + backoff + slack.
wait_for "phase B: wrapper recorded restart #1 in stderr log" 12 -- \
    grep -qF "claude-loop: restart #1" "$LOOP_STDERR"

# Second claude run lights up the spinner again. Same budget shape as
# the first wait_for — backoff + stub startup + render.
wait_for "phase B: state=busy after wrapper auto-relaunched claude" 8 -- \
    pane_state_is "$winB" busy
wait_for "phase B: window still listed after recycle" 2 -- \
    window_exists "$winB"

# Lifecycle-anchor invariant. The watcher's wrap-up matcher scopes
# `window-retain` rows by ts; a graceful-exit recycle inside the SAME
# window must not rewrite or append a second retain row, or the
# matcher would mistake the recycle for a new lifecycle.
retain_row_after=$(grep '"window":"graceful-exit-B"' "$ACTION_LOG" 2>/dev/null | tail -1)
retain_row_count=$(grep -c '"window":"graceful-exit-B"' "$ACTION_LOG" 2>/dev/null || echo 0)
assert_eq "phase B: action-log retain row unchanged across recycle" \
    "$retain_row_after" "$retain_row_before"
assert_eq "phase B: action-log retain-row count stays at 1" \
    "$retain_row_count" "1"

# Cleanup. Drop the stop-sentinel BEFORE killing the window so the
# wrapper exits via stop_reason=sentinel (clean rc=0) rather than via
# SIGHUP — keeps any future shellcheck-against-the-wrapper-log scenario
# honest. The sentinel is consumed by the wrapper on observation.
echo
echo "=== phase B: tear down via stop-sentinel ==="
SENTINEL_DIR="$LOOP_STATE_DIR/loop-stop"
mkdir -p "$SENTINEL_DIR"
touch "$SENTINEL_DIR/graceful-exit-B.flag"
# Give the wrapper one poll cycle to observe the sentinel before we
# tear the window out. Short — the wrapper checks the sentinel at the
# top of every loop iteration.
sleep 1
harness_tmux kill-window -t "${HARNESS_SESSION}:${winB}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Diagnostic dump on failure. Cheap when everything passes; precious on
# the next regression.
# ---------------------------------------------------------------------------
if (( FAIL > 0 )); then
    echo
    echo "=== diagnostic dump (failure path) ==="
    echo "--- list-windows ---"
    "$HARNESS_TMUX" list-windows -t "$HARNESS_SESSION" \
        -F '#{window_index}: #{window_name}' || true
    echo "--- action-log ---"
    cat "$ACTION_LOG" 2>/dev/null || echo "(no action-log)"
    echo "--- loop stderr (tail 60) ---"
    tail -60 "$LOOP_STDERR" 2>/dev/null || echo "(no loop log)"
    echo "--- phase-A capture (if window still alive) ---"
    harness_capture "$winA" 2>/dev/null | sed -n '1,30p' | cat -v || true
fi

th_summary_and_exit
