#!/usr/bin/env bash
# Unit tests for the bounded TCP connect (your-org/nexus-code#1028).
#
# Run: bash monitor/watcher/test-remote-connect-bound.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE DEFECT. `_remote_port_is_held` ended in a bare `/dev/tcp` connect. Bash has
# no ConnectTimeout equivalent, so the connect blocks for the kernel's SYN retry
# budget — `tcp_syn_retries` = 6 on this host, ~127s per connect. That probe sits
# in the port-collision gate, BEFORE the health wait, so neither
# REMOTE_UP_TIMEOUT nor MONITOR_REMOTE_HEALTH_TIMEOUT bounds it; a 90s and a
# 150s cap were both measured blown. An operator reaches it by configuring a
# routable `bind_address` that later stops answering — a renumbered NIC, a VLAN
# change, a typo'd octet.
#
# A TIMEOUT YOU HAVE NEVER SEEN FIRE IS NOT A BOUND, so every assertion here is
# behavioural: point the probe at an address that blackholes and require it to
# RETURN, within a wall-clock ceiling, with the timed-out verdict — and require
# it to still succeed against a real listener, because a bound that also breaks
# the working case is not a fix.
#
# SAFETY. This suite NEVER touches the live `nexus-remote-ssh` endpoint. It
# starts its own listener on a port the KERNEL allocates (bind to :0 and read
# the port back from the bound socket), which is collision-free by construction
# — unlike a `BASE + ($$ % N)` scheme, which collides silently on a host-global
# loopback shared with sibling agents.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
_repo_root=$(cd "$_test_dir/../.." && pwd)

WORK=$(mktemp -d)
LISTENER_PID=""
cleanup() {
    [ -n "$LISTENER_PID" ] && kill "$LISTENER_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# shellcheck disable=SC1091
. "$_repo_root/monitor/_remote_lib.sh"

for _f in _remote_tcp_probe _remote_connect_timeout; do
    declare -F "$_f" >/dev/null 2>&1 || { echo "FATAL: $_f not defined" >&2; exit 1; }
done

# BLACKHOLE ADDRESS. TEST-NET-3 (RFC 5737) is reserved for documentation and is
# not routed here, so a connect gets no SYN-ACK and no RST — it hangs. The
# distinction from a REFUSED port is the whole defect: a refusal returns in 0s.
BLACKHOLE=203.0.113.1
BLACKHOLE_PORT=22

# ── a real listener on a kernel-allocated port ─────────────────────────────
cat > "$WORK/listener.py" <<'PY'
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))          # 0 => the kernel picks a FREE port, atomically
s.listen(16)
sys.stdout.write("%d\n" % s.getsockname()[1])
sys.stdout.flush()
deadline = time.time() + 120      # BOUNDED: never outlive the suite
while time.time() < deadline:
    s.settimeout(1.0)
    try:
        c, _ = s.accept()
        c.close()
    except Exception:
        pass
PY

exec 9< <(python3 "$WORK/listener.py" 2>/dev/null)
LISTENER_PID=$!
LIVE_PORT=""
IFS= read -r -t 20 LIVE_PORT <&9 || LIVE_PORT=""

if [ -z "$LIVE_PORT" ]; then
    th_skip "live-listener arms" "could not start a fixture listener"
    LIVE_PORT=0
else
    assert_eq "fixture: the kernel allocated a plausible port" \
        "$( [ "$LIVE_PORT" -gt 1024 ] && echo ok || echo bad )" "ok"
fi

# ═══════════════════════════════════════════════════════════════════════════
echo "== the mutant is LIVE: an UNBOUNDED connect really does hang here =="

