#!/usr/bin/env bash
# Verify the nexus stack has CONVERGED after a bring-up.
#
# `monitor/svc.sh up` (and the `./watcher` entry point that delegates to
# it) launch the headless watcher and the registry services, then return
# immediately — the watcher spawns the orchestrator window a few probe
# cycles later (~10s). So "the bring-up command exited 0" is NOT the same
# as "the stack is running". A fresh install that stops at the bring-up
# leaves the operator guessing whether the orchestrator actually came up
# (your-org/nexus-code#313 item 4). This script closes that gap: it polls
# the three stack components until they all converge (or a timeout), so
# the bootstrap can OBSERVE a running stack before declaring success.
#
# Components checked:
#   1. watcher       — heartbeat fresh + pid alive (`_watcher_alive`)
#   2. orchestrator  — the target tmux window exists (`monitor.target_window`)
#   3. services      — every row in services.registry is healthy
#                      (an empty / missing registry is trivially satisfied)
#
# Usage:
#   monitor/watcher/verify-stack.sh [--timeout N] [--poll N] [--quiet]
#                                   [--no-orchestrator] [--check-timeout N]
#
#   --timeout N         max WALL-CLOCK seconds to wait for convergence
#                       (default: monitor.boot_verify_timeout, or 90)
#   --poll N            seconds between probe rounds (default 3)
#   --check-timeout N   max seconds any ONE probe may run — a registry
#                       healthcheck, the tmux window lookup, the cold-build
#                       probe (default: monitor.boot_verify_check_timeout,
#                       or 15; env BOOT_VERIFY_CHECK_TIMEOUT)
#   --quiet             suppress per-probe progress; still prints the
#                       final converged / not-converged summary
#   --no-orchestrator   skip the orchestrator-window check (e.g. a
#                       headless verify with no tmux, or a watcher-only
#                       deployment)
#
# THE TIMEOUT IS WALL CLOCK (your-org/nexus-code#1675). It used to count only
# the `sleep "$POLL"` between rounds, never the rounds themselves. A round runs
# every registry healthcheck serially (some are `curl --max-time 10`), and
# under host load 60-120 one round took ~40 s, so "90 s" meant ~30 rounds —
# about 20 minutes during which window 1 stayed a plain `bash` window instead
# of becoming `services`. The deadline is now `$SECONDS`-based, and:
#   * the FIRST round always runs to completion, each probe capped at
#     --check-timeout — one full observation is always made, however short
#     the budget and however slow a fork is on a loaded host;
#   * after it, no round STARTS at or after the deadline, and every probe
#     that can hang is run under `timeout` with a cap of
#     min(--check-timeout, seconds left), so a probe started before the
#     deadline cannot run past it by more than the kill grace;
#   * a probe whose turn comes after the deadline is SKIPPED and reported
#     "not checked — deadline reached" — never as healthy;
#   * the timeout summary REUSES the last round's verdicts rather than running
#     every healthcheck again (the old summary did: one more full round).
#
# WORST-CASE RUNTIME, measured from when probing starts (setup before that —
# sourcing and config reads, not a probe — was measured at 2-12 s at load
# 100-127; see DEADLINE below):
#     max( FIRST ROUND , TIMEOUT + 3 s )
#   * TIMEOUT + 3 s: the 2 s SIGTERM->SIGKILL grace `timeout -k` allows a
#     capped probe, plus <1 s because `$SECONDS` is an integer clock.
#   * FIRST ROUND <= (1 + rows + labsh rows) x (check-timeout + 2) s: the
#     orchestrator lookup, each row's healthcheck, and one cold-build probe
#     per unhealthy LABSH row, each capped. The live registry measured
#     2026-09-30 has 12 rows, 1 of them labsh, so with the default 15 s cap
#     the structural worst case — EVERY probe hanging — is
#     (1 + 12 + 1) x 17 = 238 s. A round whose probes answer takes seconds.
#   `--timeout 0` is exactly one such round.
# Both exclude the two probes that are local file reads and are NOT run under
# `timeout`: the watcher-heartbeat check and the registry parse (a hung NFS
# read there is not bounded by this script).
#
# A labsh COLD BUILD is not a failure and not health (your-org/nexus-code#1675).
# A failing healthcheck on a service whose JupyterLab env is still being
# materialised by uvx (minutes, on NFS) is expected bring-up: the watcher
# defers to the supervisor for the life of the build and never restarts it.
# This script asks the SAME shared predicate, `labsh_build_in_progress`
# (monitor/_labsh_build_evidence.sh — the one svc.sh's cold-build guard uses;
# the watcher's `_sh_labsh_build_in_progress` makes the same two-part check),
# and reports such a service as BUILDING. A BUILDING service is NEVER counted
# healthy and never printed as healthy; it only stops being BLOCKING, so the
# operator is not held for the length of the build. The predicate fails
# CLOSED (unestablished ⇒ not building ⇒ blocking). Whether a build that IS
# in flight still counts is the SHARED verdict `labsh_build_release` — the one
# the watcher, svc.sh and the supervisor act on (your-org/nexus-code#1690):
# inside monitor.service_health.cold_build_ceiling_seconds (default 1800; 0
# disables the classification — the watcher's own knob) it is BUILDING; past
# it, BUILDING only while still PROGRESSING, and blocking again once stalled
# for LABSH_BUILD_STALL_SECONDS or past LABSH_COLD_BUILD_HARD_CAP. An age test
# here used to call a progressing 1800-7200 s build DOWN while every actor
# correctly left it alone. The verdict writes the one progress sample every
# layer shares, <workdir>/.jupyter/labsh.buildprogress; nothing else.
#
# Exit codes:
#   0  all checked components converged; every service HEALTHY
#   1  timed out with at least one component still down (or not checked
#      before the deadline)
#   2  usage / environment error
#   3  converged EXCEPT services still BUILDING (labsh cold build in
#      progress): watcher + orchestrator up, every other service healthy.
#      Neither success nor failure; returned as soon as it is observed.
#  79  NOT CHECKED — the services registry EXISTS and could not be READ, so
#      no statement about service health is available. Never folded into 0.
#      (your-org/nexus-code#1266. `[[ -f ]]` is true for an unreadable file,
#      so the parser's guard did not cover the `done < "$file"` redirection;
#      the failed parse yielded zero rows and this script printed "services
#      healthy" and exited 0 while a registered service was genuinely down.
#      Measured with the registry BYTES constant and the MODE the only
#      variable: 0644 -> exit 1 naming the service; 0000 -> exit 0 "healthy".)
#      A CONFIRMED failure OUTRANKS it: if any other component is also down,
#      the verdict is 1, because "part of this could not be checked and part
#      of it FAILED" is a failure.
#
# Honors the same env overrides as bootstrap-recover.sh: NEXUS_ROOT,
# NEXUS_STATE_DIR, NEXUS_SERVICES_REGISTRY, RECOVER_TARGET_WINDOW.

