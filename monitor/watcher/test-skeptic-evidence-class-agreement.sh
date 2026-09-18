#!/usr/bin/env bash
# THE "ONE AUTHORITY" FOR EVIDENCE CLASSES WAS AUTHORITATIVE OVER ONE OF ITS
# FOUR CONSUMERS (your-org/nexus-code#1207 bundle).
#
# Run: bash monitor/watcher/test-skeptic-evidence-class-agreement.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# ── THE DEFECT ──────────────────────────────────────────────────────────────
#
# `ng`'s `_skeptic_evidence_sides` calls itself "THE ONE AUTHORITY for what each
# class establishes", and it exists because a previous guard checked only that
# each class was NAMED SOMEWHERE on a line. But it is READ by exactly two files:
# `monitor/ng` itself and `test-skeptic-verdict-evidence.sh`. The other two
# consumers — both `case` arms in `monitor/retire-preflight.sh` — hand-maintain
# their own copies of the DELIVERED group, and both had already drifted:
# `unmatched-other` and `prior-verdict-other-artefact` were MISSING from each.
#
# The consequence is not cosmetic. Both arms have a permissive default, so a
# class that is declared DELIVERED but absent from the list falls through
# silently:
#
#   · `_sk_ev_explain` (retire-preflight ~623) gates the "A VERDICT IS ON THE
#     RECORD FOR THIS WINDOW … do NOT re-spawn a skeptic" advice.
#   · the two-ledger-desync arm (~1146) gates "the CREDITOR skeptic ledger
#     ALREADY records a verdict — settle the edge rather than asking for another
#     review".
#
# So for those two classes the operator was told to get a review that had already
# happened — the duplicate-review advice `#1156` was built to prevent, missing
# from the two places built to prevent it.
#
# ── WHY A GUARD RATHER THAN A REFACTOR ──────────────────────────────────────
#
# `retire-preflight.sh` cannot source a private function out of `ng` (it shells
# out to `ng skeptic-evidence` and parses a line), so the lists have to be
# duplicated somewhere. What must not be duplicated is the OBLIGATION TO
# REMEMBER: four hand-maintained enumerations agreeing is an assertion, and this
# suite turns it into a check. Adding a class now reddens here until every
# consumer learns it, which is the only thing that keeps an enumeration honest as
# it grows.
#
# Note the DIRECTION this guard runs in, because it is the opposite of a count
# pin: a pin catches returning TOO FEW members, and cannot see a list that is the
# right LENGTH with the wrong MEMBERSHIP (`#946` F1's shape). This checks SET
# EQUALITY, so a swap is caught.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
# OVERRIDABLE SO THE POSITIVE CONTROL AT THE BOTTOM CAN PLANT A DISAGREEMENT
# (your-org/nexus-code#1483). They default to the real files, so every ordinary
# run is exactly what it was; the overrides exist only for that control, which
# re-invokes this suite against a copy with one class deleted from one arm.
NG="${SECA_NG_OVERRIDE:-$REPO_ROOT/monitor/ng}"
PREFLIGHT="${SECA_PREFLIGHT_OVERRIDE:-$REPO_ROOT/monitor/retire-preflight.sh}"
IDLE_PROBE="${SECA_IDLE_PROBE_OVERRIDE:-$REPO_ROOT/monitor/watcher/_idle_probe.sh}"

[[ -r "$NG" ]]         || th_abort "monitor/ng not readable at $NG"
[[ -r "$PREFLIGHT" ]]  || th_abort "monitor/retire-preflight.sh not readable at $PREFLIGHT"
[[ -r "$IDLE_PROBE" ]] || th_abort "monitor/watcher/_idle_probe.sh not readable at $IDLE_PROBE"

# ── THE PRODUCTION SHELL CORPUS, AS ONE ENUMERATOR ─────────────────────────
#
# Extracted (your-org/nexus-code#1301) because it had TWO inline copies below —
# the sweep and its own positive control — and now has a THIRD consumer in
# `gp_population`. The protocol's one rule for an implementor is that
# `gp_population` must CALL the guard's enumerator, never restate what it
# currently returns: a second implementation drifts, and the index then reports
# with total confidence that this guard does not read a file it does read.
#
# git's pathspec `*` crosses `/` (your-org/nexus-code#954), so `:(glob)` is the
# form that means depth-1. `monitor/ng` is named explicitly because it is a
# shell file by SHEBANG with no extension and no `*.sh` pathspec sees it — the
# omission that made `#1214`'s scope-by-FILE rule miss the main CLI.
_sec_corpus() {
    bash -c "cd '$REPO_ROOT' && git ls-files -- ':(glob)monitor/*.sh' ':(glob)monitor/*/*.sh' ':(glob)monitor/ng'" \
        | grep -v '/test-'
}

