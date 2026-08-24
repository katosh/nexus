#!/usr/bin/env bash
# Tests for ENDPOINT IDENTITY on the confined remote channel
# (your-org/nexus-code#609 items 1-3): the healthcheck must establish that the
# listener on our bind:port is OURS, remote-up must refuse to enable onto a
# foreign listener, and the fingerprint remote-up hands the operator must be the
# one it READ OFF THE LIVE ENDPOINT.
#
# WHY THIS SUITE EXISTS. On 2026-07-29 nexus-remote-ssh died with an
# agent-sandbox container restart, another operator's nexus-remote-ssh on the
# same shared host took 140.107.222.134:22022 during the downtime, and every
# surface reported healthy for 2h30m — because `remote-ssh-health.sh` accepted
# ANY `SSH-2.0-*` banner while documenting itself as "IDENTITY-AWARE". The loser
# of a port race reports healthy while serving nothing. The bind:port is
# host-global (the sandbox shares the host network namespace, 127.0.0.1
# included), so this is not exotic — it is the default outcome of two operators
# enabling the channel on one machine.
#
# THE FIXTURES ARE REAL SSHDs, not banner stubs (a non-root sshd serves a
# pre-auth KEX fine) — PLUS a forging server that claims our key without holding
# it. That last fixture exists because the first version of this fix took its
# verdict from `ssh-keyscan`, on the untested assumption that "it completes a real
# key exchange, so it cannot be spoofed". It does not: ssh-keyscan records the key
# the server CLAIMS and aborts before verifying the signature over the exchange
# hash, and our public host key is not secret (it is handed to clients by design).
# The #609 skeptic pass caught this, and it was the SAME defect class one level up
# — a check asserting a property it did not measure. The verdict now comes from a
# signature-verifying `ssh` probe; case 12 is the regression test.
#
#   1. unit: _remote_identity_probe verdicts (ours / foreign / no-local-key)
#   2. OUR sshd on the port → healthcheck HEALTHY (the positive path; without it
#      every refusal below would pass equally well if the gate fired always)
#   3. NEGATIVE CONTROL, load-bearing: a FOREIGN sshd (real sshd, DIFFERENT host
#      key) on our port → UNHEALTHY, and the message names the foreign holder
#   4. the 2026-07-29 bug verbatim: a banner-only listener → UNHEALTHY
#   5. no local host key + something listening → UNHEALTHY (nothing can be ours)
#   6. the health_require_identity knob: it covers INDETERMINATE only, and
#      CANNOT green a DEFINITE foreign verdict
#   7. not-registered still short-circuits to healthy (the no-flap rule) even
#      with a foreign daemon on the port
#   8. remote-up refuses to enable onto a foreign listener, registers NOTHING,
#      and does NOT refuse when the holder is ours (the negative control)
#   9. remote-up prints the fingerprint READ OFF THE LIVE ENDPOINT, and on a
#      collision refuses to present either value as the pin
#  10. remote-up --status reports the identity verdict as its own field
#  11. a missing assert_* helper fails the suite instead of passing it
#  12. THE KEY-CLAIM REGRESSION: a server that CLAIMS our host key without
#      holding it is REJECTED — and ssh-keyscan is shown accepting it, so the
#      test documents why the verdict must not come from a key READ
#
# Run: bash monitor/watcher/test-remote-identity-health.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
MON_DIR=$(cd "$_test_dir/.." && pwd)
LIB="$MON_DIR/_remote_lib.sh"
HEALTH="$MON_DIR/remote-ssh-health.sh"
UP="$MON_DIR/remote-up.sh"

SSHD_BIN=""
for c in /usr/sbin/sshd /sbin/sshd /usr/local/sbin/sshd sshd; do
    if command -v "$c" >/dev/null 2>&1; then SSHD_BIN=$(command -v "$c"); break; fi
    [[ -x "$c" ]] && { SSHD_BIN="$c"; break; }
done
if [[ -z "$SSHD_BIN" ]] || ! command -v ssh-keyscan >/dev/null 2>&1 \
   || ! command -v ssh-keygen >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP: this suite needs sshd + ssh-keyscan + ssh-keygen + python3"
    echo "=== summary: 0 passed, 0 failed ==="
    echo "ALL TESTS PASSED"
    exit 0
fi

WORK=$(mktemp -d -t nexus-id609-XXXXXX)
# principals_dir MUST resolve under $HOME/.claude at 0700 or
# _remote_principals_guard (correctly) refuses — so it cannot be a bare mktemp
# dir. Unique per PID so a parallel test-remote-service run cannot collide.
PRINCIPALS="$HOME/.claude/principals-id609-$$"
export MONITOR_REMOTE_PRINCIPALS_DIR="$PRINCIPALS"

SSHD_PIDS=()
cleanup() {
    local p
    for p in "${SSHD_PIDS[@]:-}"; do
        [[ -n "$p" ]] && th_kill_own_child "$p" KILL 2>/dev/null
        [[ -n "$p" ]] && wait "$p" 2>/dev/null
    done
    rm -rf "$WORK" "$PRINCIPALS"
}
trap cleanup EXIT

mkdir -p "$WORK/state" "$PRINCIPALS" "$HOME/.claude"
chmod 700 "$HOME/.claude" "$PRINCIPALS"

# ── hermetic config (the live nexus.yml carries a REAL routable bind + /32 pin
# which would leak into every case here). Env still wins per-case.
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

