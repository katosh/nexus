#!/usr/bin/env bash
# Tests for monitor/proc-exists-authorized — "is the job I am waiting on still
# running?", answered by session ownership and pid identity rather than by a
# command-line string (your-org/nexus-code#1073).
#
# THE DEFECT IT CLOSES. A process-EXISTENCE predicate keyed on a command line
# matches SIBLING AGENTS' argv, because agent prompts quote verbatim the thing
# being watched. `until ps -eo args= | grep -q '[g]uards-for-diff'` matched
# THREE processes while the awaited job ran — two of them `claude`, holding the
# string in their prompts. Bracketing stops the observer matching itself and
# does nothing about siblings.
#
# What these tests are for, in order of what they would actually catch:
#
#   1. THE SIBLING CASE, simulated with a REAL foreign-session process rather
#      than a mock, because it is the case that decided the design. It is
#      paired with a POTENCY leg proving the naive predicate DOES see the same
#      plant — an exclusion test whose plant is invisible to the thing being
#      replaced proves nothing.
#   2. THE REFUSAL TO ANSWER `--until-gone --match`. That combination is the
#      MANUFACTURED-SUCCESS direction (a setsid job is invisible to a
#      session-scoped match and would read as gone instantly), and the refusal
#      is the whole design rather than a rough edge.
#   3. BOTH LOOP DIRECTIONS AND THE THIRD ANSWER. A two-valued predicate is
#      read backwards by one of `until`/`while`; rc 3 (REFUSED) must be neither,
#      and must STOP a wait rather than spin it.
#   4. PID IDENTITY, not liveness. A recycled pid must not read as `running`.
#
# Run: bash monitor/watcher/test-proc-exists-authorized.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

# THIS FILE CONTAINS ARGV-KEYED PROCESS LOOKUPS, DELIBERATELY, AND THEY ARE
# NOT INSTANCES OF THE CLASS IT CLOSES. `setsid` forks, so `$!` is the
# intermediate shell rather than the decoy, and the decoy's pid can only be
# recovered by looking. What makes that safe here is the axis the defect varies
# on: the pattern is a RUNTIME nonce (`$$` plus nanoseconds), so it appears in
# no file, no prompt and no sibling's argv, and the population it can match is
# exactly one process this suite created. Everything is then SIGNALLED by the
# recorded pid, never by the pattern. The hazard is a predicate whose string
# also describes the thing; a nonce minted after every agent on the host
# started cannot.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HELPER="$_test_dir/../proc-exists-authorized"

# The SHARED assertion ledger (your-org/nexus-code#805): the in-memory counters
# die in a subshell, the ledger is a file and survives.
# shellcheck source=_test_helpers.sh
. "$_test_dir/_test_helpers.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$*"; _th_pass; }
fail() { printf '  FAIL: %s\n' "$*" >&2; _th_fail; }

