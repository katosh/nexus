#!/usr/bin/env bash
# WHAT EACH SUITE'S GREEN DOES NOT CERTIFY, PINNED AS DATA ON BOTH AXES.
# (your-org/nexus-code#805 boundary, corrected by #821)
#
# WHY THIS FILE EXISTS. `#805` stopped `th_summary_and_exit` announcing a pass
# over zero assertions and made it recover a FAIL lost in a subshell. That fix
# reaches exactly the suites that CALL it, so the residue had to be recorded
# rather than described — prose cannot be made to fail.
#
# WHY IT WAS REBUILT. The first version recorded ONE bucket and treated
# everything else as protected. The `#819` skeptic found that "count-guarded"
# was doing work it could not do, and measuring the correction found the
# classifier was wrong more widely than reported:
#
#   * THE TWO MECHANISMS PROTECT DIFFERENT THINGS. The ledger certifies that
#     *something* was asserted and that no FAIL was swallowed. It certifies
#     nothing about *how much*. An exact count guard is the opposite. Reporting
#     one axis as though it covered both is how "60 protected" was published
#     when the number protected on both axes is **6 of 253**.
#
#   * FIVE FILES WERE EXCLUDED ON A SUBSTRING. The old classifier asked whether
#     the word `EXPECTED` appeared anywhere. It matched `EXPECTED_TARGET` (a
#     config value), `EXPECTED_SLUG` (a path), and — in
#     `test-deliveries-split.sh` — the string `UNEXPECTEDLY` inside a printf.
#     Those five files have no count guard at all and were counted as protected.
#
#   * ONE USED A FLOOR. `test-lit-probe-order-dependence.sh` compares with
#     `-lt`. A suite can clear a floor and still under-assert, so "no longer
#     reports a pass at zero assertions" must never be read as "asserts enough".
#
# So the classifier here detects a MECHANISM — a comparison between an
# assertion total and an expected total — never a word. §1 pins that
# distinction with the `UNEXPECTEDLY` case as an explicit regression control,
# because a classifier that silently reverts to substring matching would
# repopulate the "protected" bucket with files that are not.
#
# Run: bash monitor/watcher/test-summary-honesty-manifest.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
MANIFEST="$_test_dir/summary-honesty.manifest"

# --- the `--population` protocol (your-org/nexus-code#803) -----------------
#
# The corpus this suite classifies, declared by the SAME `git ls-files` glob
# the scan below uses (and for the same reason: `git ls-tree` with a glob
# pathspec is a confident zero, #770). A test file classified `skip` today —
# it prints no banner — is exactly the file that acquires one, so the declared
# population is the enumeration, never the unguarded subset the manifest lists.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    ( cd "$REPO_ROOT" && git ls-files -- '*test-*.sh' )
    printf '%s\n' "$MANIFEST"
}
gp_handle "$@"

[[ -r "$MANIFEST" ]] || { echo "missing manifest: $MANIFEST" >&2; exit 2; }

# ── THE CLASSIFIERS ─────────────────────────────────────────────────────
# AXIS A — does this file's green certify that anything was asserted at all,
# and that no FAIL was lost to a subshell? Only the ledger provides that.
_ledger_axis() {
    grep -q 'th_summary_and_exit' "$1" 2>/dev/null && printf 'yes' || printf 'no'
}

# AXIS B — does it certify that ENOUGH was asserted? Only an EXACT comparison
# between an assertion total and an expected total does.
#
# Structural on purpose: a line that carries an expectation-ish operand, a
# count-ish operand, and a comparison. Reads the heredoc-stripped view (#806)
# so fixture text a suite WRITES is never read as a guard it HAS, and drops
# comments so prose about counting is not mistaken for counting.
#
# TWO EXCLUSIONS, BOTH LEARNED THE SAME WAY — by a mutant, not by foresight:
#
#   `UNEXPECTED` is the exact string that put `test-deliveries-split.sh` in the
#   protected bucket.
#
#   OUTPUT LINES are dropped, because a guard is CONTROL FLOW, not a banner.
#   The first draft of this very classifier — written to replace substring
#   matching with mechanism matching — accepted
#   `echo "=== summary: … expected $EXPECTED) ==="` as an exact guard, because
#   the decorative `===` satisfies its `==` test. Weakening a real file's exact
#   guard to a floor therefore changed nothing and the manifest stayed green.
#   The correction is the same one this file is about: match the mechanism, not
#   the characters. Mutant H in test-summary-honesty-manifest's verification is
#   what fails if this line is removed.
_count_axis() {
    local f="$1" lines
    lines=$(th_strip_heredocs "$f" 2>/dev/null \
            | grep -vE '^[[:space:]]*#' \
            | grep -vE '^[[:space:]]*(echo|printf)[[:space:]]' \
            | grep -E '(EXPECTED|EXPECT_|expected_)' \
            | grep -vE 'UNEXPECTED' \
            | grep -E '(\bPASS\b|\bFAIL\b|\bTOTAL\b|\bRUN\b|_total|ASSERTION|assertion)')
    [[ -n "$lines" ]] || { printf 'none'; return; }
    # An assertion CALL comparing a count to an expectation is exact even
    # though it carries no operator — `test-gh-capable.sh` spells it that way.
    grep -qE '^[[:space:]]*(assert_eq|assert_rc|eq)[[:space:]]' <<<"$lines" && { printf 'exact'; return; }
    grep -qE '(!=|==|-ne|-eq)' <<<"$lines" && { printf 'exact'; return; }
    grep -qE '(-lt|-le|-gt|-ge)'  <<<"$lines" && { printf 'floor'; return; }
    printf 'none'
}

