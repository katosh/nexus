#!/usr/bin/env bash
# notification-record.sh — the Notification-hook journal writer.
#
# ---------------------------------------------------------------------
# THIS HOOK FAILS OPEN. ALWAYS. IT EXITS 0 ON EVERY PATH.
# ---------------------------------------------------------------------
# Same contract, and the same reason, as hooks/pending-tool-record.sh: a
# bookkeeping write nobody is waiting on must never be able to take out a
# worker's tool access. On 2026-07-09 an inline hook pipeline's redirect into a
# briefly read-only project tree propagated its non-zero exit into Claude
# Code's gate and disabled Bash/Write/Edit for every hook-gated worker in the
# workspace. Every path here ends in `exit 0`.
#
# WHY IT EXISTS (your-org/nexus-code#568 D1 + D10). It replaces two inline
# `jq` pipelines that lived in monitor/worker-settings.json, against this
# codebase's own stated precedent (hooks/pending-tool-record.sh documents why
# they get extracted): JSON-embedded shell is unreachable by shellcheck and by
# unit tests, and cannot carry the comment that explains it.
#
# Both pipelines read the SAME hook payload from stdin, so as inline commands
# they cost two `jq` forks and two reads of the event per notification. Here
# they are one fork.
#
# It also CAPS the raw-capture log. `notification-raw-captures.jsonl` was
# write-only, unrotated and unbounded — no reader anywhere in the repo — and
# had reached ~2 MB while the sibling written by the very next hook in the same
# block IS rotated (`_notifications_rotate_if_oversized`, _idle_probe.sh). The
# raw capture is kept, because a raw event record is exactly what you want when
# a notification classification misbehaves, but it is now bounded on the same
# terms as its sibling and with the same retention sweep.
#
# Env:
#   NEXUS_ROOT                            state root (required; no-op without)
#   NEXUS_WORKER_WINDOW /
#   NEXUS_ORCHESTRATOR_WINDOW             window label for the row
#   MONITOR_NOTIFICATIONS_LOG_MAX_BYTES   rotation threshold (default 10 MiB)
#   MONITOR_RAW_CAPTURES_ENABLED          set to 0/false to skip the raw log
#   DIFF_RETENTION_DAYS                   rotated-archive retention (default 7)

set -u

_root="${NEXUS_ROOT:-}"
[ -n "$_root" ] || exit 0
_state="$_root/monitor/.state"
mkdir -p "$_state" 2>/dev/null || exit 0

_window="${NEXUS_WORKER_WINDOW:-${NEXUS_ORCHESTRATOR_WINDOW:-orchestrator}}"
_raw="$_state/notification-raw-captures.jsonl"
_struct="$_state/worker-notifications.jsonl"

# Rotate BEFORE appending: cheap, and it bounds the file the append is about to
# grow. Mirrors _notifications_rotate_if_oversized (_idle_probe.sh) exactly —
# rename to <path>.<epoch>, then sweep archives past the retention window.
_rotate() {   # $1 = path, $2 = archive glob
    local path="$1" glob="$2" max size retention
    max="${MONITOR_NOTIFICATIONS_LOG_MAX_BYTES:-10485760}"
    case "$max" in ''|*[!0-9]*) return 0 ;; esac
    [ "$max" -gt 0 ] 2>/dev/null || return 0
    [ -f "$path" ] || return 0
    size=$(stat -c '%s' "$path" 2>/dev/null || stat -f '%z' "$path" 2>/dev/null || echo 0)
    case "$size" in ''|*[!0-9]*) return 0 ;; esac
    [ "$size" -ge "$max" ] 2>/dev/null || return 0
    mv -f "$path" "${path}.$(date +%s)" 2>/dev/null || return 0
    retention="${DIFF_RETENTION_DAYS:-7}"
    case "$retention" in ''|*[!0-9]*) retention=7 ;; esac
    find "$(dirname "$path")" -maxdepth 1 -type f -name "$glob" \
        -mtime "+$retention" -delete 2>/dev/null || true
}

_payload=$(cat 2>/dev/null || true)

# One jq fork produces BOTH rows: the raw event enriched with window+capture
# timestamp, and the structured classification row the watcher's prelude reads
# (_notifications_count_distinct_since). `-c` keeps them one-line-per-event so
# the readers' line-oriented parsing (and the sed fallback) still applies.
# The raw capture is a WORKER-side artifact only. The orchestrator's inline
# pipeline never wrote one, and unifying the two call sites must not quietly
# start producing a new log for it — behaviour preserved by gating on
# NEXUS_WORKER_WINDOW, the variable only worker settings set.
_raw_enabled=1
[ -n "${NEXUS_WORKER_WINDOW:-}" ] || _raw_enabled=0
case "${MONITOR_RAW_CAPTURES_ENABLED:-1}" in 0|false|FALSE|no|NO|off|OFF) _raw_enabled=0 ;; esac

if command -v jq >/dev/null 2>&1; then
    _both=$(printf '%s' "$_payload" | jq -c --arg window "$_window" '
        [ (. + {nexus_window: $window, nexus_capture_ts: now}),
          {event:.hook_event_name, notification_type:.notification_type,
           message:.message, window:$window, ts:now} ]' 2>/dev/null) || _both=""
    if [ -n "$_both" ]; then
        _rawline=$(printf '%s' "$_both" | jq -c '.[0]' 2>/dev/null || true)
        _stline=$(printf '%s' "$_both" | jq -c '.[1]' 2>/dev/null || true)
        if [ "$_raw_enabled" = 1 ] && [ -n "$_rawline" ]; then
            _rotate "$_raw" 'notification-raw-captures.jsonl.*'
            printf '%s\n' "$_rawline" >> "$_raw" 2>/dev/null || true
        fi
        if [ -n "$_stline" ]; then
            _rotate "$_struct" 'worker-notifications.jsonl.*'
            printf '%s\n' "$_stline" >> "$_struct" 2>/dev/null || true
        fi
    fi
fi

exit 0