# `gp_handle` EXITS when it handles `--population`, so it must stand above the
# first line of output — anything printed before it lands in the probe's stdout
# and is read as a population row (your-org/nexus-code#1193). The three
# named files are read by the arms above this suite's corpus sweep.
# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() {
    ( cd "$REPO_ROOT" && _sec_corpus )
    printf '%s\n' "$NG" "$PREFLIGHT" "$IDLE_PROBE"
}
gp_handle "$@"

# ── THE AUTHORITY, EXECUTED ─────────────────────────────────────────────────
# Executed rather than re-parsed: the authority's own code produces this, so
# there is no second implementation here to drift. Piped into `bash` rather than
# sourced from a process substitution — `. <(…)` adds a source token the
# shell-option graph cannot statically resolve and reddens
# `test-ambient-shell-option-scope`.
_sides=$( { sed -n '/^_skeptic_evidence_sides()/,/^}/p' "$NG"; echo '_skeptic_evidence_sides'; } | bash )
assert_eq "the side authority ran and declared 3 groups" \
    "$(grep -c . <<<"$_sides")" "3"

_norm() { tr '|' '\n' <<<"$1" | tr -d ' \t' | grep -c . ; }
_set()  { tr '|' '\n' <<<"$1" | tr -d ' \t' | grep . | sort -u ; }

_delivered=$(awk -F'\t' '$1=="delivered"{print $2}' <<<"$_sides")
assert_eq "POSITIVE CONTROL: the DELIVERED group is non-empty" \
    "$( [[ -n "$_delivered" ]] && echo yes || echo no)" "yes"
_delivered_set=$(_set "$_delivered")
_delivered_n=$(grep -c . <<<"$_delivered_set")
# A floor, not a pin: this suite is about MEMBERSHIP, and pinning the exact count
# here would make every legitimate class addition red in two places for one
# reason. `test-skeptic-verdict-evidence.sh` owns the count.
assert_eq "POSITIVE CONTROL: …with several members, so set equality is meaningful" \
    "$( (( _delivered_n >= 5 )) && echo yes || echo no)" "yes"