# THE DECLARED LIMIT OF AXIS B, and it is a real one. `_count_axis` recognises a
# VOCABULARY of count-ish operand names (`PASS`, `FAIL`, `TOTAL`, `RUN`,
# `_total`, `assertion`). A suite whose exact guard compares an operand named
# something else reads as `count=none` — under-crediting itself.
#
# Found the honest way: renaming this file's own guard operand from `_total` to
# `_ran` silently moved THIS FILE into the unprotected bucket, and the ratchet
# caught it. The fix was to use the documented vocabulary, not to widen the
# pattern until nothing escapes — widening is what produced the `EXPECTED_TARGET`
# and `UNEXPECTEDLY` false positives in the first place.
#
# The bias is deliberate and one-directional: an unrecognised spelling makes a
# suite look LESS protected than it is, never more. A manifest that
# over-reported protection would be the dangerous failure; this one
# over-reports exposure. The control below pins that direction so it cannot
# silently invert.

# ── §1 CLASSIFIER CONTROLS ──────────────────────────────────────────────
# A classifier nobody tested is how the first version shipped its error.
PLANT=$(mktemp -d) || { echo "FAIL: mktemp for the plants"; exit 1; }
trap 'rm -rf "$PLANT"' EXIT

printf '%s\n' '#!/usr/bin/env bash' 'th_summary_and_exit' > "$PLANT/a-yes.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "ALL TESTS PASSED"' > "$PLANT/a-no.sh"
assert_eq "AXIS A: a th_summary_and_exit suite is ledger=yes" "$(_ledger_axis "$PLANT/a-yes.sh")" "yes"
assert_eq "AXIS A: a hand-rolled summary is ledger=no"        "$(_ledger_axis "$PLANT/a-no.sh")"  "no"

printf '%s\n' '#!/usr/bin/env bash' 'EXPECTED=3' '(( PASS + FAIL != EXPECTED )) && exit 1' > "$PLANT/b-exact.sh"
printf '%s\n' '#!/usr/bin/env bash' 'EXPECTED_MIN=3' '[[ $_total -lt $EXPECTED_MIN ]] && exit 1' > "$PLANT/b-floor.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo hi' > "$PLANT/b-none.sh"
printf '%s\n' '#!/usr/bin/env bash' 'EXPECTED_ASSERTIONS=56' 'eq "$RUN" "$EXPECTED_ASSERTIONS" "assertion count"' > "$PLANT/b-call.sh"

assert_eq "AXIS B: an exact != comparison is count=exact" "$(_count_axis "$PLANT/b-exact.sh")" "exact"
assert_eq "AXIS B: a -lt comparison is count=FLOOR, not exact" "$(_count_axis "$PLANT/b-floor.sh")" "floor"
assert_eq "AXIS B: no guard at all is count=none" "$(_count_axis "$PLANT/b-none.sh")" "none"
assert_eq "AXIS B: an assertion CALL comparing counts is exact (no operator)" \
    "$(_count_axis "$PLANT/b-call.sh")" "exact"

