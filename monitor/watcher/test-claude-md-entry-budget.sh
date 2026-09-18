#!/usr/bin/env bash
# your-org/nexus-code#904 — THE `## Common gotchas` ENTRY BUDGET.
#
# CLAUDE.md is loaded into every session of every operator's nexus. Its
# `## Common gotchas` section grew 3x in three weeks by appending incident
# narratives, was trimmed once by hand (PR #1473), and would regrow at the same
# rate on the same convention. This guard is the rate control the operator
# chose: it PRINTS every entry's size on every run (a number placed where the
# decision is made) and reds only past a GENEROUS ceiling declared in
# `claude-md-entry-budget.manifest`. The remedy for a red is not to shorten
# the prose — it is to move the long form into a skill and leave a one-line
# "use when" row, which is what the Skills table exists for.
#
# An ENTRY is a top-level bullet (`- **…`) between `## Common gotchas` and the
# next `## ` heading; its size is the number of lines up to the next bullet or
# heading, blank lines included (they are context an agent pays for too).
#
# Run: bash monitor/watcher/test-claude-md-entry-budget.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
DOC="$_repo_root/CLAUDE.md"
MANIFEST="$_test_dir/claude-md-entry-budget.manifest"

# _entries <file>  ->  "<lines>\t<first 70 chars of the bullet>" per entry
_entries() {
    awk '
        /^## Common gotchas/ { s=1; next }
        s && /^## /          { if (n) printf "%d\t%s\n", n, h; s=0; n=0 }
        s && /^- \*\*/       { if (n) printf "%d\t%s\n", n, h; n=0; h=substr($0,1,70) }
        s && n>=0 && (h!="") { n++ }
        END                  { if (n) printf "%d\t%s\n", n, h }
    ' "$1"
}
_kv() { sed -nE "s/^$1=([0-9]+)\$/\1/p" "$MANIFEST"; }   # exactly one line; two fail the integer check

# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() { printf '%s\n' "CLAUDE.md" "monitor/watcher/claude-md-entry-budget.manifest"; }
gp_handle "$@"

# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"

[[ -r "$DOC" ]]      || { echo "missing $DOC" >&2; exit 1; }
[[ -r "$MANIFEST" ]] || { echo "missing $MANIFEST" >&2; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

echo '=== 1. the budget is declared, and the extractor is not silently empty ==='
LINES_CEIL=$(_kv entry_lines_ceiling); ENTRIES_CEIL=$(_kv entries_ceiling)
assert_eq "entry_lines_ceiling declared" "$( [[ "$LINES_CEIL"   =~ ^[0-9]+$ ]] && echo yes || echo NO )" "yes"
assert_eq "entries_ceiling declared"     "$( [[ "$ENTRIES_CEIL" =~ ^[0-9]+$ ]] && echo yes || echo NO )" "yes"
_entries "$DOC" > "$WORK/entries"
_n=$(grep -c . "$WORK/entries")
_n_indep=$(awk '/^## Common gotchas/{s=1;next} s&&/^## /{s=0} s&&/^- \*\*/{c++} END{print c+0}' "$DOC")
assert_eq "entries extracted (>0)" "$( (( _n > 0 )) && echo yes || echo NO )" "yes"
assert_eq "…and the count agrees with an independent bullet count ($_n_indep)" "$_n" "$_n_indep"

echo '=== 2. the numbers, printed on every run — the decision is made here ==='
sort -rn "$WORK/entries" | awk -F'\t' -v c="$LINES_CEIL" '{ flag=($1>c)?"  <-- OVER":""; printf "    %4d lines  %s%s\n", $1, $2, flag }'
printf '    %d entries (ceiling %s); largest %s lines (ceiling %s); section total %s lines; CLAUDE.md %s lines\n' \
    "$_n" "$ENTRIES_CEIL" "$(awk -F'\t' 'NR==1 || $1>m {m=$1} END{print m+0}' "$WORK/entries")" "$LINES_CEIL" \
    "$(awk -F'\t' '{s+=$1} END{print s+0}' "$WORK/entries")" "$(wc -l < "$DOC" | tr -d ' ')"

echo '=== 3. the ceilings ==='
_over=$(awk -F'\t' -v c="$LINES_CEIL" '$1>c {printf "%s(%d) ", $2, $1}' "$WORK/entries")
assert_eq "no entry exceeds $LINES_CEIL lines (move the long form into a skill; leave a one-line row)" "$_over" ""
assert_eq "entry count $_n within the ceiling $ENTRIES_CEIL" \
    "$( (( _n <= ENTRIES_CEIL )) && echo yes || echo NO )" "yes"

echo '=== 4. POSITIVE CONTROLS — the extractor and the ceiling can fire ==='
{ printf '## Common gotchas\n\n- **short entry** one line\n\n- **long entry**\n'; for i in $(seq 1 "$LINES_CEIL"); do printf '  line %d\n' "$i"; done; printf '\n## Next\n- **not an entry** outside the section\n'; } > "$WORK/plant.md"
_pl=$(_entries "$WORK/plant.md")
assert_eq "PC1: the planted section yields exactly 2 entries (the one outside the section is not counted)" "$(grep -c . <<<"$_pl")" "2"
_pl_over=$(awk -F'\t' -v c="$LINES_CEIL" '$1>c {print $2}' <<<"$_pl")
assert_eq "PC2: the planted over-budget entry IS detected" "$_pl_over" "- **long entry**"
assert_eq "PC3: …and the short one is not" "$(awk -F'\t' -v c="$LINES_CEIL" '$1<=c {print $2}' <<<"$_pl" | grep -c .)" "1"

_EXPECTED_ASSERTIONS=9
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$_EXPECTED_ASSERTIONS" >&2; _th_fail
fi
th_summary_and_exit
