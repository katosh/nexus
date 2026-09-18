#!/usr/bin/env bash
# your-org/nexus-code#1301 item 3 — NON-DECLARATION IS EXPLICIT AND REVIEWED.
#
# Every tracked test suite is in exactly ONE of two sets: it DECLARES a
# population to the guards-for-diff index (both protocol tokens present), or it
# has a row in `suite-declarations.manifest` saying it does not, and why. A new
# suite that does neither is RED here — so the index's blind spot can no longer
# grow silently, and its `unreviewed` share is a ratchet that only goes down.
#
# What goes red:
#   a tracked suite that neither declares nor has a row      -> RED (§2)
#   a row for a suite that now declares (stale row)          -> RED (§2)
#   a row for a suite that no longer exists                  -> RED (§2)
#   the `unreviewed` count above the manifest's ceiling      -> RED (§3)
#   an unknown status token                                  -> RED (§3)
#
# Run: bash monitor/watcher/test-suite-declaration-census.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
MANIFEST="$_test_dir/suite-declarations.manifest"
# THE SAME TWO TOKENS guards-for-diff keys on (GFD_DECL / GFD_DECL2) — one
# predicate, not two, so this census and the index cannot disagree.
DECL1='gp_handle "$@"'; DECL2='gp_population()'

_rows()   { grep -vE '^[[:space:]]*(#|$)' "$MANIFEST"; }
_suites() { ( cd "$_repo_root" && git ls-files -- ':(glob)**/test-*.sh' | sort -u ); }
_declares() { grep -qF -- "$DECL1" "$1" 2>/dev/null && grep -qF -- "$DECL2" "$1" 2>/dev/null; }

# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() { printf '%s\n' "monitor/watcher/suite-declarations.manifest"; _suites; }
gp_handle "$@"

# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
[[ -r "$MANIFEST" ]] || { echo "missing $MANIFEST" >&2; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

echo '=== 1. the generator is not silently empty ==='
_suites > "$WORK/all"
_n_all=$(grep -c . "$WORK/all")
_n_indep=$(cd "$_repo_root" && find monitor .github -name 'test-*.sh' -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "tracked suites found (>= 50)" "$( (( _n_all >= 50 )) && echo yes || echo NO )" "yes"
assert_eq "…and the git enumeration agrees with the runner's find ($_n_indep)" "$_n_all" "$_n_indep"
: > "$WORK/decl"; : > "$WORK/nondecl"
while IFS= read -r f; do
    if _declares "$_repo_root/$f"; then echo "$f" >> "$WORK/decl"; else echo "$f" >> "$WORK/nondecl"; fi
done < "$WORK/all"
assert_eq "some suites declare (>0)"      "$( (( $(grep -c . "$WORK/decl") > 0 )) && echo yes || echo NO )" "yes"

echo '=== 2. partition: declaring ∪ rows == all suites, disjoint ==='
_rows | cut -d'|' -f1 | sort -u > "$WORK/rows"
assert_eq "every non-declaring suite has a row (a NEW suite must declare or be classified — never silently invisible)" \
    "$(comm -23 "$WORK/nondecl" "$WORK/rows" | tr '\n' ' ' | sed 's/ $//')" ""
assert_eq "no row names a suite that DECLARES (a stale row — remove it)" \
    "$(comm -12 "$WORK/decl" "$WORK/rows" | tr '\n' ' ' | sed 's/ $//')" ""
assert_eq "no row names a suite that is gone" \
    "$(comm -13 "$WORK/all" "$WORK/rows" | tr '\n' ' ' | sed 's/ $//')" ""
assert_eq "one row per suite" "$(_rows | cut -d'|' -f1 | sort | uniq -d | grep -c .)" "0"

echo '=== 3. status vocabulary and the unreviewed ratchet ==='
_bad=$(_rows | awk -F'|' '$2!="declares-none" && $2!="unreviewed" {printf "%s(%s) ", $1, $2} $3=="" {printf "%s(no-reason) ", $1}')
assert_eq "every row carries a known status and a reason" "$_bad" ""
_ceiling=$(sed -nE 's/^# unreviewed-ceiling: ([0-9]+)$/\1/p' "$MANIFEST")   # exactly one line; two fail the integer check
_n_unrev=$(_rows | awk -F'|' '$2=="unreviewed"' | grep -c .)
assert_eq "the manifest declares an unreviewed-ceiling" "$( [[ "$_ceiling" =~ ^[0-9]+$ ]] && echo yes || echo NO )" "yes"
assert_eq "unreviewed ($_n_unrev) within the ceiling (${_ceiling:-?}) — reviewing lowers it, nothing raises it silently" \
    "$( [[ "$_ceiling" =~ ^[0-9]+$ ]] && (( _n_unrev <= _ceiling )) && echo yes || echo NO )" "yes"
printf '    declaring: %s   declares-none: %s   unreviewed: %s   (of %s tracked suites)\n' \
    "$(grep -c . "$WORK/decl")" "$(_rows | awk -F'|' '$2=="declares-none"' | grep -c .)" "$_n_unrev" "$_n_all"

echo '=== 4. POSITIVE CONTROLS ==='
printf '%s\n' "$(cat "$WORK/nondecl")" "monitor/watcher/test-zz-planted-new-suite.sh" | sort > "$WORK/nd2"
assert_eq "PC1: a new non-declaring suite with no row IS detected" \
    "$(comm -23 "$WORK/nd2" "$WORK/rows" | tr '\n' ' ' | sed 's/ $//')" "monitor/watcher/test-zz-planted-new-suite.sh"
read -r _first_decl < "$WORK/decl"
printf '%s\n' "$(cat "$WORK/rows")" "$_first_decl" | sort -u > "$WORK/r2"
assert_eq "PC2: a row for a DECLARING suite IS detected as stale" \
    "$(comm -12 "$WORK/decl" "$WORK/r2" | tr '\n' ' ' | sed 's/ $//')" "$_first_decl"
printf '#!/usr/bin/env bash\ngp_population() { :; }\ngp_handle "$@"\n' > "$WORK/decl.sh"
assert_eq "PC3: the declaration predicate recognises a planted declaring suite" "$(_declares "$WORK/decl.sh" && echo yes || echo NO)" "yes"
printf '#!/usr/bin/env bash\n# mentions gp_population() in prose only\n' > "$WORK/nodecl.sh"
assert_eq "PC4: …and does not recognise a prose mention (both tokens required)" "$(_declares "$WORK/nodecl.sh" && echo yes || echo no)" "no"

_EXPECTED_ASSERTIONS=14
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$_EXPECTED_ASSERTIONS" >&2; _th_fail
fi
th_summary_and_exit
