#!/usr/bin/env bash
# your-org/nexus-code#1264 R2 — THE MARKER-TO-SUITE OWNERSHIP RATCHET.
#
# `CLAUDE.md` states its own convention: "a `BEGIN`/`END` marker in this file
# is a promise that a suite executes the block". Nothing checked the promise,
# and `run-tests.sh` discovers suites by GLOB, so nothing could: a marker with
# no owner, a marker whose owner was deleted, and a marker that never needed
# one are the same silence.
#
# The dangerous case is not a red test. It is a block that is UNOWNED AND
# CURRENTLY TRUE — nothing looks broken, so nobody looks, and it rots at the
# speed of the code beneath it.
#
# ── THE PREDICATE IS DECLARED, NOT DERIVED, AND THAT IS THE FINDING ───────
#
# Deriving the owner from the marker NAME is #1121's shape, and both natural
# spellings are wrong in OPPOSITE directions. Measured on this tree while
# writing this suite (2026-09-02, dev @ 0b82ffb2):
#
#   narrow  `git grep -l "BEGIN <NAME> -->" -- monitor/watcher`   4 of 24 read
#           as UNOWNED while three of them are executed — the owners spell the
#           marker three ways (`<!-- BEGIN X -->`, a bare `BEGIN X` in an awk
#           range, a `_block X` argument).
#   broad   `git grep -l "<NAME>" -- monitor`                     OVER-finds;
#           `DASH-PATTERN-OPTION` matches 6 files, `GREP-BRE-DIALECT` 5, none
#           of the extras executing anything.
#
# A predicate wrong in both directions cannot be repaired by widening or
# narrowing it, so ownership is DECLARED — all 24 rows, no exception list.
# The only GENERATED thing is the marker set the rows are checked against.
#
# ── WHAT GOES RED, WHICH IS THE POINT OF BUILDING THIS AT ALL ─────────────
#
#   add a marker to CLAUDE.md with no manifest row      -> RED (§3)
#   delete a marker, leave the row                      -> RED (§3)
#   rename or delete an owner suite                     -> RED (§4)
#   an owner that no longer names its marker            -> RED (§4)
#   a BEGIN with no matching END                        -> RED (§2)
#   the unexecuted (`drives`/`unowned`) set GROWS       -> RED (§5)
#
# An index nothing keeps current is worse than none. Those six are what keeps
# this one current.
#
# Run: bash monitor/watcher/test-claude-md-marker-ownership.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
DOC="$_repo_root/CLAUDE.md"
MANIFEST="$_test_dir/claude-md-markers.manifest"

# The manifest's data rows. Defined HERE rather than further down because
# `gp_population` below CALLS it, and the protocol REFUSES (rc 127 -> gp_render
# declines) rather than reporting a population it did not produce — which is
# what happened on the first cut of this declaration, and is the fail-closed
# behaviour working.
_rows() { grep -vE '^[[:space:]]*(#|$)' "$MANIFEST"; }

# ── DECLARE WHAT THIS GUARD READS (your-org/nexus-code#1219, #1301) ────────
#
# THIS GUARD IS THE SHARPEST CASE FOR THE INDEX IT WAS MISSING FROM. Its whole
# job is to redden when a marker is added to `CLAUDE.md` with no owner, so a
# `CLAUDE.md` EDIT IS ITS DEFINING TRIGGER — and while it declared nothing it
# was INVISIBLE to `guards-for-diff`: absent from SELECTED *and* from CONSIDERED
# AND EXCLUDED, i.e. `#1078`'s residual, so its absence read as a considered
# exclusion. Measured before this declaration, on a diff containing only
# `CLAUDE.md`: five guards selected and this one among the 385 invisible.
#
# The population is DERIVED, never listed: the doc, the manifest, and every
# OWNER SUITE the manifest names — §4 opens each of those to assert it still
# names its marker, so an edit to any of them can change this verdict. It CALLS
# `_rows`, the guard's own enumerator, rather than restating what it returns.
# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' "$DOC" "$MANIFEST"
    ( cd "$_repo_root" && _rows | cut -d'|' -f2 )
}
gp_handle "$@"

