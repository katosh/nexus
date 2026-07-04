#!/usr/bin/env bash
# One-shot watcher revival — run by the ORCHESTRATOR when its watcher-
# supervisor Monitor detects the watcher DOWN (your-org/your-nexus
# watcher-supervision, mutual-liveness design). NOT a daemon: it runs
# once, revives, and exits, so the orchestrator's always-on agent loop is
# the only external supervisor.
#
# It reuses the existing primitives the operator asked to reuse:
#   - the proper restart command  (monitor/svc.sh restart watcher — itself
#     single-flight-locked + whole-process-group-reaping + verifying),
#   - the liveness probe           (_watcher_alive),
#   - the crash-loop guard         (_respawn_loop_check), so a watcher that
#     crash-loops is not revived endlessly — past the limit it backs off +
#     sandbox-notifies, the operator's cue to intervene.
#
# It also:
#   - RESPECTS an intentional stop: if monitor/.state/watcher-stop-requested
#     exists (written by `svc.sh stop watcher`), it does NOT revive — so a
#     deliberate stop is never fought by a still-armed Monitor.
#   - leaves the SELF-FAILURE marker (monitor/.state/watcher-revived) so the
#     revived watcher's first emit reports its own prior death (a dead
#     watcher can't report it; the successor does). Gated on prior-existence
#     evidence so this is never written for a watcher that was never up.
#
# Usage:  monitor/revive-watcher.sh
# Exit:   0 revived (or already alive / intentional-stop no-op),
#         3 crash-loop guard tripped (did NOT revive),
#         4 state dir READ-ONLY (escalated out-of-band, did NOT revive —
#           a read-only project FS is unrecoverable from inside the
#           sandbox; restart the sandbox to restore the writable bind),
#         non-zero = restart command failed.
# Env overrides (tests): NEXUS_STATE_DIR, MONITOR_INTERVAL,
#   REVIVE_SVC_BIN, MONITOR_WATCHER_SUPERVISOR_LOOP_LIMIT/_WINDOW_SECONDS.

set -uo pipefail
_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_nexus_root=$(cd "$_script_dir/.." && pwd)
_cfg="$_nexus_root/config/load.sh"
# shellcheck source=watcher/_lib.sh
source "$_script_dir/watcher/_lib.sh"

NEXUS_ROOT="${NEXUS_ROOT:-$_nexus_root}"
STATE_DIR="${NEXUS_STATE_DIR:-$NEXUS_ROOT/monitor/.state}"
SVC_BIN="${REVIVE_SVC_BIN:-$_script_dir/svc.sh}"
HEARTBEAT="$STATE_DIR/watcher-heartbeat"
PIDFILE="$STATE_DIR/watcher.pid"
STOP_SENTINEL="$STATE_DIR/watcher-stop-requested"
REVIVE_HISTORY="$STATE_DIR/watcher-revive-history.txt"
REVIVED_MARKER="$STATE_DIR/watcher-revived"

if [[ -x "$_cfg" ]]; then
    INTERVAL="${MONITOR_INTERVAL:-$("$_cfg" monitor.interval_seconds 60)}"
    LOOP_LIMIT="${MONITOR_WATCHER_SUPERVISOR_LOOP_LIMIT:-$("$_cfg" monitor.watcher_supervisor.loop_limit 5)}"
    LOOP_WINDOW="${MONITOR_WATCHER_SUPERVISOR_LOOP_WINDOW_SECONDS:-$("$_cfg" monitor.watcher_supervisor.loop_window_seconds 600)}"
else
    INTERVAL="${MONITOR_INTERVAL:-60}"
    LOOP_LIMIT="${MONITOR_WATCHER_SUPERVISOR_LOOP_LIMIT:-5}"
    LOOP_WINDOW="${MONITOR_WATCHER_SUPERVISOR_LOOP_WINDOW_SECONDS:-600}"
fi
[[ "$INTERVAL" =~ ^[0-9]+$ ]] || INTERVAL=60
[[ "$LOOP_LIMIT" =~ ^[0-9]+$ ]] || LOOP_LIMIT=5
[[ "$LOOP_WINDOW" =~ ^[0-9]+$ ]] || LOOP_WINDOW=600

_log() { printf '%s [revive-watcher] %s\n' "$(date -Is 2>/dev/null || echo '?')" "$*" >&2; }

# Intentional stop wins — never fight a deliberate `svc.sh stop watcher`.
if [[ -f "$STOP_SENTINEL" ]]; then
    _log "watcher-stop-requested present ($STOP_SENTINEL) — intentional stop, NOT reviving"
    exit 0
fi

# Already alive? (race: the watcher came back on its own between the
# Monitor firing and this running.) No-op success.
_watcher_alive "$STATE_DIR" "$INTERVAL"
if (( $? <= 1 )); then
    _log "watcher already alive — nothing to revive"
    exit 0
