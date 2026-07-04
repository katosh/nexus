#!/usr/bin/env bash
# remote-sshd-supervised.sh — self-healing foreground supervisor for the
# in-sandbox sshd that backs the confined remote agent channel
# (agent-channel RFC §4.8.2). The nexus-remote-ssh analogue of
# labsh-supervised.sh: this is what the services.registry row launches
# (headless, via bootstrap-recover's setsid path) and what
# `monitor/svc.sh stop` TERMs.
#
#   Usage: remote-sshd-supervised.sh
#
# OFF-BY-DEFAULT CONTRACT (§4.8): registration IS the enable signal (there
# is no `monitor.remote.enabled` flag). If the `nexus-remote-ssh` row is not
# in services.registry, this EXITS 0 WITHOUT LISTENING — a fresh clone ships
# inert. The supervisor is normally launched BY the registry, so the row is
# present; the periodic re-check below makes a `remote-up.sh --down` (which
# removes the row) tear the listener down on its own.
#
# When enabled it execs the in-sandbox `sshd` in the foreground (-D) with
# a HARDENED, self-contained config (system /etc/ssh/sshd_config is
# ignored via -f /dev/null; every option is an explicit -o), binding the
# configured bind_address:port. The daemon runs INSIDE the sandbox, so a
# login inherits the kernel bwrap confinement — the sandbox is the
# confinement, we add no new trust boundary (§4.1, §4.5).
#
# Confinement is via the per-key `command=` forced command in
# authorized_keys (written by `ng remote enroll`), NOT a global
# ForceCommand — see remote-forced-command.sh for why (a global
# ForceCommand would erase the per-principal binding).
#
# NOTE (phasing): whether the sandbox image actually SHIPS an sshd that a
# non-root in-sandbox user can bind on a high port is the agent_sandbox
# side (RFC §4.6, Phase A1, operator-gated). This wrapper is the
# nexus-code half: correct, hardened invocation + supervision + an honest
# healthcheck. If sshd is absent or cannot start, the wrapper logs LOUD
# and exits non-zero so the emit-only healthcheck surfaces it — it never
# pretends to serve.
#
# On SIGTERM/SIGINT (svc.sh stop sends TERM to the process group): kill
# the sshd child and exit 0.
#
# Env knobs (production leaves unset):
#   REMOTE_SSHD_RESTART_DELAY  seconds between restart attempts (default 5)
#   REMOTE_SSHD_BIN            explicit sshd path (default: autodetect)

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_remote_lib.sh
source "$_script_dir/_remote_lib.sh"

# Join the nexus-wide env if present (PATH for tooling), harmless to source.
[[ -f "$_script_dir/locals-env.sh" ]] && . "$_script_dir/locals-env.sh"

RESTART_DELAY="${REMOTE_SSHD_RESTART_DELAY:-5}"
[[ "$RESTART_DELAY" =~ ^[0-9]+$ && "$RESTART_DELAY" -ge 1 ]] || RESTART_DELAY=5
RESTART_DELAY_MAX="${REMOTE_SSHD_RESTART_DELAY_MAX:-60}"
[[ "$RESTART_DELAY_MAX" =~ ^[0-9]+$ ]] || RESTART_DELAY_MAX=60
# How often to re-check the enable gate WHILE a healthy sshd is running, so
# a mid-run `enabled: false` flip tears the listener down without waiting
# for an sshd exit (service-review MEDIUM-2).
GATE_RECHECK="${REMOTE_SSHD_GATE_RECHECK:-30}"
[[ "$GATE_RECHECK" =~ ^[0-9]+$ && "$GATE_RECHECK" -ge 1 ]] || GATE_RECHECK=30
WRAPPER="$_script_dir/remote-forced-command.sh"
ENROLL="$_script_dir/remote-enroll.sh"

# Prune per-window enroll-only authorized_keys lines whose one-time token is
# consumed/expired, so the enroll window stays == the token window (RFC §4.9.1,
# rootless self-enroll). Best-effort; never fatal.
prune_enroll() { [[ -x "$ENROLL" ]] && "$ENROLL" prune-enroll >/dev/null 2>&1 || true; }

