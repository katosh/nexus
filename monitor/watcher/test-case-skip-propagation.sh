#!/usr/bin/env bash
# Tests that a CASE-level skip (th_skip) survives the trip through
# monitor/watcher/run-tests.sh (your-org/nexus-code#584 F1).
#
# The defect: `th_skip` writes to stderr and `th_summary_and_exit` exits 0.
# `run_one` prints a test's captured .out/.err ONLY on FAIL. So a file that
# ran, passed every assertion it made, and DECLINED to make three others
# rendered in CI as:
#
#     PASS  test-remote-principals-guard.sh   8.69s
#     === ledger: 1 PASS, 0 SKIP, 0 FAIL, 0 TIMEOUT (of 1 selected) ===
#
# Zero trace of the skip. The probed uid list, the SKIP line and the footer
# were all discarded. The assertions being skipped guard a security boundary
# (remote principals), so the outcome was a permanently-uncoverable security
# check behind a green PASS — worse than the red it replaced. Case-level SKIP
# had no propagation path to the file-level ledger, which is `exit 77`-only.
#
# `exit 77` is the wrong instrument here and this suite pins that too: it
# would collapse the whole file to SKIP and discard the 63 assertions that DID
# run. The count therefore travels on a stdout marker.
#
# `#611` (merged on dev) fixed the RUNNER half of this and shipped with no
# test at all. This suite is that missing coverage, plus the two gaps `#611`
# deliberately left: the ledger records nothing (its comment says "no ledger
# semantics change"), and a file run DIRECTLY still printed a bare
# `ALL TESTS PASSED`. Both are additive here — `#611`'s rendering is untouched.
#
# The teeth:
#   - A skipped case is VISIBLE in runner output, with its reason.
#   - It is COUNTED in the ledger (4th field) and in the final tally.
#   - The run does not present as an UNQUALIFIED pass.
#   - NEGATIVE CONTROL: a file with no skips produces NO qualification
#     anywhere. An always-on warning is as uninformative as an always-off
#     one, and would train dismissal.
#   - A skip is still not a FAILURE: exit code stays 0.
#
# Hermetic: synthetic test files in a tmpdir; no fixtures, no network.
#
# Run: bash monitor/watcher/test-case-skip-propagation.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
RUNNER="$REPO_ROOT/monitor/watcher/run-tests.sh"
HELPERS="$REPO_ROOT/monitor/watcher/_test_helpers.sh"

. "$HELPERS"

[[ -r "$RUNNER" ]]  || { echo "missing run-tests.sh" >&2; exit 1; }

SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT

# --- fixtures ---------------------------------------------------------------
# skipper: passes one assertion, declines one case.
cat > "$SB/test-skipper.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
. "$HELPERS"
assert_eq "an assertion that really ran" "1" "1"
th_skip "foreign-owner reader check (3 cases)" "no reachable path is owned by another uid; probed /proc/1 /etc/shadow"
th_summary_and_exit
EOF
# clean: passes, skips nothing. The negative control.
cat > "$SB/test-clean.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
. "$HELPERS"
assert_eq "an assertion that really ran" "1" "1"
th_summary_and_exit
EOF
# noisy-stderr: passes, but writes to stderr WITHOUT th_skip. Proves the
# runner is not simply dumping stderr on PASS (it must not — that is the
# output discipline the runner deliberately keeps).
cat > "$SB/test-noisy.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
. "$HELPERS"
echo "INCIDENTAL-STDERR-NOISE-MARKER" >&2
assert_eq "an assertion that really ran" "1" "1"
th_summary_and_exit
EOF
chmod +x "$SB"/test-*.sh

run_suite() { # run_suite <state-file|-> <test...>
    local state="$1"; shift
    if [[ "$state" == "-" ]]; then
        env -u NEXUS_ROOT -u NEXUS_LOCALS NEXUS_TEST_NPROC_GUARD=off \
            bash "$RUNNER" "$@" 2>&1
    else
        env -u NEXUS_ROOT -u NEXUS_LOCALS NEXUS_TEST_NPROC_GUARD=off \
            bash "$RUNNER" --state "$state" "$@" 2>&1
    fi
}

echo "=== 1. STANDALONE — the file itself is loud and self-qualifying ==="
sout=$(bash "$SB/test-skipper.sh" 2>/dev/null); srco=$?
assert_eq "a file with a skipped case still exits 0 (a skip is not a failure)" "$srco" "0"
assert_contains "the footer #611 parses rides STDOUT" \
    "$sout" "1 SKIPPED (precondition absent — NOT covered)"
assert_contains "the green banner is QUALIFIED, not bare 'ALL TESTS PASSED'" \
    "$sout" "ALL TESTS PASSED (1 case(s) SKIPPED — NOT covered)"
# The COUNT must be on stdout: stderr is what run_one throws away on PASS.
serr=$(bash "$SB/test-skipper.sh" 2>&1 >/dev/null)
assert_not_contains "the count is NOT stderr-only (that is the whole defect)" \
    "$serr" "SKIPPED (precondition absent"

