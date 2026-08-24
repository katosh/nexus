#!/usr/bin/env bash
# RUNTIME regression guard for the posture-aware `from=` pin
# (your-org/nexus-code#902, skeptic finding F2).
#
# WHY A SEPARATE SUITE, AND WHY IT USES A REAL sshd.
#
# `#902` was a RUNTIME refusal — `Permission denied (publickey)` from a live
# daemon — but every assertion that covered it was a STRING assertion on
# `authorized_keys` content. Those assertions are true and they are not enough:
# the mechanism varies on **sshd's own `from=` parsing**, which no string test
# touches. A future change that keeps the string plausible and the semantics
# wrong — a CIDR form sshd parses differently, an OpenSSH release that treats
# `::1/128` differently — passes every string assertion and locks out every
# client again. That is exactly the history this file exists to prevent.
#
# THE CONFIGURATION IS THE WHOLE POINT (this is the F2 finding).
# The repo's only pre-existing live-SSH block pins `from_cidr=127.0.0.1/32` —
# a CIDR that **already permits the loopback peer**, so it authenticates with
# or without the fix. Measured by the skeptic:
#
#     suite config, posture-aware  from=127.0.0.1/32,127.0.0.1/32,::1/128 -> ACCEPTED
#     suite config, raw (pre-#902) from=127.0.0.1/32                      -> ACCEPTED
#
# Both green. A test that cannot fail proves nothing, however truthful its
# assertions are. So this suite pins a **LAN** range that does NOT contain the
# peer, which is the only configuration where fixed and broken differ:
#
#     LAN cidr, posture-aware      from=10.99.0.0/16,127.0.0.1/32,::1/128 -> ACCEPTED
#     LAN cidr, raw (pre-#902)     from=10.99.0.0/16                      -> REFUSED
#
# Case 3 below asserts that non-discrimination DIRECTLY, so that nobody
# "simplifies" the cidr back to 127.0.0.1/32 and silently disarms the guard.
#
# The discriminating setup is the skeptic's (`indep902.sh`), adopted rather than
# re-derived — it was already demonstrated end-to-end against a live daemon.
#
# EVIDENCE IS THE DAEMON'S OWN LOG. `Accepted publickey for <user>` at
# LogLevel=VERBOSE is sshd testifying that THIS key passed authentication —
# not an inference from an exit code, which a dozen unrelated failures share.
#
# COVERAGE BOUNDARY, stated because it bounds the claim: this exercises exactly
# ONE sshd implementation — whichever is installed here (OpenSSH 7.6p1 when the
# skeptic measured it). A different OpenSSH could parse `from=` differently and
# this suite would not know until it runs there.
#
# LOOPBACK ONLY. No routable address is ever bound.
#
# Run: bash monitor/watcher/test-remote-from-pin-runtime.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
MON_DIR=$(cd "$_test_dir/.." && pwd)
LIB="$MON_DIR/_remote_lib.sh"

SSHD_BIN=""
for c in /usr/sbin/sshd /sbin/sshd /usr/local/sbin/sshd sshd; do
    if command -v "$c" >/dev/null 2>&1; then SSHD_BIN=$(command -v "$c"); break; fi
    [[ -x "$c" ]] && { SSHD_BIN="$c"; break; }
done
if [[ -z "$SSHD_BIN" ]] || ! command -v ssh >/dev/null 2>&1 \
   || ! command -v ssh-keygen >/dev/null 2>&1 || ! command -v ssh-keyscan >/dev/null 2>&1 \
   || ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP: this suite needs sshd + ssh + ssh-keygen + ssh-keyscan + python3"
    echo "=== summary: 0 passed, 0 failed ==="
    echo "ALL TESTS PASSED"
    exit 0
fi

WORK=$(mktemp -d -t nexus-frompin-902-XXXXXX)
PRINCIPALS="$HOME/.claude/principals-frompin-$$"
CHILD_PIDS=()
cleanup() {
    local p
    for p in "${CHILD_PIDS[@]:-}"; do
        [[ -n "$p" ]] || continue
        th_kill_own_child "$p" KILL 2>/dev/null
        wait "$p" 2>/dev/null
    done
    rm -rf "$WORK" "$PRINCIPALS"
}
trap cleanup EXIT

