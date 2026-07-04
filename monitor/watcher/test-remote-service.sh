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
export MONITOR_REMOTE_PRINCIPALS_DIR="$WORK/principals"
mkdir -p "$WORK/state" "$WORK/nexusroot/monitor/.state"

# pick a high, likely-free port; spread by PID to reduce parallel collisions
PORT=$(( 21000 + ($$ % 4000) ))
export MONITOR_REMOTE_PORT="$PORT"
export MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1

# stub sshd: record argv, bind 127.0.0.1:<-p PORT>, emit a real SSH banner
# on each connection (so the identity-aware health probe passes), hold until
# TERM. The banner is what distinguishes "an sshd is answering" from "some
# process squats the port" — the health check requires it.
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
mkdir -p "$WORK/principals"; chmod 700 "$WORK/principals"
ssh-keygen -t ed25519 -f "$WORK/principals/ssh_host_ed25519_key" -N '' >/dev/null 2>&1 \
    || { : > "$WORK/principals/ssh_host_ed25519_key"; }
rm -f "$WORK/sshd-argv"
bash "$SUP" >/dev/null 2>&1 &
SUP_PID=$!
listening=1
for _ in $(seq 1 30); do
    if bash "$HEALTH" >/dev/null 2>&1; then listening=0; break; fi
    sleep 0.2
done
assert_rc "registered service becomes healthy (listener up)" "$listening" "0"
argv=$(cat "$WORK/sshd-argv" 2>/dev/null || echo "")
assert_contains "argv: no system config (-f /dev/null)" "$argv" "-f /dev/null"
assert_contains "argv: PasswordAuthentication=no"        "$argv" "PasswordAuthentication=no"
assert_contains "argv: PermitRootLogin=no"               "$argv" "PermitRootLogin=no"
assert_contains "argv: AllowTcpForwarding=no"            "$argv" "AllowTcpForwarding=no"
assert_contains "argv: pubkey auth on"                   "$argv" "PubkeyAuthentication=yes"
assert_contains "argv: binds configured port"            "$argv" "-p $PORT"
assert_contains "argv: AuthorizedKeysFile in principals" "$argv" "principals/authorized_keys"
assert_contains "argv: channel-only ⇒ PermitTTY=no"      "$argv" "PermitTTY=no"
assert_contains "argv: pre-auth Banner configured"       "$argv" "Banner=$WORK/principals/banner.txt"
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
assert_file_exists "pre-auth banner written" "$WORK/principals/banner.txt"
banner=$(cat "$WORK/principals/banner.txt" 2>/dev/null)
assert_contains "banner states the command policy" "$banner" "command policy: channel-only"
assert_contains "banner points to the client's own operator (no nexus intake)" "$banner" "YOUR OWN operator"
th_kill_own_child "$SUP_PID" TERM
wait "$SUP_PID" 2>/dev/null; suprc=$?
SUP_PID=""
assert_rc "supervisor TERM → exit 0" "$suprc" "0"

echo "== 5a2. self_enroll=false ⇒ AuthorizedKeysCommand pinned to none (manual only) =="
rm -f "$WORK/sshd-argv"; rm -f "$WORK/principals/authorized_keys"
OPORT=$(( 24000 + ($$ % 4000) ))
MONITOR_REMOTE_SELF_ENROLL=false MONITOR_REMOTE_PORT=$OPORT bash "$SUP" >/dev/null 2>&1 &
OSUP=$!
ol=1; for _ in $(seq 1 30); do MONITOR_REMOTE_PORT=$OPORT bash "$HEALTH" >/dev/null 2>&1 && { ol=0; break; }; sleep 0.2; done
oargv=$(cat "$WORK/sshd-argv" 2>/dev/null || echo "")
assert_contains "self_enroll=false ⇒ AuthorizedKeysCommand=none" "$oargv" "AuthorizedKeysCommand=none"
assert_not_contains "self_enroll=false ⇒ no AKC script wired"     "$oargv" "remote-authorized-keys-command.sh"
th_kill_own_child "$OSUP" TERM; wait "$OSUP" 2>/dev/null; OSUP=""

echo "== 5b. health is IDENTITY-aware: a non-sshd listener is NOT healthy =="
NPORT=$(( 25000 + ($$ % 4000) ))
python3 -c "
import socket,signal,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$NPORT)); s.listen(1)
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
import time; time.sleep(30)" &
NPID=$!
sleep 0.5
# timeout pinned to 1s: the silent listener pays the FULL banner budget per
# attempt (3 attempts + backoff) — the default 10s would burn ~35s here.
MONITOR_REMOTE_HEALTH_TIMEOUT=1 MONITOR_REMOTE_PORT=$NPORT bash "$HEALTH" >/dev/null 2>&1
assert_rc "non-sshd listener (no banner) → unhealthy" "$?" "1"
th_kill_own_child "$NPID" KILL 2>/dev/null; wait "$NPID" 2>/dev/null

