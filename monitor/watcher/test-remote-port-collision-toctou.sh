#!/usr/bin/env bash
# test-remote-port-collision-toctou.sh — your-org/nexus-code#810.
#
# THE DEFECT. `check_port_collision` (monitor/remote-up.sh) observed the port
# occupied, THEN verified ownership with an ssh-keyscan, and then refused on
# the strength of the FIRST observation. Two observations of a mutable fact,
# separated by a network probe — so they can disagree, and in CI on `#795`
# they did, producing a refusal that contradicts itself in its own text:
#
#     REFUSING to enable — a listener holds 127.0.0.1:58944 …
#       cannot verify the endpoint host key: … Connection refused
#       no LISTEN socket visible on port 58944
#
# A run aborted with `nothing was registered or started` over a peer that no
# longer existed. It surfaced under CPU starvation (PSI `cpu-stall%=58.47` on
# 2 vCPUs) because that widens the gap between the two observations.
#
# THE FIX HAS TWO HALVES and this file tests both, because either alone is
# insufficient and each can regress independently:
#
#   1. PROBE BY THE OPERATION BEING PREDICTED. Occupancy is answered by an
#      actual bind(), not by a connect. A connect is wrong in BOTH directions
#      and the repo has paid for both: `#769` (a port held as an ephemeral
#      SOURCE port answers a connect "free" and then fails bind) and `#810`
#      (a listener mid-teardown answers one connect and is gone).
#   2. RE-ESTABLISH THE PREMISE AT THE VERDICT. Every refusal re-probes; a
#      port that is bindable NOW is not holding anything, so there is nothing
#      to refuse over.
#
# THE ASSERTION THAT MATTERS MOST IS THE NEGATIVE ONE. "Stop refusing" is
# trivially achievable by disabling the guard, and the guard exists to prevent
# a genuinely worse state (our supervisor wedged on EADDRINUSE forever while
# the healthcheck reads green off somebody else's daemon). So every
# now-proceeds case below is paired with a real-listener case that must STILL
# refuse, and with a probe-cannot-tell case that must still refuse.
#
# This suite NEVER touches the nexus-remote-ssh service: no registry row, no
# supervisor, no sshd. It binds only loopback ports it allocated itself, the
# same thing every sibling remote suite does.
#
# Run: bash monitor/watcher/test-remote-port-collision-toctou.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
MON_DIR=$(cd "$_test_dir/.." && pwd)
LIB="$MON_DIR/_remote_lib.sh"
UP="$MON_DIR/remote-up.sh"

command -v python3 >/dev/null 2>&1 || { th_skip "python3 not present — the bind probe degrades to the pre-#810 signals by design"; th_summary_and_exit; }
for f in "$LIB" "$UP"; do
    [[ -r "$f" ]] || th_abort "missing $f"
done

