#!/usr/bin/env bash
# test-assertion-accounting.sh — the runner surfaces HOW MUCH a green asserted
# (your-org/nexus-code#693).
#
# THE HOLE. CI recorded per-suite results only — `PASS test-svc.sh 15.96s` —
# and discarded every passing suite's stream. So "validate a green as
# non-vacuous", which this repo states as a standard, was not performable
# against CI at all: a suite that ran 108 assertions and one that ran none were
# typographically identical in the run log.
#
# WHAT THE CORPUS SAID, and why the fix is shaped the way it is. Measured over
# all 248 selected suites FROM THEIR OUTPUT: every one of them already declares
# a count. The gap was never coverage, it was NORMALISATION — the counts are
# spelled twelve ways, so no single reader saw them. `run-tests.sh` now reads
# that measured set and prints `?` for anything outside it.
#
# AN ENUMERATED SET IS NORMALLY THE BANNED MOVE HERE, so the distinction is
# worth stating precisely. Enumerating spellings OFFLINE TO PRODUCE A NUMBER
# fails silently: a missed spelling deflates the answer and nothing says so.
# That happened three times while this set was being derived — a terminal-line
# reader scored 23 suites as unaccounted, a whole-file reader scored 14, and
# reading all 14 by hand found the true residual is ZERO. Inside the runner the
# same miss produces a visible `?` on the row and a counted line in the footer,
# on every run. The failure mode is loud, and section 2 below is what keeps it
# loud: it feeds the runner a spelling deliberately NOT in the set and asserts
# the answer is `?` — never a number, never a silent 0.
#
# Run: bash monitor/watcher/test-assertion-accounting.sh
# Expected: ALL TESTS PASSED, exit 0. Hermetic — no tmux, no network, no nexus
# state; every fixture is composed at RUNTIME (a corpus-scanning check whose
# corpus includes its own fixtures records itself — #682's manifest).

set -uo pipefail

# shellcheck source=monitor/watcher/_test_helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

PASS=0; FAIL=0; SKIP=0

_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNNER="$_dir/run-tests.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/fixtures"
mkdir -p "$FIX"

# mkfix <name> <footer-line...>  — a suite whose ONLY job is to print a footer.
mkfix() {
    local name="$1"; shift
    { printf '#!/usr/bin/env bash\n'
      local l; for l in "$@"; do printf 'printf "%%s\\n" %q\n' "$l"; done
    } > "$FIX/test-$name.sh"
    chmod +x "$FIX/test-$name.sh"
}

# The twelve spellings, exactly as they occur in this repo's own suite output.
# Each row: fixture name, expected count, the footer line(s).
mkfix canon-summary   '=== summary: 41 passed, 0 failed ===' 'ALL TESTS PASSED'
mkfix all-assertions  'ALL TESTS PASSED (92 assertions)'
mkfix all-checks      'ALL TESTS PASSED (16 checks)'
mkfix all-bare-n      'ALL TESTS PASSED (111)'
mkfix all-n-over-m    'ALL TESTS PASSED (37/37)'
mkfix passed-failed   '4 passed, 0 failed'
mkfix label-passed    'cc-update: 23 passed, 0 failed'
mkfix passed-eq       'passed=75 failed=0'
mkfix passed-colon    'passed: 108  failed: 0' 'ALL TESTS PASSED'
mkfix pass-slash-fail '=== summary ===' '  127 pass / 0 fail' 'ALL TESTS PASSED'
mkfix pass-eq-caps    'PASS=9 FAIL=0' 'ALL TESTS PASSED'
mkfix tests-n-of-m    'functional-check tests: 18/18 passed'

# A count of ZERO — the loud case. test-public-guard-refusal.sh really does
# print this on a source tree, and before #693 it was rendered `PASS`.
mkfix declares-zero   'ALL TESTS PASSED (0 checks — skipped on source tree)'

# A spelling deliberately OUTSIDE the measured set. Section 2's whole point.
mkfix unmeasured      'checks completed: seventeen of seventeen' 'ALL TESTS PASSED'

