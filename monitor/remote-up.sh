#!/usr/bin/env bash
# remote-up.sh — orchestrator-driven enable helper for the confined remote
# agent channel (agent-channel RFC §4.8.3). The nexus-remote-ssh analogue
# of jupyter-up.sh: one idempotent command that registers + starts the
# off-by-default SSH endpoint as a supervised service, through the SAME
# decision path bootstrap-recover uses.
#
#   monitor/remote-up.sh            # register row + host key + start + verify
#   monitor/remote-up.sh --status   # one-line status; exit 0 iff healthy
#   monitor/remote-up.sh --down      # stop supervisor + remove registry row
#   monitor/remote-up.sh --port     # explain the port: in-force / recorded /
#                                   # configured / per-operator DERIVED default
#
# THE ENABLE PROCEDURE — ONE command (registration IS the enable signal;
# there is NO separate `monitor.remote.enabled` flag). Off by default = this
# was never run (no `nexus-remote-ssh` row). The orchestrator runs:
#       monitor/remote-up.sh
#   1. ensures the `nexus-remote-ssh` row in services.registry (emit-only
#      policy — a network listener is never blind-restarted). THIS is the
#      enable: the supervisor/healthcheck/wrapper all gate on this row.
#   2. ensures an ed25519 HOST KEY (generated in-sandbox, 0600, never copied
#      out); prints its FINGERPRINT (non-secret) for the operator to pin.
#   3. starts the supervisor via recover_service (idempotent).
#   4. waits for remote-ssh-health to go green; prints bind + policy + fingerprint.
#   (Edit config/nexus.yml only to change bind/port/command_policy/etc from
#    their defaults — those are behavioral params, not the on/off switch.)
#
#   FIRST CLIENT: secrets are provisioned out-of-band, NOT here —
#   `ng remote issue-token` + `ng remote enroll` (§4.9). remote-up never
#   touches a client keypair or a token.
#
# Env: NEXUS_ROOT, NEXUS_SERVICES_REGISTRY, NEXUS_STATE_DIR (as in
#      bootstrap-recover.sh). REMOTE_UP_TIMEOUT — seconds to wait for green
#      (default 30; sshd binds fast, unlike a venv build).

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NEXUS_ROOT="${NEXUS_ROOT:-$(cd "$_script_dir/.." && pwd)}"
export NEXUS_ROOT

# shellcheck source=_remote_lib.sh
source "$_script_dir/_remote_lib.sh"
# Containment invariant for a supervised-service ACTIVATION helper: this
# launcher must live inside the NEXUS_ROOT it registers under, and neither may
# be ephemeral (your-org/nexus-code#1034 rec. 3, applying #577 to the service
# registry). Consulted by cmd_up ONLY — see the call site for why the
# read-only verbs and --down are deliberately not gated.
# shellcheck source=_service_root.sh
source "$_script_dir/_service_root.sh"
# Recovery primitives (recover_service, _recover_pidfile,
# _recover_service_running, SERVICES_REGISTRY) — same decision path as
# bootstrap-recover, so activation and recovery never drift.
# shellcheck source=bootstrap-recover.sh
source "$_script_dir/bootstrap-recover.sh"

SERVICE_NAME="$REMOTE_SERVICE_NAME"   # single source of truth (from _remote_lib.sh)
LAUNCH_BIN="$_script_dir/remote-sshd-supervised.sh"
HEALTH_BIN="$_script_dir/remote-ssh-health.sh"
ENROLL_BIN="$_script_dir/remote-enroll.sh"
LOGFILE="$NEXUS_ROOT/monitor/.state/remote-ssh.log"
UP_TIMEOUT="${REMOTE_UP_TIMEOUT:-30}"

die() { echo "remote-up: $*" >&2; exit 1; }
say() { echo "[remote-up] $*" >&2; }
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

VERB=up
while (( $# > 0 )); do
    case "$1" in
        --status) VERB=status; shift ;;
        --down)   VERB=down;   shift ;;
        --port)   VERB=port;   shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

# ── registry row (6 fields: name·workdir·launch·health·log·policy) ─────
ensure_registry_row() {
    local row
    printf -v row '%s\t%s\t%s\t%s\t%s\t%s' \
        "$SERVICE_NAME" "$NEXUS_ROOT" "$LAUNCH_BIN" "$HEALTH_BIN" "$LOGFILE" "emit-only"
    mkdir -p "$(dirname "$SERVICES_REGISTRY")"
    [[ -f "$SERVICES_REGISTRY" ]] || : > "$SERVICES_REGISTRY"
    _rewrite() {
        local tmp; tmp=$(mktemp "$SERVICES_REGISTRY.XXXXXX") || die "mktemp failed"
    # your-org/nexus-code#1266 (rewrite half). `awk … "$REG" > "$tmp"` FAILS
    # OPEN on an unreadable registry — rc 2, `$tmp` EMPTY — and the `mv` two
    # lines down then COMMITS that empty file over the operator's registry.
    # Nothing tests awk's rc (this script is `set -uo pipefail`, no `-e`), so
    # the function prints its success line and returns 0. Measured against an
    # 11-row registry at 85458bf8: `ensure` left 1 row, `remove` left 0, both
    # at rc 0 announcing success. That is strictly worse than the READ half of
    # this issue — it is permanent DATA DESTRUCTION, and afterwards every
    # reader legitimately reports "no services" because there genuinely are
    # none, so the manufactured success becomes self-consistent.
    #
    # The realistic driver is not chmod but a transient ESTALE/EIO on the
    # NFS-backed tree, where the DIRECTORY stays writable while the file read
    # fails — exactly the state in which `mv` succeeds.
    #
    # Read-then-write is not atomic here, so the rc of the READ is the only
    # thing standing between a transient fault and a destroyed registry.
        if ! awk -F'\t' -v n="$SERVICE_NAME" '$1 != n' "$SERVICES_REGISTRY" > "$tmp"; then
            rm -f "$tmp"
            die "registry at $SERVICES_REGISTRY exists and could not be READ (awk rc!=0) — REFUSING to rewrite it. Rewriting now would replace every existing row with just '$SERVICE_NAME'."
        fi
        printf '%s\n' "$row" >> "$tmp"
        mv "$tmp" "$SERVICES_REGISTRY"
    }
    if command -v flock >/dev/null 2>&1; then
        ( flock -w 10 9 || exit 9; _rewrite ) 9>>"$SERVICES_REGISTRY.lock" \
            || die "registry update failed (lock timeout or write error)"
    else
        _rewrite
    fi
    say "registry: $SERVICE_NAME -> $NEXUS_ROOT (emit-only) ($SERVICES_REGISTRY)"
}

