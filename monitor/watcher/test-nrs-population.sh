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


echo "=== the CI shards PARTITION the population (#1703) ==="
# CI runs the band as a matrix, one `--shard K/N` slice per cell. A slice that
# is dropped, or two that overlap, leaves the gate reading green over suites
# it never probed — the #833 defect again, one level out. So the union of the
# slices, as `select` reports them, must equal the unsliced population exactly,
# member for member, and no slice may be empty.
WF="$REPO_ROOT/.github/workflows/tests.yml"
n_shards=$(sed -n 's/.*band --timeout [0-9]* --shard "\${{ matrix\.shard }}\/\([0-9]*\)".*/\1/p' "$WF")
matrix=$(sed -n '/^  inherited-root-gate:/,/^  [a-z-]*:$/{s/^ *shard: \[\(.*\)\]$/\1/p}' "$WF" | tr -d ' ')
want=$(seq -s, 1 "${n_shards:-0}" 2>/dev/null)
if [[ "$n_shards" =~ ^[1-9][0-9]*$ && "$matrix" == "$want" ]]; then
    printf '  PASS: %s\n' "the gate's matrix lists shards $matrix and its step slices /$n_shards — the two agree"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s\n' "the gate's matrix lists [${matrix:-none}] but its step slices /${n_shards:-none} — a slice is dropped or never run" >&2
    FAIL=$(( FAIL + 1 ))
    n_shards=4
fi
full=$(bash "$NRS" select | LC_ALL=C sort | sed "s|^$REPO_ROOT/||")
union=""; empty=0
for (( k = 1; k <= n_shards; k++ )); do
    slice=$(bash "$NRS" select --shard "$k/$n_shards" | sed "s|^$REPO_ROOT/||")
    [[ -n "$slice" ]] || empty=$(( empty + 1 ))
    union+="$slice"$'\n'
done
union=$(printf '%s' "$union" | grep . | LC_ALL=C sort)
if [[ -n "$full" && "$union" == "$full" && "$empty" == 0 ]]; then
    printf '  PASS: %s\n' "the $n_shards slices are disjoint, none is empty, and their union is the population ($(printf '%s\n' "$full" | grep -c .) suites)"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s\n' "the $n_shards slices do not partition the population: $empty empty; diff below" >&2
    diff <(printf '%s\n' "$full") <(printf '%s\n' "$union") >&2
    FAIL=$(( FAIL + 1 ))
fi
# A malformed slice is REFUSED rather than read as "the whole population" or
# "nothing" — either reading would make a matrix typo invisible.
bad_ok=1
for spec in 0/4 5/4 4 x/4; do
    rc=0; bash "$NRS" select --shard "$spec" >/dev/null 2>&1 || rc=$?
    [[ "$rc" == 2 ]] || { bad_ok=0; printf '    --shard %s exited %s, not 2\n' "$spec" "$rc" >&2; }
done
if (( bad_ok )); then
    printf '  PASS: %s\n' "malformed --shard specs (0/4 5/4 4 x/4) are refused at rc 2"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s\n' "a malformed --shard spec was accepted" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- assertion-count guard (your-org/nexus-code#805/#833) ------------------
# An exact expected total, not just the shared ledger. The ledger stops a
# ZERO-assertion run announcing a pass; it cannot see an assertion silently
# dropped from the middle of a suite, which is how a guard quietly narrows
# without anything going red. `test-summary-honesty-manifest.sh` requires this
# of every suite that claims a green.
EXPECTED_ASSERTIONS=8
TOTAL=$(( PASS + FAIL ))
if (( TOTAL != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count %d != expected %d — an assertion was silently dropped\n' \
        "$TOTAL" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
fi

th_summary_and_exit