echo
echo "=== 2. THROUGH THE RUNNER — the trip that used to erase it ==="
out=$(run_suite "$SB/s1.tsv" "$SB/test-skipper.sh"); rc=$?
assert_eq "a run containing a skipped case still exits 0" "$rc" "0"
assert_contains "the PASS row is QUALIFIED with the count" \
    "$out" "CASE(S) SKIPPED — NOT covered"
assert_contains "…and the reason is surfaced inline, not just the count" \
    "$out" "SKIP: foreign-owner reader check"
assert_contains "the final tally states the uncovered assertions plainly" \
    "$out" "CASE(S) SKIPPED across 1 passing file(s)"
assert_contains "…and denies them the status of coverage" \
    "$out" "not a coverage claim over them"
assert_contains "the per-file list names which file declined" \
    "$out" "PASSED but with SKIPPED CASES"
assert_contains "…naming the file" "$out" "test-skipper.sh"

echo
echo "=== 3. LEDGER — the count is recorded, not merely printed ==="
led=$(cat "$SB/s1.tsv")
assert_contains "the tally line carries the case-skip count in field 4" \
    "$(awk -F'\t' '{print $2"|"$4}' <<<"$led")" "PASS|1"
# Backward compatibility: field 4 is APPENDED. Every existing reader keys on
# $1/$2, so an older runner resuming this ledger must still parse it.
st=$(awk -F'\t' -v p="$SB/test-skipper.sh" '$1==p{s=$2} END{print s}' "$SB/s1.tsv")
assert_eq "an \$1/\$2 reader still resolves the status (no field reshuffle)" "$st" "PASS"

echo
echo "=== 4. NEGATIVE CONTROL — no skips must yield NO qualification ==="
# An always-on caveat is exactly as informative as an always-off one, and it
# trains dismissal. This case is what makes cases 1-3 evidence.
out=$(run_suite "$SB/s2.tsv" "$SB/test-clean.sh"); rc=$?
assert_eq "a clean run exits 0" "$rc" "0"
assert_not_contains "no 'SKIPPED' qualification on the PASS row" \
    "$out" "CASE(S) SKIPPED"
assert_not_contains "no case-skip line in the final tally" \
    "$out" "CASE(S) SKIPPED across"
assert_not_contains "no per-file skip list" \
    "$out" "PASSED but with SKIPPED CASES"
assert_contains "…and it is still reported as a pass" "$out" "1 PASS"
clean_ledger_field4=$(awk -F'\t' '{print $4}' "$SB/s2.tsv")
assert_eq "the ledger records 0, not an empty field" "$clean_ledger_field4" "0"
cout=$(bash "$SB/test-clean.sh" 2>/dev/null)
assert_contains "a clean file keeps the bare green banner" "$cout" "ALL TESTS PASSED"
assert_not_contains "…with no skip qualifier" "$cout" "SKIPPED"

echo
echo "=== 5. OUTPUT DISCIPLINE — stderr is still not dumped on PASS ==="
# The fix must not degrade into "echo everything on PASS". Only the recorded
# skip lines are surfaced; incidental stderr stays suppressed as before.
out=$(run_suite "$SB/s3.tsv" "$SB/test-noisy.sh")
assert_not_contains "incidental stderr is still withheld on a passing file" \
    "$out" "INCIDENTAL-STDERR-NOISE-MARKER"
assert_not_contains "…and no skip qualification is invented for it" \
    "$out" "CASE(S) SKIPPED"

echo
echo "=== 6. MIXED RUN — skips are attributed to the right file ==="
out=$(run_suite "$SB/s4.tsv" "$SB/test-clean.sh" "$SB/test-skipper.sh")
assert_contains "the tally counts exactly one skipping file of two" \
    "$out" "1 CASE(S) SKIPPED across 1 passing file(s)"
# Attribution is checked against the per-file SECTION, not the whole output —
# both filenames appear in the PASS rows above it, so a whole-output grep
# would pass vacuously no matter which file was blamed.
section=$(sed -n '/PASSED but with SKIPPED CASES/,$p' <<<"$out")
assert_contains "…and attributes it to the skipper" "$section" "test-skipper.sh"
assert_not_contains "…not to the clean file" "$section" "test-clean.sh"
assert_contains "both files are still counted as passes" "$out" "2 PASS"

echo
echo "=== 7. NO-LEDGER PATH — --state is optional, the caveat is not ==="
out=$(run_suite - "$SB/test-skipper.sh")
assert_contains "without --state the run is still qualified" \
    "$out" "declined individual CASES"
assert_contains "…and the file is named" "$out" "test-skipper.sh"
out=$(run_suite - "$SB/test-clean.sh")
assert_not_contains "…and a clean no-ledger run stays unqualified" \
    "$out" "declined individual CASES"

th_summary_and_exit
