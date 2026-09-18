#!/usr/bin/env bash
# your-org/nexus-code#1264 R4 — EVERY GUARD SHIPS WITH A POSITIVE CONTROL.
#
# "Every guard must ship with a planted violation it demonstrably catches, and
# go red if that plant stops being caught." The case that made this a rule
# rather than a preference: `test-assert-shims-wrapped.sh` was GREEN for the
# whole of an 18-hour outage CAUSED BY THE GUARD IT TESTS (your-org/nexus-code
# #1477). Its hermetic seam planted snapshots into a synthetic home and could
# never observe the guard's own failure class. A guard never seen to fail is
# not evidence, and an inert check and a clean tree look identical.
#
# ── DECLARED, NOT DERIVED ─────────────────────────────────────────────────
#
# A grep for "control|plant|potency" across the guards is a heuristic and it
# is wrong in both directions on this tree (see the manifest header). So each
# guard's positive control is a DECLARED row — a verbatim substring of the
# assertion label in the owner suite — and the only generated thing is the
# GUARD SET the rows are checked against: every suite that declares a
# population in `guard-populations.manifest`, i.e. every guard the
# `guards-for-diff` index can select.
#
# ── WHAT GOES RED ───────────────────────────────────────────────────────────
#
#   a guard joins the index with no row here                -> RED (§2)
#   a row names a guard that left the index                 -> RED (§2)
#   a guard's declared control label no longer appears      -> RED (§3)
#   a row's guard is missing or untracked                    -> RED (§3)
#   the NONE set grows past the manifest's none-ceiling      -> RED (§4)
#   a NONE row with no tracker ref and no until: expiry       -> RED (§3)
#
# ── WHAT IT DOES NOT CLAIM ──────────────────────────────────────────────────
#
# It does not re-run any guard's plant. Whether the plant is CAUGHT is the
# owner suite's own assertion; this ratchet keeps the plant's EXISTENCE
# checkable and its ABSENCE countable. #1477's specific lesson — a plant
# inside a hermetic seam proves the seam — is not decidable from a label, and
# is left to the owner (P0b's non-hermetic arm is the worked instance).
#
# Run: bash monitor/watcher/test-guard-positive-controls.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
MANIFEST="$_test_dir/guard-positive-controls.manifest"
POPMANIFEST="$_test_dir/guard-populations.manifest"

_rows() { grep -vE '^[[:space:]]*(#|$)' "$MANIFEST"; }
# THE GENERATOR: every suite declaring a population (first TAB field of the
# populations manifest). Not `git grep gp_population` — the index's own
# definition of "declares" is the manifest row, and two enumerators for one
# set is how they disagree.
_guards() { grep -vE '^[[:space:]]*(#|$)' "$POPMANIFEST" | cut -f1 | sort -u; }

# ── DECLARE WHAT THIS GUARD READS (your-org/nexus-code#1219, #1301) ────────
# The two manifests and every guard the rows name (§3 opens each to look for
# its label), so an edit to any guard's assertion labels selects this suite.
# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' "$MANIFEST" "$POPMANIFEST"
    ( cd "$_repo_root" && _rows | cut -d'|' -f1 )
}
gp_handle "$@"

# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"