# ── CONSUMER 1 & 2: the two `case` arms in retire-preflight.sh ──────────────
#
# SELECTED BY MEMBERSHIP, NOT BY FIRST TOKEN, and that is not a refinement — the
# first draft matched `^\s*attributed\|`, and against the REAL pre-fix lists
# (which begin `unmatched-subject|…`) it located ZERO arms. The suite went red on
# its positive control rather than on the membership arm, i.e. it reported "could
# not look" for the very drift it exists to catch. An extraction keyed on the
# ORDER of a set is a claim that the order is part of the contract; it is not.
#
# An arm is an evidence-class arm iff THREE OR MORE of its alternatives are
# classes the classifier can emit. That is order-independent and it excludes the
# unrelated multi-alternative arms in this file (pane states at ~319, skeptic
# dispositions at ~970), which share zero members with the class set.
_ng_classes_pre=$(grep -oE 'ev *= *"[a-z?][a-z-]*"' "$NG" | sed 's/ev *= *"//; s/"//' | sort -u)
_pf_arms=""
while IFS= read -r _cand; do
    [[ -n "$_cand" ]] || continue
    _cbody=${_cand#*:}; _cbody=${_cbody%%)*}
    _hits=0
    while IFS= read -r _tok; do
        [[ -n "$_tok" ]] || continue
        grep -qxF "$_tok" <<<"$_ng_classes_pre" && _hits=$(( _hits + 1 ))
    done < <(tr '|' '\n' <<<"$_cbody" | tr -d ' \t')
    (( _hits >= 3 )) && _pf_arms+="$_cand"$'\n'
done < <(grep -nE '^[[:space:]]*[a-z?][a-z?-]*(\|[a-z?][a-z?-]*){2,}\)' "$PREFLIGHT")
_pf_arms=$(grep . <<<"$_pf_arms")
_pf_n=$(grep -c . <<<"$_pf_arms")
# POSITIVE CONTROL on the EXTRACTION itself. If the arms are ever reshaped so
# this pattern misses them, the comparisons below would pass over an empty
# population — a false green in a guard, which is worse than no guard.
assert_eq "POSITIVE CONTROL: both retire-preflight class arms were located" \
    "$_pf_n" "2"

_pf_bad=""
while IFS= read -r _line; do
    [[ -n "$_line" ]] || continue
    _ln=${_line%%:*}
    _body=${_line#*:}
    _body=${_body%%)*}
    _got=$(_set "$_body")
    if [[ "$_got" != "$_delivered_set" ]]; then
        _pf_bad+="line $_ln: $(comm -3 <(printf '%s\n' "$_delivered_set") <(printf '%s\n' "$_got") | tr -d '\t' | tr '\n' ' ')"$'\n'
    fi
done <<<"$_pf_arms"
assert_eq "both retire-preflight arms carry the DELIVERED group EXACTLY" \
    "$_pf_bad" ""

# ── CONSUMER 3: the operator advice line in _idle_probe.sh ──────────────────
_adv=$(grep 'orphaned-skeptic-pending (idle' "$IDLE_PROBE")
assert_eq "POSITIVE CONTROL: the operator advice line was located" \
    "$( [[ -n "$_adv" ]] && echo yes || echo no)" "yes"
# Its DELIVERED segment only — `[...]` after the group name, so a class named
# anywhere else on the line cannot satisfy this.
_adv_delivered=${_adv#*evidence DELIVERED [}
_adv_delivered=${_adv_delivered%%]*}
assert_eq "POSITIVE CONTROL: …and its DELIVERED segment was extracted" \
    "$( [[ -n "$_adv_delivered" && "$_adv_delivered" != "$_adv" ]] && echo yes || echo no)" "yes"
assert_eq "the advice line's DELIVERED segment equals the authority's" \
    "$(_set "$_adv_delivered")" "$_delivered_set"

# ── EVERY CLASS THE CLASSIFIER CAN EMIT IS FILED SOMEWHERE ─────────────────
# Guards the other direction: a class added to the classifier and to
# retire-preflight but never filed on a side would satisfy every arm above.
# `ev *= *"` with the spaces is the required spelling — the bare `ev="` form
# missed a 13th class written the ordinary awk way (skledgsk2 B3).
_ng_classes=$(grep -oE 'ev *= *"[a-z?][a-z-]*"' "$NG" | sed 's/ev *= *"//; s/"//' | sort -u)
assert_eq "POSITIVE CONTROL: classes were extracted from the classifier" \
    "$( [[ -n "$_ng_classes" ]] && echo yes || echo no)" "yes"
_all_sides=$(cut -f2 <<<"$_sides")
_unfiled=""
while IFS= read -r _c; do
    [[ -n "$_c" ]] || continue
    grep -qE "(^|[|[:space:]])${_c//\?/\\?}([|[:space:]]|$)" <<<"$_all_sides" || _unfiled+="$_c "
done <<<"$_ng_classes"
assert_eq "every class the classifier emits is FILED on a side" "$_unfiled" ""

# ── AND THE NEW CLASS IS ON THE DELIVERED SIDE, NOT CANNOT-ESTABLISH ───────
# `verdict-without-arm` means a verdict WAS delivered and no arm was ever
# recorded. Filing it as cannot-establish would restore the exact instruction
# this bundle removed: get a review that already happened.
assert_contains "verdict-without-arm is filed DELIVERED" \
    "$_delivered_set" "verdict-without-arm"
# `no-open-arm` is the sibling shape and must be filed the same way: a ledger
# that exists with nothing outstanding is the ordinary terminal verdict, not a
# missing review. It reached the classifier and the authority without reaching
# either retire-preflight arm, which is the drift this suite exists to stop.
assert_contains "no-open-arm is filed DELIVERED too" \
    "$_delivered_set" "no-open-arm"
_cannot=$(awk -F'\t' '$1=="cannot-establish"{print $2}' <<<"$_sides")
assert_not_contains "…and NOT cannot-establish" \
    "$(_set "$_cannot")" "verdict-without-arm"

# ── NO SHADOWED FUNCTION DEFINITIONS IN THE PRODUCTION SHELL CORPUS ────────
#
# A function defined twice in one file is not a style complaint: bash keeps the
# LAST definition, so the earlier one is dead code that LOOKS live, and an edit to
# it changes nothing while appearing to. `monitor/ng` carried two byte-identical
# `_skeptic_artefact_sha` definitions (~2960 and ~3002) — the sha helper this
# whole ledger keys on — and only the second ever ran. Removing the first was
# behaviour-neutral by construction, which is also why nothing would ever have
# reddened to reveal it.
#
# Measured at the time this was written: that was the ONLY duplicate in the entire
# production shell corpus, so this guard starts from a clean population rather
# than from a documented exception list.
_dupes=""
while IFS= read -r _f; do
    [[ -n "$_f" ]] || continue
    _d=$(grep -oE '^[_a-zA-Z][_a-zA-Z0-9]*\(\) \{' "$REPO_ROOT/$_f" 2>/dev/null \
           | sort | uniq -d)
    [[ -n "$_d" ]] && _dupes+="$_f: $(tr '\n' ' ' <<<"$_d")"$'\n'
done < <(_sec_corpus)
# POSITIVE CONTROL on the ENUMERATION: a zero here must be a finding, not a
# failure to look. git's pathspec `*` crosses `/`, so `:(glob)` is the form that
# means depth-1 — and an empty file list would make the loop above vacuous.
_scanned=$(_sec_corpus | grep -c . || true)
assert_eq "POSITIVE CONTROL: the corpus scan saw a plausible number of files" \
    "$( (( _scanned >= 50 )) && echo yes || echo no)" "yes"
assert_eq "no production shell file defines the same function twice" "$_dupes" ""

# ── POSITIVE CONTROL: A PLANTED DISAGREEMENT IS CAUGHT ─────────────────────
#
# THE SECOND `none` ROW IN THE R4 CENSUS (your-org/nexus-code#1483). Every
# assertion above is either an AGREEMENT check or a GENERATOR CONTROL
# ("non-empty", "located", "extracted", "plausible number") — the first census
# read one of those generator controls AS a plant, which is precisely the
# confusion this section removes. Nothing above plants a DISAGREEMENT and
# asserts it is caught, so nothing above distinguishes "the four enumerations
# agree" from "the comparison is inert".
#
# THE PLANT is one class deleted from ONE of the two retire-preflight arms — a
# copy, never the real file. That is the exact drift this suite was written
# for: `unmatched-other` and `prior-verdict-other-artefact` were missing from
# both arms, and because both arms have a permissive default the operator was
# told to get a review that had already happened.
#
# ASSERTED ON THE MESSAGE, not on the exit code: the inner run also trips its
# own assertion-count pin and other arms, so rc 1 alone would be satisfied by a
# suite whose membership comparison had been deleted. The NEGATIVE arm — an
# UNMODIFIED copy through the same overrides — is what separates "caught the
# plant" from "reddens on any copy".
if [[ -z "${SECA_PREFLIGHT_OVERRIDE:-}" ]]; then
    _pc_dir=$(mktemp -d)
    cp "$PREFLIGHT" "$_pc_dir/preflight-clean.sh"
    cp "$PREFLIGHT" "$_pc_dir/preflight-planted.sh"
    # Delete `no-open-arm|` from the FIRST class arm only. One arm, so the
    # other still agrees — a plant that broke both would also be caught by a
    # guard that merely required the two arms to match each other.
    awk 'BEGIN{done=0}
         !done && /^[[:space:]]*attributed\|/ { sub(/no-open-arm\|/, ""); done=1 }
         { print }' \
        "$PREFLIGHT" > "$_pc_dir/preflight-planted.sh"
    _pc_delta=$(diff <(grep -c 'no-open-arm' "$PREFLIGHT") <(grep -c 'no-open-arm' "$_pc_dir/preflight-planted.sh") >/dev/null && echo same || echo differs)
    assert_eq "POSITIVE CONTROL PRECONDITION: the plant really changed the file" "$_pc_delta" "differs"
    _pc_out=$(SECA_PREFLIGHT_OVERRIDE="$_pc_dir/preflight-planted.sh" \
                bash "${BASH_SOURCE[0]}" 2>&1)
    if [[ "$_pc_out" == *"FAIL: both retire-preflight arms carry the DELIVERED group EXACTLY"* \
       && "$_pc_out" == *"no-open-arm"* ]]; then
        assert_eq "POSITIVE CONTROL: a class deleted from ONE arm IS caught, and named" yes yes
    else
        assert_eq "POSITIVE CONTROL: a class deleted from ONE arm IS caught, and named" no yes
    fi
    _pc_out2=$(SECA_PREFLIGHT_OVERRIDE="$_pc_dir/preflight-clean.sh" \
                bash "${BASH_SOURCE[0]}" 2>&1)
    if [[ "$_pc_out2" != *"FAIL: both retire-preflight arms carry the DELIVERED group EXACTLY"* ]]; then
        assert_eq "NEGATIVE CONTROL: an UNMODIFIED copy through the same override is clean" yes yes
    else
        assert_eq "NEGATIVE CONTROL: an UNMODIFIED copy through the same override is clean" no yes
    fi
    rm -rf "$_pc_dir"
fi

# ── ASSERTION-COUNT PIN ────────────────────────────────────────────────────
# An `assert_*` inside `( )` mutates a subshell's globals, so its FAIL is lost
# and the suite exits 0; a missing helper is rc 127 counted by nothing. The
# count is the evidence that the arms ran.
EXPECTED=15
# The positive-control section adds three and is skipped in the inner run, so
# the pin has to know which run it is in — the alternative is a pin that is
# wrong for one of the two, which on a count-based guard means it stops meaning
# anything.
[[ -z "${SECA_PREFLIGHT_OVERRIDE:-}" ]] && EXPECTED=18
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