remove_registry_row() {
    [[ -f "$SERVICES_REGISTRY" ]] || return 0
    local tmp; tmp=$(mktemp "$SERVICES_REGISTRY.XXXXXX") || die "mktemp failed"
    # your-org/nexus-code#1266 (rewrite half). `awk … "$REG" > "$tmp"` FAILS
    # OPEN on an unreadable registry — rc 2, `$tmp` EMPTY — and the `mv` two
    # lines down then COMMITS that empty file over the operator's registry.
    # Nothing tests awk's rc (this script is `set -uo pipefail`, no `-e`), so
    # the function prints its success line and returns 0. Measured against an
    # 11-row registry at 85458bf8: `ensure` left 1 row, `remove` left 0, both
    # at rc 0 announcing success. That is strictly worse than the READ half of
    # this issue — it is permanent DATA DESTRUCTION, and afterwards every
    # reader legitimately reports "no services" because there genuinely are
    # none, so the manufactured success becomes self-consistent.
    #
    # The realistic driver is not chmod but a transient ESTALE/EIO on the
    # NFS-backed tree, where the DIRECTORY stays writable while the file read
    # fails — exactly the state in which `mv` succeeds.
    #
    # Read-then-write is not atomic here, so the rc of the READ is the only
    # thing standing between a transient fault and a destroyed registry.
    if ! awk -F'\t' -v n="$SERVICE_NAME" '$1 != n' "$SERVICES_REGISTRY" > "$tmp"; then
        rm -f "$tmp"
        die "registry at $SERVICES_REGISTRY exists and could not be READ (awk rc!=0) — REFUSING to rewrite it. Rewriting now would TRUNCATE it to zero rows."
    fi
    mv "$tmp" "$SERVICES_REGISTRY"
    say "registry: removed row '$SERVICE_NAME'"
}

stop_supervisor() {
    local pf pid i
    pf=$(_recover_pidfile "$SERVICE_NAME")
    if ! _recover_service_running "$SERVICE_NAME" "$LAUNCH_BIN"; then
        [[ -f "$pf" ]] && { rm -f "$pf"; say "removed stale pidfile"; }
        return 0
    fi
    # `[[ -r ]]` first — the redirection failure is the SHELL's (#723). See
    # the same fix in jupyter-up.sh::stop_supervisor.
    pid=""; [[ -r "$pf" ]] && read -r pid < "$pf"
    say "stopping supervisor pid $pid (TERM to its process group)"
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    for i in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    if kill -0 "$pid" 2>/dev/null; then
        say "still alive after 5s — KILL"; kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    fi
    rm -f "$pf"
}

# ── host key (§4.9 step 1): generated in-sandbox, fingerprint printed ──
ensure_host_key() {
    [[ -x "$ENROLL_BIN" ]] || die "remote-enroll.sh missing: $ENROLL_BIN"
    "$ENROLL_BIN" gen-host-key || die "host-key generation failed"
}

# ── the fingerprint the operator hands a client, READ OFF THE LIVE ENDPOINT ──
# (your-org/nexus-code#609 item 3.) This used to print the ON-DISK key
# unconditionally, directly beneath the live bind:port and under a `healthy`
# banner. That pairing is the whole handoff: the operator pins this value
# out-of-band, so printing our key beside an endpoint we never verified hands a
# client a fingerprint for an endpoint it will never reach — and the collision
# stays invisible at exactly the moment it is cheapest to catch. Now the source
# of every printed fingerprint is labelled, and a mismatch is loud.
print_fingerprint() {
    local host port
    host=$(_remote_probe_host); port=$(_remote_port)
    _remote_identity_probe "$host" "$port" 5
    case $? in
        0)  printf '    %s\n' "$_REMOTE_ID_LIVE_FP" >&2
            printf '    ^ the endpoint at %s:%s PROVED POSSESSION of this key (its signature over\n' "$host" "$port" >&2
            printf '      the key exchange verified against our pinned public key, not merely a key\n' >&2
            printf '      it claimed to hold). Pin this.\n' >&2
            ;;
        1)  printf '    %s   <-- THE LIVE ENDPOINT %s:%s PRESENTS THIS\n' "${_REMOTE_ID_LIVE_FP:-<no host key>}" "$host" "$port" >&2
            printf '    %s   <-- ours, on disk\n' "$_REMOTE_ID_OURS_FP" >&2
            printf '\n  *** PORT COLLISION — DO NOT HAND EITHER VALUE TO A CLIENT ***\n' >&2
            printf '  %s\n' "$_REMOTE_ID_REASON" >&2
            printf '  %s\n' "$(_remote_attribute_listener "$port")" >&2
            printf '  A client pinning OUR fingerprint cannot reach that endpoint; one pinning the\n' >&2
            printf '  live value would be trusting a third party. Resolve the collision first.\n' >&2
            ;;
        *)  printf '    %s\n' "$(_remote_host_fingerprint | awk '{print $2}')" >&2
            printf '    ^ ON-DISK value — NOT verified against the live endpoint (%s).\n' "$_REMOTE_ID_REASON" >&2
            printf '      Re-check once the listener is up: monitor/remote-up.sh --status\n' >&2
            ;;
    esac
}

# ── PORT-COLLISION REFUSAL (your-org/nexus-code#609 item 2) ──────────────
# The bind:port is host-global: the sandbox shares the host network namespace,
# so every operator nexus on this machine competes for the same address (this
# includes 127.0.0.1 — a loopback bind is not private to a sandbox). Whoever
# binds first wins; the loser's supervisor sits in an EADDRINUSE backoff loop
# forever while its healthcheck reads green off the winner. So refuse to enable
# onto an endpoint held by something that is not ours, with a NAMED reason.
#
# We do NOT bind elsewhere silently (a client is pinned to host:port
# out-of-band; moving the port behind their back breaks them without telling
# them) and we do NOT start and hope. And we never signal the squatter: it is
# outside this namespace and is not ours to touch.

