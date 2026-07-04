#!/usr/bin/env bash
# One supervise tick — the loop body of the watcher-supervisor Monitor
# the ORCHESTRATOR arms (your-org/your-nexus watcher-supervision,
# mutual-liveness design).
#
# THE MUTUAL-LIVENESS CONTRACT. The watcher is the nexus's only
# always-on loop; it already revives the ORCHESTRATOR (orchestrator-
# liveness task). The missing half was: who revives a CRASHED watcher?
# An earlier draft added a bespoke always-on daemon; the operator chose a
# simpler, symmetric answer — the ORCHESTRATOR'S own always-on agent loop
# IS the external supervisor the watcher needs. The orchestrator arms a
# persistent `Monitor` whose until-loop runs THIS script every interval:
#
#     Monitor({command:
#       'until ! /ABS/monitor/watcher-supervise-tick.sh; do sleep 15; done'})
#
# Each tick (1) TOUCHES the supervisor-heartbeat file the watcher stats —
# proving to the watcher that a supervisor is armed — and (2) reports the
# watcher's liveness via exit code: 0 = alive (loop continues), non-zero =
# DOWN (the `until ! tick` condition becomes true, the loop exits, and the
# Monitor wakes the orchestrator). On that wake the orchestrator runs the
# revive (`monitor/revive-watcher.sh`) and re-arms the Monitor. The watcher
# reviving the orchestrator + the orchestrator reviving the watcher closes
# the circularity by MUTUALITY — no third always-on process. Both down at
# once falls to cold-boot recovery (bootstrap-recover at SessionStart).
#
# Liveness uses the exact `_watcher_alive` probe recovery + the cockpit
# use: bucket 0/1 (fresh / merely-stale-but-pid-alive) = alive; bucket
# >=2 (dead pid / no heartbeat) = DOWN. We do NOT fire on a merely-stale
# watcher — it is still running; the watcher's own machinery handles a
# wedge. Only genuine death wakes the orchestrator.
#
# Idempotent + side-effect-light: the only write is the heartbeat touch.
# Env overrides (tests): NEXUS_STATE_DIR, MONITOR_INTERVAL.

set -uo pipefail
_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_nexus_root=$(cd "$_script_dir/.." && pwd)
_cfg="$_nexus_root/config/load.sh"
# shellcheck source=watcher/_lib.sh
source "$_script_dir/watcher/_lib.sh"

STATE_DIR="${NEXUS_STATE_DIR:-$_nexus_root/monitor/.state}"
SUP_HEARTBEAT="$STATE_DIR/watcher-supervisor-heartbeat"
if [[ -x "$_cfg" ]]; then
    INTERVAL="${MONITOR_INTERVAL:-$("$_cfg" monitor.interval_seconds 60)}"
    ASYNC_FLOOR="${MONITOR_SCHEDULER_ASYNC_TIMEOUT_FLOOR:-$("$_cfg" monitor.scheduler.async_timeout_floor_seconds 300)}"
else
    INTERVAL="${MONITOR_INTERVAL:-60}"
    ASYNC_FLOOR="${MONITOR_SCHEDULER_ASYNC_TIMEOUT_FLOOR:-300}"
fi
[[ "$INTERVAL" =~ ^[0-9]+$ ]] || INTERVAL=60
[[ "$ASYNC_FLOOR" =~ ^[0-9]+$ ]] || ASYNC_FLOOR=300
# DEAD threshold for the CONTINUOUS supervisor. The heartbeat is bumped per
# compose cycle, and a stalled cycle is killed + re-armed by the watcher's own
# async hang-watchdog whose budget is max(4×interval, async_timeout_floor)
# (typically 300s). If the supervisor declared DOWN at exactly that budget it
# would race the self-recovery and restart a watcher that was about to heal —
# the zero-margin bug. We set DOWN to ABOVE the watchdog budget (its effective
# value + 2×interval headroom for the re-armed cycle to complete and bump),
# floored at the usual 5×interval, so a SINGLE transient stall recovers on its
# own (no restart) while a PERSISTENT wedge still trips DOWN.
_watchdog_budget=$(( INTERVAL * 4 )); (( _watchdog_budget < ASYNC_FLOOR )) && _watchdog_budget=$ASYNC_FLOOR
DEAD_CUTOFF=$(( _watchdog_budget + INTERVAL * 2 ))
(( DEAD_CUTOFF < INTERVAL * 5 )) && DEAD_CUTOFF=$(( INTERVAL * 5 ))

