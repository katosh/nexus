#!/usr/bin/env bash
# remote-ssh-health.sh — registry healthcheck for the nexus-remote-ssh
# service (agent-channel RFC §4.8.2). The single source of truth for
# "is the confined remote endpoint healthy?", shared by bootstrap-recover's
# revival decision and the watcher's continuous service-health task.
#
# Usage: remote-ssh-health.sh
# Exit 0 = healthy; non-zero = unhealthy.
#
# NOT-REGISTERED-AS-HEALTHY (the no-flap rule, §4.8.2): registration is the
# enable signal (no `monitor.remote.enabled` flag). If the nexus-remote-ssh
# row is absent the service is SUPPOSED to be not running, so "not
# listening" is the correct, healthy state — exit 0. This keeps an
# off/never-registered service from false-alarming the `--- service health
# ---` emit (the jupyterfix lesson: gate on the real intended state).
#
# REGISTERED: assert BOTH
#   (a) the forced-command wrapper is present + executable (the
#       confinement is meaningless without it), and
#   (b) a listener is actually up on the configured bind:port.
# Either missing → unhealthy (non-zero), which the emit-only policy
# escalates to the orchestrator after the grace window.

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_remote_lib.sh
source "$_script_dir/_remote_lib.sh"

# (a)+(b) only matter when registered. Not-registered ⇒ healthy-because-off.
if ! _remote_registered; then
    exit 0
fi

WRAPPER="$_script_dir/remote-forced-command.sh"
[[ -x "$WRAPPER" ]] || {
    echo "remote-ssh-health: UNHEALTHY — forced-command wrapper missing/not executable: $WRAPPER" >&2
    exit 1
}

BIND=$(_remote_bind_address)
PORT=$(_remote_port)
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "remote-ssh-health: UNHEALTHY — bad port: $PORT" >&2; exit 1; }

# IDENTITY-AWARE probe (the jupyter-health lesson applied to SSH): a bare
# "a socket is listening on the port" check is false-healthy — ANY process
# squatting the port would pass. So we read the SSH protocol BANNER (sshd
# sends `SSH-2.0-…` immediately on TCP connect, before auth) and require it.
# An unauthenticated connect that does NOT yield an SSH banner is NOT
# healthy, exactly as jupyter-health rejects an unauthenticated 200.
#
# TIMEOUT precedence: legacy REMOTE_HEALTH_TIMEOUT env (kept for compat) →
# monitor.remote.health_timeout via _remote_cfg (MONITOR_REMOTE_HEALTH_TIMEOUT
# env → config file → default 10). Integer seconds ≥1; garbage falls back to
# the default rather than wedging the probe (issue #434). Generous on purpose:
# a live sshd banners in ~0.03s even at loadavg ~12, so ONLY a pathological
# silent listener ever pays the full budget — 3s just gave a CPU-starved
# prober no slack.
TIMEOUT="${REMOTE_HEALTH_TIMEOUT:-$(_remote_health_timeout)}"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || TIMEOUT=10
PROBE_HOST="$BIND"; case "$BIND" in 0.0.0.0|::|"") PROBE_HOST=127.0.0.1 ;; esac

# Probe rc contract (shared by _probe_banner and the nc fallback):
#   0 = read an SSH banner (it IS sshd)
#   1 = connected AND read a NON-SSH banner (a foreign listener — definite)
#   2 = could not connect at all (refused / unreachable / no probe tool)
#   3 = connected but NO banner within TIMEOUT (INDETERMINATE: prober or
#       sshd starved under host load, a MaxStartups drop, or a silent
#       non-SSH listener — issue #434's flap lived here, misreported as 1)
_nc_banner() {
    command -v nc >/dev/null 2>&1 || return 2
    local b
    b=$(printf '' | nc -w "$TIMEOUT" "$PROBE_HOST" "$PORT" 2>/dev/null) || return 2
    b=${b%%$'\n'*}
    case "$b" in SSH-2.0-*|SSH-1.99-*) return 0 ;; "") return 3 ;; *) return 1 ;; esac
}
_probe_banner() {
    # ONE subshell, ONE TCP connect. The pre-#434 probe connected TWICE per
    # attempt (a subshell connect-test, then the real read) — doubling the
    # probe's pressure on sshd's MaxStartups=3, one of the two flap
    # mechanisms #431 diagnosed. The connect lives inside the subshell
    # because a redirection error on `exec` exits a non-interactive shell;
    # the `C:` marker distinguishes connect-failure from an empty read.
    local out banner
    out=$(
        { exec 3<>"/dev/tcp/$PROBE_HOST/$PORT"; } 2>/dev/null || exit 9
        printf 'C:'
        b=""
        IFS= read -t "$TIMEOUT" -r b <&3 2>/dev/null || true
        printf '%s' "$b"
    )
    if [[ "$out" != C:* ]]; then
        _nc_banner; return $?           # /dev/tcp unusable or connect refused → try nc
    fi
    banner="${out#C:}"
    case "$banner" in SSH-2.0-*|SSH-1.99-*) return 0 ;; "") return 3 ;; *) return 1 ;; esac
}

# Cheap connection-free liveness via ss (own-uid sockets). rc 0 = a LISTEN
# socket exists on PORT; 1 = none; 2 = ss absent/errored.
_ss_has_listener() {
    command -v ss >/dev/null 2>&1 || return 2
    local out; out=$(ss -ltnH 2>/dev/null) || return 2
    awk -v p=":$PORT\$" '$4 ~ p {f=1} END{exit !f}' <<<"$out"
}

# Retry before declaring unhealthy: on a busy node a single probe can miss
# transiently — sshd MaxStartups=3 probabilistically drops the probe's own
# connection, or the /dev/tcp read is scheduled past TIMEOUT under load —
# while the daemon is perfectly healthy (issue: sshflap 2026-07-03; #431).
# DEFINITE outcomes (foreign banner rc 1, no-connect rc 2) keep #431's
# retry-once so a real outage still reports within ~2 attempts; the
# INDETERMINATE connected-but-no-banner case (rc 3, #434's load-starvation
# signature) earns one extra backoff attempt before we give up. The healthy
# path exits on attempt 1 with zero added latency.
brc=1
for _attempt in 1 2 3; do
    _probe_banner; brc=$?
    (( brc == 0 )) && break
    (( _attempt == 2 && brc != 3 )) && break
    (( _attempt < 3 )) && sleep "$_attempt"
done
case "$brc" in
    0) exit 0 ;;  # confirmed: a real sshd is answering
    1) echo "remote-ssh-health: UNHEALTHY — listener on ${PROBE_HOST}:${PORT} is NOT sshd (non-SSH banner)" >&2; exit 1 ;;
    3) echo "remote-ssh-health: UNHEALTHY — connected to ${PROBE_HOST}:${PORT} but no SSH banner within ${TIMEOUT}s x3 attempts (sshd/prober starved under load, or a silent non-SSH listener)" >&2; exit 1 ;;
    2)
        # Could not banner-probe (no /dev/tcp AND no nc, or connect refused).
        # Fall back to ss liveness: a present socket with no usable banner
        # path is accepted (best-effort) with a caveat; no socket = down.
        if _ss_has_listener; then
            echo "remote-ssh-health: WARNING — cannot banner-probe (no /dev/tcp or nc); accepting ss liveness only on ${PROBE_HOST}:${PORT}" >&2
            exit 0
        fi
        echo "remote-ssh-health: UNHEALTHY — no listener on ${PROBE_HOST}:${PORT}" >&2
        exit 1
        ;;
esac