# Can our sshd bind host:port? rc 0 = NO, something holds it; rc 1 = yes.
#
# your-org/nexus-code#810 — ASK BY BINDING. This used to be three connect-ish
# signals (a /dev/tcp connect, an nc connect, an `ss` LISTEN row), and a
# connect answers a DIFFERENT question than the one the caller acts on. It is
# wrong in both directions: a port held as an ephemeral SOURCE port refuses a
# connect and still fails bind() (`#769`), and a listener mid-teardown answers
# one connect and is gone by the next observation (`#810`, seen in CI on
# `#795` under 58% CPU stall). `_remote_port_bindable` performs the actual
# bind; the three original signals stay as the no-python3 fallback so a host
# without an interpreter degrades to the previous guard rather than to a
# confident wrong answer.
port_is_held() {
    local host="$1" port="$2"
    _remote_port_bindable "$host" "$port"
    case $? in
        0) return 1 ;;   # bound it ourselves — free
        1) return 0 ;;   # EADDRINUSE — held
    esac
    # your-org/nexus-code#1028 — BOUNDED, via the one helper in _remote_lib.sh.
    # This is a near-duplicate of `_remote_port_is_held` and carried the same
    # unbounded connect; fixing only the lib copy would have left the hang on
    # the path an operator actually reaches (`remote-up.sh` blew a 90s and a
    # 150s cap on exactly this line).
    _remote_tcp_probe "$host" "$port"
    case $? in
        0) return 0 ;;
        2) printf 'remote-up: WARNING — TCP probe of %s:%s TIMED OUT; occupancy is UNKNOWN, not free (your-org/nexus-code#1028)\n' \
               "$host" "$port" >&2 ;;
    esac
    if command -v nc >/dev/null 2>&1; then
        printf '' | nc -w 2 "$host" "$port" >/dev/null 2>&1 && return 0
    fi
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH 2>/dev/null | awk -v p=":$port\$" '$4 ~ p {f=1} END{exit !f}' && return 0
    fi
    return 1
}

# ── THE TWO-OBSERVATION PROBLEM (your-org/nexus-code#810) ────────────────
#
# `check_port_collision` observes occupancy, THEN verifies ownership, and then
# refuses on the strength of the first observation. Those are two observations
# of a mutable fact separated by an ssh-keyscan, so they can disagree — and in
# CI they did, producing a refusal that contradicted itself in its own text:
#
#     REFUSING to enable — a listener holds 127.0.0.1:58944 …
#       cannot verify the endpoint host key: … Connection refused
#       no LISTEN socket visible on port 58944
#
# Both cannot be true of one instant. A run aborted with `nothing was
# registered or started` over a peer that was already gone.
#
# The fix is to make the REFUSAL re-establish its own premise. Called
# immediately before every refusal: rc 0 = the collision still stands, refuse;
# rc 1 = the port is bindable NOW, so whatever was there has gone and there is
# nothing to refuse over.
#
# This cannot make the guard weaker. The guard exists to stop us enabling onto
# a port our supervisor cannot bind — and this arm fires only when we have
# just bound that port ourselves. It also declines to answer unless the bind
# probe is CONCLUSIVE: rc 2 (no python3, unbindable address) leaves the
# refusal standing, so a host that cannot run the probe keeps the pre-#810
# behaviour exactly.
#
# THE RACE IT DOES NOT CLOSE, stated rather than papered over: a third party
# may bind between this probe and the sshd bind moments later. That window is
# irreducible without handing sshd a pre-bound descriptor, which `sshd -p`
# cannot take. When it is lost, the supervisor hits EADDRINUSE and the
# identity-aware healthcheck surfaces it — a loud, recoverable state, and the
# same one the pre-existing `_remote_find_free_port` TOCTOU already accepts.
_collision_still_stands() {
    local host="$1" port="$2"
    _remote_port_bindable "$host" "$port"
    case $? in
        0)  say "port check: :$port was occupied at detection and is BINDABLE at verification —"
            say "  the listener went away between the two observations, so there is no collision"
            say "  to refuse over (your-org/nexus-code#810). Proceeding; if a third party takes the"
            say "  port before sshd binds, the supervisor reports EADDRINUSE and health goes red."
            return 1 ;;
        1)  return 0 ;;   # still EADDRINUSE — the refusal stands on fresh evidence
        *)  return 0 ;;   # cannot tell — never downgrade a refusal on a non-answer
    esac
}

