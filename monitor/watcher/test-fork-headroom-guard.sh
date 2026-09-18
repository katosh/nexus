#!/usr/bin/env bash
# Fork-headroom instrumentation and precondition — your-org/nexus-code#655,
# the intermittent-suite component.
#
# WHAT WAS ALREADY SETTLED, and is NOT re-litigated here: the cause is
# per-UID RLIMIT_NPROC headroom, not loadavg. `run-tests.sh`'s own
# `_rt_resource_note` header records that finding, and it replicates —
# 6/6 green at loadavg 36.4-39.0 with full headroom, 3/3 red at loadavg
# 38.0 with headroom squeezed to 60 tasks, same host, same sha.
#
# WHAT THIS SUITE IS FOR is the INSTRUMENTATION around that finding,
# which had two defects, each an instance of this repo's dominant class —
# a proxy standing in for the property:
#
#   1. the count printed beside every failure was `ps -u` (PROCESSES),
#      while RLIMIT_NPROC is checked against TASKS. Measured the same
#      instant: 153 vs 871, a 5.7x understatement of the only number the
#      ceiling compares against;
#   2. the fork-EAGAIN detector matched bash's exact wording,
#      `fork: retry: Resource temporarily unavailable`. The reproduction
#      emits coreutils' `timeout: fork system call failed: Resource
#      temporarily unavailable`, which does not match — and `timeout` is
#      how run_one invokes EVERY test under PER_TEST_TIMEOUT, so the
#      spelling CI is most likely to hit was the one that stayed silent.
#
# Run: bash monitor/watcher/test-fork-headroom-guard.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
RT="$_repo_root/monitor/watcher/run-tests.sh"
. "$_test_dir/_test_helpers.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
ck()   { if [[ "$2" == "$3" ]]; then pass "$1 (got '$2')"; else fail "$1 — got '$2' want '$3'"; fi; }
ck_has() {
    if [[ -z "${3:-}" ]]; then
        fail "$(printf '%s — EMPTY needle: `grep -qF ""` matches anything, so this assertion could only have passed VACUOUSLY (your-org/nexus-code#1110). Fix the CALLER: its expected value came back empty; check the rc of whatever produced it.' "$1")"
        return
    fi
    if grep -qF -- "$3" <<<"$2"; then pass "$1"
    else fail "$(printf '%s — %q not found in %q' "$1" "$3" "$2")"; fi
}
ck_not_has() {
    if grep -qF -- "$3" <<<"$2"; then
        fail "$(printf '%s — %q unexpectedly present' "$1" "$3")"
    else pass "$1"; fi
}
# THE ATTRIBUTION, NOT ONE REGISTER OF ITS PROSE (your-org/nexus-code#1040).
#
# D1-D3 used to pin the literal string `EAGAIN in this run`. That is the defect
# this repo names in its own words — "a test that pins PROSE it does not assert
# anything about turns every honesty improvement into a false red" — and it
# fired: `#1040` conditions the note on measured fork-headroom, so under the
# HEALTHY headroom these fixtures have BY CONSTRUCTION (they test spelling
# recognition, not exhaustion) the note now reads "the EAGAIN strerror appears
# in this run — but fork-headroom=… is HEALTHY". Three assertions went red for a
# suite whose subject had not changed and whose file was byte-identical.
#
# A CONJUNCTION, and the second half is what makes it safe. Asserting only that
# the spelling is echoed on `matched:` is defeated by a mutant that strips the
# whole attribution block and keeps the echo — `#655` coverage silently lost,
# green suite. So: the note must ALSO have made an EAGAIN claim, in EITHER
# register. Both registers are enumerated here on purpose; a third one added
# later reds this line, which is the right place to notice it.
ck_attributes() {   # ck_attributes <label> <note> <spelling-that-must-be-echoed>
    local label="$1" note="$2" spelling="$3"
    if ! grep -qE '^[[:space:]]*\*\*\* (EAGAIN in this run|the EAGAIN strerror appears in this run)' <<<"$note"; then
        fail "$label — the note made NO EAGAIN attribution in either register"
        return
    fi
    if ! grep -qF -- "$spelling" <<<"$note"; then
        fail "$(printf '%s — the spelling %q was not echoed on the matched: line' "$label" "$spelling")"
        return
    fi
    pass "$label"
}

