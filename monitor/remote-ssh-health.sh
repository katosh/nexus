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
# REGISTERED: assert ALL THREE
#   (a) the forced-command wrapper is present + executable (the
#       confinement is meaningless without it),
#   (b) a listener is up on the configured bind:port AND speaks SSH, and
#   (c) that listener is OURS — it presents OUR host key.
# Any of the three missing → unhealthy (non-zero), which the emit-only
# policy escalates to the orchestrator after the grace window.
#
# (c) EXISTS BECAUSE (b) IS NOT ENOUGH (your-org/nexus-code#609). The bind:port
# is a host-global resource — the sandbox shares the host network namespace, so
# every operator nexus on this machine competes for the same address (127.0.0.1
# included; it is NOT private to a sandbox). On 2026-07-29 our daemon died with
# a container restart, another operator's nexus-remote-ssh took
# 140.107.222.134:22022 during the downtime, and THIS SCRIPT returned 0 for
# 2h30m — because an `SSH-2.0-*` banner from ANY sshd satisfied it. Worse, a
# 15-line socket server emitting eight bytes of `SSH-2.0-` also satisfied it: the
# check was PROTOCOL-aware while its own comments claimed identity-awareness,
# and that claim is why nobody suspected the green. The loser of a port race
# reporting healthy is the failure mode; being DOWN is the truth, and the truth
# is what lets the supervisor and the operator act.

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