# If the blackhole address does not actually blackhole on this host, every
# timing assertion below is vacuous — it would pass against a fix that does
# nothing. Prove the hang before claiming to have bounded it. Capped at 6s so
# the proof itself is bounded; the real budget is ~127s.
_t0=$SECONDS
timeout 6 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$BLACKHOLE" "$BLACKHOLE_PORT" 2>/dev/null
_raw_rc=$?
_raw_el=$(( SECONDS - _t0 ))
assert_eq "MUTANT IS LIVE: a bare connect to the blackhole does NOT return on its own" \
    "$( [ "$_raw_rc" -eq 124 ] && echo hung || echo "returned-rc-$_raw_rc" )" "hung"
assert_eq "MUTANT IS LIVE: it consumed the whole cap rather than failing fast" \
    "$( [ "$_raw_el" -ge 5 ] && echo used-the-cap || echo "fast-${_raw_el}s" )" "used-the-cap"

# THE CONTROL that makes the above mean what it says: a REFUSED connect returns
# immediately. Without this, "slow" could just be how connects behave here.
_t0=$SECONDS
timeout 6 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/1"' 2>/dev/null
_ref_el=$(( SECONDS - _t0 ))
assert_eq "CONTROL: a REFUSED connect returns immediately (only blackholes hang)" \
    "$( [ "$_ref_el" -le 2 ] && echo fast || echo "slow-${_ref_el}s" )" "fast"

# ═══════════════════════════════════════════════════════════════════════════
echo "== the bound FIRES: _remote_tcp_probe returns, and says it could not tell =="

_t0=$SECONDS
REMOTE_CONNECT_TIMEOUT=2 _remote_tcp_probe "$BLACKHOLE" "$BLACKHOLE_PORT"
_rc=$?
_el=$(( SECONDS - _t0 ))
assert_eq "a blackholed connect returns rc 2 (TIMED OUT), not 0 and not 1" "$_rc" "2"
assert_eq "…and returns within the configured bound (2s, ceiling 6s)" \
    "$( [ "$_el" -le 6 ] && echo bounded || echo "overran-${_el}s" )" "bounded"

# THE BOUND IS THE KNOB, not a constant. Two different caps must produce two
# different elapsed times, or the "bound" could be anything at all.
_t0=$SECONDS; REMOTE_CONNECT_TIMEOUT=5 _remote_tcp_probe "$BLACKHOLE" "$BLACKHOLE_PORT"; _el5=$(( SECONDS - _t0 ))
assert_eq "the knob is load-bearing: a 5s cap outlasts a 2s cap" \
    "$( [ "$_el5" -ge 4 ] && [ "$_el5" -le 9 ] && echo tracks-the-knob || echo "elapsed-${_el5}s" )" \
    "tracks-the-knob"

# A NON-NUMERIC OR ZERO KNOB MUST NOT DISABLE THE BOUND. `timeout 0` means "no
# limit", so a config typo would silently restore the hang — the defect
# reappearing through the very knob added to prevent it.
for bad in 0 '' abc -1; do
    _t0=$SECONDS
    REMOTE_CONNECT_TIMEOUT="$bad" _remote_tcp_probe "$BLACKHOLE" "$BLACKHOLE_PORT" >/dev/null 2>&1
    _elb=$(( SECONDS - _t0 ))
    assert_eq "a bad knob (${bad:-<empty>}) falls back to the default bound, never to unbounded" \
        "$( [ "$_elb" -le 8 ] && echo bounded || echo "overran-${_elb}s" )" "bounded"
done

# ═══════════════════════════════════════════════════════════════════════════
echo "== the bound does NOT break the working case =="

if [ "$LIVE_PORT" -gt 0 ]; then
    _t0=$SECONDS
    REMOTE_CONNECT_TIMEOUT=3 _remote_tcp_probe 127.0.0.1 "$LIVE_PORT"
    _lrc=$?
    _lel=$(( SECONDS - _t0 ))
    assert_eq "a REAL listener is still detected (rc 0)" "$_lrc" "0"
    assert_eq "…and detection is immediate, not at the bound" \
        "$( [ "$_lel" -le 2 ] && echo fast || echo "slow-${_lel}s" )" "fast"

    assert_eq "_remote_port_is_held reports HELD for the live listener" \
        "$( _remote_port_is_held 127.0.0.1 "$LIVE_PORT" 2>/dev/null && echo held || echo free )" "held"
