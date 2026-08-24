#!/usr/bin/env bash
# Tests for PERMANENT-vs-TRANSIENT bind-failure classification
# (your-org/nexus-code#894):
#   monitor/_remote_lib.sh              (_remote_bind_failure_class, the
#                                        bind-blocked marker + its rate limiter)
#   monitor/remote-sshd-supervised.sh   (STOP on permanent; honour + self-clear
#                                        the marker; keep retrying otherwise)
#   monitor/remote-ssh-health.sh        (surface the marker; never green on a
#                                        foreign endpoint)
#   monitor/remote-up.sh                (--status surfaces it; --up clears it)
#
# THE DEFECT, measured on the live nexus before this change: the supervisor
# treated EVERY non-zero sshd exit as transient and relaunched forever —
# **1,753** `restarting in 60s` rounds against `140.107.222.134:22022`, an
# address held by ANOTHER OPERATOR's sshd (different host key; socket owner
# `uid:65534` with no pid attribution, i.e. outside this container's user+pid
# namespace). Waiting cannot clear that. So the decisive assertion in this file
# is a NEGATIVE one: after a permanent failure the log contains ZERO
# `restarting in` lines. A suite that only checked "the marker exists" would
# pass on a supervisor that wrote the marker and then kept hammering anyway.
#
# THE FIXTURES ARE REAL SSHDs, following test-remote-identity-health.sh: the
# FOREIGN holder is an actual sshd carrying a DIFFERENT host key, because the
# classifier's whole job is to distinguish it from ours, and a banner stub
# cannot exercise the signature-verifying probe that makes the verdict DEFINITE.
#
# EVERY assertion runs in the TOP-LEVEL shell. Values needing an isolated env
# are computed in a SUBPROCESS and asserted on in the parent — never
# `( … assert … )`, whose FAIL increments a subshell copy of $FAIL that is lost
# on exit (the #637 skeptic finding; the ledger in _test_helpers.sh now catches
# it, which is a backstop, not a licence).
#
# Fixture ports come from `th_alloc_port` (bind-probed, per-process exclusion
# set) — NOT `BASE + ($$ % 4000)`. These ports are HOST-GLOBAL (the sandbox
# shares the host network namespace) and this file is about port collisions;
# reintroducing the class it tests would be the joke writing itself
# (your-org/nexus-code#769/#800).
#
# Run: bash monitor/watcher/test-remote-permanent-failure.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
MON_DIR=$(cd "$_test_dir/.." && pwd)
LIB="$MON_DIR/_remote_lib.sh"
SUP="$MON_DIR/remote-sshd-supervised.sh"
HEALTH="$MON_DIR/remote-ssh-health.sh"
UP="$MON_DIR/remote-up.sh"

SSHD_BIN=""
for c in /usr/sbin/sshd /sbin/sshd /usr/local/sbin/sshd sshd; do
    if command -v "$c" >/dev/null 2>&1; then SSHD_BIN=$(command -v "$c"); break; fi
    [[ -x "$c" ]] && { SSHD_BIN="$c"; break; }
done
if [[ -z "$SSHD_BIN" ]] || ! command -v ssh-keygen >/dev/null 2>&1 \
   || ! command -v ssh-keyscan >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP: this suite needs sshd + ssh-keygen + ssh-keyscan + python3"
    echo "=== summary: 0 passed, 0 failed ==="
    echo "ALL TESTS PASSED"
    exit 0
fi

WORK=$(mktemp -d -t nexus-permfail-894-XXXXXX)
# principals_dir MUST resolve under $HOME/.claude at 0700 or
# _remote_principals_guard (correctly) refuses. Unique per PID so a parallel
# remote suite cannot collide with it.
PRINCIPALS="$HOME/.claude/principals-permfail-$$"
export MONITOR_REMOTE_PRINCIPALS_DIR="$PRINCIPALS"

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

mkdir -p "$WORK/state" "$PRINCIPALS" "$HOME/.claude"
chmod 700 "$HOME/.claude" "$PRINCIPALS"