set -uo pipefail

_script_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
# Captured under a PRIVATE name: sourcing bootstrap-recover.sh below
# REASSIGNS `_script_dir` to monitor/, so any path derived from it afterwards
# is one directory too high. That made the cold-build predicate's file
# "unreadable" and the BUILDING classification silently dead (it fails
# closed) — caught only by a fixture with a real build in flight.
_vs_monitor_dir=$(cd "$_script_dir/.." && pwd)

# bootstrap-recover.sh sources _lib.sh and exposes STATE_DIR,
# SERVICES_REGISTRY, TARGET_WINDOW, _cfg, _watcher_alive,
# _recover_window_exists, _recover_parse_registry, _recover_service_healthy.
# Sourcing it is side-effect-free (no auto-run), mirroring jupyter-up.sh.
# shellcheck source=../bootstrap-recover.sh
source "$_script_dir/../bootstrap-recover.sh"

TIMEOUT="${BOOT_VERIFY_TIMEOUT:-$("$_cfg" monitor.boot_verify_timeout 90)}"
CHECK_TIMEOUT="${BOOT_VERIFY_CHECK_TIMEOUT:-$("$_cfg" monitor.boot_verify_check_timeout 15)}"
POLL=3
QUIET=0
CHECK_ORCH=1

while (( $# > 0 )); do
    case "$1" in
        --timeout)         TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
        --poll)            POLL="${2:?--poll needs a value}"; shift 2 ;;
        --check-timeout)   CHECK_TIMEOUT="${2:?--check-timeout needs a value}"; shift 2 ;;
        --quiet)           QUIET=1; shift ;;
        --no-orchestrator) CHECK_ORCH=0; shift ;;
        -h|--help)         sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "verify-stack: unknown flag: $1" >&2; exit 2 ;;
    esac
