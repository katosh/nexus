#!/usr/bin/env bash
# monitor/hooks/decision-emit.sh
#
# Claude Code Notification-hook handler. Reads the hook payload from
# stdin and writes a per-decision JSON event to:
#
#   $NEXUS_ROOT/monitor/.state/decisions/<window>.<fp>.json
#
# Fingerprint is a stable hash of (window, notification-type, message)
# so re-fires of the same prompt within a session map to the same
# file — the orchestrator sees one row per pending decision, not one
# per re-render.
#
# Write is atomic (temp file in the same directory + rename). The
# ack channel has two shapes:
#   - `rm <window>.<fp>.json` (ack-and-allow): the next hook fire
#     for the same fingerprint writes a fresh `<fp>.json` and the
#     orchestrator re-handles it.
#   - `mv <window>.<fp>.json <window>.<fp>.handled.json` (ack-and-
#     suppress): the tombstone is honoured here — if a sibling
#     `<window>.<fp>.handled.json` exists, the hook silently
#     no-ops and never re-writes `<fp>.json`. The fingerprint is
#     terminal for the lifetime of `monitor/.state/decisions/`.
#     The watcher's reader also skips tombstones.
#
# Side channels consumed (best-effort, optional):
#   - $NEXUS_ROOT/monitor/.state/pending-tool/<window>.json — written
#     by the PreToolUse hook on Bash/Write/Edit/NotebookEdit. When
#     present at Notification time, its body is embedded into
#     `tool_context` so the orchestrator can see the tool+args
#     without consulting the pane.
#
# Required env (exported by spawn-worker.sh into the worker's
# process tree):
#   NEXUS_ROOT           absolute path to the primary nexus clone
#   NEXUS_WORKER_WINDOW  tmux window name this worker was spawned into
#
# Exit conditions:
#   - missing env vars              → log to stderr, exit 0 (don't
#                                     block claude's turn)
#   - jq missing                    → exit 0 (degraded silently)
#   - any internal failure          → exit 0 (hook hot-path discipline)
#
# Hot-path discipline: every step is O(milliseconds). No subshell
# loops, no network, no waits. Hook runs synchronously on claude's
# turn — a wedged hook would block the agent.

set -u

# Read payload before any other work so a missing stdin doesn't hang.
payload=$(cat 2>/dev/null || true)

window="${NEXUS_WORKER_WINDOW:-}"
root="${NEXUS_ROOT:-}"

if [[ -z "$window" ]] || [[ -z "$root" ]]; then
    echo "decision-emit: NEXUS_WORKER_WINDOW or NEXUS_ROOT unset; skipping" >&2
    exit 0
fi

command -v jq >/dev/null 2>&1 || {
    echo "decision-emit: jq missing; skipping (decision not captured)" >&2
    exit 0
}

dest_dir="$root/monitor/.state/decisions"
mkdir -p "$dest_dir" 2>/dev/null || { echo "decision-emit: mkdir $dest_dir failed" >&2; exit 0; }

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# session_id / kind / message are read with defensive defaults; a
# malformed payload yields a file with empty strings rather than no
# file at all (the operator can still see "something pinged").
session_id=$(jq -r '.session_id // ""' <<<"$payload" 2>/dev/null || printf '')
# kind = notification_type when present (permission_prompt /
# idle_prompt / auth_success / elicitation_* / ...), per the
# Notification payload shape Claude Code emits empirically — see
# PR #132 for a captured payload. Fall back to the legacy
# `.notification.type` shape (kept in case a future schema flip
# re-nests the field), then to the hook_event_name itself. The
# bare hook_event_name leg ensures the handler still records a
# fingerprint for unanticipated event types instead of silently
# producing `kind:"unknown"`.
kind=$(jq -r '.notification_type // .notification.type // .hook_event_name // "unknown"' <<<"$payload" 2>/dev/null || printf 'unknown')
# `.message` is a sibling of `.notification_type` at the top
# level of the empirically-observed payload. The older assumed
# shape put the user-facing string under `.notification.message`;
# preserve the legacy path as a fallback so a future schema
# regression doesn't silently regress prompt_excerpt to "".
message=$(jq -r '.message // .notification.message // ""' <<<"$payload" 2>/dev/null || printf '')

# Stable fingerprint: 12 hex chars of sha1(window | kind | message).
# Collision avoidance within a single workspace is more than enough
# at 48 bits; cross-workspace collisions don't matter (different
# .state dirs). Window is in the input so two workers showing the
# same prompt get distinct fingerprints, which is what we want — they
# need to be answered independently.
fp=$(printf '%s|%s|%s' "$window" "$kind" "$message" \
     | sha1sum 2>/dev/null | cut -c1-12)
if [[ -z "$fp" ]]; then
    # sha1sum missing (Alpine + busybox edge case). Synthesise from
    # epoch + pid so we still write SOMETHING — operator can rotate
    # later. Collision-prone but it never matters in practice.
    fp="ts$(date +%s)p$$"
fi

# Tombstone gate: a `<window>.<fp>.handled.json` sibling means the
# orchestrator has already declared this fingerprint terminal
# (ack-and-suppress). Silently no-op so re-fires of the same prompt
# don't resurface. No stderr — the hook runs on every Notification
# and tombstoned fingerprints are common (retained-idle workers
# repeatedly fire `idle_prompt`); logging would flood neighbours.
if [[ -f "$dest_dir/$window.$fp.handled.json" ]]; then
    exit 0
fi

# Prompt excerpt: first ~20 lines (as the operator spec asked). The
# Notification.message is usually a single paragraph; the 20-line cap
# is a defensive bound for an unusually long auth_success or MCP
# elicitation payload.
prompt_excerpt=$(printf '%s\n' "$message" | head -20)

# Tool context (optional): if PreToolUse just stamped a pending-tool
# file for this window, embed its body so the orchestrator sees the
# tool+args. Read as a raw string — the watcher emit cites the file
# path so anyone curious can inspect the full structured form.
pending_tool_file="$root/monitor/.state/pending-tool/$window.json"
tool_context=""
if [[ -f "$pending_tool_file" ]]; then
    tool_context=$(<"$pending_tool_file")
fi

dest="$dest_dir/$window.$fp.json"
tmp="$dest_dir/.$window.$fp.$$.tmp"

# Build the JSON atomically. --arg coerces every value to string,
# which is the right shape for the operator's read path — tool_context
# is a string holding the embedded pending-tool JSON, not a nested
# object (avoids escaping headaches downstream and keeps the file
# stable across jq versions).
if jq -nc \
    --arg ts             "$ts" \
    --arg window         "$window" \
    --arg session_id     "$session_id" \
    --arg kind           "$kind" \
    --arg prompt_excerpt "$prompt_excerpt" \
    --arg tool_context   "$tool_context" \
    --arg fingerprint    "$fp" \
    '{
        ts: $ts,
        window: $window,
        session_id: $session_id,
        kind: $kind,
        prompt_excerpt: $prompt_excerpt,
        tool_context: $tool_context,
        fingerprint: $fingerprint
     }' > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$dest" 2>/dev/null || rm -f "$tmp"
else
    rm -f "$tmp"
    echo "decision-emit: jq failed to build $dest" >&2
fi
exit 0