check_port_collision() {
    local host port
    host=$(_remote_probe_host); port=$(_remote_port)
    if ! port_is_held "$host" "$port"; then
        say "port check: nothing listening on $host:$port — free to bind"
        return 0
    fi
    _remote_identity_probe "$host" "$port" 5
    case $? in
        0)  say "port check: $host:$port is already held by OUR daemon ($_REMOTE_ID_LIVE_FP) — proceeding (idempotent)"
            return 0 ;;
        1)  _collision_still_stands "$host" "$port" || return 0
            say "REFUSING to enable — $_REMOTE_ID_REASON"
            say "  $(_remote_attribute_listener "$port")"
            say "  Our supervisor could not bind ($host:$port is taken); it would loop on"
            say "  'Address already in use' forever while the healthcheck read green off THEIR"
            say "  daemon. Nothing was registered, started, or changed."
            say "  Resolve by ONE of:"
            say "    * coordinate one channel per host with the other operator, or"
            say "    * change monitor.remote.port — then re-tell every client the new host:port"
            say "      AND have them re-pin the host fingerprint out-of-band."
            say "  Do NOT kill that listener: it belongs to a process outside this namespace."
            return 1 ;;
        3)  _collision_still_stands "$host" "$port" || return 0
            say "REFUSING to enable — $_REMOTE_ID_REASON"
            say "  …yet something IS listening on $host:$port, so that listener is not ours."
            say "  $(_remote_attribute_listener "$port")"
            return 1 ;;
        *)  # INDETERMINATE. Before refusing an IDEMPOTENT re-run, check whether
            # our own supervisor is recorded as running: a probe we could not
            # complete is not evidence that the daemon we are supervising is
            # somebody else's. A pid record is weak identity (your-org/nexus-code#608)
            # and would never be enough to declare the ENDPOINT ours — but here
            # the cost of being wrong is only the pre-existing EADDRINUSE loop,
            # while refusing wrongly breaks `remote-up` as a re-runnable command.
            if _recover_service_running "$SERVICE_NAME" "$LAUNCH_BIN"; then
                say "port check: identity unverifiable ($_REMOTE_ID_REASON) but OUR supervisor is"
                say "  recorded running — treating $host:$port as ours and proceeding (idempotent re-run)."
                return 0
            fi
            if [[ "${REMOTE_UP_ALLOW_UNVERIFIED_PORT:-}" == 1 ]]; then
                say "WARNING — a listener holds $host:$port and its identity is UNVERIFIED"
                say "  ($_REMOTE_ID_REASON). Proceeding only because REMOTE_UP_ALLOW_UNVERIFIED_PORT=1."
                return 0
            fi
            # THE ARM #810 WAS OBSERVED ON. This is the refusal whose own text
            # contradicted itself: it asserts a listener holds the port and
            # then prints the two later observations (`Connection refused`, no
            # LISTEN row) that say the opposite. Re-establish before refusing.
            _collision_still_stands "$host" "$port" || return 0
            say "REFUSING to enable — a listener holds $host:$port and we cannot verify whose it is:"
            say "  $_REMOTE_ID_REASON"
            say "  $(_remote_attribute_listener "$port")"
            say "  Install openssh-client (ssh-keyscan) so identity is answerable, or override"
            say "  deliberately with REMOTE_UP_ALLOW_UNVERIFIED_PORT=1 (which cannot bypass a"
            say "  CONFIRMED foreign endpoint — only an unknown one)."
            return 1 ;;
    esac
}

# ── SETUP-TIME OPEN-PORT SELECTION (your-org/nexus-code#637 item 1) ───────
# Choose a bindable port at enable time and RECORD it as the canonical port, so a
# hard-coded constant can never make the endpoint unrecoverable — the exact state
# the 2026-07-29 container restart left it in: 22022 grabbed by a foreign socket
# in another namespace, with no way to move by design. The choice is STICKY: a
# port a prior setup already recorded is PREFERRED, so re-running remote-up never
# churns an endpoint a client is pinned to. We move ONLY when the preferred port
# is held by something that is NOT our daemon — and then we alert LOUDLY and
# DURABLY (cmd_up), because the client is pinned to host:port out-of-band and must
# be re-informed (#637 item 3). Sets: CHOSEN_PORT; on a move PORT_CHANGED=1 +
# PORT_OLD/PORT_NEW. rc 1 (whole band full) is fatal.
PORT_SPAN="${REMOTE_PORT_SELECT_SPAN:-100}"
CHOSEN_PORT=""; PORT_CHANGED=0; PORT_OLD=""; PORT_NEW=""
select_and_record_port() {
    local host recorded preferred chosen idrc
    # An explicit MONITOR_REMOTE_PORT is a DELIBERATE pin (an operator override or
    # a test seam) — honor it verbatim, no probing, no moving. Auto-selection is
    # for the config/default path where the operator did not pin a port. This also
    # keeps _remote_port's precedence honest: env outranks the recorded file, so
    # selecting-then-moving while env is pinned would record a port nothing binds.
    if [[ -n "${MONITOR_REMOTE_PORT:-}" ]]; then
        chosen="$MONITOR_REMOTE_PORT"
        say "port select: MONITOR_REMOTE_PORT=$chosen is explicitly pinned — honoring it verbatim (no auto-select)"
        _remote_record_port "$chosen" 2>/dev/null || true
        CHOSEN_PORT="$chosen"
        return 0
    fi
    host=$(_remote_probe_host)
    recorded=$(_remote_recorded_port)                  # empty on first setup
    if [[ -n "$recorded" ]]; then preferred="$recorded"; else preferred=$(_remote_configured_port); fi
    # Last-resort fallback for a non-numeric preference. This used to be the
    # literal 22022 — the very constant every operator shares, so a garbled
    # config landed EVERY nexus on the one port guaranteed to collide
    # (your-org/nexus-code#893). Fall back to the per-operator DERIVED port.
    [[ "$preferred" =~ ^[0-9]+$ ]] || preferred=$(_remote_derived_port)

    if ! port_is_held "$host" "$preferred"; then
        chosen="$preferred"
        say "port select: $host:$preferred is free — using it"
    else
        _remote_identity_probe "$host" "$preferred" 5; idrc=$?
        case "$idrc" in
            0)  chosen="$preferred"                    # OUR daemon PROVED possession — keep (idempotent)
                say "port select: $host:$preferred is already held by OUR daemon — keeping it (no churn)" ;;
            1|3)  # DEFINITE not-ours: a foreign daemon (rc 1), or we hold NO host key
                # so nothing serving here can be ours (rc 3). The lib marks BOTH
                # DEFINITE and forbids downgrading them — safe to move.
                chosen=$(_remote_find_free_port "$host" "$preferred" "$PORT_SPAN" port_is_held) || {
                    say "port select: FAILED — no free port in [$preferred, $((preferred+PORT_SPAN))) on $host"
                    say "  reason the preferred port is unusable: $_REMOTE_ID_REASON"
                    return 1; }
                say "port select: $host:$preferred is held by a NON-ours listener — $_REMOTE_ID_REASON"
                say "  $(_remote_attribute_listener "$preferred")"
                say "  moving to the next free port: $chosen (the preferred port stays untouched — never signalled)" ;;
            *)  # INDETERMINATE (rc 2): the lib could NOT verify whose listener this
                # is (no ssh/ssh-keyscan, or the endpoint was unreachable this
                # instant). "I could not tell" is NOT "somebody else owns it" — and
                # moving the port on a don't-know STRANDS every pinned client. So do
                # NOT move and do NOT record: keep the preferred port and DEFER to
                # check_port_collision, which is fail-CLOSED on exactly this verdict
                # (it proceeds only if OUR supervisor is recorded running, or the
                # operator sets REMOTE_UP_ALLOW_UNVERIFIED_PORT, else it refuses).
                # rc 2 is the ONE overridable verdict and must not be consumed here
                # as a definite one (the don't-know-as-definite class: #603/#607/#626).
                say "port select: identity of the listener on $host:$preferred is UNVERIFIABLE ($_REMOTE_ID_REASON)"
                say "  — NOT moving (a move on a don't-know strands pinned clients); deferring to the fail-closed collision gate."
                CHOSEN_PORT="$preferred"
                return 0 ;;
        esac
    fi

    if [[ "$chosen" != "$preferred" ]]; then
        _remote_record_port_change "$preferred" "$chosen" \
            "preferred port $preferred occupied by a non-ours listener at setup"
        PORT_CHANGED=1; PORT_OLD="$preferred"; PORT_NEW="$chosen"
    fi
    _remote_record_port "$chosen" || { say "port select: could not record chosen port $chosen"; return 1; }
    CHOSEN_PORT="$chosen"
    return 0
}