done

[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || { echo "verify-stack: --timeout must be an integer" >&2; exit 2; }
[[ "$POLL" =~ ^[0-9]+$ && "$POLL" -gt 0 ]] || { echo "verify-stack: --poll must be a positive integer" >&2; exit 2; }
[[ "$CHECK_TIMEOUT" =~ ^[0-9]+$ && "$CHECK_TIMEOUT" -gt 0 ]] || { echo "verify-stack: --check-timeout must be a positive integer" >&2; exit 2; }
command -v timeout >/dev/null 2>&1 || { echo "verify-stack: coreutils 'timeout' not found — cannot bound the probes" >&2; exit 2; }

INTERVAL=$("$_cfg" monitor.interval_seconds 60)
COLD_BUILD_CEILING="${MONITOR_SERVICE_HEALTH_COLD_BUILD_CEILING_SECONDS:-$("$_cfg" monitor.service_health.cold_build_ceiling_seconds 1800)}"
[[ "$COLD_BUILD_CEILING" =~ ^[0-9]+$ ]] || COLD_BUILD_CEILING=1800
LABSH_EVIDENCE="$_vs_monitor_dir/_labsh_build_evidence.sh"

# Which ROWS may be BUILDING at all: the watcher's own `_sh_is_labsh_service`
# (launch names labsh-supervised.sh, or health names jupyter-health.sh), REUSED
# by sourcing the module that defines it — never a copy. The build predicate
# below keys on the WORKDIR, and production rows share one (nexus-remote-ssh
# and tmpfs-guard run in $NEXUS_ROOT beside the root labsh .jupyter), so
# without this gate a DOWN non-labsh row read BUILDING at exit 3 and the
# summary said "every other service healthy" (skeptic verdict on #1679).
# Sourced AFTER COLD_BUILD_CEILING is resolved: the module defaults
# MONITOR_SERVICE_HEALTH_COLD_BUILD_CEILING_SECONDS, which would otherwise
# shadow the config read above. Its top level only assigns defaults and
# defines functions. Missing predicate ⇒ no row is labsh ⇒ BUILDING is never
# reported (fail closed: blocking).
# shellcheck source=_service_health.sh
source "$_vs_monitor_dir/watcher/_service_health.sh" 2>/dev/null || true
_vs_is_labsh_row() {
    declare -F _sh_is_labsh_service >/dev/null || return 1
    _sh_is_labsh_service "$1" "$2"
}

# The deadline is on bash's own wall clock, `$SECONDS`, and starts when
# PROBING starts — after the setup above (sourcing bootstrap-recover.sh, four
# config reads), which is not a probe and cannot hang on a service. That setup
# is ~0.3 s on an idle host and was measured at 2-9 s at load ~100
# (2026-09-29); it precedes the budget rather than eating it, so a short
# --timeout still gets a real first round.
KILL_GRACE=2
PROBE_T0=$SECONDS
DEADLINE=$(( PROBE_T0 + TIMEOUT ))

# "Ns" in verdict lines: time spent PROBING, then the total including setup.
_took() { printf '%ss (%ss incl. setup)' $(( SECONDS - PROBE_T0 )) "$SECONDS"; }

say() { (( QUIET )) || echo "[verify-stack] $*" >&2; }

# Seconds left before the deadline (may be <= 0).
_remaining() { printf '%s' $(( DEADLINE - SECONDS )); }

# The cap for the next probe, or rc 1 when the deadline has passed and the
# probe must be SKIPPED. The FIRST round is exempt from the deadline (one full
# observation is always made), so each of its probes gets --check-timeout.
FIRST_ROUND=1
_probe_cap() {
    local rem
    (( FIRST_ROUND )) && { printf '%s' "$CHECK_TIMEOUT"; return 0; }
    rem=$(_remaining)
    (( rem > 0 )) || return 1
    printf '%s' $(( rem < CHECK_TIMEOUT ? rem : CHECK_TIMEOUT ))
}

# _bounded <cap> <script> — run <script> in a child bash under `timeout`.
# The probe's inputs travel in the ENVIRONMENT (VS_*), never in argv: a
# registry health string in argv is process-table content that a `pgrep -f`
# healthcheck would match against itself — the false-healthy of
# your-org/nexus-code#891 that `_recover_service_healthy` exists to avoid.
# `timeout` (no --foreground) puts the child in its own process group and
# signals the whole group, so a `curl` or `sleep` grandchild dies with it.
# stdin is /dev/null: a probe must never block on (or steal) the terminal.
# rc: the script's own, or 124/137 when the cap fired.
_bounded() {
    local cap="$1" script="$2"
    timeout -k "$KILL_GRACE" "$cap" bash -c "$script" </dev/null
}
export -f _recover_service_healthy _recover_window_exists

# --- component probes (each: rc 0 = converged) -----------------------------

_check_watcher() { _watcher_alive "$STATE_DIR" "$INTERVAL"; }

ORCH_NOTE=''
ORCH_LAST_UP_AT=''   # when a round last SAW the window (#1743; see SVC_LAST_V)
_check_orchestrator() {
    (( CHECK_ORCH )) || return 0
    local cap rc
    ORCH_NOTE=''
    if ! cap=$(_probe_cap); then
        # Skipped by the deadline: still not converged, but say what was last
        # seen instead of reporting a window round 1 found as "not present".
        if [[ -n "$ORCH_LAST_UP_AT" ]]; then
            ORCH_NOTE="not re-checked — deadline reached; last observed PRESENT $(( SECONDS - ORCH_LAST_UP_AT ))s ago"
        else
            ORCH_NOTE='not checked — deadline reached'
        fi
        return 1
    fi
    VS_WIN="$TARGET_WINDOW" _bounded "$cap" '_recover_window_exists "$VS_WIN"' >/dev/null 2>&1
    rc=$?
    case "$rc" in
        0)       ORCH_LAST_UP_AT=$SECONDS; return 0 ;;
        124|137) ORCH_NOTE="tmux lookup timed out after ${cap}s"; return 1 ;;
        *)       return 1 ;;
    esac
}