else
    th_skip "live-listener assertions" "no fixture listener"
fi

# A closed loopback port is a POSITIVE 'refused', distinct from a timeout.
REMOTE_CONNECT_TIMEOUT=3 _remote_tcp_probe 127.0.0.1 1
assert_eq "a refused port is rc 1 (positively closed), NOT rc 2 (unknown)" "$?" "1"

# ═══════════════════════════════════════════════════════════════════════════
echo "== a blind probe is LOUD, never silently 'free' =="

# The public contract of _remote_port_is_held is two-valued, so a timeout must
# fall through — but doing that SILENTLY is the confident-negative shape this
# repo keeps filing. The caller is about to bind.
err=$(REMOTE_CONNECT_TIMEOUT=2 _remote_port_is_held "$BLACKHOLE" "$BLACKHOLE_PORT" 2>&1 >/dev/null)
assert_contains "a timed-out occupancy probe warns on stderr" "$err" "TIMED OUT"
assert_contains "…and says occupancy is UNKNOWN rather than free" "$err" "UNKNOWN"

# And the whole call is bounded, which is the end-to-end property #1028 is about:
# this is the gate `remote-up.sh` blew a 90s and a 150s cap on.
_t0=$SECONDS
REMOTE_CONNECT_TIMEOUT=2 _remote_port_is_held "$BLACKHOLE" "$BLACKHOLE_PORT" >/dev/null 2>&1
_hel=$(( SECONDS - _t0 ))
assert_eq "_remote_port_is_held itself returns within the bound" \
    "$( [ "$_hel" -le 8 ] && echo bounded || echo "overran-${_hel}s" )" "bounded"

# ═══════════════════════════════════════════════════════════════════════════
echo "== _remote_find_free_port cannot become an unbounded scan =="

# 100 ports x ~127s was the latent worst case: over three and a half hours, from
# a loop that looks perfectly ordinary. Bounded, a short span is seconds.
_t0=$SECONDS
REMOTE_CONNECT_TIMEOUT=1 _remote_find_free_port "$BLACKHOLE" 22000 3 >/dev/null 2>&1
_sel=$(( SECONDS - _t0 ))
assert_eq "a 3-port scan of a blackholing host completes in bounded time" \
    "$( [ "$_sel" -le 15 ] && echo bounded || echo "overran-${_sel}s" )" "bounded"

# ═══════════════════════════════════════════════════════════════════════════
echo "== the probe must not LEAK bash's own connect diagnostic to stderr =="

# your-org/nexus-code#1028 skeptic F1 — a REGRESSION this suite shipped without
# noticing, because `_probe_banner` had zero assertions of its own.
#
# Bash applies redirections LEFT TO RIGHT. `exec 3<>… 2>/dev/null` therefore
# attempts the connect BEFORE stderr is redirected, and the shell's own
# diagnostic escapes. The grouped form redirects the whole group first.
#
# THE LEAK IS NOT COSMETIC, which is the reason this is an assertion and not a
# style note: `monitor/watcher/_service_health.sh` picks the operator-facing
# verdict by keyword over stderr with `head -n1`, and `refused` is one of those
# keywords. A leaked "connect: Connection refused" therefore OUTRANKS the real
# diagnostic, and a port held by a FOREIGN SQUATTER gets reported to the
# operator as our own daemon being down — the #609/#637 distinction, re-broken
# by a new route at unchanged rc.
leak_bytes() { bash -c "$1" 127.0.0.1 1 2>&1 >/dev/null | wc -c; }

