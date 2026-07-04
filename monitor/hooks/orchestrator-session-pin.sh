#!/usr/bin/env bash
# monitor/hooks/orchestrator-session-pin.sh
#
# Claude Code UserPromptSubmit-hook handler. Pins the orchestrator's
# session-id to `monitor/.state/orchestrator-session-id` so that
# `monitor/watcher/entry.sh`'s post-restart launch can target THIS
# session specifically via `claude --resume <id>` instead of falling
# back to `claude --continue`, which resolves to "the most-recently-
# written jsonl in this project" — nondeterministic when concurrent
# workers share the project slug, and known to resume the wrong
# session (incident: 2026-05-20 17:51 PT, where the release-ship
# worker's jsonl was newer than the orchestrator's at restart time).
#
# Wired only from `monitor/orchestrator-settings.json` (which entry.sh
# passes to claude via `--settings`). Workers use the separate
# `monitor/worker-settings.json`, so this never fires from a worker.
#
# Atomic write: temp file in the same dir + rename, so a torn write
# never leaves a half-baked id in place.
#
# UserPromptSubmit is chosen over SessionStart because it fires on
# every turn, including the first turn after a `/clear` (which Claude
# Code internally treats as a new session with a new session_id).
# Re-writing the same id on every turn is idempotent and ~milliseconds.
#
# Hot-path discipline: exit 0 on any failure. The hook runs
# synchronously on claude's turn — a non-zero exit or hang would
# block the agent.

set -u

# Read payload first so a missing stdin doesn't hang.
payload=$(cat 2>/dev/null || true)

root="${NEXUS_ROOT:-}"
if [[ -z "$root" ]]; then
    # Fallback resolver: script lives at $root/monitor/hooks/.
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null) || exit 0
    root=$(cd "$script_dir/../.." && pwd 2>/dev/null) || exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

session_id=$(jq -r '.session_id // ""' <<<"$payload" 2>/dev/null || printf '')
# UUID shape guard: only pin canonical 8-4-4-4-12 hex ids. A malformed
# payload (e.g. empty string from a hook-schema change) must not blow
# away a known-good pin from a prior turn.
[[ "$session_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || exit 0

dest_dir="$root/monitor/.state"
dest="$dest_dir/orchestrator-session-id"
mkdir -p "$dest_dir" 2>/dev/null || exit 0

tmp="$dest_dir/.orchestrator-session-id.$$.tmp"
printf '%s\n' "$session_id" > "$tmp" 2>/dev/null || { rm -f "$tmp"; exit 0; }
mv -f "$tmp" "$dest" 2>/dev/null || rm -f "$tmp"

# Self-rename the hosting tmux window to the watcher's configured
# target window and disable tmux's automatic-rename so the running
# command (claude, bash, etc.) can't mutate it back. Idempotent:
# cheap to run on every turn.
#
# The name comes from NEXUS_ORCHESTRATOR_WINDOW — exported by the
# orchestrator's launch paths (entry.sh, _respawn.sh's launcher)
# from their already-resolved $TARGET, so the rename always agrees
# with whatever `monitor.target_window` / `--target` the watcher is
# actually polling. Falls back to "orchestrator" (the config
# default) for sessions launched before the env var existed.
# Renaming to a hardcoded "orchestrator" here while the watcher
# targets something else is the exact crash-loop in
# your-org/nexus-code issue 209: the watcher loses its target window
# seconds after every spawn and respawns until the loop guard trips.
#
# Two reasons this lives here rather than at watcher-spawn time:
#   1. Robustness — if a leftover stale-named window survives an
#      operator upgrade (stale tmux session, pre-rename watcher
#      restart), the orchestrator's first post-upgrade turn corrects
#      the name in place. No manual `tmux rename-window` needed.
#   2. automatic-rename — tmux defaults to renaming a window after
#      the running command's process name. Without `automatic-rename
#      off`, the window can flip back to e.g. "node" / "bash" on
#      every command transition, which historically caused phantom
#      transient `claude` windows to reappear and confuse the
#      watcher's window-name targeting.
#
# Gated on `NEXUS_IS_ORCHESTRATOR=1` — an env-var marker the
# orchestrator's two launch paths (`monitor/watcher/entry.sh` and
# `monitor/watcher/spawn-fresh-orchestrator.sh`) export into their
# launcher heredocs before `exec claude`. Workers, watcher panes,
# test scripts, and any other ad-hoc invocation lack the marker, so
# the rename is a no-op there. Real incident, 2026-05-21: an
# earlier ungated version of this rename renamed a worker's pane
# during `bash monitor/watcher/test-orchestrator-session-pin.sh` —
# the test piped a synthetic payload to the hook, the hook read
# `$TMUX_PANE` from the test runner's env, and renamed the worker
# window the test was running in. The marker keeps the side effects
# strictly inside the orchestrator's Claude Code session.
#
# Failures here are non-fatal (no tmux, no TMUX_PANE, etc.) — never
# block the orchestrator's turn over a cosmetic rename.
if [[ "${NEXUS_IS_ORCHESTRATOR:-0}" == "1" \
      && -n "${TMUX_PANE:-}" ]] \
   && command -v tmux >/dev/null 2>&1; then
    tmux rename-window -t "$TMUX_PANE" "${NEXUS_ORCHESTRATOR_WINDOW:-orchestrator}" 2>/dev/null || true
    tmux set-window-option -t "$TMUX_PANE" automatic-rename off 2>/dev/null || true
    tmux set-window-option -t "$TMUX_PANE" allow-rename off 2>/dev/null || true
fi

exit 0
