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

# ── #1031 / #997: the footer is ONE line, and both fields come from it ──────
#
# skip-banner   the #1031 shape. `th_summary_and_exit` prints the SKIP-QUALIFIED
#               banner AFTER the summary, so the runner's `tail -n1` landed on
#               it and the `ALL TESTS PASSED (N` capture — written for
#               `(63 assertions)` — took the SKIP COUNT. Measured on `dev` at
#               `ca62020`: test-tmux-shim.sh ran 102 and its row said 1.
#               EXPECT 102 assertions AND 1 skipped case, from one line.
#
# echoed-spec   the #997 shape, and it is not a hypothetical: section 8 of THIS
#               file prints exactly this line, and the runner scored this suite
#               on it for every full run in the repo. The specimen is echoed
#               FIRST and the suite's own clean footer follows, which is the
#               real ordering — a suite cannot echo anything after its summary,
#               because the summary exits.
#               EXPECT 63 assertions and NO skip annotation.
#
# lower-skip    `th_summary_and_exit` spells it `SKIPPED`, but the corpus does
#               not only contain that: test-claude-md-618-remedies.sh emits
#               `%d skipped` on a summary line. The absence of an annotation
#               used to mean "no UPPERCASE SKIPPED", read as "nothing was
#               declined". EXPECT 7 assertions AND 2 skipped cases.
#
# two-digit     the greedy-`.*` trap on the SKIP capture, the same one the
#               assertion capture documents: without the explicit `[^0-9]`,
#               `12 SKIPPED` captures `2`. EXPECT 12, never 2.
mkfix skip-banner     '=== summary: 102 passed, 0 failed, 1 SKIPPED (precondition absent — NOT covered) ===' \
                      'ALL TESTS PASSED (1 case(s) SKIPPED — NOT covered)'
mkfix echoed-spec     '  PASS: capture: === summary: 41 passed, 0 failed, 2 SKIPPED (precond' \
                      '=== summary: 63 passed, 0 failed ===' 'ALL TESTS PASSED'
mkfix lower-skip      '=== summary: 7 passed, 0 failed, 2 skipped (7 assertions; expected 7) ==='
# suffix-noise  the OTHER end of the same `tail -n1` mechanism, and the reason
#               the repair is a two-tier SELECT rather than a widened regex.
#               #1031's overriding line is the harness's own banner; here it is
#               ordinary trailing prose, and it wins for exactly the same
#               reason. Measured before the fix: 88 read as 0, which also
#               selects the `0 ASSERTIONS — this PASS covers nothing` wording
#               and NAMES the suite in `=== N passing file(s) declared ZERO
#               assertions ===`. A suite is published as vacuous by a sentence
#               it printed about itself. EXPECT 88.
mkfix suffix-noise    '=== summary: 88 passed, 0 failed ===' 'ALL TESTS PASSED' \
                      'hint: 0 passed, 0 failed means nothing ran'
mkfix two-digit       '=== summary: 55 passed, 0 failed, 12 SKIPPED (precondition absent — NOT covered) ===' \
                      'ALL TESTS PASSED (12 case(s) SKIPPED — NOT covered)'

EXPECT_CANON=41  EXPECT_ASSERTIONS=92 EXPECT_CHECKS=16   EXPECT_BAREN=111
EXPECT_NOVERM=37 EXPECT_PF=4          EXPECT_LABEL=23    EXPECT_EQ=75
EXPECT_COLON=108 EXPECT_SLASH=127     EXPECT_CAPS=9      EXPECT_TESTS=18
# The #1031/#997 fixtures (section 9). Carried into section 4's total on
# purpose: a run total that did not move when four counting fixtures were added
# would mean they contributed nothing, and section 4 is the only place that
# notices.
EXPECT_SKIPBANNER=102 EXPECT_ECHOED=63 EXPECT_LOWERSKIP=7 EXPECT_TWODIGIT=55
EXPECT_SUFFIX=88

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