echo "== 5e. SLOW banner (#434): sshd that banners after 4s is HEALTHY, not 'NOT sshd' =="
# The false-flap contract: a listener whose SSH banner is delayed past the OLD
# 3s budget (CPU-starved sshd/prober on a loaded host) must be classified
# healthy under the raised default. Fails on the pre-#434 classify (3s → rc 1
# "NOT sshd"); passes post-fix (banner lands inside the 10s default).
SLPORT=$(( 28000 + ($$ % 4000) ))
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
assert_rc "slow-banner (4s) listener → HEALTHY" "$slrc" "0"
assert_not_contains "slow banner never misreported as NOT sshd" "$slerr" "NOT sshd"
th_kill_own_child "$SLPID" KILL 2>/dev/null; wait "$SLPID" 2>/dev/null

echo "== 5f. SILENT listener: still unhealthy, but classified as no-banner, not 'NOT sshd' =="
# rc-space refinement (#434): connected-but-silent is INDETERMINATE — it must
# still fail (identity unconfirmed) but with an accurate message, distinct
# from the definite foreign-banner claim. Fails pre-fix (old classify said
# "NOT sshd" for an empty read).
SIPORT=$(( 29000 + ($$ % 4000) ))
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
FBPORT=$(( 30000 + ($$ % 4000) ))
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
DEADPORT=$(( 31000 + ($$ % 4000) ))
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
printf 'ssh-ed25519 AAAAC3NzaShellKeyNoCommand danger@host\n' > "$WORK/principals/authorized_keys"
BPORT=$(( 26000 + ($$ % 4000) ))
MONITOR_REMOTE_PORT=$BPORT bash "$SUP" >/dev/null 2>&1 &
BSUP=$!
bad_listen=1
for _ in $(seq 1 12); do
    if MONITOR_REMOTE_PORT=$BPORT bash "$HEALTH" >/dev/null 2>&1; then bad_listen=0; break; fi
    sleep 0.2
done
assert_rc "channel-only + command=-less key → no listener" "$bad_listen" "1"
th_kill_own_child "$BSUP" KILL 2>/dev/null; wait "$BSUP" 2>/dev/null

echo "== 5d. unfiltered: SAME command=-less key DOES launch + PermitTTY=yes =="
# Under the trust policy a command=-less key is intended (shell mode), so the
# supervisor launches; PermitTTY flips to yes for an interactive shell.
UPORT=$(( 27000 + ($$ % 4000) ))
rm -f "$WORK/sshd-argv"
MONITOR_REMOTE_COMMAND_POLICY=unfiltered MONITOR_REMOTE_PORT=$UPORT bash "$SUP" >/dev/null 2>&1 &
USUP=$!
u_listen=1
for _ in $(seq 1 30); do
    if MONITOR_REMOTE_PORT=$UPORT bash "$HEALTH" >/dev/null 2>&1; then u_listen=0; break; fi
    sleep 0.2
done
assert_rc "unfiltered + command=-less key → DOES listen" "$u_listen" "0"
uargv=$(cat "$WORK/sshd-argv" 2>/dev/null || echo "")
assert_contains "unfiltered ⇒ PermitTTY=yes" "$uargv" "PermitTTY=yes"
th_kill_own_child "$USUP" TERM; wait "$USUP" 2>/dev/null
rm -f "$WORK/principals/authorized_keys"

echo "== 6. remote-up: enable is ONE command (no flag) → row + host key + healthy =="
deregister_row   # clean slate; remote-up writes the row itself (= enabling)
out=$(REMOTE_UP_TIMEOUT=12 bash "$UP" 2>&1)
assert_file_exists "registry written" "$WORK/services.registry"
row=$(cat "$WORK/services.registry")
assert_contains "row name nexus-remote-ssh" "$row" "nexus-remote-ssh"
assert_contains "row policy emit-only"      "$row" "emit-only"
assert_contains "row launch = supervisor"   "$row" "remote-sshd-supervised.sh"
assert_file_exists "host key generated" "$WORK/principals/ssh_host_ed25519_key"
# idempotent: re-run leaves exactly one row
REMOTE_UP_TIMEOUT=12 bash "$UP" >/dev/null 2>&1
assert_eq "registry row idempotent (one row)" "$(grep -c 'nexus-remote-ssh' "$WORK/services.registry")" "1"
bash "$UP" --status >/dev/null 2>&1
assert_rc "remote-up --status healthy" "$?" "0"

echo "== 7. remote-up --down: the single off switch removes the row =="
bash "$UP" --down >/dev/null 2>&1
assert_rc "remote-up --down rc0" "$?" "0"
downrows=$(grep -c 'nexus-remote-ssh' "$WORK/services.registry" 2>/dev/null); downrows=${downrows:-0}
assert_eq "row removed after --down (service now off)" "$downrows" "0"
# and once deregistered, health is healthy-because-off again
bash "$HEALTH" >/dev/null 2>&1
assert_rc "deregistered → health healthy (off)" "$?" "0"

th_summary_and_exit
