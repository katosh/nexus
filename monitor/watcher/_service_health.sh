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

# ---- shared labsh build-evidence predicate -------------------------------
# One definition of "is this process OUR labsh cold build?", shared with
# monitor/labsh-supervised.sh's reaper so the two layers cannot drift
# (your-org/nexus-code#467). Sourcing is guarded: if the file is absent (a
# partial deploy, an old checkout), `_sh_labsh_build_in_progress` fails closed
# and returns 1 — the ordinary restart machinery proceeds, which is the safe
# direction for a watchdog. Overridable so tests can aim at a fixture copy.
: "${SERVICE_HEALTH_LABSH_EVIDENCE:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/_labsh_build_evidence.sh}"
# shellcheck source=../_labsh_build_evidence.sh
[[ -r "$SERVICE_HEALTH_LABSH_EVIDENCE" ]] && source "$SERVICE_HEALTH_LABSH_EVIDENCE"

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
#   cold_build_ceiling — belt-and-suspenders upper bound (seconds) on how
#                   long a jupyter/labsh service's failing healthcheck is
#                   excused as an in-progress COLD BUILD (see
#                   `_sh_labsh_build_in_progress`). Past this the watcher
#                   stops deferring even if a build still looks in flight —
#                   a "build" running longer than this is pathological
#                   (wedged uvx) and must be recoverable. Default 1800
#                   (30 min): well above the observed ~615 s cold build and
#                   the supervisor's 900 s START_GRACE, so a genuine cold
#                   build never trips it. 0 disables the cold-build defer
#                   entirely (legacy behaviour: restart a labsh service on
#                   grace like any other).
: "${MONITOR_SERVICE_HEALTH_GRACE_SECONDS:=30}"
: "${MONITOR_SERVICE_HEALTH_RESTART_COOLDOWN_SECONDS:=300}"
: "${MONITOR_SERVICE_HEALTH_FLAP_CEILING:=3}"
: "${MONITOR_SERVICE_HEALTH_DEFAULT_POLICY:=auto-restart}"
: "${MONITOR_SERVICE_HEALTH_COLD_BUILD_CEILING_SECONDS:=1800}"
[[ "$MONITOR_SERVICE_HEALTH_COLD_BUILD_CEILING_SECONDS" =~ ^[0-9]+$ ]] \
    || MONITOR_SERVICE_HEALTH_COLD_BUILD_CEILING_SECONDS=1800
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

# ---- supervisor record (reuse of _recover_supervisor_state) --------------
# IDENTICAL semantics to bootstrap-recover.sh's `_recover_supervisor_state`
# — replicated inline for the same reason `_sh_service_healthy` is: the
# watcher must not `source` bootstrap-recover.sh. Emits `alive:<pid>`,
# `stale:<pid>` (record present, process gone/recycled) or `absent`.
#
# The pidfile lives beside the service-health dir, under <state>/services/,
# derived from SERVICE_HEALTH_STATE_DIR so fixtures relocate both together.
_sh_services_dir() { printf '%s/services' "${SERVICE_HEALTH_STATE_DIR%/service-health}"; }
_sh_pidfile()      { printf '%s/%s.pid' "$(_sh_services_dir)" "$1"; }

