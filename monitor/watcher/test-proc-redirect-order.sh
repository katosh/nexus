#!/usr/bin/env bash
# The REDIRECTION-ORDER population must not grow, and it must be EMPTY in
# production code. your-org/nexus-code#1305.
#
# THE DEFECT. Redirections are performed LEFT TO RIGHT, so
# `cmd < "/proc/$pid/cmdline" 2>/dev/null` attempts the `<` while stderr is
# still the terminal; the `2>/dev/null` takes effect afterwards, on a command
# that never ran. Found by RUNNING the merged code on the live board — one
# ordinary orchestration command printed
# `pane-state.sh: line 2391: /proc/27901/cmdline: No such file or directory` —
# not by reading it, and not by any test.
#
# WHY A GUARD AND NOT JUST THE FIX. Two instances landed in one evening, in
# different files, by different authors: `pane-state.sh`'s `/proc` walk and
# `remote-ssh-health.sh`'s `/dev/tcp` probe, where `_service_health.sh` selects
# the operator-facing verdict BY KEYWORD from that very stream, so a port taken
# by a foreign squatter reported as our daemon being down. Two independent
# authorings is a class, not a slip, and a class closed only by fixing its
# instances reopens with instance N+1.
#
# WHAT A GREEN CERTIFIES, AND WHAT IT DOES NOT. It certifies that no PRODUCTION
# shell file pairs a `/proc/<expansion>` redirection with a later
# `2>/dev/null`, and that the remaining test-file population has not grown. It
# does NOT certify that every ungrouped redirection in the repo is sound: the
# predicate is keyed on the one target family whose absence at read time is
# routine and unavoidable. `#1305` declines to establish the wider population
# for a good reason — the shape is only a defect when the target CAN vanish,
# which is a runtime property — and a lint that guessed at that would produce a
# number nobody can act on.
#
# THE TEST-FILE REMAINDER IS RATCHETED, NOT FIXED, AND THAT IS DELIBERATE. A
# stderr leak in a test has no consumer parsing it, so the harm the issue names
# — "a helper that prints unexpected stderr trains its readers to ignore its
# stderr, and that is where a real diagnostic goes to die" — does not apply.
# Fixing 22 sites across 14 test files would buy hygiene at the cost of a wide
# diff and real conflict surface against other branches. The ceiling below can
# only go DOWN, so the class cannot grow and the remainder is recorded rather
# than invisible.
#
# Run: bash monitor/watcher/test-proc-redirect-order.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# The shared helpers, ADOPTED rather than opted out of. `th_summary_and_exit`
# gives the subshell-durable ledger (`#805` — a FAIL lost to a subshell must
# still red the suite); the `_EXPECTED_ASSERTIONS` guard at the bottom reddens
# a VANISHED assertion (`#807`). Different properties, neither implying the
# other, and `summary-honesty.manifest` requires both of a new suite. Appending
# a manifest row instead would opt this suite's own new code out of the
# standard — which its own header says is what NOT to do.
# shellcheck source=/dev/null
. "$_test_dir/_test_helpers.sh"
_repo_root=$(cd "$_test_dir/../.." && pwd)
GEN="$_test_dir/proc-redirect-order.sh"
AWKF="$_test_dir/_proc_redirect_order.awk"

# THE CEILING. Re-derive with:
#     bash monitor/watcher/proc-redirect-order.sh | wc -l
# at the ref you are reading. A count is a property of a TREE, so the command
# and the ref belong beside it: 22 at `dev` @ the #1305 merge. Lower this
# whenever sites are fixed; never raise it.
TEST_FILE_CEILING=22
# The population floor. A vacuous enumeration yields zero sites, which reads
# exactly like a clean tree — the silent-zero shape this repo's own dominant
# defect class. 607 shell files at the same ref; the floor is deliberately far
# below it so ordinary growth and pruning do not red the suite.
POPULATION_FLOOR=300

pass() { printf '  PASS: %s\n' "$1"; _th_pass; }
fail() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }

[[ -r "$GEN"  ]] || { echo "missing $GEN"  >&2; exit 1; }
[[ -r "$AWKF" ]] || { echo "missing $AWKF" >&2; exit 1; }

echo "=== the enumeration is non-vacuous ==="

pop_n=$(bash "$GEN" --files "$_repo_root" | wc -l)
if (( pop_n >= POPULATION_FLOOR )); then
    pass "population is $pop_n shell files (floor $POPULATION_FLOOR) — a zero below would be a claim I could not vouch for"
else
    fail "population is $pop_n shell files, below the floor $POPULATION_FLOOR — refusing to read any zero from it"
fi

sites_raw=$(bash "$GEN" "$_repo_root"); gen_rc=$?
# THIS SUITE'S OWN PLANTED SPECIMENS ARE EXCLUDED FROM THE COUNTS, and the
# exclusion is safe only because of what replaces it. The potency block below
# plants three leaking forms as literal source lines, so the classifier — whose
# population is every shell file — finds them here. That is correct behaviour
# and it is precisely CLAUDE.md's recorded trap: `test-ambient-shell-option-scope`
# printed three paths, two of which were its own fixtures, and counting them
# made one problem look like three. The guidance there is "read the LIST, not
# the count" — which a human can do and an assertion cannot.
#
# So the specimens are dropped from the count, and their continued existence is
# asserted DIRECTLY in the potency block: if a plant is ever removed or
# reworded, those assertions fail. The exclusion therefore cannot hide a
# regression; it can only hide this file, whose specimens are checked by name.
_SELF="monitor/watcher/$(basename "$0")"
sites=$(printf '%s\n' "$sites_raw" | awk -v self="$_SELF" 'BEGIN{FS="\t"} $1 != self {print}')
if (( gen_rc == 0 )); then
    pass "the classifier ran (rc 0)"