# Hermetic config — the live nexus.yml carries a real routable bind + /32 pin
# which would otherwise leak into every case here.
cat >"$WORK/nexus.yml" <<'YML'
monitor:
  remote:
    bind_address: 127.0.0.1
    from_cidr: ""
YML
export NEXUS_CONFIG="$WORK/nexus.yml"
export NEXUS_ROOT="$WORK"
export NEXUS_STATE_DIR="$WORK/state"
export NEXUS_SERVICES_REGISTRY="$WORK/services.registry"
export MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1
export REMOTE_HEALTH_TIMEOUT=5
export REMOTE_SSHD_BIN="$SSHD_BIN"
# Short delays: the point is that it does NOT retry, so a real 60s backoff would
# only make a FAILING run take an hour to say so.
export REMOTE_SSHD_RESTART_DELAY=1
export REMOTE_SSHD_RESTART_DELAY_MAX=2
export REMOTE_SSHD_GATE_RECHECK=2

# Register the service — registration IS the enable signal, so without this row
# the supervisor exits 0 without listening and every case below would pass
# vacuously.
register_row() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        nexus-remote-ssh "$NEXUS_ROOT" "$SUP" "$HEALTH" "$WORK/remote-ssh.log" emit-only \
        > "$NEXUS_SERVICES_REGISTRY"
}
register_row

# Host keys: OURS (in principals_dir, where the lib looks) and a FOREIGN one.
ssh-keygen -q -t ed25519 -f "$PRINCIPALS/ssh_host_ed25519_key" -N '' \
    || { echo "FAIL: keygen (ours)"; exit 1; }
ssh-keygen -q -t ed25519 -f "$WORK/foreign_host_key" -N '' \
    || { echo "FAIL: keygen (foreign)"; exit 1; }
chmod 600 "$PRINCIPALS/ssh_host_ed25519_key" "$WORK/foreign_host_key"
OURS_FP=$(ssh-keygen -lf "$PRINCIPALS/ssh_host_ed25519_key.pub" | awk '{print $2}')
FOREIGN_FP=$(ssh-keygen -lf "$WORK/foreign_host_key.pub" | awk '{print $2}')
: > "$WORK/empty_authorized_keys"
MARKER="$PRINCIPALS/bind-blocked"

# ── fixtures ────────────────────────────────────────────────────────────
# A real sshd on 127.0.0.1:<port> with <key>. Waits for the daemon to ANNOUNCE
# its own bind on stderr rather than inferring it from a connect that any
# stranger on this host-global port could answer.
#
# The pid arrives in the GLOBAL `_SSHD_PID`, never on stdout, so this is called
# DIRECTLY and never as `pid=$(start_sshd …)`. A command substitution would run
# the whole thing in a subshell, where the `CHILD_PIDS+=( … )` registration dies
# with the child — leaving a real sshd running on a host-global port with
# nothing left holding its pid to reap it. Same subshell-scoped-mutation class
# as the assertion ledger's, in the one place where losing it leaks a daemon.
#
# NOTE (measured on this host's bash): `local port="$1" log="$W/x-$port.log"`
# fails with `port: unbound variable` under `set -u` — later assignments in one
# `local` cannot see earlier ones. Hence one assignment per line.
_SSHD_PID=""
start_sshd() {
    local port="$1"
    local key="$2"
    local log="$WORK/sshd-$port.log"
    local i
    _SSHD_PID=""
    : > "$log"
    "$SSHD_BIN" -D -e -f /dev/null -h "$key" -p "$port" \
        -o ListenAddress=127.0.0.1 -o UsePAM=no -o PidFile=none \
        -o "AuthorizedKeysFile=$WORK/empty_authorized_keys" \
        >>"$log" 2>&1 &
    local pid=$!
    CHILD_PIDS+=( "$pid" )
    for i in $(seq 1 60); do
        grep -q "Server listening on 127.0.0.1 port $port." "$log" 2>/dev/null && { _SSHD_PID="$pid"; return 0; }
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
    done
    echo "  FAIL: foreign sshd fixture did not bind :$port — log follows" >&2
    sed 's/^/        | /' "$log" >&2
    FAIL=$((FAIL+1))
    th_summary_and_exit
}