# ── FIXTURE PORTS: ALLOCATED, NOT ASSUMED ───────────────────────────────
# Every start_* helper treats "a TCP connect to my port succeeds" as "my fixture
# came up" — a LIVENESS PROXY, the very defect this suite tests for, sitting in
# the suite's own fixtures. On this host that is not hypothetical: the sandbox
# shares the host network namespace, so these ports are HOST-GLOBAL, every
# operator's nexus suite derives them from the same `BASE + ($$ % 4000)` formula,
# and `ss -ltnpe` shows a standing population of foreign listeners (uid:65534, no
# pid attribution) across exactly these ranges. A collision would silently point
# the assertions at a stranger's process — and it fired on the first run of this
# guard (port 31228 was already held).
#
# So probe for a FREE port instead of assuming one, and fail loud only if a whole
# window is occupied. Never signal the holder: uid:65534 with no pid means it is
# outside this user+pid namespace and is not ours to touch.
# PROBE BY THE OPERATION YOU ARE PREDICTING (your-org/nexus-code#769).
#
# This used to probe with a TCP CONNECT and hand back any port that refused it.
# A connect only detects a LISTENING socket. It CANNOT see a port already held
# as the EPHEMERAL SOURCE PORT of an outbound connection — and every window this
# suite allocates from except OURS_PORT sits INSIDE the kernel's ephemeral range
# (`/proc/sys/net/ipv4/ip_local_port_range`, 32768-60999 on this host and on the
# CI runners). Measured, not reasoned: an ESTABLISHED outbound socket's local
# port answers the connect-probe with "FREE" and then fails `bind()` with
# `[Errno 98] Address already in use`, SO_REUSEADDR or not.
#
# That is the confirmed mechanism of your-org/nexus-code#769, caught in the wild
# once the #794 post-mortem stopped destroying the evidence:
#
#     note: fixture port 33054 was SEIZED between allocation and bind (x3)
#     WHY: the child EXITED (status 1, classified port-seized) after 1 poll ≈ 0.2s.
#          NO deadline was involved: the ceiling here is 80 poll(s) ≈ 16.0s.
#     LOG: OSError: [Errno 98] Address already in use
#
# Note the retries returned THE SAME PORT three times: the probe is deterministic
# and its verdict never changes, because the blocker is invisible to it. So this
# is also why "retry on seizure" was a placebo until the probe was fixed.
#
# It is the suite's own defect class, sitting in its allocator: a check asserting
# a property it did not measure. The fix is to measure the property — `bind()`
# the port, which is exactly what the fixture is about to do — and to remember
# the ports already found unusable so a retry genuinely tries a different one.
# One python3 process per allocation (python3 is a hard dependency, gated at the
# top of this file), not one per probe.
#
# HONEST LIMIT: this BINDS but does not HOLD. The probe socket is closed in a
# `finally`, so the port is released before the fixture binds it, and this
# remains a PREDICTION — a far better-evidenced one, but a prediction. Holding
# the socket open and handing the fixture an inherited fd would eliminate the
# race outright; it would also mean rewriting `sshd -p` and both python fixtures
# to accept a pre-bound descriptor, which is a larger change than the two issues
# in hand justify. The residual window is quantified above, and a seizure inside
# it is now DETECTED (`port-seized`), RETRIED on an excluded-set port, and if it
# still fails, reported with the log inline rather than silently miscounted.
_PORT_EXCLUDE=""
pick_free_port() {
    local base="$1" got
    got=$(python3 -c '
import socket, sys
base = int(sys.argv[1]); pid = int(sys.argv[2])
excl = set(int(x) for x in sys.argv[3].split(",") if x.strip())
for i in range(200):
    p = base + ((pid + i * 7) % 900)
    if p in excl:
        continue
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", p))
    except OSError:
        continue
    finally:
        s.close()
    print(p)
    sys.exit(0)
sys.exit(1)
' "$base" "$$" "$_PORT_EXCLUDE" 2>/dev/null) || return 1
    [[ "$got" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$got"
}
# The five fixture ports used to be allocated RIGHT HERE, in one loop, and then
# bound as much as 15 s later — FORGE_PORT not until case 12. "This port is
# free" is only true at the instant it is measured, so that gap was the entire
# exposure surface of your-org/nexus-code#769. Allocation now happens inside
# `_fixture_up`, immediately before each bind. Ports below are declared only so
# `set -u` has something to read if a fixture is ever referenced out of order.
OURS_PORT=""; FOREIGN_PORT=""; BANNER_PORT=""; UPOK_PORT=""; FORGE_PORT=""

# ── 0. THE ALLOCATOR ITSELF ─────────────────────────────────────────────
# your-org/nexus-code#769's root cause was here, not in any deadline: the
# allocator predicted "you can bind this" from evidence that only shows "nothing
# is listening here". Those differ for every port inside the kernel's ephemeral
# range, which is where four of this suite's five windows live.
#
# The fixture is a port bound WITHOUT listen(): a connect-probe gets ECONNREFUSED
# and calls it free, while bind() gets EADDRINUSE. That is precisely the state an
# outbound connection's local port is in, and it is what seized port 33054.
echo "== 0. the port allocator refuses a port only bind() can see =="
ALLOC_BASE=39000
# The holder must be an ESTABLISHED OUTBOUND socket, which is the real-world
# state — not merely a bound-not-listening one. Linux lets two SO_REUSEADDR
# sockets share a port while neither listens, so a bound-not-listening fixture
# does NOT reproduce the conflict; this suite's own assertion caught that draft.
# An ordinary outbound connection (no SO_REUSEADDR) pinned to the port does.
python3 -c '
import socket, sys, time
base = int(sys.argv[1]); pid = int(sys.argv[2])
p = base + (pid % 900)          # the FIRST port pick_free_port will try (i=0)
srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(5)
cli = socket.socket()           # deliberately NO SO_REUSEADDR
cli.bind(("127.0.0.1", p))      # pin our chosen port as the SOURCE port
cli.connect(srv.getsockname())  # …and make it ESTABLISHED
conn, _ = srv.accept()
open(sys.argv[3], "w").write(str(p))
time.sleep(300)
' "$ALLOC_BASE" "$$" "$WORK/held.port" &
SSHD_PIDS+=( "$!" )
for _i in $(seq 1 50); do [[ -s "$WORK/held.port" ]] && break; sleep 0.2; done
HELD_PORT=$(cat "$WORK/held.port" 2>/dev/null)

if [[ ! "$HELD_PORT" =~ ^[0-9]+$ ]]; then
    # Do not let this degrade into a vacuous pass: if the fixture could not be
    # held, the assertions below would compare nothing and report success.
    printf '  FAIL: could not hold a bound-not-listening port for the allocator test\n' >&2
    FAIL=$((FAIL+1))
else
    # (a) THE BLIND SPOT, demonstrated — the old probe's evidence says "free".
    if ( exec 3<>"/dev/tcp/127.0.0.1/$HELD_PORT" ) 2>/dev/null; then
        conn_verdict=occupied
    else
        conn_verdict=free
    fi
    assert_eq "a connect-probe calls an ESTABLISHED socket's source port FREE" "$conn_verdict" "free"

    # (b) …and bind() — the operation the fixture actually performs — disagrees.
    bind_verdict=$(python3 -c '
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("127.0.0.1", int(sys.argv[1]))); print("bindable")
except OSError:
    print("EADDRINUSE")
finally:
    s.close()
' "$HELD_PORT")
    assert_eq "…while bind() reports EADDRINUSE on that same port" "$bind_verdict" "EADDRINUSE"

    # (c) THE FIX: the allocator must not hand it out. Before this, it did —
    #     deterministically, on every retry, which is why retrying was a placebo.
    alloc_got=$(pick_free_port "$ALLOC_BASE")
    assert_eq "pick_free_port allocates a port at all" \
        "$([[ "$alloc_got" =~ ^[0-9]+$ ]] && echo yes || echo "no ($alloc_got)")" "yes"
    assert_eq "…and NEVER the port only bind() could see" \
        "$([[ "$alloc_got" == "$HELD_PORT" ]] && echo "handed out the held port" || echo differs)" "differs"

    # (d) The exclusion list is honoured, so a retry cannot re-pick the port it
    #     just found unusable — the observed 3x-same-port retry loop.
    _PORT_EXCLUDE_SAVE="$_PORT_EXCLUDE"
    _PORT_EXCLUDE="${_PORT_EXCLUDE:+$_PORT_EXCLUDE,}$alloc_got"
    alloc_again=$(pick_free_port "$ALLOC_BASE")
    assert_eq "an excluded port is never re-allocated" \
        "$([[ "$alloc_again" == "$alloc_got" ]] && echo "re-allocated" || echo differs)" "differs"
    _PORT_EXCLUDE="$_PORT_EXCLUDE_SAVE"
fi



register_row() {
    printf 'nexus-remote-ssh\t%s\t%s\t%s\t%s\temit-only\n' \
        "$NEXUS_ROOT" "$MON_DIR/remote-sshd-supervised.sh" "$HEALTH" "$WORK/svc.log" \
        > "$NEXUS_SERVICES_REGISTRY"
}
deregister_row() { : > "$NEXUS_SERVICES_REGISTRY"; }

# Fixture-daemon bind ceilings, SCALED for contention (your-org/nexus-code#558).
#
# Each `start_*` below polls at 0.2 s for its daemon to bind. Those ceilings were
# written as unloaded-host guesses, and this suite never joined the `th_deadline`
# convention — it referenced it ZERO times — so under `--jobs 4` on a 2-vCPU
# runner they were not scaled at all.
#
# That is precisely the failure `th_deadline`'s own docstring describes:
# "`test-jupyter-service.sh` … green 93/93 standalone, failing EVERY full-suite
# run at `--jobs 4`, because its 20 s deadlines were sized on an idle host.
# Nothing was wrong with the code under test." It reddened case 12 on
# your-org/nexus-code#776 as `the forging fixture could not start` — a python
# process that had not bound inside a flat 8 s — in ONE of six matrix cells,
# while the same suite passed 6/6 locally both with `NEXUS_ROOT` exported and
# with it unset.
#
# A polled ceiling costs ZERO wall time on a green run: the loop returns the
# instant the bind lands. Scaling only changes how long a genuinely broken
# fixture takes to be declared broken — which is why the fix is to scale rather
# than to raise the flat number, and why it is not a tolerance.
_bind_polls() {   # _bind_polls <unloaded-seconds> → number of 0.2 s polls
    local secs
    secs=$(th_deadline "$1" 2>/dev/null)
    # Fall back to the unscaled value rather than to 0: a th_deadline that ever
    # returns something non-numeric must not silently collapse the ceiling to
    # "poll zero times", which would turn every fixture start into an instant
    # failure — a confident wrong answer of exactly the kind this suite exists
    # to refuse.
    [[ "$secs" =~ ^[0-9]+$ ]] && (( secs >= 1 )) || secs="$1"
    printf '%s' $(( secs * 5 ))
}

# ── FIXTURE-START POST-MORTEM (your-org/nexus-code#794) ─────────────────
#
# A DIAGNOSTIC MAY ONLY NAME A PATH THAT OUTLIVES THE PROCESS PRINTING IT.
#
# This file used to answer "why did the fixture not start?" with
# `see $WORK/forge-<port>.log` — a file its own EXIT trap (`rm -rf "$WORK"`,
# armed unconditionally at line ~91) deletes at suite exit, i.e. BEFORE
# run-tests.sh records the failure and long before CI's `collect failure
# artifacts` step runs. Confirmed by downloading all four artifacts of a real
# failing run (`#781` head `f5a9fe07`, `unit suite (bash, jobs 4)`, attempt 1):
# the suite's `.out`/`.err`, `_env.txt` and the suite file are there; the forge
# log is in NONE of them. The collector's re-run cannot recover it either — it
# calls `mktemp -d` afresh, so any log it produces belongs to a different run,
# and on a flake the re-run passes outright (it printed `90 passed, 0 failed`).
#
# The citation read as helpful and was inert. That is why your-org/nexus-code#769
# accumulated occurrences for months without anyone naming its mechanism: every
# occurrence destroyed the one artefact that would have named it.
#
# So these helpers print CONTENTS, not paths, onto the suite's own stderr —
# which CI already uploads. They cost nothing on a green run: every call site is
# reached only on failure.
_polls_to_secs() { printf '%d.%ds' $(( $1 * 2 / 10 )) $(( $1 * 2 % 10 )); }

# _await_bind <pid> <port> <tries> <ready-string> — poll at 0.2 s for <pid> to
# announce <ready-string> in its own log.
#
# rc 0 = bound. rc 1 = did not bind, with `_FIXTURE_EXIT` naming WHICH exit was
# taken (`port-seized`, `child-exited`, `ceiling-expired`) and `_FIXTURE_DETAIL`
# carrying the numbers.
#
# WHY THE DISCRIMINATOR IS LOAD-BEARING. The old loops returned a bare `1` for
# both "the child exited" and "the ceiling expired", so the post-mortem had to
# GUESS which. It guessed the ceiling — your-org/nexus-code#769/#720 were filed
# as "CPU contention against a bind-readiness ceiling" — and the arithmetic
# refutes that: on the failing job `NEXUS_TEST_DEADLINE_SCALE=2` and `nproc=2`,
# so this ceiling was 80 polls ≥ 16 s, while the WHOLE SUITE ran 15.67 s. The
# ceiling cannot have expired. Erasing the distinction is what let a wrong
# mechanism stand, and a wrong mechanism sends the next fix at a bigger
# deadline — which would not work. Record it instead of inferring it.
#
# The port and log travel in globals set by `_await_bind` itself rather than as
# post-mortem arguments. That is deliberate: the first draft threaded the port
# through `fixture_or_fail`'s parameter list, which changed its arity — and I
# missed the fifth call site (line ~543), so the post-mortem printed
# `PORT start_sshd`. A diagnostic that has to be wired up correctly at every
# call site is a diagnostic that will be wrong at one of them, and it is only
# ever read on the day something is already broken.
_FIXTURE_EXIT=""      # port-seized | child-exited | ceiling-expired
_FIXTURE_DETAIL=""
_FIXTURE_LOG=""       # log the failed fixture was writing to, if any
_FIXTURE_PORT=""      # port it was trying to bind
#
# READINESS IS AN ANNOUNCEMENT, NOT A TCP CONNECT (your-org/nexus-code#769).
#
# This loop used to accept "a TCP connect to my port succeeds" as "my fixture
# came up". That is a LIVENESS PROXY — the exact defect class this whole suite
# exists to refuse — sitting in the suite's own fixtures, and the file header
# says so in as many words. `pick_free_port` fixed ALLOCATION, not this: the
# ports are host-global, FORGE_PORT is bound ~15 s after it is allocated, and
# ANY listener answering in that window was read as ours.
#
# Reproduced by construction: with a stranger holding FORGE_PORT, the old check
# reported the forger STARTED, and case 12 then measured the stranger — 82
# passed, 8 failed, including `…named as IMPERSONATION` and `…stating it does
# not hold the key` VERBATIM, which is the failure family your-org/nexus-code#769
# reports from CI. So a foreign listener on a fixture port does not merely flake
# the suite; it makes the suite accuse a stranger's process of impersonation.
#
# Every fixture here can say for itself that it bound: `sshd -e` prints
# `Server listening on …`, and the two python fixtures print a READY line after
# `listen()`. An announcement is proof of OWNERSHIP — two listeners cannot hold
# one addr:port (SO_REUSEADDR does not permit it, and SO_REUSEPORT is not set),
# so if our child announced the bind, the port is ours.
_await_bind() {
    local pid="$1" port="$2" tries="$3" ready="$4" i rc
    _FIXTURE_EXIT=""; _FIXTURE_DETAIL=""; _FIXTURE_PORT="$port"
    for (( i = 0; i < tries; i++ )); do
        grep -qF -- "$ready" "$_FIXTURE_LOG" 2>/dev/null && return 0
        if ! kill -0 "$pid" 2>/dev/null; then
            # The child is gone. `kill -0` failing means bash has already reaped
            # it (a ZOMBIE still answers `kill -0`), so its status is still in
            # the jobs table and this `wait` returns the real one.
            wait "$pid" 2>/dev/null; rc=$?
            # WHY it exited decides whether this is the HOST's fault or OURS.
            # A bind refusal is the host's; anything else (a traceback, a bad
            # argument, a broken forge.py) is this suite's own input and must
            # never be downgraded.
            if grep -qiE 'address already in use|errno 98|EADDRINUSE' "$_FIXTURE_LOG" 2>/dev/null; then
                _FIXTURE_EXIT="port-seized"
            else
                _FIXTURE_EXIT="child-exited"
            fi
            printf -v _FIXTURE_DETAIL \
                'the child EXITED (status %s, classified %s) after %s poll(s) ≈ %s. NO deadline was involved: the ceiling here is %s poll(s) ≈ %s.' \
                "$rc" "$_FIXTURE_EXIT" "$i" "$(_polls_to_secs "$i")" "$tries" "$(_polls_to_secs "$tries")"
            return 1
        fi
        sleep 0.2
    done
    _FIXTURE_EXIT="ceiling-expired"
    printf -v _FIXTURE_DETAIL \
        'the child was STILL ALIVE but had not announced a bind after %s poll(s) ≈ %s (the full ceiling).' \
        "$tries" "$(_polls_to_secs "$tries")"
    return 1
}

# _fixture_env_fault — is the recorded failure attributable to the HOST rather
# than to this suite's own inputs? Only these may ever be downgraded from FAIL.
# An ALLOWLIST with a default-deny arm, deliberately: a denylist with a
# permissive default downgrades whatever its author did not think of, and
# "the fixture did not start" is precisely where an unthought-of cause lands.
_fixture_env_fault() {
    case "$_FIXTURE_EXIT" in
        port-seized|ceiling-expired|no-free-port) return 0 ;;
        *) return 1 ;;
    esac
}

# _fixture_log_dump <logfile> — print the log's CONTENTS, indented, bounded.
#
# Three outcomes, all of them stated. An ABSENT or EMPTY log is evidence too and
# must be said out loud rather than rendered as a blank gap: it excludes both a
# python traceback and a bind error (each of which writes here), which points at
# death by signal or a failed exec. Silence standing in for an answer is this
# repo's dominant defect class; a diagnostic that prints nothing when it found
# nothing reproduces it.
_fixture_log_dump() {
    local f="$1" n
    if [[ -z "$f" || ! -e "$f" ]]; then
        printf '        LOG: NO log file exists — the child never got far enough to create one.\n' >&2
        return 0
    fi
    if [[ ! -s "$f" ]]; then
        printf '        LOG: exists but is EMPTY. That EXCLUDES a python traceback and a bind\n' >&2
        printf '             error (both write here) and points at a signal or a failed exec.\n' >&2
        return 0
    fi
    n=$(wc -l <"$f" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] || n='?'
    printf '        LOG (%s line(s)) follows INLINE — printed, not cited, because the work dir\n' "$n" >&2
    printf '             is removed by this suite EXIT trap before any collector can read it:\n' >&2
    sed -n '1,80{s/^/          | /;p;}' "$f" >&2
    [[ "$n" =~ ^[0-9]+$ ]] && (( n > 80 )) \
        && printf '          | … (%s further line(s) truncated)\n' $(( n - 80 )) >&2
    return 0
}

# _fixture_postmortem — the full "why did it not start" block. Takes NO
# arguments (see above): it reads what `_await_bind` recorded. Prints the
# exit path taken, then the log contents, then what is holding the port NOW.
_fixture_postmortem() {
    local port="$_FIXTURE_PORT"
    printf '        WHY: %s\n' "${_FIXTURE_DETAIL:-<not recorded>}" >&2
    _fixture_log_dump "$_FIXTURE_LOG"
    # Who holds the port at post-mortem time. These fixture ports are
    # HOST-GLOBAL (the sandbox shares the host network namespace), so a stranger
    # seizing one between allocation and bind is not a hypothesis — it is the
    # confirmed mechanism of your-org/nexus-code#769, and this is the line that
    # names the holder.
    if command -v ss >/dev/null 2>&1; then
        printf '        PORT %s at post-mortem (ss -ltnp):\n' "$port" >&2
        ss -ltnp 2>/dev/null | awk -v p=":$port" 'NR==1 || index($4, p)' \
            | sed 's/^/          | /' >&2
    fi
}

# start_sshd <port> <keyfile> — a real, non-root sshd on 127.0.0.1.
# Echoes nothing; appends its pid to SSHD_PIDS and waits for it to ANNOUNCE the
# bind. `-e` sends `Server listening on 127.0.0.1 port N.` to stderr, which this
# captures — sshd testifying to its own bind, rather than us inferring it from a
# connect that any stranger could answer.
start_sshd() {
    local port="$1" key="$2" tries
    tries=$(_bind_polls 12)
    _FIXTURE_LOG="$WORK/sshd-$port.log"
    : > "$_FIXTURE_LOG"
    "$SSHD_BIN" -D -e -f /dev/null -h "$key" -p "$port" \
        -o ListenAddress=127.0.0.1 -o UsePAM=no -o PidFile=none \
        -o "AuthorizedKeysFile=$WORK/empty_authorized_keys" \
        >>"$_FIXTURE_LOG" 2>&1 &
    local pid=$!
    SSHD_PIDS+=( "$pid" )
    _await_bind "$pid" "$port" "$tries" "Server listening on 127.0.0.1 port $port."
}

# start_banner_only <port> — the 2026-07-29 false-green fixture: eight bytes of
# `SSH-2.0-`, no host key, no key exchange, no sshd of any kind.
start_banner_only() {
    local port="$1" tries
    tries=$(_bind_polls 8)
    # Was `>/dev/null 2>&1`, which discarded this fixture's post-mortem at the
    # source — and it is a fixture your-org/nexus-code#769 has been OBSERVED
    # failing to start (`FAIL: fixture could not start: banner-only stub on
    # 33370`, run 3 of the six in that issue's table). Keep the output.
    _FIXTURE_LOG="$WORK/banner-$port.log"
    : > "$_FIXTURE_LOG"
    python3 -c "
import socket,signal,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$port)); s.listen(5)
sys.stderr.write('READY banner $port\\n'); sys.stderr.flush()
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
while True:
    try:
        c,_=s.accept(); c.sendall(b'SSH-2.0-NOT_OURS_AT_ALL\r\n'); c.close()
    except Exception: pass
