#!/usr/bin/env bash
# test-ci-diag-budget.sh — the diagnostics budget is DERIVED from the job's
# remaining time (your-org/nexus-code#1442), and the workflow that consumes it
# cannot drift from the ceiling it was derived against.
#
# Two halves. (1) THE ARITHMETIC, driven with a pinned clock: the zero arm
# (remaining below the reserve — the arm that turns a real verdict into a
# non-verdict, so it must PRINT zero rather than fall back to a constant), the
# 420 s clamp, the per-suite clamp to the budget, a negative elapsed, and the
# non-numeric refusal that prints NOTHING on stdout (an `eval`-able refusal is
# a budget). (2) THE WORKFLOW: every job in tests.yml that declares
# JOB_CEILING_S declares it EQUAL to its own `timeout-minutes * 60`; every
# unit-suite job records JOB_START_S before its first real step and prints its
# elapsed time against the ceiling; the diagnostics step derives its budget
# through the script rather than a constant; and the decoy gate is its OWN job
# (#1384). Parsed with PyYAML, never grepped — a mention in a comment must not
# satisfy a structural claim.
#
# Run: bash monitor/watcher/test-ci-diag-budget.sh
# Expected: ALL TESTS PASSED, exit 0. Hermetic.
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO=$(cd "$_test_dir/../.." && pwd)
B="$REPO/monitor/watcher/ci-diag-budget.sh"
WF="$REPO/.github/workflows/tests.yml"
[[ -x "$B" ]] || th_abort "missing $B"
[[ -r "$WF" ]] || th_abort "missing $WF"

echo "== 1. the budget is what remains, clamped, never a constant"
out=$(NEXUS_DIAG_NOW=1000 bash "$B" 2400 0); rc=$?
assert_eq "plenty of room: rc 0" "$rc" "0"
assert_eq "…budget clamps at 420" "$(sed -n 's/^DIAG_BUDGET_S=//p' <<<"$out")" "420"
assert_eq "…per-suite clamps at 240" "$(sed -n 's/^DIAG_PER_SUITE_S=//p' <<<"$out")" "240"
out=$(NEXUS_DIAG_NOW=2100 bash "$B" 2400 0)
assert_eq "2400 ceiling, 2100 elapsed, 120 reserve -> 180 s budget (below the constant it replaced)" "$(sed -n 's/^DIAG_BUDGET_S=//p' <<<"$out")" "180"
assert_eq "…and the per-suite cap is clamped TO the budget (a 240 s re-run with 180 s left would overrun)" "$(sed -n 's/^DIAG_PER_SUITE_S=//p' <<<"$out")" "180"
out=$(NEXUS_DIAG_NOW=2000 bash "$B" 2400 0 200)
assert_eq "an explicit reserve is honoured (2400-2000-200 = 200)" "$(sed -n 's/^DIAG_BUDGET_S=//p' <<<"$out")" "200"

echo "== 2. THE ZERO ARM: remaining below the reserve prints ZERO, computed, at rc 0"
out=$(NEXUS_DIAG_NOW=2300 bash "$B" 2400 0); rc=$?
assert_eq "rc 0 — a zero budget is an ANSWER, not a failure" "$rc" "0"
assert_eq "DIAG_BUDGET_S=0 (2400-2300 = 100 < 120 reserve)" "$(sed -n 's/^DIAG_BUDGET_S=//p' <<<"$out")" "0"
assert_eq "DIAG_PER_SUITE_S=0" "$(sed -n 's/^DIAG_PER_SUITE_S=//p' <<<"$out")" "0"
out=$(NEXUS_DIAG_NOW=9999 bash "$B" 2400 0)
assert_eq "past the ceiling entirely: still zero, never negative" "$(sed -n 's/^DIAG_BUDGET_S=//p' <<<"$out")" "0"
out=$(NEXUS_DIAG_NOW=5 bash "$B" 2400 100)
assert_eq "a clock BEHIND the recorded start reads as zero elapsed (full budget), not negative" "$(sed -n 's/^DIAG_BUDGET_S=//p' <<<"$out")" "420"

echo "== 3. a non-numeric argument is REFUSED with nothing on stdout"
for bad in "x 0" "2400 x" "2400 0 x"; do
    # shellcheck disable=SC2086 — the split is the point of the loop
    out=$(NEXUS_DIAG_NOW=1 bash "$B" $bad 2>/dev/null); rc=$?
    assert_eq "'$bad' -> rc 2" "$rc" "2"
    assert_eq "'$bad' -> empty stdout (nothing an eval could turn into a budget)" "$out" ""
done
out=$(NEXUS_DIAG_NOW=abc bash "$B" 2400 0 2>/dev/null); rc=$?
assert_eq "an unreadable clock -> rc 2" "$rc" "2"