# RC 1 IS THE EXPECTED VERDICT HERE, AND IT IS A CONTRACT CHANGE, NOT A BUG
# (your-org/nexus-code#1145). This fixture set deliberately contains
# `declares-zero` — a suite that exits 0 having asserted NOTHING — and the
# runner now treats that as RED rather than merely naming it. Printing the
# census was not enough: `#568 A6` added the third state and fixed the RUNNER,
# two real suites never adopted the CONVENTION it depends on, and the hole
# stayed open for months with the census naming them on every run and the run
# staying green. So the gate below asserts the rc AND its cause, because
# `rc == 1` on its own is satisfied by any unrelated failure.
if (( run_rc != 1 )); then
    printf '  FAIL: the runner over the fixtures should be RED for the zero-assertion fixture (rc %d, want 1)\n' "$run_rc" >&2
    FAIL=$(( FAIL + 1 ))
    tail -20 "$OUT" | sed 's/^/    /' >&2
    th_summary_and_exit
fi
if grep -qE '^  (FAIL|TIMEOUT) ' "$OUT"; then
    printf '  FAIL: a fixture FAILED or TIMED OUT — the rc above is not the zero-assertion red\n' >&2
    FAIL=$(( FAIL + 1 ))
    grep -E '^  (FAIL|TIMEOUT) ' "$OUT" | sed 's/^/    /' >&2
    th_summary_and_exit
fi
assert_eq "0. the run is RED, and the census names the zero-assertion fixture" \
    "$(grep -c 'declared ZERO assertions' "$OUT")" "1"
assert_eq "0. …and names it by path, not merely by count" \
    "$(grep -c '0 assertions: .*test-declares-zero\.sh' "$OUT")" "1"
# CONTROL — the SAME fixture set minus the zero-assertion suite must be GREEN.
# Without it, "rc 1" is satisfied by a runner that reds on everything, which is
# the shape that makes a ratchet worthless.
_ctl_fixtures=(); for _f in "${fixtures[@]}"; do
    case "$_f" in */test-declares-zero.sh) continue ;; esac
    _ctl_fixtures+=("$_f")
done
timeout 300 bash "$RUNNER" --jobs 1 --state "$WORK/ledger-ctl.tsv" "${_ctl_fixtures[@]}" > "$WORK/run-ctl.log" 2>&1
_ctl_rc=$?
assert_eq "0. CONTROL: the same fixtures WITHOUT the zero-assertion one are GREEN" "$_ctl_rc" "0"

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
# row_skips <fixture-name> — the CASE-SKIP count the runner annotated that row
# with, or `-` if it annotated none. Read from the RENDERED row for the same
# reason row_count is: the annotation is #997's filed surface.
row_skips() {
    local n
    n=$(sed -n "s/^  PASS  test-$1\.sh .*(\([0-9][0-9]*\) CASE(S) SKIPPED.*/\1/p" "$OUT" | tail -1)
    printf '%s' "${n:--}"
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
# MATCHED ON STRUCTURE, NOT PROSE. This pinned the exact wording
# `declared across the run;`, which the #1031 sweep changed to name the
# population and the scope — so the label repair reddened three assertions that
# were not about the label. A test that pins prose it does not assert anything
# about turns every honesty improvement into a false red.
if grep -qE '=== assertions: [0-9]+ declared across [^;]*; 1 file\(s\) declared no machine-readable count ===' "$OUT"; then
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
             + EXPECT_COLON + EXPECT_SLASH + EXPECT_CAPS + EXPECT_TESTS
             + EXPECT_SKIPBANNER + EXPECT_ECHOED + EXPECT_LOWERSKIP
             + EXPECT_TWODIGIT + EXPECT_SUFFIX ))
