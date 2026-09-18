#!/usr/bin/env bash
# Tests for run-tests.sh's bounded, resumable, honest-accounting mode
# (your-org/nexus-code#499).
#
# The defect: the watcher suite outgrew any single bounded invocation
# (~175 tests, dozens past a 10-minute tool ceiling) and the runner had
# no per-test timeout, no resumability, and no way to distinguish "never
# ran" from "passed" — so every "ran the full suite" claim was an
# assertion of a state that was never established. Contracts under test:
#
#   T1  --timeout: a hanging test is terminated, PRINTED as TIMEOUT,
#       tallied as TIMEOUT (never a pass, never omitted), exit 1.
#   T2  --state ledger: every completed test appends path/status/wall;
#       the summary accounts for the FULL selection.
#   T3  --resume: recorded tests are skipped; the sweep completes across
#       two invocations and only then reads green (exit 0).
#   T4  --max-seconds: the runner stops cleanly between tests, reports
#       the unaccounted remainder, exits 3 with a resume hint — and a
#       green-so-far ledger with unrun tests is NOT exit 0.
#   T5  a ledger containing a FAIL yields exit 1 even when complete.
#
# Hermetic: fixture "tests" are trivial scripts in a temp dir, invoked
# by explicit path (the runner accepts explicit paths); the runner's
# last-failures state is scoped via NEXUS_TEST_STATE_DIR; the nproc
# guard is left on (it is relative and harmless here).
#
# Run: bash monitor/watcher/test-run-tests-bounded.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNNER="$_test_dir/run-tests.sh"

PASS=0
FAIL=0
SKIP=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    if [[ -n "$needle" ]] && grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — missing %q\n' "$label" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

