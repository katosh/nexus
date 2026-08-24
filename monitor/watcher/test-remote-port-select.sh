#!/usr/bin/env bash
# Tests for SETUP-TIME open-port selection + recording (your-org/nexus-code#637):
#   monitor/_remote_lib.sh   (_remote_port precedence, recorded-port file,
#                             _remote_find_free_port)
#   monitor/remote-up.sh     (select_and_record_port: prefer-recorded stickiness,
#                             the four identity-verdict branches, move-when-
#                             DEFINITELY-not-ours, DON'T-move-on-INDETERMINATE,
#                             the PORT-CHANGED durable alert, the setup message)
#
# Hermetic, mirroring test-remote-service.sh: sshd is a REMOTE_SSHD_BIN stub that
# binds a real TCP socket; registry + state + principals_dir are fixture-local;
# HOME is relocated so principals_dir resolves under $HOME/.claude. Supervisors
# are killed by recorded pidfile, never by pattern.
#
# EVERY assertion runs in the TOP-LEVEL shell. Values that need an isolated env
# (a fresh `source`, a scripted identity verdict) are computed in a SUBPROCESS
# and the assertion is made in the parent on the emitted value — never
# `( … assert … )`, whose FAIL increments a subshell copy of $FAIL that is lost
# on exit, so a real failure would print yet the suite would still exit 0
# (the #637 skeptic finding: 11/28 assertions could not fail the suite).
#
# The port is NOT pinned via MONITOR_REMOTE_PORT (that env is a deliberate
# override select_and_record_port honours verbatim, which is why every OTHER
# remote test is unaffected). Selection is driven through a NEXUS_CONFIG fixture.
#
# Run: bash monitor/watcher/test-remote-port-select.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
MON_DIR=$(cd "$_test_dir/.." && pwd)
LIB="$MON_DIR/_remote_lib.sh"
UP="$MON_DIR/remote-up.sh"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not present"; echo "ALL TESTS PASSED"; exit 0; }