# ── THE PORT-CHANGED ALERT (your-org/nexus-code#757) ─────────────────────
# select_and_record_port's header has always promised an alert that is "LOUD and
# DURABLE". The durable half was missing: what ran here was one `sandbox-notify`,
# `2>/dev/null`-muted and `|| true`-swallowed. Three measured reasons that is
# transient, all detailed in remote-port-change-notify.sh's header — the sharpest
# being that the message classifies as `task` in monitor/notifywrap/sandbox-notify
# (the catch-all, highest-traffic class) and is BATCHED away by a 300 s
# cross-window cooldown whenever any worker rang a bell in the last five minutes.
#
# So the durable fan-out (issue comment + push + local copy) is now the
# mechanism, and the bell is the nice-to-have. Both are reported, neither is
# swallowed.
#
# WE DO NOT BLOCK THE BRING-UP ON A FAILED ALERT. By the time we run, the port
# has already moved and been recorded — a client is already stale. Aborting would
# leave the operator with a stale client AND a dead endpoint instead of just a
# stale client, and it would make an unconfigured notification target into an
# outage. Instead the failure is made PERSISTENT: the emitter drops an
# UNDELIVERED marker in principals_dir, which cmd_status surfaces on every run
# until it is resolved. That is the loud-without-blocking shape.
alert_port_change() {
    local notifier="$_script_dir/remote-port-change-notify.sh"
    # The bell first — cheap, and useful for whoever IS at the terminal. Prefixed
    # `CRITICAL:` so notifywrap classifies it as `critical` (60 s window, opens an
    # incident) instead of dropping it into the `task` catch-all. Still
    # best-effort: it is not the durable surface and must never be load-bearing.
    if command -v sandbox-notify >/dev/null 2>&1; then
        sandbox-notify "CRITICAL: nexus-remote-ssh port CHANGED $PORT_OLD->$PORT_NEW — re-inform your remote client (was pinned to :$PORT_OLD)" \
            || say "  (the terminal bell failed — the durable surfaces below are what matter)"
    else
        say "  (no sandbox-notify on PATH — the durable surfaces below are what matter)"
    fi

    if [[ ! -x "$notifier" ]]; then
        say "  !! DURABLE ALERT NOT SENT: $notifier is missing or not executable."
        say "     Re-inform your remote client BY HAND: it must connect to :$PORT_NEW, not :$PORT_OLD."
        return 1
    fi
    local rc=0
    "$notifier" --old "$PORT_OLD" --new "$PORT_NEW" \
        --reason "preferred port $PORT_OLD occupied by a non-ours listener at setup" || rc=$?
    if (( rc != 0 )); then
        say ""
        say "  !! THE DURABLE PORT-CHANGE ALERT FAILED (exit $rc) — see the per-surface reasons above."
        say "     The endpoint bring-up CONTINUES (a working endpoint nobody was told about still"
        say "     beats no endpoint), but NOBODY HAS BEEN INFORMED. Your remote client is pinned to"
        say "     :$PORT_OLD and will fail to connect until you re-inform it of :$PORT_NEW."
        say "     The text to send it: $(_remote_principals_dir)/port-change-notice.md"
        say "     Re-send once the surface is fixed:"
        say "       monitor/remote-port-change-notify.sh --old $PORT_OLD --new $PORT_NEW"
    fi
    return "$rc"
}