" >>"$_FIXTURE_LOG" 2>&1 &
    local pid=$!
    SSHD_PIDS+=( "$pid" )
    # This loop also never checked `kill -0`, so a stub that DIED burned the
    # whole ceiling and then reported the same bare `1` as a stub that merely
    # had not bound yet — the identical erasure `_await_bind` exists to end.
    _await_bind "$pid" "$port" "$tries" "READY banner $port"
}

: > "$WORK/empty_authorized_keys"

# start_forger <port> <pubkey-path> — an SSH-2 server that CLAIMS the given host
# key without holding its private half: it speaks the protocol as far as
# SSH_MSG_KEX_ECDH_REPLY, replays the real key blob, and sends a 64-byte all-zero
# signature. It computes no valid shared secret and holds no private key.
FORGER="$WORK/forge.py"
cat > "$FORGER" <<'FORGEPY'
import base64, os, socket, struct, sys
KEXINIT, KEX_ECDH_INIT, KEX_ECDH_REPLY = 20, 30, 31
def s_str(b): return struct.pack(">I", len(b)) + b
def pack(p):
    pad = 8 - ((len(p) + 5) % 8)
    if pad < 4: pad += 8
    return struct.pack(">IB", len(p) + 1 + pad, pad) + p + b"\0" * pad