WORK=$(mktemp -d -t nexus-remote-portsel-XXXXXX)
SQUATTERS=()
cleanup() {
    local pf pid
    for pf in "$WORK"/state/services/*.pid; do
        [[ -f "$pf" ]] || continue
        read -r pid < "$pf" 2>/dev/null || continue
        [[ "$pid" =~ ^[0-9]+$ ]] && { kill -KILL -- "-$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null; }
    done
    for pid in "${SQUATTERS[@]}"; do kill -KILL "$pid" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT

export NEXUS_STATE_DIR="$WORK/state"
export NEXUS_SERVICES_REGISTRY="$WORK/services.registry"
export NEXUS_ROOT="$WORK/nexusroot"
export HOME="$WORK/home"
export MONITOR_REMOTE_PRINCIPALS_DIR="$HOME/.claude/principals"
PRINCIPALS="$MONITOR_REMOTE_PRINCIPALS_DIR"
export MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1
mkdir -p "$WORK/state" "$WORK/nexusroot/monitor/.state" "$HOME/.claude" "$PRINCIPALS"
chmod 700 "$HOME/.claude" "$PRINCIPALS"
unset MONITOR_REMOTE_PORT 2>/dev/null || true
unset NEXUS_CONFIG 2>/dev/null || true

PORTFILE="$PRINCIPALS/port"
HISTFILE="$PRINCIPALS/port-history.log"

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

# Bind a listener that HOLDS a port until KILLed. `disown` so its later KILL does
# not print a job-control "Killed" line into the test output.
squat_port() {
    local port="$1"
    python3 -c "
import socket,signal,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$port)); s.listen(5)
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
signal.signal(signal.SIGINT,  lambda *a: sys.exit(0))
while True:
    try: c,_=s.accept(); c.close()
    except Exception: time.sleep(0.05)
" &
    local pid=$!
    disown "$pid" 2>/dev/null || true
    SQUATTERS+=("$pid")
    local i
    for (( i=0; i<50; i++ )); do
        ( exec 3<>"/dev/tcp/127.0.0.1/$port" ) 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}

write_cfg() { cat > "$WORK/cfg.yml" <<YAML
monitor:
  remote:
    bind_address: 127.0.0.1
    port: $1
YAML
}

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
        c,_=s.accept(); c.sendall(b'SSH-2.0-stubsshd\r\n'); c.close()
    except Exception: pass
"
EOF
chmod +x "$STUB/sshd"
export REMOTE_SSHD_BIN="$STUB/sshd"

register_row() { printf 'nexus-remote-ssh\t%s\t%s\t%s\t%s\temit-only\n' \
    "$NEXUS_ROOT" "$MON_DIR/remote-sshd-supervised.sh" "$MON_DIR/remote-ssh-health.sh" "$WORK/svc.log" > "$NEXUS_SERVICES_REGISTRY"; }
kill_supervisors() {
    local pf pid
    for pf in "$WORK"/state/services/*.pid; do
        [[ -f "$pf" ]] || continue
        read -r pid < "$pf" 2>/dev/null || continue
        [[ "$pid" =~ ^[0-9]+$ ]] && { kill -TERM -- "-$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null; }
        rm -f "$pf"
    done
}

# ===========================================================================
echo "== UNIT 1. _remote_port precedence: env > recorded > config-default =="
printf '39111\n' > "$PORTFILE"
got=$(unset NEXUS_CONFIG; MONITOR_REMOTE_PORT=51999 bash -c "source '$LIB'; _remote_port")
assert_eq "env MONITOR_REMOTE_PORT overrides recorded" "$got" "51999"
got=$(unset NEXUS_CONFIG MONITOR_REMOTE_PORT; bash -c "source '$LIB'; _remote_port")
assert_eq "recorded port wins over config default" "$got" "39111"
rm -f "$PORTFILE"
got=$(unset NEXUS_CONFIG MONITOR_REMOTE_PORT; bash -c "source '$LIB'; _remote_port")
exp=$(unset NEXUS_CONFIG MONITOR_REMOTE_PORT; bash -c "source '$LIB'; _remote_derived_port")
assert_eq "no recorded ⇒ config/default (the per-operator DERIVED port, #893)" "$got" "$exp"

# ===========================================================================
echo "== UNIT 1b. per-operator port DERIVATION (your-org/nexus-code#893) =="
# The defect being fixed: the built-in default was the CONSTANT 22022 in every
# operator's clone, on a HOST-GLOBAL bind. These assertions pin the three
# properties that stop that recurring — distinctness, determinism, and a band
# clear of the ephemeral range.
derive() { unset NEXUS_CONFIG MONITOR_REMOTE_PORT; MONITOR_REMOTE_OPERATOR_IDENTITY="$1" bash -c "source '$LIB'; _remote_derived_port"; }

# NOT the old constant — the whole point.
got=$(derive operator)
assert_not_contains "the derived default is NOT the shared constant 22022" "$got" "22022"

# DISTINCT between operators. The negative control matters more than the
# positive one here: a derivation that ignored its input would still be
# "deterministic" and would still collide for everyone.
a=$(derive alice); b=$(derive bob)
assert_eq "distinct operators derive distinct ports (alice vs bob)" \
    "$([[ "$a" != "$b" ]] && echo differ || echo "SAME:$a")" "differ"

# DETERMINISTIC — the reason this is a derivation and not a free-port scan: a
# client is pinned to host:port out of band, so the port must survive a restart.
assert_eq "same operator derives the same port twice (stable across restarts)" "$(derive alice)" "$a"

# IN BAND, and the band is clear of /proc/sys/net/ipv4/ip_local_port_range
# (32768-60999 on this host) — reaching into the ephemeral range is #769's
# false-free mechanism — and clear of 22022/22080, both held on this node.
inband=yes
for who in alice bob carol dave erin frank grace heidi ivan judy; do
    p=$(derive "$who")
    [[ "$p" =~ ^[0-9]+$ ]] || { inband="non-numeric:$who:$p"; break; }
    (( p >= 22100 && p < 23000 )) || { inband="out-of-band:$who:$p"; break; }
    (( p == 22022 || p == 22080 )) && { inband="hit-known-occupied:$who:$p"; break; }
done
assert_eq "10 identities all land in [22100,23000) and miss 22022/22080" "$inband" "yes"

# An explicit pin still wins — derivation changes only the DEFAULT, so no
# already-enabled endpoint churns.
got=$(unset NEXUS_CONFIG; MONITOR_REMOTE_PORT=51999 MONITOR_REMOTE_OPERATOR_IDENTITY=alice bash -c "source '$LIB'; _remote_configured_port")
assert_eq "an explicit MONITOR_REMOTE_PORT still outranks the derived default" "$got" "51999"

# A clone with NO identity at all still derives a REAL port rather than failing
# arithmetic or emitting an empty string that a caller would bind as ':'.
got=$(unset NEXUS_CONFIG MONITOR_REMOTE_PORT USER; MONITOR_REMOTE_OPERATOR_IDENTITY="" bash -c "source '$LIB'; _remote_derived_port")
assert_eq "no identity ⇒ still a numeric in-band port (never empty)" \
    "$([[ "$got" =~ ^[0-9]+$ ]] && (( got >= 22100 && got < 23000 )) && echo ok || echo "BAD:$got")" "ok"

echo "== UNIT 2. record/recorded roundtrip + validation (asserts in parent) =="
rm -f "$PORTFILE"
res=$(bash -c "source '$LIB'; _remote_record_port 40123 && echo RC=0 || echo RC=1; printf 'VAL=%s\n' \"\$(_remote_recorded_port)\"; printf 'MODE=%s\n' \"\$(stat -c '%a' '$PORTFILE' 2>/dev/null)\"")
assert_contains "record_port succeeds (rc0)" "$res" "RC=0"
assert_contains "recorded reads back 40123"  "$res" "VAL=40123"
assert_contains "recorded-port file is 0644 (non-secret)" "$res" "MODE=644"
res=$(bash -c "source '$LIB'; _remote_record_port 99999 && echo RC=0 || echo RC=1; printf 'VAL=%s\n' \"\$(_remote_recorded_port)\"")
assert_contains "record_port rejects out-of-range (rc1)" "$res" "RC=1"
assert_contains "…and leaves the prior value intact"     "$res" "VAL=40123"
printf 'garbage\n' > "$PORTFILE"
got=$(bash -c "source '$LIB'; _remote_recorded_port")
assert_eq "a corrupt recorded-port file reads as empty (not a crash)" "$got" ""
rm -f "$PORTFILE"

echo "== UNIT 3. _remote_find_free_port skips an occupied port =="
base=$(free_port)
squat_port "$base" || printf '  (squat failed — case still meaningful)\n'
chosen=$(bash -c "source '$LIB'; _remote_find_free_port 127.0.0.1 $base 20 _remote_port_is_held")
if [[ -n "$chosen" && "$chosen" != "$base" ]] && (( chosen > base && chosen <= base+20 )); then
    printf '  PASS: free port %s skips occupied %s (within band)\n' "$chosen" "$base"; PASS=$((PASS+1))
else
    printf '  FAIL: find_free_port returned %q for occupied base %s\n' "$chosen" "$base" >&2; FAIL=$((FAIL+1))
fi

echo "== UNIT 4. select branches on the identity VERDICT (rc0/1/2/3), incl. ours-live =="
# The branch decision, isolated from crypto: source remote-up.sh in a SUBPROCESS,
# stub _remote_identity_probe to a scripted rc, and read back the outcome. Covers
# the ours-live KEEP branch (rc 0 — the state a normal restart takes, untested in
# both the skeptic pass and the prior suite) and the INDETERMINATE branch (rc 2 —
# must NOT move: "I could not tell" is not "somebody else owns it").
run_branch() {
    STUB_IDRC="$1" PREF="$2" MOVED="$(( $2 + 7 ))" bash -c '
        set -uo pipefail
        unset MONITOR_REMOTE_PORT NEXUS_CONFIG
        source "'"$UP"'" >/dev/null 2>&1
        port_is_held()            { return 0; }                # preferred is HELD
        _remote_identity_probe()  { _REMOTE_ID_REASON="stub idrc=$STUB_IDRC"; return "$STUB_IDRC"; }
        _remote_find_free_port()  { printf "%s" "$MOVED"; }     # deterministic move target
        _remote_attribute_listener() { printf "stub-attr"; }
        _remote_recorded_port()   { printf "%s" "$PREF"; }     # preferred = PREF
        _remote_record_port()     { :; }                       # no fixture writes
        _remote_record_port_change() { :; }
        PORT_CHANGED=0; CHOSEN_PORT=""
        select_and_record_port >/dev/null 2>&1
        printf "CHOSEN=%s CHANGED=%s" "$CHOSEN_PORT" "$PORT_CHANGED"
    '
}
P=45000
assert_eq "rc0 OURS-live: keep the port, NO churn"        "$(run_branch 0 $P)" "CHOSEN=$P CHANGED=0"
assert_eq "rc1 FOREIGN: move + change"                    "$(run_branch 1 $P)" "CHOSEN=$((P+7)) CHANGED=1"
assert_eq "rc2 INDETERMINATE: do NOT move (defer, no churn)" "$(run_branch 2 $P)" "CHOSEN=$P CHANGED=0"
assert_eq "rc3 NO-LOCAL-KEY: move + change"               "$(run_branch 3 $P)" "CHOSEN=$((P+7)) CHANGED=1"

# ===========================================================================
echo "== INT 1. fresh setup, preferred port FREE ⇒ chosen==preferred, recorded, NO change =="
rm -f "$PORTFILE" "$HISTFILE" "$WORK/sshd-argv"
register_row
PREF1=$(free_port); write_cfg "$PREF1"
out=$(NEXUS_CONFIG="$WORK/cfg.yml" REMOTE_UP_TIMEOUT=3 bash "$UP" 2>&1)
assert_file_exists "recorded-port file written" "$PORTFILE"
assert_eq       "recorded port == the free preferred port" "$(cat "$PORTFILE")" "$PREF1"
assert_no_file  "no port-history row on a no-move setup (negative control)" "$HISTFILE"
assert_contains "stderr says the preferred port was free" "$out" "is free — using it"
assert_not_contains "no PORT CHANGED alert when nothing moved (negative control)" "$out" "PORT CHANGED"
assert_contains "setup message carries the chosen port" "$out" "Port:            $PREF1"
kill_supervisors

echo "== INT 2. recorded port is STICKY: a prior recorded value beats config, no churn =="
kill_supervisors
PREF2=$(free_port)
printf '%s\n' "$PREF2" > "$PORTFILE"
rm -f "$HISTFILE" "$WORK/sshd-argv"
CFGPORT=$(free_port); write_cfg "$CFGPORT"
register_row
out=$(NEXUS_CONFIG="$WORK/cfg.yml" REMOTE_UP_TIMEOUT=3 bash "$UP" 2>&1)
assert_eq       "recorded port kept (sticky over config)" "$(cat "$PORTFILE")" "$PREF2"
assert_not_contains "recorded (not config) is used: config port not chosen" "$(cat "$PORTFILE")" "$CFGPORT"
assert_no_file  "no history row when the recorded port is honoured (negative control)" "$HISTFILE"
assert_not_contains "no PORT CHANGED on a sticky re-run" "$out" "PORT CHANGED"
kill_supervisors

echo "== INT 3. preferred port OCCUPIED by a NON-ours listener ⇒ MOVE + durable alert =="
kill_supervisors
rm -f "$PORTFILE" "$HISTFILE" "$WORK/sshd-argv"
OCC=$(free_port); squat_port "$OCC" || printf '  (could not occupy port — case may be weakened)\n'
write_cfg "$OCC"
register_row
out=$(NEXUS_CONFIG="$WORK/cfg.yml" REMOTE_UP_TIMEOUT=3 bash "$UP" 2>&1)
newport=$(cat "$PORTFILE" 2>/dev/null || echo "")
if [[ -n "$newport" && "$newport" != "$OCC" ]] && (( newport > OCC && newport <= OCC+100 )); then
    printf '  PASS: moved off occupied %s to free %s (within band)\n' "$OCC" "$newport"; PASS=$((PASS+1))
else
    printf '  FAIL: expected a move off occupied %s; recorded=%q\n' "$OCC" "$newport" >&2; FAIL=$((FAIL+1))
fi
assert_contains "stderr announces the move for the OCCUPANCY reason" "$out" "moving to the next free port"
assert_contains "PORT CHANGED alert fired" "$out" "PORT CHANGED"
assert_file_exists "durable port-history.log written (alert survives the session)" "$HISTFILE"
hist=$(cat "$HISTFILE" 2>/dev/null || echo "")
assert_contains "history row names the OLD (occupied) port" "$hist" "old=$OCC"
assert_contains "history row names the NEW (chosen) port"  "$hist" "new=$newport"
assert_contains "setup message carries the NEW port" "$out" "Port:            $newport"
kill_supervisors

th_summary_and_exit
