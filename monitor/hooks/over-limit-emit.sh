#!/usr/bin/env bash
# monitor/hooks/over-limit-emit.sh
#
# Claude Code StopFailure-hook handler. Reads the hook payload from
# stdin; when `.error_type == "rate_limit"`, writes a per-window
# over-limit stamp to:
#
#   $NEXUS_ROOT/monitor/.state/over-limit/<window>.json
#
# `pane-state.sh` reads that file after the dead-claude pid gate and
# emits `state=over-limit` directly — replacing the canonical
# "You've hit your limit · resets <time>" text-scrape detection
# (`_detect_over_limit`, monitor/pane-state.sh:213-219) with a
# structured-event channel.
#
# File contents:
#
#   {"ts": <epoch>,
#    "session_id": <claude session id>,
#    "error_type": "rate_limit",
#    "error_message": <text, best-effort>,
#    "reset_at": <token-or-null>,
#    "window": <tmux window name>,
#    "hook_event_name": "StopFailure"}
#
# `reset_at`: issue #129 open question #2 is now settled empirically.
# 17 real rate-limit StopFailure payloads captured in production
# (monitor/.state/stopfailure-raw-captures.jsonl, 2026-06-26 →
# 2026-07-14) show the shape:
#
#   { "hook_event_name": "StopFailure",
#     "error": "rate_limit",                       <- STRING, not .error_type
#     "last_assistant_message":
#       "You've hit your weekly limit · resets 3am (America/Los_Angeles)",
#     "session_id": ..., "transcript_path": ..., "cwd": ...,
#     "prompt_id": ..., "effort": {...} }
#
# There is NO dedicated reset field — the reset time rides inside
# `last_assistant_message`. This handler therefore (a) filters on
# `.error == "rate_limit"` (string) with `.error_type` /
# `.error.type` kept as compatibility fallbacks, and (b) extracts
# `reset_at` from the explicit fields if a future CC adds one, else
# parses the `resets <suffix>` clause of `last_assistant_message`,
# normalised to the same token grammar `_extract_over_limit_reset`
# (monitor/pane-state.sh) produces — "3am_America/Los_Angeles" — so
# `_over_limit_reset_at_to_epoch` parses both channels identically.
#
# Cleanup contract: the file persists until a successful Stop event
# clears it (see the `rm -f` entry the Stop block in
# monitor/worker-settings.json now carries). A subsequent successful
# turn = the rate limit reset and the worker is back online.
#
# Side-effect: also writes a verbatim copy of the payload (merged
# with window + capture_ts) to
# `monitor/.state/stopfailure-raw-captures.jsonl` so the very first
# real rate-limit event in production gives us the empirical
# payload shape, mirroring the capture line PR #132 added for
# Notification.
#
# Required env:
#   NEXUS_ROOT           absolute path to the primary nexus clone
# Window resolution (first match wins):
#   NEXUS_WORKER_WINDOW        exported by spawn-worker.sh (workers)
#   NEXUS_ORCHESTRATOR_WINDOW  exported by the orchestrator launcher
#                              (_respawn_compose_launcher)
#   tmux display-message       best-effort $TMUX_PANE lookup, covering
#                              manually-launched panes
#
# Hot-path discipline: O(ms). Two jq invocations + one mv. Failure
# in any path short-circuits to exit 0 (a wedged hook must not
# block claude's turn).

set -u

payload=$(cat 2>/dev/null || true)

window="${NEXUS_WORKER_WINDOW:-${NEXUS_ORCHESTRATOR_WINDOW:-}}"
root="${NEXUS_ROOT:-}"

# Last-resort window resolution for panes launched without either env
# var (operator-manual launches). Best-effort; a failure leaves
# `window` empty and we bail exactly as before.
if [[ -z "$window" ]] && [[ -n "${TMUX_PANE:-}" ]] \
    && command -v tmux >/dev/null 2>&1; then
    window=$(tmux display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null) || window=""
fi

if [[ -z "$window" ]] || [[ -z "$root" ]]; then
    exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

# NEXUS_STATE_DIR: direct override (test escape hatch + the resolution
# order pane-state.sh already uses for READING the stamp — the writer
# must agree or the two sides split-brain). Same convention as the
# sibling hooks (turn-failure-emit.sh, async-launch-detect.sh, …).
state_dir="${NEXUS_STATE_DIR:-$root/monitor/.state}"
mkdir -p "$state_dir" 2>/dev/null || exit 0

