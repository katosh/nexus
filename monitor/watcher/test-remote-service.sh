#!/usr/bin/env bash
# Tests for the off-by-default registered remote-SSH SERVICE layer
# (agent-channel RFC §4.8):
#   monitor/remote-sshd-supervised.sh   (supervisor: disabled-exit, hardened argv, TERM)
#   monitor/remote-ssh-health.sh        (disabled-as-healthy; listener probe)
#   monitor/remote-up.sh                (enable helper: refuse-when-disabled,
#                                        registry row + host key + start + --down)
#
# Hermetic: sshd is a PATH/REMOTE_SSHD_BIN stub that records its argv and
# binds a real TCP socket on the configured port (so the listener probe is
# exercised against a real socket without OpenSSH). Registry + state +
# principals_dir are fixture-local; the operator's live registry is never
# touched. Supervisors/stubs are killed by recorded pidfile, never by
# pattern (self-kill hazard).
#
# Run: bash monitor/watcher/test-remote-service.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
MON_DIR=$(cd "$_test_dir/.." && pwd)
SUP="$MON_DIR/remote-sshd-supervised.sh"
HEALTH="$MON_DIR/remote-ssh-health.sh"
UP="$MON_DIR/remote-up.sh"

assert_rc() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s — rc %s want %s\n' "$label" "$got" "$want" >&2; FAIL=$((FAIL+1)); fi
}

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not present"; echo "ALL TESTS PASSED"; exit 0; }