# THE REGRESSION CONTROL FOR THE ORIGINAL DEFECT. Each of these carries the
# WORD but no mechanism, and each put a real file in the protected bucket.
printf '%s\n' '#!/usr/bin/env bash' "printf '  FAIL: %s UNEXPECTEDLY present\\n' \"\$l\" >&2" > "$PLANT/b-word1.sh"
printf '%s\n' '#!/usr/bin/env bash' 'EXPECTED_TARGET=orchestrator' 'echo "$EXPECTED_TARGET"' > "$PLANT/b-word2.sh"
printf '%s\n' '#!/usr/bin/env bash' '# T2. EMPTY, WITH BANDS EXPECTED — the outage shape' 'PASS=1' > "$PLANT/b-word3.sh"
assert_eq "the word UNEXPECTEDLY in a printf is NOT a count guard" "$(_count_axis "$PLANT/b-word1.sh")" "none"
assert_eq "an EXPECTED_TARGET config value is NOT a count guard"   "$(_count_axis "$PLANT/b-word2.sh")" "none"
assert_eq "the word EXPECTED in a COMMENT is NOT a count guard"    "$(_count_axis "$PLANT/b-word3.sh")" "none"

# THE VOCABULARY LIMIT, pinned as data rather than left as prose. An exact
# comparison whose operand is named outside the recognised set reads as `none`.
# This assertion documents the blind spot AND its direction: under-crediting,
# never over-crediting.
printf '%s\n' '#!/usr/bin/env bash' 'EXPECTED=3' '(( _ran != EXPECTED )) && exit 1' > "$PLANT/b-vocab.sh"
assert_eq "KNOWN LIMIT: an exact guard on an unrecognised operand name reads as none" \
    "$(_count_axis "$PLANT/b-vocab.sh")" "none"

# A guard written as FIXTURE TEXT is not a guard the file has (#806).
cat >"$PLANT/b-heredoc.sh" <<'HD'
#!/usr/bin/env bash
cat > /tmp/fixture <<'INNER'
EXPECTED=3
(( PASS + FAIL != EXPECTED )) && exit 1
INNER
HD
assert_eq "a count guard written as HEREDOC fixture text does not count" \
    "$(_count_axis "$PLANT/b-heredoc.sh")" "none"

# ── §2 THE CORPUS ───────────────────────────────────────────────────────
# `git ls-files` with a GLOB pathspec — NOT `git ls-tree`, whose pathspecs are
# path prefixes and which returns a confident zero here (#770).
# ── THE SELECTOR SELECTS BY THE PROPERTY, NOT A PROXY (#864) ────────────
# This used to be, inline in the loop below:
#
#     grep -q 'ALL TESTS PASSED' "$f" || continue
#
# which never asks "is this a suite that announces a pass". It looks for a
# STRING a suite happens to print. A suite that routes its footer through
# `th_summary_and_exit` does not contain that string — the HELPER prints it —
# so ADOPTING THE SHARED HELPER REMOVED A SUITE FROM THIS GUARD. That is the
# practice this file's own remedy text prescribes (`ledger=yes` needs the
# shared summary helper), which made this a guard that rewarded compliance
# with invisibility. Measured on `a91f82b`: 25 suites outside the population,
# all 25 with no count guard and no manifest row, and their absence
# indistinguishable from compliance.
#
# It cut the other way too. The predicate is plain text over the whole file,
# comments included, so a suite could opt IN by writing the phrase in a
# comment — `test-claude-md-guards-for-diff.sh` was visible solely because its
# header says `# Expected: ALL TESTS PASSED on stdout`. Delete that comment and
# it silently leaves the population. Visibility was accidental in BOTH
# directions and nobody chose either.
_announces_pass() {   # <file> -> rc 0 if this file announces a pass
    # (a) its own bytes carry the banner, or
    grep -q 'ALL TESTS PASSED' "$1" 2>/dev/null && return 0
    # (b) it delegates the footer to the shared helper, which prints it.
    grep -q 'th_summary_and_exit' "$1" 2>/dev/null && return 0
    return 1
}
# The predicate, as text, so the guard can STATE the boundary it selected by
# rather than leaving the reader to infer it from a count.
_SELECTOR_DESC='own bytes contain "ALL TESTS PASSED", OR the file calls th_summary_and_exit'
_CANDIDATE_DESC='tracked *test-*.sh'

# ── §1c SELECTOR PREDICATE CONTROLS (your-org/nexus-code#864) ───────────
# `_SELECTOR_DESC` is PROSE describing `_announces_pass`, and prose cannot be
# made to fail — the two can drift, and a boundary sentence that no longer
# describes the code is worse than none, because it is believed. Measured:
# deleting the helper arm of the predicate leaves the boundary line still
# CLAIMING the helper is included, and reddens only downstream, via §3's
# `delete these lines` — i.e. the reader is told to record the regression as
# progress and is never told the selector narrowed.
#
# So each arm of the predicate is driven directly, and a removed arm is a
# NAMED failure at the selector rather than a drift in the manifest.
printf '%s\n' '#!/usr/bin/env bash' 'echo "ALL TESTS PASSED"' > "$PLANT/s-literal.sh"
printf '%s\n' '#!/usr/bin/env bash' 'th_summary_and_exit'     > "$PLANT/s-helper.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo hi'                 > "$PLANT/s-neither.sh"

