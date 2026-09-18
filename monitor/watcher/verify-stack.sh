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
#                                   [--no-orchestrator]
#
#   --timeout N         max seconds to wait for convergence
#                       (default: monitor.boot_verify_timeout, or 90)
#   --poll N            seconds between probes (default 3)
#   --quiet             suppress per-probe progress; still prints the
#                       final converged / not-converged summary
#   --no-orchestrator   skip the orchestrator-window check (e.g. a
#                       headless verify with no tmux, or a watcher-only
#                       deployment)
#
# Exit codes:
#   0  all checked components converged
#   1  timed out with at least one component still down
#   2  usage / environment error
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

# bootstrap-recover.sh sources _lib.sh and exposes STATE_DIR,
# SERVICES_REGISTRY, TARGET_WINDOW, _cfg, _watcher_alive,
# _recover_window_exists, _recover_parse_registry, _recover_service_healthy.
# Sourcing it is side-effect-free (no auto-run), mirroring jupyter-up.sh.
# shellcheck source=../bootstrap-recover.sh
source "$_script_dir/../bootstrap-recover.sh"

TIMEOUT="${BOOT_VERIFY_TIMEOUT:-$("$_cfg" monitor.boot_verify_timeout 90)}"
POLL=3
QUIET=0
CHECK_ORCH=1

while (( $# > 0 )); do
    case "$1" in
        --timeout)         TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
        --poll)            POLL="${2:?--poll needs a value}"; shift 2 ;;
        --quiet)           QUIET=1; shift ;;
        --no-orchestrator) CHECK_ORCH=0; shift ;;
        -h|--help)         sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "verify-stack: unknown flag: $1" >&2; exit 2 ;;
    esac
done

[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || { echo "verify-stack: --timeout must be an integer" >&2; exit 2; }
[[ "$POLL" =~ ^[0-9]+$ && "$POLL" -gt 0 ]] || { echo "verify-stack: --poll must be a positive integer" >&2; exit 2; }

INTERVAL=$("$_cfg" monitor.interval_seconds 60)

say() { (( QUIET )) || echo "[verify-stack] $*" >&2; }

# --- component probes (each: rc 0 = converged) -----------------------------

_check_watcher() { _watcher_alive "$STATE_DIR" "$INTERVAL"; }

_check_orchestrator() {
    (( CHECK_ORCH )) || return 0
    _recover_window_exists "$TARGET_WINDOW"
}

# All registry services healthy. Missing/empty registry → satisfied.
# Emits the names of any UNHEALTHY services on stdout (for the summary).
#
# An UNREADABLE registry is NOT satisfied and is not a service failure
# either — it is "could not look" (rc 79 from the parser; see the
# registry-READABILITY contract in bootstrap-recover.sh). It is recorded in
# SERVICES_NOT_CHECKED rather than returned, because this function's stdout
# is the unhealthy-name list and its rc is not consulted by _check_services.
# Returning 0 here without the flag is the whole of #1266.
SERVICES_NOT_CHECKED=0
_unhealthy_services() {
    local rows rc name workdir launch health logfile
    rows=$(_recover_parse_registry "$SERVICES_REGISTRY"); rc=$?
    if (( rc == 79 )); then
        SERVICES_NOT_CHECKED=1
        return 0
    fi
    (( rc == 0 )) || { SERVICES_NOT_CHECKED=1; return 0; }
    [[ -z "$rows" ]] && return 0
    while IFS=$'\t' read -r name workdir launch health logfile; do
        [[ -z "$name" ]] && continue
        _recover_service_healthy "$workdir" "$health" || printf '%s ' "$name"
    done <<<"$rows"
}

# rc 0 == "checked, and every service is healthy". An unreadable registry is
# never rc 0 here: SERVICES_NOT_CHECKED is set INSIDE the $( ) subshell by
# _unhealthy_services, so it cannot propagate out — the flag is re-derived in
# THIS scope from the parser's own rc. Reading the subshell's copy would be a
# silent always-0, i.e. the defect re-introduced one layer down.
_check_services() {
    local bad rc
    _recover_parse_registry "$SERVICES_REGISTRY" >/dev/null 2>&1; rc=$?
    if (( rc != 0 )); then
        SERVICES_NOT_CHECKED=1
        return 1
    fi
    SERVICES_NOT_CHECKED=0
    bad=$(_unhealthy_services)
    [[ -z "${bad// }" ]]
}

# --- poll loop -------------------------------------------------------------

say "verifying stack convergence (timeout ${TIMEOUT}s): watcher$( (( CHECK_ORCH )) && echo ', orchestrator'), services"

waited=0
w_ok=0; o_ok=0; s_ok=0
while :; do
    _check_watcher       && w_ok=1 || w_ok=0
    _check_orchestrator  && o_ok=1 || o_ok=0
    _check_services      && s_ok=1 || s_ok=0

    if (( w_ok && o_ok && s_ok )); then
        say "stack converged in ${waited}s: watcher fresh$( (( CHECK_ORCH )) && echo ', orchestrator up'), services healthy"
        exit 0
    fi

    if (( waited >= TIMEOUT )); then
        break
    fi

    if (( waited % 15 == 0 )); then
        say "  ...waiting (${waited}s): watcher=$( (( w_ok )) && echo ok || echo DOWN)$( (( CHECK_ORCH )) && printf ' orchestrator=%s' "$( (( o_ok )) && echo ok || echo DOWN)") services=$( (( s_ok )) && echo ok || echo DOWN)"
    fi

    sleep "$POLL"
    waited=$(( waited + POLL ))
done

# --- timeout summary -------------------------------------------------------

down=()
(( w_ok )) || down+=("watcher (heartbeat stale or pid dead — see monitor/.state/watcher.log)")
if (( CHECK_ORCH )) && (( ! o_ok )); then
    down+=("orchestrator (window '$TARGET_WINDOW' not present — the watcher spawns it within ~10s; check the cockpit)")
fi
svc_not_checked=0
if (( ! s_ok )); then
    bad_svcs=$(_unhealthy_services)
    if (( SERVICES_NOT_CHECKED )); then
        svc_not_checked=1
        down+=("services: NOT CHECKED — the registry at $SERVICES_REGISTRY exists and could not be read (mode/ACL/ESTALE). No statement about service health is available; this is NOT a report that services are healthy.")
    else
        down+=("services: ${bad_svcs:-unknown} (see monitor/svc.sh status)")
    fi
fi

echo "[verify-stack] stack did NOT fully converge after ${TIMEOUT}s:" >&2
for d in "${down[@]}"; do echo "[verify-stack]   - $d" >&2; done
echo "[verify-stack] inspect with: monitor/svc.sh status  |  monitor/ng watcher-status" >&2

# A CONFIRMED failure outranks NOT-CHECKED: 79 only when the services leg is
# the ONLY thing wrong and the reason is that it could not be read.
if (( svc_not_checked )) && (( ${#down[@]} == 1 )); then
    echo "[verify-stack] verdict: NOT CHECKED (79) — services unreadable; nothing else is down." >&2
    exit 79
fi
exit 1