EXPECT_CANON=41  EXPECT_ASSERTIONS=92 EXPECT_CHECKS=16   EXPECT_BAREN=111
EXPECT_NOVERM=37 EXPECT_PF=4          EXPECT_LABEL=23    EXPECT_EQ=75
EXPECT_COLON=108 EXPECT_SLASH=127     EXPECT_CAPS=9      EXPECT_TESTS=18

LEDGER="$WORK/ledger.tsv"
OUT="$WORK/run.log"
mapfile -t fixtures < <(find "$FIX" -name 'test-*.sh' -type f | LC_ALL=C sort)
# Serial + ledger. This IS a configuration CI exercises — `tests-slow-integration
# .yml:151` runs the band `--state --resume --max-seconds` with no `--jobs`, and
# `cc-harness.yml:163` is serial too. What nothing covered was the PARALLEL path,
# which section 6 adds. (An earlier draft of this comment said the opposite —
# that serial was the unused configuration. It is not; see section 6.)
timeout 300 bash "$RUNNER" --jobs 1 --state "$LEDGER" "${fixtures[@]}" > "$OUT" 2>&1
run_rc=$?

if (( run_rc != 0 )); then
    printf '  FAIL: the runner did not complete over the fixtures (rc %d)\n' "$run_rc" >&2
    FAIL=$(( FAIL + 1 ))
    tail -20 "$OUT" | sed 's/^/    /' >&2
    th_summary_and_exit
fi

# row_count <fixture-name> — the count the runner printed on that suite's row.
# Reads the RENDERED row, not the ledger: the row is what a human reading a CI
# log sees, and it is the surface #693 filed against.
row_count() {
    sed -n "s/^  PASS  test-$1\.sh  *[0-9.]*s  *\([0-9][0-9]*\) assertions.*/\1/p" "$OUT" | tail -1
}
# ledger_count <fixture-name> — field 5 of the durable ledger.
ledger_count() {
    awk -F'\t' -v n="/test-$1.sh" 'index($1, n) { c=$5 } END { print c }' "$LEDGER"
}

echo "=== 1. every spelling this repo actually uses is READ ==="
check() {
    local label="$1" fixture="$2" want="$3" got
    got=$(row_count "$fixture")
    assert_eq "$label" "${got:-<none>}" "$want"
    got=$(ledger_count "$fixture")
    assert_eq "$label — ledger field 5" "${got:-<none>}" "$want"
}
check "=== summary: N passed, M failed ==="   canon-summary   "$EXPECT_CANON"
check "ALL TESTS PASSED (N assertions)"       all-assertions  "$EXPECT_ASSERTIONS"
check "ALL TESTS PASSED (N checks)"           all-checks      "$EXPECT_CHECKS"
check "ALL TESTS PASSED (N)"                  all-bare-n      "$EXPECT_BAREN"
check "ALL TESTS PASSED (N/M)"                all-n-over-m    "$EXPECT_NOVERM"
check "N passed, M failed"                    passed-failed   "$EXPECT_PF"
check "<label>: N passed, M failed"           label-passed    "$EXPECT_LABEL"
check "passed=N failed=M"                     passed-eq       "$EXPECT_EQ"
check "passed: N  failed: M"                  passed-colon    "$EXPECT_COLON"
check "N pass / M fail"                       pass-slash-fail "$EXPECT_SLASH"
check "PASS=N FAIL=M"                         pass-eq-caps    "$EXPECT_CAPS"
check "<label> tests: N/M passed"             tests-n-of-m    "$EXPECT_TESTS"

echo
echo "=== 2. a spelling OUTSIDE the set is '?', never a number and never 0 ==="

# The load-bearing assertion of the whole file. If this ever reads a number,
# the runner is guessing; if it ever reads 0, an unreadable footer has been
# silently conflated with a suite that asserted nothing.
if grep -qE "^  PASS  test-unmeasured\.sh +[0-9.]+s +assertions: \?" "$OUT"; then
    printf "  PASS: an unmeasured footer renders 'assertions: ?' on its own row\n"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: unmeasured footer did not render as ? — row was: %s\n' \
        "$(grep -m1 'test-unmeasured' "$OUT")" >&2
    FAIL=$(( FAIL + 1 ))
