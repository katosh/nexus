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
    if grep -qF -- "$needle" <<<"$hay"; then
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
assert_contains "T3 ledger accounts for both"     "$OUT" "2 PASS, 0 FAIL, 0 TIMEOUT, 0 not yet run"
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
assert_contains "T5 ledger shows the fail"     "$OUT" "1 PASS, 1 FAIL, 0 TIMEOUT, 0 not yet run"

# ---- T6: the nproc guard budgets TASKS, not processes (#506) ---------------
# RLIMIT_NPROC is checked against the uid's TASK (thread) count; a single
# node/claude process holds up to ~1000 threads, so the old guard's
# `ps -o pid=` PROCESS count under-counted ~7-9x and a small
# NEXUS_TEST_NPROC_HEADROOM produced a cap below the fork floor — every
# test died with fork:EAGAIN (a confirmation hazard). Post-fix the cap is
# probed-task-floor + headroom, so a small headroom still runs a trivial
# test to completion, and the banner's cap must exceed what the pre-fix
# process-count formula would ever produce.
# Headroom 64: enough for the runner's own post-cap fork bursts (a floor+8
# cap completes but crawls through bash's EAGAIN retry backoff under
# ambient churn); still ~15x below the process-vs-task gap, so the pre-fix
# formula (procs+64, ~200) stays far under the ~1000+ task floor and both
# assertions red on it.
echo '=== T6: small headroom is usable; cap derives from the task floor ==='
t6_ok=0
for attempt in 1 2 3; do
    OUT=$(NEXUS_TEST_NPROC_HEADROOM=64 bash "$RUNNER" --state "$WORK/t6-$attempt.tsv" "$FIX/ok-a.sh" 2>&1); RC=$?
    (( RC == 0 )) && { t6_ok=1; break; }
done
assert_eq "T6 headroom=64 run completes green (cap clears the true fork floor)" "$t6_ok" "1"
# Scale discriminator, churn-proof: tasks outnumber processes ~7-9x here
# (one node/claude process holds ~1000 threads), so a task-derived cap is
# always > 2x the process count, while the pre-fix process-count formula
# (procs + headroom) can never reach 2x procs for any headroom < procs.
t6_cap=$(sed -n 's/.*capped at \([0-9]*\).*/\1/p' <<<"$OUT" | head -1)
t6_procs=$(ps -o pid= -u "$(id -u)" 2>/dev/null | grep -c .)
if [[ "$t6_cap" =~ ^[0-9]+$ ]] && (( t6_cap > 2 * t6_procs )); then
    printf '  PASS: T6 cap (%s) is task-scale (> 2x %s visible processes)\n' \
        "$t6_cap" "$t6_procs"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: T6 cap %q is process-scale (procs=%s) — still counting the wrong noun\n' \
        "$t6_cap" "$t6_procs" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- summary ---------------------------------------------------------------
echo
printf '=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "FAILED"
exit 1
