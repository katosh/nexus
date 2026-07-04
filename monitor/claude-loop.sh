#!/usr/bin/env bash
# monitor/claude-loop.sh — respawn shim for retained `claude` workers.
#
# Wraps `claude` so a graceful exit produces a fresh
# `claude --continue` against the same workdir, bounded by:
#
#   - Max restart count (default 10; flag `--max-restarts`).
#   - Window-retain TTL (default from
#     `monitor.retain_ttl_seconds`, env `MONITOR_RETAIN_TTL_SECONDS`,
#     or flag `--retain-ttl-seconds`). The loop ends once the most
#     recent `window-retain` action-log event for this window is
#     older than the TTL, OR there is NO retain event at all by the
#     time the worker's claude has exited the first time — the
#     respawn is for re-engagement AFTER `ng wrap-up`, not crash
#     recovery for a worker that never wrapped up.
#   - Operator stop sentinel: `<state-dir>/loop-stop/<window>.flag`.
#     Designed for a future `SessionEnd` hook (issue follow-up) that
#     `touch`es the sentinel when the operator types `/exit`. Manual
#     `touch` works too. The sentinel is consumed (rm) on stop.
#   - SIGINT / SIGTERM trap: Ctrl+C during the back-off sleep (or
#     any other gap between child runs) stops the loop cleanly.
#
# The first claude invocation receives the prompt body (read from
# `--prompt-file`) as the initial user message; every subsequent
# invocation runs `claude --continue` so an operator paste-buffer
# follow-up resumes the SAME session against the same workdir.
#
# Usage:
#   monitor/claude-loop.sh \
#       --window <name> \
#       --prompt-file <path> \
#       [--settings <path>] \
#       [--model <model-id>] \
#       [--max-restarts N] \
#       [--retain-ttl-seconds SEC] \
#       [--state-dir <dir>] \
#       [--backoff-base SEC]
#
# Exit codes:
#   0   stopped via stop sentinel (operator intent)
#   10  stopped because retain TTL expired / no retain event
#   11  stopped because max-restart cap reached
#   12  stopped because of SIGINT/SIGTERM
#   *   last claude exit code if no stop condition triggered (rare —
#       only reachable if claude exits without any of the gates
#       firing, e.g. when the first run finishes and the loop never
#       enters because of an earlier sentinel).

set -uo pipefail

usage() {
    sed -n '3,46p' "$0" >&2
    exit "${1:-2}"
}

WINDOW=
PROMPT_FILE=
SETTINGS_PATH=
MODEL=
MAX_RESTARTS=10
RETAIN_TTL=
STATE_DIR=
BACKOFF_BASE=5

while (( $# )); do
    case "${1:-}" in
        --window)              WINDOW="${2:-}"; shift 2 ;;
        --prompt-file)         PROMPT_FILE="${2:-}"; shift 2 ;;
        --settings)            SETTINGS_PATH="${2:-}"; shift 2 ;;
        --model)               MODEL="${2:-}"; shift 2 ;;
        --max-restarts)        MAX_RESTARTS="${2:-}"; shift 2 ;;
        --retain-ttl-seconds)  RETAIN_TTL="${2:-}"; shift 2 ;;
        --state-dir)           STATE_DIR="${2:-}"; shift 2 ;;
        --backoff-base)        BACKOFF_BASE="${2:-}"; shift 2 ;;
        -h|--help)             usage 0 ;;
        *) echo "claude-loop: unknown arg: ${1:-}" >&2; usage 2 ;;
    esac
done

[[ -n "$WINDOW" ]]      || { echo "claude-loop: --window required"      >&2; exit 2; }
[[ -n "$PROMPT_FILE" ]] || { echo "claude-loop: --prompt-file required" >&2; exit 2; }
[[ -r "$PROMPT_FILE" ]] || { echo "claude-loop: prompt-file unreadable: $PROMPT_FILE" >&2; exit 2; }

# NEXUS_ROOT resolved from this script's location so the wrapper
# works in forks, worktrees, and fresh clones without env setup.
script_dir=$(cd "$(dirname "$0")" && pwd)
NEXUS_ROOT="${NEXUS_ROOT:-$(cd "$script_dir/.." && pwd)}"
STATE_DIR="${STATE_DIR:-$NEXUS_ROOT/monitor/.state}"

# Resolve $CLAUDE_BIN (env override → project-local install → PATH).
# shellcheck disable=SC1091
. "$NEXUS_ROOT/monitor/_claude-bin.sh"

# Resolve retain TTL: explicit flag wins; otherwise env override;
# otherwise config; otherwise 24 h. Match the precedence used in
# monitor/watcher/_idle_probe.sh so a single config knob governs
# both the suppression window and the respawn window.
if [[ -z "$RETAIN_TTL" ]]; then
    RETAIN_TTL="${MONITOR_RETAIN_TTL_SECONDS:-}"
fi
if [[ -z "$RETAIN_TTL" ]]; then
    if [[ -x "$NEXUS_ROOT/config/load.sh" ]]; then
        RETAIN_TTL=$("$NEXUS_ROOT/config/load.sh" monitor.retain_ttl_seconds 86400 2>/dev/null || echo 86400)
    else
        RETAIN_TTL=86400
    fi
fi
[[ "$RETAIN_TTL"    =~ ^[0-9]+$ ]] || RETAIN_TTL=86400
[[ "$MAX_RESTARTS"  =~ ^[0-9]+$ ]] || MAX_RESTARTS=10
[[ "$BACKOFF_BASE"  =~ ^[0-9]+$ ]] || BACKOFF_BASE=5

