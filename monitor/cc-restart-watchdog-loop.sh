#!/usr/bin/env bash
# monitor/cc-restart-watchdog-loop.sh — the deterministic watch loop the
# cc-update restart watchdog runs (GUIDE Step 5b, shipped as a repo file
# so the autonomous routine and manual evaluators run the SAME audited
# loop instead of re-adapting the skill's inline listing each time).
#
# Usage: NEXUS_ROOT=<abs-path> [WATCHDOG_DEADLINE_SECONDS=180] \
#            monitor/cc-restart-watchdog-loop.sh
#        (or pass the root as $1)
#
# Contract (see skills/nexus.cc-update/GUIDE.md "The restart watchdog"):
#   - records the baseline (candidate, orchestrator pid, watcher pid,
#     pinned sid, jsonl byte offset), THEN writes the armed marker —
#     the orchestrator-kill fires only after that marker exists;
#   - waits for the old pane to die and a new orchestrator window;
#   - verifies: exactly ONE orchestrator window, no stand-down window,
#     the watcher survived, the session pin unchanged, and a FRESH
#     jsonl record (past the baseline offset) stamped with the
#     candidate version — POLLED to the deadline, never one-shot (the
#     dying orchestrator keeps writing old-binary records for ~30s;
#     the 2026-06-03 cc-2.1.161 false negative);
#   - exit 0 on verified success (marker removed), exit 1 on failure
#     (failure marker written; the supervising agent diagnoses and
#     FIXES, then re-runs this loop).
#
# Deliberately contains NO pattern-based process kill (and no kill at
# all): observation only. See monitor/cc-harness/lint-no-mass-kill.sh.

set -uo pipefail
NEXUS_ROOT="${NEXUS_ROOT:-${1:-}}"
[[ -n "$NEXUS_ROOT" && -d "$NEXUS_ROOT" ]] || {
    echo "cc-restart-watchdog-loop: NEXUS_ROOT required (env or \$1)" >&2
    exit 2
}
STATE="${NEXUS_STATE_DIR:-$NEXUS_ROOT/monitor/.state}"
TARGET="${CC_AUTO_TARGET_WINDOW:-orchestrator}"
SLUG=$(printf '%s' "$NEXUS_ROOT" | sed 's|[^a-zA-Z0-9]|-|g')
PROJECTS_DIR="${CC_AUTO_PROJECTS_DIR:-$HOME/.claude/projects}"
DEADLINE=$(( $(date +%s) + ${WATCHDOG_DEADLINE_SECONDS:-180} ))
LOG="$STATE/restart-watchdog.log"

note() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }
fail() {
    note "FAIL: $*"
    command -v sandbox-notify >/dev/null 2>&1 \
        && sandbox-notify "cc-update self-restart FAILED: $*"
    date -Is > "$STATE/restart-watchdog-failed"
    exit 1
}

# 1. baseline
candidate=$("$NEXUS_ROOT/node_modules/.bin/claude" --version \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
orch_pid=$(tmux list-panes -t "$TARGET" -F '#{pane_pid}' | head -1)
watcher_pid=$(cat "$STATE/watcher.pid" 2>/dev/null || true)
sid=$(tr -d '[:space:]' < "$STATE/orchestrator-session-id")
jsonl="$PROJECTS_DIR/$SLUG/$sid.jsonl"
base_size=$(stat -c%s "$jsonl") || fail "pinned jsonl missing — pin stale, ABORT (do not kill)"
[[ -n "$candidate" && -n "$orch_pid" ]] || fail "baseline incomplete (candidate=$candidate orch_pid=$orch_pid)"
note "armed: candidate=$candidate orch_pid=$orch_pid watcher_pid=${watcher_pid:-?} sid=$sid jsonl=$base_size bytes"

# 2. armed — the kill may fire once this file exists
date -Is > "$STATE/restart-watchdog-armed"

# 3. wait: old pane dies, then a new orchestrator window appears
while kill -0 "$orch_pid" 2>/dev/null; do
    (( $(date +%s) > DEADLINE )) && fail "orchestrator was never killed"
    sleep 2
done
note "old orchestrator pid $orch_pid gone; waiting for the watcher respawn"
while :; do
    (( $(date +%s) > DEADLINE )) && fail "no respawn before deadline — read $STATE/watcher.log (re-verify abort? crash-loop?); manual recovery: monitor/watcher/spawn-fresh-orchestrator.sh"
    new_pid=$(tmux list-panes -t "$TARGET" -F '#{pane_pid}' 2>/dev/null | head -1)
    [[ -n "${new_pid:-}" && "$new_pid" != "$orch_pid" ]] && break
    sleep 2
done
note "new orchestrator pane pid $new_pid"

# 4. verify
n=$(tmux list-windows -F '#{window_name}' | grep -cx "$TARGET")
(( n == 1 )) || fail "$n $TARGET windows — duplicate respawn (PR 214 class)"
tmux list-windows -F '#{window_name}' | grep -qi standdown \
    && fail "stand-down window present — duplicate respawn occurred"
if [[ -n "${watcher_pid:-}" ]]; then
    kill -0 "$watcher_pid" 2>/dev/null \
        || fail "watcher died — relaunch: monitor/watcher/launcher.sh --target $TARGET"
fi
[[ "$(tr -d '[:space:]' < "$STATE/orchestrator-session-id")" == "$sid" ]] \
    || fail "session pin changed — cold spawn, context LOST; point the new orchestrator at the latest reports/"
# Grow-gate + new-binary check collapsed into ONE race-free poll: a
# FRESH record (past the baseline offset) stamped with the candidate
# version proves BOTH a context-preserving resume AND the new binary.
while :; do
    (( $(date +%s) > DEADLINE )) && fail "no fresh jsonl record stamped version=$candidate before deadline — cold spawn, wedged resume, or resumed on the OLD binary"
    tail -c +$(( base_size + 1 )) "$jsonl" 2>/dev/null \
        | grep -qF "\"version\":\"$candidate\"" && break
    sleep 2
done

note "SUCCESS: sid=$sid resumed on $candidate; single window; watcher alive"
command -v sandbox-notify >/dev/null 2>&1 \
    && sandbox-notify "cc-update self-restart verified: orchestrator on $candidate"
rm -f "$STATE/restart-watchdog-armed"
exit 0