# One service's verdict: prints `healthy`, `building <pid> <age> <token>`,
# `timeout <cap>`, `skipped` or `down`.
_service_verdict() {
    local workdir="$1" launch="$2" health="$3" cap cap2 rc ev pid age
    cap=$(_probe_cap) || { echo skipped; return; }
    VS_WD="$workdir" VS_HEALTH="$health" \
        _bounded "$cap" '_recover_service_healthy "$VS_WD" "$VS_HEALTH"' >/dev/null 2>&1
    rc=$?
    (( rc == 0 )) && { echo healthy; return; }
    # Unhealthy (or its check timed out): is a labsh cold build in flight?
    # Asked of the SHARED predicate, in a bounded child — it walks /proc.
    if (( COLD_BUILD_CEILING > 0 )) && _vs_is_labsh_row "$launch" "$health" \
         && [[ -r "$LABSH_EVIDENCE" && -d "$workdir/.jupyter" ]] \
         && cap2=$(_probe_cap); then
        # In flight AND protected by the shared verdict (rc 1 = PROTECTED) ⇒
        # prints "<pid> <age> <token>"; released or unestablished ⇒ nothing.
        ev=$(VS_WD="$workdir" VS_EVIDENCE="$LABSH_EVIDENCE" VS_CEIL="$COLD_BUILD_CEILING" \
             _bounded "$cap2" 'source "$VS_EVIDENCE" && ev=$(labsh_build_in_progress "$VS_WD") && read -r p a <<<"$ev" && ! v=$(labsh_build_release "$p" "$a" "$VS_WD" "$VS_CEIL") && printf "%s %s %s" "$p" "$a" "${v%% *}"' 2>/dev/null) \
            && read -r pid age tok <<<"$ev" \
            && [[ "$pid" =~ ^[0-9]+$ && "$age" =~ ^[0-9]+$ && -n "$tok" ]] \
            && { echo "building $pid $age $tok"; return; }
    fi
    if (( rc == 124 || rc == 137 )); then echo "timeout $cap"; else echo down; fi
}