def read_packet(f):
    hdr = f.read(5)
    if len(hdr) < 5: raise EOFError
    plen, pad = struct.unpack(">IB", hdr)
    body = f.read(plen - 1)
    return body[: len(body) - pad]
def nl(*n): return s_str(",".join(n).encode())
def handle(conn, blob):
    conn.settimeout(10)
    f = conn.makefile("rb")
    conn.sendall(b"SSH-2.0-forgery_probe\r\n")
    f.readline()
    k = bytes([KEXINIT]) + os.urandom(16) + nl("curve25519-sha256") + nl("ssh-ed25519")
    k += nl("aes128-ctr") * 2 + nl("hmac-sha2-256") * 2 + nl("none") * 2
    k += s_str(b"") * 2 + b"\0" + struct.pack(">I", 0)
    conn.sendall(pack(k))
    while True:
        p = read_packet(f)
        if p and p[0] == KEX_ECDH_INIT: break
    conn.sendall(pack(bytes([KEX_ECDH_REPLY]) + s_str(blob) + s_str(os.urandom(32))
                 + s_str(s_str(b"ssh-ed25519") + s_str(b"\0" * 64))))
with open(sys.argv[2], "rb") as fh:
    blob = base64.b64decode(fh.read().split()[1])
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", int(sys.argv[1]))); srv.listen(5)
sys.stderr.write("READY forger %s\n" % sys.argv[1]); sys.stderr.flush()
while True:
    try: conn, _ = srv.accept()
    except OSError: continue
    try: handle(conn, blob)
    except Exception: pass
    finally:
        try: conn.close()
        except OSError: pass
FORGEPY
start_forger() {
    local port="$1" pub="$2" tries
    tries=$(_bind_polls 8)
    _FIXTURE_LOG="$WORK/forge-$port.log"
    : > "$_FIXTURE_LOG"
    python3 "$FORGER" "$port" "$pub" >>"$_FIXTURE_LOG" 2>&1 &
    local pid=$!
    SSHD_PIDS+=( "$pid" )
    _await_bind "$pid" "$port" "$tries" "READY forger $port"
}

# _fixture_up <portvar> <base> <start-fn> [args-after-port...]
#
# Allocate a free port into <portvar> IMMEDIATELY before the bind, then start.
# Two things this buys, both aimed at your-org/nexus-code#769:
#
#  * the allocate→bind TOCTOU window SHRINKS — it is not eliminated, and the
#    figure matters. It was ~15 s (all five ports were picked at the TOP of this
#    file, while FORGE_PORT is not bound until case 12). It is now the cost of
#    one `pick_free_port` plus the fixture's exec: MEASURED at 99-108 ms per
#    invocation at load 54-62 on 36 cores, so the residual is TENS TO HUNDREDS
#    OF MILLISECONDS, not "milliseconds". That is a ~150x reduction, which is
#    the honest claim; a race this narrow is rare, not impossible.
#    That window is the whole exposure: these ports are host-global, and the
#    check that a port is free is only true at the instant it is made.
#  * a DEMONSTRATED seizure is retried on a fresh port rather than reported.
#    Retrying a fixture bind cannot mask a product regression — nothing under
#    test binds these ports — so this removes the flake instead of reclassifying
#    it. Only `port-seized` is retried; every other cause returns immediately.
_fixture_up() {
    local var="$1" base="$2" fn="$3"; shift 3
    local attempt port
    for (( attempt = 1; attempt <= 3; attempt++ )); do
        if ! port=$(pick_free_port "$base"); then
            _FIXTURE_EXIT="no-free-port"; _FIXTURE_LOG=""; _FIXTURE_PORT=""
            printf -v _FIXTURE_DETAIL \
                'no free port in %s-%s after 200 probes (host-global range, shared across operators).' \
                "$base" "$(( base + 899 ))"
            return 1
        fi
        printf -v "$var" '%s' "$port"
        "$fn" "$port" "$@" && return 0
        [[ "$_FIXTURE_EXIT" == "port-seized" ]] || return 1
        # EXCLUDE it, or the next `pick_free_port` hands back the same port: the
        # probe is deterministic, so without this the retry loop re-tries the
        # identical port three times and calls that three attempts. Observed
        # doing exactly that on port 33054 (your-org/nexus-code#769).
        _PORT_EXCLUDE="${_PORT_EXCLUDE:+$_PORT_EXCLUDE,}$port"
        printf '  note: fixture port %s was SEIZED between allocation and bind; excluded, retrying on a fresh port (attempt %s of 3)\n' \
            "$port" "$attempt" >&2
    done
    return 1
}

