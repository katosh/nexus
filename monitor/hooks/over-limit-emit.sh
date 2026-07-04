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
# `reset_at`: the brief flagged issue #129 open question #2 — does
# the StopFailure payload carry the reset timestamp? Without an
# observed rate-limit event during PR #129's implementation work we
# cannot empirically confirm the field name. This handler probes
# several plausible paths (`.reset_at`, `.reset_time`,
# `.rate_limit_reset`, nested under `.error.reset_at`) and writes
# the first non-null match; otherwise writes `null`. The renderer
# regex `_extract_over_limit_reset` (monitor/pane-state.sh:232)
# remains the authoritative `reset_at` extractor until a real
# StopFailure payload settles the field name.
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
# Required env (exported by spawn-worker.sh):
#   NEXUS_ROOT           absolute path to the primary nexus clone
#   NEXUS_WORKER_WINDOW  tmux window name this worker was spawned into
#
# Hot-path discipline: O(ms). Two jq invocations + one mv. Failure
# in any path short-circuits to exit 0 (a wedged hook must not
# block claude's turn).

set -u

payload=$(cat 2>/dev/null || true)

window="${NEXUS_WORKER_WINDOW:-}"
root="${NEXUS_ROOT:-}"

if [[ -z "$window" ]] || [[ -z "$root" ]]; then
    exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

state_dir="$root/monitor/.state"
mkdir -p "$state_dir" 2>/dev/null || exit 0

# Empirical-capture: write every StopFailure payload to a jsonl log
# regardless of error_type, so we can audit the field shape after
# the first real rate-limit event in production. Mirrors PR #132's
# notification-raw-captures.jsonl line.
printf '%s' "$payload" \
    | jq -c --arg window "$window" '. + {nexus_window: $window, nexus_capture_ts: now}' \
    >> "$state_dir/stopfailure-raw-captures.jsonl" 2>/dev/null || true

# Filter: only act on rate_limit. Other error_types (api_error,
# auth_failure, etc.) get captured to the raw log above but do not
# write an over-limit stamp.
error_type=$(jq -r '.error_type // empty' <<<"$payload" 2>/dev/null) || error_type=""
[[ "$error_type" == "rate_limit" ]] || exit 0

dest_dir="$state_dir/over-limit"
mkdir -p "$dest_dir" 2>/dev/null || exit 0

ts=$(date +%s)
session_id=$(jq -r '.session_id // ""' <<<"$payload" 2>/dev/null || printf '')
error_message=$(jq -r '.error.message // .error // .message // ""' <<<"$payload" 2>/dev/null || printf '')

# Probe plausible reset_at field paths. The bare `// "null"` ladder
# ensures we always end with a literal `null` for jq's --argjson
# (which insists on JSON-valid input). The probed paths come from
# inspecting the documented schemas across recent Claude Code
# releases — settle this once we see a real payload (#129 q2).
reset_at_raw=$(jq -r '.reset_at // .reset_time // .rate_limit_reset // .error.reset_at // .error.reset // "null"' <<<"$payload" 2>/dev/null)
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
