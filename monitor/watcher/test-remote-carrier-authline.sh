#!/usr/bin/env bash
# Tests for `ng remote carrier-authline` (monitor/remote-enroll.sh) — the
# OFF-HOST FORWARD-ONLY CARRIER authorized_keys line. The nexus sshd binds
# loopback inside the sandbox; an off-host client reaches it only by SSHing
# into the carrier host and local-forwarding. This line locks ONE client key
# to ONLY that forward: no shell, no command, no other forward target.
#
#  Hermetic (string/option) assertions — always run:
#   1.  default form = restrict,port-forwarding,permitopen="127.0.0.1:<port>"
#       + the forced-command NO-SHELL BELT; key reconstructed from type+blob
#   2.  --port overrides the permitopen target; default comes from config
#   3.  --no-shell-belt drops the command= (literal minimal form)
#   4.  --explicit uses the no-* options instead of `restrict` (sshd < 7.2)
#   5.  pubkey OPTION-INJECTION stripped (smuggled command=/options/comment gone)
#   6.  --pubkey - reads the key from stdin
#   7.  bad --port / --comment rejected (rc1); malformed pubkey rejected (rc2)
#   8.  stdout is the SINGLE line; the usage note goes to stderr only
#
#  Live-sshd integration (CARRIER_LIVE_SSHD=1 AND a non-root sshd can bind a
#  loopback high port) — empirically proves the confinement semantics:
#   A.  restrict-only (NO belt) ALLOWS `ssh carrier <cmd>` exec — THE GAP that
#       motivates the belt (restrict denies a PTY, NOT command execution)
#   B.  restrict + belt DENIES exec
#   C.  belt line: `-N -L` to the PERMITTED target still forwards (the belt's
#       forced command never fires under -N, so the legit path is unaffected)
#   D.  belt line: `-L` to a NON-permitted target is REFUSED by permitopen
#
# Run: bash monitor/watcher/test-remote-carrier-authline.sh
#      CARRIER_LIVE_SSHD=1 bash monitor/watcher/test-remote-carrier-authline.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
MON_DIR=$(cd "$_test_dir/.." && pwd)
EN="$MON_DIR/remote-enroll.sh"

assert_rc() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s — rc %s want %s\n' "$label" "$got" "$want" >&2; FAIL=$((FAIL+1)); fi
}

command -v ssh-keygen >/dev/null 2>&1 || { echo "SKIP: ssh-keygen not present"; echo "ALL TESTS PASSED"; exit 0; }