fi
assert_eq "an unmeasured footer is '?' in the ledger too, not 0" \
    "$(ledger_count unmeasured)" "?"
if grep -qE '=== assertions: [0-9]+ declared across the run; 1 file\(s\) declared no machine-readable count ===' "$OUT"; then
    printf '  PASS: the footer COUNTS the unreadable file rather than dropping it\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: footer did not count exactly 1 unreadable file — got: %s\n' \
        "$(grep -m1 '=== assertions:' "$OUT")" >&2
    FAIL=$(( FAIL + 1 ))
fi
if grep -q 'assertions ?: .*test-unmeasured.sh' "$OUT"; then
    printf '  PASS: the footer NAMES the unreadable file (a normalisation checklist)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: footer did not name test-unmeasured.sh\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== 3. a DECLARED zero is loud, and distinct from unreadable ==="
if grep -qE "^  PASS  test-declares-zero\.sh +[0-9.]+s +0 ASSERTIONS — this PASS covers nothing" "$OUT"; then
    printf '  PASS: a suite declaring 0 says so ON ITS OWN ROW\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: zero-declaring row not flagged — got: %s\n' \
        "$(grep -m1 'test-declares-zero' "$OUT")" >&2
    FAIL=$(( FAIL + 1 ))
fi
if grep -q '1 passing file(s) declared ZERO assertions' "$OUT"; then
    printf '  PASS: the footer counts zero-declaring files SEPARATELY from unreadable ones\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: footer has no ZERO-assertion line\n' >&2
    FAIL=$(( FAIL + 1 ))
fi
assert_eq "a declared 0 is 0 in the ledger, not '?'" "$(ledger_count declares-zero)" "0"

echo
echo "=== 4. the footer total is the SUM of what was declared ==="
want_total=$(( EXPECT_CANON + EXPECT_ASSERTIONS + EXPECT_CHECKS + EXPECT_BAREN
             + EXPECT_NOVERM + EXPECT_PF + EXPECT_LABEL + EXPECT_EQ
             + EXPECT_COLON + EXPECT_SLASH + EXPECT_CAPS + EXPECT_TESTS ))
got_total=$(sed -n 's/^=== assertions: \([0-9][0-9]*\) declared.*/\1/p' "$OUT" | tail -1)
assert_eq "footer total == sum of the twelve declared counts (+ the 0)" \
    "${got_total:-<none>}" "$want_total"

echo
echo "=== 5. a pre-#693 ledger row has no field 5 — that is '?', never 0 ==="
OLD="$WORK/old-ledger.tsv"
printf '%s\tPASS\t0.01\t0\n' "$FIX/test-canon-summary.sh" > "$OLD"
OUT2="$WORK/run2.log"
timeout 300 bash "$RUNNER" --jobs 1 --state "$OLD" --resume "$FIX/test-canon-summary.sh" \
    > "$OUT2" 2>&1
assert_eq "a 4-field legacy row contributes 0 to the total, as '?'" \
    "$(sed -n 's/^=== assertions: \([0-9][0-9]*\) declared.*/\1/p' "$OUT2" | tail -1)" "0"
if grep -q 'assertions ?: .*test-canon-summary.sh' "$OUT2"; then
    printf '  PASS: a legacy row is reported UNREADABLE, not silently zero-asserting\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: legacy row was not reported as unreadable\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== 6. THE MODE CI ACTUALLY RUNS — --jobs 2 and --jobs 4 ==="