WORK=$(mktemp -d -t nexus-runner-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
export NEXUS_TEST_STATE_DIR="$WORK/runner-state"

FIX="$WORK/fixture"
mkdir -p "$FIX"
printf '#!/bin/bash\nexit 0\n'              > "$FIX/ok-a.sh"
printf '#!/bin/bash\nexit 0\n'              > "$FIX/ok-b.sh"
printf '#!/bin/bash\nexit 1\n'              > "$FIX/red.sh"
printf '#!/bin/bash\nsleep 60\n'            > "$FIX/hang.sh"
printf '#!/bin/bash\nsleep 2; exit 0\n'     > "$FIX/slow-ok.sh"
# A test that DECLINES TO RUN: exit 77 (your-org/nexus-code#568 A6).
printf '#!/bin/bash\necho "skipped: needs a thing this host lacks"\nexit 77\n' > "$FIX/skip.sh"
# T7 (your-org/nexus-code#752) — the three FAILURE-REPORTING SHAPES a suite can
# have. `red.sh` above is already the third (silent on both streams).
#   red-stdout.sh  announces its verdict on STDOUT only. This is the #752 shape:
#                  test-respawn-loop-integration.sh's terminal `echo "FAIL: guard
#                  did not trip within deadline"` carries no `>&2`, so its .err
#                  was 0 bytes and the band summary printed `rc=1` and nothing.
#   red-stderr.sh  announces on STDERR, the shape the runner already handled.
#                  Kept so the fix cannot regress the path that worked.
printf '#!/bin/bash\necho "VERDICT-ON-STDOUT: the guard did not trip"\nexit 1\n' > "$FIX/red-stdout.sh"
printf '#!/bin/bash\necho "VERDICT-ON-STDERR: assertion 3 failed" >&2\nexit 1\n' > "$FIX/red-stderr.sh"
chmod +x "$FIX"/*.sh

run() { OUT=$(bash "$RUNNER" "$@" 2>&1); RC=$?; }

# ---- T1: timeouts are terminated, named, tallied — never passes ----------
echo '=== T1: --timeout turns a hang into a LOUD TIMEOUT, exit 1 ==='
run --timeout 2 --state "$WORK/t1.tsv" "$FIX/ok-a.sh" "$FIX/hang.sh"
assert_eq       "T1 exit 1 (a timeout is a failure)"       "$RC" "1"
assert_contains "T1 prints the TIMEOUT row"                "$OUT" "TIMEOUT  hang.sh"
assert_contains "T1 summary counts it as TIMEOUT"          "$OUT" "1 TIMEOUT"
assert_contains "T1 timeout listed, marked not-a-pass"     "$OUT" "NOT passes"
assert_eq       "T1 ledger records TIMEOUT" \
    "$(awk -F'\t' '$1 ~ /hang.sh/ {print $2}' "$WORK/t1.tsv")" "TIMEOUT"
assert_eq       "T1 ledger records the pass" \
    "$(awk -F'\t' '$1 ~ /ok-a.sh/ {print $2}' "$WORK/t1.tsv")" "PASS"

# ---- T2/T3: ledger + resume complete a sweep across invocations ----------
echo '=== T2/T3: --state + --resume finish the sweep across two invocations ==='
run --state "$WORK/t2.tsv" "$FIX/ok-a.sh"
assert_eq "T2 first invocation green so far but selection=1, exit 0" "$RC" "0"
run --state "$WORK/t2.tsv" --resume "$FIX/ok-a.sh" "$FIX/ok-b.sh"
assert_eq       "T3 second invocation exit 0 (sweep complete, all green)" "$RC" "0"
assert_contains "T3 announced the resume skip"    "$OUT" "resume: 1 already recorded"
assert_contains "T3 ledger accounts for both"     "$OUT" "2 PASS, 0 SKIP, 0 ENVSKIP, 0 FAIL, 0 TIMEOUT, 0 not yet run"
assert_eq       "T3 ok-a ran exactly once (skipped on resume)" \
    "$(grep -c 'ok-a.sh' "$WORK/t2.tsv")" "1"
# T3b — resume on a FULLY-recorded ledger: the counts must read zero
# remaining and "running 0 tests" (the `("${filtered[@]:-}")` expansion
# used to leave one empty element, printing "1 remaining / running 1
# tests" while running nothing — skeptic finding on #499. A runner whose
# own counts lie is disqualified from being the honesty mechanism).
run --state "$WORK/t2.tsv" --resume "$FIX/ok-a.sh" "$FIX/ok-b.sh"
assert_eq       "T3b fully-recorded resume exits 0"        "$RC" "0"
assert_contains "T3b reports zero remaining"               "$OUT" "; 0 remaining"
assert_contains "T3b runs zero tests (no phantom element)" "$OUT" "running 0 tests"
assert_eq       "T3b ledger unchanged (nothing double-counted)" \
    "$(wc -l < "$WORK/t2.tsv" | tr -d ' ')" "2"

# ---- T4: budget stop is INCOMPLETE (exit 3), never green ------------------
echo '=== T4: --max-seconds stops between tests; unrun tests block green ==='
run --state "$WORK/t4.tsv" --max-seconds 1 "$FIX/slow-ok.sh" "$FIX/ok-b.sh"
assert_eq       "T4 exit 3 (incomplete)"           "$RC" "3"
assert_contains "T4 says INCOMPLETE"               "$OUT" "INCOMPLETE"
assert_contains "T4 names the unaccounted count"   "$OUT" "1 not yet run"
assert_contains "T4 prescribes resuming"           "$OUT" "Resume with the SAME command"
run --state "$WORK/t4.tsv" --resume --max-seconds 30 "$FIX/slow-ok.sh" "$FIX/ok-b.sh"
assert_eq "T4 resumed invocation completes green (exit 0)" "$RC" "0"

# ---- T5: a complete ledger with a FAIL is exit 1 --------------------------
echo '=== T5: complete-but-red ledger exits 1 ==='
run --state "$WORK/t5.tsv" "$FIX/ok-a.sh" "$FIX/red.sh"
assert_eq       "T5 exit 1"                    "$RC" "1"
assert_contains "T5 ledger shows the fail"     "$OUT" "1 PASS, 0 SKIP, 0 ENVSKIP, 1 FAIL, 0 TIMEOUT, 0 not yet run"

# ---- T5b: SKIP is a THIRD outcome — not a pass, not a failure -------------
# your-org/nexus-code#568 A6. `status=PASS` whenever `rc == 0` meant every
# self-skipping test tallied as a pass: 13 structurally-skipping tests sat in
# the default band and three printed the literal `ALL TESTS PASSED` after ZERO
# checks. A green count was therefore never a coverage claim, and nothing in
# the output said so. Exit 77 (the autotools convention) now records SKIP.
echo '=== T5b: exit 77 records SKIP — green, but never counted as evidence ==='
run --state "$WORK/t5b.tsv" "$FIX/ok-a.sh" "$FIX/skip.sh"
assert_eq       "T5b a SKIP does not turn the run red"  "$RC" "0"
assert_contains "T5b prints a SKIP row"                 "$OUT" "SKIP  skip.sh"
assert_contains "T5b row carries the test's own reason" "$OUT" "needs a thing this host lacks"
assert_contains "T5b summary counts it separately"      "$OUT" "1 PASS, 1 SKIP, 0 ENVSKIP, 0 FAIL, 0 TIMEOUT, 0 not yet run"
assert_contains "T5b states the PASS count is not coverage over it" \
    "$OUT" "DECLINED TO RUN"
assert_contains "T5b lists the skipped path"            "$OUT" "SKIPPED (declined to run"
assert_eq       "T5b ledger records SKIP, not PASS" \
    "$(awk -F'\t' '$1 ~ /skip.sh/ {print $2}' "$WORK/t5b.tsv")" "SKIP"
# A SKIP must not be re-selected by --failed-only: it did not fail.
run --state "$WORK/t5b.tsv" --resume "$FIX/ok-a.sh" "$FIX/skip.sh"
assert_eq       "T5b a recorded SKIP is not re-run on resume" \
    "$(grep -c 'skip.sh' "$WORK/t5b.tsv")" "1"

# ---- T6: the nproc guard budgets TASKS, not processes (#506) ---------------
# RLIMIT_NPROC is checked against the uid's TASK (thread) count; a single
# node/claude process holds up to ~1000 threads, so the old guard's
# `ps -o pid=` PROCESS count under-counted ~7-9x and a small
# NEXUS_TEST_NPROC_HEADROOM produced a cap below the fork floor — every
# test died with fork:EAGAIN (a confirmation hazard). Post-fix the cap is
# probed-task-floor + headroom, so a small headroom still runs a trivial
# test to completion, and the floor the banner reports must be the TASK
# count, not the process count.
# Headroom 64: enough for the runner's own post-cap fork bursts (a floor+8
# cap completes but crawls through bash's EAGAIN retry backoff under
# ambient churn).
#
# HOW THIS IS MEASURED, and why the obvious way does not work
# (your-org/nexus-code#585). The discriminator used to be
# `cap > 2 * process_count`, resting on the premise that tasks outnumber
# processes ~7-9x "because one node/claude process holds ~1000 threads".
# That is a property of a developer workstation running a nexus worker
# (measured 1489 tasks / 186 processes = 8.0x), NOT of the environment. A CI
# runner has no fat multithreaded process, so tasks ≈ processes, and the two
# sides of the comparison collide: it went red on an exact tie (cap 82 vs
# 2x41 procs = 82), flipping green on re-run with no code change, because
# `t6_procs` counts whatever else the suite happens to co-schedule at
# `--jobs 4`. The assertion was comparing a STABLE quantity (the cap,
# derived from the probed floor) against a SCHEDULING-DEPENDENT one.
#
# Widening the multiplier or the headroom would have converted a real
# fragility into a silent one. The noun was the problem, not the constant:
# where tasks ≈ processes the two nouns are INDISTINGUISHABLE, so no
# assertion phrased over ambient counts can discriminate there — and the
# pre-fix guard genuinely was not broken on such a host.
#
# So MANUFACTURE the condition instead of hoping for it: park N threads in
# ONE process for the duration of the probe. That establishes a known
# task-minus-process gap of ~N on ANY host, runner included, and the
# assertion becomes "the reported floor exceeds the PROCESS count by a
# large fraction of the gap we deliberately created" — a claim about the
# noun, decided by a margin (N/2) that dwarfs both the probe's 32-wide
# binary-search granularity and any plausible co-scheduling churn.
#
# T6b EARNED ITS KEEP IMMEDIATELY: it is the regression test for the
# elided-fork bug in the guard's own probe. On bash 5.2 (every current
# runner) `( ulimit -Su N; /bin/true )` is exec'd in place of the subshell,
# so no child is created, RLIMIT_NPROC is never exercised, every candidate
# "succeeds", and the search collapses to its lower bound. The guard
# reported "probed task floor 23" on a runner whose real floor was 566 and
# then hit `fork: Resource temporarily unavailable` at the resulting cap of
# 87 — the #506 hazard exactly, masked in normal use only because the
# default headroom (2048) is big enough to hide a garbage floor. The old
# `2 * procs` discriminator could never have caught it: 23 > 2 * 14 is
# true. See run-tests.sh's _probe_ok for the fix and the measurement.
echo '=== T6: small headroom is usable; cap derives from the task floor ==='

T6_THREADS=512
t6_farm_pid=""
t6_farm_ready=0
t6_farm_why=""

# Signal the farm only while it is still OUR child: pid_max on the lab boxes
# is small and a parallel suite recycles PIDs in under a minute, so killing a
# recorded-but-exited PID can signal a stranger (_test_helpers.sh documents
# the same hazard). This file keeps its own assertions inline for
# self-containment, so the guard is inline too.
#
# The `wait` is not incidental: bash announces an asynchronously-reaped job on
# stderr ("Terminated  python3 …"), and for a job started from a heredoc that
# notice carries the ENTIRE script body into the test's output. Reaping the
# job explicitly, inside a redirected group, keeps it quiet.
t6_stop_farm() {
    [[ -n "${t6_farm_pid:-}" ]] || return 0
    local st rest ppid
    if st=$(cat "/proc/$t6_farm_pid/stat" 2>/dev/null); then
        rest="${st##*) }"
        read -r _ ppid _ <<<"$rest"
        [[ "$ppid" == "$$" ]] && { kill "$t6_farm_pid"; wait "$t6_farm_pid"; } 2>/dev/null
    fi
    t6_farm_pid=""
}
trap 't6_stop_farm; rm -rf "$WORK"' EXIT

if command -v python3 >/dev/null 2>&1; then
    # 256 KiB stacks: 512 threads costs ~128 MiB of VIRTUAL address space and
    # a negligible RSS, so this is safe on a 2-vCPU/7 GiB runner. Threads are
    # tasks, so they count against RLIMIT_NPROC exactly as the kernel's fork
    # check does — which is the entire point.
    # In a FILE, not a backgrounded heredoc: bash's job notice quotes the whole
    # command line, and for a heredoc job that means the entire script body.
    cat > "$WORK/t6-farm.py" <<'PY'
import sys, threading
n = int(sys.argv[1])
threading.stack_size(262144)
up, stop = threading.Semaphore(0), threading.Event()
def hold():
    up.release()
    stop.wait(300)          # hard-bounded: the farm cannot outlive the test by long
for _ in range(n):
    threading.Thread(target=hold, daemon=True).start()
for _ in range(n):
    up.acquire()            # every thread is genuinely alive before we say READY
print("READY", flush=True)
stop.wait(300)
PY
    python3 "$WORK/t6-farm.py" "$T6_THREADS" > "$WORK/t6-farm.out" 2>&1 &
    t6_farm_pid=$!
    for _ in $(seq 1 150); do
        grep -q READY "$WORK/t6-farm.out" 2>/dev/null && { t6_farm_ready=1; break; }
        kill -0 "$t6_farm_pid" 2>/dev/null || break
        sleep 0.2
    done
    (( t6_farm_ready )) || t6_farm_why="thread farm never reported READY: $(tr '\n' ' ' < "$WORK/t6-farm.out" 2>/dev/null)"
else
    t6_farm_why="python3 absent — cannot park $T6_THREADS threads in one process"
fi

# Run the guard WHILE the farm is alive, so the probe sees those tasks.
t6_ok=0
for attempt in 1 2 3; do
    OUT=$(NEXUS_TEST_NPROC_HEADROOM=64 bash "$RUNNER" --state "$WORK/t6-$attempt.tsv" "$FIX/ok-a.sh" 2>&1); RC=$?
    (( RC == 0 )) && { t6_ok=1; break; }
done
# Measure both nouns for OUR uid in the same window as the probe, then release.
t6_procs=$(ps -o  pid= -u "$(id -u)" 2>/dev/null | grep -c .)
t6_tasks=$(ps -Lo pid= -u "$(id -u)" 2>/dev/null | grep -c .)
t6_stop_farm

assert_eq "T6 headroom=64 run completes green (cap clears the true fork floor)" "$t6_ok" "1"

t6_cap=$(sed   -n 's/.*capped at \([0-9]*\).*/\1/p'            <<<"$OUT" | head -1)
t6_floor=$(sed -n 's/.*probed task floor \([0-9]*\).*/\1/p'    <<<"$OUT" | head -1)

# T6a — the banner's own accounting must hold: the cap IS floor + headroom.
# Environment-independent, and it is what makes the floor the auditable
# quantity rather than the cap. An absent banner is a failure, not a skip:
# it means the guard never engaged.
if [[ "$t6_cap" =~ ^[0-9]+$ && "$t6_floor" =~ ^[0-9]+$ ]] && (( t6_cap == t6_floor + 64 )); then
    printf '  PASS: T6a cap %s == probed floor %s + headroom 64 (banner accounting is honest)\n' \
        "$t6_cap" "$t6_floor"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: T6a cap %q / floor %q do not reconcile with headroom 64 (banner absent or wrong)\n' \
        "$t6_cap" "$t6_floor" >&2
    FAIL=$(( FAIL + 1 ))
fi

# T6b — the noun. With ~T6_THREADS tasks deliberately parked in one process,
# a task-derived floor clears the PROCESS count by ~gap; a process-derived
# one cannot clear it at all. Margin gap/2 ≫ the 32-wide search granularity.
#
# THE VERDICT IS A FUNCTION, AND THAT IS THE FIX (your-org/nexus-code#925).
# This used to be an if/else whose `else` was reached by TWO different
# outcomes — a floor that is a number and too low (the real finding), and a
# floor that is not a number at all (no measurement happened) — while the
# message asserted the first: `floor '' is process-scale … still counting the
# wrong noun`. Observed with the floor as the EMPTY STRING. Neither "is
# process-scale" nor "counts the wrong noun" is established by an absent
# value; a reader who trusts it goes hunting in the floor computation for a
# defect that may not be there.
#
# That is this repo's dominant defect class — absence reported as a finding —
# inside a guard whose own job is to catch it, and it is the same remedy
# `_merge_ref_base` took for a non-numeric `total_count`: a value the parse
# cannot read is `unread`, never a verdict about what it would have said.
#
# Extracted to a pure classifier so the distinction is TESTABLE rather than
# merely correct: the synthetic cases below drive it with the empty floor that
# produced the report, which no live run can be made to reproduce on demand.
#
# _t6b_verdict <farm_ready> <floor> <procs> <tasks> <threads>
#   -> unmeasured | skip | task-scale | process-scale
_t6b_verdict() {
    local ready="${1-}" floor="${2-}" procs="${3-}" tasks="${4-}" threads="${5-}"
    # Inputs the arm's own arithmetic needs. Checked BEFORE any (( )) touches
    # them: `(( x >= 1 ))` on a non-numeric x is a bash `set -u` fatal and a
    # silent 0 elsewhere, which is the #903 total_count trap one file over.
    if ! [[ "$procs" =~ ^[0-9]+$ && "$tasks" =~ ^[0-9]+$ && "$threads" =~ ^[0-9]+$ ]]; then
        printf 'unmeasured'; return
    fi
    local gap=$(( tasks - procs ))
    if [[ "$ready" != 1 ]] || (( gap < threads / 2 )); then printf 'skip'; return; fi
    # The discriminator IS decidable here — so an unreadable floor is the one
    # thing left unmeasured, and it is reported as that and nothing more.
    if ! [[ "$floor" =~ ^[0-9]+$ ]]; then printf 'unmeasured'; return; fi
    if (( floor >= procs + gap / 2 )); then printf 'task-scale'; else printf 'process-scale'; fi
}

t6_gap=$(( t6_tasks - t6_procs ))
case "$(_t6b_verdict "$t6_farm_ready" "$t6_floor" "$t6_procs" "$t6_tasks" "$T6_THREADS")" in
    task-scale)
        printf '  PASS: T6b floor %s counts TASKS not processes (procs=%s tasks=%s gap=%s, needed >= %s)\n' \
            "$t6_floor" "$t6_procs" "$t6_tasks" "$t6_gap" "$(( t6_procs + t6_gap / 2 ))"
        PASS=$(( PASS + 1 )) ;;
    process-scale)
        # The floor IS a number and it IS too low. Only this arm has earned the
        # noun claim, so only this arm makes it.
        printf '  FAIL: T6b floor %s is process-scale (procs=%s tasks=%s gap=%s, needed >= %s) — still counting the wrong noun\n' \
            "$t6_floor" "$t6_procs" "$t6_tasks" "$t6_gap" "$(( t6_procs + t6_gap / 2 ))" >&2
        FAIL=$(( FAIL + 1 )) ;;
    unmeasured)
        # NOT a finding, and deliberately not a FAIL: nothing was measured, so
        # there is nothing to conclude about the noun. Counted as a SKIP so the
        # summary reports it as NOT COVERED rather than as a pass.
        SKIP=$(( ${SKIP:-0} + 1 ))
        printf '  SKIP: T6b UNMEASURED — the floor is %q, not a number, so the task-vs-process\n' "$t6_floor" >&2
        printf '        question was never asked. This is NOT a claim that the floor is\n' >&2
        printf '        process-scale or that anything counts the wrong noun (procs=%q tasks=%q).\n' \
            "$t6_procs" "$t6_tasks" >&2 ;;
    *)
        # Loud, counted, and it names the numbers so the reader can act. The
        # alternative — asserting over ambient counts anyway — is exactly the
        # tie-on-a-runner flake this replaced.
        SKIP=$(( ${SKIP:-0} + 1 ))
        printf '  SKIP: T6b task-vs-process discriminator — %s (procs=%s tasks=%s gap=%s, need gap >= %s)\n' \
            "${t6_farm_why:-manufactured task/process gap did not materialise}" \
            "$t6_procs" "$t6_tasks" "$t6_gap" "$(( T6_THREADS / 2 ))" >&2 ;;