mkdir -p "$WORK" "$PRINCIPALS" "$HOME/.claude"
chmod 700 "$HOME/.claude" "$PRINCIPALS"

# Hermetic config. NEXUS_ROOT must point at a fixture, not the live tree — the
# skeptic's first pass was INVALID because an inherited NEXUS_ROOT made
# `_remote_cfg` read the live primary config, so its "empty" cases were never
# empty. Same trap, pre-empted here.
cat >"$WORK/nexus.yml" <<'YML'
monitor:
  remote:
    bind_address: 127.0.0.1
    from_cidr: ""
YML
export NEXUS_CONFIG="$WORK/nexus.yml"
export NEXUS_ROOT="$WORK"
export MONITOR_REMOTE_PRINCIPALS_DIR="$PRINCIPALS"
export MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1

ME=$(id -un)
ssh-keygen -q -t ed25519 -f "$WORK/hostkey" -N '' || th_abort "keygen (host) failed"
ssh-keygen -q -t ed25519 -f "$WORK/client"  -N '' || th_abort "keygen (client) failed"
chmod 600 "$WORK/hostkey" "$WORK/client"
CLIENT_KEYPAIR=$(cut -d' ' -f1-2 < "$WORK/client.pub")
AK="$WORK/authorized_keys"

# The pin list the REAL library builds under a loopback bind, for a given
# from_cidr — not a literal retyped here, so the test tracks the implementation.
pin_list() {
    MONITOR_REMOTE_FROM_CIDR="$1" bash -c "source '$LIB'; _remote_from_pin_list"
}

# Bring up a real sshd carrying an authorized_keys line in the shape
# `cmd_enroll` writes (from= + restrict + forced command), attempt ONE publickey
# connection, and report what the DAEMON logged.
#
# Results arrive in globals — this is called DIRECTLY, never as `$( )`, because
# `CHILD_PIDS+=()` and `th_kill_own_child` (which requires PPID == $$) both die
# in a subshell. That combination previously produced an 11-minute silent hang
# in a sibling suite; not repeating it.
_ATTEMPT_ACCEPTED=""
_ATTEMPT_SSH_RC=""
attempt() {                       # $1 = the from= list ('' for no from= option)
    local fromlist="$1"
    local port cfg log pid i
    _ATTEMPT_ACCEPTED=""; _ATTEMPT_SSH_RC=""
    port=$(th_alloc_port 24200) || { th_abort "no free fixture port in [24200,25100)"; }
    cfg="$WORK/sshd-$port.conf"
    log="$WORK/sshd-$port.log"
    if [[ -n "$fromlist" ]]; then
        printf 'from="%s",restrict,command="/bin/true" %s testclient@nexus-remote\n' \
            "$fromlist" "$CLIENT_KEYPAIR" > "$AK"
    else
        printf 'restrict,command="/bin/true" %s testclient@nexus-remote\n' \
            "$CLIENT_KEYPAIR" > "$AK"
    fi
    chmod 600 "$AK"
    cat > "$cfg" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $WORK/hostkey
PidFile none
AuthorizedKeysFile $AK
AuthorizedKeysCommand none
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
LogLevel VERBOSE
EOF
    : > "$log"
    "$SSHD_BIN" -f "$cfg" -D -e >"$log" 2>&1 &
    pid=$!
    CHILD_PIDS+=( "$pid" )
    local bound=1
    for (( i = 0; i < 60; i++ )); do
        grep -q "Server listening on 127.0.0.1 port $port" "$log" 2>/dev/null && { bound=0; break; }
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
    done
    if (( bound != 0 )); then
        printf '  FAIL: sshd fixture did not bind :%s — log follows\n' "$port" >&2
        sed 's/^/        | /' "$log" >&2
        FAIL=$((FAIL+1))
        th_kill_own_child "$pid" KILL 2>/dev/null
        th_summary_and_exit
    fi
    ssh-keyscan -p "$port" 127.0.0.1 > "$WORK/known" 2>/dev/null
    ssh -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$WORK/known" \
        -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR \
        -o PreferredAuthentications=publickey -i "$WORK/client" -T "$ME@127.0.0.1" \
        </dev/null >/dev/null 2>"$WORK/ssh.err"
    _ATTEMPT_SSH_RC=$?
    # The DAEMON's own testimony, not our inference from an exit code.
    if grep -q "Accepted publickey for $ME" "$log" 2>/dev/null; then
        _ATTEMPT_ACCEPTED=YES
    else
        _ATTEMPT_ACCEPTED=no
    fi
    th_kill_own_child "$pid" KILL 2>/dev/null
    wait "$pid" 2>/dev/null
}