# Run the supervisor to completion under a deadline. The rc lands in the GLOBAL
# `_SUP_RC` — `TIMEOUT` if the deadline elapsed, which IS the failure this suite
# is about (it means the supervisor is still looping) and must be reported as
# itself rather than silently killed and read as some other rc.
#
# MUST be called DIRECTLY, never as `rc=$(run_supervisor …)`. Two reasons, and
# the second one was measured here rather than reasoned about:
#   1. `CHILD_PIDS+=( … )` inside a subshell dies with it, leaking the supervisor.
#   2. `th_kill_own_child` refuses any pid whose PPID is not `$$` — and bash
#      keeps `$$` at the ORIGINAL shell's pid inside a subshell, while the
#      supervisor's real parent is the SUBSHELL. So the deadline kill was
#      declined, and the `wait` behind it then blocked forever on a live child:
#      an 11-minute hang with the mutation in place, where the suite should have
#      gone red in 90 seconds. Same `$$`-in-a-subshell trap the assertion ledger
#      documents, reached through the kill path.
_SUP_RC=""
run_supervisor() {
    local logfile="$1"
    local budget="${2:-90}"
    local pid i
    _SUP_RC=""
    : > "$logfile"
    MONITOR_REMOTE_PORT="$PORT" bash "$SUP" >>"$logfile" 2>&1 &
    pid=$!
    CHILD_PIDS+=( "$pid" )
    for (( i = 0; i < budget * 2; i++ )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid"; _SUP_RC=$?
            return 0
        fi
        sleep 0.5
    done
    # Deadline. Kill the whole process GROUP: a looping supervisor has an sshd
    # child, and reaping only the parent would leave it holding a host-global
    # port. `kill -0` gates the `wait` so a refused kill cannot block us.
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    for (( i = 0; i < 20; i++ )); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
    done
    kill -0 "$pid" 2>/dev/null || wait "$pid" 2>/dev/null
    _SUP_RC="TIMEOUT"
}

PORT=$(th_alloc_port 22400) || th_abort "no free fixture port in [22400,23300)"

# ===========================================================================
echo "== UNIT 1. _remote_bind_failure_class: the four verdicts =="
# The classifier is called DIRECTLY by its callers so the reason globals
# survive; here each case runs in its own SUBPROCESS that prints class+reason,
# and the assertion is made in the PARENT on that printed value.
classify() {   # <port> [env assignments...]
    local port="$1"; shift
    env "$@" bash -c "source '$LIB'; \
        if _remote_bind_failure_class 127.0.0.1 '$port' 5; then rc=0; else rc=1; fi; \
        printf '%s|%s|%s' \"\$rc\" \"\$_REMOTE_BINDFAIL_CLASS\" \"\$_REMOTE_BINDFAIL_REASON\""
}

# (a) FREE port — nothing holds it, so a relaunch is exactly the right move.
FREEPORT=$(th_alloc_port 22400) || th_abort "no second free fixture port"
out=$(classify "$FREEPORT")
assert_eq       "free port ⇒ transient (rc 1)" "${out%%|*}" "1"
assert_contains "…classified transient"        "$out" "|transient|"
assert_contains "…and says the port is bindable now" "$out" "BINDABLE now"

# (b) FOREIGN holder — the live defect. This is the ONLY permanent verdict.
start_sshd "$PORT" "$WORK/foreign_host_key"; FOREIGN_PID="$_SSHD_PID"
out=$(classify "$PORT")
assert_eq       "foreign holder ⇒ PERMANENT (rc 0)" "${out%%|*}" "0"
assert_contains "…classified permanent"             "$out" "|permanent|"
assert_contains "…reason names it as definitely not ours" "$out" "DEFINITELY not ours"
assert_contains "…reason names the FOREIGN fingerprint"   "$out" "$FOREIGN_FP"
assert_contains "…reason names OUR fingerprint to compare against" "$out" "$OURS_FP"

# (c) INDETERMINATE — no ssh client, so identity is unanswerable. A don't-know
# is NOT a verdict: parking the channel on it would strand an endpoint whose
# port merely failed to probe (#603/#607/#626). The port IS held here, so this
# case differs from (a) in exactly one variable: whether we can tell WHOSE.
out=$(classify "$PORT" REMOTE_SSH_BIN="$WORK/no-such-ssh" REMOTE_KEYSCAN_BIN="$WORK/no-such-keyscan")
assert_eq       "held + UNVERIFIABLE ⇒ transient (rc 1), NOT permanent" "${out%%|*}" "1"
assert_contains "…classified transient"        "$out" "|transient|"
assert_contains "…and says why it declined to call it permanent" "$out" "not a verdict"

# (d) OUR OWN daemon holds it — a duplicate supervisor, not a foreign
# collision, and the pidfile path resolves that. Must NOT be permanent.
OURS_PORT=$(th_alloc_port 22400) || th_abort "no third free fixture port"
start_sshd "$OURS_PORT" "$PRINCIPALS/ssh_host_ed25519_key"; OURS_PID="$_SSHD_PID"
out=$(classify "$OURS_PORT")
assert_eq       "OUR OWN daemon holds it ⇒ transient (rc 1)" "${out%%|*}" "1"
assert_contains "…classified transient"       "$out" "|transient|"
assert_contains "…named as our own daemon, not a collision" "$out" "OUR OWN daemon"
th_kill_own_child "$OURS_PID" TERM 2>/dev/null; wait "$OURS_PID" 2>/dev/null

# ===========================================================================
echo "== UNIT 2. the bind-blocked marker =="
res=$(bash -c "source '$LIB'; _remote_record_bind_blocked 127.0.0.1 $PORT 'a test reason' && echo RC=0 || echo RC=1; \
    printf 'BLOCKED=%s\n' \"\$(_remote_bind_blocked && echo yes || echo no)\"; \
    printf 'SUMMARY=%s\n' \"\$(_remote_bind_blocked_summary)\"; \
    printf 'MODE=%s\n' \"\$(stat -c '%a' '$MARKER' 2>/dev/null)\"")
assert_contains "record_bind_blocked succeeds (rc0)"          "$res" "RC=0"
assert_contains "the marker reads back as blocked"            "$res" "BLOCKED=yes"
assert_contains "the summary carries the recorded reason"     "$res" "a test reason"
assert_contains "the marker is 0644 (non-secret, like the recorded port)" "$res" "MODE=644"
assert_contains "the marker file records the port"            "$(cat "$MARKER")" "port=$PORT"
assert_contains "the marker file records socket attribution"  "$(cat "$MARKER")" "attribution="

# The rate limiter: the supervisor is relaunched by the recovery sweep about
# once a minute and exits immediately, so an unthrottled notice would write
# ~1,440 identical lines a day into a log this repo already calls scan noise.
res=$(bash -c "source '$LIB'; \
    _remote_bind_blocked_should_log && echo FIRST=log || echo FIRST=quiet; \
    _remote_bind_blocked_should_log && echo SECOND=log || echo SECOND=quiet; \
    REMOTE_BLOCKED_RELOG=0 _remote_bind_blocked_should_log && echo FORCED=log || echo FORCED=quiet")
assert_contains "first blocked-start notice is logged"        "$res" "FIRST=log"
assert_contains "an immediate second notice is suppressed"    "$res" "SECOND=quiet"
assert_contains "…and the interval is what suppresses it (0 ⇒ logs again)" "$res" "FORCED=log"

res=$(bash -c "source '$LIB'; _remote_clear_bind_blocked; \
    printf 'BLOCKED=%s\n' \"\$(_remote_bind_blocked && echo yes || echo no)\"; \
    printf 'LASTLOG=%s\n' \"\$([[ -f '$MARKER.lastlog' ]] && echo present || echo gone)\"")
assert_contains "clear removes the marker"                    "$res" "BLOCKED=no"
assert_contains "…and its rate-limit stamp, so a re-block logs at once" "$res" "LASTLOG=gone"

# ===========================================================================
echo "== INT 1. supervisor STOPS on a permanent failure (does NOT loop) =="
# The foreign sshd from UNIT 1(b) still holds $PORT.
rm -f "$MARKER" "$MARKER.lastlog"
SUPLOG="$WORK/sup1.log"
run_supervisor "$SUPLOG" 90; rc="$_SUP_RC"
log=$(cat "$SUPLOG" 2>/dev/null)

assert_eq       "supervisor EXITS (does not loop) with EX_CONFIG 78" "$rc" "78"
# THE decisive assertion. 1,753 of these lines is the defect; zero is the fix.
# Without this a supervisor that wrote the marker and kept hammering would pass.
assert_not_contains "ZERO 'restarting in' lines — the 1,753-round signature is gone" "$log" "restarting in"
assert_contains "log states the failure is PERMANENT and it is not retrying" "$log" "PERMANENT FAILURE — NOT retrying"
assert_contains "…names the foreign holder's fingerprint"   "$log" "$FOREIGN_FP"
assert_contains "…tells the operator NOT to signal the holder" "$log" "Do NOT signal"
assert_contains "…names the remedy (move OUR port)"         "$log" "remote-up.sh --down"
assert_contains "…names the incident verb"                  "$log" "ng service-incident"
assert_file_exists "the durable marker was written"         "$MARKER"
assert_contains "the marker names the port that is blocked" "$(cat "$MARKER")" "port=$PORT"

# ===========================================================================
echo "== INT 2. health + status surface the block (and never report green) =="
# The property, not a proxy: the port IS open and IS answering SSH — a check
# that asked "is something listening?" would say healthy. Ours must not,
# because the endpoint is not OURS.
MONITOR_REMOTE_PORT="$PORT" "$HEALTH" >"$WORK/health1.out" 2>"$WORK/health1.err"; hrc=$?
herr=$(cat "$WORK/health1.err")
assert_eq       "health is UNHEALTHY while a FOREIGN sshd answers our port" "$hrc" "1"
assert_contains "…and says it is foreign, not merely down"  "$herr" "FOREIGN sshd"
assert_contains "…naming both fingerprints it compared"     "$herr" "$FOREIGN_FP"
assert_contains "…and ours"                                 "$herr" "$OURS_FP"
assert_contains "…and reports that the supervisor STOPPED (not crashed)" "$herr" "BIND-BLOCKED"

MONITOR_REMOTE_PORT="$PORT" bash "$UP" --status >"$WORK/status1.out" 2>"$WORK/status1.err"
serr=$(cat "$WORK/status1.err")
assert_contains "--status surfaces the bind-blocked diagnosis" "$serr" "BIND-BLOCKED"
assert_contains "…and says the supervisor stopped deliberately" "$serr" "STOPPED deliberately"
assert_contains "…and points at the incident verb"             "$serr" "ng service-incident"

# ===========================================================================
echo "== INT 3. a blocked restart re-verifies and exits WITHOUT spawning sshd =="
# The self-healing shape. To be exact about WHEN this happens: the service's
# registry policy is emit-only, so the watcher NEVER auto-restarts it — this
# path is reached on boot recovery, `svc.sh restart` and each `remote-up.sh`,
# not on a timer. Whenever it IS reached it must cost one bind probe rather than
# a process spawn, and it must not re-log every time.
SUPLOG2="$WORK/sup2.log"
run_supervisor "$SUPLOG2" 60; rc2="$_SUP_RC"
log2=$(cat "$SUPLOG2" 2>/dev/null)
assert_eq       "a blocked restart exits 78 again" "$rc2" "78"
assert_not_contains "…without exec'ing sshd at all" "$log2" "exec: "
assert_not_contains "…and still zero retry rounds"  "$log2" "restarting in"
# This is the FIRST start to reach the blocked-start check (INT 1's supervisor
# created the marker on its way out, it never read one), so the notice is due.
assert_contains "…and it says WHY it declined to start" "$log2" "still BIND-BLOCKED"
assert_contains "…naming the holder"                    "$log2" "DEFINITELY not ours"

# …and the NEXT one inside the interval is suppressed. Unthrottled, the ~1/min
# recovery sweep would write ~1,440 identical lines a day — trading a loud loop
# for a quiet one is not the fix.
SUPLOG2b="$WORK/sup2b.log"
run_supervisor "$SUPLOG2b" 60; rc2b="$_SUP_RC"
log2b=$(cat "$SUPLOG2b" 2>/dev/null)
assert_eq       "a second blocked restart still exits 78" "$rc2b" "78"
assert_not_contains "…but its notice is rate-limited away" "$log2b" "still BIND-BLOCKED"

# ===========================================================================
echo "== INT 4. SELF-HEAL: the holder goes away, the channel comes back UP =="
# Both directions are required. INT 1-3 proved it stops; without this case the
# fix could be "never start again", which is not a fix.
th_kill_own_child "$FOREIGN_PID" TERM 2>/dev/null; wait "$FOREIGN_PID" 2>/dev/null
for i in $(seq 1 40); do
    bindable=$(bash -c "source '$LIB'; _remote_port_bindable 127.0.0.1 '$PORT'; echo \$?")
    [[ "$bindable" == 0 ]] && break
    sleep 0.25
done
assert_eq "the foreign holder released the port (precondition for this case)" "$bindable" "0"

SUPLOG3="$WORK/sup3.log"
: > "$SUPLOG3"
MONITOR_REMOTE_PORT="$PORT" bash "$SUP" >>"$SUPLOG3" 2>&1 &
SUP3_PID=$!
CHILD_PIDS+=( "$SUP3_PID" )
hrc3=1
for i in $(seq 1 60); do
    if MONITOR_REMOTE_PORT="$PORT" "$HEALTH" >/dev/null 2>&1; then hrc3=0; break; fi
    kill -0 "$SUP3_PID" 2>/dev/null || break
    sleep 0.5
done
log3=$(cat "$SUPLOG3" 2>/dev/null)
assert_eq       "the channel comes UP and health goes GREEN on our own daemon" "$hrc3" "0"
assert_contains "…the supervisor announced clearing the stale marker" "$log3" "bind-blocked marker CLEARED"
assert_no_file  "…and the marker is gone (it self-cleared, no operator action)" "$MARKER"
th_kill_own_child "$SUP3_PID" TERM 2>/dev/null; wait "$SUP3_PID" 2>/dev/null

# EXPECTED-COUNT GUARD (your-org/nexus-code#807; required by
# test-summary-honesty-manifest.sh at the `ledger=yes` protection level).
# An assert_* that never RUNS reports zero failures and reads as a pass — and
# this suite is unusually exposed to that, because most of its cases sit behind
# a fixture (`start_sshd`) and a deadline (`run_supervisor`). A case that
# silently stopped running would otherwise shrink the total and still print the
# pass banner, which is the exact shape `#805` catalogued.
#   14  UNIT 1  — 3 free + 5 foreign + 3 indeterminate + 3 ours
# + 11  UNIT 2  — 6 marker + 3 rate-limit + 2 clear
# +  9  INT 1   — stop, no-retry, log content, marker
# +  8  INT 2   — 5 health + 3 status
# +  7  INT 3   — 5 first blocked restart + 2 rate-limited second
# +  4  INT 4   — self-heal
EXPECTED=$(( 14 + 11 + 9 + 8 + 7 + 4 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