[[ -r "$MANIFEST" ]]    || { echo "missing $MANIFEST" >&2; exit 1; }
[[ -r "$POPMANIFEST" ]] || { echo "missing $POPMANIFEST" >&2; exit 1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# ===========================================================================
echo '=== 1. the generator is not silently empty ==='
# ===========================================================================
# POSITIVE CONTROL BEFORE ANY ABSENCE IS BELIEVED: every "no guard lacks a
# row" below is a false pass on an empty guard set.
_guards > "$WORK/guards"
_n_guards=$(grep -c . "$WORK/guards")
_n_indep=$(grep -vE '^[[:space:]]*(#|$)' "$POPMANIFEST" | awk -F'\t' '{print $1}' | sort -u | wc -l | tr -d ' ')
assert_eq "the generator finds declaring guards at all (>0)" \
    "$( (( _n_guards > 0 )) && echo yes || echo NO )" "yes"
assert_eq "…and agrees with an INDEPENDENT awk count ($_n_indep)" "$_n_guards" "$_n_indep"

# ===========================================================================
echo '=== 2. set equality, BOTH directions, declaring guards <-> rows ==='
# ===========================================================================
_rows | cut -d'|' -f1 | sort > "$WORK/rows"
assert_eq "no declaring guard lacks a positive-control row" \
    "$(comm -23 "$WORK/guards" "$WORK/rows" | tr '\n' ' ' | sed 's/ $//')" ""
assert_eq "no row names a guard that no longer declares a population" \
    "$(comm -13 "$WORK/guards" "$WORK/rows" | tr '\n' ' ' | sed 's/ $//')" ""
assert_eq "one row per guard (no duplicates)" \
    "$(_rows | cut -d'|' -f1 | sort | uniq -d | grep -c .)" "0"

# ===========================================================================
echo '=== 3. every row: guard exists, is tracked, names its control ==='
# ===========================================================================
_missing="" _untracked="" _unnamed="" _badkind="" _noreason="" _unowned="" _unasserted=""
# A `none` row is an EXEMPTION, and an unowned exemption is inherited rather
# than re-justified (your-org/nexus-code#1469). Its reason must carry a tracker
# ref or an expiry date; the same predicate is applied to a planted row in §5.
_none_owned() { [[ "$1" == *\#[0-9]* || "$1" == *until:[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]* ]]; }
while IFS='|' read -r _g _label _kind _reason; do
    [[ -n "$_reason" ]] || _noreason+="$_g "
    case "$_kind" in
        plant|refusal) ;;
        none) [[ "$_label" == NONE ]] || _badkind+="$_g(none-with-label) "
              _none_owned "$_reason" || _unowned+="$_g "
              continue ;;
        *) _badkind+="$_g($_kind) "; continue ;;
    esac
    [[ "$_label" != NONE && -n "$_label" ]] || { _badkind+="$_g(kind-without-label) "; continue; }
    _p="$_repo_root/$_g"
    [[ -f "$_p" ]] || { _missing+="$_g "; continue; }
    git -C "$_repo_root" ls-files --error-unmatch -- "$_g" >/dev/null 2>&1 || _untracked+="$_g "
    grep -qF -- "$_label" "$_p" || { _unnamed+="$_g "; continue; }
    # The label must sit on an ASSERTION line, not merely exist in the file:
    # §3 used to prove label existence, and a plant can be deleted while its
    # text survives in a comment (the w225 skeptic's F4). Measured 0 comment-
    # only labels at the census, so this costs nothing today and catches the
    # hollowing later.
    # Accepted: a shared assert helper, or a WRAPPER the suite defines itself
    # whose body calls one (`_env_ctl 'label' …` -> `assert_eq "A: $1"`).
    _on_assert=0
    while IFS= read -r _line; do
        _tok=$(sed -nE 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*).*/\1/p' <<<"$_line")
        [[ -n "$_tok" ]] || continue
        if [[ "$_tok" =~ ^(assert_[a-z_]+|ok|pass|_ok|th_pass|note_pass|eq|good|_pass)$ ]]; then _on_assert=1; break; fi
        # herestring, not a pipe: `sed | grep -q` is the sigpipe idiom the lint refuses
        if grep -qE "^${_tok}\(\)" "$_p" && grep -qE '(assert_[a-z_]+|\bok\b|\bpass\b|th_pass)' <<<"$(sed -nE "/^${_tok}\(\)/,/^}/p" "$_p")"; then _on_assert=1; break; fi
    done < <(grep -F -- "$_label" "$_p")
    (( _on_assert )) || _unasserted+="$_g "