echo "== 4. --elapsed prints the line a band leaves before it can be killed (#1443)"
out=$(NEXUS_DIAG_NOW=1500 bash "$B" --elapsed 2400 0); rc=$?
assert_eq "rc 0" "$rc" "0"
assert_eq "elapsed 25m00s of 40m ceiling (62% used)" "$out" "elapsed 25m00s of 40m ceiling (62% used)"
out=$(NEXUS_DIAG_NOW=2701 bash "$B" --elapsed 2700 0)
assert_contains "past the ceiling reads over 100%, not clamped (the number is the finding)" "$out" "(100% used)"

echo "== 5. tests.yml: the ceiling the budget is derived from IS the job's timeout-minutes"
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' 2>/dev/null; then
    th_skip "tests.yml structure" "python3 with PyYAML unavailable — section 5 asserted nothing"
    th_summary_and_exit
fi
readarray -t rows < <(python3 - "$WF" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for name, job in (wf.get('jobs') or {}).items():
    env = job.get('env') or {}
    ceil = str(env.get('JOB_CEILING_S', ''))
    tm = job.get('timeout-minutes')
    steps = job.get('steps') or []
    runs = [str(st.get('run') or '') for st in steps]
    names = [str(st.get('name') or '') for st in steps]
    # index of the first step that records JOB_START_S, and of the first real step
    rec = next((i for i, r in enumerate(runs) if 'JOB_START_S=$(date +%s)' in r and 'GITHUB_ENV' in r), -1)
    first_real = next((i for i, st in enumerate(steps) if st.get('uses') or ('run-tests.sh' in str(st.get('run') or ''))), -1)
    runs_band = any('run-tests.sh --jobs' in r for r in runs)
    elapsed = any('ci-diag-budget.sh --elapsed "$JOB_CEILING_S" "$JOB_START_S"' in r for r in runs)
    derives = any('ci-diag-budget.sh "$JOB_CEILING_S" "$JOB_START_S"' in r for r in runs)
    const = any('DIAG_BUDGET_S="${NEXUS_DIAG_BUDGET_S' in r for r in runs)
    # The INVOCATION, not a mention: the report step echoes the band's name
    # in prose, and a mention must not satisfy a structural claim.
    gate = any('bash monitor/nexus-root-sensitivity.sh band' in r for r in runs)
    attribute = any('bash monitor/nexus-root-sensitivity.sh attribute "$GITHUB_WORKSPACE"' in r for r in runs)
    # `|`-separated, NOT tab: `read` with IFS=tab collapses a run of tabs (an
    # EMPTY field shifts every later column left — measured, the first cut
    # read timeout-minutes as the ceiling for every job with no env block).
    print('|'.join(str(x) for x in [name, ceil, tm if tm is not None else '', rec, first_real, int(runs_band), int(elapsed), int(derives), int(const), int(gate), int(attribute)]))
PY
)
n_ceil=0; n_band=0; gate_jobs=()
for row in "${rows[@]}"; do
    IFS='|' read -r name ceil tm rec first runs_band elapsed derives const gate attribute <<<"$row"
    if [[ -n "$ceil" ]]; then
        n_ceil=$(( n_ceil + 1 ))
        [[ "$tm" =~ ^[0-9]+$ ]] || tm=0
        assert_eq "job '$name': JOB_CEILING_S ($ceil) == timeout-minutes*60 ($tm*60)" "$ceil" "$(( tm * 60 ))"
        assert_eq "job '$name': records JOB_START_S BEFORE its first real step (record at $rec, first real at $first)" \
            "$(( rec >= 0 && first >= 0 && rec < first ))" "1"
    fi
    if (( runs_band )); then
        n_band=$(( n_band + 1 ))
        assert_eq "unit job '$name': declares JOB_CEILING_S (the budget/elapsed lines need it)" "$([[ -n "$ceil" ]] && echo 1 || echo 0)" "1"
        assert_eq "unit job '$name': prints its elapsed time against the ceiling (#1443 remedy 1)" "$elapsed" "1"
        assert_eq "unit job '$name': no CONSTANT diagnostics budget survives (#1442)" "$const" "0"
    fi
    (( gate )) && gate_jobs+=("$name")
    if [[ "$name" == inherited-root ]]; then
        assert_eq "inherited-root: the report step GATES through 'attribute' (#1336)" "$attribute" "1"
        assert_eq "inherited-root: the decoy band is NOT in this job any more (#1384)" "$gate" "0"
    fi
done
assert_eq "at least one job declares a ceiling (the section is not vacuous)" "$(( n_ceil > 0 ))" "1"
assert_eq "at least one job runs the band" "$(( n_band > 0 ))" "1"
assert_eq "exactly ONE job runs the decoy band, and it is its own job (#1384): ${gate_jobs[*]:-none}" "${#gate_jobs[@]}" "1"
assert_eq "…named inherited-root-gate" "${gate_jobs[0]:-}" "inherited-root-gate"
# The diagnostics step exists only in the matrix job; it must derive, not assume.
assert_eq "the 'unit' matrix job derives its diagnostics budget through the script" \
    "$(printf '%s\n' "${rows[@]}" | awk -F'|' '$1=="unit"{print $8}')" "1"

th_summary_and_exit