# Our host key lives where the principals dir says; the foreign daemon gets a
# DIFFERENT one, exactly as two operator nexuses on one host would.
ssh-keygen -q -t ed25519 -f "$PRINCIPALS/ssh_host_ed25519_key" -N '' || { echo "FAIL: keygen (ours)"; exit 1; }
ssh-keygen -q -t ed25519 -f "$WORK/foreign_host_key"          -N '' || { echo "FAIL: keygen (foreign)"; exit 1; }
chmod 600 "$PRINCIPALS/ssh_host_ed25519_key"
OURS_FP=$(ssh-keygen -lf "$PRINCIPALS/ssh_host_ed25519_key.pub" | awk '{print $2}')
FOREIGN_FP=$(ssh-keygen -lf "$WORK/foreign_host_key.pub" | awk '{print $2}')
assert_eq "fixture sanity: the two host keys differ" \
    "$([[ "$OURS_FP" != "$FOREIGN_FP" ]] && echo differ || echo same)" "differ"

# A FIXTURE THAT FAILS TO START IS A FAILURE, NOT A SKIP. The genuine
# missing-dependency SKIP is the gate at the top of this file (sshd / ssh-keyscan /
# ssh-keygen / python3). Past that gate, everything these need is present, so a
# failure to bind is an environment fault that INVALIDATED THE RUN — and reporting
# it as a skip collapses the suite to `1 passed, 0 failed` + `ALL TESTS PASSED`
# with rc 0, which is indistinguishable from success in any CI summary.
#
# Not hypothetical, twice over: the skeptic hit this collapse and misread it as its
# own harness (your-org/nexus-code#609 F8), and I hit it again running ten suites
# back to back — an intermittent sshd start failure under load reported ALL TESTS
# PASSED. Every guard in this file exists because "a check that cannot fail is
# believed"; a suite that cannot fail is the same defect at the file level.
# WHY THESE THREE STAY A HARD FAIL, and case 12 does not.
#
# your-org/nexus-code#769 asks whether an unstartable fixture should be `th_skip`
# with a named precondition rather than a FAIL. For case 12 the answer is yes and
# it is implemented there. For THESE fixtures it is no, for a mechanical reason
# rather than a philosophical one: they are the SUBSTRATE of cases 1-11, so
# downgrading them does not skip a case, it empties the file. The only mechanism
# the runner offers for that is a file-level `exit 77`, and run-tests.sh recovers
# a file-level SKIP's reason from `head -n 3` of the test's STDOUT
# (run-tests.sh:708) — while every diagnostic below is on stderr, hundreds of
# lines in. An `exit 77` here would therefore render as a SKIP row with an EMPTY
# reason: "a SKIP whose cause is invisible", which is what that code's own
# comment calls "how a permanently-unrun test hides in plain sight".
#
# So the downgrade is applied exactly where the runner can carry its reason —
# case-level `th_skip`, which run-tests.sh echoes verbatim from .out AND .err
# (run-tests.sh:677-684) — and nowhere else.
fixture_or_fail() {   # <description> <portvar> <base> <start-fn> [args-after-port...]
    local what="$1"; shift
    _fixture_up "$@" && return 0
    printf '  FAIL: fixture could not start: %s (port %s)\n' "$what" "${_FIXTURE_PORT:-<unallocated>}" >&2
    printf '        Dependencies were verified present at the top of this file, so this is an\n' >&2
    printf '        environment fault that INVALIDATED the run — not a missing dependency.\n' >&2
    # your-org/nexus-code#794: this site never cited a doomed path, but it lost
    # the SAME evidence by never emitting one — the sshd/stub log dies with
    # `$WORK` exactly as the forge log did. Not-citing is not better than
    # citing-a-corpse; both leave the reader with nothing. Print the contents.
    _fixture_postmortem
    FAIL=$((FAIL+1))
    th_summary_and_exit
}
fixture_or_fail "our own sshd"      OURS_PORT    31000 start_sshd "$PRINCIPALS/ssh_host_ed25519_key"
fixture_or_fail "foreign sshd"      FOREIGN_PORT 32000 start_sshd "$WORK/foreign_host_key"
fixture_or_fail "banner-only stub"  BANNER_PORT  33000 start_banner_only

register_row

# ── 1. unit: the identity verdict itself ────────────────────────────────
echo "== 1. _remote_identity_probe verdicts =="
probe_verdict() {   # <port> [extra env assignments via caller]
    bash -c "source '$LIB'; _remote_identity_probe 127.0.0.1 '$1' 5; \
             printf '%s|%s' \"\$?\" \"\$_REMOTE_ID_VERDICT\""
}
assert_eq "our own sshd → rc 0 / ours"       "$(probe_verdict "$OURS_PORT")"    "0|ours"
assert_eq "foreign sshd → rc 1 / foreign"    "$(probe_verdict "$FOREIGN_PORT")" "1|foreign"
assert_eq "banner-only → rc 1 / foreign"     "$(probe_verdict "$BANNER_PORT")"  "1|foreign"
nokey_out=$(MONITOR_REMOTE_PRINCIPALS_DIR="$WORK/nokey" bash -c \
    "source '$LIB'; _remote_identity_probe 127.0.0.1 '$OURS_PORT' 5; printf '%s|%s' \"\$?\" \"\$_REMOTE_ID_VERDICT\"")
assert_eq "no host key on disk → rc 3 / no-local-key" "$nokey_out" "3|no-local-key"
ind_out=$(REMOTE_SSH_BIN="$WORK/no-such-ssh" REMOTE_KEYSCAN_BIN="$WORK/no-such-keyscan" bash -c \
    "source '$LIB'; _remote_identity_probe 127.0.0.1 '$OURS_PORT' 5; printf '%s|%s' \"\$?\" \"\$_REMOTE_ID_VERDICT\"")
assert_eq "no ssh-keyscan → rc 2 / indeterminate" "$ind_out" "2|indeterminate"
# The globals must survive the call — the whole reason the verdict is returned
# via globals rather than stdout (the _SVC_LOCATE_AMBIGUOUS subshell bug, #608).
fps=$(bash -c "source '$LIB'; _remote_identity_probe 127.0.0.1 '$FOREIGN_PORT' 5 >/dev/null; \
               printf '%s %s' \"\$_REMOTE_ID_LIVE_FP\" \"\$_REMOTE_ID_OURS_FP\"")
assert_eq "the compared fingerprints reach the caller" "$fps" "$FOREIGN_FP $OURS_FP"

# ── 2. positive path (without this, every refusal below proves nothing) ──
echo "== 2. OUR sshd on the port → HEALTHY =="
out=$(MONITOR_REMOTE_PORT=$OURS_PORT bash "$HEALTH" 2>&1); rc=$?
assert_rc "our own sshd → healthcheck exit 0" "$rc" "0"
assert_empty "…and says nothing on the healthy path" "$out"

# ── 3. THE negative control ─────────────────────────────────────────────
echo "== 3. NEGATIVE CONTROL: a FOREIGN sshd holding our port → DOWN =="
# A real sshd, full key exchange, valid `SSH-2.0-*` banner — everything the old
# check asked for. Only the host key differs, which is the only thing that
# distinguishes another operator's daemon from ours. Asserted on the MESSAGE,
# not the exit code: an exit code cannot tell "refused for the right reason"
# from "refused because the fixture was broken".
ferr=$(MONITOR_REMOTE_PORT=$FOREIGN_PORT bash "$HEALTH" 2>&1); frc=$?
assert_rc "foreign sshd → healthcheck exit 1" "$frc" "1"
assert_contains "…names the collision explicitly"     "$ferr" "a FOREIGN sshd holds"
assert_contains "…reports the key it actually saw"    "$ferr" "$FOREIGN_FP"
assert_contains "…and the key we expected"            "$ferr" "$OURS_FP"
assert_contains "…and states OUR channel is down"     "$ferr" "OUR channel is DOWN"
assert_not_contains "…never claims a non-SSH banner"  "$ferr" "non-SSH banner"

