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
        awk -F'\t' -v n="$SERVICE_NAME" '$1 != n' "$SERVICES_REGISTRY" > "$tmp"
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
    awk -F'\t' -v n="$SERVICE_NAME" '$1 != n' "$SERVICES_REGISTRY" > "$tmp"
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
    read -r pid < "$pf" 2>/dev/null
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

print_fingerprint() {
    [[ -x "$ENROLL_BIN" ]] && "$ENROLL_BIN" host-fingerprint 2>/dev/null || true
}

cmd_up() {
    # Registration IS enabling — running this command turns the channel on
    # (no separate config flag). Off by default = this was never run / was
    # --down'd. Registering the row before launch makes the supervisor +
    # healthcheck (which gate on registration) treat the service as live.
    # Fail-closed bind-exposure gate BEFORE we register/enable anything: a
    # routable bind is a first-class in-sandbox path, but sensitive — it must
    # carry a from_cidr pin and never be a wildcard (see _remote_bind_guard).
    _remote_bind_guard || die "unsafe bind configuration — fix config/nexus.yml and re-run (nothing was enabled)"
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

    local outcome
    outcome=$(recover_service "$SERVICE_NAME" "$NEXUS_ROOT" "$LAUNCH_BIN" "$HEALTH_BIN" "$LOGFILE")
    case "$outcome" in
        healthy|supervisor-alive|relaunched|window-present) say "service outcome: $outcome" ;;
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

    cat >&2 <<EOF

  nexus-remote-ssh service is registered$( "$HEALTH_BIN" >/dev/null 2>&1 && echo " and HEALTHY" || echo " (listener not yet up)" ).

  Bind:            $(_remote_bind_address):$(_remote_port)
  Command policy:  $(_remote_command_policy)$( _remote_unfiltered && echo "  (clients get a sandbox-confined SHELL)" || echo "  (request-only channel)" )
  Read-only attach:$(_remote_allow_attach && echo " enabled" || echo " disabled")
  Host key:        $(_remote_principals_dir)/ssh_host_ed25519_key
  Host fingerprint (give to the operator to PIN; NON-secret):
EOF
    print_fingerprint >&2
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
    local health sup
    if "$HEALTH_BIN" >/dev/null 2>&1; then health=healthy; else health=unhealthy; fi
    if _recover_service_running "$SERVICE_NAME" "$LAUNCH_BIN"; then
        sup="pid:$(cat "$(_recover_pidfile "$SERVICE_NAME")" 2>/dev/null)"
    else
        sup='-'
    fi
    echo "$SERVICE_NAME  registered:$(_remote_registered && echo yes || echo no)  policy:$(_remote_command_policy)  $health  supervisor:$sup  bind:$(_remote_bind_address):$(_remote_port)"
    [[ "$health" == healthy ]]
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "$VERB" in
        up)     cmd_up ;;
        down)   cmd_down ;;
        status) cmd_status ;;
    esac
fi
