#!/usr/bin/env bash
# monitor/cc-restart-watchdog-loop.sh — the deterministic watch loop the
# cc-update restart watchdog runs (GUIDE Step 5b, shipped as a repo file
# so the autonomous routine and manual evaluators run the SAME audited
# loop instead of re-adapting the skill's inline listing each time).
#
# Usage: NEXUS_ROOT=<abs-path> [CC_AUTO_TARGET_WINDOW=<name>] \
#            [WATCHDOG_DEADLINE_SECONDS=180] \
#            monitor/cc-restart-watchdog-loop.sh
#        (or pass the root as $1)
#
# The coordinator window this loop watches is resolved exactly as
# cc-auto-update-apply.sh resolves its TARGET_WINDOW. apply.sh also passes the
# window it already resolved via CC_AUTO_TARGET_WINDOW (rendered into the
# watchdog prompt), so the two can never disagree.
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
# Resolve the coordinator window NAME exactly as cc-auto-update-apply.sh's
# TARGET_WINDOW does: CC_AUTO_TARGET_WINDOW → MONITOR_TARGET env → config
# `monitor.target_window` → literal `orchestrator`. The config leg is
# load-bearing: #428 added it to apply.sh but left this sibling hard-coded, so
# on a nexus that sets `monitor.target_window: claude` the baseline's
# `tmux list-panes -t orchestrator` found nothing, the loop died before writing
# the armed marker, and apply.sh aborted the whole restart at
# `watchdog-never-armed` after burning its 600s ARM_WAIT (#459). The bug is
# invisible to any nexus whose window happens to be named `orchestrator`.
TARGET="${CC_AUTO_TARGET_WINDOW:-${MONITOR_TARGET:-$("$NEXUS_ROOT/config/load.sh" monitor.target_window orchestrator 2>/dev/null || echo orchestrator)}}"
SLUG=$(printf '%s' "$NEXUS_ROOT" | sed 's|[^a-zA-Z0-9]|-|g')
PROJECTS_DIR="${CC_AUTO_PROJECTS_DIR:-$HOME/.claude/projects}"
DEADLINE=$(( $(date +%s) + ${WATCHDOG_DEADLINE_SECONDS:-180} ))
LOG="$STATE/restart-watchdog.log"

# `_ensure_service_log` (your-org/nexus-code#484): `tee -a` creates the
# log under the ambient umask (0660 — group-writable) exactly as a bare
# `>>` would. Set the mode once, here, before the first note() lands.
# shellcheck source=_log-mode.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_log-mode.sh"
mkdir -p "$STATE" 2>/dev/null || true
_ensure_service_log "$LOG"

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
#
# Hardened against jsonl flush-visibility lag (your-org/nexus-code#532).
# On a large session jsonl (~1.1 GB), `--resume` replays a big context and
# the append is not durably visible to THIS independent poller until well
# after the records' internal event-timestamps. The old fixed-deadline poll
# false-negatived the 2.1.212 bump: the version records were on disk
# ~90-120 s before the 180 s deadline yet the poll declared FAIL, which is
# the trigger for a diagnose-and-fix path — burning attention on a healthy
# bump and inviting a "fix" against a workspace that needs none. Three
# hardenings, none of which weaken the success criterion (a fresh
# candidate-version record is still required to declare success):
#   1. GRACE window — keep polling for WATCHDOG_GRACE_SECONDS past the
#      deadline, so a flush that lands seconds late still counts. A single
#      grace read would have flipped 2.1.212 to SUCCESS. We are already
#      past the respawn gate here, so a new orchestrator pane provably
#      exists and the sid is unchanged — the only open question is whether
#      the candidate-version stamp has become visible yet, which makes a
#      generous grace low-risk.
#   2. Per-poll diagnostics to the log (size, growth-past-baseline, time
#      left) so the NEXT occurrence is diagnosable from the log instead of
#      requiring live forensics.
#   3. Growth-aware verdict — file grew past baseline but no candidate
#      stamp within grace ⇒ "resumed on the OLD binary / wedged resume";
#      never grew ⇒ "never resumed". The old message conflated the two.
GRACE_SECONDS="${WATCHDOG_GRACE_SECONDS:-60}"
VDEADLINE=$(( DEADLINE + GRACE_SECONDS ))
last_size=$base_size
diag() { printf '%s poll: %s\n' "$(date -Is)" "$*" >> "$LOG" 2>/dev/null || true; }
while :; do
    tail -c +$(( base_size + 1 )) "$jsonl" 2>/dev/null \
        | grep -qF "\"version\":\"$candidate\"" && break
    now=$(date +%s)
    cur_size=$(stat -c%s "$jsonl" 2>/dev/null || echo "$last_size")
    (( cur_size > last_size )) && last_size=$cur_size
    diag "size=$cur_size (+$(( last_size - base_size )) past baseline) version=$candidate not-yet-visible; $(( VDEADLINE - now ))s to deadline"
    if (( now > VDEADLINE )); then
        if (( last_size > base_size )); then
            fail "jsonl grew +$(( last_size - base_size )) bytes past baseline but no \"version\":\"$candidate\" record became visible within ${GRACE_SECONDS}s grace past the deadline — resumed on the OLD binary, or a wedged resume writing non-version records (size=$last_size)"
        else
            fail "no fresh jsonl record and the file never grew past baseline ($base_size bytes) after deadline+${GRACE_SECONDS}s grace — the orchestrator never resumed (cold spawn, or wedged before its first write)"
        fi
    fi
    sleep 2
done

note "SUCCESS: sid=$sid resumed on $candidate; single window; watcher alive"
command -v sandbox-notify >/dev/null 2>&1 \
    && sandbox-notify "cc-update self-restart verified: orchestrator on $candidate"
rm -f "$STATE/restart-watchdog-armed"
exit 0