# ── 4. the 2026-07-29 incident, verbatim ────────────────────────────────
echo "== 4. banner-only listener (the 2h30m false green) → DOWN =="
berr=$(MONITOR_REMOTE_PORT=$BANNER_PORT bash "$HEALTH" 2>&1); brc=$?
assert_rc "banner-only listener → healthcheck exit 1" "$brc" "1"
assert_contains "…names the absent host key" "$berr" "NO usable ed25519 host key"
# Stage 1 accepted it — proving the refusal comes from the IDENTITY stage and
# not from the pre-existing banner classifier.
assert_not_contains "…not misreported as a non-SSH banner" "$berr" "non-SSH banner"
assert_not_contains "…nor as a banner timeout"             "$berr" "no SSH banner within"

# ── 5. no local host key ────────────────────────────────────────────────
echo "== 5. no host key on disk + a listener present → DOWN =="
nerr=$(MONITOR_REMOTE_PRINCIPALS_DIR="$WORK/nokey" MONITOR_REMOTE_PORT=$OURS_PORT \
    bash "$HEALTH" 2>&1); nrc=$?
assert_rc "no host key → healthcheck exit 1" "$nrc" "1"
assert_contains "…says no daemon of ours can be serving" "$nerr" "no daemon of ours can be serving"
assert_contains "…and points out something IS answering" "$nerr" "so that listener is not ours"

# ── 6. the knob: it covers UNKNOWN, never VERIFIED-NOT-OURS ─────────────
echo "== 6. health_require_identity covers INDETERMINATE only =="
ierr=$(REMOTE_SSH_BIN="$WORK/no-such-ssh" REMOTE_KEYSCAN_BIN="$WORK/no-such-keyscan" MONITOR_REMOTE_PORT=$OURS_PORT \
    bash "$HEALTH" 2>&1); irc=$?
assert_rc "unverifiable identity → DOWN by default" "$irc" "1"
assert_contains "…says it cannot verify"      "$ierr" "cannot verify endpoint identity"
assert_contains "…and names the knob"         "$ierr" "health_require_identity"
ierr2=$(REMOTE_SSH_BIN="$WORK/no-such-ssh" REMOTE_KEYSCAN_BIN="$WORK/no-such-keyscan" MONITOR_REMOTE_HEALTH_REQUIRE_IDENTITY=false \
    MONITOR_REMOTE_PORT=$OURS_PORT bash "$HEALTH" 2>&1); irc2=$?
assert_rc "…knob=false accepts protocol-only evidence" "$irc2" "0"
assert_contains "…loudly, as a WARNING" "$ierr2" "identity unverified"
# THE property that makes the knob safe: it must not be able to restore the
# 2026-07-29 false green. A DEFINITE foreign verdict is not overridable.
kerr=$(MONITOR_REMOTE_HEALTH_REQUIRE_IDENTITY=false MONITOR_REMOTE_PORT=$FOREIGN_PORT \
    bash "$HEALTH" 2>&1); krc=$?
assert_rc "knob=false CANNOT green a real foreign sshd" "$krc" "1"
assert_contains "…still names the collision" "$kerr" "a FOREIGN sshd holds"
kerr2=$(MONITOR_REMOTE_HEALTH_REQUIRE_IDENTITY=false MONITOR_REMOTE_PORT=$BANNER_PORT \
    bash "$HEALTH" 2>&1); krc2=$?
assert_rc "knob=false CANNOT green a banner-only squatter" "$krc2" "1"

# ── 7. the no-flap rule survives ────────────────────────────────────────
echo "== 7. NOT registered → healthy-because-off, even on a foreign endpoint =="
deregister_row
MONITOR_REMOTE_PORT=$FOREIGN_PORT bash "$HEALTH" >/dev/null 2>&1
assert_rc "unregistered + foreign daemon → still exit 0 (no flap)" "$?" "0"
register_row

# ── 8. remote-up refuses to enable onto a foreign listener ──────────────
echo "== 8. remote-up: port-collision refusal =="
deregister_row
uerr=$(REMOTE_UP_TIMEOUT=4 MONITOR_REMOTE_PORT=$FOREIGN_PORT bash "$UP" 2>&1); urc=$?
assert_rc "remote-up onto a foreign listener → non-zero" "$urc" "1"
assert_contains "…refuses with a NAMED reason"        "$uerr" "REFUSING to enable"
assert_contains "…identifying the foreign host key"   "$uerr" "a FOREIGN sshd holds"
assert_contains "…and forbids signalling it"          "$uerr" "Do NOT kill that listener"
assert_contains "…nothing was registered or started"  "$uerr" "Nothing was registered"
rows=$(grep -c 'nexus-remote-ssh' "$NEXUS_SERVICES_REGISTRY" 2>/dev/null); rows=${rows:-0}
assert_eq "…and the registry row was NOT written" "$rows" "0"
assert_not_contains "…it never silently rebinds elsewhere" "$uerr" "binding on an alternate port"
# NEGATIVE CONTROL for case 8: the refusal must be conditioned on the endpoint
# being FOREIGN, not on "a listener exists". Our own sshd on the port is the
# idempotent re-enable case and must NOT be refused.
fixture_or_fail "second ours-sshd"  UPOK_PORT    35000 start_sshd "$PRINCIPALS/ssh_host_ed25519_key"
oerr=$(REMOTE_UP_TIMEOUT=4 MONITOR_REMOTE_PORT=$UPOK_PORT bash "$UP" 2>&1)
assert_not_contains "OUR daemon on the port is NOT a collision" "$oerr" "REFUSING to enable"
assert_contains "…it is recognised as ours"    "$oerr" "already held by OUR daemon"
orows=$(grep -c 'nexus-remote-ssh' "$NEXUS_SERVICES_REGISTRY" 2>/dev/null); orows=${orows:-0}
assert_eq "…and the row IS written" "$orows" "1"
# An unverifiable (not foreign) endpoint is the only overridable case.
ierr3=$(REMOTE_SSH_BIN="$WORK/no-such-ssh" REMOTE_KEYSCAN_BIN="$WORK/no-such-keyscan" REMOTE_UP_TIMEOUT=4 \
    MONITOR_REMOTE_PORT=$FOREIGN_PORT bash "$UP" 2>&1)
assert_contains "unverifiable holder → refuse, naming the override" "$ierr3" "REMOTE_UP_ALLOW_UNVERIFIED_PORT=1"
ferr4=$(REMOTE_UP_ALLOW_UNVERIFIED_PORT=1 REMOTE_UP_TIMEOUT=4 \
    MONITOR_REMOTE_PORT=$FOREIGN_PORT bash "$UP" 2>&1)
assert_contains "…but that override CANNOT bypass a confirmed foreign endpoint" \
    "$ferr4" "REFUSING to enable"

# ── 9. the fingerprint comes off the LIVE endpoint ──────────────────────
echo "== 9. remote-up prints the LIVE endpoint's fingerprint, not the on-disk one =="
# print_fingerprint is called directly: the `[[ BASH_SOURCE == $0 ]]` main guard
# in remote-up.sh exists so this is possible.
fp_ok=$(MONITOR_REMOTE_PORT=$OURS_PORT bash -c \
    "source '$UP' >/dev/null 2>&1; print_fingerprint" 2>&1)
assert_contains "ours: prints the fingerprint"           "$fp_ok" "$OURS_FP"
# The label must claim POSSESSION, not a read. A read is what ssh-keyscan does and
# it is forgeable; this line is the moment a human decides what to trust, so it
# must not overstate the evidence (your-org/nexus-code#609 skeptic pass).
assert_contains "…labelled as PROVED POSSESSION, not merely read" "$fp_ok" "PROVED POSSESSION"
assert_contains "…and says the signature was verified"            "$fp_ok" "signature over"
assert_not_contains "…never labels a read as verification"        "$fp_ok" "READ OFF THE LIVE ENDPOINT"
# THE case that turns this guard into a comment if it is got wrong: a foreign
# daemon holds the port. Printing OUR on-disk value here hands a client a
# fingerprint for an endpoint it will never reach, and hides the collision at
# the moment it is cheapest to catch.
fp_bad=$(MONITOR_REMOTE_PORT=$FOREIGN_PORT bash -c \
    "source '$UP' >/dev/null 2>&1; print_fingerprint" 2>&1)
