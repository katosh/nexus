#!/usr/bin/env bash
# Tests for monitor/ci-band-coverage.sh (your-org/nexus-code#1474 finding 1):
# a cancelled CI band is either a TEARDOWN kill (every discovered suite has a
# verdict; cosmetic) or a MID-RUN kill (members missing; a coverage gap), and
# the discriminator is SET MEMBERSHIP against the discovered population.
#
# Hermetic: planted logs in the runner's real line shape (timestamp prefix,
# `  PASS  test-x.sh  1.71s  16 assertions`, `Discovered N tests`), driven
# through the --log-file / --population-file / --conclusion seams. No network.
#
# Run: bash monitor/watcher/test-ci-band-coverage.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
TOOL="$_repo_root/monitor/ci-band-coverage.sh"

# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() { printf '%s\n' "monitor/ci-band-coverage.sh"; }
gp_handle "$@"

# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
[[ -x "$TOOL" ]] || { echo "missing/non-executable $TOOL" >&2; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

TS='2026-09-07T05:01:02.0000000Z'
printf 'test-a.sh\ntest-b.sh\ntest-c.sh\ntest-d.sh\n' > "$WORK/pop"
_line() { printf '%s   %-5s %-12s %6ss   %s assertions\n' "$TS" "$1" "$2" "$3" "$4"; }
_footer() { printf '%s === suite total: 20.42s across %s tests; 0 failed (0 of those TIMEOUT) — loadavg 4.9 4.0 3.9 on 2 cpus ===\n' "$TS" "$1"; }
_end()    { printf '%s Post job cleanup.\n%s Cleaning up orphan processes\n' "$TS" "$TS"; }
_run() {  # _run <log> <conclusion> [pop]  -> sets OUT RC
    OUT=$("$TOOL" --log-file "$1" --population-file "${3:-$WORK/pop}" --conclusion "$2" 2>&1); RC=$?
}

echo '=== 1. TEARDOWN kill: every discovered suite verdicted, conclusion cancelled -> complete, cosmetic ==='
{ printf '%s Discovered 4 tests. SHELL=/bin/bash jobs=4\n' "$TS"; _line PASS test-a.sh 1.71 16; _line PASS test-b.sh 15.70 108; _line SKIP test-c.sh 0.01 0; _line FAIL test-d.sh 3.00 9; _footer 4; printf '%s ##[error]The operation was canceled.\n' "$TS"; _end; } > "$WORK/teardown.log"
_run "$WORK/teardown.log" cancelled
assert_eq "teardown kill exits 0" "$RC" "0"
assert_contains "…verdict=complete with all four reported" "$OUT" "population=4 reported=4 missing=0 verdict=complete"
assert_contains "…and SAYS it is a teardown kill, cosmetic" "$OUT" "TEARDOWN kill"
assert_contains "…SKIP and FAIL lines count as verdicts (a verdict is a verdict, not a pass)" "$OUT" "reported=4"
assert_contains "…and the output SAYS the tail is not the evidence (a mid-run kill ends with the same cleanup lines)" "$OUT" "not the log tail"

echo '=== 2. MID-RUN kill: members missing, conclusion cancelled -> the gap, NAMED ==='
{ printf '%s Discovered 4 tests.\n' "$TS"; _line PASS test-a.sh 1.71 16; _line PASS test-b.sh 15.70 108; printf '%s ##[error]The operation was canceled.\n' "$TS"; _end; } > "$WORK/midrun.log"
_run "$WORK/midrun.log" cancelled
assert_eq "mid-run kill exits 1 (coverage LOST)" "$RC" "1"
assert_contains "…verdict=mid-run-kill" "$OUT" "missing=2 verdict=mid-run-kill"
assert_contains "…and names the first missing member" "$OUT" "test-c.sh"
assert_contains "…and the second" "$OUT" "test-d.sh"
assert_not_contains "…and not a reported one" "$OUT" "    test-a.sh"

echo '=== 3. SET MEMBERSHIP, not counts: equal totals, different members ==='
# Population of 4; the log reports 4 verdicts but one of them is NOT in the
# population (a different band's log) — a count comparison would say complete.
{ printf '%s Discovered 4 tests.\n' "$TS"; _line PASS test-a.sh 1 1; _line PASS test-b.sh 1 1; _line PASS test-c.sh 1 1; _line PASS test-zz.sh 1 1; _footer 4; _end; } > "$WORK/swap.log"
_run "$WORK/swap.log" cancelled
assert_eq "a reported suite outside the population is REFUSED (2), never read as complete" "$RC" "2"
assert_contains "…naming the stray member" "$OUT" "test-zz.sh"

echo '=== 4. refusals: could-not-look is never complete ==='
: > "$WORK/empty.log"
_run "$WORK/empty.log" cancelled
assert_eq "an EMPTY log is REFUSED (2) — the stale-gh-client shape" "$RC" "2"
assert_contains "…and says why" "$OUT" "EMPTY"
{ printf '%s Discovered 7 tests.\n' "$TS"; _line PASS test-a.sh 1 1; _end; } > "$WORK/disagree.log"
_run "$WORK/disagree.log" cancelled
assert_eq "log count and tree population DISAGREEING is REFUSED (2)" "$RC" "2"
assert_contains "…naming both numbers" "$OUT" 'says "Discovered 7 tests" but the tree at the head enumerates 4'
: > "$WORK/emptypop"
_run "$WORK/midrun.log" cancelled "$WORK/emptypop"
assert_eq "an EMPTY population is REFUSED (2), never a clean sweep" "$RC" "2"

echo '=== 4b. TRUNCATED or STREAMING logs are never complete (the arm that adjudicates merges) ==='
# All four verdicts present, footer present, but the log stops before GitHub's
# post-job line: a truncated fetch of a teardown kill and a still-streaming job
# look exactly like this. Refuse.
{ printf '%s Discovered 4 tests.\n' "$TS"; _line PASS test-a.sh 1 1; _line PASS test-b.sh 1 1; _line SKIP test-c.sh 0 0; _line PASS test-d.sh 1 1; _footer 4; } > "$WORK/trunc.log"
_run "$WORK/trunc.log" cancelled
assert_eq "a log without the post-job cleanup line is REFUSED (2), not complete" "$RC" "2"
assert_contains "…and says TRUNCATED or STREAMING" "$OUT" "TRUNCATED or the job is still STREAMING"
# All verdicts present, post-job line present, but NO runner footer: the log
# ends between the last verdict and the total — truncation, not a teardown kill
# (the kill lands AFTER the footer).
{ printf '%s Discovered 4 tests.\n' "$TS"; _line PASS test-a.sh 1 1; _line PASS test-b.sh 1 1; _line SKIP test-c.sh 0 0; _line PASS test-d.sh 1 1; _end; } > "$WORK/nofooter.log"
_run "$WORK/nofooter.log" cancelled
assert_eq "all verdicts but no runner footer is REFUSED (2)" "$RC" "2"
assert_contains "…naming the footer" "$OUT" "footer (=== suite total:"
# The footer's own total disagreeing with the population is a third refusal.
{ printf '%s Discovered 4 tests.\n' "$TS"; _line PASS test-a.sh 1 1; _line PASS test-b.sh 1 1; _line SKIP test-c.sh 0 0; _line PASS test-d.sh 1 1; _footer 9; _end; } > "$WORK/badfooter.log"
_run "$WORK/badfooter.log" cancelled
assert_eq "a footer total disagreeing with the population is REFUSED (2)" "$RC" "2"
# A job with no conclusion yet has nothing to adjudicate.
_run "$WORK/teardown.log" in-progress
assert_eq "conclusion=in-progress is REFUSED (2)" "$RC" "2"
# CONTROL: the same teardown log with everything present is still complete.
_run "$WORK/teardown.log" cancelled
assert_eq "CONTROL: the fully-ended teardown log is still complete (0)" "$RC" "0"

echo '=== 5. not cancelled but short: incomplete, still a gap ==='
_run "$WORK/midrun.log" failure
assert_eq "missing members with conclusion=failure exit 1" "$RC" "1"
assert_contains "…verdict=incomplete (a crash or runner fault, not a ceiling)" "$OUT" "verdict=incomplete"

echo '=== 5b. the repo is derived from the remote URL WITHOUT the .git suffix (found live on #1481: every job read 404 on your-org/nexus-code.git) ==='
assert_eq "https remote with .git -> OWNER/NAME" "$(CI_BAND_COVERAGE_REMOTE_URL=https://github.com/your-org/nexus-code.git "$TOOL" 1 --print-repo 2>&1)" "your-org/nexus-code"
assert_eq "ssh remote with .git -> OWNER/NAME"   "$(CI_BAND_COVERAGE_REMOTE_URL=git@github.com:your-org/nexus-code.git "$TOOL" 1 --print-repo 2>&1)" "your-org/nexus-code"
assert_eq "remote without .git is unchanged"     "$(CI_BAND_COVERAGE_REMOTE_URL=https://github.com/your-org/nexus-code "$TOOL" 1 --print-repo 2>&1)" "your-org/nexus-code"
"$TOOL" 1 --print-repo --repo owner/explicit >/dev/null 2>&1; _prc=$?
assert_eq "--repo overrides the derivation (and --print-repo exits 0)" "$_prc/$("$TOOL" 1 --print-repo --repo owner/explicit 2>&1)" "0/owner/explicit"

echo '=== 6. usage ==='
"$TOOL" >/dev/null 2>&1; assert_eq "no args is usage (3)" "$?" "3"
"$TOOL" not-a-number >/dev/null 2>&1; assert_eq "a non-numeric job id is usage (3)" "$?" "3"


echo '=== 7. SHADOW RUN: selecting the right run is the step BEFORE classifying it (your-org/nexus-code#1485) ==='
# A PR body/title edit spawns a fully-SKIPPED run that is the NEWEST at the sha,
# so it wins every latest-first view including `gh pr checks` — which then
# reports `skipping` for every check while the real battery runs unseen. A merge
# taken from that view is taken with NO VERDICT AT ALL.
#
# The tell is free: a skipped run never expands its matrix, so its check names
# keep the LITERAL template.
OUT=$("$TOOL" --job-name 'unit suite (${{ matrix.login_shell }}, jobs ${{ matrix.jobs }})' \
              --log-file "$WORK/teardown.log" --population-file "$WORK/pop" --conclusion cancelled 2>&1); RC=$?
assert_eq       "an unexpanded matrix template in the job name is REFUSED (2)" "$RC" "2"
assert_contains "…named as a SHADOW RUN"                     "$OUT" "SHADOW RUN"
assert_contains "…explaining that it dispatched nothing"     "$OUT" "dispatched nothing"
assert_contains "…and saying how to select the real run"     "$OUT" "Select the run by ID"
# POTENCY: the refusal is keyed on the TEMPLATE, not on the tool being broken —
# an EXPANDED name of the same job classifies normally.
OUT=$("$TOOL" --job-name 'unit suite (zsh, jobs 4)' \
              --log-file "$WORK/teardown.log" --population-file "$WORK/pop" --conclusion cancelled 2>&1); RC=$?
assert_eq       "POTENCY: the same job with an EXPANDED name classifies normally (0)" "$RC" "0"
assert_contains "…reaching the real verdict"                 "$OUT" "verdict=complete"
# And the guard is not merely decorative on the default path.
OUT=$("$TOOL" --log-file "$WORK/teardown.log" --population-file "$WORK/pop" --conclusion cancelled 2>&1); RC=$?
assert_eq       "CONTROL: no --job-name at all is unaffected (0)" "$RC" "0"

_EXPECTED_ASSERTIONS=39   # +7: your-org/nexus-code#1485 shadow-run refusal + potency + control
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$_EXPECTED_ASSERTIONS" >&2; _th_fail
fi
th_summary_and_exit
