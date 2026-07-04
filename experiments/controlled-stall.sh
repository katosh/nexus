#!/usr/bin/env bash
# experiments/controlled-stall.sh — a deterministic, reproducible
# stalled-worker fixture for the stall-detection work.
#
# The motivating incident was a random API 500 mid-turn. We do NOT want
# to wait for a random 500 to develop/verify the detector, so this
# fixture MANUFACTURES the same end-state on demand: a Claude Code turn
# that dies to a model error fires the `StopFailure` hook (verified:
# a clean turn fires Stop; a failed turn fires StopFailure, never Stop),
# which runs the REAL `monitor/hooks/turn-failure-emit.sh` and writes a
# real `turn-failure/<window>.json` marker. We then run the REAL
# `list_really_idle_workers` classifier against that marker and confirm
# it emits `interrupted` (with the right recovery verb) instead of the
# false "no-wrap-up" nag.
#
# End-to-end chain exercised:
#   claude -p (bogus model) → StopFailure hook → turn-failure-emit.sh
#     → real marker on disk → _idle_probe classifier → `interrupted`
#
# Self-contained: hermetic temp state dir, throwaway settings, no live
# worker touched, no tmux server needed (the failed headless turn writes
# the marker; the classifier is driven with a stub tmux/pane-state
# reporting the window idle — exactly the post-crash pane shape).
#
# Run: bash experiments/controlled-stall.sh
# Expected: "CONTROLLED STALL DETECTED" + exit 0.

set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v claude >/dev/null 2>&1 || { echo "claude not on PATH" >&2; exit 2; }
command -v jq     >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR"
WINDOW="controlled-stall-fixture"

# Settings wiring the REAL StopFailure handlers (over-limit + turn-
# failure), keyed on our hermetic state dir + window. The hook reads
# NEXUS_STATE_DIR / NEXUS_WORKER_WINDOW from claude's inherited env.
cat > "$WORK/settings.json" <<EOF
{
  "hooks": {
    "StopFailure": [
      { "hooks": [
        { "type": "command", "command": "$repo_root/monitor/hooks/over-limit-emit.sh" },
        { "type": "command", "command": "$repo_root/monitor/hooks/turn-failure-emit.sh" }
      ] }
    ]
  }
}
EOF

echo "=== [1/3] driving a turn into StopFailure (bogus model) ==="
marker="$STATE_DIR/turn-failure/$WINDOW.json"
# Retry once: the FIRST headless run in a fresh cwd may spend its turn
# resolving project MCP servers instead of hitting the model error, so
# no StopFailure fires. The second run is warm and deterministic.
for attempt in 1 2; do
    NEXUS_STATE_DIR="$STATE_DIR" NEXUS_WORKER_WINDOW="$WINDOW" NEXUS_ROOT="$repo_root" \
        timeout 90 claude -p "say pong" \
            --model claude-bogus-stall-fixture-9 \
            --settings "$WORK/settings.json" >/dev/null 2>&1
    [[ -f "$marker" ]] && break
    echo "    attempt $attempt: no marker yet (cold MCP resolve?); retrying"
done
echo "    turn returned (headless process exits; in a live worker it stays idle-alive)"

if [[ ! -f "$marker" ]]; then
    echo "FAIL: no turn-failure marker written by the real hook" >&2
    exit 1
fi
echo "=== [2/3] real hook wrote a marker ==="
jq . "$marker"
category=$(jq -r .category "$marker")
recovery=$(jq -r .recovery "$marker")

echo "=== [3/3] real classifier sees the marker → interrupted ==="
# Stub tmux + pane-state to present the crashed window as idle/empty
# with claude alive — the exact post-crash pane shape. The marker is
# the REAL one the hook just wrote.
STUB="$WORK/bin"; mkdir -p "$STUB" "$WORK/monitor"
cat > "$STUB/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in list-windows) printf '%s\n' "${MOCK_TMUX_WINDOWS:-}";; *) :;; esac
exit 0
STUB
chmod +x "$STUB/tmux"
cat > "$STUB/pane-state.sh" <<'STUB'
#!/usr/bin/env bash
win="${1:-}"; while [[ "$win" == --* ]]; do shift 2 2>/dev/null || break; win="${1:-}"; done
printf 'state=idle\n'   # post-crash pane: empty box, claude alive
STUB
chmod +x "$STUB/pane-state.sh"
cp "$STUB/pane-state.sh" "$WORK/monitor/pane-state.sh"

OLD_TS=$(( $(date +%s) - 120 ))   # above the 60s idle threshold
printf '%s\t%s\n' "$WINDOW" "$OLD_TS" > "$STATE_DIR/engagement-log.tsv"

out=$(PATH="$STUB:$PATH" MOCK_TMUX_WINDOWS="$WINDOW|$OLD_TS" bash -c "
    set -uo pipefail
    STATE_DIR='$STATE_DIR'; NEXUS_ROOT='$WORK'
    source '$repo_root/monitor/watcher/_idle_probe.sh'
    list_really_idle_workers" 2>/dev/null)

echo "    classifier output: $out"
if grep -qF $'\tinterrupted\t' <<<"$out" && grep -qF "$category:$recovery" <<<"$out"; then
    echo
    echo "CONTROLLED STALL DETECTED — class=interrupted detail=$category:$recovery"
    echo "(a random API 500 would have produced category=transient recovery=paste)"
    exit 0
else
    echo "FAIL: classifier did not emit interrupted for the crashed window" >&2
    exit 1
fi