assert_contains "collision: shows the LIVE (foreign) value"  "$fp_bad" "$FOREIGN_FP"
assert_contains "…flags it as a PORT COLLISION"              "$fp_bad" "PORT COLLISION"
assert_contains "…and forbids handing either value over"     "$fp_bad" "DO NOT HAND EITHER VALUE"
assert_not_contains "…never presents anything as pinnable"   "$fp_bad" "Pin this"
# Indeterminate: the on-disk value MAY be printed, but only labelled unverified.
fp_ind=$(REMOTE_SSH_BIN="$WORK/no-such-ssh" REMOTE_KEYSCAN_BIN="$WORK/no-such-keyscan" MONITOR_REMOTE_PORT=$OURS_PORT bash -c \
    "source '$UP' >/dev/null 2>&1; print_fingerprint" 2>&1)
assert_contains "unverified: labels the on-disk value as such" "$fp_ind" "ON-DISK value"
assert_contains "…and says it was not verified"                "$fp_ind" "NOT verified against the live endpoint"

# ── 10. --status carries the verdict as its own field ───────────────────
echo "== 10. remote-up --status reports the identity verdict =="
sout=$(MONITOR_REMOTE_PORT=$FOREIGN_PORT bash "$UP" --status 2>&1); src=$?
assert_rc "--status on a foreign endpoint → non-zero" "$src" "1"
assert_contains "…and reports endpoint:foreign" "$sout" "endpoint:foreign"
sout2=$(MONITOR_REMOTE_PORT=$OURS_PORT bash "$UP" --status 2>&1); src2=$?
assert_rc "--status on OUR endpoint → 0" "$src2" "0"
assert_contains "…and reports endpoint:ours" "$sout2" "endpoint:ours"
# A free port must not be reported as either.
FREE_PORT=$(pick_free_port 36000)
sout3=$(MONITOR_REMOTE_PORT=$FREE_PORT bash "$UP" --status 2>&1)
assert_contains "an unbound port reports endpoint:absent" "$sout3" "endpoint:absent"

# ── 11. the suite's own guard: a MISSING assertion helper must FAIL ─────
echo "== 11. a missing assert_* helper fails the suite instead of passing it =="
# Found while writing this file: `assert_rc` was not in _test_helpers.sh, so 14
# exit-code assertions here resolved to `command not found` and the suite still
# printed ALL TESTS PASSED. Meta-control, run in a child so it cannot pollute
# this suite's counters: a suite calling an undefined assert_* must exit 1.
cat >"$WORK/meta-suite.sh" <<META
#!/usr/bin/env bash
set -uo pipefail
. "$_test_dir/_test_helpers.sh"
assert_eq "a real assertion still passes" "x" "x"
assert_this_helper_does_not_exist "label" "a" "b"
th_summary_and_exit
META
meta_out=$(bash "$WORK/meta-suite.sh" 2>&1); meta_rc=$?
assert_rc "a suite calling an undefined assert_* exits 1" "$meta_rc" "1"
assert_contains "…and says which helper was missing" "$meta_out" "MISSING TEST HELPER"
assert_not_contains "…and does NOT claim all tests passed" "$meta_out" "ALL TESTS PASSED"
# Negative control for the handler: a missing NON-assert command keeps stock
# behaviour, so no existing suite that probes for an absent binary changes.
cat >"$WORK/meta-suite2.sh" <<META2
#!/usr/bin/env bash
set -uo pipefail
. "$_test_dir/_test_helpers.sh"
some-binary-that-does-not-exist >/dev/null 2>&1 || true
assert_eq "an absent non-assert command is not a suite failure" "ok" "ok"
th_summary_and_exit
META2
meta2_out=$(bash "$WORK/meta-suite2.sh" 2>&1); meta2_rc=$?
assert_rc "a missing NON-assert command does not fail the suite" "$meta2_rc" "0"
assert_contains "…the suite still reports success" "$meta2_out" "ALL TESTS PASSED"

# ── 12. THE KEY-CLAIM REGRESSION (your-org/nexus-code#609 skeptic pass) ──
echo "== 12. a server that CLAIMS our host key without holding it is REJECTED =="
# FATAL, not skippable. This is the decisive regression test for the defect the
# #609 skeptic pass found, and the suite already gated on python3 at the top, so
# the forger has everything it needs. An earlier draft printed a note and
# continued — i.e. the one test that proves a key READ is not a key VERIFICATION
# could silently vanish and the suite would still report ALL TESTS PASSED. That is
# the same "a guard that cannot fail" shape this whole suite exists to prevent,
# and it also made CI green unable to testify that this case ran at all.
if ! _fixture_up FORGE_PORT 37000 start_forger "$PRINCIPALS/ssh_host_ed25519_key.pub"; then
    # your-org/nexus-code#769 half 2. A fixture the HOST could not supply is
    # "not covered"; it is not "the product is broken". But that downgrade is
    # only honest when the precondition is NAMED and CLASSIFIED from evidence,
    # so it is gated on `_fixture_env_fault` — an allowlist (port seized, bind
    # ceiling, no free port) with a default-DENY arm. A broken forge.py, a bad
    # pubkey, a python that will not run: all still FAIL, loudly.
    #
    # THE SAFETY ARGUMENT, which is what makes this legitimate: no product
    # regression can present as "the forger did not bind". `forge.py` is written
    # by this suite, takes a port and a pubkey, and shares nothing with the code
    # under test — `_remote_lib.sh`, `remote-ssh-health.sh` and `remote-up.sh`
    # never bind FORGE_PORT and never read forge.py. The impersonation property
    # itself lives in assertions (a)-(g) below, which run only when the forger IS
    # up, and are untouched by this branch. A negative control that breaks the
    # identity probe and confirms the suite still reddens is the check.
    if _fixture_env_fault; then
        th_skip "case 12 — the key-claim (impersonation) regression" \
            "the forging fixture could not be started on this host after 3 port attempts: $_FIXTURE_DETAIL"
        printf '        THIS CASE WAS NOT MEASURED. It is the decisive your-org/nexus-code#609\n' >&2
        printf '        regression test; a run that skips it has NOT shown that a key-claiming\n' >&2
        printf '        forger is rejected. Skipped rather than failed only because the cause\n' >&2
        printf '        above is attributable to the host, not to the code under test.\n' >&2
    else
        printf '  FAIL: the forging fixture could not start — case 12 did NOT run\n' >&2
        printf '        (python3 is present, so this is not a missing dependency, and the\n' >&2
        printf '         cause below is NOT one this suite may attribute to the host.)\n' >&2
        FAIL=$((FAIL+1))
    fi
    # your-org/nexus-code#794: this block used to read `see $WORK/forge-<port>.log`
    # — a file the EXIT trap deletes before any reader exists. Contents, not path.
    _fixture_postmortem