SENTINEL_DIR="$STATE_DIR/loop-stop"
SENTINEL_FILE="$SENTINEL_DIR/${WINDOW}.flag"
ACTION_LOG="$STATE_DIR/action-log.jsonl"

PROMPT_BODY=$(<"$PROMPT_FILE")

# Stop flag set by signal traps. Bash dispatches traps between
# commands, and a signal received during `wait` interrupts the
# wait so the next loop iteration observes STOP=1.
STOP=0
on_stop() { STOP=1; }
trap on_stop INT TERM

# Latest window-retain epoch for this window. Empty stdout when
# no retain event exists. Mirrors monitor/watcher/_idle_probe.sh
# `_idle_window_retain_event`: jq when available, regex fallback
# otherwise. The action-log is append-only, so `tac | head` finds
# the most recent entry cheaply.
_latest_retain_epoch() {
    local log="$ACTION_LOG" win="$1"
    [[ -f "$log" ]] || return 0
    local ts=""
    if command -v jq >/dev/null 2>&1; then
        ts=$(grep '"event":"window-retain"' "$log" 2>/dev/null \
            | tac \
            | jq -r --arg w "$win" \
                'select(.window == $w) | .ts' 2>/dev/null \
            | head -1)
    fi
    if [[ -z "$ts" ]]; then
        local line w_field
        while IFS= read -r line; do
            w_field=$(printf '%s' "$line" | sed -n 's/.*"window":"\([^"]*\)".*/\1/p')
            [[ "$w_field" == "$win" ]] || continue
            ts=$(printf '%s' "$line" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')
            [[ -n "$ts" ]] && break
        done < <(grep '"event":"window-retain"' "$log" 2>/dev/null | tac)
    fi
    [[ -n "$ts" ]] || return 0
    date -d "$ts" +%s 2>/dev/null || return 0
}

_sentinel_present() { [[ -e "$SENTINEL_FILE" ]]; }
_consume_sentinel() { [[ -e "$SENTINEL_FILE" ]] && rm -f "$SENTINEL_FILE"; }

# claude invocation. `--continue` resumes the most-recent session
# in the cwd; on the first call we instead pass the prompt body.
#
# Env exports suppress Claude Code's stale-large-session resume
# dialog so respawned workers reload their full transcript instead of
# blocking on the "Resume from summary / Resume full session as-is /
# Don't ask me again" picker. Upstream's gate (`if(z<q)return null`
# / `if(Y<K)return null`) reads `CLAUDE_CODE_RESUME_*` env vars
# before rendering the picker; pushing both thresholds beyond any
# plausible session makes the gate trip and the picker never appears.
# Scoped to this child process — the user's own panes are unaffected.
_run_claude() {
    local first="$1"
    local -a args=( --dangerously-skip-permissions )
    [[ -n "$SETTINGS_PATH" ]] && args+=( --settings "$SETTINGS_PATH" )
    # Per-worker model pin (issue #433). Appended on the first call
    # AND every --continue respawn so the pin survives restarts.
    # Empty MODEL = inherit the ambient default, args unchanged.
    [[ -n "$MODEL" ]] && args+=( --model "$MODEL" )
    if (( first )); then
        args+=( "$PROMPT_BODY" )
    else
        args+=( --continue )
    fi
    CLAUDE_CODE_RESUME_THRESHOLD_MINUTES=999999999 \
    CLAUDE_CODE_RESUME_TOKEN_THRESHOLD=999999999999 \
        "$CLAUDE_BIN" "${args[@]}"
}

restarts=0
last_rc=0
stop_reason=""

# Pre-flight sentinel: honour an operator who pre-disabled the
# loop before the worker even started. Rare but cheap to check.
if _sentinel_present; then
    stop_reason="sentinel-pre-start"
    _consume_sentinel
else
    _run_claude 1
    last_rc=$?
fi

while [[ -z "$stop_reason" ]]; do
    if (( STOP )); then stop_reason="signal"; break; fi
    if _sentinel_present; then
        stop_reason="sentinel"
        _consume_sentinel
        break
    fi

    retain_epoch=$(_latest_retain_epoch "$WINDOW" || true)
    if [[ -z "$retain_epoch" ]]; then
        stop_reason="no-retain-event"; break
    fi
    now=$(date +%s)
    retain_age=$(( now - retain_epoch ))
    if (( retain_age > RETAIN_TTL )); then
        stop_reason="retain-ttl-expired"; break
    fi

    if (( restarts >= MAX_RESTARTS )); then
        stop_reason="max-restarts"; break
    fi

    sleep_for=$(( BACKOFF_BASE * (restarts + 1) ))
    # Background the sleep so trap on the parent shell can
    # interrupt it; `wait` returns immediately on signal.
    sleep "$sleep_for" &
    sleep_pid=$!
    wait "$sleep_pid" 2>/dev/null || true
    if (( STOP )); then stop_reason="signal"; break; fi

    restarts=$(( restarts + 1 ))
    printf 'claude-loop: restart #%d for window=%s (last rc=%d, retain-age=%ss/ttl=%ss)\n' \
        "$restarts" "$WINDOW" "$last_rc" "$retain_age" "$RETAIN_TTL" >&2
    _run_claude 0
    last_rc=$?
done

case "$stop_reason" in
    sentinel|sentinel-pre-start)        exit 0  ;;
    no-retain-event|retain-ttl-expired) exit 10 ;;
    max-restarts)                       exit 11 ;;
    signal)                             exit 12 ;;
    *)                                  exit "$last_rc" ;;
esac