log() { echo "[$(date -Is 2>/dev/null || date)] remote-sshd: $*"; }

# ── off-by-default gate (registration is the enable signal) ───────────
if ! _remote_registered; then
    log "service '$REMOTE_SERVICE_NAME' not registered — NOT listening (off-by-default). Exiting 0."
    exit 0
fi

PRINCIPALS_DIR=$(_remote_principals_dir)
BIND=$(_remote_bind_address)
PORT=$(_remote_port)
HOST_KEY="$PRINCIPALS_DIR/ssh_host_ed25519_key"
AUTH_KEYS="$PRINCIPALS_DIR/authorized_keys"
BANNER_FILE="$PRINCIPALS_DIR/banner.txt"

# Write the pre-auth SSH banner describing the imposed restrictions (and that
# broader access is obtained out-of-band via the client's own operator — there
# is NO in-nexus expansion intake; operator directive, PR #379). Shown to EVERY
# connecting client before auth, in BOTH command policies — so even an
# `unfiltered` shell client (whose key has no forced command, so the policy
# verb never runs) still learns the posture on connect. Non-secret.
write_banner() {
    _remote_policy_notice > "$BANNER_FILE" 2>/dev/null || return 0
    chmod 644 "$BANNER_FILE" 2>/dev/null || true
}

[[ "$PORT" =~ ^[0-9]+$ ]] || { log "FATAL: bad port: $PORT"; exit 1; }
[[ -x "$WRAPPER" ]] || { log "FATAL: forced-command wrapper missing/not executable: $WRAPPER"; exit 1; }