# POSITIVE CONTROL FIRST: the ungrouped form must actually leak here, or the
# assertion below passes for a shell that never leaks and proves nothing.
assert_eq "control: the UNGROUPED form really does leak on this shell" \
    "$( [ "$(leak_bytes 'exec 3<>"/dev/tcp/$0/$1" 2>/dev/null || exit 9')" -gt 0 ] \
        && echo leaks || echo silent )" "leaks"

assert_eq "the GROUPED form leaks nothing" \
    "$(leak_bytes '{ exec 3<>"/dev/tcp/$0/$1"; } 2>/dev/null || exit 9')" "0"

# And the SHIPPED file must use the grouped form. Keyed on the source because
# the consumer (_service_health.sh) is pinned against hand-written stderr
# literals and never runs this script, so it stayed 15/0 green while the real
# pairing was broken.
# BEHAVIOURAL ON THE SHIPPED FILE — your-org/nexus-code#1028 skeptic round 2, R2.
#
# The source assertions below are necessary and NOT sufficient, and the skeptic
# demonstrated that concretely: a TWO-PART edit (add a grouped form somewhere,
# ungroup the live one) leaves a pure census 23/0 GREEN while the live path leaks
# 91 bytes. My own commit conceded the principle — "a census pins MEMBERSHIP
# only, never PLACEMENT" — and then shipped a census anyway.
#
# So run the REAL function. `_probe_banner` is extracted from the shipped
# `remote-ssh-health.sh` at run time, exactly as the sibling suite in this branch
# extracts `_clone_freshness_block` from `spawn-worker.sh`, and driven against a
# CLOSED port. The property is: the operator-facing stderr must be EMPTY, because
# `_service_health.sh` selects its verdict by keyword off `head -n1` and `refused`
# is one of those keywords.
_PB="$WORK/probe_banner.sh"
awk '/^_probe_banner\(\) \{/,/^}$/' "$_repo_root/monitor/remote-ssh-health.sh" > "$_PB"
# POSITIVE CONTROL ON THE EXTRACTOR: an awk range that matches nothing yields an
# EMPTY file that sources cleanly and defines no function, and every assertion
# below would then measure a no-op and report exactly what I expected.
assert_eq "extractor found _probe_banner in the shipped file" \
    "$(grep -c '^_probe_banner() {' "$_PB")" "1"

probe_stderr_bytes() {          # <host> <port> -> bytes on stderr
    (
        PROBE_HOST="$1"; PORT="$2"; TIMEOUT=2
        _remote_connect_timeout() { printf 2; }
        _nc_banner() { return 3; }
        # shellcheck disable=SC1090
        . "$_PB"
        _probe_banner >/dev/null
    ) 2>&1 >/dev/null | wc -c
}

# A CLOSED loopback port: connect is refused instantly, so this measures the
# LEAK and not a timeout.
assert_eq "the SHIPPED _probe_banner leaks NOTHING on a refused connect" \
    "$(probe_stderr_bytes 127.0.0.1 1)" "0"

# BOOLEANS, not counts. `grep -c` counts LINES, not matches, so a count is the
# wrong unit for "is this construct present" — and a census pins MEMBERSHIP
# only, never PLACEMENT (textguard-lint R1, your-org/nexus-code#1016/#1026). The
# question here is genuinely yes/no in both directions: the grouped form must be
# present, and no ungrouped exec-connect may exist anywhere in the file.
_hp="$_repo_root/monitor/remote-ssh-health.sh"
assert_eq "remote-ssh-health.sh uses the GROUPED redirect" \
    "$( grep -qF '{ exec 3<>"/dev/tcp/$0/$1"; } 2>/dev/null' "$_hp" && echo present || echo ABSENT )" \
    "present"
assert_eq "…and carries no UNGROUPED exec-connect anywhere" \
    "$( grep -qE '^[[:space:]]*exec 3<>"/dev/tcp' "$_hp" && echo FOUND || echo none )" \
    "none"

th_summary_and_exit