WORK=$(mktemp -d -t nexus-655-headroom-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ===========================================================================
# PART A — th_fork_headroom measures the right population.
# ===========================================================================
echo "=== PART A: the gauge counts TASKS, not processes ==="

H=$(th_fork_headroom)
if [[ "$H" =~ ^[0-9]+$ ]]; then
    pass "A1 headroom is an integer on this host (got $H)"
else
    ck "A1 headroom degrades to 'unknown' when it cannot be read" "$H" unknown
fi

if [[ "$H" =~ ^[0-9]+$ ]]; then
    soft=$(ulimit -Su)
    tasks=$(ps -Lu "$(id -u)" -o pid= | grep -c .)
    procs=$(ps -u "$(id -u)" -o pid= | grep -c .)
    by_tasks=$(( soft - tasks ))
    by_procs=$(( soft - procs ))
    d_tasks=$(( H > by_tasks ? H - by_tasks : by_tasks - H ))
    d_procs=$(( H > by_procs ? H - by_procs : by_procs - H ))
    # Tolerance absorbs churn between the gauge's sample and ours.
    ck "A2 headroom tracks soft - TASKS (the quantity RLIMIT_NPROC checks)" \
       "$(( d_tasks <= 60 ? 1 : 0 ))" 1
    # A3 is the DISCRIMINATING half, and it is only decidable when the two
    # populations differ by more than the tolerance. On this operator's box
    # they differ ~5.7x (871 tasks / 153 processes) and the hypotheses are
    # far apart; on a CI runner threads barely exceed processes — measured
    # 63 vs 24 — and `soft - tasks` and `soft - procs` are 39 apart, inside
    # the noise. The first draft asserted the difference unconditionally and
    # went red on every CI band for that reason: a host-dependent assertion
    # dressed as a property. Declaring the gap it needs, and skipping when
    # the host cannot supply it, is the honest form.
    gap=$(( by_procs - by_tasks ))
    if (( gap > 120 )); then
        ck "A3 headroom is NOT soft - processes (that would overstate it)" \
           "$(( d_tasks < d_procs ? 1 : 0 ))" 1
    else
        # SKIP-AS-PASS, and worth naming: CI runners measure a gap of ~39, so
        # A3 — the DISCRIMINATING half — is vacuous on every CI band and runs
        # only on a host with a large thread/process ratio. The suite's total
        # is therefore blind to which of A2/A3 actually asserted anything.
        pass "A3 skipped (VACUOUS HERE) — tasks and processes differ by only $gap, so the two hypotheses are indistinguishable on this host"
    fi
else
    pass "A2 skipped (gauge unreadable)"
    pass "A3 skipped (gauge unreadable)"
fi

# An unreadable ceiling must not read as starvation.
ck "A4 an unreadable ceiling degrades to 'unknown', never to 0" \
   "$(ulimit() { return 1; }; th_fork_headroom)" unknown

# ===========================================================================
# PART B — the precondition: right polarity, loud, and numeric.
# ===========================================================================
printf '\n=== PART B: th_require_fork_headroom ===\n'

# Ample requirement → passes. Uses the real gauge, so this also proves the
# guard is not unconditionally refusing.
th_require_fork_headroom 1 "probe" 2>/dev/null
ck "B1 a requirement the host meets → rc 0" "$?" 0

# An impossible requirement → refuses. 10^9 tasks is beyond any ceiling.
b2=$(th_require_fork_headroom 1000000000 "probe-suite" 2>&1)
b2rc=$?
ck "B2 a requirement the host cannot meet → rc 1" "$b2rc" 1
ck_has "B2 the diagnostic names the suite" "$b2" "probe-suite"
ck_has "B2 the diagnostic gives the number required" "$b2" "needs 1000000000 tasks"
ck_has "B2 the diagnostic gives the number available" "$b2" "available"
ck_has "B2 the diagnostic names the per-UID sharing that makes it intermittent" \
   "$b2" "shared with every agent on this box"
# The whole point: a resource condition must not be readable as a defect.
ck_has "B2 the diagnostic says this is the MACHINE, not a test failure" \
   "$b2" "not a test failure"
ck_has "B2 the diagnostic cites the issue" "$b2" "your-org/nexus-code#655"

# The refusal must go to stderr, so it survives a suite whose stdout is
# scraped for ALL TESTS PASSED.
b3out=$(th_require_fork_headroom 1000000000 "probe" 2>/dev/null)
ck "B3 the diagnostic is on stderr, not stdout" "$b3out" ""

# A malformed requirement must not block a run.
th_require_fork_headroom "not-a-number" "probe" 2>/dev/null
ck "B4 a malformed requirement → rc 0 (never blocks on a bad argument)" "$?" 0

# An unreadable gauge must not manufacture a refusal.
b5rc=0
( th_fork_headroom() { printf 'unknown'; }
  th_require_fork_headroom 1000000000 "probe" 2>/dev/null ) || b5rc=$?
ck "B5 an unreadable gauge → rc 0 (degrade to running, never to blocking)" "$b5rc" 0

# ===========================================================================
# PART C — the suite that drove the issue declares its precondition, and
#          declines with SKIP rather than dying red.
# ===========================================================================
printf '\n=== PART C: the measured suite is wired up ===\n'

RSE="$_repo_root/monitor/watcher/test-remote-source-enforcement.sh"
ck_has "C1 the measured suite declares a fork-headroom precondition" \
   "$(cat "$RSE")" "th_require_fork_headroom"
# 77 is SKIP, which #568 A6 made a first-class status precisely so that
# "declined to run" is never counted as evidence. A red would file a
# resource condition as a code defect.
ck_has "C2 it exits 77 (SKIP), not 1 — a starved run is not a defect report" \
   "$(cat "$RSE")" "|| exit 77"

# BEHAVIOURAL, not structural: run the real suite under a ceiling that
# cannot meet its declared requirement and assert what actually happens.
# A grep for the call site would pass even if the guard never fired.
#
# The ceiling is derived INSIDE the child, immediately before exec. An
# earlier draft sampled the task count out here and set `base + 100`,
# which made the case racy against the board: the guard re-reads the
# count when it runs, and on a busy host it can fall by more than the
# margin between the two readings, leaving real headroom and letting the
# suite run. That showed up as C3/C4 reddening under a mutant that could
# not possibly affect them — a flaky assertion is worse than a missing
# one, because it discredits the mutant matrix it appears in. Sampling
# and capping in the same breath leaves a millisecond window instead of
# a multi-second one.
#
# MARGIN 128, inside a band with a floor as well as a ceiling. Measured
# on this host: at <= 64 tasks of headroom the guard cannot run AT ALL —
# `th_fork_headroom` has to fork `ps` to answer, and that fork is itself
# the one that EAGAINs, so the suite dies with rc 254 and bash's
# `fork: retry:` line. At >= 96 it measures and declines cleanly with 77.
#
# That floor is a real limitation and is deliberately not papered over.
# The two mechanisms are complementary rather than redundant: the
# precondition converts MODERATE starvation into a legible skip, and
# severe starvation still dies of EAGAIN — which is exactly why
# _rt_resource_note's detector had to be widened to the property, since
# that is the regime where the attribution is all the operator gets.
# THE MARGIN IS CHECKED AFTER THE CAP, NOT ASSUMED (your-org/nexus-code#1436).
# A fixed `t + 128` was chosen when this board was small. On a busy primary
# (~7,000 uid tasks, a dozen agent windows) the task count moves by MORE than
# the margin between the sample and the exec — so the child landed in the
# <= 64 regime at random and died 254 where C3 expects a clean 77, on every
# full local run, at load ~34. The guard was doing the right thing; the case
# was measuring the board's volatility and reporting it as a defect.
#
# So the case now (a) caps at a margin sitting in the MIDDLE of the window the
# guard needs — above the ~96 floor where `th_fork_headroom` can still fork
# its own `ps`, below the 256 the measured suite declares — and (b) RE-SAMPLES
# inside the child, after the cap and immediately before exec: if the count
# has already moved the headroom out of that window, the child exits 67 with
# both readings and the case retries. After N attempts it SKIPS with the
# measured volatility beside the constant, which is a statement about the
# board and not about the guard. `exit 66` (cannot lower ulimit) is unchanged.
C3_MARGIN=176; C3_FLOOR=96; C3_DECLARED=256; C3_TRIES=5
c3rc=67; c3=""; c3_attempts=0; c3_volatility=""
while (( c3_attempts < C3_TRIES )) && (( c3rc == 67 )); do
    c3_attempts=$(( c3_attempts + 1 ))
    c3=$(bash -c 't=$(ps -Lu "$(id -u)" -o pid= | grep -c .)
                  ulimit -Su $(( t + '"$C3_MARGIN"' )) 2>/dev/null || exit 66
                  t2=$(ps -Lu "$(id -u)" -o pid= 2>/dev/null | grep -c .) || t2=""
                  [[ "$t2" =~ ^[0-9]+$ ]] || { echo "C3-VOLATILE sampled=$t resampled=? (ps could not fork: headroom already gone)"; exit 67; }
                  h=$(( t + '"$C3_MARGIN"' - t2 ))
                  if (( h < '"$C3_FLOOR"' || h >= '"$C3_DECLARED"' )); then
                      echo "C3-VOLATILE sampled=$t resampled=$t2 headroom-at-exec=$h window=['"$C3_FLOOR"','"$C3_DECLARED"')"
                      exit 67
                  fi
                  exec bash '"'$RSE'" 2>&1)
    c3rc=$?
    # A 254 carrying bash's own EAGAIN wording is the child dying BEFORE the
    # re-sample could run — the count rose past the margin in the millisecond
    # between the cap and the first fork. Same volatility, one regime lower,
    # and no line of the child's is reachable to say so; classified here.
    if (( c3rc == 254 )) && grep -qE 'fork: retry|Resource temporarily unavailable' <<<"$c3"; then
        c3="C3-VOLATILE the child died of EAGAIN (rc 254) before it could re-sample — headroom was already below the fork floor at exec"
        c3rc=67
    fi
    (( c3rc == 67 )) && c3_volatility+="${c3_volatility:+; }attempt $c3_attempts: $(grep -o 'C3-VOLATILE.*' <<<"$c3")"
done
if (( c3rc == 66 )); then
    pass "C3 skipped — cannot lower ulimit on this host"
    pass "C4 skipped — cannot lower ulimit on this host"
elif (( c3rc == 67 )); then
    # A SKIP with the numbers: the board moved the task count by more than the
    # margin on every attempt. Not a pass, not a defect — coverage NOT taken.
    th_skip "C3 starved run exits 77 (SKIP) instead of dying with EAGAIN" \
        "task-count volatility exceeded the ${C3_MARGIN}-task margin on ${C3_TRIES}/${C3_TRIES} attempts (loadavg $(cut -d' ' -f1-3 /proc/loadavg)); $c3_volatility"
    th_skip "C4 and says why, in numbers" "same — the starved regime could not be staged on this board"
else
    ck "C3 starved run exits 77 (SKIP) instead of dying with EAGAIN (attempt $c3_attempts of $C3_TRIES, margin $C3_MARGIN)" "$c3rc" 77
    ck_has "C4 and says why, in numbers" "$c3" "RESOURCE PRECONDITION NOT MET"
fi

# And the converse: with real headroom it still runs its assertions. A
# guard that refused everything would satisfy C3 and be useless.
c5=$(bash "$RSE" 2>&1); c5rc=$?
ck "C5 with headroom, the suite still runs and passes" "$c5rc" 0
ck_has "C5 the suite actually asserted something" "$c5" "ALL TESTS PASSED"

# ===========================================================================
# PART D — the EAGAIN detector matches the PROPERTY, not one spelling.
# ===========================================================================
printf '\n=== PART D: _rt_resource_note attributes what it should ===\n'

# Source just the function under test out of run-tests.sh. Executing the
# runner would run the whole tree, so extract the definition instead.
sed -n '/^_rt_resource_note() {/,/^}/p' "$RT" > "$WORK/note.sh"
# shellcheck source=/dev/null
. "$WORK/note.sh" || { echo "could not extract _rt_resource_note" >&2; exit 1; }

mk_log() { printf '%s\n' "$2" > "$WORK/$1.err"; : > "$WORK/$1.out"; }

# D1: bash's spelling — the one the old fixed-string detector caught.
mk_log bashy 'bash: fork: retry: Resource temporarily unavailable'
d1=$(_rt_resource_note "$WORK/bashy")
ck_attributes "D1 bash's 'fork: retry:' spelling is attributed" \
   "$d1" "bash: fork: retry:"

# D2: THE REGRESSION. coreutils' spelling, emitted by `timeout` — which is
# how run_one invokes every test under PER_TEST_TIMEOUT. The old detector
# was silent here and the run read as a plain red.
mk_log timeouty 'timeout: fork system call failed: Resource temporarily unavailable'
d2=$(_rt_resource_note "$WORK/timeouty")
ck_attributes "D2 coreutils' 'fork system call failed' spelling is attributed" \
   "$d2" "fork system call failed"
ck_has "D2 the matched line is echoed, so the reader can judge the attribution" \
   "$d2" "fork system call failed"

# D3: a third spelling nobody has enumerated. Matching the property means
# an unlisted wording is covered by construction, which is the entire
# reason not to keep a list.
mk_log novel 'sh: cannot fork: Resource temporarily unavailable'
ck_attributes "D3 an un-enumerated spelling is still attributed" \
   "$(_rt_resource_note "$WORK/novel")" "sh: cannot fork:"

# D4: no EAGAIN → no attribution. Without this the detector could be
# firing on everything and D1-D3 would be vacuous.
mk_log clean 'assertion failed: expected 3 got 4'
d4=$(_rt_resource_note "$WORK/clean")
ck_not_has "D4 an ordinary failure is NOT attributed to EAGAIN" "$d4" "EAGAIN in this run"
ck_has "D4 the resource line is still printed for every failure" "$d4" "fork-headroom="

# D5: the counts. Both populations, and the one the ceiling uses labelled.
ck_has "D5 the note reports uid TASKS" "$d4" "uid-TASKS="
ck_has "D5 the note says which population the ceiling counts" \
   "$d4" "(what the ceiling counts)"
ck_has "D5 the note still reports processes, for comparison" "$d4" "uid-procs="
ck_has "D5 the note computes headroom rather than leaving a subtraction" \
   "$d4" "fork-headroom="
ck_has "D5 loadavg is retained (correlate, not cause — still worth recording)" \
   "$d4" "loadavg="

# ---------------------------------------------------------------------------
# The footer carries the SKIP count when C3/C4 could not be staged (#1436), in
# the same shape `th_summary_and_exit` prints, so the case-skip is visible at
# the foot and to the runner's case-skip accounting rather than only inline.
if (( ${SKIP:-0} > 0 )); then
    printf '\n=== summary: %d passed, %d failed, %d SKIPPED (precondition absent — NOT covered) ===\n' "$PASS" "$FAIL" "$SKIP"
else
    printf '\n=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
fi
if (( FAIL == 0 )); then
    if (( ${SKIP:-0} > 0 )); then echo "ALL TESTS PASSED ($SKIP case(s) SKIPPED — NOT covered)"; else echo "ALL TESTS PASSED"; fi
    exit 0
fi
exit 1
