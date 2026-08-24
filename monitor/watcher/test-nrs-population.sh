#!/usr/bin/env bash
# test-nrs-population.sh — the gate must LOOK at the suites that exhibit the
# class, not merely be ABLE to see it (your-org/nexus-code#833).
#
# THE DEFECT THIS PINS. `nexus-root-sensitivity.sh`'s decoy was fixed so the
# probe could observe `#833`'s class at all. That was necessary and not
# sufficient: `fixture_suites()` — the population the band gate walks — still
# selected on `#655`'s predicate, "builds a temp root AND references
# spawn-worker/launcher/bootstrap-recover". Those three scripts are the ones
# that honour an inherited NEXUS_ROOT **when they spawn**. `#833` reaches the
# same variable by a different route — a fixture `ng`, whose
# `_resolve_state_dir` prefers the inherited root — and such a suite need not
# mention any of them.
#
# So two MEASURED leakers, `watcher/test-ng-reply-repo.sh` and
# `watcher/test-ng-report-check.sh`, sat outside the gated population while the
# gate reported clean. Blindness moved from **cannot see** to **does not look**,
# which is the same defect one level out and reads identically from a summary.
#
# WHAT IS ASSERTED, AND WHY IT IS NAMES AND NOT A COUNT. A count is satisfied by
# any 88 files. The claim worth pinning is that the population CONTAINS THE
# KNOWN INSTANCES — a boundary you cannot demonstrate contains them is a claim,
# not a boundary. Naming them means a future narrowing of the predicate reddens
# here instead of silently shrinking the gate, which is exactly how the
# `#655`-shaped predicate came to be load-bearing for a class it predates.
#
# Run: bash monitor/watcher/test-nrs-population.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
NRS="$REPO_ROOT/monitor/nexus-root-sensitivity.sh"

. "$_test_dir/_test_helpers.sh"

[[ -r "$NRS" ]] || { echo "FAIL: missing $NRS" >&2; exit 1; }

# The MEASURED leakers. Every one of these was attributed from the operator's
# own `ng-usage.jsonl` via the `src` field, not inferred: 40 / 52 / 68 rows.
# This list only ever grows, and only from measurement.
KNOWN_LEAKERS=(
    monitor/watcher/test-ng-reply-repo.sh
    monitor/watcher/test-ng-report-check.sh
    monitor/test-retire-preflight.sh
)

# Source ONLY the function, from the real script, so this asserts the shipped
# predicate rather than a copy of it.
pop=$(
    REPO_ROOT="$REPO_ROOT"
    # shellcheck disable=SC1090
    source /dev/stdin <<EOF
$(sed -n '/^fixture_suites()/,/^}/p' "$NRS")
EOF
    fixture_suites | sed "s|^$REPO_ROOT/||"
)

n=$(printf '%s\n' "$pop" | grep -c . || true)

# NON-VACUITY first. An empty or tiny population makes every membership check
# below meaningless, and "the predicate returned nothing" is indistinguishable
# from "your suite is not a member" to everything downstream.
if (( n >= 20 )); then
    printf '  PASS: %s\n' "fixture_suites() returns $n suites — the membership checks below are not being run against an empty set"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s\n' "fixture_suites() returned only $n suites; the assertions below would be vacuous" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo "=== every MEASURED leaker is inside the gated population ==="
for leaker in "${KNOWN_LEAKERS[@]}"; do
    # Whole-line membership WITHOUT a pipe. `printf … | grep -qxF` is the
    # obvious spelling and is a live bug under this file's `set -o pipefail`:
    # `grep -q` exits on its FIRST match, `printf` takes SIGPIPE, pipefail
    # surfaces 141, and this `if` reads FALSE for a leaker that IS in the
    # population — under-reporting exactly when the assertion matters.
    # `aso_scan_leaks` carries the same construction for the same reason, and
    # `test-sigpipe-assertion-lint.sh` is what caught this line.
    if [[ $'\n'"$pop"$'\n' == *$'\n'"$leaker"$'\n'* ]]; then
        printf '  PASS: %s\n' "$leaker is in the population the band gate walks"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$leaker LEAKED and is NOT in the gated population — the gate does not look at a known offender" >&2
        FAIL=$(( FAIL + 1 ))
    fi
done

echo "=== NEGATIVE CONTROL: the #655-only predicate misses two of the three ==="
# The predicate as it stood before #833. If this reproduces the gap, the
# membership assertions above are attributable to the widening and not to some
# incidental property of the tree.
missed=0
for leaker in "${KNOWN_LEAKERS[@]}"; do
    grep -qE 'spawn-worker\.sh|launcher\.sh|bootstrap-recover\.sh' "$REPO_ROOT/$leaker" 2>/dev/null \
        || missed=$(( missed + 1 ))
done
if (( missed == 2 )); then
    printf '  PASS: %s\n' "the inherited #655 predicate omits exactly 2 of the 3 measured leakers — the gap was real and the widening is what closes it"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s\n' "expected the #655-only predicate to miss 2 leakers, it misses $missed — this control no longer reproduces the gap it documents" >&2
    FAIL=$(( FAIL + 1 ))
fi


# ---- assertion-count guard (your-org/nexus-code#805/#833) ------------------
# An exact expected total, not just the shared ledger. The ledger stops a
# ZERO-assertion run announcing a pass; it cannot see an assertion silently
# dropped from the middle of a suite, which is how a guard quietly narrows
# without anything going red. `test-summary-honesty-manifest.sh` requires this
# of every suite that claims a green.
EXPECTED_ASSERTIONS=5
TOTAL=$(( PASS + FAIL ))
if (( TOTAL != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count %d != expected %d — an assertion was silently dropped\n' \
        "$TOTAL" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
fi

th_summary_and_exit