#
# This section exists because everything above it passed 34/0 while the feature
# was completely non-functional in the fast band. `run_one` is dispatched through
# `xargs … bash -c` when --jobs > 1, and a child shell inherits exported
# FUNCTIONS only. `_rt_declared_assertions` was not exported, so it did not exist
# in any child: 245 x `command not found`, every row `assertions: ?`, and a run
# total of `0` — on a GREEN run, in all five cells of tests.yml, from the first
# merge.
#
# THE PRECISE STATEMENT, because the obvious one is wrong. It is NOT that serial
# is a configuration production never uses: `tests-slow-integration.yml:151` runs
# the band serial + ledger nightly, and `cc-harness.yml:163` is serial as well.
# Sections 1-5 above therefore test a quadrant CI really does exercise. What
# NOTHING covered is the PARALLEL path — and that is precisely where the defect
# can live, because `xargs bash -c` is the only thing that crosses a process
# boundary. `tests.yml` — the band that runs on every push and PR — uses
# `--jobs 2`/`--jobs 4` exclusively, so the uncovered quadrant was also the
# most-executed one.
#
# Hence the assertion is not "the count is right at --jobs 4" but "the accounting
# is IDENTICAL to --jobs 1, whatever the job count". A property that varies with
# parallelism is not an accounting.
for _j in 2 4; do
    _pout="$WORK/run-j$_j.log"
    _pled="$WORK/ledger-j$_j.tsv"
    timeout 300 bash "$RUNNER" --jobs "$_j" --state "$_pled" "${fixtures[@]}" \
        > "$_pout" 2>&1
    _prc=$?

    # The direct symptom, asserted directly. A missing helper is rc 127 counted
    # by nothing — the runner stays green and the row just reads `?`.
    if grep -q 'command not found' "$_pout"; then
        printf '  FAIL: --jobs %s emitted "command not found" — a helper is missing from the parallel children\n' "$_j" >&2
        grep -m2 'command not found' "$_pout" | sed 's/^/      /' >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: --jobs %s: no "command not found" in the run\n' "$_j"
        PASS=$(( PASS + 1 ))
    fi

    # The property: identical accounting, not merely a plausible one.
    _ptotal=$(sed -n 's/^=== assertions: \([0-9][0-9]*\) declared.*/\1/p' "$_pout" | tail -1)
    assert_eq "--jobs $_j: run total equals the --jobs 1 total" \
        "${_ptotal:-<none>}" "$want_total"

    _pnocount=$(sed -n 's/^=== assertions: [0-9]* declared across the run; \([0-9][0-9]*\) file.*/\1/p' "$_pout" | tail -1)
    assert_eq "--jobs $_j: exactly one unreadable footer, as at --jobs 1" \
        "${_pnocount:-<none>}" "1"

    # Per-row, not just the aggregate: a total can be right while individual
    # rows are not (two errors cancelling is exactly how a wrong number hides).
    _pcanon=$(sed -n "s/^  PASS  test-canon-summary\.sh  *[0-9.]*s  *\([0-9][0-9]*\) assertions.*/\1/p" "$_pout" | tail -1)
    assert_eq "--jobs $_j: the canonical fixture's ROW still carries its count" \
        "${_pcanon:-<none>}" "$EXPECT_CANON"

    # Ledger field 5 travels out of the child too.
    assert_eq "--jobs $_j: ledger field 5 survives the parallel dispatcher" \
        "$(awk -F'\t' -v n="/test-pass-eq-caps.sh" 'index($1,n){c=$5} END{print c}' "$_pled")" \
        "$EXPECT_CAPS"

    # A run that is otherwise green must stay green.
    assert_eq "--jobs $_j: the runner still exits 0 on a green fixture set" "$_prc" "0"
done

echo
echo "=== 7. an all-'?' run is the HARNESS, and must go RED ==="
#
# `?` was designed as the loud value and it was not loud enough: "could not read
# the footer" and "could not RUN the reader" render identically, so the broken
# state printed `0 declared` — a plausible number, on a green run. Every suite in
# this repo declares a count, so every passing file reading `?` is not 248
# simultaneous corpus regressions. It is the reader. A SINGLE `?` must stay a
# quiet normalisation note (asserted above: sections 2 and 6 are green with one).
# The guard is FLOORED at 20 passing files, because throwaway fixtures
# legitimately have no footer — an unfloored version turned six of
# test-run-tests-bounded.sh's assertions red, i.e. a guard against a false green
# that manufactured a false red. Both sides of that floor are asserted here.
BROKE="$WORK/broken"
mkdir -p "$BROKE"
for i in $(seq 1 24); do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "no footer at all"\n' > "$BROKE/test-nofooter-$i.sh"
    chmod +x "$BROKE/test-nofooter-$i.sh"