# STAGE 1 — PROTOCOL probe. A bare "a socket is listening" check is
# false-healthy, so we read the SSH protocol BANNER (sshd sends `SSH-2.0-…`
# immediately on TCP connect, before auth) and require it. This stage is
# necessary but NOT sufficient: any responder emitting those eight bytes passes
# it. Stage 2 below establishes IDENTITY — that is the check which corresponds
# to jupyter-health rejecting an unauthenticated 200; the banner alone is only
# the equivalent of "something answered the port".
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
PROBE_HOST=$(_remote_probe_host "$BIND")

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
    # your-org/nexus-code#1028 — the `read -t` bounds the READ; it never bounded
    # the CONNECT, and a blackholing address blocks in `exec` for the kernel's
    # SYN budget (~127s here) before the read timeout is ever reached. Wrapping
    # the WHOLE subshell adds NO second connect — the one-connect-per-attempt
    # property this function exists to preserve (MaxStartups=3 pressure, #431)
    # is untouched.
    local _ct _ov
    _ct=$(_remote_connect_timeout)
    [[ "$_ct" =~ ^[0-9]+$ ]] && (( _ct > 0 )) || _ct=3
    _ov=$(( _ct + TIMEOUT ))
    # BRACES ARE LOAD-BEARING inside the probe below (your-org/nexus-code#1028
    # skeptic F1). Bash applies redirections LEFT TO RIGHT, so a bare
    # `exec 3<>… 2>/dev/null` attempts the connect BEFORE stderr is redirected
    # and leaks the shell own diagnostic. Measured: 91 bytes
    # ("bash: connect: Connection refused") against 0 for the grouped form.
    #
    # NOT COSMETIC. `_service_health.sh:313` selects the operator-facing verdict
    # by keyword over stderr with `head -n1`, and `refused` is in that list — so
    # the leak WINS over the real diagnostic and a port held by a FOREIGN
    # SQUATTER is reported as our daemon being down. That is the distinction
    # `#609`/`#637` exist to preserve, re-broken by a new route at unchanged rc.
    #
    # This comment is OUTSIDE the `bash -c '…'` on purpose: it is single-quoted,
    # so an apostrophe in there terminates the script (caught by `bash -n`).
    out=$(timeout "$_ov" bash -c '
        # BRACES ARE LOAD-BEARING — see the note above this bash -c.
        { exec 3<>"/dev/tcp/$0/$1"; } 2>/dev/null || exit 9
        printf "C:"
        b=""
        IFS= read -t "$2" -r b <&3 2>/dev/null || true
        printf "%s" "$b"
    ' "$PROBE_HOST" "$PORT" "$TIMEOUT")
    # A timeout leaves `out` without the `C:` marker, so it takes the SAME
    # branch as a refused connect: fall through to the `nc` probe (`-w 2`,
    # already bounded). A blind probe must never read as a live banner.
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
# ── STAGE 2: IDENTITY. Something speaks SSH here — is it OURS? ──────────
# Compare the host key the endpoint actually presents (read over a real key
# exchange, so a banner cannot fake it) against the one we would serve. Runs
# ONLY on the otherwise-healthy path, so it costs one extra TCP connection on a
# green poll and none on a failing one — deliberate, because the banner probe
# was reduced to ONE connect per attempt to stop starving sshd's MaxStartups=3
# (#434/#431) and stage 2 must not undo that. Two SEQUENTIAL connects are not
# three CONCURRENT ones.
identity_gate() {
    local rc
    _remote_identity_probe "$PROBE_HOST" "$PORT" "$TIMEOUT"; rc=$?
    # INDETERMINATE (tooling absent) earns one retry, like the banner probe:
    # a starved prober is not evidence of anything.
    if (( rc == 2 )); then
        sleep 1
        _remote_identity_probe "$PROBE_HOST" "$PORT" "$TIMEOUT"; rc=$?
    fi
    case "$rc" in
        0) return 0 ;;
        1)  # DEFINITE. No knob may downgrade this — it is the 2026-07-29 state.
            echo "remote-ssh-health: UNHEALTHY — $_REMOTE_ID_REASON" >&2
            echo "remote-ssh-health:   OUR channel is DOWN; the endpoint is being served by something else." >&2
            echo "remote-ssh-health:   $(_remote_attribute_listener "$PORT")" >&2
            # Distinguish "our supervisor is fighting this" from "our supervisor
            # STOPPED and is waiting for an operator" (your-org/nexus-code#894).
            # Without this line the two states are indistinguishable from health
            # output, and only one of them is going to resolve itself.
            _remote_bind_blocked && \
                echo "remote-ssh-health:   $(_remote_bind_blocked_summary) — the supervisor STOPPED (permanent); remedy: monitor/remote-up.sh --down && monitor/remote-up.sh" >&2
            return 1 ;;
        3)  # DEFINITE. No host key ⇒ our supervisor cannot even launch.
            echo "remote-ssh-health: UNHEALTHY — $_REMOTE_ID_REASON" >&2
            echo "remote-ssh-health:   something IS answering ${PROBE_HOST}:${PORT}, so that listener is not ours." >&2
            return 1 ;;
        *)  # INDETERMINATE — the ONLY overridable verdict, because it is the
            # only one that means "unknown" rather than "verified not ours".
            # ATTRIBUTE THE SOCKET HERE TOO (your-org/your-nexus#331). This was
            # printed on the rc-1 arm only, so the ONE verdict that means "I do
            # not know" withheld the most useful evidence an operator could have
            # for resolving it. During the 2026-08-24 false alarm the emit did
            # carry the line — from the rc-1 arm — and it CONTRADICTED the
            # verdict printed two lines above it:
            #
            #   socket owner uid:71780 held by "sshd",pid=19516,fd=3 (inside this namespace)
            #
            # It is EVIDENCE, NOT A VERDICT, and deliberately does not vote.
            # In-namespace + our uid rules out ANOTHER OPERATOR (a foreign
            # socket renders as uid:65534 with no pid attribution), but it does
            # NOT establish that the listener is the confined endpoint we mean —
            # a stale sshd of OUR OWN, serving a different host key, attributes
            # identically and is genuinely not-ours. `ss` may also be absent
            # entirely. So it sharpens the report and never moves the gate.
            if _remote_health_require_identity; then
                echo "remote-ssh-health: UNHEALTHY — cannot verify endpoint identity: $_REMOTE_ID_REASON" >&2
                echo "remote-ssh-health:   $(_remote_attribute_listener "$PORT")" >&2
                echo "remote-ssh-health:   an unverifiable endpoint is reported DOWN by default. Install openssh-client," >&2
                echo "remote-ssh-health:   or set monitor.remote.health_require_identity: false to accept protocol-only" >&2
                echo "remote-ssh-health:   evidence (which CANNOT distinguish our daemon from another operator's)." >&2
                return 1
            fi
            echo "remote-ssh-health: WARNING — identity unverified ($_REMOTE_ID_REASON);" >&2
            echo "remote-ssh-health:   accepting protocol-only evidence because health_require_identity=false." >&2
            return 0 ;;
    esac
}

case "$brc" in
    0) identity_gate && exit 0 || exit 1 ;;  # sshd is answering — and it is ours
    1) echo "remote-ssh-health: UNHEALTHY — listener on ${PROBE_HOST}:${PORT} is NOT sshd (non-SSH banner)" >&2; exit 1 ;;
    3) echo "remote-ssh-health: UNHEALTHY — connected to ${PROBE_HOST}:${PORT} but no SSH banner within ${TIMEOUT}s x3 attempts (sshd/prober starved under load, or a silent non-SSH listener)" >&2; exit 1 ;;
    2)
        # Could not banner-probe (no /dev/tcp AND no nc, or connect refused).
        # Fall back to ss liveness — but STILL through the identity gate. ss
        # reads the shared network namespace, so it sees another operator's
        # socket exactly as it sees ours; accepting it bare was a second route
        # to the same false green. ssh-keyscan does not depend on /dev/tcp or
        # nc, so identity is usually still answerable here.
        if _ss_has_listener; then
            echo "remote-ssh-health: WARNING — cannot banner-probe (no /dev/tcp or nc); falling back to ss liveness on ${PROBE_HOST}:${PORT}" >&2
            identity_gate && exit 0 || exit 1
        fi
        echo "remote-ssh-health: UNHEALTHY — no listener on ${PROBE_HOST}:${PORT}" >&2
        exit 1
        ;;
esac