WORK=$(mktemp -d -t nexus-remote-carrier-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# a client keypair fixture (the private key would never leave the client)
ssh-keygen -t ed25519 -f "$WORK/client" -N '' -C 'client@laptop' >/dev/null 2>&1
BLOB=$(awk '{print $2}' "$WORK/client.pub")

echo "== 1. default form: restrict + port-forwarding + permitopen + belt =="
line=$(bash "$EN" carrier-authline --pubkey "$WORK/client.pub" --port 22022 2>/dev/null)
assert_rc "carrier-authline rc0" "$?" "0"
assert_contains "has restrict"            "$line" "restrict"
assert_contains "has port-forwarding"     "$line" "port-forwarding"
assert_contains "permitopen pins loopback:port" "$line" 'permitopen="127.0.0.1:22022"'
assert_contains "NO-SHELL BELT (forced command)" "$line" 'command="'
assert_contains "belt forces exit 1"      "$line" 'exit 1'
assert_contains "carries the client key blob" "$line" "$BLOB"
assert_contains "carries the carrier comment" "$line" "nexus-remote-carrier"
# exactly one line on stdout
assert_eq "single line on stdout" "$(printf '%s' "$line" | grep -c '')" "1"

echo "== 2. --port overrides; config default applies when omitted =="
line2=$(bash "$EN" carrier-authline --pubkey "$WORK/client.pub" --port 40000 2>/dev/null)
assert_contains "permitopen uses --port 40000" "$line2" 'permitopen="127.0.0.1:40000"'
assert_not_contains "no other port present"    "$line2" '22022'
# default (no --port): MONITOR_REMOTE_PORT env override is the config surface
line2b=$(MONITOR_REMOTE_PORT=33333 bash "$EN" carrier-authline --pubkey "$WORK/client.pub" 2>/dev/null)
assert_contains "default port comes from config (env override)" "$line2b" 'permitopen="127.0.0.1:33333"'

echo "== 3. --no-shell-belt drops the forced command (literal minimal form) =="
line3=$(bash "$EN" carrier-authline --pubkey "$WORK/client.pub" --port 22022 --no-shell-belt 2>/dev/null)
assert_contains "still has restrict + permitopen" "$line3" 'restrict,port-forwarding,permitopen="127.0.0.1:22022"'
assert_not_contains "NO forced command in minimal form" "$line3" 'command="'

echo "== 4. --explicit uses the no-* options instead of restrict (sshd < 7.2) =="
line4=$(bash "$EN" carrier-authline --pubkey "$WORK/client.pub" --port 22022 --explicit 2>/dev/null)
assert_not_contains "no 'restrict' keyword in explicit form" "$line4" 'restrict'
assert_contains "explicit: no-pty"               "$line4" 'no-pty'
assert_contains "explicit: no-agent-forwarding"  "$line4" 'no-agent-forwarding'
assert_contains "explicit: no-X11-forwarding"    "$line4" 'no-X11-forwarding'
assert_contains "explicit: no-user-rc"           "$line4" 'no-user-rc'
assert_contains "explicit still pins permitopen" "$line4" 'permitopen="127.0.0.1:22022"'
assert_contains "explicit still carries the belt" "$line4" 'command="'

echo "== 5. pubkey option-injection is stripped (server reconstructs) =="
printf 'command="rm -rf /",no-pty ssh-ed25519 %s evil@host\n' "$BLOB" > "$WORK/evil.pub"
line5=$(bash "$EN" carrier-authline --pubkey "$WORK/evil.pub" --port 22022 2>/dev/null)
assert_rc "hostile .pub still rc0 (sanitized)" "$?" "0"
assert_not_contains "smuggled 'rm -rf' NOT present"     "$line5" "rm -rf"
assert_not_contains "smuggled 'evil@host' comment gone" "$line5" "evil@host"
assert_contains "reconstructed with OUR options + key"  "$line5" "restrict,port-forwarding,permitopen="
assert_contains "reconstructed key blob intact"         "$line5" "$BLOB"

echo "== 6. --pubkey - reads the key from stdin =="
line6=$(printf 'ssh-ed25519 %s from-stdin\n' "$BLOB" | bash "$EN" carrier-authline --pubkey - --port 22022 2>/dev/null)
assert_rc "stdin pubkey rc0" "$?" "0"
assert_contains "stdin key reconstructed" "$line6" "$BLOB"
assert_contains "stdin: belt present"     "$line6" 'command="'

echo "== 7. bad inputs rejected =="
bash "$EN" carrier-authline --pubkey "$WORK/client.pub" --port 99999 >/dev/null 2>&1
assert_rc "port out of range rejected rc1" "$?" "1"
bash "$EN" carrier-authline --pubkey "$WORK/client.pub" --port notaport >/dev/null 2>&1
assert_rc "non-numeric port rejected rc1" "$?" "1"
bash "$EN" carrier-authline --pubkey "$WORK/client.pub" --comment 'bad comment with spaces' >/dev/null 2>&1
assert_rc "comment with illegal chars rejected rc1" "$?" "1"
bash "$EN" carrier-authline >/dev/null 2>&1
assert_rc "missing --pubkey rejected rc1" "$?" "1"
printf 'this is not a key\n' > "$WORK/bad.pub"
bash "$EN" carrier-authline --pubkey "$WORK/bad.pub" >/dev/null 2>&1
assert_rc "malformed pubkey rejected rc2" "$?" "2"

echo "== 8. stdout/stderr separation: stdout is the line, note is stderr =="
sout=$(bash "$EN" carrier-authline --pubkey "$WORK/client.pub" --port 22022 2>/dev/null)
serr=$(bash "$EN" carrier-authline --pubkey "$WORK/client.pub" --port 22022 2>&1 1>/dev/null)
assert_contains "stdout carries the authline"        "$sout" 'permitopen="127.0.0.1:22022"'
assert_not_contains "stdout carries NO usage prose"  "$sout" 'CARRIER HOST'
assert_contains "stderr carries the usage note"      "$serr" 'CARRIER HOST'
assert_not_contains "stderr carries NO authline"     "$serr" 'permitopen='

# ── 9. NO GitHub surface (mirror the enroll suite's static guarantee) ──
echo "== 9. carrier-authline adds no GitHub surface =="
# Already covered globally by test-remote-enroll.sh §12 over the whole file;
# re-assert that the new code path emits to stdout/stderr only (no gh verb).
if grep -nE '(^|[^a-zA-Z._-])gh +(pr|issue|api|release|comment)' "$EN" >/dev/null 2>&1; then
    printf '  FAIL: a GitHub write verb appears in remote-enroll.sh\n' >&2; FAIL=$((FAIL+1))
else
    printf '  PASS: no GitHub write verb in remote-enroll.sh\n'; PASS=$((PASS+1))
fi

# ──────────────────────────────────────────────────────────────────────
# Live-sshd integration: prove the confinement semantics against a real
# sshd. Opt-in (CARRIER_LIVE_SSHD=1) AND only if a non-root sshd can bind a
# loopback high port — skip cleanly otherwise (CI runners vary).
# ──────────────────────────────────────────────────────────────────────
if [[ "${CARRIER_LIVE_SSHD:-0}" == "1" ]]; then
    echo "== LIVE. empirical sshd confinement (A restrict-exec gap · B belt-denies · C forward · D permitopen) =="
    SSHD=$(command -v sshd || echo /usr/sbin/sshd)
    if [[ ! -x "$SSHD" ]] || ! command -v python3 >/dev/null 2>&1; then
        echo "  SKIP: sshd or python3 unavailable"
    else
        LPORT=42022; PERMIT=42999; DENY=42998; ME=$(whoami)
        ssh-keygen -t ed25519 -f "$WORK/hostkey" -N '' >/dev/null 2>&1
        cat > "$WORK/sshd_config" <<EOF
Port $LPORT
ListenAddress 127.0.0.1
HostKey $WORK/hostkey
PidFile $WORK/sshd.pid
AuthorizedKeysFile $WORK/authorized_keys
StrictModes no
UsePAM no
PubkeyAuthentication yes
PasswordAuthentication no
AllowTcpForwarding yes
LogLevel ERROR
EOF
        if "$SSHD" -f "$WORK/sshd_config" -E "$WORK/sshd.log" 2>/dev/null && sleep 1 && \
           { ss -ltn 2>/dev/null | grep -q ":$LPORT " || netstat -ltn 2>/dev/null | grep -q ":$LPORT "; }; then
            # two loopback TCP targets that announce which port answered
            python3 - "$PERMIT" "$DENY" <<'PY' >/dev/null 2>&1 &
import socket,sys,threading,time
def serve(p):
    s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    s.bind(('127.0.0.1',int(p))); s.listen(5)
    while True:
        c,_=s.accept(); c.sendall(b'TARGET-%b\n'%p.encode()); c.close()
for p in sys.argv[1:]:
    threading.Thread(target=serve,args=(p,),daemon=True).start()
time.sleep(3600)
PY
            TARGETS=$!
            sleep 1
            ssh-keyscan -p "$LPORT" 127.0.0.1 >"$WORK/known" 2>/dev/null
            # Common SSH client opts as an ARRAY. For the -N forward cases we
            # invoke `ssh` DIRECTLY (not through a function) so `$!` is the real
            # ssh PID — a function backgrounded with `&` leaves ssh reparented
            # and unkillable by the subshell PID, leaking the local listener.
            SSH_OPTS=(-i "$WORK/client" -p "$LPORT" -o StrictHostKeyChecking=no
                      -o UserKnownHostsFile="$WORK/known" -o BatchMode=yes
                      -o ConnectTimeout=5 -o LogLevel=ERROR -o ExitOnForwardFailure=yes)
            ssh_as() { ssh "${SSH_OPTS[@]}" "$@"; }
            set_ak() { printf '%s\n' "$1" > "$WORK/authorized_keys"; chmod 600 "$WORK/authorized_keys"; }
            keyin() { printf 'ssh-ed25519 %s probe\n' "$BLOB"; }

            # A. restrict-only (NO belt): exec MUST succeed (proves the gap)
            set_ak "$(keyin | bash "$EN" carrier-authline --pubkey - --port "$PERMIT" --no-shell-belt 2>/dev/null)"
            a=$(ssh_as "$ME@127.0.0.1" 'echo PWNED_$(id -un)' 2>/dev/null)
            if [[ "$a" == PWNED_* ]]; then printf '  PASS: A — restrict-only ALLOWS exec (the gap the belt closes)\n'; PASS=$((PASS+1))
            else printf '  FAIL: A — expected exec to succeed under restrict-only, got [%s]\n' "$a" >&2; FAIL=$((FAIL+1)); fi

            # B. restrict + belt: exec MUST be denied
            set_ak "$(keyin | bash "$EN" carrier-authline --pubkey - --port "$PERMIT" 2>/dev/null)"
            b=$(ssh_as "$ME@127.0.0.1" 'echo PWNED_$(id -un)' 2>/dev/null)
            if [[ "$b" != *PWNED_* ]]; then printf '  PASS: B — belt DENIES command execution\n'; PASS=$((PASS+1))
            else printf '  FAIL: B — belt failed to deny exec, got [%s]\n' "$b" >&2; FAIL=$((FAIL+1)); fi

            # C. belt line: -N -L to the PERMITTED target forwards
            ssh "${SSH_OPTS[@]}" -N -L 43900:127.0.0.1:"$PERMIT" "$ME@127.0.0.1" >/dev/null 2>&1 &
            FWC=$!; sleep 1.5
            c=$( (exec 3<>/dev/tcp/127.0.0.1/43900; head -c 40 <&3) 2>/dev/null )
            kill "$FWC" 2>/dev/null; wait "$FWC" 2>/dev/null
            if [[ "$c" == TARGET-"$PERMIT"* ]]; then printf '  PASS: C — belt line still forwards to the permitted target\n'; PASS=$((PASS+1))
            else printf '  FAIL: C — forward to permitted target failed, got [%s]\n' "$c" >&2; FAIL=$((FAIL+1)); fi

            # D. belt line: -L to a NON-permitted target is refused by permitopen
            ssh "${SSH_OPTS[@]}" -N -L 43901:127.0.0.1:"$DENY" "$ME@127.0.0.1" >/dev/null 2>&1 &
            FWD=$!; sleep 1.5
            d=$( (exec 3<>/dev/tcp/127.0.0.1/43901; head -c 40 <&3) 2>/dev/null )
            kill "$FWD" 2>/dev/null; wait "$FWD" 2>/dev/null
            if [[ -z "$d" ]]; then printf '  PASS: D — permitopen REFUSES a non-permitted forward target\n'; PASS=$((PASS+1))
            else printf '  FAIL: D — non-permitted forward was NOT refused, got [%s]\n' "$d" >&2; FAIL=$((FAIL+1)); fi

            kill "$TARGETS" 2>/dev/null; wait "$TARGETS" 2>/dev/null
            [[ -f "$WORK/sshd.pid" ]] && kill "$(cat "$WORK/sshd.pid")" 2>/dev/null
        else
            echo "  SKIP: could not start a non-root sshd on 127.0.0.1:$LPORT (environment-dependent)"
            [[ -f "$WORK/sshd.pid" ]] && kill "$(cat "$WORK/sshd.pid")" 2>/dev/null
        fi
    fi
fi

th_summary_and_exit