# Per-round service state, kept so the timeout summary reports what the LAST
# round saw instead of re-running every healthcheck.
SVC_BAD=''        # names that are down / timed out / skipped, with reasons
SVC_BUILDING=''   # names BUILDING, with pid + age
SERVICES_NOT_CHECKED=0
# Each row's LAST OBSERVED verdict and when (your-org/nexus-code#1743). A round
# that starts just before the deadline can reach a row after it, and that row
# is SKIPPED. Reporting only "not checked" then threw away what an earlier
# round really saw — measured on a stalled 2-CPU runner: round 1 saw `jlab`
# BUILDING and `broken` DOWN, round 2 skipped both, and the summary named
# neither verdict. A skipped row now reports its last observation WITH ITS
# AGE, and it still never counts as converged: a skip blocks rc 0 and rc 3
# exactly as before, so a stale observation can be READ, never CERTIFIED.
declare -A SVC_LAST_V=() SVC_LAST_AT=()

# rc 0 == "checked, and every service is healthy or BUILDING". The registry is
# parsed ONCE per round; an unreadable registry (parser rc 79, or any other
# non-zero) is never rc 0 — it sets SERVICES_NOT_CHECKED (#1266), in THIS
# scope rather than in a `$( )` subshell, so the flag cannot be silently lost.
_check_services() {
    local rows rc name workdir launch health logfile v pid age
    SVC_BAD=''; SVC_BUILDING=''
    rows=$(_recover_parse_registry "$SERVICES_REGISTRY" 2>/dev/null); rc=$?
    if (( rc != 0 )); then
        SERVICES_NOT_CHECKED=1
        return 1
    fi
    SERVICES_NOT_CHECKED=0
    [[ -z "$rows" ]] && return 0
    local skipped_any=0 seen ago
    while IFS=$'\t' read -r name workdir launch health logfile; do
        [[ -z "$name" ]] && continue
        v=$(_service_verdict "$workdir" "$launch" "$health")
        seen=''
        if [[ "$v" == skipped ]]; then
            skipped_any=1
            if [[ -n "${SVC_LAST_V[$name]:-}" ]]; then
                v="${SVC_LAST_V[$name]}"
                ago=$(( SECONDS - ${SVC_LAST_AT[$name]:-$SECONDS} ))
                seen="not re-checked — deadline reached; last observed ${ago}s ago"
            else
                v=skipped
            fi
        else
            SVC_LAST_V[$name]="$v"; SVC_LAST_AT[$name]=$SECONDS
        fi
        case "$v" in
            healthy)    [[ -n "$seen" ]] && SVC_BAD+="${SVC_BAD:+, }$name ($seen: healthy)" ;;
            building\ *)
                read -r _ pid age tok <<<"$v"
                SVC_BUILDING+="${SVC_BUILDING:+, }$name (labsh cold build pid $pid, running ${age}s, $tok${seen:+; $seen})" ;;
            timeout\ *) SVC_BAD+="${SVC_BAD:+, }$name (healthcheck timed out after ${v#timeout }s${seen:+; $seen})" ;;
            skipped)    SVC_BAD+="${SVC_BAD:+, }$name (not checked — deadline reached)" ;;
            *)          SVC_BAD+="${SVC_BAD:+, }$name${seen:+ (down; $seen)}" ;;
        esac
    done <<<"$rows"
    [[ -z "$SVC_BAD" ]] && (( ! skipped_any ))
}

# --- poll loop -------------------------------------------------------------

say "verifying stack convergence (timeout ${TIMEOUT}s wall clock, ${CHECK_TIMEOUT}s per probe): watcher$( (( CHECK_ORCH )) && echo ', orchestrator'), services"

