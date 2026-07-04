#!/usr/bin/env bash
# Nexus monitor — continuous service-health watch (your-org/your-nexus
# service-health-watch).
#
# Background — the gap this closes. Before this module the watcher did
# NOT continuously monitor service health. A registered infra service
# (monitor/services.registry) was protected only by:
#   (a) its own `*-supervised.sh` restart-loop wrapper, which silently
#       re-launches a crashed *process* but emits nothing and does not
#       notice a process that is alive-but-wedged (HTTP hung, healthcheck
#       failing); and
#   (b) bootstrap-recover.sh --services-only, called ONLY at cockpit
#       bootstrap (watcher/bootstrap.sh), never on a loop.
# So a service that wedged, or whose supervisor wrapper itself died,
# was never detected, restarted, or surfaced to the orchestrator. This
# module adds the missing periodic detection → minimal-downtime
# auto-restart → orchestrator emit chain.
#
# Where it sits in the watcher:
#   - `_service_health_check_tick` is the scheduler task body (registered
#     `service_health`, --async, ~120 s default cadence). Each fire runs
#     every registry service's column-4 healthcheck. A freshly-unhealthy
#     service is FIRST given a grace window to self-heal via its own
#     supervisor wrapper (no watcher action); only one still unhealthy
#     after grace is acted on, and then ONLY per its restart policy
#     (auto-restart vs emit-only). It records a per-service incident
#     state file at every step.
#
# RESTART vs INVESTIGATE vs EMIT (your-org/nexus-code#283 design follow-up):
#   The watcher must not fight the per-service `*-supervised.sh` wrapper,
#   which already self-heals a crashed process. So:
#     - GRACE FIRST. A fresh failure does not trigger a restart; the
#       wrapper gets `MONITOR_SERVICE_HEALTH_GRACE_SECONDS` to recover the
#       process. Survives grace ⇒ wedged / wrapper-dead ⇒ the watcher acts.
#       This is the "without restarting unnecessarily" fix.
#     - HONOR PER-SERVICE POLICY (registry 6th column / default knob):
#       `auto-restart` (grace → restart → emit) for the clearly-recoverable,
#       `emit-only` (escalate, never auto-restart) for services where a
#       blind restart is unsafe or wants human judgment.
#     - THE EMIT ALWAYS CARRIES THE FULL STATE regardless of which path
#       fired (detected / in-grace / restart attempted + outcome /
#       escalation / policy in effect), so the orchestrator retains full
#       intervention capacity and is nagged only for what needs judgment.
#   - `_service_health_emit_section` is consumed by compose_emit to
#     surface the down / recovering / flapping / recovered conditions to
#     the orchestrator (re-nag guarded so a persistently-down service
#     does not spam every loop). It mirrors the cc-update / version-drift
#     emit-surfacing model verbatim.
#
# DETECTION keys on the REGISTRY HEALTHCHECK (the column-4 command), never
# on tmux window / worker heuristics. Registry-listed service windows are
# already exempt from the watcher's worker-dead detection in
# `_idle_probe.sh:_idle_list_worker_windows` (the `$1 in svc { next }`
# predicate, your-org/your-nexus#204) — that exemption is what stops the
# historical false-positive where a healthy serve window got misflagged a
# dead worker. This module does NOT touch that path; it is an independent,
# registry-keyed health surface.
#
# REUSE, not reimplementation:
#   - the healthcheck evaluation is the exact `( cd workdir && bash -c
#     health )` semantics of bootstrap-recover.sh's `_recover_service_healthy`
#     (:309). It is replicated as a 3-line local (`_sh_service_healthy`)
#     ONLY to avoid `source`-ing bootstrap-recover.sh into the watcher
#     process — that script redefines `log()` and ~a dozen run-mode
#     globals (DO_WATCHER, DRY_RUN, STATE_DIR, …) at source time and would
#     clobber main.sh's. There is no health *logic* here to drift.
#   - the RESTART action delegates to `monitor/svc.sh restart <name>` (a
#     separate process, no clobber), which internally reuses
#     `recover_service()` for the relaunch AND stops a live-but-wedged
#     supervisor's process group first (`_stop_service`). That stop step
#     is precisely what fixes the wedged case bare `recover_service`
#     cannot (it would defer to the live supervisor, "supervisor-alive").
#     svc.sh restart is also the exact command the orchestrator-recovery
#     skill documents — single source of truth for "restart one service".
#
# State files (under `$SERVICE_HEALTH_STATE_DIR`, default
# `monitor/.state/service-health/`):
#   <name>.state      current-incident record (key=value, _version_field
#                     style). status, first_unhealthy, restart_attempts,
#                     last_restart, the failing healthcheck, logfile, etc.
#   <name>.events     append-only TAB log of every transition + restart
#                     attempt (iso<TAB>event<TAB>detail) — the durable
#                     incident history the `ng service-incident` generator
#                     reads so the issue prose cannot drift from fact.
#   <name>-surfaced   emit re-nag guard (the status:attempts key last
#                     surfaced), mirroring drift-<comp>-surfaced.
#
# NEVER degrade or falsify the service to make a healthcheck pass — the
# operator's explicit constraint. The only action taken is an honest
# restart; if that cannot restore the service within the flap ceiling the
# incident escalates to "won't-recover" and waits for the orchestrator.