_announces_pass "$PLANT/s-literal.sh"; _sel_rc=$?
assert_eq "SELECTOR: a file whose OWN BYTES carry the banner is selected" "$_sel_rc" "0"
_announces_pass "$PLANT/s-helper.sh"; _sel_rc=$?
assert_eq "SELECTOR: a file that DELEGATES to th_summary_and_exit is selected (#864)" "$_sel_rc" "0"
_announces_pass "$PLANT/s-neither.sh"; _sel_rc=$?
assert_eq "SELECTOR: a file that announces nothing is NOT selected" "$_sel_rc" "1"

cd "$REPO_ROOT" || { echo "FAIL: cd repo root"; exit 1; }

n_cand=0 n_files=0 n_full=0
actual=""
while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    n_cand=$(( n_cand + 1 ))
    _announces_pass "$f" || continue
    n_files=$(( n_files + 1 ))
    a=$(_ledger_axis "$f"); b=$(_count_axis "$f")
    if [[ "$a" == yes && "$b" == exact ]]; then
        n_full=$(( n_full + 1 ))
    else
        actual+="$f::ledger=$a::count=$b"$'\n'
    fi
done < <(git ls-files -- '*test-*.sh')

# ── THE SELECTOR DECLARES ITS OWN BOUNDARY (#864) ───────────────────────
# A coverage number that names only what it MATCHED is unfalsifiable: 258 and
# 283 read identically when you cannot see the denominator. So report the
# candidate set, the predicate that narrowed it, and what fell outside.
#
# "EXAMINED NOTHING" AND "SELECTED NOTHING" ARE DIFFERENT FAILURES and a
# single count cannot tell them apart — one means the enumerator broke, the
# other means the predicate stopped matching, and they are repaired in
# opposite places. Both are fatal here. A GUARD THAT EXAMINED NOTHING MUST NOT
# EXIT 0; this is checked BEFORE any population comparison below, because with
# an empty scan every downstream set comparison is vacuously satisfiable.
if (( n_cand == 0 )); then
    _th_fail
    printf '  FAIL: SELECTOR EXAMINED NOTHING — 0 candidate files (%s).\n' "$_CANDIDATE_DESC" >&2
    printf '        The ENUMERATOR is blind, not the predicate. Nothing below\n' >&2
    printf '        describes this repository. See #770 (ls-tree glob) and #618.\n' >&2
elif (( n_files == 0 )); then
    _th_fail
    printf '  FAIL: SELECTOR MATCHED NOTHING — %d candidate(s) examined, 0 selected.\n' "$n_cand" >&2
    printf '        The PREDICATE stopped matching, not the enumerator. Predicate:\n' >&2
    printf '        %s\n' "$_SELECTOR_DESC" >&2
else
    _th_pass
    printf '  PASS: selector boundary declared — %d candidate(s) examined (%s), %d selected, %d outside\n' \
        "$n_cand" "$_CANDIDATE_DESC" "$n_files" "$(( n_cand - n_files ))"
    printf '        predicate: %s\n' "$_SELECTOR_DESC"
fi

# A population this scan could not have enumerated makes every result below
# meaningless — the silent-zero class this repo keeps re-learning.
if (( n_files >= 200 )); then
    _th_pass
    printf '  PASS: the banner-printing corpus was enumerated (%d files)\n' "$n_files"
else
    _th_fail
    printf '  FAIL: enumeration returned %d files (expected >=200) — the scan is blind\n' "$n_files" >&2
fi

# Both classifiers must still discriminate. If either collapsed to a constant,
# the comparison below would fail for a reason nobody could diagnose from it.
if (( n_full >= 1 )) && (( n_files - n_full >= 100 )); then
    _th_pass
    printf '  PASS: classifiers still discriminate (%d fully protected, %d not)\n' \
        "$n_full" "$(( n_files - n_full ))"
else
    _th_fail
    printf '  FAIL: %d fully protected of %d — a classifier has collapsed to a constant\n' \
        "$n_full" "$n_files" >&2
fi