cmd_up() {
    # FIRST gate, before every other one: may THIS launcher enable a service at
    # all? Everything below writes a registry row naming `$LAUNCH_BIN` — which
    # is `$_script_dir/remote-sshd-supervised.sh`, i.e. THIS tree's supervisor,
    # NOT `$NEXUS_ROOT`'s. So a clone's copy of this script registers a clone
    # path, and it does so whether NEXUS_ROOT was inherited (the row lands in
    # the PRIMARY registry pointing at a launcher the primary does not contain)
    # or not (the whole activation forks into the clone — your-org/nexus-code#1034).
    # Neither is recoverable by the primary once the clone is gone. Refuse here,
    # where nothing has been created yet.
    #
    # Only `up` is gated. `--status` and `--port` create nothing, and `--down`
    # is the RETIREMENT path: gating it would strand exactly the state this
    # guard exists to prevent.
    SVCROOT_TAG=remote-up SVCROOT_VERB=remote-up.sh \
        svcroot_guard "$_script_dir" "$NEXUS_ROOT" \
        || die "refusing to enable '$SERVICE_NAME' from this tree (see above) — nothing was registered, started or changed"
    # Registration IS enabling — running this command turns the channel on
    # (no separate config flag). Off by default = this was never run / was
    # --down'd. Registering the row before launch makes the supervisor +
    # healthcheck (which gate on registration) treat the service as live.
    # Fail-closed bind-exposure gate BEFORE we register/enable anything: a
    # routable bind is a first-class in-sandbox path, but sensitive — it must
    # carry a from_cidr pin and never be a wildcard (see _remote_bind_guard).
    _remote_bind_guard || die "unsafe bind configuration — fix config/nexus.yml and re-run (nothing was enabled)"
    # Fail-closed CREDENTIAL-STORAGE gate: the host key, authorized_keys and
    # enrollment tokens may only ever live under $HOME/.claude (0700, single-uid,
    # survives a sandbox restart) — never in the group-shared project tree.
    # Harden the modes we own first, so a legacy dir self-heals rather than
    # bricking; the LOCATION rule is never auto-"fixed".
    _remote_principals_harden
    _remote_principals_guard || die "unsafe credential storage — fix principals_dir and re-run (nothing was enabled)"
    # WHAT YOUR PIN ACTUALLY MEANS — printed every bring-up, never conditional on
    # something looking wrong. `from_cidr` constrains the source address of the
    # LAST HOP, not the client: behind a bastion / jump host / VPN concentrator /
    # NAT it authenticates shared infrastructure and says nothing about WHICH
    # client. A correctly-written `from=` line is not evidence of a client
    # restriction, and the weak case has to be REPORTABLE rather than silent —
    # it survives every check the absence-focused guards perform.
    say "from_cidr meaning: $(_remote_pin_meaning)"
    # SEQUENCE the posture change: refuse to APPLY a ROUTABLE move while any
    # enrolled principal has not yet RE-ENROLLED onto the pin the new posture
    # requires. An invitation merely being outstanding is NOT enough and does
    # not release this — the client has to redeem it, which it can only do while
    # the current posture is still serving, which is why this refuses. A
    # locked-out client cannot ask this channel why it is locked out.
    # Runs BEFORE anything is registered or started, so a refusal leaves the
    # current posture serving. Exact width of the guarantee, including what it
    # deliberately does NOT gate: see the header block in _remote_lib.sh.
    # The die text must name the condition that ACTUALLY refused. It used to say
    # "issue the invitation(s) … then re-run", which is the pre-S2 release rule:
    # issuance no longer opens this gate, redemption does. The message an
    # operator reads under a refusal is the one they act on, so a stale one
    # sends them round a loop that cannot terminate.
    _remote_posture_change_guard || die "posture change refused — the principal(s) named above have not RE-ENROLLED yet. Issuing an invitation is step 1 of 3; the client must redeem it over the current posture, then re-run (nothing was changed)"
    # Choose + RECORD an open port BEFORE the collision gate (#637 item 1). This
    # runs after the credential guards (it writes the recorded-port file into the
    # now-validated principals_dir) and before check_port_collision (which reads
    # _remote_port — now the CHOSEN port — so a fresh selection lands the endpoint
    # on a free port instead of wedging the supervisor on EADDRINUSE). On a move it
    # sets PORT_CHANGED, which we alert on below and which forces a supervisor
    # relaunch so the new port actually takes effect.
    select_and_record_port || die "could not select an open port — nothing was registered or started (see above)"
    # A deliberate re-enable is the operator answering the bind-blocked
    # diagnosis (your-org/nexus-code#894). Selection above has just re-verified
    # the port, so a marker left over from the OLD port must not park the
    # supervisor we are about to start. The supervisor re-verifies at startup
    # anyway; clearing here keeps `--status` from reporting a resolved incident.
    if _remote_bind_blocked; then
        say "clearing the bind-blocked marker — re-enabling on port $CHOSEN_PORT"
        _remote_clear_bind_blocked
    fi
    if (( PORT_CHANGED )); then
        say ""
        say "*** PORT CHANGED: $PORT_OLD -> $PORT_NEW ***"
        say "  The preferred port ($PORT_OLD) was held by another process at setup, so the endpoint"
        say "  moved to $PORT_NEW. Your remote client is pinned to host:$PORT_OLD OUT-OF-BAND and will"
        say "  fail to connect until you re-inform it of :$PORT_NEW (the setup message below carries it)."
        say "  Durable record: $(_remote_principals_dir)/port-history.log"
        alert_port_change
    fi
    # Fail-closed PORT-COLLISION gate, BEFORE we register or start anything: the
    # bind:port is host-global on a shared host, and enabling onto a foreign
    # listener produces the worst possible state — our supervisor wedged on
    # EADDRINUSE while the healthcheck reads green off somebody else's daemon.
    check_port_collision || die "port collision — nothing was registered or started (see the reason above)"
    command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]] \
        || say "WARNING: no sshd on PATH — the listener cannot come up until the sandbox image ships sshd (RFC §4.6/A1). Registering + host-key anyway; health will report unhealthy."
    if _remote_bind_is_loopback "$(_remote_bind_address)"; then
        say "bind: $(_remote_bind_address):$(_remote_port) (loopback — on-host only; tunnel/carrier for off-host)"
    else
        say "bind: $(_remote_bind_address):$(_remote_port) (routable LAN — off-host clients connect directly; from_cidr pin=$(_remote_from_cidr))"
    fi
    say "command policy: $(_remote_command_policy) (set monitor.remote.command_policy=unfiltered for a sandbox-confined shell)"
    ensure_registry_row
    ensure_host_key
    # NOTE: the posture is recorded only AFTER the endpoint is confirmed
    # serving — see the commit step below the health wait. Recording it here
    # (which is what this did) is the ordering bug the guard exists to prevent,
    # one level up: an ABORTED bring-up would leave behind a record of a posture
    # that never served, permanently disarming the guard for that transition.

    # A running supervisor captured the OLD port at its launch (remote-sshd-
    # supervised.sh reads _remote_port ONCE, before its loop). recover_service is
    # idempotent — it would report `supervisor-alive` and leave that stale bind in
    # place — so a port change must stop the supervisor first, forcing a clean
    # relaunch that re-reads the now-recorded port.
    if (( PORT_CHANGED )); then
        say "restarting the supervisor so it binds the new port ($PORT_NEW)"
        stop_supervisor
    fi

    local outcome
    outcome=$(recover_service "$SERVICE_NAME" "$NEXUS_ROOT" "$LAUNCH_BIN" "$HEALTH_BIN" "$LOGFILE")
    case "$outcome" in
        healthy|supervisor-alive|relaunched|window-present) say "service outcome: $outcome" ;;
        # An sshd is answering on our bind:port but no supervisor holds it
        # (your-org/nexus-code#606). Do NOT fall through to the health wait —
        # it would go green off the orphan (or off a listener that is not even
        # ours) and print a ready banner for a channel nobody supervises.
        healthy-unsupervised)
            say "UNSUPERVISED: the endpoint answers but the supervisor record is stale."
            say "  A reconcile is required BEFORE this reports ready: monitor/svc.sh restart $SERVICE_NAME"
            say "  Verify the listener is OURS first — compare the presented host key against"
            say "  $(_remote_principals_dir)/ssh_host_ed25519_key.pub:"
            say "    ssh-keyscan -p $(_remote_port) $(_remote_bind_address) | ssh-keygen -lf -"
            say "  A port probe (or an SSH banner) proves only that SOMETHING answers, not that it is ours."
            return 1 ;;
        *) say "service launch outcome: $outcome (see $LOGFILE) — continuing to health wait" ;;
    esac

    local waited=0
    while ! "$HEALTH_BIN" >/dev/null 2>&1; do
        if (( waited >= UP_TIMEOUT )); then
            say "not healthy after ${UP_TIMEOUT}s. If sshd is unavailable in this sandbox, that is expected"
            say "  (the transport is the agent_sandbox side, RFC §4.6/A1). Service log: $LOGFILE"
            say "  Re-check: monitor/remote-up.sh --status"
            # The row + host key are in place; this is not a hard failure of
            # the (idempotent) enable step. Exit 0 with the banner so the
            # exit code does not contradict a later-converging listener.
            break
        fi
        sleep 2; waited=$(( waited + 2 ))
    done

    # ── COMMIT THE POSTURE, through the tested seam ──────────────────────
    # The decision lives in _remote_commit_posture (see _remote_lib.sh), NOT
    # here, and deliberately so: inline, the invariant "recorded iff serving"
    # had no seam at which any test could observe it, and every textual
    # assertion written over this file's shape was defeatable. This call site
    # must stay a pure delegation — putting a branch back here re-creates the
    # untestable shape.
    # ⚠ THIS CALL'S PLACEMENT IS NOT GUARDED BY ANY TEST. The suite closes the
    # CENSUS axis (how many call sites) but cannot close the PLACEMENT axis
    # (whether the one call sits inside this health-gated block). Move it onto
    # another branch and every assertion stays green while the endpoint records
    # a posture for an endpoint that never served. See the box above
    # `_remote_commit_posture` in _remote_lib.sh before touching this.
    _remote_commit_posture "$HEALTH_BIN"
    case $? in
        0) ;;   # serving and recorded — the silent, normal path
        1) say "WARNING: could not record the applied posture at $(_remote_posture_file) — the next run will treat this posture as a change (the guarded direction)" ;;
        2) say "posture NOT recorded: the endpoint is not serving, so this posture was not applied."
           say "  The posture-change guard stays ARMED for this transition — as it should." ;;
    esac

    cat >&2 <<EOF

  nexus-remote-ssh service is registered$( "$HEALTH_BIN" >/dev/null 2>&1 && echo " and HEALTHY" || echo " (listener not yet up)" ).