# Locate sshd. It is normally in sbin, not on a user PATH.
locate_sshd() {
    if [[ -n "${REMOTE_SSHD_BIN:-}" ]]; then printf '%s' "$REMOTE_SSHD_BIN"; return 0; fi
    local c
    for c in sshd /usr/sbin/sshd /sbin/sshd /usr/local/sbin/sshd; do
        if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return 0; fi
        [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
SSHD=$(locate_sshd) || {
    log "FATAL: no sshd binary found (looked for sshd, /usr/sbin/sshd, …)."
    log "  The in-sandbox sshd transport is the agent_sandbox side (RFC §4.6/A1)."
    log "  Until the sandbox image ships sshd, this service cannot listen; the"
    log "  emit-only healthcheck will surface this to the orchestrator."
    exit 1
}

[[ -f "$HOST_KEY" ]] || { log "FATAL: host key absent: $HOST_KEY (run: ng remote gen-host-key)"; exit 1; }
[[ -f "$AUTH_KEYS" ]] || { log "WARNING: no authorized_keys at $AUTH_KEYS — no client can connect until 'ng remote enroll' adds one"; }

# Hardened, self-contained sshd argv. -f /dev/null => ignore the system
# sshd_config entirely; every policy is an explicit -o (§4.3). No global
# ForceCommand (per-key command= is authoritative — see the header).
build_sshd_args() {
    # PermitTTY follows the command policy: an `unfiltered` shell and a
    # read-only `attach` both need a pty; `channel-only` request-only does
    # not (tighter). policy/attach-aware.
    local permit_tty=no
    if _remote_unfiltered || _remote_allow_attach; then permit_tty=yes; fi
    SSHD_ARGS=(
        -D -e
        -f /dev/null
        -h "$HOST_KEY"
        -p "$PORT"
        -o "ListenAddress=$BIND"
        -o "Protocol=2"
        -o "PasswordAuthentication=no"
        -o "KbdInteractiveAuthentication=no"
        -o "ChallengeResponseAuthentication=no"
        -o "PubkeyAuthentication=yes"
        -o "HostbasedAuthentication=no"
        -o "PermitRootLogin=no"
        -o "PermitEmptyPasswords=no"
        -o "MaxAuthTries=3"
        -o "AllowUsers=$USER"
        -o "AllowTcpForwarding=no"
        -o "AllowAgentForwarding=no"
        -o "X11Forwarding=no"
        -o "PermitTunnel=no"
        -o "GatewayPorts=no"
        -o "PermitTTY=$permit_tty"
        -o "PermitUserRC=no"
        -o "PermitUserEnvironment=no"
        -o "AllowStreamLocalForwarding=no"
        -o "UsePAM=no"
        -o "PrintMotd=no"
        -o "Banner=$BANNER_FILE"
        -o "AuthorizedKeysFile=$AUTH_KEYS"
        # DoS caps (single-purpose, low-concurrency endpoint; tight by design).
        -o "LoginGraceTime=15"
        -o "MaxStartups=3:50:10"
        -o "MaxSessions=4"
        -o "ClientAliveInterval=30"
        -o "ClientAliveCountMax=2"
        -o "LogLevel=VERBOSE"
        # Strong-crypto allowlist — matters most on a routable LAN bind. Every
        # algorithm here is supported on OpenSSH 7.6p1 (the sandbox floor) and
        # remains valid on 9.x. AEAD ciphers (chacha20-poly1305, *-gcm) carry
        # their own integrity; the ETM MACs cover the CTR fallback. SHA-1 kex,
        # CBC ciphers, and the SHA-1 (ssh-rsa) client-key signature are excluded.
        -o "KexAlgorithms=curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512"
        -o "Ciphers=chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr"
        -o "MACs=hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com"
        -o "PubkeyAcceptedKeyTypes=ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521"
    )
    # Self-enrollment is ROOTLESS (RFC §4.9.1). We deliberately DO NOT use
    # AuthorizedKeysCommand: an in-sandbox sshd is NON-root and OpenSSH's
    # auth_secure_path REQUIRES the command (and every path component) owned by
    # uid 0 — but the sandbox user namespace has NO uid-0-owned files (real root
    # maps to `nobody`), so sshd refuses to EXECUTE any AuthorizedKeysCommand
    # here ("Unsafe AuthorizedKeysCommand: bad ownership or modes"). No
    # relocation/chmod can satisfy it. Proven empirically; see
    # docs/remote-access-akc-note.md (the impossibility proof) + test-remote-self-enroll.sh.
    #
    # Instead, token-gated self-enroll rides AuthorizedKeysFile (the one rootless
    # key primitive): `ng remote enroll-invite` installs a per-window, enroll-ONLY
    # key line whose forced command is remote-enroll-session.sh; the client
    # connects with that enroll key and pipes <token>\n<its-own-pubkey> to
    # self-enroll. The enroll line is removed on consume and pruned on expiry
    # (prune-enroll, below), so the enroll window == the token window.
    SSHD_ARGS+=( -o "AuthorizedKeysCommand=none" )
    # NOTE: deliberately NO `-o ForceCommand` — a global ForceCommand is
    # evaluated BEFORE the per-key command= (verified on OpenSSH 7.6p1), so
    # it would shadow the per-key `<principal>` arg and break every key. In
    # `channel-only` the confinement is the per-key command=, validated by
    # validate_auth_keys() before each launch (RFC §4.8.2 reconciled). In
    # `unfiltered` the keys intentionally carry NO command= (full shell); the
    # sandbox still confines, and the transport hardening above still applies.
}

# HIGH-severity startup gate, POLICY-AWARE. In `channel-only` the entire
# confinement rests on EVERY authorized_keys line carrying a `command="…"`
# forced command — refuse to launch if any non-blank, non-comment line lacks
# one (a command=-less line would grant a shell, defeating the policy). In
# `unfiltered` a shell IS the intent, so no command= is required (the
# transport hardening + the sandbox are the controls). An absent
# authorized_keys file is fine (no client can connect yet). Returns
# non-zero ⇒ caller must NOT exec sshd.
validate_auth_keys() {
    [[ -f "$AUTH_KEYS" ]] || return 0
    if _remote_unfiltered; then
        log "command policy: unfiltered — keys grant a sandbox-confined shell (no forced-command requirement)"
        return 0
    fi
    local line bad=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
        case "$line" in
            command=\"*) ;;  # good: forced command present
            *) log "FATAL: channel-only policy but an authorized_keys line lacks a forced command (would grant a shell): ${line:0:40}…"; bad=1 ;;
        esac
        case "$line" in *restrict*) ;; *) log "WARNING: authorized_keys line without 'restrict' hardening: ${line:0:40}…" ;; esac
    done < "$AUTH_KEYS"
    (( bad == 0 ))
}