done
OUT3="$WORK/run3.log"
mapfile -t broke_all < <(find "$BROKE" -name 'test-*.sh' -type f | LC_ALL=C sort)
timeout 300 bash "$RUNNER" --jobs 2 "${broke_all[@]}" > "$OUT3" 2>&1
rc3=$?
assert_eq "24 passing files ALL reading '?' exits non-zero" "$rc3" "1"

# Below the floor: a small fixture run must stay green, or every suite that
# drives this runner with footerless fixtures goes red.
OUT4="$WORK/run4.log"
timeout 300 bash "$RUNNER" --jobs 2 "$BROKE/test-nofooter-1.sh" "$BROKE/test-nofooter-2.sh" \
    > "$OUT4" 2>&1
assert_eq "2 footerless fixtures (below the floor) stay GREEN — no false red" "$?" "0"
if grep -q '::error::ASSERTION ACCOUNTING IS BROKEN' "$OUT4"; then
    printf '  FAIL: the guard fired below its floor — it would redden fixture-driven suites\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: the guard stays silent below its floor\n'
    PASS=$(( PASS + 1 ))
fi
if grep -q '::error::ASSERTION ACCOUNTING IS BROKEN' "$OUT3"; then
    printf '  PASS: it says the READER did not run, not that the corpus regressed\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: no ::error:: for an all-unreadable run — a broken reader still reports a plausible 0\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== 8. the capture is ANCHORED — a prefix digit must not become the count ==="
#
# The extractor used to take "the first integer on the matched line", which is a
# SILENT corruption path — the one failure mode this feature must not have, since
# a wrong count is indistinguishable from a right one on the row.
#
# Two of these are INSIDE the supported set, which is what makes it worth a
# section: `<label>: N passed, M failed` is a documented spelling and a single
# digit in the label misreads it, and a datestamp prefix misreads the CANONICAL
# `_test_helpers.sh` footer that 163 suites emit. "Use a documented spelling"
# was not protection. Latent today — no current label carries a digit — which is
# exactly when to fix it.
#
# Driven against the extracted function directly rather than through a run: it
# isolates the thing under test, and it is the form that caught the greedy-`.*`
# bug in the first anchored draft (`.*\([0-9]*\)` let `.*` swallow `cc-update: 2`
# and captured `3`).
extract_line() {   # extract_line <footer-line> -> the count, or `?`
    printf '%s\n' "$1" > "$WORK/oneline.out"
    _rt_declared_assertions "$WORK/oneline.out" 2>/dev/null || printf '?'
}
# shellcheck source=monitor/watcher/run-tests.sh
source <(sed -n '/^_rt_declared_assertions() {/,/^}/p' "$RUNNER")

while IFS='|' read -r want line; do
    [[ -n "$line" ]] || continue
    assert_eq "capture: ${line:0:52}" "$(extract_line "$line")" "$want"
done <<'CASES'
63|=== summary: 63 passed, 0 failed ===
41|=== summary: 41 passed, 0 failed, 2 SKIPPED (precondition absent — NOT covered) ===
0|ALL TESTS PASSED (0 checks — skipped on source tree)
4|4 passed, 0 failed
23|cc-update: 23 passed, 0 failed
17|cc-update2: 17 passed, 0 failed
127|  127 pass / 0 fail
18|functional-check tests: 18/18 passed
41|[2026-08-05 02:00:00] passed: 41  failed: 0
41|[3/12] passed=41 failed=0
63|2026-08-05 === summary: 63 passed, 0 failed ===
?|1..14
?|Results: 17 of 17 checks OK
CASES

th_summary_and_exit