WORK=$(mktemp -d -t nexus-remote-svc-XXXXXX)
cleanup() {
    local pf pid
    for pf in "$WORK"/state/services/*.pid; do
        [[ -f "$pf" ]] || continue
        read -r pid < "$pf" 2>/dev/null || continue
        [[ "$pid" =~ ^[0-9]+$ ]] && { kill -KILL -- "-$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null; }
    done
    [[ -n "${SUP_PID:-}" ]] && th_kill_own_child "$SUP_PID" KILL 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

export NEXUS_STATE_DIR="$WORK/state"
export NEXUS_SERVICES_REGISTRY="$WORK/services.registry"
export NEXUS_ROOT="$WORK/nexusroot"
# The supervisor now enforces the credential-storage invariant fail-closed:
# principals_dir MUST resolve under $HOME/.claude, 0700 (see
# _remote_principals_guard, test-remote-principals-guard.sh). There is no env
# escape hatch — by design. So the fixture relocates HOME rather than pointing
# principals_dir at a bare mktemp dir, which the guard would (correctly) refuse.
export HOME="$WORK/home"
export MONITOR_REMOTE_PRINCIPALS_DIR="$HOME/.claude/principals"
PRINCIPALS="$MONITOR_REMOTE_PRINCIPALS_DIR"
mkdir -p "$WORK/state" "$WORK/nexusroot/monitor/.state" "$HOME/.claude"
chmod 700 "$HOME/.claude"

# Allocate by BIND PROBE, never by arithmetic (your-org/nexus-code#800, the
# class of #769). "High and likely-free, spread by PID" is a PREDICTION about
# bindability derived from nothing that measures it; the windows below reach
# into the kernel's ephemeral range (32768-60999 here and on CI), where a port
# held as an outbound connection's SOURCE port answers a connect-probe FREE and
# then fails bind() with EADDRINUSE. Two of these windows also used to collide
# with each other outright — the 26000 and 27000 bases each appeared twice, so
# a single `$$` handed two fixtures the SAME port. th_alloc_port carries a
# process-wide exclusion set, which is what stops that recurring.
PORT=$(th_alloc_port 21000) || th_abort "no bindable fixture port in the 21000 window"
export MONITOR_REMOTE_PORT="$PORT"
export MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1

# stub sshd: record argv, bind 127.0.0.1:<-p PORT>, emit a real SSH protocol
# banner on each connection, hold until TERM.
#
# THE STUB IS NOT AN SSHD AND MUST NOT READ AS HEALTHY (your-org/nexus-code#609).
# This comment used to say the banner exists "so the identity-aware health probe
# passes" — and it did pass, which is precisely the defect: the stub implements
# no key exchange, holds no host key, and is eight bytes of `SSH-2.0-`. That a
# 20-line Python socket server satisfied a check documenting itself as
# identity-aware is what let another operator's daemon on our bind:port read
# green for 2h30m on 2026-07-29. So the health probe is NO LONGER a valid proxy
# for "the supervisor launched and bound", and the cases below use DIRECT
# evidence instead (see stub_bound): the recorded argv plus a real TCP connect.
# The cases that assert on the health VERDICT against this stub now assert
# UNHEALTHY, which is the truth.
STUB="$WORK/stub-bin"; mkdir -p "$STUB"
cat > "$STUB/sshd" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/sshd-argv"
port=""
while (( \$# )); do [[ "\$1" == "-p" ]] && { port="\$2"; shift; }; shift; done
exec python3 -c "
import socket,signal,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',int('\$port'))); s.listen(5)
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
while True:
    try:
        c,_=s.accept()
        c.sendall(b'SSH-2.0-stubsshd\r\n')   # the protocol banner sshd sends pre-auth
        c.close()
    except Exception:
        pass
"
EOF
chmod +x "$STUB/sshd"
export REMOTE_SSHD_BIN="$STUB/sshd"

# stub_bound <port> [tries] — DIRECT evidence that the supervisor launched the
# stub AND it is accepting connections on <port>. Replaces polling the health
# check, which now (correctly) rejects the stub on identity grounds and so can
# no longer serve as a launch signal. rc 0 = bound.
stub_bound() {
    local port="$1" tries="${2:-40}" i
    for (( i = 0; i < tries; i++ )); do
        if grep -q -- "-p $port" "$WORK/sshd-argv" 2>/dev/null \
           && ( exec 3<>"/dev/tcp/127.0.0.1/$port" ) 2>/dev/null; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

# Registration IS the enable signal (no MONITOR_REMOTE_ENABLED flag).
# Toggle the service on/off by adding/removing the nexus-remote-ssh row.
register_row()   { printf 'nexus-remote-ssh\t%s\t%s\t%s\t%s\temit-only\n' "$NEXUS_ROOT" "$SUP" "$HEALTH" "$WORK/svc.log" > "$NEXUS_SERVICES_REGISTRY"; }
deregister_row() { : > "$NEXUS_SERVICES_REGISTRY"; }

echo "== 1. NOT registered → supervisor exits 0 without listening, stub not run =="
deregister_row
rm -f "$WORK/sshd-argv"
timeout 5 bash "$SUP" >/dev/null 2>&1
assert_rc "unregistered supervisor exits 0" "$?" "0"
assert_no_file "stub sshd never invoked when unregistered" "$WORK/sshd-argv"

echo "== 2. NOT registered → health exits 0 (off-as-healthy, no flap) =="
bash "$HEALTH" >/dev/null 2>&1
assert_rc "unregistered health is healthy" "$?" "0"

echo "== 3. registered + no listener → unhealthy (exit 1) =="
register_row
bash "$HEALTH" >/dev/null 2>&1
assert_rc "registered+no-listener unhealthy" "$?" "1"

echo "== 4. registered but NO host key → supervisor FATAL (exit 1) =="
timeout 5 bash "$SUP" >/dev/null 2>&1
assert_rc "no host key → supervisor exits 1" "$?" "1"

echo "== 5. registered + host key + stub sshd → listens, hardened argv =="
mkdir -p "$PRINCIPALS"; chmod 700 "$PRINCIPALS"
ssh-keygen -t ed25519 -f "$PRINCIPALS/ssh_host_ed25519_key" -N '' >/dev/null 2>&1 \
    || { : > "$PRINCIPALS/ssh_host_ed25519_key"; }
rm -f "$WORK/sshd-argv"
bash "$SUP" >/dev/null 2>&1 &
SUP_PID=$!
stub_bound "$PORT"; listening=$?
assert_rc "registered service launches + binds (argv recorded, TCP accepts)" "$listening" "0"
# …AND the health check reports UNHEALTHY against it, because the stub is not
# our sshd. This is the #609 fix asserted in the suite that used to encode the
# defect: bound-and-bannering is no longer sufficient for green.
iderr=$(bash "$HEALTH" 2>&1); idrc=$?
assert_rc "bound banner-only stub is NOT healthy (identity required)" "$idrc" "1"
assert_contains "…and the reason names the identity failure" "$iderr" "NO usable ed25519 host key"
argv=$(cat "$WORK/sshd-argv" 2>/dev/null || echo "")
assert_contains "argv: no system config (-f /dev/null)" "$argv" "-f /dev/null"
assert_contains "argv: PasswordAuthentication=no"        "$argv" "PasswordAuthentication=no"
assert_contains "argv: PermitRootLogin=no"               "$argv" "PermitRootLogin=no"
assert_contains "argv: AllowTcpForwarding=no"            "$argv" "AllowTcpForwarding=no"
assert_contains "argv: pubkey auth on"                   "$argv" "PubkeyAuthentication=yes"
assert_contains "argv: binds configured port"            "$argv" "-p $PORT"
assert_contains "argv: AuthorizedKeysFile in principals" "$argv" "principals/authorized_keys"
assert_contains "argv: channel-only ⇒ PermitTTY=no"      "$argv" "PermitTTY=no"
assert_contains "argv: pre-auth Banner configured"       "$argv" "Banner=$PRINCIPALS/banner.txt"
# ROOTLESS self-enroll (RFC §4.9.1): an in-sandbox sshd is NON-root and CANNOT
# use AuthorizedKeysCommand (OpenSSH requires it owned by uid 0; the sandbox
# userns has no uid-0-owned files). So the supervisor pins AuthorizedKeysCommand
# to `none` even with self-enroll ON — self-enroll rides AuthorizedKeysFile via
# per-window enroll keys (ng remote enroll-invite), not a dynamic-key AKC.
assert_contains "argv: rootless ⇒ AuthorizedKeysCommand=none (no AKC)"  "$argv" "AuthorizedKeysCommand=none"
assert_not_contains "argv: NO AuthorizedKeysCommand script wired"        "$argv" "remote-authorized-keys-command.sh"
assert_not_contains "argv: NO AuthorizedKeysCommandUser"                 "$argv" "AuthorizedKeysCommandUser"
# NO global ForceCommand (per-key command= is authoritative — see header)
assert_not_contains "argv: NO global ForceCommand"        "$argv" "ForceCommand"
# the banner self-describes the policy + the expansion path (operator round-2)
assert_file_exists "pre-auth banner written" "$PRINCIPALS/banner.txt"
banner=$(cat "$PRINCIPALS/banner.txt" 2>/dev/null)
assert_contains "banner states the command policy" "$banner" "command policy: channel-only"
assert_contains "banner points to the client's own operator (no nexus intake)" "$banner" "YOUR OWN operator"
th_kill_own_child "$SUP_PID" TERM
wait "$SUP_PID" 2>/dev/null; suprc=$?
SUP_PID=""
assert_rc "supervisor TERM → exit 0" "$suprc" "0"

echo "== 5a1. UNSAFE CREDENTIAL STORAGE ⇒ supervisor refuses to launch sshd =="
# The end-to-end form of the invariant: it is not enough that
# _remote_principals_guard returns non-zero — the SERVICE must not listen.
# Pre-fix, a principals_dir in the group-shared project tree started an sshd
# happily and wrote a host key + authorized_keys there.
BADDIR="$WORK/nexusroot/monitor/.state/principals"   # i.e. the shared project tree
mkdir -p "$BADDIR"; chmod 700 "$BADDIR"
cp "$PRINCIPALS/ssh_host_ed25519_key" "$BADDIR/" 2>/dev/null || : > "$BADDIR/ssh_host_ed25519_key"
rm -f "$WORK/sshd-argv"
BPORT=$(th_alloc_port 25000) || th_abort "no bindable fixture port in the 25000 window"
MONITOR_REMOTE_PRINCIPALS_DIR="$BADDIR" MONITOR_REMOTE_PORT=$BPORT \
    timeout 5 bash "$SUP" > "$WORK/badsup.log" 2>&1
assert_no_file "principals_dir OUTSIDE \$HOME/.claude ⇒ stub sshd NEVER invoked" "$WORK/sshd-argv"
assert_contains "…supervisor logs a loud credential-storage refusal" \
    "$(cat "$WORK/badsup.log" 2>/dev/null)" "refusing to launch sshd: unsafe credential storage"
MONITOR_REMOTE_PRINCIPALS_DIR="$BADDIR" MONITOR_REMOTE_PORT=$BPORT bash "$HEALTH" >/dev/null 2>&1
assert_rc "…and nothing is listening on that port" "$?" "1"

echo "== 5a1b. LOOSE MODES at a VALID location ⇒ harden repairs, then sshd launches =="
# The complement of 5a1. A wrong LOCATION is refused outright and never
# auto-"fixed"; loose MODES at a correct location are repaired by
# _remote_principals_harden (it only ever restricts, and only files we own) and
# the service then launches. Without this case the guard could pass 5a1 by
# refusing everything — including a healthy dir — and would get switched off.
# The refusal side of the mode axis is unit-tested exhaustively in
# test-remote-principals-guard.sh (0755/0750/enroll-0755/secret-0640/go-w).
chmod 755 "$PRINCIPALS"; chmod 640 "$PRINCIPALS/ssh_host_ed25519_key"
rm -f "$WORK/sshd-argv"
HPORT=$(th_alloc_port 26000) || th_abort "no bindable fixture port in the 26000 window"
MONITOR_REMOTE_PORT=$HPORT bash "$SUP" >/dev/null 2>&1 &
HSUP=$!
stub_bound "$HPORT"; hl=$?
assert_rc "harden repairs the modes it owns ⇒ service launches" "$hl" "0"
assert_eq "…principals_dir back to 0700" "$(stat -c '%a' "$PRINCIPALS" 2>/dev/null)" "700"
assert_eq "…host key back to 0600"       "$(stat -c '%a' "$PRINCIPALS/ssh_host_ed25519_key" 2>/dev/null)" "600"
th_kill_own_child "$HSUP" TERM; wait "$HSUP" 2>/dev/null; HSUP=""

echo "== 5a2. self_enroll=false ⇒ AuthorizedKeysCommand pinned to none (manual only) =="
rm -f "$WORK/sshd-argv"; rm -f "$PRINCIPALS/authorized_keys"
OPORT=$(th_alloc_port 24000) || th_abort "no bindable fixture port in the 24000 window"
MONITOR_REMOTE_SELF_ENROLL=false MONITOR_REMOTE_PORT=$OPORT bash "$SUP" >/dev/null 2>&1 &
OSUP=$!
stub_bound "$OPORT" || true      # argv is the assertion target; bind is the wait
oargv=$(cat "$WORK/sshd-argv" 2>/dev/null || echo "")
assert_contains "self_enroll=false ⇒ AuthorizedKeysCommand=none" "$oargv" "AuthorizedKeysCommand=none"
assert_not_contains "self_enroll=false ⇒ no AKC script wired"     "$oargv" "remote-authorized-keys-command.sh"
th_kill_own_child "$OSUP" TERM; wait "$OSUP" 2>/dev/null; OSUP=""

echo "== 5b. health is IDENTITY-aware: a listener that is NOT sshd is NOT healthy =="
# your-org/nexus-code#568 A7. This case could not fail for the right reason and
# so proved nothing. Three defects, all fixed here:
#   1. NPORT was `25000 + ($$ % 4000)` — BYTE-IDENTICAL to BPORT at case 5a1,
#      so the two cases fought over one port.
#   2. An unconditional `sleep 0.5` stood in for the readiness poll used at
#      5a1b / 5a2 / 5e, so the fixture was routinely probed before it listened.
#   3. It asserted ONLY `rc == 1`, which remote-ssh-health.sh returns for ALL
#      THREE failure classes (foreign banner :125, no banner :126, no listener
#      :135) — and it discarded stderr, the one channel that distinguishes
#      them. Between (1)/(2) and (3) it almost certainly passed via the
#      NO-LISTENER path, degenerating into a duplicate of case 5h. The security
#      property in its title — "a listener that isn't sshd is not healthy" —
#      was unproven.
# The fixture is now a listener that ACCEPTS and immediately CLOSES without a
# banner: a distinct class from 5f's hang-open silence, on its own port, waited
# for, and asserted on the classification string. Sibling case 5f at :275-277
# is the shape this follows.
NPORT=$(th_alloc_port 27000) || th_abort "no bindable fixture port in the 27000 window"
python3 -c "
import socket,signal,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$NPORT)); s.listen(5)
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
deadline=time.time()+30
while time.time() < deadline:
    try:
        c,_=s.accept(); c.close()      # accept, then EOF with no banner
    except Exception:
        break" &
NPID=$!
# Readiness poll, not a fixed sleep: probing before the socket is listening is
# exactly how this case degenerated into the no-listener path.
nready=1
for _ in $(seq 1 50); do
    if python3 -c "
import socket,sys
try:
    c=socket.create_connection(('127.0.0.1',$NPORT),0.2); c.close()
except Exception: sys.exit(1)" 2>/dev/null; then nready=0; break; fi
    sleep 0.1
done
assert_rc "…fixture listener is actually up before probing" "$nready" "0"
# timeout pinned to 1s: a bannerless listener pays the FULL banner budget per
# attempt (3 attempts + backoff) — the default 10s would burn ~35s here.
nerr=$(MONITOR_REMOTE_HEALTH_TIMEOUT=1 MONITOR_REMOTE_PORT=$NPORT bash "$HEALTH" 2>&1 >/dev/null); nrc=$?
assert_rc "non-sshd listener (accept-then-close) → unhealthy" "$nrc" "1"
# The load-bearing half: it must be unhealthy for the LISTENER-IDENTITY reason,
# never because nothing was listening. Without this the case cannot fail for
# the right reason.
assert_not_contains "…unhealthy for the identity reason, NOT 'no listener'" "$nerr" "no listener on"
assert_contains     "…classified as a banner failure against a live listener" "$nerr" "no SSH banner within"
th_kill_own_child "$NPID" KILL 2>/dev/null; wait "$NPID" 2>/dev/null

echo "== 5e. SLOW banner (#434): a 4s banner is ACCEPTED by stage 1, never 'NOT sshd' =="
# #434's contract is a CLASSIFICATION contract: a listener whose SSH banner is
# delayed past the OLD 3s budget (a CPU-starved sshd/prober on a loaded host)
# must not be misreported as a foreign non-SSH listener. That contract is intact
# and still asserted below.
#
# The VERDICT this case asserted was flipped by your-org/nexus-code#609, and the
# old form was encoding the defect: this fixture is a bare Python socket that
# sleeps 4s and writes `SSH-2.0-slowsshd` — it has no host key and implements no
# key exchange, so "→ HEALTHY" asserted that a non-sshd satisfies the check. It
# now reports UNHEALTHY on IDENTITY, having passed the banner stage. Both halves
# matter: the stage-1 classification must still be right (no "NOT sshd"), and
# the overall verdict must be honest (not ours ⇒ down).
SLPORT=$(th_alloc_port 28000) || th_abort "no bindable fixture port in the 28000 window"
python3 -c "
import socket,signal,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$SLPORT)); s.listen(5)
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
while True:
    try:
        c,_=s.accept()
        time.sleep(4)                      # banner delayed past the OLD 3s budget
        c.sendall(b'SSH-2.0-slowsshd\r\n')
        c.close()
    except Exception:
        pass
" &
SLPID=$!
sleep 0.5
slerr=$(MONITOR_REMOTE_PORT=$SLPORT bash "$HEALTH" 2>&1); slrc=$?
assert_rc "slow-banner (4s) listener → UNHEALTHY (no host key: not ours)" "$slrc" "1"
assert_not_contains "slow banner never misreported as NOT sshd" "$slerr" "NOT sshd"
assert_not_contains "…nor as a banner timeout (stage 1 accepted it)" "$slerr" "no SSH banner within"
assert_contains "…it fails on IDENTITY, the honest reason" "$slerr" "NO usable ed25519 host key"
th_kill_own_child "$SLPID" KILL 2>/dev/null; wait "$SLPID" 2>/dev/null

echo "== 5f. SILENT listener: still unhealthy, but classified as no-banner, not 'NOT sshd' =="
# rc-space refinement (#434): connected-but-silent is INDETERMINATE — it must
# still fail (identity unconfirmed) but with an accurate message, distinct
# from the definite foreign-banner claim. Fails pre-fix (old classify said
# "NOT sshd" for an empty read).
SIPORT=$(th_alloc_port 29000) || th_abort "no bindable fixture port in the 29000 window"
python3 -c "
import socket,signal,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$SIPORT)); s.listen(5)
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
while True:
    try:
        c,_=s.accept()          # accept and say NOTHING
        time.sleep(30)
    except Exception:
        pass
" &
SIPID=$!
sleep 0.5
sierr=$(MONITOR_REMOTE_HEALTH_TIMEOUT=1 MONITOR_REMOTE_PORT=$SIPORT bash "$HEALTH" 2>&1); sirc=$?
assert_rc "silent listener → unhealthy" "$sirc" "1"
assert_contains     "silent listener → no-banner classification" "$sierr" "no SSH banner within"
assert_not_contains "silent listener NOT claimed as foreign"      "$sierr" "NOT sshd"
th_kill_own_child "$SIPID" KILL 2>/dev/null; wait "$SIPID" 2>/dev/null

echo "== 5g. FOREIGN banner: definite 'NOT sshd' detection intact (no blunting) =="
FBPORT=$(th_alloc_port 30000) || th_abort "no bindable fixture port in the 30000 window"
python3 -c "
import socket,signal,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$FBPORT)); s.listen(5)
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
while True:
    try:
        c,_=s.accept()
        c.sendall(b'HTTP/1.0 200 OK\r\n')   # a squatter speaking NOT-ssh
        c.close()
    except Exception:
        pass
" &
FBPID=$!
sleep 0.5
fberr=$(MONITOR_REMOTE_PORT=$FBPORT bash "$HEALTH" 2>&1); fbrc=$?
assert_rc "foreign-banner listener → unhealthy" "$fbrc" "1"
assert_contains "foreign banner → NOT sshd classification" "$fberr" "NOT sshd"
th_kill_own_child "$FBPID" KILL 2>/dev/null; wait "$FBPID" 2>/dev/null

echo "== 5h. connect-refused fails FAST (no banner-budget burn on a dead port) =="
# The raised banner budget must NOT slow real-outage detection: a refused
# connect never enters a banner read, so even with the 10s default the check
# reports in ~1s (one retry sleep). Bound generous for loaded test hosts.
DEADPORT=$(th_alloc_port 31000) || th_abort "no bindable fixture port in the 31000 window"
t0=$SECONDS
MONITOR_REMOTE_PORT=$DEADPORT bash "$HEALTH" >/dev/null 2>&1; deadrc=$?
dead_elapsed=$(( SECONDS - t0 ))
assert_rc "no listener → unhealthy" "$deadrc" "1"
if (( dead_elapsed <= 8 )); then printf '  PASS: connect-refused reports fast (%ss)\n' "$dead_elapsed"; PASS=$((PASS+1))
else printf '  FAIL: connect-refused took %ss (want <=8; banner budget leaked into the refused path?)\n' "$dead_elapsed" >&2; FAIL=$((FAIL+1)); fi

echo "== 5i. monitor.remote.health_timeout is CONFIG-driven (not env-only) =="
# Plumbing test: the timeout must be readable from the config file via the
# same load path as every other monitor.remote.* knob (issue #434 — the
# watcher-invoked healthcheck has no clean way to set a per-operator env).
cat > "$WORK/fixture-timeout.yml" <<'YAML'
monitor:
  remote:
    health_timeout: 1
YAML
python3 -c "
import socket,signal,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$SIPORT)); s.listen(5)
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
while True:
    try:
        c,_=s.accept()
        time.sleep(30)
    except Exception:
        pass
" &
CFPID=$!
sleep 0.5
cferr=$(NEXUS_CONFIG="$WORK/fixture-timeout.yml" MONITOR_REMOTE_PORT=$SIPORT bash "$HEALTH" 2>&1); cfrc=$?
assert_rc "config-driven run → unhealthy (silent listener)" "$cfrc" "1"
assert_contains "config health_timeout=1 honored in the probe" "$cferr" "no SSH banner within 1s"
th_kill_own_child "$CFPID" KILL 2>/dev/null; wait "$CFPID" 2>/dev/null

echo "== 5c. channel-only: supervisor REFUSES a command=-less authorized_keys (HIGH) =="
printf 'ssh-ed25519 AAAAC3NzaShellKeyNoCommand danger@host\n' > "$PRINCIPALS/authorized_keys"
BPORT=$(th_alloc_port 26000) || th_abort "no bindable fixture port in the 26000 window"
MONITOR_REMOTE_PORT=$BPORT bash "$SUP" >/dev/null 2>&1 &
BSUP=$!
# DIRECT evidence, deliberately not the health check. Post-#609 the health check
# rejects the stub on identity grounds regardless of whether it bound, so a
# health-based assertion here would pass even if this HIGH gate were removed —
# it could no longer fail for the right reason. Assert the stub was never
# launched for this port and nothing is accepting on it.
stub_bound "$BPORT" 12; bad_listen=$?
assert_rc "channel-only + command=-less key → stub never bound" "$bad_listen" "1"
assert_not_contains "…and sshd was never invoked for that port" \
    "$(cat "$WORK/sshd-argv" 2>/dev/null || echo "")" "-p $BPORT"
th_kill_own_child "$BSUP" KILL 2>/dev/null; wait "$BSUP" 2>/dev/null

echo "== 5d. unfiltered: SAME command=-less key DOES launch + PermitTTY=yes =="
# Under the trust policy a command=-less key is intended (shell mode), so the
# supervisor launches; PermitTTY flips to yes for an interactive shell.
UPORT=$(th_alloc_port 27000) || th_abort "no bindable fixture port in the 27000 window"
rm -f "$WORK/sshd-argv"
MONITOR_REMOTE_COMMAND_POLICY=unfiltered MONITOR_REMOTE_PORT=$UPORT bash "$SUP" >/dev/null 2>&1 &
USUP=$!
stub_bound "$UPORT"; u_listen=$?
assert_rc "unfiltered + command=-less key → DOES listen" "$u_listen" "0"
uargv=$(cat "$WORK/sshd-argv" 2>/dev/null || echo "")
assert_contains "unfiltered ⇒ PermitTTY=yes" "$uargv" "PermitTTY=yes"
th_kill_own_child "$USUP" TERM; wait "$USUP" 2>/dev/null
rm -f "$PRINCIPALS/authorized_keys"

echo "== 6. remote-up: enable is ONE command (no flag) → row + host key + healthy =="
deregister_row   # clean slate; remote-up writes the row itself (= enabling)
out=$(REMOTE_UP_TIMEOUT=12 bash "$UP" 2>&1)
assert_file_exists "registry written" "$WORK/services.registry"
row=$(cat "$WORK/services.registry")
assert_contains "row name nexus-remote-ssh" "$row" "nexus-remote-ssh"
assert_contains "row policy emit-only"      "$row" "emit-only"
assert_contains "row launch = supervisor"   "$row" "remote-sshd-supervised.sh"
assert_file_exists "host key generated" "$PRINCIPALS/ssh_host_ed25519_key"
# idempotent: re-run leaves exactly one row
REMOTE_UP_TIMEOUT=12 bash "$UP" >/dev/null 2>&1
assert_eq "registry row idempotent (one row)" "$(grep -c 'nexus-remote-ssh' "$WORK/services.registry")" "1"
# --status against the banner-only stub: `endpoint:` reports the identity verdict
# as its OWN field and the exit code follows health. Pre-#609 this asserted
# `healthy` — with the stub answering, which is exactly the pairing (`healthy`
# read as `ours`) that misdirected an operator into a destructive reconcile.
# A genuinely-ours end-to-end healthy path is covered against a REAL sshd in
# test-remote-identity-health.sh; a stub cannot honestly produce it.
statout=$(bash "$UP" --status 2>&1); statrc=$?
assert_rc "remote-up --status is NOT healthy against a foreign endpoint" "$statrc" "1"
assert_contains "--status reports the identity verdict explicitly" "$statout" "endpoint:foreign"

echo "== 7. remote-up --down: the single off switch removes the row =="
bash "$UP" --down >/dev/null 2>&1
assert_rc "remote-up --down rc0" "$?" "0"
downrows=$(grep -c 'nexus-remote-ssh' "$WORK/services.registry" 2>/dev/null); downrows=${downrows:-0}
assert_eq "row removed after --down (service now off)" "$downrows" "0"
# and once deregistered, health is healthy-because-off again
bash "$HEALTH" >/dev/null 2>&1
assert_rc "deregistered → health healthy (off)" "$?" "0"

th_summary_and_exit