# ---- double-source guard ------------------------------------------------
if [[ -n "${_NEXUS_SERVICE_HEALTH_LOADED:-}" ]]; then
    return 0
fi
_NEXUS_SERVICE_HEALTH_LOADED=1

# ---- config / path resolution -------------------------------------------
# All overridable so tests can aim the module at a throwaway fixture tree
# and never touch the live state dir, registry, or svc.sh. Defaults match
# the rest of the stack (STATE_DIR is main.sh's; NEXUS_ROOT the live root).

# Per-service incident state directory.
: "${SERVICE_HEALTH_STATE_DIR:=${STATE_DIR:-}/service-health}"

# The registry path resolves the same way the rest of the stack does:
# $NEXUS_SERVICES_REGISTRY override, else $NEXUS_ROOT/monitor/services.registry,
# else this file's sibling monitor dir. Mirrors _idle_registry_service_names.
_sh_registry_path() {
    local registry="${NEXUS_SERVICES_REGISTRY:-}"
    if [[ -z "$registry" ]]; then
        if [[ -n "${NEXUS_ROOT:-}" ]]; then
            registry="$NEXUS_ROOT/monitor/services.registry"
        else
            registry="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/services.registry"
        fi
    fi
    printf '%s\n' "$registry"
}

# Path to svc.sh — the restart surface. Test override:
# SERVICE_HEALTH_SVC_BIN.
_sh_svc_bin() {
    printf '%s\n' "${SERVICE_HEALTH_SVC_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/svc.sh}"
}

# Knobs (resolved by main.sh's _config.sh; defaulted here so the module is
# usable when sourced standalone in a test that doesn't set them).
#   interval      — cadence of the service_health task (registration time).
#   grace         — seconds a freshly-unhealthy service is given to recover
#                   ON ITS OWN (its *-supervised.sh wrapper's self-heal)
#                   BEFORE the watcher takes any action. This is the key
#                   "don't restart unnecessarily" knob: a process-crash the
#                   wrapper relaunches heals within grace and the watcher
#                   never touches it; only a service STILL unhealthy after
#                   grace (wedged process, or dead wrapper) is acted on.
#                   0 = act on first detection (legacy behaviour).
#   cooldown      — min seconds between restart attempts on the SAME service.
#   flap_ceiling  — max restart attempts within ONE incident before the
#                   watcher gives up and escalates "won't-recover".
#   default_policy — per-service restart policy applied to registry rows
#                   that don't declare one (6th column). 'auto-restart'
#                   (grace → restart → emit) or 'emit-only' (never auto-
#                   restart; emit and let the orchestrator decide).
: "${MONITOR_SERVICE_HEALTH_GRACE_SECONDS:=30}"
: "${MONITOR_SERVICE_HEALTH_RESTART_COOLDOWN_SECONDS:=300}"
: "${MONITOR_SERVICE_HEALTH_FLAP_CEILING:=3}"
: "${MONITOR_SERVICE_HEALTH_DEFAULT_POLICY:=auto-restart}"
[[ "$MONITOR_SERVICE_HEALTH_GRACE_SECONDS" =~ ^[0-9]+$ ]] \
    || MONITOR_SERVICE_HEALTH_GRACE_SECONDS=30
