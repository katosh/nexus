#!/usr/bin/env bash
# your-org/nexus-code#1264 R5 — THE SKILLS CATALOG IS A SET-EQUALITY CLAIM.
#
# "Any enumeration feeding a decision must be a set-equality assertion against
# a generator, never an exemplification." `docs/reference/skills.md` is the
# catalog every operator reads to learn which skills exist, and it SAYS of
# itself that it is a claim of set equality — while asserted by nothing. At
# the census ref (dev 2a299572, 2026-09-06) it listed 19 skills against 21
# shipped skill directories: `nexus.ci-triage` and `nexus.claims` were
# missing, exactly the drift #1264 measured once before (16 against 19) and
# the doc's own warning box was written about. An enumeration that is merely
# illustrative cannot be wrong, which is why nobody notices when it stops
# being complete.
#
# GENERATOR: every tracked `skills/<name>/` that ships a `SKILL.md` or a
# `GUIDE.md` (`nexus.cc-update` deliberately ships GUIDE.md only — see its
# catalog entry). CLAIMS CHECKED, both directions:
#   table rows   `| [`<name>`](#…) | … |`   <->  directories
#   sections     `## `<name>``               <->  directories
#
# Run: bash monitor/watcher/test-skills-catalog.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
DOC="$_repo_root/docs/reference/skills.md"

_skill_dirs() {
    ( cd "$_repo_root" && git ls-files -- ':(glob)skills/*/SKILL.md' ':(glob)skills/*/GUIDE.md' \
        | sed 's#^skills/##; s#/.*##' | sort -u )
}
_table_rows() { grep -oE '^\| \[`[A-Za-z0-9_.-]+`\]' "$DOC" | sed -E 's/^\| \[`//; s/`\]$//' | sort -u; }
_sections()   { grep -oE '^## `[A-Za-z0-9_.-]+`$' "$DOC" | sed -E 's/^## `//; s/`$//' | sort -u; }

# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' "docs/reference/skills.md"
    ( cd "$_repo_root" && git ls-files -- ':(glob)skills/*/SKILL.md' ':(glob)skills/*/GUIDE.md' )
}
gp_handle "$@"

# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"

[[ -r "$DOC" ]] || { echo "missing $DOC" >&2; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

echo '=== 1. the generator and both extractors are not silently empty ==='
_skill_dirs > "$WORK/dirs"; _table_rows > "$WORK/rows"; _sections > "$WORK/secs"
_n_dirs=$(grep -c . "$WORK/dirs"); _n_rows=$(grep -c . "$WORK/rows"); _n_secs=$(grep -c . "$WORK/secs")
# `find`, not `ls -d …/skills/*/`: under nullglob an unmatched glob VANISHES and a
# bare `ls -d` lists the cwd — the pairing nullglob-bare-form.manifest tracks (#1214).
_n_indep=$(find "$_repo_root/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
assert_eq "skill directories found (>0)" "$( (( _n_dirs > 0 )) && echo yes || echo NO )" "yes"
assert_eq "…and the tracked count agrees with an independent directory listing ($_n_indep)" "$_n_dirs" "$_n_indep"
assert_eq "table rows extracted (>0)" "$( (( _n_rows > 0 )) && echo yes || echo NO )" "yes"
assert_eq "sections extracted (>0)"   "$( (( _n_secs > 0 )) && echo yes || echo NO )" "yes"

echo '=== 2. set equality, BOTH directions, directories <-> table rows ==='
assert_eq "every shipped skill has a catalog table row" \
    "$(comm -23 "$WORK/dirs" "$WORK/rows" | tr '\n' ' ' | sed 's/ $//')" ""
assert_eq "no table row names a skill that does not ship" \
    "$(comm -13 "$WORK/dirs" "$WORK/rows" | tr '\n' ' ' | sed 's/ $//')" ""

echo '=== 3. set equality, BOTH directions, directories <-> sections ==='
assert_eq "every shipped skill has a catalog section" \
    "$(comm -23 "$WORK/dirs" "$WORK/secs" | tr '\n' ' ' | sed 's/ $//')" ""
assert_eq "no section names a skill that does not ship" \
    "$(comm -13 "$WORK/dirs" "$WORK/secs" | tr '\n' ' ' | sed 's/ $//')" ""

echo '=== 4. POSITIVE CONTROLS — the extractors see what they must ==='
printf '| [`zz.planted-skill`](#zzplanted-skill) | nobody | plant |\n## `zz.planted-section`\n' > "$WORK/plant.md"
assert_eq "PC1: a planted table row is extracted"  "$(DOC="$WORK/plant.md" _table_rows)" "zz.planted-skill"
assert_eq "PC2: a planted section is extracted"    "$(DOC="$WORK/plant.md" _sections)"   "zz.planted-section"
printf '%s\n' "$(cat "$WORK/dirs")" "zz.planted-skill" | sort > "$WORK/d2"
assert_eq "PC3: a directory with no row IS detected" \
    "$(comm -23 "$WORK/d2" "$WORK/rows" | tr '\n' ' ' | sed 's/ $//')" "zz.planted-skill"

_EXPECTED_ASSERTIONS=11
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$_EXPECTED_ASSERTIONS" >&2; _th_fail
fi
th_summary_and_exit