else
    # (a) THE DEFECT, demonstrated: ssh-keyscan ACCEPTS the forged endpoint and
    #     reports OUR OWN key blob, byte for byte. This assertion documents why the
    #     verdict must not come from a key READ. If it ever starts failing,
    #     ssh-keyscan's behaviour changed and this design note can be revisited.
    claimed=$(bash -c "source '$LIB'; _remote_live_host_key 127.0.0.1 '$FORGE_PORT' 6")
    expected=$(bash -c "source '$LIB'; _remote_expected_host_key")
    assert_eq "ssh-keyscan ACCEPTS the forgery and echoes our own key" "$claimed" "$expected"

    # (b) THE FIX: the signature-verifying probe rejects it as a forgery.
    v=$(bash -c "source '$LIB'; _remote_verify_live_host_key 127.0.0.1 '$FORGE_PORT' 6; \
                 printf '%s|%s' \"\$?\" \"\$_REMOTE_VERIFY_DETAIL\"")
    assert_eq "the verifying probe returns rc 3 (forgery)" "${v%%|*}" "3"
    assert_contains "…naming the failed signature check" "$v" "FAILED the signature check"

    # (c) The verdict is FOREIGN, never `ours`. This is the whole point.
    fv=$(bash -c "source '$LIB'; _remote_identity_probe 127.0.0.1 '$FORGE_PORT' 6; \
                  printf '%s|%s' \"\$?\" \"\$_REMOTE_ID_VERDICT\"")
    assert_eq "identity verdict on a key-claiming forger → rc 1 / foreign" "$fv" "1|foreign"

    # (d) The healthcheck is UNHEALTHY and says IMPERSONATION, not "collision" —
    #     an accidental collision presents its OWN key; this one replayed ours.
    gerr=$(MONITOR_REMOTE_PORT=$FORGE_PORT bash "$HEALTH" 2>&1); grc=$?
    assert_rc "forger on our port → healthcheck exit 1" "$grc" "1"
    assert_contains "…named as IMPERSONATION"            "$gerr" "IMPERSONATION"
    assert_contains "…stating it does not hold the key"  "$gerr" "does NOT hold the private key"

    # (e) NOT overridable. A forgery is a DEFINITE not-ours, so the
    #     indeterminate-only knob must not green it.
    kerr3=$(MONITOR_REMOTE_HEALTH_REQUIRE_IDENTITY=false MONITOR_REMOTE_PORT=$FORGE_PORT \
        bash "$HEALTH" 2>&1); krc3=$?
    assert_rc "knob=false CANNOT green a key-claiming forger" "$krc3" "1"

    # (f) remote-up refuses to enable onto it.
    deregister_row
    uferr=$(REMOTE_UP_TIMEOUT=4 MONITOR_REMOTE_PORT=$FORGE_PORT bash "$UP" 2>&1)
    assert_contains "remote-up REFUSES to enable onto a forger" "$uferr" "REFUSING to enable"
    ufrows=$(grep -c 'nexus-remote-ssh' "$NEXUS_SERVICES_REGISTRY" 2>/dev/null); ufrows=${ufrows:-0}
    assert_eq "…and registers nothing" "$ufrows" "0"
    register_row

    # (g) NEGATIVE CONTROL for the forgery classification: a banner-only squatter
    #     must NOT be accused of impersonation. It is an accident, not an attack,
    #     and `ssh` reports BOTH through an `ssh_dispatch_run_fatal:` prefix — an
    #     earlier draft matched that generic prefix and libelled every squatter.
    berr2=$(MONITOR_REMOTE_PORT=$BANNER_PORT bash "$HEALTH" 2>&1)
    assert_not_contains "a banner-only squatter is NOT called an IMPERSONATION" "$berr2" "IMPERSONATION"
    assert_contains "…it is reported as an ordinary foreign listener" "$berr2" "NO usable ed25519 host key"
fi

# ── 13. unit: the verifying probe's other verdicts ──────────────────────
echo "== 13. _remote_verify_live_host_key verdicts =="
vp() { bash -c "source '$LIB'; _remote_verify_live_host_key 127.0.0.1 '$1' 6; echo \$?"; }
assert_eq "our own sshd → rc 0 (signature verified)" "$(vp "$OURS_PORT")"    "0"
assert_eq "a real sshd with another key → rc 1"      "$(vp "$FOREIGN_PORT")" "1"
assert_eq "banner-only listener → rc 1 (definite, not overridable)" "$(vp "$BANNER_PORT")" "1"
FREE2=$(pick_free_port 38000)
assert_eq "nothing listening → rc 2 (unknown)"       "$(vp "$FREE2")"        "2"
assert_eq "no ssh client → rc 2 (unknown)" \
    "$(REMOTE_SSH_BIN=/nonexistent/ssh bash -c "source '$LIB'; _remote_verify_live_host_key 127.0.0.1 '$OURS_PORT' 6; echo \$?")" "2"

# ── 14. F9: the terminal fall-through must be DEFINITE, not overridable ──
echo "== 14. an UNCLASSIFIABLE probe result is definite-foreign, never overridable =="
# The forgery/handshake/unreachable arms are pattern matches on `ssh`'s message, so
# a wording this code has never seen is always possible — an OpenSSH release, a
# distro patch, a locale. The design's stated safety asymmetry is that the
# health_require_identity knob can NEVER green a confirmed not-ours, so the
# terminal arm has to be rc 1. It used to be rc 2 (indeterminate = overridable),
# which meant an unlisted BAD-SIGNATURE wording read HEALTHY with the knob off —
# your-org/nexus-code#609 finding F9. The banner stage does not save us there: a
# forger sends a perfectly good SSH-2.0 banner, so stage 2 always runs.
#
# Simulated through the REMOTE_SSH_BIN seam rather than by neutering the patterns,
# so the test exercises the real classifier.
cat > "$WORK/ssh-gibberish" <<'STUB'
#!/usr/bin/env bash
echo "totally unrecognised diagnostic from a future openssh" >&2
exit 255
STUB
chmod +x "$WORK/ssh-gibberish"
gib=$(REMOTE_SSH_BIN="$WORK/ssh-gibberish" bash -c \
    "source '$LIB'; _remote_verify_live_host_key 127.0.0.1 '$OURS_PORT' 6; \
     printf '%s|%s' \"\$?\" \"\$_REMOTE_VERIFY_DETAIL\"")
assert_eq "unclassifiable ssh output → rc 1 (DEFINITE), not rc 2" "${gib%%|*}" "1"
assert_contains "…and says it reached the listener but could not verify" "$gib" "could not verify it is ours"
gidv=$(REMOTE_SSH_BIN="$WORK/ssh-gibberish" bash -c \
    "source '$LIB'; _remote_identity_probe 127.0.0.1 '$OURS_PORT' 6; \
     printf '%s|%s' \"\$?\" \"\$_REMOTE_ID_VERDICT\"")
assert_eq "…so the identity verdict is foreign, not indeterminate" "$gidv" "1|foreign"
# THE ASSERTION THAT WOULD HAVE CAUGHT F9: knob off + unclassifiable result.
g1=$(REMOTE_SSH_BIN="$WORK/ssh-gibberish" MONITOR_REMOTE_PORT=$OURS_PORT \
    bash "$HEALTH" 2>&1); g1rc=$?
assert_rc "knob DEFAULT + unclassifiable → UNHEALTHY" "$g1rc" "1"
g2=$(REMOTE_SSH_BIN="$WORK/ssh-gibberish" MONITOR_REMOTE_HEALTH_REQUIRE_IDENTITY=false \
    MONITOR_REMOTE_PORT=$OURS_PORT bash "$HEALTH" 2>&1); g2rc=$?
assert_rc "knob OFF + unclassifiable → STILL UNHEALTHY (F9)" "$g2rc" "1"
assert_not_contains "…never accepts protocol-only evidence for it" "$g2" "accepting protocol-only evidence"
# NEGATIVE CONTROL: rc 2 must still exist for GENUINE unknowns, or the fix above
# would just be "return 1 always" and the knob would be dead code.
cat > "$WORK/ssh-refused" <<'STUB2'
#!/usr/bin/env bash
echo "ssh: connect to host 127.0.0.1 port 1: Connection refused" >&2
exit 255
STUB2
chmod +x "$WORK/ssh-refused"
assert_eq "a genuine unreachable STILL returns rc 2" \
    "$(REMOTE_SSH_BIN="$WORK/ssh-refused" bash -c "source '$LIB'; _remote_verify_live_host_key 127.0.0.1 '$OURS_PORT' 6; echo \$?")" "2"
assert_eq "…and no ssh client STILL returns rc 2" \
    "$(REMOTE_SSH_BIN=/nonexistent/ssh bash -c "source '$LIB'; _remote_verify_live_host_key 127.0.0.1 '$OURS_PORT' 6; echo \$?")" "2"
# PIN THE rc-2 BOUNDARY. This is the residual risk I flagged to the skeptic when
# moving the terminal arm to rc 1: the danger is not a missed foreign endpoint (that
# direction now fails closed) but a GENUINE unknown misfiled as definite-foreign,
# which costs availability and is the direction I would be least likely to notice.
# Contract: rc 2 means "could not reach it, or a tooling/environment fault"; rc 1
# means "reached a listener and could not verify it is ours". These assertions are
# the whole rc-2 surface, so a future arm that drifts across the line trips one.
assert_eq "no host key on disk → verify rc 2 (we cannot even ask)" \
    "$(MONITOR_REMOTE_PRINCIPALS_DIR="$WORK/nokey2" bash -c "source '$LIB'; _remote_verify_live_host_key 127.0.0.1 '$OURS_PORT' 6; echo \$?")" "2"
# …while the identity probe answers rc 3 for the same state, because IT checks the
# local key first and "we hold no key, yet something is answering" IS definite.
# Deliberate asymmetry between the two functions, pinned so it stays deliberate.
assert_eq "…but the identity probe calls that state definite (rc 3)" \
    "$(MONITOR_REMOTE_PRINCIPALS_DIR="$WORK/nokey2" bash -c "source '$LIB'; _remote_identity_probe 127.0.0.1 '$OURS_PORT' 6; echo \$?")" "3"


th_summary_and_exit