fi

reason=$(_watcher_reason "$STATE_DIR" 2>/dev/null || echo 'not alive')

# Read-only-filesystem short-circuit (your-org/nexus-code rofs-incident).
# A revive is IMPOSSIBLE when the project FS is read-only: svc.sh restart
# cannot write the pidfile / log / lock, so it fails — and the supervisor
# would re-fire this revive on EVERY DOWN tick, silently retry-failing for
# as long as the FS stays read-only (the ~25-min silent outage this guards).
# Detect it up front, raise a turn-INDEPENDENT operator alarm over a channel
# that does NOT touch the read-only project FS, and exit with a DISTINCT code
# so the orchestrator stops the futile retry loop. A read-only project bind
# is unrecoverable in-namespace; the only fix is a full sandbox restart.
if ! _nexus_dir_writable "$STATE_DIR"; then
    _log "watcher DOWN ($reason) AND state dir is READ-ONLY ($STATE_DIR) — revive is impossible from inside the sandbox. Restore the writable bind with a FULL SANDBOX RESTART. See skills/nexus.service-recovery."
    if _nexus_critical_alarm "watcher-rofs" "${MONITOR_ROFS_ALARM_THROTTLE_SECONDS:-120}" \
        "nexus project FS READ-ONLY (cannot write $STATE_DIR). Watcher is DOWN and cannot be revived from inside the sandbox — restart the sandbox to restore the writable mount. See skills/nexus.service-recovery."; then
        # The alarm just RANG (not throttled) — also escalate OUT-OF-BAND to
        # GitHub: file/locate the incident issue + ping the operator there and
        # on the nexus overview. Network-only + RO-FS-safe; gating on the
        # un-throttled alarm bounds the network attempt to one per window.
        # Fail-soft (`|| true`) — never let escalation abort the exit-4 path.
        _nexus_github_incident_escalate "$NEXUS_ROOT" "$STATE_DIR" "revive-watcher.sh" "$reason" || true
    fi
    exit 4
fi

# Crash-loop guard: cap revivals per window so a watcher crash-looping on
# a real fault is not revived forever (records only when it ALLOWS).
if ! guard=$(_respawn_loop_check "$REVIVE_HISTORY" "$LOOP_WINDOW" "$LOOP_LIMIT" "watcher-revive"); then
    _log "watcher DOWN ($reason) but revive guard tripped: $guard — NOT reviving (manual: monitor/svc.sh restart watcher)"
    command -v sandbox-notify >/dev/null 2>&1 && \
        sandbox-notify "revive-watcher: guard tripped ($guard) — watcher down, needs attention" >/dev/null 2>&1 || true
    exit 3
fi

# Self-failure marker (the revived watcher surfaces it). Gate on prior-
# existence evidence so a cold boot is never falsely reported as a revival.
if [[ -f "$HEARTBEAT" || -f "$PIDFILE" ]]; then
    down_est=$(_watcher_heartbeat_age "$HEARTBEAT" 2>/dev/null)
    [[ "$down_est" =~ ^[0-9]+$ ]] || down_est="?"
    {
        printf 'reason=%s\n' "$reason"
        printf 'downtime_estimate_s=%s\n' "$down_est"
        printf 'detected_at=%s\n' "$(date -Is 2>/dev/null || echo '?')"
        printf 'restarted_by=orchestrator-monitor\n'
    } > "$REVIVED_MARKER.tmp" 2>/dev/null && mv "$REVIVED_MARKER.tmp" "$REVIVED_MARKER" 2>/dev/null || true
fi

_log "watcher DOWN ($reason) — reviving via svc.sh restart watcher"
if [[ ! -x "$SVC_BIN" && ! -f "$SVC_BIN" ]]; then
    _log "svc.sh not found at $SVC_BIN — cannot revive"
    exit 1
fi
NEXUS_ROOT="$NEXUS_ROOT" bash "$SVC_BIN" restart watcher
rc=$?
if (( rc == 0 )); then
    _log "watcher revived (svc.sh restart watcher rc=0) — exactly ONE live watcher should now result (svc.sh restart is single-flight-locked + group-reaping, so never zero and never a duplicate). Verify: $NEXUS_ROOT/monitor/svc.sh status. Then re-arm the supervisor Monitor if its until-loop exited: $(_supervisor_monitor_command "$NEXUS_ROOT")"
else
    _log "watcher revive FAILED (svc.sh restart watcher rc=$rc) — watcher likely still DOWN. Re-arm the supervisor Monitor ($(_supervisor_monitor_command "$NEXUS_ROOT")); its next DOWN tick retries the revive. If it keeps failing, restart manually: $NEXUS_ROOT/monitor/svc.sh restart watcher. See skills/nexus.service-recovery."
fi
exit "$rc"