WORK=$(mktemp -d -t nexus-toctou-XXXXXX)
HOLDERS=()
cleanup() {
    local pid
    for pid in "${HOLDERS[@]:-}"; do
        [[ "$pid" =~ ^[0-9]+$ ]] && th_kill_own_child "$pid"
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

# Fixture env — entirely under $WORK, mirroring test-remote-port-select.sh, so
# sourcing remote-up.sh cannot read or write the operator state.
export NEXUS_STATE_DIR="$WORK/state"
export NEXUS_SERVICES_REGISTRY="$WORK/services.registry"
export NEXUS_ROOT="$WORK/nexusroot"
export HOME="$WORK/home"
export MONITOR_REMOTE_PRINCIPALS_DIR="$HOME/.claude/principals"
export MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1
mkdir -p "$WORK/state" "$WORK/nexusroot/monitor/.state" "$HOME/.claude" \
         "$MONITOR_REMOTE_PRINCIPALS_DIR" || th_abort "fixture mkdir failed"
: > "$NEXUS_SERVICES_REGISTRY"

# ---- helpers ------------------------------------------------------------

# Start a real LISTENING socket on $1 and block until it is up. Returns after
# the port is genuinely held, so no assertion races the fixture.
_hold_listening() {
    local port="$1" flag
    # NOT `local port="$1" flag="$WORK/held.$port"` — bash expands every word of
    # the command line before the builtin runs, so `$port` there is the OUTER
    # (unset) name and `set -u` aborts the suite.
    flag="$WORK/held.$port"
    rm -f "$flag"
    python3 -c '
import socket, sys, time
port, flag = int(sys.argv[1]), sys.argv[2]
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(5)
open(flag, "w").write("1")
time.sleep(120)
' "$port" "$flag" &
    HOLDERS+=( "$!" )
    # `disown` so the shell does not print a `Terminated` notification (with the
    # whole python source inline) when cleanup kills the holder at EXIT. That
    # noise lands AFTER `ALL TESTS PASSED` and reads exactly like a failure.
    disown "$!" 2>/dev/null || true
    local i
    for i in $(seq 1 100); do [[ -s "$flag" ]] && return 0; sleep 0.1; done
    return 1
}

# Start an ESTABLISHED OUTBOUND connection pinned to $1 as its SOURCE port —
# the `#769` state. A connect-probe calls this FREE; bind() gets EADDRINUSE.
# Deliberately NO SO_REUSEADDR on the client: Linux lets two SO_REUSEADDR
# sockets share a port while neither listens, so a bound-not-listening fixture
# does NOT reproduce the conflict.
_hold_as_source_port() {
    local port="$1" flag
    # NOT `local port="$1" flag="$WORK/src.$port"` — bash expands every word of
    # the command line before the builtin runs, so `$port` there is the OUTER
    # (unset) name and `set -u` aborts the suite.
    flag="$WORK/src.$port"
    rm -f "$flag"
    python3 -c '
import socket, sys, time
port, flag = int(sys.argv[1]), sys.argv[2]
srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(5)
cli = socket.socket()
cli.bind(("127.0.0.1", port))
cli.connect(srv.getsockname())
conn, _ = srv.accept()
open(flag, "w").write("1")
time.sleep(120)
' "$port" "$flag" &
    HOLDERS+=( "$!" )
    # `disown` so the shell does not print a `Terminated` notification (with the
    # whole python source inline) when cleanup kills the holder at EXIT. That
    # noise lands AFTER `ALL TESTS PASSED` and reads exactly like a failure.
    disown "$!" 2>/dev/null || true
    local i
    for i in $(seq 1 100); do [[ -s "$flag" ]] && return 0; sleep 0.1; done
    return 1
}

# Run check_port_collision in a subprocess with a scripted world. Echoes the
# combined output plus a trailing `RC=<n>`; every assertion is made in the
# PARENT on that value, never inside the subshell (a FAIL there increments a
# copy of $FAIL that dies with the subshell — the #637 skeptic finding).
#   $1 port · $2 identity-probe rc · $3 extra shell to inject (may be empty)
_run_collision() {
    local port="$1" idrc="$2" extra="${3:-}"
    MONITOR_REMOTE_PORT="$port" STUB_IDRC="$idrc" EXTRA="$extra" bash -c '
        set -uo pipefail
        source "'"$UP"'" >/dev/null 2>&1
        # The transient observation the real bug started from: occupancy says
        # HELD. Everything downstream must cope with that being stale.
        port_is_held() { return 0; }
        _remote_identity_probe() { _REMOTE_ID_REASON="stub idrc=$STUB_IDRC"; return "$STUB_IDRC"; }
        _remote_attribute_listener() { printf "no LISTEN socket visible on port %s" "$MONITOR_REMOTE_PORT"; }
        _recover_service_running() { return 1; }   # our supervisor is NOT running
        eval "$EXTRA"
        check_port_collision 2>&1
        printf "RC=%s" "$?"
    ' 2>&1
}

# ===========================================================================
echo "== 1. the primitive: _remote_port_bindable answers by BINDING =="

FREE_PORT=$(th_alloc_port 41100) || th_abort "no free port for the bindable probe"
rc=$(bash -c "source '$LIB'; _remote_port_bindable 127.0.0.1 $FREE_PORT; printf %s \$?")
assert_eq "free port → rc 0 (bindable)" "$rc" "0"

LISTEN_PORT=$(th_alloc_port 41300) || th_abort "no free port for the listener fixture"
_hold_listening "$LISTEN_PORT" || th_abort "listener fixture never came up on $LISTEN_PORT"
rc=$(bash -c "source '$LIB'; _remote_port_bindable 127.0.0.1 $LISTEN_PORT; printf %s \$?")
assert_eq "listening port → rc 1 (EADDRINUSE)" "$rc" "1"
rc=$(bash -c "source '$LIB'; _remote_port_is_held 127.0.0.1 $LISTEN_PORT; printf %s \$?")
assert_eq "_remote_port_is_held agrees: held" "$rc" "0"

# ---------------------------------------------------------------------------
echo
echo "== 2. the #769 direction: a connect-probe FALSE FREE that bind() sees =="
# Not decoration. This is why the fix is "probe by binding" rather than "retry
# the connect": a retry of a blind probe returns the same wrong answer, which
# is precisely why "retry on seizure" was a placebo in #769.
_srcport_asserts=0
SRC_PORT=$(th_alloc_port 41500) || th_abort "no free port for the source-port fixture"
if _hold_as_source_port "$SRC_PORT"; then
    connect_says=$(bash -c "( exec 3<>/dev/tcp/127.0.0.1/$SRC_PORT ) 2>/dev/null; printf %s \$?")
    bind_says=$(bash -c "source '$LIB'; _remote_port_bindable 127.0.0.1 $SRC_PORT; printf %s \$?")
    assert_eq "connect-probe calls the source port FREE (rc!=0 = refused)" \
              "$( [[ "$connect_says" == 0 ]] && echo connected || echo refused )" "refused"
    assert_eq "bind-probe calls it HELD — the answer the caller acts on" "$bind_says" "1"
    held=$(bash -c "source '$LIB'; _remote_port_is_held 127.0.0.1 $SRC_PORT; printf %s \$?")
    assert_eq "_remote_port_is_held reports held (was FREE pre-#810)" "$held" "0"
    _srcport_asserts=3
else
    th_skip "could not pin an ephemeral source port — #769 direction unverified this run"
    _srcport_asserts=0
fi

# ---------------------------------------------------------------------------
echo
echo "== 3. THE #810 CASE: occupied at detection, FREE at verification =="
# Exactly the CI shape: occupancy said held (stubbed), the identity probe came
# back INDETERMINATE (rc 2 — `Connection refused`, the arm the incident hit),
# and the port is in fact free. The run must PROCEED, and must say why.
GONE_PORT=$(th_alloc_port 41700) || th_abort "no free port for the vanished-listener case"
out=$(_run_collision "$GONE_PORT" 2)
assert_contains "vanished listener → rc 0 (proceeds)" "$out" "RC=0"
assert_not_contains "vanished listener → does NOT refuse" "$out" "REFUSING to enable"
assert_contains "and NAMES the reason rather than going quiet" "$out" \
                "BINDABLE at verification"

# rc 3 (`no local key`) is the other arm that printed "…yet something IS
# listening": same two-observation shape, same treatment.
out=$(_run_collision "$GONE_PORT" 3)
assert_contains "rc3 arm also proceeds when the port is free now" "$out" "RC=0"
assert_not_contains "rc3 arm does not refuse over a vanished peer" "$out" "REFUSING to enable"

# ---------------------------------------------------------------------------
echo
echo "== 4. NEGATIVE CONTROLS: a REAL collision must still refuse =="
# The whole risk of this change is turning a guard into a no-op. A live
# listener on the port is a genuine collision at verification time and every
# arm must still refuse, with nothing registered or started.
out=$(_run_collision "$LISTEN_PORT" 2)
assert_contains "real listener, rc2 → still REFUSES" "$out" "REFUSING to enable"
assert_contains "real listener, rc2 → rc 1" "$out" "RC=1"
assert_not_contains "and does NOT claim the collision cleared" "$out" \
                    "BINDABLE at verification"

out=$(_run_collision "$LISTEN_PORT" 3)
assert_contains "real listener, rc3 → still REFUSES" "$out" "REFUSING to enable"
assert_contains "real listener, rc3 → rc 1" "$out" "RC=1"

out=$(_run_collision "$LISTEN_PORT" 1)
assert_contains "real listener, rc1 (CONFIRMED FOREIGN) → still REFUSES" "$out" "REFUSING to enable"
assert_contains "real listener, rc1 → rc 1" "$out" "RC=1"

# ---------------------------------------------------------------------------
echo
echo "== 5. a probe that CANNOT TELL never downgrades a refusal =="
# rc 2 from _remote_port_bindable means "no python3 / not our address / some
# other errno". That is not evidence the port is free, and treating it as
# such would re-open the EADDRINUSE-forever state on exactly the hosts least
# able to diagnose it. Fail CLOSED.
out=$(_run_collision "$GONE_PORT" 2 '_remote_port_bindable() { return 2; }')
assert_contains "bind probe inconclusive → refusal STANDS" "$out" "REFUSING to enable"
assert_contains "bind probe inconclusive → rc 1" "$out" "RC=1"
assert_not_contains "…and makes no cleared-collision claim" "$out" \
                    "BINDABLE at verification"

# And the mirror: if the probe says BINDABLE, the same arm proceeds. Together
# these two show the outcome is decided by the probe and nothing else — the
# assertions above cannot be passing for an unrelated reason.
out=$(_run_collision "$LISTEN_PORT" 2 '_remote_port_bindable() { return 0; }')
assert_contains "bind probe says free → proceeds even on the held port" "$out" "RC=0"

# ---------------------------------------------------------------------------
echo
echo "== 6. the idempotent OURS path is untouched =="
# rc 0 = the endpoint proved possession of our host key. That never reached
# the refusal path and must not start.
out=$(_run_collision "$LISTEN_PORT" 0)
assert_contains "ours-live → rc 0" "$out" "RC=0"
assert_not_contains "ours-live → no refusal" "$out" "REFUSING to enable"

# EXPECTED-COUNT GUARD (your-org/nexus-code#807; required by
# test-summary-honesty-manifest.sh at the `ledger=yes` protection level).
# DERIVED, because the #769 source-port fixture can legitimately fail to pin an
# ephemeral port and skip. Pinning a literal would hide exactly the case this
# suite is about: an assertion that silently did not run.
#   3  the bind() primitive (free / EADDRINUSE / _remote_port_is_held agrees)
# + 3  the #769 connect-vs-bind disagreement, ONLY when the fixture pinned
# + 5  the #810 case: rc2 arm (3) + rc3 arm (2)
# + 7  negative controls: rc2 (3), rc3 (2), rc1 (2)
# + 4  inconclusive probe never downgrades a refusal (3) + its mirror (1)
# + 2  the idempotent ours-live path
EXPECTED=$(( 3 + _srcport_asserts + 5 + 7 + 4 + 2 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
