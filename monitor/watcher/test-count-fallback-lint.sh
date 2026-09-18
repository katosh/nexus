#!/usr/bin/env bash
# test-count-fallback-lint.sh — both-directions coverage for
# monitor/watcher/count-fallback-lint.sh (your-org/nexus-code#725).
#
# A lint is only worth its maintenance if BOTH its directions are checked. A
# lint that flags nothing passes a clean tree and a broken one identically;
# a lint that flags everything gets muted within a week. So every case below
# plants a fixture and states which direction it pins:
#
#   POSITIVE — the defect, in each spelling seen live on `dev`. Each MUST be
#              flagged, or the lint's green is a claim about its regex rather
#              than about the tree.
#   NEGATIVE — the CORRECT forms, plus the near-misses that share the defect's
#              silhouette (`wc -l <`, `grep -qc`, a `||` belonging to a later
#              command on the same line). Each MUST NOT be flagged.
#
# The negatives are the load-bearing half. `#682` makes the point directly:
# converting on a raw grep count "would churn hundreds of safe sites and spend
# the review attention that catches the real ones."
#
# Run: bash monitor/watcher/test-count-fallback-lint.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LINT="$_dir/count-fallback-lint.sh"

# ---------------------------------------------------------------------------
# POPULATION DECLARATION (your-org/nexus-code#1494, #1301 item 2)
# ---------------------------------------------------------------------------
#
# THIS SUITE WENT RED ON PR #1493 FOR A REAL DEFECT IN THAT DIFF — and
# `guards-for-diff` had returned rc 0 with 28 guards SELECTED and green,
# listing this one in NEITHER `SELECTED` nor `CONSIDERED AND EXCLUDED`. It
# declared no population, so the index could not see it at all: invisible, not
# excluded, and an absence in both blocks is indistinguishable from a
# considered exclusion. The two guards the index could not see were precisely
# the two that caught real defects.
#
# The population is the lint's OWN selection, forwarded via `--files`, never a
# copy: a second implementation of a population drifts until the index reports,
# with total confidence, that this guard does not read a file it does read.
# The declaration is NOT the fixture tree — those live under $WORK and no diff
# can touch them. What makes this suite routable is its LAST case, which runs
# the lint over the REAL repo, so any file that lint scans can redden it.
#
# PLACED HERE, above the first thing this suite prints: `gp_handle` EXITS when
# it handles the flag, and anything printed before it lands in the probe's
# stdout and is read as a population row.
. "$_dir/../_guard_population.sh"
gp_population() {
    bash "$LINT" --files "$(cd "$_dir/../.." && pwd)"
    printf '%s\n' 'monitor/watcher/count-fallback-lint.sh'
}
gp_handle "$@"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# plant <relative-path> <line…> — build a fixture tree rooted at $WORK/tree.
# DECLARED per case, never mutated incrementally: each case rebuilds the tree
# from scratch, so a fixture cannot leak into the next case and answer through
# a path it was never written to reach (#718's B6c bought that lesson).
_plant() {
    rm -rf "$WORK/tree"; mkdir -p "$WORK/tree/monitor/watcher"
    local rel="$1"; shift
    mkdir -p "$WORK/tree/$(dirname "$rel")"
    { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } > "$WORK/tree/$rel"
}
# The fixture bodies below assemble `||` from `$_OR` instead of writing it
# literally. Not cosmetic: the lint scans all of `monitor/`, so a literal
# `grep -c … || echo 0` inside THIS file is indistinguishable from a real
# site and would make the lint flag its own test — one hit, forever, in the
# tree it certifies clean. The alternative is an allowlist exempting this
# path, and a lint with an exemption for the file most likely to contain the
# pattern is a lint with a hole shaped like its own author. Keeping the
# literal out of the source keeps the scan uniform and needs no exception.
_OR='||'

# _lint_hits → number of rows the lint printed (0 when clean).
_lint_hits() {
    local out
    out=$(bash "$LINT" "$WORK/tree" 2>/dev/null)
    # `grep -c` prints 0 on no match and exits 1; `|| true` REPLACES nothing
    # and appends nothing. `|| echo 0` here would be this suite committing the
    # very defect it exists to catch.
    printf '%s' "$out" | grep -c ':' || true
}
# _lint_rc → the lint's exit status (1 iff it flagged something).
_lint_rc() { bash "$LINT" "$WORK/tree" >/dev/null 2>&1; printf '%s' "$?"; }

echo '=== POSITIVE: every live spelling is flagged ==='

_plant monitor/watcher/a.sh 'n=$(grep -c PATTERN "$f" 2>/dev/null '"$_OR"' echo 0)'
assert_eq "plain assignment + fallback that PRINTS"            "$(_lint_hits)" "1"
assert_eq "…and the lint exits non-zero"            "$(_lint_rc)"   "1"

_plant monitor/watcher/a.sh "held=\$(grep -c \$'\\theld\\t' \"\$LOG\" 2>/dev/null $_OR printf '0')"
assert_eq "printf fallback (not just echo)"         "$(_lint_hits)" "1"

_plant monitor/watcher/a.sh 'x=$(ps -Lu "$(id -u)" -o pid= 2>/dev/null | grep -c . '"$_OR"' echo '"'"'?'"'"')'
assert_eq "pipeline ending in grep -c, non-numeric fallback" "$(_lint_hits)" "1"