w_ok=0; o_ok=0; s_ok=0
next_progress=0
while :; do
    _check_watcher       && w_ok=1 || w_ok=0
    _check_orchestrator  && o_ok=1 || o_ok=0
    _check_services      && s_ok=1 || s_ok=0
    FIRST_ROUND=0

    if (( w_ok && o_ok && s_ok )); then
        if [[ -z "$SVC_BUILDING" ]]; then
            say "stack converged in $(_took): watcher fresh$( (( CHECK_ORCH )) && echo ', orchestrator up'), services healthy"
            exit 0
        fi
        # Printed unconditionally (not `say`): like the not-converged summary,
        # this is a verdict the operator must see even under --quiet.
        echo "[verify-stack] stack up in $(_took) EXCEPT services still BUILDING — NOT healthy yet, not counted as blocking: $SVC_BUILDING" >&2
        echo "[verify-stack]   watcher fresh$( (( CHECK_ORCH )) && echo ', orchestrator up'), every other service healthy; the watcher defers to the supervisor until the build binds (monitor/svc.sh status)." >&2
        exit 3
    fi

    (( $(_remaining) > 0 )) || break

    if (( SECONDS - PROBE_T0 >= next_progress )); then
        say "  ...waiting ($(( SECONDS - PROBE_T0 ))s): watcher=$( (( w_ok )) && echo ok || echo DOWN)$( (( CHECK_ORCH )) && printf ' orchestrator=%s' "$( (( o_ok )) && echo ok || echo DOWN)") services=$( (( s_ok )) && echo ok || echo DOWN)"
        next_progress=$(( SECONDS - PROBE_T0 + 15 ))
    fi

    rem=$(_remaining)
    (( rem > 0 )) || break
    sleep $(( POLL < rem ? POLL : rem ))
    # Never start a round at or past the deadline.
    (( $(_remaining) > 0 )) || break
done

# --- timeout summary -------------------------------------------------------
# From the LAST round's verdicts — no probe runs after the deadline.

down=()
(( w_ok )) || down+=("watcher (heartbeat stale or pid dead — see monitor/.state/watcher.log)")
if (( CHECK_ORCH )) && (( ! o_ok )); then
    if [[ "$ORCH_NOTE" == "not re-checked"* ]]; then
        down+=("orchestrator (window '$TARGET_WINDOW' $ORCH_NOTE — not counted as converged)")
    else
        down+=("orchestrator (window '$TARGET_WINDOW' not present${ORCH_NOTE:+: $ORCH_NOTE} — the watcher spawns it within ~10s; check the cockpit)")
    fi
fi
svc_not_checked=0
if (( ! s_ok )); then
    if (( SERVICES_NOT_CHECKED )); then
        svc_not_checked=1
        down+=("services: NOT CHECKED — the registry at $SERVICES_REGISTRY exists and could not be read (mode/ACL/ESTALE). No statement about service health is available; this is NOT a report that services are healthy.")
    else
        # An empty SVC_BAD with !s_ok is a round cut by the deadline whose only
        # unconverged rows were last seen BUILDING (#1743): say so, not "unknown".
        down+=("services: ${SVC_BAD:-not re-checked before the deadline (last observations listed as BUILDING below)} (see monitor/svc.sh status)")
    fi
fi

echo "[verify-stack] stack did NOT fully converge after $(_took) (timeout ${TIMEOUT}s):" >&2
for d in "${down[@]}"; do echo "[verify-stack]   - $d" >&2; done
[[ -n "$SVC_BUILDING" ]] && \
    echo "[verify-stack]   - also BUILDING (not healthy; not counted as blocking): $SVC_BUILDING" >&2
echo "[verify-stack] inspect with: monitor/svc.sh status  |  monitor/ng watcher-status" >&2

# A CONFIRMED failure outranks NOT-CHECKED: 79 only when the services leg is
# the ONLY thing wrong and the reason is that it could not be read.
if (( svc_not_checked )) && (( ${#down[@]} == 1 )); then
    echo "[verify-stack] verdict: NOT CHECKED (79) — services unreadable; nothing else is down." >&2
    exit 79
fi
exit 1