done < <(_rows)
assert_eq "every row's guard EXISTS"                             "$_missing"   ""
assert_eq "…is TRACKED (an untracked guard is invisible to CI)"  "$_untracked" ""
assert_eq "…and carries its declared control label VERBATIM (a renamed or deleted plant reddens here)" "$_unnamed" ""
assert_eq "…on an ASSERTION line, not in a comment (a plant whose text outlives it reddens here)" "$_unasserted" ""
assert_eq "every row declares a known kind consistent with its label" "$_badkind"  ""
assert_eq "every row carries a reason"                           "$_noreason"  ""
assert_eq "every NONE row carries an OWNER — a tracker ref or an until: date (an exemption must be re-justified, not inherited; #1469)" "$_unowned" ""

# ===========================================================================
echo '=== 4. the NONE set is a ratchet, not a running total ==='
# ===========================================================================
# No `| head -n1`: the manifest carries exactly ONE ceiling line, and a second
# would fail the integer check below — a stronger assertion than taking the first,
# and no early-exit reader (early-exit-readers.manifest tracks those; #622).
_ceiling=$(sed -nE 's/^# none-ceiling: ([0-9]+)$/\1/p' "$MANIFEST")
assert_eq "the manifest declares a none-ceiling" "$( [[ "$_ceiling" =~ ^[0-9]+$ ]] && echo yes || echo NO )" "yes"
_n_none=$(_rows | awk -F'|' '$3=="none"' | grep -c .)
assert_eq "guards without a positive control ($_n_none) within the ceiling (${_ceiling:-?})" \
    "$( [[ "$_ceiling" =~ ^[0-9]+$ ]] && (( _n_none <= _ceiling )) && echo yes || echo NO )" "yes"
printf '    without a positive control: %s\n' "$(_rows | awk -F'|' '$3=="none"{printf "%s ", $1}')"

# ===========================================================================
echo '=== 5. POSITIVE CONTROLS — this ratchet is not inert ==='
# ===========================================================================
# The rule applied to its own enforcer. Four plants, one per red arm.
printf '%s\n' "$(cat "$WORK/guards")" "monitor/watcher/zz-planted-guard.sh" | sort > "$WORK/g2"
assert_eq "PC1: a guard joining the index with no row IS detected" \
    "$(comm -23 "$WORK/g2" "$WORK/rows" | tr '\n' ' ' | sed 's/ $//')" "monitor/watcher/zz-planted-guard.sh"
printf '%s\n' "$(cat "$WORK/rows")" "monitor/watcher/zz-orphan-row.sh" | sort > "$WORK/r2"
assert_eq "PC2: a row whose guard left the index IS detected" \
    "$(comm -13 "$WORK/guards" "$WORK/r2" | tr '\n' ' ' | sed 's/ $//')" "monitor/watcher/zz-orphan-row.sh"
read -r _first_guard < "$WORK/rows"
assert_eq "PC3: a control label that is NOT in its guard IS detected" \
    "$( grep -qF -- 'ZZ-NO-SUCH-LABEL-1264' "$_repo_root/$_first_guard" && echo MISSED || echo detected )" "detected"
_planted_none=$(( _ceiling + 1 ))
assert_eq "PC4: a NONE count above the ceiling IS detected" \
    "$( (( _planted_none <= _ceiling )) && echo MISSED || echo detected )" "detected"
assert_eq "PC5: an UNOWNED none row (prose reason, no tracker, no expiry) IS detected" \
    "$( _none_owned 'a set-equality manifest with no plant driving it' && echo MISSED || echo detected )" "detected"
assert_eq "PC5 CONTROL: a tracker ref satisfies ownership" "$( _none_owned 'tracker: your-org/nexus-code#1483 — …' && echo yes || echo NO )" "yes"
assert_eq "PC5 CONTROL: an until: date satisfies ownership" "$( _none_owned 'until:2026-12-31 — re-justify' && echo yes || echo NO )" "yes"

# ===========================================================================
_EXPECTED_ASSERTIONS=21
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$_EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