# Empirical-capture: write every StopFailure payload to a jsonl log
# regardless of error_type, so we can audit the field shape after
# the first real rate-limit event in production. Mirrors PR #132's
# notification-raw-captures.jsonl line.
printf '%s' "$payload" \
    | jq -c --arg window "$window" '. + {nexus_window: $window, nexus_capture_ts: now}' \
    >> "$state_dir/stopfailure-raw-captures.jsonl" 2>/dev/null || true

# Filter: only act on rate_limit. Other errors (server_error,
# invalid_request, etc.) get captured to the raw log above but do not
# write an over-limit stamp. The REAL payload carries the token as a
# STRING in `.error` (empirically confirmed — see header); the
# `.error_type` / `.error.type` probes are compatibility fallbacks in
# case a CC release moves the field.
error_type=$(jq -r '
    if (.error | type) == "string" then .error
    else (.error_type // .error.type // empty) end
' <<<"$payload" 2>/dev/null) || error_type=""
[[ "$error_type" == "rate_limit" ]] || exit 0

dest_dir="$state_dir/over-limit"
mkdir -p "$dest_dir" 2>/dev/null || exit 0

ts=$(date +%s)
session_id=$(jq -r '.session_id // ""' <<<"$payload" 2>/dev/null || printf '')
# `last_assistant_message` carries the human-readable notice in the
# real payload ("You've hit your weekly limit · resets 3am (…)").
# Older probes kept as fallbacks for fabricated/legacy shapes.
error_message=$(jq -r '
    if (.last_assistant_message? // null) != null then .last_assistant_message
    elif ((.error? // null) | type) == "object" then (.error.message? // "")
    elif ((.error? // null) | type) == "string" then .error
    else (.message? // "") end
' <<<"$payload" 2>/dev/null) || error_message=""

# Reset time. Explicit fields first (none exist in the empirical
# payload today, but a future CC may add one), then parse the
# `resets <suffix>` clause of the notice text and normalise it to the
# same token grammar as pane-state.sh::_extract_over_limit_reset:
# strip parens, whitespace → `_`, cap 40 chars. Example:
#   "… · resets 3am (America/Los_Angeles)" → "3am_America/Los_Angeles"
# `_over_limit_reset_at_to_epoch` (monitor/watcher/_over_limit.sh)
# consumes exactly this shape. On no match we write `null`; the
# watcher's 6h safety-fallback hold bounds the unparseable case.
reset_at_raw=$(jq -r '
    (.reset_at? // .reset_time? // .rate_limit_reset?
     // (if ((.error? // null) | type) == "object"
         then (.error.reset_at? // .error.reset?)
         else null end)
     // "null")
' <<<"$payload" 2>/dev/null) || reset_at_raw="null"
if [[ -z "$reset_at_raw" ]] || [[ "$reset_at_raw" == "null" ]]; then
    # The `s/·.*$//` cut mirrors pane-state's _extract_over_limit_reset:
    # anything after a following `·` separator is UI decoration, not
    # part of the reset time.
    reset_at_raw=$(printf '%s' "$error_message" \
        | grep -oE 'resets[[:space:]]+[^[:cntrl:]]+' \
        | head -1 \
        | sed -E 's/[[:space:]]*·.*$//; s/^resets[[:space:]]+//; s/[[:space:]]+$//' \
        | tr -d '()' | tr -s '[:space:]' '_' | sed 's/_*$//') || reset_at_raw=""
    reset_at_raw="${reset_at_raw:0:40}"
fi
if [[ -n "$reset_at_raw" ]] && [[ "$reset_at_raw" != "null" ]]; then
    reset_at_json=$(jq -nc --arg v "$reset_at_raw" '$v')
else
    reset_at_json='null'
fi

dest="$dest_dir/$window.json"
tmp="$dest_dir/.$window.$$.tmp"

if jq -nc \
    --argjson ts          "$ts" \
    --arg     session_id  "$session_id" \
    --arg     error_type  "$error_type" \
    --arg     error_message "$error_message" \
    --argjson reset_at    "$reset_at_json" \
    --arg     window      "$window" \
    '{
        ts:              $ts,
        session_id:      $session_id,
        error_type:      $error_type,
        error_message:   $error_message,
        reset_at:        $reset_at,
        window:          $window,
        hook_event_name: "StopFailure"
     }' > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$dest" 2>/dev/null || rm -f "$tmp"
else
    rm -f "$tmp"
fi
exit 0