_sh_supervisor_state() {
    local name="$1" launch="$2"
    local pf; pf="$(_sh_pidfile "$name")"
    [[ -f "$pf" ]] || { printf 'absent'; return 0; }
    local pid; read -r pid < "$pf" 2>/dev/null
    [[ "$pid" =~ ^[0-9]+$ ]] || { printf 'stale:%s' "${pid:-?}"; return 0; }
    kill -0 "$pid" 2>/dev/null || { printf 'stale:%s' "$pid"; return 0; }
    local cmdline_file="/proc/$pid/cmdline"
    if [[ -r "$cmdline_file" ]]; then
        local cmdline tok
        cmdline=$(tr '\0' ' ' < "$cmdline_file" 2>/dev/null)
        tok=${launch%% *}; tok=${tok##*/}
        [[ -n "$tok" && "$cmdline" == *"$tok"* ]] || { printf 'stale:%s' "$pid"; return 0; }
    fi
    printf 'alive:%s' "$pid"
}

# ---- labsh COLD-BUILD detection (your-org/nexus-code#326 follow-up) -------
# A jupyter/labsh service's healthcheck fails for the ENTIRE duration of a
# COLD `uvx` build — CPython 3.12 + jupyterlab + extensions materialised onto
# the slow NFS-backed uv cache, observed ~615 s (~10 min) on /shared. That
# window is legitimate in-progress bring-up, NOT a wedged/dead service: the
# per-service supervisor (labsh-supervised.sh, START_GRACE=900) already waits
# patiently for it — that was the #326 fix, IN THE SUPERVISOR. But this
# service-health-watch is a SEPARATE, later layer #326 never touched, and its
# short grace fires a `svc.sh restart` that KILLS the in-progress build,
# re-introducing the very kill-loop #326 fixed (live incident 2026-07-09:
# jupyter-scecho-dev-mem restart-issued 2m18s into a ~615 s cold build). These
# two helpers make the watch cold-build-aware so it defers to the (patient)
# supervisor instead of fighting it.
#
# `_sh_is_labsh_service`: name-independent — keys on the launch/health COMMAND
# being the nexus labsh wrapper / probe, so a `jupyter-<project>` row, the
# root `jupyterlab` row, and any future rename are all covered.
_sh_is_labsh_service() {
    local launch="$1" health="$2"
    [[ "$launch" == *labsh-supervised.sh* || "$health" == *jupyter-health.sh* ]]
}

# `_sh_labsh_build_in_progress`: true iff a labsh COLD BUILD is materialising
# for this service. Deliberately TIGHT so it can never mask a genuinely-dead
# service (the one regression a skeptic must rule out) — it requires BOTH:
#   (a) the build log has exposed NO live server URL yet — labsh prints the
#       "is running at" banner + http(s) URL only once jupyter-lab binds, i.e.
#       AFTER the whole uvx materialisation. A URL present ⇒ the cold phase is
#       over ⇒ NOT in progress ⇒ the ordinary grace/restart machine resumes
#       (a bound-but-wedged server is still recovered — recovery not weakened);
#   AND
#   (b) a live build PROCESS exists — either the pid labsh recorded in
#       `<wd>/.jupyter/labsh.bg.pid` is alive with a uvx/jupyter-lab cmdline,
#       or a `pgrep` finds our uvx/jupyter-lab build on the service's port
#       (a prior supervisor generation whose bg.pid we no longer hold).
# This MIRRORS labsh-supervised.sh's `reap_stale_builds` notion of an
# in-progress build, so the supervisor and the watcher agree on "a build is
# running". A dead service (no live build process) ⇒ false ⇒ restart as today.
# Only ever called on the unhealthy path (health already failing), so a live
# bg.pid here is a build, not a healthy server.
_sh_labsh_build_in_progress() {
    local workdir="$1"
    local jdir="$workdir/.jupyter"
    [[ -d "$jdir" ]] || return 1

    # (a) A live server URL in the build log ⇒ the cold build already bound;
    #     no longer "in progress". Match labsh's banner + the URL lines.
    local bglog="$jdir/labsh.bg.log"
    if [[ -f "$bglog" ]] \
       && grep -qE 'is running at|https?://[0-9A-Za-z._-]+:[0-9]+/' "$bglog" 2>/dev/null; then
        return 1
    fi

    # (b) a live build PROCESS exists, established by IDENTITY (uid + exe +
    #     cwd + this service's pidfile/port), never by an argv substring.
    #
    #     The original (b1)/(b2) decided by resemblance:
    #
    #         case "$cmd" in *jupyter-lab*|*jupyter_lab*|*uvx*) return 0 ;; esac
    #         [[ "$cmd" == *jupyter-lab* && "$cmd" == *"--port $port"* ]]
    #
    #     fed by `pgrep -u <uid> -f 'jupyter-lab'`. Both fail OPEN: ANY process
    #     whose command line contains `jupyter-lab` and the service's port
    #     silences the watchdog while the service is down. On 2026-07-09 a test
    #     fixture with exactly that argv did so — the supervisor's reaper killed
    #     the real build on the same string match, and this predicate then
    #     reported "cold build in progress" and suspended auto-restart. One
    #     resemblance both destroyed the service and muted its recovery.
    #     The `*uvx*` arm is worse still: this nexus permanently runs
    #     `uv tool uvx --from zotero-mcp-server`, whose /proc/<pid>/exe IS `uv`.
    #
    #     #465's intent is right and is preserved verbatim: a cold build in
    #     flight must not be restarted out from under itself. Only the evidence
    #     changes. `labsh_build_is_ours` is the SAME predicate the supervisor's
    #     `reap_stale_builds` now uses, so the two layers cannot drift.
    #
    #     Fail closed HERE means: unestablished ⇒ NOT in progress ⇒ the ordinary
    #     restart machinery proceeds. Never suspend recovery for a process we
    #     cannot prove is our build. Note the polarity is the opposite of the
    #     reaper's, which is precisely why one shared predicate is safer than
    #     two hand-kept-in-sync ones.
    declare -F labsh_build_is_ours >/dev/null || return 1

    local port pid
    port=$(sed -n 's/^PORT=//p' "$jdir/labsh-service.env" 2>/dev/null | head -1)

    # (b1) the pid labsh recorded for the backgrounded build.
    pid=$(cat "$jdir/labsh.bg.pid" 2>/dev/null)
    if [[ -n "$pid" ]] && labsh_build_is_ours "$pid" "$workdir" "$port"; then
        return 0
    fi

    # (b2) a build for THIS service from a prior supervisor generation whose
    #      bg.pid we no longer hold. A /proc scan under the same identity gates.
    if [[ "$port" =~ ^[0-9]+$ ]]; then
        while IFS= read -r pid; do
            [[ -n "$pid" ]] && return 0
        done < <(labsh_build_scan "$workdir" "$port")
    fi
    return 1
}

# Consecutive-poll counter for the healthy-but-unsupervised inconsistency.
# Deliberately NOT the .state file: a healthy, consistent service must leave
# no .state behind (that invariant is what keeps the emit loop quiet), and a
# service still below the surfacing threshold is not yet an incident.
_sh_inconsistent_file() { printf '%s/%s.inconsistent' "$SERVICE_HEALTH_STATE_DIR" "$1"; }

# Evidence marker written by `svc.sh restart <name>` (see _record_restart_marker
# there): `actor=<watcher|operator>` + the epoch it happened. This is what lets
# a recovery be ATTRIBUTED rather than inferred. Without it the tick can only
# reason by elimination — "green, and I didn't restart it, so it self-healed"
# — which silently relabels an operator's rescue as a transient blip.
_sh_restart_marker() { printf '%s/%s.restart' "$SERVICE_HEALTH_STATE_DIR" "$1"; }

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
# _sh_restart_service <name> [force]
# <force>=1 means WE have already ruled a labsh cold build pathological on our
# own clock (it is past our cold_build_ceiling), so svc.sh's cold-build guard
# must not re-derive that verdict from the build's process age — a different
# origin, which always reads younger than our `elapsed` and would veto this
# restart. See the clock-origin note in the state machine.
_sh_restart_service() {
    local name="$1" force="${2:-0}"
    [[ "$force" =~ ^[01]$ ]] || force=0
    local svc; svc="$(_sh_svc_bin)"
    if [[ ! -x "$svc" && ! -f "$svc" ]]; then
        _sh_log "svc.sh not found at $svc — cannot auto-restart '$name'"
        return 127
    fi
    # Close the instance-lock fd IN the svc.sh child so the long-lived service
    # it (re)spawns via _recover_launch_service can't INHERIT the flock and
    # hold it past the watcher's death. This is the FD-inheritance leak behind
    # the 2026-07-07 outage: a version-/health-restart's jupyter service kept
    # nexus-instance.lock open on a leaked fd, so after the watcher wedged and
    # died `launcher.sh --instance-status` still read `assessment=live-local`
    # (holder pid dead, flock held via the leaked fd) and every
    # revive-watcher / `svc.sh restart watcher` refused — an unrecoverable
    # outage until the operator manually rm'd the lock. Mirrors launcher.sh's
    # `{_RESTART_LOCK_FD}>&-` close-at-spawn. The brace-close MUST be a LITERAL
    # redirect word (bash scans redirects before expansion — an expansion-built
    # `10>&-` is passed as an argument, not honoured), so branch on the fd
    # being held: it is empty on a WARN-degraded start, or whenever this module
    # runs outside the watcher (e.g. under test), where the plain call is right.
    # Stamp ourselves as the actor so svc.sh's restart marker distinguishes a
    # watcher auto-restart from an operator/orchestrator intervention. The
    # recovery attribution below reads it as EVIDENCE, never infers.
    if [[ -n "${INSTANCE_LOCK_FD:-}" ]]; then
        SVC_FORCE="$force" SVC_RESTART_ACTOR=watcher bash "$svc" restart "$name" >&2 {INSTANCE_LOCK_FD}>&-
    else
        SVC_FORCE="$force" SVC_RESTART_ACTOR=watcher bash "$svc" restart "$name" >&2
    fi
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
#               THEN reconcile the supervisor record against the green
#               healthcheck: a PRESENT-but-dead pidfile means the daemon
#               outlived its wrapper and runs UNSUPERVISED — status
#               `inconsistent`, surfaced once after N consecutive polls,
#               never auto-restarted (it is healthy; a bounce would
#               manufacture the outage). Clears as `reconciled` — a one-shot
#               breadcrumb — once a live supervisor is recorded again. An
#               `absent` pidfile is NOT inconsistent (unmanaged / legacy
#               tmux-hosted services never recorded one).
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
# (still down after grace — the watcher must act). For the DOWN path it
# needs no coupling to the supervisor pidfile: surviving the grace window IS
# the signal.
#
# The HEALTHY path is where the pidfile earns its keep. Grace assumes a live
# wrapper is standing by to self-heal; nothing ever verified that. A daemon
# that outlives its supervisor stays green forever — so the healthcheck-only
# gate never fires, and the cockpit's `stale` supervisor cell was the only
# trace. That is the `inconsistent` state above: detected on the healthy
# path, surfaced through this same emit channel, and never auto-actioned.
#
# All state is on-disk, so running this --async in a subshell is safe.
_service_health_check_tick() {
    : "${SERVICE_HEALTH_STATE_DIR:=${STATE_DIR:-}/service-health}"
    [[ -n "${SERVICE_HEALTH_STATE_DIR%/service-health}" ]] || return 0
    mkdir -p "$SERVICE_HEALTH_STATE_DIR" 2>/dev/null || true

    local grace="${MONITOR_SERVICE_HEALTH_GRACE_SECONDS:-30}"
    local cooldown="${MONITOR_SERVICE_HEALTH_RESTART_COOLDOWN_SECONDS:-300}"
    local ceiling="${MONITOR_SERVICE_HEALTH_FLAP_CEILING:-3}"
    # Consecutive ticks a healthy-but-unsupervised service must persist in
    # that state before it is surfaced. >1 absorbs the inherent race in
    # _recover_launch_service (setsid forks, THEN the inner shell writes its
    # pid), during which a relaunching service legitimately reads `stale`.
    local incon_polls="${MONITOR_SERVICE_HEALTH_INCONSISTENT_POLLS:-3}"
    # A supervisor-less service is one crash from a terminal outage, so this
    # inconsistency is NEVER silently retired: it re-surfaces once per window
    # for as long as it persists. Bounded re-nag, not suppression — the
    # opposite trade-off from the DOWN path, where an operator is already
    # looking. Default 6h.
    local incon_renag="${MONITOR_SERVICE_HEALTH_INCONSISTENT_RENAG_SECONDS:-21600}"
    [[ "$grace" =~ ^[0-9]+$ ]] || grace=30
    [[ "$cooldown" =~ ^[0-9]+$ ]] || cooldown=300
    [[ "$ceiling" =~ ^[0-9]+$ ]] || ceiling=3
    [[ "$incon_polls" =~ ^[1-9][0-9]*$ ]] || incon_polls=3
    [[ "$incon_renag" =~ ^[1-9][0-9]*$ ]] || incon_renag=21600

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

        # Supervisor record, resolved once per service per tick (a kill -0 +
        # a /proc read; cheaper than the healthcheck it accompanies).
        local sup_state; sup_state="$(_sh_supervisor_state "$name" "$launch")"
        local incon_file; incon_file="$(_sh_inconsistent_file "$name")"

        if _sh_service_healthy "$workdir" "$health"; then
            # --- healthy ---
            if [[ -n "$prev_status" && "$prev_status" != "healthy" && "$prev_status" != "recovered" \
                  && "$prev_status" != "inconsistent" && "$prev_status" != "reconciled" ]]; then
                # Transition unhealthy → healthy. ATTRIBUTE the restore from
                # evidence; never infer it by elimination. Three actors can
                # take a service from red to green, and they need different
                # responses from the orchestrator:
                #
                #   watcher      we restarted it (attempts > 0).
                #   operator     someone ran `svc.sh restart` — proven by the
                #                marker svc.sh drops, not guessed. A rescue is
                #                NOT a self-heal and NOT "no action needed".
                #   supervisor   the wrapper healed it inside grace. Only
                #                claimable when a supervisor is actually ALIVE;
                #                this line used to assert it unconditionally,
                #                so a dead-supervisor outage read as a blip.
                #
                # Anything else is honestly `unknown` — say so rather than
                # inventing a comforting cause.
                local recovered_via recovered_by mk mk_actor mk_at
                mk="$(_sh_restart_marker "$name")"
                mk_actor=""; mk_at=0
                if [[ -f "$mk" ]]; then
                    mk_actor=$(_sh_field "$mk" actor 2>/dev/null || echo '')
                    mk_at=$(_sh_field "$mk" at 2>/dev/null || echo 0)
                    [[ "$mk_at" =~ ^[0-9]+$ ]] || mk_at=0
                fi
                # Is this marker RELEVANT to this incident? A restart CAUSES the
                # downtime that follows it: svc.sh stamps the marker at the top
                # of cmd_restart, then stops the service, and we only observe
                # `first_unhealthy` on the NEXT poll. So the marker is always
                # stamped strictly BEFORE the incident it explains — up to one
                # poll interval before. Requiring `mk_at >= first_unhealthy`
                # (the obvious-looking guard) admits ONLY the rescue-an-
                # already-down-service case and silently discards the marker in
                # the reconcile-an-orphan case — which is exactly the workflow
                # the inconsistency emit tells the orchestrator to run. That
                # misattributed the operator's own rescue to a supervisor pid
                # that healed nothing, and closed it out as "no action needed".
                # Allow one interval of lead; markers are consumed at incident
                # close and swept below, so staleness stays bounded.
                local mk_slack="${MONITOR_SERVICE_HEALTH_INTERVAL_SECONDS:-120}"
                [[ "$mk_slack" =~ ^[0-9]+$ ]] || mk_slack=120
                local mk_fresh=0
                [[ -n "$mk_actor" ]] && (( mk_at > 0 )) \
                    && [[ "$first_unhealthy" =~ ^[0-9]+$ ]] \
                    && (( mk_at + mk_slack >= first_unhealthy )) && mk_fresh=1

                if [[ "$attempts" -gt 0 ]]; then
                    recovered_by=watcher
                    recovered_via="held after ${attempts} watcher restart attempt(s)"
                elif (( mk_fresh )) && [[ "$mk_actor" != watcher ]]; then
                    recovered_by=operator
                    recovered_via="RESTORED by ${mk_actor} intervention ($(_sh_field "$mk" iso 2>/dev/null || echo '?') via svc.sh restart) — not a self-heal"
                elif [[ "$prev_status" == "cold-build" ]]; then
                    # The service was unhealthy only because a labsh cold build
                    # was materialising the env; the watcher deferred throughout
                    # (attempts==0, no marker). Its completion IS the supervisor
                    # bringing it up — expected bring-up, never an outage.
                    recovered_by=cold-build
                    if [[ "$sup_state" == alive:* ]]; then
                        recovered_via="labsh cold build completed and bound (supervisor pid ${sup_state#alive:}); the watcher deferred throughout and never restarted"
                    else
                        recovered_via="labsh cold build completed and bound; the watcher deferred throughout and never restarted (no live supervisor record to credit)"
                    fi
                elif [[ "$prev_status" == "grace" && "$sup_state" == alive:* ]]; then
                    recovered_by=supervisor
                    recovered_via="self-healed within grace (supervisor pid ${sup_state#alive:} recovered it; watcher did not restart)"
                elif [[ "$prev_status" == "grace" && "$sup_state" == absent ]]; then
                    # No pidfile: an unmanaged / legacy tmux-hosted service.
                    # It healed inside grace and nobody intervened, so this is
                    # still a blip — but we have no record to CREDIT, and we
                    # say so rather than inventing a supervisor.
                    recovered_by=self-heal
                    recovered_via="self-healed within grace (no supervisor record to credit; watcher did not restart)"
                else
                    # The dangerous shape: green again while its supervisor
                    # record is DEAD, with no restart on file. Nothing we know
                    # of restored it. Never call this a blip.
                    recovered_by=unknown
                    recovered_via="recovered with NO live supervisor (record ${sup_state}) and no recorded restart — cause UNKNOWN; the watcher did not restart it and no wrapper was alive to self-heal it"
                fi
                # Did this incident ever leave the grace window? A sub-grace
                # flicker is a blip; anything that escalated was a real outage,
                # however it ended.
                local escalated; escalated=$(_sh_field "$sf" escalated 2>/dev/null || echo 0)
                [[ "$escalated" =~ ^[01]$ ]] || escalated=0
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
                    "recovered_by=${recovered_by}" \
                    "recovered_via=${recovered_via}" \
                    "escalated=${escalated}" \
                    "health_cmd=${health}" \
                    "logfile=${logfile}" \
                    "last_check=${now}"
                # A health incident just closed; let its breadcrumb surface
                # alone. Supervisor consistency is judged from the next tick.
                rm -f "$incon_file" "$mk" 2>/dev/null || true
                continue
            fi

            # --- healthy: supervisor-consistency reconciliation ------------
            # A green healthcheck beside a DEAD supervisor record is an
            # inconsistent state, not a cosmetic one: the daemon outlived its
            # wrapper and runs unsupervised, so the grace window's
            # defer-to-the-wrapper assumption is silently false. Surface it
            # (never auto-restart — the service is HEALTHY; bouncing it would
            # manufacture the outage we are trying to prevent).
            #
            # `absent` is NOT inconsistent for a service that never recorded a
            # pid (unmanaged / legacy-tmux): nothing contradicts anything. But
            # a service that WAS inconsistent and is now `absent` did not get
            # supervised — its record VANISHED beneath a still-live daemon
            # (`svc.sh stop` on an orphan removes the stale pidfile and leaves
            # the daemon running). Treating that as "reconciled" would assert
            # supervision on evidence that cannot support it, and silence the
            # alarm forever. Hold the inconsistency instead.
            local vanished=0
            if [[ "$sup_state" == absent && "$prev_status" == "inconsistent" ]]; then
                vanished=1
            fi

            # Sweep a restart marker that never opened an incident (a restart
            # with no observed downtime). Bounded, so it can never later be
            # mistaken for evidence about an unrelated incident.
            local mk_sweep; mk_sweep="$(_sh_restart_marker "$name")"
            if [[ -f "$mk_sweep" ]]; then
                local sw_at; sw_at=$(_sh_field "$mk_sweep" at 2>/dev/null || echo 0)
                [[ "$sw_at" =~ ^[0-9]+$ ]] || sw_at=0
                local sw_ttl=$(( 2 * ${MONITOR_SERVICE_HEALTH_INTERVAL_SECONDS:-120} ))
                (( now - sw_at > sw_ttl )) && rm -f "$mk_sweep" 2>/dev/null
            fi

            if [[ "$sup_state" == stale:* ]] || (( vanished )); then
                local polls=0
                [[ -f "$incon_file" ]] && read -r polls < "$incon_file" 2>/dev/null
                [[ "$polls" =~ ^[0-9]+$ ]] || polls=0
                polls=$(( polls + 1 ))
                printf '%s\n' "$polls" > "$incon_file" 2>/dev/null || true
                if (( polls >= incon_polls )); then
                    local sf_now; sf_now="$(_sh_state_file "$name")"
                    local first_incon first_incon_iso prev_kind
                    first_incon=$(_sh_field "$sf_now" first_inconsistent 2>/dev/null || echo "")
                    first_incon_iso=$(_sh_field "$sf_now" first_inconsistent_iso 2>/dev/null || echo "")
                    prev_kind=$(_sh_field "$sf_now" supervisor_kind 2>/dev/null || echo "")
                    [[ "$first_incon" =~ ^[0-9]+$ ]] || { first_incon="$now"; first_incon_iso="$(_sh_iso)"; }
                    # `dead` = a record naming a corpse. `vanished` = the record
                    # was deleted out from under a still-serving daemon. Both are
                    # unsupervised; they need different words and each re-surfaces
                    # once (the kind is part of the emit key).
                    local sup_kind=dead sup_desc="$sup_state"
                    if (( vanished )); then
                        sup_kind=vanished
                        sup_desc="absent — the pid record was DELETED while the daemon kept serving"
                    fi
                    if [[ "$prev_status" != "inconsistent" ]]; then
                        _sh_record_event "$name" detected-inconsistent \
                            "healthcheck PASSES but supervisor record is dead (${sup_state}) across ${polls} consecutive polls — daemon running unsupervised, its next failure is terminal (policy ${policy})"
                        _sh_log "service '$name' INCONSISTENT: healthy but supervisor record dead (${sup_state}) — running unsupervised"
                    elif [[ "$sup_kind" == vanished && "$prev_kind" != vanished ]]; then
                        _sh_record_event "$name" supervisor-record-vanished \
                            "the stale pid record was removed (e.g. svc.sh stop on an orphan) but the daemon is STILL serving — still unsupervised, NOT reconciled"
                        _sh_log "service '$name' supervisor record VANISHED while healthy — still unsupervised"
                    fi
                    # Re-nag bucket: advances once per incon_renag window, so
                    # the emit's status:attempts:bucket key re-surfaces a
                    # PERSISTING inconsistency periodically instead of
                    # suppressing it forever after the first sighting.
                    local bucket=$(( ( now - first_incon ) / incon_renag ))
                    (( bucket >= 0 )) || bucket=0
                    _sh_write_state "$name" \
                        "service=$name" \
                        "status=inconsistent" \
                        "policy=${policy}" \
                        "restart_attempts=0" \
                        "supervisor=${sup_desc}" \
                        "supervisor_kind=${sup_kind}" \
                        "supervisor_pidfile=$(_sh_pidfile "$name")" \
                        "inconsistent_polls=${polls}" \
                        "first_inconsistent=${first_incon}" \
                        "first_inconsistent_iso=${first_incon_iso}" \
                        "renag_bucket=${bucket}" \
                        "health_cmd=${health}" \
                        "workdir=${workdir}" \
                        "logfile=${logfile}" \
                        "last_check=${now}" \
                        "last_check_iso=$(_sh_iso)"
                fi
                continue
            fi

            # Reconciled ONLY on positive evidence: a LIVE supervisor is
            # recorded again. (`absent` after an inconsistency is handled above
            # as `vanished` — it proves nothing about supervision.)
            rm -f "$incon_file" 2>/dev/null || true
            if [[ "$prev_status" == "inconsistent" && "$sup_state" == alive:* ]]; then
                _sh_record_event "$name" inconsistent-cleared \
                    "supervisor record reconciled (${sup_state}); healthy and supervised again"
                _sh_log "service '$name' supervisor RECONCILED (${sup_state})"
                _sh_write_state "$name" \
                    "service=$name" \
                    "status=reconciled" \
                    "policy=${policy}" \
                    "restart_attempts=0" \
                    "supervisor=${sup_state}" \
                    "reconciled_at_iso=$(_sh_iso)" \
                    "health_cmd=${health}" \
                    "logfile=${logfile}" \
                    "last_check=${now}"
            fi
            continue
        fi

        # --- unhealthy ---
        # A health incident supersedes any supervisor-consistency counting:
        # `stale` beside a FAILING healthcheck is the ordinary dead-service
        # shape, already handled by the grace/restart/escalate machine below.
        rm -f "$incon_file" 2>/dev/null || true
        local fresh=0
        if [[ -z "$prev_status" || "$prev_status" == "healthy" || "$prev_status" == "recovered" \
              || "$prev_status" == "inconsistent" || "$prev_status" == "reconciled" ]]; then
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
        local cbceiling="${MONITOR_SERVICE_HEALTH_COLD_BUILD_CEILING_SECONDS:-1800}"
        [[ "$cbceiling" =~ ^[0-9]+$ ]] || cbceiling=1800

        # Evaluate "is a labsh cold build materialising?" ONCE per tick, into a
        # variable, because two decisions below need it and they must not
        # disagree: the defer branch (don't restart a build in flight) and the
        # act branch (tell svc.sh we have already ruled this build pathological).
        #
        # ── CLOCK ORIGIN — the whole point of this variable ──────────────────
        # This module's ceiling counts from `first_unhealthy` (the INCIDENT).
        # svc.sh's cold-build guard counts from the build process's own start
        # (`etimes`). A build can only begin AFTER the service is already
        # unhealthy, so `age = elapsed - D` with `D > 0` ALWAYS. Two clocks, the
        # same 1800s duration, different origins: at our ceiling the build is
        # still D seconds short of the guard's cap, so svc.sh REFUSED our first
        # post-ceiling restart — a guaranteed wasted attempt out of three, and a
        # permanent `flapping` (recovery dead) whenever D exceeds the restart
        # budget, e.g. if monitor.service_health.grace_seconds is raised toward
        # restart_cooldown_seconds. Found by the round-2 skeptic
        # (your-org/your-nexus#273); it survived round 1 because the guard was
        # tested as a function and nobody asked whether the WATCHER gets through.
        #
        # The fix is to have ONE origin decide. Reaching the act branch below
        # while a build is live implies `elapsed >= cbceiling` BY CONSTRUCTION
        # (the defer branch is the only gate on a live build, and it would have
        # been taken otherwise) — i.e. WE have already declared it pathological,
        # on OUR clock, which is exactly what the ceiling means. So we pass
        # SVC_FORCE=1 and svc.sh's guard does not re-derive that verdict from a
        # clock it cannot reconcile with ours.
        local cb_build=0
        if (( cbceiling > 0 )) && _sh_is_labsh_service "$launch" "$health" \
               && _sh_labsh_build_in_progress "$workdir"; then
            cb_build=1
        fi

        if (( cb_build )) && (( elapsed < cbceiling )); then
            # --- labsh COLD BUILD in progress: defer to the supervisor
            #     (#326 already made it patient), NEVER restart. This
            #     SUSPENDS the grace/restart machine for the life of the
            #     build — the healthcheck failing throughout is legitimate
            #     bring-up (uvx materialising the env), not an outage. The
            #     defer is self-calibrating: it lasts exactly as long as the
            #     build process runs with no URL (or until the cbceiling
            #     backstop). A genuinely-dead service has no live build ⇒
            #     this branch is skipped ⇒ ordinary restart still recovers it.
            status="cold-build"
            note="labsh cold build in progress (${elapsed}s; uvx materialising the JupyterLab env on NFS — minutes). Deferring to the supervisor; the watcher will NOT restart until the build binds a URL, the build process dies, or the ${cbceiling}s cold-build ceiling elapses."
            if [[ "$prev_status" != "cold-build" ]]; then
                _sh_record_event "$name" cold-build-in-progress \
                    "healthcheck fails while a labsh cold build materialises the env (live build process); deferring to supervisor, no restart (policy ${policy})"
                _sh_log "service '$name' labsh COLD BUILD in progress — deferring to supervisor, not restarting"
            fi
        elif (( elapsed < grace )); then
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
            # cb_build here ⇒ elapsed >= cbceiling (see the clock-origin note
            # above): we have already ruled this build pathological on OUR
            # clock, so svc.sh's guard must not veto us on its own.
            if (( cb_build )); then
                _sh_log "service '$name' has a live labsh build past the ${cbceiling}s cold-build ceiling — presumed WEDGED; forcing the restart through svc.sh's cold-build guard"
            fi
            _sh_restart_service "$name" "$cb_build" || rc=$?
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

        # Sticky for the life of the incident: once we leave the grace window
        # this was a real outage, and the `recovered` breadcrumb must never
        # call it a transient blip no matter who ends up restoring it.
        local escalated; escalated=$(_sh_field "$sf" escalated 2>/dev/null || echo 0)
        [[ "$escalated" =~ ^[01]$ ]] || escalated=0
        # `cold-build` is legitimate bring-up, not an outage — like `grace` it
        # does NOT escalate, so a completed build's breadcrumb never reads as a
        # rescued outage.
        [[ "$status" != "grace" && "$status" != "cold-build" ]] && escalated=1

        _sh_write_state "$name" \
            "service=$name" \
            "status=${status}" \
            "policy=${policy}" \
            "first_unhealthy=${first_unhealthy}" \
            "first_unhealthy_iso=${first_iso}" \
            "restart_attempts=${attempts}" \
            "last_restart=${last_restart}" \
            "escalated=${escalated}" \
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
    local supervisor sup_pidfile incon_polls incon_iso recovered_by escalated renag_bucket sup_kind
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
        supervisor=$(_sh_field "$sf" supervisor 2>/dev/null || echo '?')
        sup_pidfile=$(_sh_field "$sf" supervisor_pidfile 2>/dev/null || echo '')
        incon_polls=$(_sh_field "$sf" inconsistent_polls 2>/dev/null || echo '?')
        incon_iso=$(_sh_field "$sf" first_inconsistent_iso 2>/dev/null || echo '?')
        recovered_by=$(_sh_field "$sf" recovered_by 2>/dev/null || echo '')
        escalated=$(_sh_field "$sf" escalated 2>/dev/null || echo 0)
        renag_bucket=$(_sh_field "$sf" renag_bucket 2>/dev/null || echo 0)
        sup_kind=$(_sh_field "$sf" supervisor_kind 2>/dev/null || echo 'dead')
        surfaced_file="$state_dir/$name-surfaced"
        # The re-nag key. `renag_bucket` advances once per re-nag window, so a
        # PERSISTING inconsistency re-surfaces periodically instead of being
        # suppressed forever; every other status keys on status:attempts as
        # before.
        key="$status:$attempts"
        # `sup_kind` is in the key so a dead record that later VANISHES (someone
        # ran `svc.sh stop` on the orphan) re-surfaces once — it is a new fact,
        # and it is emphatically not a reconciliation.
        [[ "$status" == inconsistent ]] && key="$status:$attempts:$renag_bucket:$sup_kind"
        case "$status" in
            recovered)
                # One-shot breadcrumb, then close the incident. The closing
                # ADVICE is earned, never assumed: only a supervisor self-heal
                # that never left the grace window is a transient blip. A
                # watcher restart, an operator rescue, an unattributed
                # recovery, or ANY incident that escalated past grace all
                # describe a real outage — saying "no action needed" there is
                # how a 19h unsupervised outage got logged as a blip.
                case "$recovered_by" in
                    watcher)
                        printf 'service %s RECOVERED (auto-restart held): unhealthy since %s, restored ~%s after %s restart attempt(s).\n' \
                            "'$name'" "$first_iso" "$recovered_iso" "$attempts" ;;
                    operator)
                        printf 'service %s RECOVERED BY INTERVENTION: unhealthy since %s, restored ~%s. %s\n' \
                            "'$name'" "$first_iso" "$recovered_iso" "$recovered_via" ;;
                    unknown)
                        printf 'service %s RECOVERED, CAUSE UNKNOWN: unhealthy since %s, green again ~%s. %s\n' \
                            "'$name'" "$first_iso" "$recovered_iso" "$recovered_via" ;;
                    cold-build)
                        printf 'service %s came up after a labsh COLD BUILD: unhealthy since %s while the env materialised, healthy again ~%s.\n' \
                            "'$name'" "$first_iso" "$recovered_iso"
                        printf '  %s\n' "$recovered_via" ;;
                    *)
                        printf 'service %s RECOVERED (%s): unhealthy since %s, restored ~%s.\n' \
                            "'$name'" "$recovered_via" "$first_iso" "$recovered_iso" ;;
                esac
                if [[ "$recovered_by" == cold-build ]]; then
                    printf '  Expected bring-up: a labsh cold build (uvx materialising the env) blocks the healthcheck for minutes; the watcher correctly DEFERRED to the supervisor and never restarted. No action needed.\n'
                elif [[ ( "$recovered_by" == supervisor || "$recovered_by" == self-heal ) && "$escalated" != 1 ]]; then
                    printf '  Transient blip, self-resolved within grace. No action needed; file an incident if you want a record:\n'
                    printf '    %smonitor/ng service-incident %s\n' "${nexus_root:+$nexus_root/}" "$name"
                else
                    printf '  NOT a transient blip: the service left the grace window (or was restored by an actor other than its own supervisor). Action WAS taken or is still warranted.\n'
                    printf '  Record it and close the loop (skills/nexus.service-recovery):\n'
                    printf '    %smonitor/ng service-incident %s\n' "${nexus_root:+$nexus_root/}" "$name"
                fi
                printf '\n'
                rm -f "$sf" "$surfaced_file" 2>/dev/null || true
                emitted=0
                ;;
            inconsistent)
                # Escalation of a state that is NEITHER up nor down: the
                # healthcheck passes while the supervisor record is dead.
                # Surfaced once per incident (key is `inconsistent:0`, so a
                # persisting inconsistency never re-nags), cleared by the
                # `reconciled` breadcrumb below. NEVER auto-restarted: the
                # service is healthy, and a blind bounce would create the
                # outage. The orchestrator decides when a bounce is safe.
                last=$(cat "$surfaced_file" 2>/dev/null || true)
                [[ "$last" == "$key" ]] && continue
                printf 'service %s INCONSISTENT since %s — its healthcheck PASSES but its supervisor is GONE (%s): the daemon is running UNSUPERVISED.\n' \
                    "'$name'" "$incon_iso" "$supervisor"
                printf '  passing healthcheck: %s\n' "$health"
                if [[ "$sup_kind" == vanished ]]; then
                    printf '  the pid record was REMOVED while the daemon kept serving (e.g. `svc.sh stop` on an orphan): still unsupervised, NOT reconciled.\n'
                fi
                [[ -n "$sup_pidfile" ]] && printf '  supervisor record: %s\n' "$sup_pidfile"
                printf '  persisted across %s consecutive polls (not a relaunch race).\n' "$incon_polls"
                printf '  policy: %s — the watcher will NOT restart a service whose healthcheck passes.\n' "$policy"
                printf '  Why it matters: the grace window defers a crash to that supervisor. With it dead, nothing performs the wrapper self-heal — the next crash gets no restart from it.\n'
                [[ -n "$logfile" ]] && printf '  logfile: %s\n' "$logfile"
                printf '  incident state: %s   (history: %s)\n' "$sf" "$state_dir/$name.events"
                printf '  ACTION (skills/nexus.service-recovery): decide WHEN a bounce is safe — a restart drops live sessions of this service.\n'
                printf '    reconcile (restarts the daemon): %smonitor/svc.sh restart %s\n' "${nexus_root:+$nexus_root/}" "$name"
                printf '    incident issue:                  %smonitor/ng service-incident %s\n' "${nexus_root:+$nexus_root/}" "$name"
                printf '\n'
                printf '%s\n' "$key" > "$surfaced_file" 2>/dev/null || true
                emitted=0
                ;;
            reconciled)
                # One-shot close of an inconsistency, mirroring `recovered`. Only
                # ever written on positive evidence (a LIVE supervisor pid), so
                # this line can never be an unearned all-clear.
                printf 'service %s supervisor RECONCILED (%s) — the unsupervised-daemon inconsistency is closed; healthy and supervised again.\n' \
                    "'$name'" "$supervisor"
                printf '  No action needed.\n'
                printf '\n'
                rm -f "$sf" "$surfaced_file" 2>/dev/null || true
                emitted=0
                ;;
            cold-build)
                # Informational only: a labsh cold build is materialising the
                # env, so the healthcheck fails for minutes — legitimate
                # bring-up, not an outage. The watcher is deferring to the
                # (patient, #326) supervisor and will NOT restart. Surfaced
                # once (re-nag guarded) so a normal cold build leaves at most
                # this breadcrumb + the "came up after a cold build" line.
                last=$(cat "$surfaced_file" 2>/dev/null || true)
                [[ "$last" == "$key" ]] && continue
                printf 'service %s unhealthy since %s — but a labsh COLD BUILD is in progress (uvx materialising the JupyterLab env; minutes on NFS). Deferring to its supervisor; the watcher will NOT restart it.\n' \
                    "'$name'" "$first_iso"
                printf '  failing healthcheck (expected during the build): %s\n' "$health"
                printf '  policy: %s — auto-restart is SUSPENDED until the build binds a URL, the build dies, or the cold-build ceiling elapses.\n' "$policy"
                printf '  No action needed (informational). incident state: %s\n' "$sf"
                printf '\n'
                printf '%s\n' "$key" > "$surfaced_file" 2>/dev/null || true
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
