#!/usr/bin/env bash
# monitor/codex-hook.sh <event> — the nexus's hook adapter for Codex workers
# (your-org/nexus-code#1640, layer 2). Codex's `-c hooks.<Event>=…` entries,
# written by spawn-worker.sh --harness codex, point here.
#
# WHAT IT BUYS. Codex 0.156.1 has Claude-compatible command hooks (measured
# on a real TUI: SessionStart, UserPromptSubmit, PostToolUse and Stop all fire,
# with a JSON payload on stdin carrying session_id, transcript_path, cwd,
# hook_event_name, turn_id, and `prompt` on UserPromptSubmit). That payload
# is what monitor/worker-heartbeat.sh already parses, so a Codex worker gets
# the SAME two nexus signals a Claude worker gets, from the same writer:
#
#   heartbeat/<window>.json   busy / user_prompt / idle_prompt (+ session_id)
#   user-prompt/<window>      <epoch>\t<session_id>  — the submit-stamp receipt
#                             ng send and paste-followup.sh confirm against
#
#   Codex event        → worker-heartbeat.sh token
#   SessionStart       → busy        (+ record the thread id, below)
#   UserPromptSubmit   → user_prompt (writes the submit-stamp)
#   PreToolUse         → busy        (a tool STARTS; PostToolUse only at its end)
#   PostToolUse        → busy
#   Stop               → turn_end    (idle_prompt + last_turn_end)
#
# MEASURED, AND BETTER THAN THE CLAUDE PATH: a message steered in while Codex
# is mid-turn fires UserPromptSubmit when Codex CONSUMES it (11 s later in the
# capture), so the submit-stamp arrives on the queued path too — the path
# your-org/nexus-code#1099 found receipt-less for Claude Code.
#
# SessionStart also writes Codex's thread id into the window descriptor
# (monitor/.state/windows/<key>.json .session_id) when the spawn left it
# empty. A Claude spawn PRE-assigns its session id (`--session-id`); Codex
# offers no such flag, so the id exists only once the session starts. The
# descriptor's .session_id is what the retire gate uses to tell the worker's
# own submits from the operator's, and what `spawn-worker.sh --resume` reads.
# It is written only when empty and only for harness=codex, so a Claude
# descriptor can never be touched by this file.
#
# CONTRACT WITH CODEX: never print to STDOUT (Codex parses hook stdout for
# decisions such as `{"decision":"block"}`), always exit 0 (a failing hook
# must not wedge the worker), and bound every step.

event="${1:-}"
payload=$(head -c 65536 2>/dev/null || true)

_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
hb="$_dir/worker-heartbeat.sh"

case "$event" in
    SessionStart)     token=busy ;;
    UserPromptSubmit) token=user_prompt ;;
    PreToolUse)       token=busy ;;
    PostToolUse)      token=busy ;;
    Stop)             token=turn_end ;;
    *)                exit 0 ;;
esac

if [[ -x "$hb" ]]; then
    printf '%s' "$payload" | timeout 10 "$hb" "$token" >/dev/null 2>&1 || true
fi

if [[ "$event" == SessionStart && -n "${NEXUS_WORKER_WINDOW:-}" ]] && command -v jq >/dev/null 2>&1; then
    sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null) || sid=""
    state_dir="${NEXUS_STATE_DIR:-${NEXUS_ROOT:+$NEXUS_ROOT/monitor/.state}}"
    if [[ "$sid" =~ ^[0-9a-fA-F-]{8,64}$ && -n "$state_dir" && -r "$_dir/_bookkeeping.sh" ]]; then
        (
            # shellcheck source=monitor/_bookkeeping.sh
            . "$_dir/_bookkeeping.sh" >/dev/null 2>&1 || exit 0
            declare -F wk_encode >/dev/null 2>&1 || exit 0
            desc="$state_dir/windows/$(wk_encode "$NEXUS_WORKER_WINDOW").json"
            [[ -f "$desc" ]] || exit 0
            jq -e '.harness == "codex" and ((.session_id // "") == "")' "$desc" >/dev/null 2>&1 || exit 0
            tmp=$(mktemp "$desc.XXXXXX" 2>/dev/null) || exit 0
            if jq --arg sid "$sid" '.session_id = $sid' "$desc" > "$tmp" 2>/dev/null; then
                mv -f "$tmp" "$desc" 2>/dev/null || rm -f "$tmp"
            else
                rm -f "$tmp"
            fi
        ) >/dev/null 2>&1 || true
    fi
fi
exit 0