$( (( PORT_CHANGED )) && printf '\n  *** PORT CHANGED %s -> %s — re-inform the remote client (it is pinned to :%s) ***\n' "$PORT_OLD" "$PORT_NEW" "$PORT_OLD" )
  Bind:            $(_remote_bind_address):$(_remote_port)
  Port:            $(_remote_port)   <-- the OPEN port chosen + recorded at setup; a client connects here
  Command policy:  $(_remote_command_policy)$( _remote_unfiltered && echo "  (clients get a sandbox-confined SHELL)" || echo "  (request-only channel)" )
  Read-only attach:$(_remote_allow_attach && echo " enabled" || echo " disabled")
  Host key:        $(_remote_principals_dir)/ssh_host_ed25519_key
  Host fingerprint (cross-check; NON-secret):
EOF
    print_fingerprint >&2
    # THE PINNABLE LINE, not just a fingerprint. A client handed only SHA256:…
    # cannot populate known_hosts without connecting once and accepting what
    # arrives — TOFU against a port this very script warns may be held by a
    # co-tenant. `ssh-keyscan` is not a substitute: it reports the key a server
    # CLAIMS without verifying a signature, and this public key is not secret,
    # so anyone can replay it. Keyed on an ALIAS, because 127.0.0.1 is not an
    # identity on a shared network namespace and an address-keyed pin breaks on
    # every posture move.
    _remote_endpoint_params
    if [[ -n "$_REMOTE_EP_KNOWN_HOSTS_LINE" ]]; then
        cat >&2 <<EOF

  Host key LINE to give the client — this is what it PINS (NON-secret).
  It appends this verbatim to ~/.ssh/known_hosts.nexus:

    $_REMOTE_EP_KNOWN_HOSTS_LINE

  and connects with:
    $_REMOTE_EP_CONNECT policy

  Jump hops: $_REMOTE_EP_JUMP_NOTE
  Verify that form against a FRESH client (ignores your own ssh_config):
    $_REMOTE_EP_VERIFY_LINE
EOF
    else
        say "WARNING: no host public key on disk — cannot print a pinnable line yet"
    fi
    cat >&2 <<EOF

  Enroll a client (secret token delivered OUT-OF-BAND, never on GitHub):
    monitor/ng remote issue-token --principal <name>     # prints token to THIS session only
    monitor/ng remote enroll --principal <name> --pubkey <client.pub> --token <TOKEN>

  Manage:
    monitor/svc.sh status | logs $SERVICE_NAME | restart $SERVICE_NAME
  Disable (the single off switch): monitor/remote-up.sh --down
EOF
    return 0
}

cmd_down() {
    stop_supervisor
    remove_registry_row
    say "deactivated '$SERVICE_NAME' (no auto-revival until re-registered). Host key + authorized_keys are left in place."
}