# The SHARED helpers, not a hand-rolled `ok`/`bad` pair — so this suite is
# `ledger=yes` AND `count=exact` and therefore needs no row in
# `summary-honesty.manifest` at all. The ledger is what certifies that no FAIL
# was swallowed by a subshell (your-org/nexus-code#805); the
# `_EXPECTED_ASSERTIONS` guard at the bottom is what reddens a VANISHED
# assertion (#807). They protect different things and neither implies the other.
# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"

[[ -r "$DOC" ]]      || { echo "missing $DOC" >&2; exit 1; }
[[ -r "$MANIFEST" ]] || { echo "missing $MANIFEST" >&2; exit 1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# ── THE GENERATOR ─────────────────────────────────────────────────────────
# Marker names out of a file, one per line. `grep -F` on the literal opener,
# then sed the name out — NOT an anchored pattern. An earlier draft used
# `^<!-- BEGIN ...` and returned a confident ZERO, because every marker in
# this document is INDENTED two spaces inside its bullet. It was caught only
# by cross-checking against `grep -cF "<!-- BEGIN "`, which is why that
# cross-check is now §1 rather than a thing the author did once.
_markers() {   # <file> <BEGIN|END>
    grep -F -- "<!-- $2 " "$1" \
        | sed -nE 's/.*<!-- '"$2"' ([A-Za-z0-9_-]+) -->.*/\1/p'
}

# ===========================================================================
echo '=== 1. the generator is not silently empty ==='
# ===========================================================================
# POSITIVE CONTROL BEFORE ANY ABSENCE IS BELIEVED. Every "not in the manifest"
# assertion below is a false pass on an empty marker set.
_n_begin=$(_markers "$DOC" BEGIN | grep -c .)
_n_literal=$(grep -cF -- "<!-- BEGIN " "$DOC")
assert_eq "the extractor finds markers at all (>0)" \
    "$( (( _n_begin > 0 )) && echo yes || echo NO )" "yes"
assert_eq "…and agrees with an INDEPENDENT literal count ($_n_literal)" \
    "$_n_begin" "$_n_literal"

# ===========================================================================
echo '=== 2. every BEGIN has a matching END ==='
# ===========================================================================
_markers "$DOC" BEGIN | sort > "$WORK/begin"
_markers "$DOC" END   | sort > "$WORK/end"
assert_eq "BEGIN and END name the same set (unpaired: none)" \
    "$(comm -3 "$WORK/begin" "$WORK/end" | grep -c . )" "0"

# ===========================================================================
echo '=== 3. set equality, BOTH directions, markers <-> manifest rows ==='
# ===========================================================================
_rows | cut -d'|' -f1 | sort > "$WORK/rows"
assert_eq "no marker lacks a manifest row" \
    "$(comm -23 "$WORK/begin" "$WORK/rows" | tr '\n' ' ' | sed 's/ $//')" ""
assert_eq "no manifest row names a marker that is gone" \
    "$(comm -13 "$WORK/begin" "$WORK/rows" | tr '\n' ' ' | sed 's/ $//')" ""
assert_eq "one row per marker (no duplicate rows)" \
    "$(_rows | cut -d'|' -f1 | sort | uniq -d | grep -c .)" "0"

# ===========================================================================
echo '=== 4. every declared owner exists, is tracked, and names its marker ==='
# ===========================================================================
_missing="" _untracked="" _unnamed="" _nodoc="" _badmode=""
while IFS='|' read -r _m _suite _mode _reason; do
    case "$_mode" in
        executes|drives) ;;
        unowned) [[ -n "$_reason" ]] || _badmode+="$_m(no reason) "; continue ;;
        *) _badmode+="$_m($_mode) "; continue ;;
    esac
    [[ -n "$_reason" ]] || _badmode+="$_m(no reason) "
    _p="$_repo_root/$_suite"
    [[ -f "$_p" ]] || { _missing+="$_m->$_suite "; continue; }
    git -C "$_repo_root" ls-files --error-unmatch -- "$_suite" >/dev/null 2>&1 \
        || _untracked+="$_m->$_suite "
    grep -qF -- "$_m" "$_p"        || _unnamed+="$_m->$_suite "
    grep -qF -- "CLAUDE.md" "$_p"  || _nodoc+="$_m->$_suite "