else
    fail "the classifier exited $gen_rc — its verdict is not a measurement"
fi

echo "=== PRODUCTION shell files carry ZERO redirection-order sites ==="

# THE SPLIT IS ON FIELD 1, NOT ON THE WHOLE ROW. A row is
# `<file>\t<line>\t<code>`, so an end-anchored path pattern applied to the row
# never matches — the code column follows the path. The first cut of this did
# exactly that and reported every test file as production: a filter that
# silently matches NOTHING, inside a suite whose verdict is a count. Split with
# awk on the field, so the pattern is applied to the thing it describes.
#
# The production/test split is a FILENAME predicate, and its direction of error
# is stated rather than left to be inferred: a production file misnamed
# `test-*` would escape the zero rule. That direction is permissive, so the
# floor assertion below — production files must still be a large majority —
# is what keeps the split honest.
_is_test_row='BEGIN{FS="\t"} $1 ~ /(^|\/)test-[^\/]*$/ || $1 ~ /\/test-integration\// {print}'
_not_test_row='BEGIN{FS="\t"} $1 !~ /(^|\/)test-[^\/]*$/ && $1 !~ /\/test-integration\// {print}'
prod_rows=$(printf '%s\n' "$sites" | awk "$_not_test_row")
prod_sites=$(printf '%s' "$prod_rows" | grep -c . || true)
if (( prod_sites == 0 )); then
    pass "no production shell file pairs a /proc/<expansion> redirection with a later 2>/dev/null"
else
    printf '%s\n' "$prod_rows" >&2
    fail "$prod_sites production site(s) above — group the redirection: { cmd < FILE; } 2>/dev/null"
fi

prod_pop=$(bash "$GEN" --files "$_repo_root" | grep -cvE '(^|/)test-[^/]*$|/test-integration/' || true)
# (that one IS a bare path list, one per line, so an end-anchored pattern is
# correct here — the distinction is what the first cut above got wrong.)
if (( prod_pop >= 100 )); then
    pass "the production side of the split is $prod_pop files — the zero above is about a real population"
else
    fail "the production side of the split is only $prod_pop files — the split, not the tree, is what to check"
fi

echo "=== the test-file remainder RATCHETS ==="

total=$(printf '%s' "$sites" | grep -c . || true)
if (( total <= TEST_FILE_CEILING )); then
    pass "$total site(s) total, ceiling $TEST_FILE_CEILING (lower this when sites are fixed; never raise it)"
else
    fail "$total site(s) total, above the ceiling $TEST_FILE_CEILING — a NEW site joined the class"
fi

echo "=== POTENCY: each distinction the classifier draws is load-bearing ==="

# Every arm is exercised against a planted fixture. A classifier whose
# exemptions are never tested is a classifier whose exemptions are guesses —
# and an over-broad exemption here is silent, because it presents as a clean
# tree.
FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

_plant() {   # _plant <name> <line>
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$FIX/$1"
}
_hits() { awk -f "$AWKF" "$FIX/$1" | grep -c . || true; }

_plant leak.sh          'cmdl=$(tr "\0" " " < "/proc/$pid/cmdline" 2>/dev/null)'
_plant leak_loop.sh     'while read -r a; do :; done < "/proc/$pid/cmdline" 2>/dev/null'
_plant leak_andarm.sh   '[[ -r x ]] && { d=$(tr "\0" "\n" < "/proc/$pid/environ" 2>/dev/null) || d=""; }'
_plant ok_grouped.sh    'cmdl=$( { tr "\0" " " < "/proc/$pid/cmdline"; } 2>/dev/null )'
_plant ok_stderrfirst.sh 'cmdl=$(2>/dev/null tr "\0" " " < "/proc/$pid/cmdline")'
_plant ok_static.sh     'while read -r l; do :; done < /proc/stat 2>/dev/null'
_plant ok_nonproc.sh    'x=$(cat < "$HOME/$f" 2>/dev/null)'
_plant ok_comment.sh    '# cmdl=$(tr "\0" " " < "/proc/$pid/cmdline" 2>/dev/null)'
_plant ok_noredir.sh    'cmdl=$(ps -o args= "$pid" 2>/dev/null)'

for _f in leak.sh leak_loop.sh leak_andarm.sh; do
    if (( $(_hits "$_f") == 1 )); then
        pass "DETECTS the leaking form: $_f"
    else
        fail "MISSED the leaking form: $_f — the classifier cannot see the defect it exists for"
    fi
done

# `leak_andarm.sh` is the one that matters most among the positives: a hand
# sweep over this repo scored exactly that shape CLEAN, because the `; }` it
# saw belonged to the `&&` arm rather than to the redirection, and the
# `2>/dev/null` was still inside it. The classifier disagreed and was right —
# which is the argument for having a classifier at all.

for _f in ok_grouped.sh ok_stderrfirst.sh ok_static.sh ok_nonproc.sh ok_comment.sh ok_noredir.sh; do
    if (( $(_hits "$_f") == 0 )); then
        pass "EXEMPTS, correctly: $_f"
    else
        fail "FALSE POSITIVE on $_f — an exemption this classifier must draw"
    fi
done

# Every assertion this file declares must actually RUN. A guard whose
# assertions silently stop executing reports 0 failures, which reads as a pass
# — the defect class this whole suite is about, one level up.
_EXPECTED_ASSERTIONS=14
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$_EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