# assert_rc <label> <want-rc> <cmd…> — asserts the rc AND captures output in
# $OUT for a follow-on verdict check. rc alone would pass against a tool that
# is right by accident.
OUT=""
assert_rc() {
    local label="$1" want="$2"; shift 2
    local rc
    OUT=$("$@" 2>&1); rc=$?
    if (( rc == want )); then
        pass "$label -> rc=$rc"
    else
        fail "$label -> rc=$rc, want $want (out: $OUT)"
    fi
}
assert_out() { # <label> <substring>
    if [[ -z "${2:-}" ]]; then
        fail "$1 — EMPTY needle: \`*\"\"*\` matches any string, so this assertion could
      only have passed VACUOUSLY (your-org/nexus-code#1110). Fix the CALLER: its
      expected value came back empty; check the rc of whatever produced it."
        return
    fi
    if [[ "$OUT" == *"$2"* ]]; then
        pass "$1"
    else
        fail "$1 (out: $OUT)"
    fi
}
assert_out_absent() { # <label> <substring>
    if [[ "$OUT" != *"$2"* ]]; then
        pass "$1"
    else
        fail "$1 — unexpectedly present (out: $OUT)"
    fi
}

_kids=""
cleanup() {
    # ONLY recorded pids, never a pattern. This suite is about the hazard of
    # matching processes by name; building its own teardown that way would be
    # absurd (your-org/nexus-code#851).
    local k
    for k in $_kids; do kill "$k" 2>/dev/null; done
}
trap cleanup EXIT

[[ -x "$HELPER" ]] || { echo "FATAL: helper not executable: $HELPER" >&2; exit 1; }

# A nonce that cannot collide with anything else on the host. It appears in
# THIS shell's argv too, which is the point of T5.
NONCE="pea$$x$(date +%N | tail -c 6)"

echo "=== T1: pid modes — existence, and IDENTITY, not just liveness ==="
# THE BARE-PID ARM (your-org/nexus-code#1351). This used to assert rc 0
# `running` for `--pid $$` with no start-time — the tool WROTE
# `identity=unverified` into DETAIL and answered PRESENT anyway. On a recycled
# pid that is the 5h20m wedge through the tool's own preferred handle. An
# OCCUPIED number with no identity is REFUSED; the number alone is not the job.
assert_rc "a bare --pid on an OCCUPIED number is REFUSED, not answered" 3 "$HELPER" --pid "$$"
assert_out "  …as refused"                        "verdict=refused"
assert_out "  …naming the missing input"          "no-start-time-given"
assert_out_absent "  …and never as running"       "verdict=running"
# An EMPTY start-time is the omission wearing a flag: #1351 was reached by a
# wrong state filename yielding "" and silently disarming the guard.
assert_rc "an EMPTY --start-time is the same refusal"  3 "$HELPER" --pid "$$" --start-time ""
# The escape is EXPLICIT: omission is a decision, not a default.
assert_rc "--unsafe-no-identity answers running on request" 0 "$HELPER" --pid "$$" --unsafe-no-identity
assert_out "  …and says the identity was waived, not verified" "identity=UNVERIFIED-by-request"
assert_rc "an impossible pid is ABSENT"       1 "$HELPER" --pid 4194304
assert_out "  …positively, as no-such-pid"      "no-such-pid"
# pid 1 is init: not-a-pid, and REFUSED (3) rather than answered. "Could not
# look" must never collapse into "looked and found nothing".
assert_rc "pid 1 is REFUSED, not answered"    3 "$HELPER" --pid 1
assert_out "  …with the refusal named"          "verdict=refused"

# THE RECYCLED-PID DIRECTION. `kill -0 $pid` answers "is SOME process alive at
# that number"; a reused pid would turn a died into a confident running.
_ST=$(awk '{n=index($0,") "); r=substr($0,n+2); split(r,a," "); print a[20]}' "/proc/$$/stat")
assert_rc "correct start-time verifies identity" 0 "$HELPER" --pid "$$" --start-time "$_ST"
assert_out "  …and says so"                       "identity=verified"
assert_rc "a WRONG start-time reads as absent"  1 "$HELPER" --pid "$$" --start-time 1
assert_out "  …naming the recycle, not a liveness answer" "recycled"

echo "=== T2: --match is SESSION-SCOPED — an owned process is found ==="
( exec -a "owned_${NONCE}_decoy" sleep 60 ) & _owned=$!; _kids="$_kids $_owned"
sleep 1
assert_rc "a decoy in MY session is present"  0 "$HELPER" --match "$NONCE"
assert_out "  …and its pid is named"            "owned_pids=$_owned"
OUT=$("$HELPER" --match "$NONCE" --list 2>/dev/null | grep -c "^${_owned}$")
if [[ "$OUT" == "1" ]]; then pass "--list emits the owned pid"; else fail "--list did not emit $_owned (got $OUT)"; fi
kill "$_owned" 2>/dev/null; wait "$_owned" 2>/dev/null || true

echo "=== T2b: A MALFORMED ERE IS REFUSED, NEVER ABSENT (F1) ==="
# THE DEFECT THIS PINS. The scan loop was `[[ "$argv" =~ $re ]] || continue`.
# bash returns 2 on a MALFORMED regex and 1 on a well-formed non-match, and
# `|| continue` fused them — so an invalid ERE scanned nothing and returned
# `absent` at rc 1, the code this tool defines as "positively established".
# `#1073`'s own defect class, inside the tool that closes it, surviving 46
# passing assertions because every one of them used a valid regex. An error
# path fused into a data path is invisible to every test that exercises only
# the data path.
( exec -a "ere_${NONCE}_decoy" sleep 60 ) & _ere=$!; _kids="$_kids $_ere"
sleep 1
# THE PAIR, on ONE live process, which is what makes this more than an rc check:
# two spellings of the same intent must not give opposite ANSWERS.
assert_rc "a valid ERE finds the live owned process"    0 "$HELPER" --match "ere_${NONCE}"
assert_out "  …as running"                                "verdict=running"
assert_rc "the SAME process under a MALFORMED ERE REFUSES" 3 "$HELPER" --match "ere_${NONCE}["
assert_out "  …naming the cause, not a phantom absence"   "invalid-ere"
assert_out_absent "  …and never claims an absence"        "verdict=absent"
assert_rc "an unbalanced paren refuses too"             3 "$HELPER" --match "a(b"
# THE OTHER POLARITY, and it is the one a careless fix breaks: a VALID pattern
# that genuinely matches nothing must still be ABSENT (rc 1), not refused.
# A tool that refused everything would pass every assertion above.
assert_rc "a VALID pattern matching nothing is still ABSENT" 1 "$HELPER" --match "zzz-nothing-${NONCE}"
assert_out "  …at the absent verdict, not refused"        "verdict=absent"
# In a WAIT, the refusal must stop the loop — not spin, and not time out at
# rc 4, which would report a budget failure for a question never asked.
assert_rc "a malformed ERE in a wait REFUSES rather than timing out" 3 \
    "$HELPER" --until-present --match "ere_${NONCE}[" --timeout 30 --interval 2
assert_out "  …immediately, having waited 0s"             "waited=0s"
kill "$_ere" 2>/dev/null; wait "$_ere" 2>/dev/null || true

echo "=== T3: THE SIBLING CASE — a foreign-session match is NOT ours ==="
# `setsid` puts the decoy in its OWN session, which is exactly the relationship
# a sibling agent's `claude` has to us: a process can LEAVE your session, never
# JOIN it. This stands in for the sibling because the property is identical and
# spawning a real second agent is not something a unit test may do.
FNONCE="pef$$x$(date +%N | tail -c 6)"
setsid bash -c "exec -a foreign_${FNONCE}_decoy sleep 60" >/dev/null 2>&1 &
sleep 1
    # NO `exit` in the awk and no `| head`: both are EARLY-EXIT READERS, which
    # under this file's `pipefail` turn the upstream SIGPIPE into the
    # pipeline's status (your-org/nexus-code#622). Drain, then take the first
    # line in the shell.
_foreign=$(ps -eo pid=,args= | awk -v n="foreign_${FNONCE}_decoy" 'index($0,n){print $1}')
_foreign=${_foreign%%$'\n'*}
if [[ -z "$_foreign" ]]; then
    th_skip "sibling-plant" "could not plant a foreign-session decoy on this host"
else
    _kids="$_kids $_foreign"
    # POTENCY FIRST. An exclusion test whose plant the naive predicate cannot
    # see proves nothing at all — it would pass against a helper that always
    # answers absent. Show the thing being replaced DOES match it.
    _naive=$(ps -eo pid=,args= | grep -c "foreign_${FNONCE}_decoy" || true)
    if (( _naive >= 1 )); then
        pass "POTENCY: the naive ps|grep DOES see the foreign plant ($_naive hit(s))"
    else
        fail "POTENCY FAILED: naive ps|grep cannot see the plant — T3 is vacuous"
    fi
    assert_rc "a foreign-session match is not ours -> absent" 1 "$HELPER" --match "$FNONCE"
    assert_out "  …owned_pids=none"                             "owned_pids=none"
    assert_out "  …and the unowned hit is COUNTED, not hidden"  "unowned=1"
    assert_out "  …and said out loud, as a refusal to guess"    "NOTHING OWNED matched"
    assert_out "  …naming the setsid trap that looks identical" "setsid-detached"
    assert_out "  …and pointing at the handle form"             "--token"
    kill "$_foreign" 2>/dev/null
fi

echo "=== T4: a pattern nobody is running is a CLEAN absent ==="
assert_rc "no such process -> absent" 1 "$HELPER" --match "zzz-no-such-process-$NONCE"
assert_out "  …with nothing unowned to report" "unowned=0"
assert_out_absent "  …and no loud advisory"    "NOTHING OWNED matched"

echo "=== T5: the OBSERVER cannot match itself ==="
# $NONCE is in THIS shell's argv (it was interpolated into the command line),
# and in the helper's own argv. `ps | grep` would count both. `scanned_hits`
# proves the scan LOOKED and saw them; `owned_pids=none` proves they were
# excluded as self/ancestors rather than never examined — the distinction a
# bare zero cannot make.
OUT=$("$HELPER" --match "$NONCE" 2>&1) || true
_hits=$(printf '%s' "$OUT" | sed -n 's/.*scanned_hits=\([0-9]*\).*/\1/p')
if (( ${_hits:-0} >= 1 )); then
    pass "the scan saw $_hits argv hit(s) it then excluded (not a blind zero)"
else
    fail "scanned_hits=$_hits — the exclusion cannot be distinguished from not looking"
fi
assert_out "  …and reports none owned" "owned_pids=none"

echo "=== T6: --until-gone REFUSES --match. This is the design, not an edge ==="
assert_rc "--until-gone --match is refused at rc 2" 2 "$HELPER" --until-gone --match "$NONCE"
assert_out "  …naming the manufactured-success direction" "MANUFACTURED-SUCCESS"
assert_out "  …and handing over the two handle forms"     "--until-gone --token"
# THE OTHER POLARITY: --until-present --match is SOUND and must NOT be refused.
# A fix that refused both would be a prohibition, not a design.
assert_rc "--until-present --match is ALLOWED (times out, not refused)" 4 \
    "$HELPER" --until-present --match "zzz-nothing-$NONCE" --timeout 2 --interval 1
assert_out "  …and says TIMEOUT rather than answering" "verdict=timeout"

echo "=== T7: the wait modes own the loop, in both directions ==="
( exec -a "wait_${NONCE}_decoy" sleep 60 ) & _w=$!; _kids="$_kids $_w"
sleep 1
_wst=$(awk '{n=index($0,") "); r=substr($0,n+2); split(r,a," "); print a[20]}' "/proc/$_w/stat")
assert_rc "--until-present resolves an already-present pid (with identity)" 0 \
    "$HELPER" --until-present --pid "$_w" --start-time "$_wst" --timeout 5 --interval 1
# #1351: a BARE --pid on an occupied number must STOP the wait at rc 3 — not
# time out at rc 4 (which is how this read before: `verdict=timeout …
# identity=unverified-no-start-time-given`), and never spin on a recycled pid.
assert_rc "--until-gone on an OCCUPIED bare pid REFUSES instead of spinning" 3 \
    "$HELPER" --until-gone --pid "$_w" --timeout 5 --interval 1
assert_out "  …immediately, having waited 0s"     "waited=0s"
kill "$_w" 2>/dev/null; wait "$_w" 2>/dev/null || true
assert_rc "--until-gone resolves an already-dead pid" 0 \
    "$HELPER" --until-gone --pid 4194304 --timeout 5 --interval 1
assert_rc "--until-present TIMES OUT on a dead pid rather than hanging" 4 \
    "$HELPER" --until-present --pid 4194304 --timeout 2 --interval 1

echo "=== T8: REFUSED stops a wait, it does not spin on it ==="
# The wedge this tool exists to prevent is a loop polling an unanswerable
# predicate. rc 3 must terminate the wait, and must not be reachable only via
# the one-shot path.
assert_rc "an unresolvable token REFUSES (one-shot)" 3 "$HELPER" --token ar-no-such-token
assert_out "  …as refused, not absent"                "verdict=refused"
assert_rc "…and a WAIT on it stops rather than spinning" 3 \
    "$HELPER" --until-present --token ar-no-such-token --timeout 30 --interval 1
assert_out "  …saying why it stopped"                 "REFUSED after"

echo "=== T8b/T8c: --token against REAL async-run jobs — running, DIED, TERMINAL ==="
# your-org/nexus-code#1278. This used to be ONE fixture and ONE assertion:
#
#     if (( _trc == 1 )) && [[ "$OUT" == *"verdict=terminal"* || "$OUT" == *"verdict=died"* ]]; then
#         pass "a finished async-run token reads rc=1 and keeps terminal/died distinct"
#
# The fixture killed its job, so the resolver answered `died` every time and
# the `terminal` half of that disjunction was UNREACHABLE — line coverage
# measured `_resolve_token`s terminal arm executed ZERO times across the whole
# suite. A mutant making `terminal` report `running` and return 0 — which would
# hang every `--until-gone --token` wait, the form this repo prescribes as the
# ONLY sound way to await a detached job — left the suite at 56 passed, 0
# failed.
#
# A DISJUNCTION CANNOT ESTABLISH A DISTINCTION. `A or B` is satisfied by a tool
# that only ever says B, which is precisely what was happening, and the label
# claimed the opposite. So the two verdicts now get two fixtures that can each
# produce ONLY their own half, and each asserts the other verdict ABSENT:
#
#   job R  `sleep 30`, then SIGKILL   -> no status file can be written -> died
#   job T  `sleep 1`,  left alone     -> status file IS written        -> terminal
#
# SIGKILL rather than SIGTERM is load-bearing: the runner writes its status on a
# trap-free straight line after the payload, so only an uncatchable signal can
# guarantee the file never appears. And the status file's presence/absence is
# asserted as a PRECONDITION on each fixture, so "this fixture could only have
# produced its own verdict" is measured rather than argued.
_ASWORK=$(mktemp -d -t nexus-pea-XXXXXX)
_pea_launch() {   # <desc> <cmd…> -> echoes the token, empty on failure
    local _d="$1"; shift
    local _o _t
    _o=$(NEXUS_STATE_DIR="$_ASWORK" NEXUS_WORKER_WINDOW="pea-test" \
         bash "$_test_dir/../async-run.sh" --desc "$_d" -- "$@" 2>&1) || true
    _t=$(printf '%s' "$_o" | sed -n 's/^[[:space:]]*token[[:space:]]*\(ar-[0-9a-f]*\).*/\1/p')
    printf '%s' "${_t%%$'\n'*}"
}
_pea_probe() {    # <args…> -> sets OUT and _trc
    OUT=$(NEXUS_STATE_DIR="$_ASWORK" NEXUS_WORKER_WINDOW="pea-test" "$HELPER" "$@" 2>&1); _trc=$?
}
# Every leg skips individually when the host cannot run the fixture, so this
# case contributes the SAME count either way and the suite keeps ONE expected
# total rather than a disjunction over several — the shape this case is about.
_pea_skip_legs() { local r="$1" n="$2" i; for (( i=1; i<=n; i++ )); do th_skip "async-token-leg-$i" "$r"; done; }

if ! command -v setsid >/dev/null 2>&1; then
    _pea_skip_legs "setsid unavailable — async-run.sh cannot launch here" 12
else
    _tokR=$(_pea_launch "pea died probe" sleep 30)
    _tokT=$(_pea_launch "pea terminal probe" sleep 1)
    if [[ -z "$_tokR" || -z "$_tokT" ]]; then
        _pea_skip_legs "async-run.sh did not mint a token here (R='${_tokR:-}' T='${_tokT:-}')" 12
    else
        _dirR="$_ASWORK/async-run/pea-test/$_tokR"
        _dirT="$_ASWORK/async-run/pea-test/$_tokT"

        # ---- job R, while it is still running -----------------------------
        _pea_probe --token "$_tokR"
        if (( _trc == 0 )); then pass "a RUNNING async-run token is present -> rc=0"
        else fail "a RUNNING async-run token gave rc=$_trc (out: $OUT)"; fi
        assert_out "  …and says running" "verdict=running"

        # ---- job R -> DIED ------------------------------------------------
        # By RECORDED PID, never by a pattern: this suite is about the hazard of
        # matching processes by name. The payload is reaped through the runner's
        # /proc children list, so nothing is left behind.
        _pidR=$(cat "$_dirR/pid" 2>/dev/null || true)
        _kidsR=$(cat "/proc/$_pidR/task/$_pidR/children" 2>/dev/null || true)
        _kids="$_kids $_pidR $_kidsR"
        [[ -n "$_pidR" ]] && kill -9 $_pidR $_kidsR 2>/dev/null
        _d=0; while (( _d < 20 )); do
            [[ -d "/proc/$_pidR" ]] || break
            sleep 0.25; _d=$(( _d + 1 ))
        done
        # PRECONDITION: this fixture CANNOT produce `terminal`, because the
        # status file it would be read from does not exist.
        if [[ ! -s "$_dirR/status" ]]; then
            pass 'fixture R: SIGKILLed before any status file was written — terminal is UNREACHABLE for it'
        else
            fail 'fixture R wrote a status file anyway; it can no longer isolate died'
        fi
        _pea_probe --token "$_tokR"
        if (( _trc == 1 )); then pass "…and a job killed before it could report reads rc=1"
        else fail "the killed token gave rc=$_trc (out: $OUT)"; fi
        assert_out        "  …as DIED, named"              "verdict=died"
        assert_out_absent "  …and never as terminal"       "verdict=terminal"

        # ---- job T -> TERMINAL --------------------------------------------
        _d=0; while (( _d < 40 )); do
            [[ -s "$_dirT/status" ]] && break
            sleep 0.25; _d=$(( _d + 1 ))
        done
        # PRECONDITION: this fixture CANNOT produce `died`, which is DEFINED as
        # the recorded pid gone AND no status file written.
        if [[ -s "$_dirT/status" ]]; then
            pass 'fixture T: ran to completion and wrote its status — died is UNREACHABLE for it'
        else
            fail 'fixture T never wrote a status file; terminal cannot be reached and this case proves nothing'
        fi
        _pea_probe --token "$_tokT"
        if (( _trc == 1 )); then pass "a job that FINISHED reads rc=1 (not running, not an error)"
        else fail "the finished token gave rc=$_trc (out: $OUT)"; fi
        assert_out        "  …as TERMINAL, named"          "verdict=terminal"
        assert_out_absent "  …and never as died"           "verdict=died"
        # THE PRESCRIBED WAIT, end to end. `--until-gone --token` is the only
        # form this repo endorses for awaiting a detached job, and `terminal` is
        # its NORMAL resolution — so it is asserted at the exit code a caller
        # actually branches on, not only through the one-shot path.
        _pea_probe --until-gone --token "$_tokT" --timeout 10 --interval 1
        if (( _trc == 0 )); then pass "--until-gone --token RESOLVES on a finished job -> rc=0"
        else fail "--until-gone --token gave rc=$_trc on a finished job (out: $OUT)"; fi
        assert_out "  …carrying the terminal verdict, not a bare success" "verdict=terminal"
    fi
fi
rm -rf "$_ASWORK"

echo "=== T9: usage refusals are rc 2, never a silent answer ==="
assert_rc "no mode at all"            2 "$HELPER"
assert_rc "--start-time without --pid" 2 "$HELPER" --match x --start-time 5
assert_rc "--unsafe-no-identity without --pid" 2 "$HELPER" --match x --unsafe-no-identity
assert_rc "a non-numeric --start-time"  2 "$HELPER" --pid "$$" --start-time abc
assert_rc "a non-numeric timeout"      2 "$HELPER" --pid "$$" --until-present --timeout abc
assert_rc "an interval of 0"           2 "$HELPER" --pid "$$" --until-present --interval 0

echo "=== T10: --quiet suppresses the line, never the answer ==="
OUT=$("$HELPER" --quiet --pid "$$" --start-time "$_ST" 2>&1); _qrc=$?
if (( _qrc == 0 )) && [[ -z "$OUT" ]]; then
    pass "--quiet: rc is the answer and stdout is empty"
else
    fail "--quiet leaked output or wrong rc (rc=$_qrc out=$OUT)"
fi

echo
# COUNT GUARD. T3 is CONDITIONAL (it needs a foreign-session plant), so a case
# that silently stops running would show up as a smaller green rather than a
# red. Pinning the total makes a truncated run a failure. `+ 1` counts this
# assertion itself. T3 contributes 7 when it runs and 1 (the th_skip) when it
# does not, so the two totals are enumerated rather than averaged. T8b/T8c is
# likewise conditional and contributes 12 either way — deliberately, by skipping
# each leg individually rather than collapsing to one th_skip, so it adds NO new
# member to this disjunction (your-org/nexus-code#1278: a disjunction over
# expected totals is the same hiding place as a disjunction over verdicts).
_EXPECTED_ASSERTIONS=74
_EXPECTED_IF_SKIPPED=68
_ran=$(( PASS + FAIL + SKIP + 1 ))
if (( _ran == _EXPECTED_ASSERTIONS || _ran == _EXPECTED_IF_SKIPPED )); then
    pass "every declared assertion executed ($_ran)"
else
    fail "assertion count drifted — ran $_ran, expected $_EXPECTED_ASSERTIONS (or $_EXPECTED_IF_SKIPPED if the sibling plant was skipped)"
fi

th_summary_and_exit