esac

# T6c — the classifier itself, driven with synthetic inputs. THE EMPTY FLOOR IS
# THE POINT: it is the value that produced `#925`'s misreport, and no live run
# can be made to yield it on demand, so the only way it is ever covered is here.
_t6c() {   # <want> <label> <args...>
    local want="$1" label="$2"; shift 2
    local got; got=$(_t6b_verdict "$@")
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: T6c %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: T6c %s — got %q want %q\n' "$label" "$got" "$want" >&2; FAIL=$(( FAIL + 1 ))
    fi
}
_t6c unmeasured    "an EMPTY floor is UNMEASURED, never a noun verdict (#925's own observation)" 1 ''    100 1000 64
_t6c unmeasured    "…and so is a non-numeric floor"                                              1 'n/a' 100 1000 64
_t6c process-scale "a numeric floor at process scale IS the finding — the arm still fires"       1 '105' 100 1000 64
_t6c task-scale    "a task-derived floor passes"                                                 1 '600' 100 1000 64
_t6c skip          "no manufactured gap → skip, not a verdict"                                   1 '600' 100 100  64
_t6c skip          "farm not ready → skip"                                                       0 '600' 100 1000 64
_t6c unmeasured    "unreadable procs/tasks are UNMEASURED before any arithmetic touches them"    1 '600' ''  1000 64