LAN_CIDR="10.99.0.0/16"   # a LAN range that does NOT contain 127.0.0.1

# ===========================================================================
echo "== 1. THE PROPERTY: posture-aware pin + LAN cidr ⇒ the client AUTHENTICATES =="
# bind=127.0.0.1, from_cidr=10.99.0.0/16, peer=127.0.0.1 — inside the bind,
# OUTSIDE the configured cidr. This is the live posture that locked out every
# client before #902.
FIXED_PIN=$(pin_list "$LAN_CIDR")
assert_eq "the library builds the posture-aware pin for a LAN cidr" \
    "$FIXED_PIN" "10.99.0.0/16,127.0.0.1/32,::1/128"
attempt "$FIXED_PIN"
assert_eq "a real sshd ACCEPTS the key under the posture-aware pin" "$_ATTEMPT_ACCEPTED" "YES"
assert_eq "…and ssh exits 0" "$_ATTEMPT_SSH_RC" "0"

# ===========================================================================
echo "== 2. THE REGRESSION: the raw cidr (pre-#902) is REFUSED at publickey time =="
# This arm is the one that reddens if the posture-awareness is ever removed —
# the string assertions elsewhere cannot see this, because the string is a
# perfectly plausible from= value. It just does not authenticate.
attempt "$LAN_CIDR"
assert_eq "a real sshd REFUSES the same key under the raw LAN-only pin" "$_ATTEMPT_ACCEPTED" "no"
assert_eq "…and ssh fails (non-zero)" \
    "$([[ "$_ATTEMPT_SSH_RC" != "0" ]] && echo failed || echo "UNEXPECTEDLY-OK")" "failed"

# ===========================================================================
echo "== 3. WHY THE CIDR MATTERS: 127.0.0.1/32 cannot discriminate (F2 itself) =="
# Asserted directly so the discriminating configuration cannot be "simplified"
# back to the one that proves nothing. Under from_cidr=127.0.0.1/32 BOTH the
# fixed and the broken pin authenticate — which is precisely why the repo's
# pre-existing live block could not have caught #902.
attempt "$(pin_list 127.0.0.1/32)"
assert_eq "loopback cidr + posture-aware pin ⇒ accepted" "$_ATTEMPT_ACCEPTED" "YES"
attempt "127.0.0.1/32"
assert_eq "loopback cidr + RAW pin ⇒ ALSO accepted (so this config proves nothing)" \
    "$_ATTEMPT_ACCEPTED" "YES"

# ===========================================================================
echo "== 4. no from= at all still authenticates (the pin is what is under test) =="
# Non-vacuity for the whole fixture: if the harness were broken — wrong key,
# wrong user, sshd rejecting for an unrelated reason — every case above would
# read `no` and case 2 would PASS for the wrong reason. This proves the fixture
# can produce an acceptance at all.
attempt ""
assert_eq "no from= option ⇒ accepted (fixture is capable of success)" "$_ATTEMPT_ACCEPTED" "YES"

# ===========================================================================
# EXPECTED-COUNT GUARD (your-org/nexus-code#807; required by
# test-summary-honesty-manifest.sh at the `ledger=yes` protection level).
#   3  case 1 (pin value, accepted, rc)
# + 2  case 2 (refused, rc)
# + 2  case 3 (both accepted)
# + 1  case 4 (non-vacuity)
EXPECTED=$(( 3 + 2 + 2 + 1 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