[[ "$MONITOR_SERVICE_HEALTH_RESTART_COOLDOWN_SECONDS" =~ ^[0-9]+$ ]] \
    || MONITOR_SERVICE_HEALTH_RESTART_COOLDOWN_SECONDS=300
[[ "$MONITOR_SERVICE_HEALTH_FLAP_CEILING" =~ ^[0-9]+$ ]] \
    || MONITOR_SERVICE_HEALTH_FLAP_CEILING=3
case "$MONITOR_SERVICE_HEALTH_DEFAULT_POLICY" in
    auto-restart|emit-only) ;;
    *) MONITOR_SERVICE_HEALTH_DEFAULT_POLICY=auto-restart ;;
esac

# Recognised per-service restart policies. A registry row's optional 6th
# column selects one; an empty/missing/unknown value falls back to
# $MONITOR_SERVICE_HEALTH_DEFAULT_POLICY.
#   auto-restart  grace → minimal-downtime restart (flap-controlled) → emit.
#   emit-only     never auto-restart; on a post-grace failure emit and defer
#                 to the orchestrator (for services where a blind restart is
#                 unsafe or wants human judgment).
_sh_resolve_policy() {
    local p="${1:-}"
    p="${p//[[:space:]]/}"
    case "$p" in
        auto-restart|emit-only) printf '%s\n' "$p" ;;
        "") printf '%s\n' "${MONITOR_SERVICE_HEALTH_DEFAULT_POLICY:-auto-restart}" ;;
        *)  _sh_log "unknown restart policy '$p'; using default '${MONITOR_SERVICE_HEALTH_DEFAULT_POLICY:-auto-restart}'"
            printf '%s\n' "${MONITOR_SERVICE_HEALTH_DEFAULT_POLICY:-auto-restart}" ;;
    esac
}

# ---- clock indirection (test-injectable) --------------------------------
# Mirrors the scheduler's nexus_clock: tests set NEXUS_TEST_NOW to a fixed
# epoch and advance it between ticks to simulate elapsed time.
_sh_now() {
    if [[ -n "${NEXUS_TEST_NOW:-}" ]]; then
        printf '%s\n' "$NEXUS_TEST_NOW"
    else
        date +%s
    fi
}
_sh_iso() {
    if [[ -n "${NEXUS_TEST_NOW:-}" ]]; then
        date -d "@${NEXUS_TEST_NOW}" -Is 2>/dev/null || printf '@%s\n' "$NEXUS_TEST_NOW"
    else
        date -Is 2>/dev/null || echo unknown
    fi
}

# stderr log. In production the tick runs in the scheduler's async
# subshell, whose stderr is replayed into watcher.log on every reap
# (_scheduler_reap_async). `log` (main.sh's) is preferred when present.
_sh_log() {
    if declare -F log >/dev/null 2>&1; then
        log "service-health: $*"
    else
        echo "[service-health] $*" >&2
    fi
}

# ---- registry parsing ---------------------------------------------------
# Emit one `name<TAB>workdir<TAB>launch<TAB>health<TAB>logfile<TAB>policy`
# record per service. Mirrors bootstrap-recover.sh's `_recover_parse_registry`
# line handling (skip blanks/#, require 4 TAB fields, expand ~ and
# $NEXUS_ROOT in workdir + logfile) so the two stay in lock-step. The 6th
# `policy` column is OPTIONAL and additive — resolved through
# `_sh_resolve_policy` (default when empty/unknown). The sibling parsers in
# bootstrap-recover.sh / _version_restart.sh absorb-and-ignore the 6th
# field so its presence can never corrupt their `logfile` (read's
# trailing-remainder rule), keeping every registry reader lock-step.
_sh_parse_registry() {
    local file; file="$(_sh_registry_path)"
    [[ -f "$file" ]] || return 0
    local line name workdir launch health logfile policy
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        IFS=$'\t' read -r name workdir launch health logfile policy <<<"$line"
        if [[ -z "$name" || -z "$workdir" || -z "$launch" || -z "$health" ]]; then
            continue
        fi
        workdir="${workdir/#\~/$HOME}"
        workdir="${workdir//\$NEXUS_ROOT/${NEXUS_ROOT:-}}"
        logfile="${logfile/#\~/$HOME}"
        logfile="${logfile//\$NEXUS_ROOT/${NEXUS_ROOT:-}}"
        policy="$(_sh_resolve_policy "$policy")"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$workdir" "$launch" "$health" "$logfile" "$policy"
    done < "$file"
}