# ---- T7: a red must print the failing test's OWN diagnosis ------------------
#
# your-org/nexus-code#752. The runner tailed `.err` alone, which is a PROXY for
# "show what the test said about its failure". For any suite that reports its
# verdict on stdout the proxy returns nothing, silently — and the band summary
# renders a bare `rc=1`. That is what happened to
# test-respawn-loop-integration.sh on BOTH attempts of run 31153179861: 0-byte
# .err, 10,563-byte .out ending in its verdict, and a day spent triaging a red
# whose cause was already on disk.
#
# NOT tested by asserting "stderr is where verdicts go" — that would re-encode
# the proxy. The property asserted is that the TEXT THE TEST EMITTED reaches the
# summary, whichever stream carried it.
echo '=== T7: a FAIL surfaces the test'"'"'s own diagnosis from either stream ==='

run --state "$WORK/t7.tsv" "$FIX/red-stdout.sh"
assert_eq       "T7a stdout-only red still exits 1"            "$RC" "1"
assert_contains "T7a the STDOUT verdict reaches the summary"   "$OUT" "VERDICT-ON-STDOUT: the guard did not trip"
assert_contains "T7a the summary names which stream it read"   "$OUT" "stderr empty — stdout tail follows"

run --state "$WORK/t7b.tsv" "$FIX/red-stderr.sh"
assert_contains "T7b the STDERR verdict still reaches the summary" "$OUT" "VERDICT-ON-STDERR: assertion 3 failed"
# No regression: when stderr HAS the diagnosis, the stdout-fallback banner must
# not appear. Otherwise the label stops meaning anything.
if [[ "$OUT" == *"stderr empty"* ]]; then
    printf '  FAIL: T7b stderr-carrying red wrongly announced the stdout fallback\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: T7b stderr-carrying red does NOT announce the stdout fallback\n'
    PASS=$(( PASS + 1 ))