mkdir -p "$STATE_DIR" 2>/dev/null || true
# (1) Prove the supervisor is armed: touch the heartbeat the watcher stats.
_hb_written=0
if { : > "$SUP_HEARTBEAT.tmp"; } 2>/dev/null && mv "$SUP_HEARTBEAT.tmp" "$SUP_HEARTBEAT" 2>/dev/null; then
    _hb_written=1
elif touch "$SUP_HEARTBEAT" 2>/dev/null; then
    _hb_written=1
fi

# (1b) Read-only-filesystem guard (your-org/nexus-code rofs-incident).
# If the heartbeat write just failed, the project FS may be read-only — the
# failure mode where the watcher dies on EROFS and NO revive can succeed
# from inside the sandbox. Confirm with a writability probe and, if it IS
# read-only, raise a turn-INDEPENDENT operator alarm over a channel that
# does NOT touch the read-only project FS (sandbox-notify + stderr,
# throttled, shared key with revive-watcher so the two never double-ring).
# We do NOT exit here — execution falls through to the liveness verdict so
# the orchestrator is still woken; the alarm guarantees the operator hears
# it even if the orchestrator's own revive loop is itself wedged on EROFS.
if (( ! _hb_written )) && ! _nexus_dir_writable "$STATE_DIR"; then
    if _nexus_critical_alarm "watcher-rofs" "${MONITOR_ROFS_ALARM_THROTTLE_SECONDS:-120}" \
        "nexus project FS READ-ONLY (cannot write $STATE_DIR). Watcher supervisor cannot maintain state and revive will fail — restart the sandbox to restore the writable mount. See skills/nexus.service-recovery."; then
        # Alarm rang (not throttled) — also escalate to GitHub out-of-band:
        # incident issue + nexus-overview comment, both pinging the operator,
        # so a watcher-down-on-RO-FS reaches them even with an unattended
        # terminal. Network-only + RO-FS-safe; fail-soft so the tick still
        # falls through to the DOWN verdict below and wakes the orchestrator.
        _nexus_github_incident_escalate "$_nexus_root" "$STATE_DIR" "watcher-supervise-tick.sh" \
            "$(_watcher_reason "$STATE_DIR" 2>/dev/null || echo 'not alive')" || true
    fi
fi

# (2) Report watcher liveness via exit code.
#
# The heartbeat is now bumped ONLY at the end of a correct compose cycle
# (nexus-code#236), so _watcher_alive's heartbeat-age buckets ALREADY mean
# "the loop completed a cycle recently": a fresh heartbeat proves the loop
# works (even on a deliberately-silent quiet workspace), and a stale heartbeat
# means the loop is wedged. No separate emit-functional probe is needed — the
# heartbeat IS the functional signal. We pass DEAD_CUTOFF (above the watcher's
# own async hang-watchdog budget) so a SINGLE transient stall is killed + healed
# by the watcher itself before the supervisor would restart it; only a
# PERSISTENT wedge (heartbeat stale past DEAD_CUTOFF) trips DOWN.
_watcher_alive "$STATE_DIR" "$INTERVAL" "$DEAD_CUTOFF"
rc=$?
if (( rc <= 1 )); then
    exit 0   # alive (fresh or stale-but-pid-alive) — Monitor loop continues
fi
# DOWN — print the FULL recovery (lands in the Monitor's exit report) and
# exit non-zero so `until ! tick` exits and wakes the orchestrator. The
# message is self-descriptive (exact revive + re-arm commands + skill
# pointer) so a naive orchestrator reading only this block recovers
# without prior knowledge — symmetric with the arm-emit GOLD STANDARD.
_supervisor_down_recovery_message \
    "$(_watcher_reason "$STATE_DIR" 2>/dev/null || echo 'not alive')" "$_nexus_root" >&2
exit 1