SSHD_CHILD=''
on_term() {
    log "signal received — stopping sshd, exiting"
    [[ -n "$SSHD_CHILD" ]] && kill -TERM "$SSHD_CHILD" 2>/dev/null || true
    exit 0
}
trap on_term TERM INT

log "supervisor up: sshd=$SSHD bind=$BIND port=$PORT principals_dir=$PRINCIPALS_DIR"
log "  (read-only attach: $(_remote_allow_attach && echo enabled || echo disabled))"

delay="$RESTART_DELAY"
while true; do
    # Re-check the gate each loop: a `remote-up.sh --down` (row removed)
    # should not be fought by the restart loop.
    if ! _remote_registered; then
        log "service '$REMOTE_SERVICE_NAME' deregistered — exiting 0 (no relaunch)."
        exit 0
    fi
    # HIGH gate (defense-in-depth; remote-up.sh checks this too): never listen
    # on a wildcard bind, nor a routable LAN bind without a from_cidr pin. This
    # sensitive endpoint is fail-closed on exposure — surface unhealthy, don't
    # serve, until the operator fixes bind_address/from_cidr.
    guard_err=$(_remote_bind_guard 2>&1); guard_rc=$?
    if (( guard_rc != 0 )); then
        [[ -n "$guard_err" ]] && while IFS= read -r l; do log "$l"; done <<<"$guard_err"
        log "refusing to launch sshd: unsafe bind exposure ($BIND). Fix bind_address/from_cidr, then it relaunches."
        sleep "$delay" & wait $! 2>/dev/null
        delay=$(( delay * 2 )); (( delay > RESTART_DELAY_MAX )) && delay="$RESTART_DELAY_MAX"
        continue
    fi
    # HIGH gate: never launch against an authorized_keys that contains a
    # shell-granting (command=-less) line. Surface as unhealthy, don't serve.
    if ! validate_auth_keys; then
        log "refusing to launch sshd: authorized_keys failed validation. Fix/quarantine it, then it relaunches."
        sleep "$delay" & wait $! 2>/dev/null
        delay=$(( delay * 2 )); (( delay > RESTART_DELAY_MAX )) && delay="$RESTART_DELAY_MAX"
        continue
    fi
    write_banner            # refresh in case command_policy changed
    prune_enroll            # drop enroll lines whose token has expired/consumed
    build_sshd_args
    log "exec: $SSHD ${SSHD_ARGS[*]}"
    "$SSHD" "${SSHD_ARGS[@]}" &
    SSHD_CHILD=$!
    # Supervise WHILE alive: periodically re-check the enable gate so a
    # mid-run flip to disabled tears the listener down promptly (don't wait
    # for an sshd exit that may never come on a healthy daemon).
    while kill -0 "$SSHD_CHILD" 2>/dev/null; do
        sleep "$GATE_RECHECK" & wait $! 2>/dev/null
        prune_enroll        # expire stale enroll lines while sshd stays up
        if ! _remote_registered; then
            log "service '$REMOTE_SERVICE_NAME' deregistered mid-run — stopping sshd, exiting 0."
            kill -TERM "$SSHD_CHILD" 2>/dev/null
            wait "$SSHD_CHILD" 2>/dev/null
            exit 0
        fi
    done
    wait "$SSHD_CHILD"; rc=$?
    SSHD_CHILD=''
    if (( rc == 0 )); then delay="$RESTART_DELAY"; fi   # clean exit → reset backoff
    log "sshd exited rc=$rc — restarting in ${delay}s"
    sleep "$delay" & wait $! 2>/dev/null
    # capped exponential backoff so a persistently-failing sshd (port taken,
    # config reject) does not hot-spin every RESTART_DELAY forever.
    delay=$(( delay * 2 )); (( delay > RESTART_DELAY_MAX )) && delay="$RESTART_DELAY_MAX"
done