_plant monitor/watcher/a.sh 'rows() { [[ -f "$LOG" ]] && grep -c PATTERN "$LOG" '"$_OR"' echo 0; }'
assert_eq "guarded: the && precedes the grep, so the fallback is still its own" "$(_lint_hits)" "1"

_plant monitor/watcher/a.sh 'assert_eq "lbl" "$(grep -c PATTERN "$F" 2>/dev/null '"$_OR"' echo 0)" "1"'
assert_eq "inside a command substitution used as an argument" "$(_lint_hits)" "1"

_plant monitor/watcher/a.sh 'n=$(grep -c PATTERN "$(path_of x)" 2>/dev/null '"$_OR"' echo 0)'
assert_eq "operand is itself a command substitution"  "$(_lint_hits)" "1"

_plant monitor/ng 'n=$(grep -c PATTERN "$f" '"$_OR"' echo 0)'
assert_eq "extensionless executables (ng) are in scope" "$(_lint_hits)" "1"
_plant monitor/notifywrap/sandbox-notify 'n=$(grep -c PATTERN "$f" '"$_OR"' echo 0)'
assert_eq "extensionless executables (sandbox-notify) are in scope" "$(_lint_hits)" "1"

# your-org/nexus-code#730. `.github/` joined the roots, and the file rule moved
# with it: every file there is YAML, so widening the find root ALONE would have
# left the name filter rejecting all of them — a root that is scanned and can
# never match is a boundary claim the lint cannot support. Both halves are
# pinned here, in both directions.
_plant .github/workflows/w.yml '          listed=$(bash x.sh --list | grep -c "(integration" '"$_OR"' echo 0)'
assert_eq "#730: workflow YAML under .github/ IS in scope" "$(_lint_hits)" "1"
assert_eq "…and the lint exits non-zero for it"            "$(_lint_rc)"   "1"

echo '=== NEGATIVE: the correct forms and the near-misses are NOT flagged ==='

_plant monitor/watcher/a.sh 'n=$(grep -c PATTERN "$f" 2>/dev/null) || n=0'
assert_eq "the REMEDY (replace, do not append) is clean" "$(_lint_hits)" "0"
assert_eq "…and the lint exits 0"                        "$(_lint_rc)"   "0"

_plant monitor/watcher/a.sh 'n=$(grep -c PATTERN "$f" 2>/dev/null || true)'
assert_eq "|| true is clean"                            "$(_lint_hits)" "0"

_plant monitor/watcher/a.sh 'grep -c PATTERN "$f" >/dev/null || return 0'
assert_eq "|| return is clean (prints nothing)"         "$(_lint_hits)" "0"

_plant monitor/watcher/a.sh 'n=$(wc -l < "$f" 2>/dev/null || echo 0)'
assert_eq "wc -l < … || echo 0 is NOT this defect (declared off-axis)" \
    "$(_lint_hits)" "0"

_plant monitor/watcher/a.sh 'if grep -qc PATTERN "$f"; then echo yes || echo no; fi'
assert_eq "grep -qc prints nothing, so it is not the defect" "$(_lint_hits)" "0"

# The exact false positive a line-wide regex produces, and the reason the axis
# names ADJACENCY: this `||` belongs to `_visible`, not to the `grep -c`.
_plant monitor/watcher/a.sh 'fail "renames=$(grep -c rename "$L") vis=$(_visible "$P" && echo yes || echo no)"'
assert_eq "a || belonging to a LATER command on the same line is not flagged" \
    "$(_lint_hits)" "0"

_plant monitor/watcher/a.sh '# n=$(grep -c PATTERN "$f" 2>/dev/null '"$_OR"' echo 0)'
assert_eq "a commented-out instance is not flagged"     "$(_lint_hits)" "0"

_plant monitor/watcher/notes.md 'n=$(grep -c PATTERN "$f" '"$_OR"' echo 0)'
assert_eq "non-shell files are off-axis"                "$(_lint_hits)" "0"

# The other side of #730's YAML arm: it is scoped to `.github/` on purpose, so
# YAML elsewhere stays off-axis. Without this the widening would silently be
# "all YAML anywhere", which is a different boundary than the one declared.
_plant monitor/watcher/ci.yml 'n=$(grep -c PATTERN "$f" '"$_OR"' echo 0)'
assert_eq "#730: YAML OUTSIDE .github/ stays off-axis"  "$(_lint_hits)" "0"

# A fixture tree with no `.github/` at all must still lint cleanly rather than
# erroring on a missing root — every other case above is exactly that tree, so
# this pins the reason they keep working.
_plant monitor/watcher/a.sh 'n=$(grep -c PATTERN "$f" 2>/dev/null) || n=0'
assert_eq "a tree with no .github/ is not an error"     "$(_lint_rc)"   "0"

echo '=== the repo itself is clean, and that green is non-vacuous ==='
# Asserted TOGETHER with the positives above: "the tree is clean" means
# something only because the cases above proved this lint can go red.
_repo_root=$(cd "$_dir/../.." && pwd)
bash "$LINT" "$_repo_root" >/dev/null 2>&1
assert_eq "monitor/ + .github/ carry no \`grep -c … || <print>\` site" "$?" "0"

th_summary_and_exit