got_total=$(sed -n 's/^=== assertions: \([0-9][0-9]*\) declared.*/\1/p' "$OUT" | tail -1)
assert_eq "footer total == sum of the declared counts (twelve spellings, four #1031/#997 fixtures, + the 0)" \
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

    _pnocount=$(sed -n 's/^=== assertions: [0-9]* declared across [^;]*; \([0-9][0-9]*\) file.*/\1/p' "$_pout" | tail -1)
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

    # THE VERDICT MUST AGREE WITH THE SERIAL PATH, which is what this section is
    # about. It used to assert `0` outright — correct until `#1145` made a
    # zero-assertion PASS red, at which point the fixture set (which contains
    # `declares-zero` ON PURPOSE) stopped being green and the assertion was
    # demanding the wrong answer. Comparing against `$run_rc` keeps the claim on
    # the axis the mechanism varies on — dispatcher, not fixture content — and
    # cannot go stale the next time the contract moves.
    assert_eq "--jobs $_j: the verdict AGREES with the --jobs 1 verdict" "$_prc" "$run_rc"
    # …and the green direction, on the control set, so "agrees" cannot be
    # satisfied by a dispatcher that reds unconditionally.
    timeout 300 bash "$RUNNER" --jobs "$_j" --state "$WORK/ledger-ctl-$_j.tsv" \
        "${_ctl_fixtures[@]}" > "$WORK/run-ctl-$_j.log" 2>&1
    assert_eq "--jobs $_j: CONTROL a genuinely green fixture set still exits 0" "$?" "0"
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
# THE WHOLE READER, not one function of it (your-org/nexus-code#1031, #997).
# `_rt_declared_assertions` used to be self-contained; it now delegates line
# SELECTION to `_rt_footer_line`, which both it and `_rt_footer_skips` read, so
# extracting it alone leaves the callee undefined — `command not found`, an
# empty line, `return 1`, and every case below reading `?`. That failure is
# loud here only because of the potency check that follows it; without one, an
# extraction that silently pulled in nothing would make this section a row of
# vacuous `?` comparisons against `?` expectations.
# shellcheck source=monitor/watcher/run-tests.sh
source <(sed -n '/^_rt_footer_line() {/,/^}/p;/^_rt_declared_assertions() {/,/^}/p;/^_rt_footer_skips() {/,/^}/p' "$RUNNER")
# POTENCY. Assert the extraction landed before believing anything it produces.
for _fn in _rt_footer_line _rt_declared_assertions _rt_footer_skips; do
    if declare -F "$_fn" >/dev/null 2>&1; then
        assert_eq "extracted \`$_fn\` from the runner" "yes" "yes"
    else
        printf '  FAIL: could not extract %s from %s — every capture below would read `?`\n' \
            "$_fn" "$RUNNER" >&2
        _th_fail
    fi
done

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

echo "=== 9. ONE footer line, TWO fields — the row's numbers cannot describe different lines (#1031, #997) ==="
#
# THE UNIFYING DEFECT, stated once because both issues are it: the runner
# derived the assertion count and the case-skip count by scraping the SAME
# stdout with DIFFERENT, independently-written patterns. #1031 is the capture
# taking a skip count out of a banner it was never written for; #997 is the
# selection taking a line the suite merely echoed. Both are repaired at the
# SELECTION step, in `_rt_footer_line`, which is now the only place a line is
# chosen — so the two fields cannot disagree about which line they describe.
#
# Driven through the RUNNER rather than the extracted function, deliberately:
# section 8 covers the capture in isolation and would have kept passing through
# both defects. #1031's damage is on the ROW, and the row is the artefact other
# agents quote into reports and merge decisions.

# #1031. Was `1 assertions` for a suite that ran 102 — and note the direction:
# the number is ANTI-CORRELATED with coverage, so a suite that skips more looks
# like it asserted more. That is why an off-by-N framing understates it.
assert_eq "#1031 the skip-qualified BANNER does not become the assertion count" \
    "$(row_count skip-banner)" "102"
assert_eq "#1031 …and the same line still yields the skip count" \
    "$(row_skips skip-banner)" "1"
assert_eq "#1031 the ledger agrees with the row" \
    "$(ledger_count skip-banner)" "102"

# #997. Was annotated `(2 CASE(S) SKIPPED)` against a suite whose real footer
# declines nothing — scored on a fixture it printed as test data.
assert_eq "#997 an ECHOED specimen footer is not read as the suite's result" \
    "$(row_count echoed-spec)" "63"
assert_eq "#997 …and the echoed SKIPPED count does not annotate the row" \
    "$(row_skips echoed-spec)" "-"

# The class sweep, not the two filed instances.
assert_eq "the lowercase 'skipped' spelling is seen (a predicate narrower than its population)" \
    "$(row_skips lower-skip)" "2"
assert_eq "…and its assertion count is unaffected" \
    "$(row_count lower-skip)" "7"
assert_eq "a TWO-DIGIT skip count survives the greedy-.* trap (12, never 2)" \
    "$(row_skips two-digit)" "12"
assert_eq "…and its assertion count comes from the summary, not the banner" \
    "$(row_count two-digit)" "55"