expected=$(grep -vE '^[[:space:]]*(#|$)' "$MANIFEST" | sort -u)
actual=$(printf '%s' "$actual" | grep -v '^$' | sort -u || true)

# ── §3 THE RATCHET ──────────────────────────────────────────────────────
# Forward: a banner-printing file that is not fully protected and not recorded.
# This catches both a NEW unguarded suite and a file whose protection WEAKENED
# (its old record no longer matches, so the new state reads as unrecorded).
new=$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual"))
if [[ -z "$new" ]]; then
    _th_pass
    printf '  PASS: no new or weakened unprotected suite (%d on record)\n' \
        "$(printf '%s\n' "$expected" | grep -c .)"
else
    _th_fail
    printf '  FAIL: suite(s) whose green is unrecorded at its current protection level:\n' >&2
    printf '%s\n' "$new" | sed 's/^/         /' >&2
    printf '        `ledger=yes` needs `th_summary_and_exit`; `count=exact` needs a\n' >&2
    printf '        comparison of the assertion total against an expected total. A suite\n' >&2
    printf '        built on DELIBERATE failing assertions can adopt the ledger with\n' >&2
    printf '        th_expect_fail (see its header) instead of staying opted out.\n' >&2
    printf '        If YOU are adding the suite: do NOT append a line — that opts your own\n' >&2
    printf '        new code out of the standard. If it ARRIVED BY MERGE from another\n' >&2
    printf '        change: record it, note where it came from, and let its author raise it.\n' >&2
fi

# Closing: a file that gained protection, or was deleted, must leave the list.
gone=$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual"))
if [[ -z "$gone" ]]; then
    _th_pass
    echo "  PASS: no stale manifest entries"
else
    _th_fail
    printf '  FAIL: recorded state no longer matches the tree — delete these lines:\n' >&2
    printf '%s\n' "$gone" | sed 's/^/         /' >&2
    printf '        (a suite improved, or was removed. Good — but the list must shrink\n' >&2
    printf '        with it, or it stops measuring anything.)\n' >&2
fi

# ── §4 THE FLOOR IS NOT PROTECTION ──────────────────────────────────────
# The `#819` skeptic proved this synthetically and it is the reason the `floor`
# bucket exists rather than being folded into `exact`. Proved again here, live,
# so the claim is not carried by prose: a suite that clears its floor while
# LOSING a failing assertion in a subshell still announces a pass.
cat >"$PLANT/floor-blind.sh" <<'FLOORCTL'
#!/usr/bin/env bash
PASS=0; FAIL=0
assert_eq() { if [[ "$2" == "$3" ]]; then PASS=$(( PASS + 1 )); else FAIL=$(( FAIL + 1 )); fi; }
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do assert_eq "ok$i" 1 1; done
_lost=$(assert_eq "a REAL failure, in a subshell" 1 2)
_total=$(( PASS + FAIL ))
EXPECTED_MIN=10
[[ $_total -lt $EXPECTED_MIN ]] && { echo "FLOOR NOT MET" >&2; exit 1; }
(( FAIL == 0 )) && { echo "ALL TESTS PASSED ($_total assertions)"; exit 0; }
exit 1
FLOORCTL
floor_out=$(bash "$PLANT/floor-blind.sh" 2>&1); floor_rc=$?
assert_eq "a FLOOR-guarded suite exits 0 despite a subshell-lost FAILURE" "$floor_rc" "0"
assert_contains "…announcing a pass, floor cleared, failure invisible" \
    "$floor_out" "ALL TESTS PASSED"

# EXPECTED-COUNT GUARD (#807) — this suite practises what it records.
# The total is captured BEFORE the guard counts its own failure. Reporting
# `$(( PASS + FAIL ))` after `_th_fail` overstates the run by one and sends the
# next reader hunting for an assertion that never existed — which is how the
# first draft of this guard reported "17 ran" for a 16-assertion suite.
EXPECTED=21
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    # ANNOUNCE, THEN COUNT — the order `uncounted-abort-lint.sh` requires, since
    # it scans FORWARD from an announcement for a counting disposition.
    #
    # The second half of this comment used to say "and keep the summary
    # function's name out of the message", because naming it made the lint read
    # this path as reaching the summary uncounted. That was a false positive,
    # fixed in your-org/nexus-code#838 — the lint now distinguishes NAMING a
    # symbol from CALLING it. The workaround is gone rather than left in place:
    # a stale workaround comment is how a false positive becomes folklore, with
    # the next author copying it without knowing why.
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$_total" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