fi

# A test that says nothing at all must SAY that it said nothing. A blank gap
# under a FAIL row is indistinguishable from the #752 bug it just fixed.
run --state "$WORK/t7c.tsv" "$FIX/red.sh"
assert_contains "T7c a genuinely silent red is named as silent" \
    "$OUT" "(test emitted nothing on either stream)"

# T7d — THE PARALLEL PATH. `run_one` is dispatched through `xargs … bash -c`
# when --jobs > 1, and a child shell inherits exported FUNCTIONS only. An
# unexported `_rt_failure_tail` is `command not found` there — a red that prints
# no diagnosis, i.e. #752 reproduced inside its own fix. This cannot be covered
# by test-assertion-accounting.sh section 6 (the established guard for missing
# parallel helpers): every fixture it builds exits 0, so the FAIL arm this
# function lives on never executes there.
run --jobs 2 --state "$WORK/t7d.tsv" "$FIX/red-stdout.sh" "$FIX/red-stderr.sh"
assert_contains "T7d --jobs 2: stdout verdict survives the parallel dispatcher" \
    "$OUT" "VERDICT-ON-STDOUT: the guard did not trip"
assert_contains "T7d --jobs 2: stderr verdict survives the parallel dispatcher" \
    "$OUT" "VERDICT-ON-STDERR: assertion 3 failed"
if [[ "$OUT" == *"command not found"* ]]; then
    printf '  FAIL: T7d --jobs 2 emitted "command not found" — a helper is missing from the parallel children\n' >&2
    grep -m2 'command not found' <<<"$OUT" | sed 's/^/      /' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: T7d --jobs 2: no "command not found" in the run\n'
    PASS=$(( PASS + 1 ))
fi

# ---- summary ---------------------------------------------------------------
echo
if (( SKIP > 0 )); then
    printf '=== summary: %d passed, %d failed, %d SKIPPED (precondition absent — NOT covered) ===\n' \
        "$PASS" "$FAIL" "$SKIP"
else
    printf '=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
fi
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "FAILED"
exit 1
