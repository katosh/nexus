#!/usr/bin/env bash
# monitor/hooks/decision-mark-unresolved.sh
#
# Claude Code Stop-hook handler. Walks every decision file for this
# worker's tmux window and adds `unresolved: true` to ones still
# present at turn-end. The orchestrator removes a file when it
# answers the prompt (paste-decided or escalated); a file lingering
# past the worker's Stop event means the prompt was never acted on,
# so the watcher's next emit will surface it more loudly.
#
# Skipped:
#   - already-marked files (idempotent across multiple turn-ends)
#   - `*.handled.json` tombstones (orchestrator opted to keep a
#     historical audit copy after answering)
#
# Required env (exported by spawn-worker.sh):
#   NEXUS_ROOT           absolute path to the primary nexus clone
#   NEXUS_WORKER_WINDOW  tmux window name this worker was spawned into
#
# Stop fires per agent turn-end. Hot-path discipline: the loop is
# bounded by the number of pending decisions for this one window
# (typically 0 or 1), each iteration is one jq + one mv.

set -u

window="${NEXUS_WORKER_WINDOW:-}"
root="${NEXUS_ROOT:-}"

if [[ -z "$window" ]] || [[ -z "$root" ]]; then
    exit 0
fi

dest_dir="$root/monitor/.state/decisions"
[[ -d "$dest_dir" ]] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

shopt -s nullglob
for f in "$dest_dir/$window".*.json; do
    # Skip handled tombstones — they're already terminal.
    case "$f" in
        *.handled.json) continue ;;
    esac
    # Idempotent: don't re-mark.
    if jq -e '.unresolved == true' "$f" >/dev/null 2>&1; then
        continue
    fi
    tmp="$f.tmp.$$"
    if jq -c '. + {unresolved: true}' "$f" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi
done
exit 0