done < <(_rows)

assert_eq "every owner suite EXISTS"                       "$_missing"   ""
assert_eq "…is TRACKED (an untracked owner is invisible to CI)" "$_untracked" ""
assert_eq "…NAMES its marker"                              "$_unnamed"   ""
assert_eq "…and reads CLAUDE.md at all"                    "$_nodoc"     ""
assert_eq "every row declares a known mode and a reason"   "$_badmode"   ""

# ===========================================================================
echo '=== 5. the UNEXECUTED set is a ratchet, not a running total ==='
# ===========================================================================
# `drives` and `unowned` are the modes whose block is not extracted, so a
# PROSE edit cannot fail them. Both are legitimate and both must be BOUNDED,
# or the index degrades one honest row at a time. Raising this ceiling is a
# deliberate act with a diff; drifting past it is not possible.
_UNEXECUTED_CEILING=1
_n_unexec=$(_rows | cut -d'|' -f3 | grep -cE '^(drives|unowned)$')
assert_eq "unexecuted markers ($_n_unexec) within the declared ceiling ($_UNEXECUTED_CEILING)" \
    "$( (( _n_unexec <= _UNEXECUTED_CEILING )) && echo yes || echo NO )" "yes"
# NAME them, so the ceiling is a statement about a KNOWN set rather than a
# number. A failing lint must print its offenders; this one prints them green.
printf '    unexecuted: %s\n' "$(_rows | awk -F'|' '$3!="executes"{printf "%s(%s) ", $1, $3}')"

# ===========================================================================
echo '=== 6. POSITIVE CONTROLS — the guard is not inert ==='
# ===========================================================================
# Three plants, each proving one of §3/§4's absences can actually FIRE. A
# guard never seen fail is not evidence, and an inert check and a clean tree
# look identical.
cp "$DOC" "$WORK/doc.md"
printf '\n  <!-- BEGIN ZZ-PLANTED-MARKER -->\n  x\n  <!-- END ZZ-PLANTED-MARKER -->\n' >> "$WORK/doc.md"
_planted=$(_markers "$WORK/doc.md" BEGIN | sort | comm -23 - "$WORK/rows" | tr '\n' ' ' | sed 's/ $//')
assert_eq "PC1: an unmanifested marker IS detected" "$_planted" "ZZ-PLANTED-MARKER"

_orphan=$(printf '%s\nZZ-ORPHAN-ROW\n' "$(cat "$WORK/rows")" | sort \
            | comm -13 "$WORK/begin" - | tr '\n' ' ' | sed 's/ $//')
assert_eq "PC2: a row whose marker is gone IS detected" "$_orphan" "ZZ-ORPHAN-ROW"

_p="$_repo_root/monitor/watcher/zz-no-such-suite.sh"
assert_eq "PC3: a row naming a nonexistent suite IS detected" \
    "$( [[ -f "$_p" ]] && echo MISSED || echo detected )" "detected"

# A BEGIN with no END must be caught by §2 — plant one and require the pairing
# check to fire, since a `comm -3` over two empty sets also returns 0.
printf '\n  <!-- BEGIN ZZ-UNPAIRED -->\n' >> "$WORK/doc.md"
_markers "$WORK/doc.md" BEGIN | sort > "$WORK/b2"
_markers "$WORK/doc.md" END   | sort > "$WORK/e2"
assert_eq "PC4: an unpaired BEGIN IS detected" \
    "$(comm -3 "$WORK/b2" "$WORK/e2" | tr -d ' \t' | tr '\n' ' ' | sed 's/ $//')" "ZZ-UNPAIRED"

# ===========================================================================
_EXPECTED_ASSERTIONS=16
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$_EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