cmd_status() {
    local health sup host port
    if "$HEALTH_BIN" >/dev/null 2>&1; then health=healthy; else health=unhealthy; fi
    if _recover_service_running "$SERVICE_NAME" "$LAUNCH_BIN"; then
        # First line only — see the same fix in jupyter-up.sh's cmd_status.
        # The pidfile is a three-line identity record (pid / ns= / start=)
        # since bcf9e3a, so `cat` here split this status across three lines
        # (your-org/nexus-code#729).
        # `[[ -r ]]` first: a redirection failure is the SHELL's, so a
        # `2>/dev/null` on `read` could not suppress it (#723).
        local _sp="" _pf; _pf=$(_recover_pidfile "$SERVICE_NAME")
        [[ -r "$_pf" ]] && read -r _sp < "$_pf"
        sup="pid:$_sp"
    else
        sup='-'
    fi
    # Report the identity verdict as its own field. `healthy` never implied
    # `ours` and this line used to let a reader assume it did — the exact
    # inference that made a 2h30m outage invisible (your-org/nexus-code#609).
    host=$(_remote_probe_host); port=$(_remote_port)
    local id=absent
    if port_is_held "$host" "$port"; then
        _remote_identity_probe "$host" "$port" 5
        id="$_REMOTE_ID_VERDICT"
    fi
    echo "$SERVICE_NAME  registered:$(_remote_registered && echo yes || echo no)  policy:$(_remote_command_policy)  $health  endpoint:$id  supervisor:$sup  bind:$(_remote_bind_address):$port  pin:$(_remote_pin_class)"
    # WHAT THE PIN ACTUALLY MEANS, on the surface an operator reads most often.
    # `--status` is where someone checks "is my channel fine?", and a from_cidr
    # that authenticates a shared bastion — or one that is malformed and
    # therefore restricts nothing — looks identical to a real client pin from
    # the one-line summary. bring-up already prints this; status did not, so the
    # value was stated once at enable time and never again.
    echo "  pin meaning: $(_remote_pin_meaning)" >&2
    [[ "$id" == foreign ]] && echo "  ^ $_REMOTE_ID_REASON" >&2
    # Surface the port PROVENANCE (#637): a recorded port that diverges from the
    # configured preference means setup had to move — a client pinned to the
    # configured value is stale. The port-history log is the durable trail.
    local rec cfg; rec=$(_remote_recorded_port); cfg=$(_remote_configured_port)
    if [[ -n "$rec" ]]; then
        if [[ "$rec" != "$cfg" ]]; then
            echo "  ^ port:$rec is RECORDED (chosen at setup), diverges from configured monitor.remote.port=$cfg — a client pinned to :$cfg is stale. History: $(_remote_principals_dir)/port-history.log" >&2
        fi
    fi
    # An UNDELIVERED port-change notice is the one failure that must not decay
    # into a single stderr line at 04:00 (your-org/nexus-code#757). The emitter
    # drops this marker when no durable surface accepted the alert, and clears it
    # on the first successful re-send — so it keeps announcing itself on every
    # status read until the operator has actually been informed.
    local undel; undel="$(_remote_principals_dir)/port-change-notice.UNDELIVERED"
    if [[ -f "$undel" ]]; then
        echo "  ^ A PORT-CHANGE NOTICE WAS NEVER DELIVERED — your remote client may still be pinned to a dead port." >&2
        while IFS= read -r _l; do [[ -n "$_l" ]] && echo "      $_l" >&2; done < "$undel"
        echo "      Text to send the client: $(_remote_principals_dir)/port-change-notice.md" >&2
        echo "      Re-send: monitor/remote-port-change-notify.sh --old <old> --new <new>" >&2
    fi
    # A supervisor that STOPPED on a permanent bind failure (your-org/nexus-code#894)
    # is not "down" in the ordinary sense — it is parked on a diagnosis. Say so
    # here, because `supervisor:-` alone reads as "crashed" and invites exactly
    # the restart that cannot work.
    if _remote_bind_blocked; then
        echo "  ^ $(_remote_bind_blocked_summary)" >&2
        echo "      The supervisor STOPPED deliberately (a foreign holder cannot clear by waiting)." >&2
        # Be exact about WHEN it re-checks. This service's registry policy is
        # emit-only, so the watcher NEVER auto-restarts it — there is no periodic
        # sweep that will pick this up. It re-verifies when it is next STARTED,
        # and then clears the marker by itself if the holder has gone.
        echo "      It re-verifies (and self-clears) on its next START — boot recovery," >&2
        echo "      'monitor/svc.sh restart nexus-remote-ssh', or remote-up.sh. The emit-only" >&2
        echo "      policy means nothing restarts it on a timer; this will not resolve unattended." >&2
        echo "      To move OUR port instead: monitor/remote-up.sh --down && monitor/remote-up.sh" >&2
        echo "      Incident: monitor/ng service-incident $SERVICE_NAME" >&2
    fi
    [[ "$health" == healthy ]]
}

# ── WHERE DOES THE PORT COME FROM? (your-org/nexus-code#893) ─────────────
# Per-operator derivation only helps if it is DISCOVERABLE. Four values can
# each be the answer and they are easy to confuse, so print all four with the
# precedence that resolves them, and name the identity the default derives from
# — that is what makes the port predictable rather than merely unique.
cmd_port() {
    local id derived cfg rec inforce
    id=$(_remote_operator_identity)
    derived=$(_remote_derived_port)
    cfg=$(_remote_configured_port)
    rec=$(_remote_recorded_port)
    inforce=$(_remote_port)
    echo "port IN FORCE:      $inforce"
    echo "  precedence: MONITOR_REMOTE_PORT env > recorded-at-setup > configured/derived"
    echo "  env MONITOR_REMOTE_PORT: ${MONITOR_REMOTE_PORT:-<unset>}"
    echo "  recorded at setup:       ${rec:-<none — remote-up.sh has not run since #637>}"
    echo "  configured preference:   $cfg"
    echo "  DERIVED default:         $derived   (operator identity '$id', band [$REMOTE_PORT_BAND_BASE, $((REMOTE_PORT_BAND_BASE + REMOTE_PORT_BAND_SPAN)))"
    echo "  recorded-port file:      $(_remote_recorded_port_file)"
    if [[ -n "$rec" && "$rec" != "$cfg" ]]; then
        echo "  NOTE: the recorded port diverges from the configured preference — a client pinned to :$cfg is stale."
    fi
    _remote_bind_blocked && echo "  NOTE: $(_remote_bind_blocked_summary)"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "$VERB" in
        up)     cmd_up ;;
        down)   cmd_down ;;
        status) cmd_status ;;
        port)   cmd_port ;;
    esac
fi