# RE-DERIVABILITY (#1031 non-negotiable): a qualified row prints the line both
# of its numbers came from, so a reader can check them without the suite's log.
# Asserted on CONTENT, not on presence — a `footer:` line naming a different
# line would satisfy a presence check and defeat the entire point.
_ftr=$(sed -n 's/^    footer: //p' "$OUT" | grep -F '102 passed' | tail -1)
assert_eq "a qualified row prints the footer line its numbers were read from" \
    "$_ftr" "=== summary: 102 passed, 0 failed, 1 SKIPPED (precondition absent — NOT covered) ==="
# NEGATIVE CONTROL. Unqualified rows must NOT print it — otherwise the assertion
# above passes on a runner that echoes a footer for all ~300 suites, which is a
# different (and much noisier) behaviour than the one being specified.
assert_eq "an UNQUALIFIED row prints no footer line" \
    "$(sed -n 's/^    footer: //p' "$OUT" | grep -cF '41 passed, 0 failed ===')" "0"

# THE SUFFIX-OVERRIDE, which is the same mechanism as #1031 read from the other
# end: `tail -n1` over ONE combined pattern lets any later match beat the real
# footer. Two tiers fix it — a marker-led footer wins outright, and the weak
# shape-only spellings are consulted only when there is no marker-led line at
# all. Asserted through the runner AND on the derived wordings, because the
# damage was not just a wrong number: it renamed a 88-assertion suite as vacuous.
assert_eq "trailing prose does NOT override a real footer (was 0, is 88)" \
    "$(row_count suffix-noise)" "88"
assert_eq "…so the suite is not branded '0 ASSERTIONS — this PASS covers nothing'" \
    "$(grep -c 'test-suffix-noise.sh.*0 ASSERTIONS' "$OUT")" "0"
assert_eq "…nor named in the ZERO-assertion footer list" \
    "$(grep -c '0 assertions:.*test-suffix-noise\.sh' "$OUT")" "0"

# THE SELECTION RULE ITSELF, at the boundary this fix draws. The anchor is
# PER-ALTERNATIVE: marker-led spellings must lead the line (modulo indentation),
# shape-only ones may carry a label. A global `^` anchor is the obvious repair
# and it would turn eight real suites (`  127 pass / 0 fail`) and one documented
# spelling (`cc-update: 23 passed, …`) into `?`.
assert_eq "an INDENTED real footer is still read (8 suites emit this)" \
    "$(extract_line '  127 pass / 0 fail')" "127"
assert_eq "a LABELLED footer is still read (a documented spelling)" \
    "$(extract_line 'cc-update: 23 passed, 0 failed')" "23"
assert_eq "a MARKER-LED banner behind non-blank text is refused — '?', not a guess" \
    "$(extract_line '  PASS: capture: ALL TESTS PASSED (92 assertions)')" "?"
# THE DECLARED RESIDUE, asserted so it is a stated boundary rather than an
# unexamined gap. The same echoed line still yields 41 through a SHAPE-ONLY
# alternative (`N passed, M failed`), which carries no marker to anchor. Closing
# that means dropping the five weak spellings, which costs ten real suites — so
# it is priced, not fixed. Anyone who narrows the weak set later should expect
# this assertion to change, and that is the signal.
assert_eq "…while a SHAPE-ONLY spelling on the same line still reads (declared residue)" \
    "$(extract_line '  PASS: capture: === summary: 41 passed, 0 failed ===')" "41"
assert_eq "a lone skip banner declares no assertion count — '?', never the skip count" \
    "$(extract_line 'ALL TESTS PASSED (1 case(s) SKIPPED — NOT covered)')" "?"
# TIER PRECEDENCE, driven directly: a marker-led footer beats a LATER
# shape-only line, and a shape-only line still wins when there is no
# marker-led one. Both directions, because asserting only the first would pass
# on a runner that had simply dropped the weak spellings.
printf '%s\n' '=== summary: 88 passed, 0 failed ===' 'hint: 0 passed, 0 failed' > "$WORK/tier.out"
assert_eq "tier 1 (marker-led) outranks a LATER tier-2 match" \
    "$(_rt_declared_assertions "$WORK/tier.out" 2>/dev/null || printf '?')" "88"
printf '%s\n' 'cc-update: 23 passed, 0 failed' '  127 pass / 0 fail' > "$WORK/tier2.out"
assert_eq "with NO marker-led line, tier 2 still reads — and takes the LAST" \
    "$(_rt_declared_assertions "$WORK/tier2.out" 2>/dev/null || printf '?')" "127"

th_summary_and_exit