# ---- per-service healthcheck (reuse of _recover_service_healthy:309) -----
# Run the registry healthcheck in the service's workdir; exit 0 == healthy.
# IDENTICAL semantics to bootstrap-recover.sh's `_recover_service_healthy`
# — replicated inline (3 lines, no logic to drift) to avoid sourcing that
# script into the watcher process. See the module header.
_sh_service_healthy() {
    local workdir="$1" health="$2"
    ( cd "$workdir" 2>/dev/null && bash -c "$health" ) >/dev/null 2>&1
}

# ---- state-file helpers -------------------------------------------------
_sh_state_file()    { printf '%s/%s.state'    "$SERVICE_HEALTH_STATE_DIR" "$1"; }
_sh_events_file()   { printf '%s/%s.events'   "$SERVICE_HEALTH_STATE_DIR" "$1"; }
# (No <name>-surfaced helper here on purpose: the surfaced-file path is
# derived only inside `_service_health_emit_section`, which is
# parameterized on its OWN $1 state_dir — an env-keyed helper like the
# two above would silently diverge from that parameter.)

# Read one key=value field (mirrors _version_field). rc 1 + empty on miss.
_sh_field() {
    local file="${1:?}" key="${2:?}"
    [[ -f "$file" ]] || return 1
    local out
    out=$(awk -F= -v k="$key" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$file")
    [[ -n "$out" ]] || return 1
    printf '%s\n' "$out"
}

# Append one TAB event row to the incident history (durable; the issue
# generator reads it). Best-effort.
_sh_record_event() {
    local name="$1" event="$2" detail="${3:-}"
    local ef; ef="$(_sh_events_file "$name")"
    mkdir -p "$SERVICE_HEALTH_STATE_DIR" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "$(_sh_iso)" "$event" "$detail" >> "$ef" 2>/dev/null || true
}

# Atomically (tmp+rename) write the current-incident state file from the
# key=value pairs passed as `key=value` args.
_sh_write_state() {
    local name="$1"; shift
    local sf; sf="$(_sh_state_file "$name")"
    mkdir -p "$SERVICE_HEALTH_STATE_DIR" 2>/dev/null || true
    { local kv; for kv in "$@"; do printf '%s\n' "$kv"; done; } \
        > "$sf.tmp.$$" 2>/dev/null && mv "$sf.tmp.$$" "$sf" 2>/dev/null \
        || { rm -f "$sf.tmp.$$" 2>/dev/null; return 1; }
    return 0
}

# ---- restart action (reuse of svc.sh restart → recover_service) ---------
# Delegate to `svc.sh restart <name>` (separate process: no log/global
# clobber). It stops a live-but-wedged supervisor's process group, then
# relaunches via recover_service. Returns svc.sh's rc. Test override:
# SERVICE_HEALTH_SVC_BIN can point at a capture stub.
_sh_restart_service() {
    local name="$1"
    local svc; svc="$(_sh_svc_bin)"
    if [[ ! -x "$svc" && ! -f "$svc" ]]; then
        _sh_log "svc.sh not found at $svc — cannot auto-restart '$name'"
        return 127
    fi
    bash "$svc" restart "$name" >&2
}

# ---- the scheduler task body --------------------------------------------
# One health evaluation across every registry service. The state machine
# is grace-gated and policy-aware so the watcher restarts only what
# genuinely needs it, and the orchestrator's attention is reserved for
# what needs judgment:
#
#   healthy   → if an incident was open, mark it `recovered` (the emit
#               section surfaces a one-shot breadcrumb, then closes it),
#               recording WHETHER it self-healed within grace (no watcher
#               restart) or held after a watcher restart; otherwise nothing.
#   unhealthy, within grace  → status `grace`. Do NOT act: give the
#               service's own *-supervised.sh wrapper its self-heal window
#               first. A process-crash the wrapper relaunches recovers here
#               and the watcher never restarts it (the "don't restart
#               unnecessarily" fix). grace=0 disables the defer (legacy
#               act-on-first-detection).
#   unhealthy, grace elapsed, policy emit-only → status `emit-only`. Never
#               auto-restart; escalate to the orchestrator (a blind restart
#               is unsafe / wants human judgment for this service).
#   unhealthy, grace elapsed, policy auto-restart → flap-controlled
#               minimal-downtime `svc.sh restart`. The NEXT tick judges
#               whether it took (healthy ⇒ recovered; still unhealthy ⇒ the
#               attempt counts toward the ceiling, then `flapping`
#               escalates). Never re-checks health synchronously right after
#               the restart — recover_service relaunches async, so an
#               immediate probe would false-negative.
#
# The grace window is what discriminates process-down-wrapper-will-recover
# (heals within grace, deferred to the wrapper) from wedged / wrapper-dead
# (still down after grace — the watcher must act). It needs no coupling to
# the supervisor pidfile: surviving the grace window IS the signal.
#
# All state is on-disk, so running this --async in a subshell is safe.
_service_health_check_tick() {
    : "${SERVICE_HEALTH_STATE_DIR:=${STATE_DIR:-}/service-health}"
    [[ -n "${SERVICE_HEALTH_STATE_DIR%/service-health}" ]] || return 0
    mkdir -p "$SERVICE_HEALTH_STATE_DIR" 2>/dev/null || true

    local grace="${MONITOR_SERVICE_HEALTH_GRACE_SECONDS:-30}"
    local cooldown="${MONITOR_SERVICE_HEALTH_RESTART_COOLDOWN_SECONDS:-300}"
    local ceiling="${MONITOR_SERVICE_HEALTH_FLAP_CEILING:-3}"
    [[ "$grace" =~ ^[0-9]+$ ]] || grace=30
    [[ "$cooldown" =~ ^[0-9]+$ ]] || cooldown=300
    [[ "$ceiling" =~ ^[0-9]+$ ]] || ceiling=3

    local now; now="$(_sh_now)"
    local name workdir launch health logfile policy
    while IFS=$'\t' read -r name workdir launch health logfile policy; do
        [[ -n "$name" ]] || continue
        [[ -n "$policy" ]] || policy="$(_sh_resolve_policy "")"
        local sf; sf="$(_sh_state_file "$name")"
        local prev_status="" attempts=0 first_unhealthy="" first_iso="" last_restart=0
        if [[ -f "$sf" ]]; then
            prev_status=$(_sh_field "$sf" status 2>/dev/null || true)
            attempts=$(_sh_field "$sf" restart_attempts 2>/dev/null || echo 0)
            first_unhealthy=$(_sh_field "$sf" first_unhealthy 2>/dev/null || echo "")
            first_iso=$(_sh_field "$sf" first_unhealthy_iso 2>/dev/null || echo "")
            last_restart=$(_sh_field "$sf" last_restart 2>/dev/null || echo 0)
        fi
        [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
        [[ "$last_restart" =~ ^[0-9]+$ ]] || last_restart=0

        if _sh_service_healthy "$workdir" "$health"; then
            # --- healthy ---
            if [[ -n "$prev_status" && "$prev_status" != "healthy" && "$prev_status" != "recovered" ]]; then
                # Transition unhealthy → healthy. Distinguish a within-grace
                # self-heal (the supervisor wrapper recovered it; the watcher
                # never restarted) from a watcher-restart that held — the
                # emit + incident report read this to tell the orchestrator
                # which actually happened.
                local recovered_via
                if [[ "$attempts" -gt 0 ]]; then
                    recovered_via="held after ${attempts} watcher restart attempt(s)"
                elif [[ "$prev_status" == "grace" ]]; then
                    recovered_via="self-healed within grace (supervisor recovered it; watcher did not restart)"
                else
                    recovered_via="self-healed (no watcher restart)"
                fi
                _sh_record_event "$name" recovered "${recovered_via}; status was ${prev_status}"
                _sh_write_state "$name" \
                    "service=$name" \
                    "status=recovered" \
                    "policy=${policy}" \
                    "first_unhealthy=${first_unhealthy}" \
                    "first_unhealthy_iso=${first_iso}" \
                    "recovered_at=${now}" \
                    "recovered_at_iso=$(_sh_iso)" \
                    "restart_attempts=${attempts}" \
                    "recovered_via=${recovered_via}" \
                    "health_cmd=${health}" \
                    "logfile=${logfile}" \
                    "last_check=${now}"
            fi
            continue
        fi

        # --- unhealthy ---
        local fresh=0
        if [[ -z "$prev_status" || "$prev_status" == "healthy" || "$prev_status" == "recovered" ]]; then
            # Fresh incident.
            fresh=1
            first_unhealthy="$now"
            first_iso="$(_sh_iso)"
            attempts=0
            last_restart=0
            _sh_record_event "$name" detected-unhealthy "healthcheck failed: ${health} (policy ${policy})"
            _sh_log "service '$name' UNHEALTHY (healthcheck: ${health}; policy ${policy})"
        fi

        # Wall-clock since first detection — the grace gate. Robust to the
        # tick cadence (it measures real elapsed time, not tick count).
        local elapsed=$(( now - first_unhealthy ))
        (( elapsed >= 0 )) || elapsed=0

        local status note=""
        if (( elapsed < grace )); then
            # --- grace window: defer to the supervisor wrapper's self-heal.
            status="grace"
            note="unhealthy ${elapsed}s; deferring to supervisor self-heal for grace ${grace}s before acting (policy ${policy})"
            [[ "$fresh" == 1 ]] && _sh_record_event "$name" grace-started \
                "deferring ${grace}s to supervisor self-heal before acting (policy ${policy})"
        elif [[ "$policy" == "emit-only" ]]; then
            # --- policy forbids auto-restart: escalate, never restart.
            status="emit-only"
            if [[ "$prev_status" != "emit-only" ]]; then
                _sh_record_event "$name" escalate-emit-only \
                    "grace elapsed, still unhealthy; policy emit-only — no auto-restart, orchestrator decides"
                _sh_log "service '$name' DOWN past grace; policy emit-only — escalating to orchestrator (no auto-restart)"
            fi
            note="policy emit-only — watcher will NOT auto-restart; orchestrator decides"
        elif [[ "$prev_status" == "flapping" ]] || (( attempts >= ceiling )); then
            # --- flap ceiling reached — stop thrashing, escalate. Re-arms
            #     only when the service becomes healthy again (incident closes).
            if [[ "$prev_status" != "flapping" ]]; then
                _sh_record_event "$name" flap-ceiling-reached "${attempts} restart attempt(s) within incident; giving up auto-restart"
                _sh_log "service '$name' FLAPPING — ${attempts} restarts did not hold; escalating (won't-recover)"
            fi
            status="flapping"
            note="auto-restart ceiling (${ceiling}) reached after ${attempts} attempts; needs orchestrator"
        elif (( last_restart > 0 && now - last_restart < cooldown )); then
            # --- in cooldown after a recent restart — wait it out.
            status="recovering"
            note="restart issued ${attempts}x; waiting out ${cooldown}s cooldown (last $(( now - last_restart ))s ago)"
        else
            # --- act: minimal-downtime restart (policy auto-restart, grace
            #     elapsed, wedged or wrapper-dead).
            _sh_log "service '$name' restart attempt $(( attempts + 1 ))/${ceiling} via svc.sh restart (policy ${policy})"
            local rc=0
            _sh_restart_service "$name" || rc=$?
            attempts=$(( attempts + 1 ))
            last_restart="$now"
            status="recovering"
            if (( rc == 0 )); then
                _sh_record_event "$name" restart-issued "attempt ${attempts}/${ceiling} (svc.sh restart rc=0)"
                note="restart attempt ${attempts}/${ceiling} issued; next tick verifies"
            else
                _sh_record_event "$name" restart-failed "attempt ${attempts}/${ceiling} (svc.sh restart rc=${rc})"
                note="restart attempt ${attempts}/${ceiling} returned rc=${rc}; next tick verifies"
            fi
        fi

        _sh_write_state "$name" \
            "service=$name" \
            "status=${status}" \
            "policy=${policy}" \
            "first_unhealthy=${first_unhealthy}" \
            "first_unhealthy_iso=${first_iso}" \
            "restart_attempts=${attempts}" \
            "last_restart=${last_restart}" \
            "last_check=${now}" \
            "last_check_iso=$(_sh_iso)" \
            "grace_seconds=${grace}" \
            "health_cmd=${health}" \
            "workdir=${workdir}" \
            "logfile=${logfile}" \
            "note=${note}"
    done < <(_sh_parse_registry)
    return 0
}

# ---- emit surfacing -----------------------------------------------------
# Render every UNSURFACED service-health incident for the orchestrator,
# and advance the re-nag guard. Mirrors _version_emit_section / the
# cc-update model: stdout = section body (empty when nothing new), rc 0
# when anything emitted, 1 otherwise.
#
# Re-nag guard keys on `status:restart_attempts` so:
#   - first detection emits;
#   - a still-down/in-cooldown/in-grace repeat with the SAME attempt count
#     is suppressed (no spam every loop);
#   - a NEW restart attempt (attempts++) or a status change (grace →
#     recovering / emit-only / flapping) RE-surfaces, so the orchestrator
#     sees progress;
#   - a `recovered` breadcrumb is surfaced exactly once, then the incident
#     state is CLOSED (state + surfaced files removed; the .events history
#     is kept as the durable record for `ng service-incident`).
# compose_emit's content-hash dedup is the belt-and-suspenders backstop.
#
# Every section line reports the POLICY in effect and the full current
# state (detected / grace-in-progress / restart attempted + outcome /
# escalation), so the orchestrator always sees what happened and keeps
# its intervention capacity — it can override, escalate, or stand down.
# Urgency is graded: `grace` is informational (no action — the watcher
# is deferring to the supervisor); `recovering` is progress; `emit-only`
# and `flapping` are escalations that need judgment.
_service_health_emit_section() {
    local state_dir="${1:-$SERVICE_HEALTH_STATE_DIR}" nexus_root="${2:-${NEXUS_ROOT:-}}"
    [[ -n "$state_dir" && -d "$state_dir" ]] || return 1
    local emitted=1 sf name status policy attempts first_iso recovered_iso recovered_via grace_seconds health logfile note key last surfaced_file
    for sf in "$state_dir"/*.state; do
        [[ -f "$sf" ]] || continue
        name=$(basename "$sf" .state)
        status=$(_sh_field "$sf" status 2>/dev/null || true)
        [[ -n "$status" ]] || continue
        policy=$(_sh_field "$sf" policy 2>/dev/null || echo 'auto-restart')
        attempts=$(_sh_field "$sf" restart_attempts 2>/dev/null || echo 0)
        first_iso=$(_sh_field "$sf" first_unhealthy_iso 2>/dev/null || echo '?')
        recovered_iso=$(_sh_field "$sf" recovered_at_iso 2>/dev/null || echo '?')
        recovered_via=$(_sh_field "$sf" recovered_via 2>/dev/null || echo '')
        grace_seconds=$(_sh_field "$sf" grace_seconds 2>/dev/null || echo '?')
        health=$(_sh_field "$sf" health_cmd 2>/dev/null || echo '?')
        logfile=$(_sh_field "$sf" logfile 2>/dev/null || echo '')
        note=$(_sh_field "$sf" note 2>/dev/null || echo '')
        surfaced_file="$state_dir/$name-surfaced"
        key="$status:$attempts"
        case "$status" in
            recovered)
                # One-shot transient-blip breadcrumb, then close the incident.
                if [[ "$recovered_via" == self-healed* ]]; then
                    printf 'service %s RECOVERED (%s): unhealthy since %s, restored ~%s.\n' \
                        "'$name'" "$recovered_via" "$first_iso" "$recovered_iso"
                else
                    printf 'service %s RECOVERED (auto-restart held): unhealthy since %s, restored ~%s after %s restart attempt(s).\n' \
                        "'$name'" "$first_iso" "$recovered_iso" "$attempts"
                fi
                printf '  Transient blip, self-resolved. No action needed; file an incident if you want a record:\n'
                printf '    %smonitor/ng service-incident %s\n' "${nexus_root:+$nexus_root/}" "$name"
                printf '\n'
                rm -f "$sf" "$surfaced_file" 2>/dev/null || true
                emitted=0
                ;;
            grace)
                # Informational only: the watcher is deferring to the
                # service's supervisor for the grace window. Surfaced once
                # (re-nag guarded) so a clean self-heal leaves at most this
                # breadcrumb + the RECOVERED line — never a restart, never a
                # nag for the orchestrator to act on.
                last=$(cat "$surfaced_file" 2>/dev/null || true)
                [[ "$last" == "$key" ]] && continue
                printf 'service %s unhealthy since %s — within the %ss grace window; deferring to its supervisor before the watcher acts.\n' \
                    "'$name'" "$first_iso" "$grace_seconds"
                printf '  failing healthcheck: %s\n' "$health"
                if [[ "$policy" == "emit-only" ]]; then
                    printf '  policy: emit-only — if still unhealthy after grace the watcher will escalate (no auto-restart).\n'
                else
                    printf '  policy: %s — if still unhealthy after grace the watcher will auto-restart.\n' "$policy"
                fi
                printf '  No action needed yet (informational). incident state: %s\n' "$sf"
                printf '\n'
                printf '%s\n' "$key" > "$surfaced_file" 2>/dev/null || true
                emitted=0
                ;;
            emit-only)
                # Escalation: policy forbids auto-restart, so this is the
                # orchestrator's call. Surfaced once per incident.
                last=$(cat "$surfaced_file" 2>/dev/null || true)
                [[ "$last" == "$key" ]] && continue
                printf 'service %s DOWN since %s — policy emit-only: the watcher will NOT auto-restart; this needs your judgment.\n' \
                    "'$name'" "$first_iso"
                printf '  failing healthcheck: %s\n' "$health"
                printf '  policy: emit-only\n'
                [[ -n "$logfile" ]] && printf '  logfile: %s\n' "$logfile"
                printf '  incident state: %s   (history: %s)\n' "$sf" "$state_dir/$name.events"
                printf '  ACTION (skills/nexus.service-recovery): decide, then if a restart is safe restore first + dispatch a root-cause worker + open an incident issue.\n'
                printf '    restart now:    %smonitor/svc.sh restart %s\n' "${nexus_root:+$nexus_root/}" "$name"
                printf '    incident issue: %smonitor/ng service-incident %s\n' "${nexus_root:+$nexus_root/}" "$name"
                printf '\n'
                printf '%s\n' "$key" > "$surfaced_file" 2>/dev/null || true
                emitted=0
                ;;
            down|recovering|flapping)
                last=$(cat "$surfaced_file" 2>/dev/null || true)
                [[ "$last" == "$key" ]] && continue
                case "$status" in
                    flapping)
                        printf 'service %s DOWN and NOT auto-recovering (FLAPPING): unhealthy since %s; %s restart attempt(s) did not hold.\n' \
                            "'$name'" "$first_iso" "$attempts" ;;
                    recovering)
                        printf 'service %s unhealthy since %s — auto-restart in progress (%s attempt(s)).\n' \
                            "'$name'" "$first_iso" "$attempts" ;;
                    *)
                        printf 'service %s DOWN since %s — watcher is auto-restarting.\n' \
                            "'$name'" "$first_iso" ;;
                esac
                printf '  failing healthcheck: %s\n' "$health"
                printf '  policy: %s\n' "$policy"
                [[ -n "$note" ]] && printf '  auto-restart: %s\n' "$note"
                [[ -n "$logfile" ]] && printf '  logfile: %s\n' "$logfile"
                printf '  incident state: %s   (history: %s)\n' "$sf" "$state_dir/$name.events"
                if [[ "$status" == "flapping" ]]; then
                    printf '  ACTION (skills/nexus.service-recovery): restore first, then dispatch a root-cause worker + open an operator incident issue.\n'
                    printf '    restart now:   %smonitor/svc.sh restart %s\n' "${nexus_root:+$nexus_root/}" "$name"
                    printf '    incident issue: %smonitor/ng service-incident %s\n' "${nexus_root:+$nexus_root/}" "$name"
                else
                    printf '  See skills/nexus.service-recovery; incident report: %smonitor/ng service-incident %s\n' \
                        "${nexus_root:+$nexus_root/}" "$name"
                fi
                printf '\n'
                printf '%s\n' "$key" > "$surfaced_file" 2>/dev/null || true
                emitted=0
                ;;
        esac
    done
    return $emitted
}
