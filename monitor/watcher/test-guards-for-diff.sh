#!/usr/bin/env bash
# test-guards-for-diff.sh — the reverse index and the `--population` protocol
# it is built on (your-org/nexus-code#803).
#
# WHAT IS BEING GUARDED. "Which guards scan what I just changed?" is answered
# by asking each guard, so every way that question can be answered WRONGLY is a
# way this index quietly under-covers a push:
#
#   * a guard whose enumerator returns nothing reads downstream as "does not
#     read your diff" — the silent-zero class, which has produced three
#     confident wrong answers in this workspace already (`mapfile` in zsh,
#     `grep -r` over `reports/`, `git ls-tree` with a glob pathspec);
#   * a guard the index could not ASK looks exactly like a guard that answered
#     "no";
#   * an empty SELECTION reads as "nothing to run" when it may mean "the index
#     did not run".
#
# So the assertions below are about REFUSALS at least as much as about hits,
# and the two selection cases are planted BOTH ways: a diff touching a
# known-scanned file must select that guard, and a diff touching nothing
# scanned must report zero WITH a non-empty considered list.
#
# EVERY ASSERTION MATCHES THE MESSAGE OR THE SET, NOT MERELY THE EXIT CODE. An
# exit code says a guard fired; only the message says it fired for the reason
# claimed.
#
# Run: bash monitor/watcher/test-guards-for-diff.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
INDEX="$REPO_ROOT/monitor/guards-for-diff.sh"
PROTO="$REPO_ROOT/monitor/_guard_population.sh"
MANIFEST="$_test_dir/guard-populations.manifest"

. "$_test_dir/_test_helpers.sh"

# The operator's interactive `grep` is a ugrep wrapper honouring .gitignore
# (your-org/nexus-code#618); bind the real binary so no scan below can return a
# confident zero.
REAL_GREP=$(type -P grep 2>/dev/null) || REAL_GREP=/bin/grep

WORK=$(mktemp -d)

# PLANTED UNTRACKED FIXTURES LIVE INSIDE THE REPO (your-org/nexus-code#1179),
# because that is the only place they can be what they claim to be. §4b/§4c/§4d
# below are about a file that EXISTS on disk and is absent from the index; a
# path under $TMPDIR is neither in this repo's diff nor reachable by any
# population, so it could only ever stand in for one.
_gfd_plant=$(mktemp -d "$REPO_ROOT/.gfd-plant-XXXXXX") || { echo "FAIL: mktemp in repo" >&2; exit 1; }
_PLANT=$(basename "$_gfd_plant")

# ONE TRAP, LISTING EVERY TEMPORARY. `trap ... EXIT` REPLACES the previous
# handler rather than adding to it, so the second `trap` this file used to
# install silently orphaned $WORK on every run. Harmless in $TMPDIR and NOT
# harmless now: two of these three directories are created INSIDE the repo, and
# a leaked one shows up as an untracked file in everyone else's diff — which is
# the very input this suite exists to reason about.
_gfd_t=""
# `git reset -- <plant>` FIRST (your-org/nexus-code#1387): the plant is an
# ordinary untracked path in the repo root, so a concurrent `git add -A` —
# the documented #1054 pre-flight — stages it, and `rm -rf` removes the
# DIRECTORY, not the index entry. On a path that was never staged the reset
# is a no-op. NOT a .gitignore rule: `guards-for-diff.sh` enumerates
# untracked files with `--exclude-standard`, so ignoring the plant would
# blind §4b/§4c's own selection to it (measured on #1387).
trap 'git -C "$REPO_ROOT" reset -q -- "$_gfd_plant" 2>/dev/null; rm -rf "$WORK" "$_gfd_plant" ${_gfd_t:+"$_gfd_t"}' EXIT

# --- this suite is ITSELF a declaring guard (your-org/nexus-code#803) -------
#
# Not a formality. It reads the index, the protocol library, the manifest and
# every guard the manifest names — it RUNS each of their `--population` probes —
# so an edit to any of them can change this suite's verdict, which is exactly
# the definition of its population.
#
# It is also the honest resolution of a real discovery ambiguity. Section 5
# below PLANTS a protocol fixture, so this file's text carries both discovery
# tokens whether or not it implements the protocol, and no text predicate can
# tell quoting from implementing without a parse. Rather than exempt the file by
# name — an exemption that would silently cover whatever else got named that way
# — it implements the protocol for real and declares a row like any other guard.
. "$REPO_ROOT/monitor/_guard_population.sh"

# --- THE TWO DERIVATIONS OF "WHICH SUITES DECLARE A POPULATION" ------------
#
# There are two, and there must be two, because §1's entire assertion is that
# they AGREE. They are named here — rather than written inline at their one use
# — because BOTH `gp_population` below and §1 below have to call them, and
# `_guard_population.sh`'s one rule for an implementor is that `gp_population`
# must CALL the guard's own enumerator, never restate what it currently returns.
#
#   _tgfd_recorded    reads the MANIFEST — the checked-in CLAIM
#   _tgfd_discovered  reads the TREE     — the protocol IMPLEMENTATION itself
#
# THE POPULATION IS THE UNION OF BOTH, AND THAT IS THE FIX FOR #1170. It used to
# be the manifest side alone, which made this guard's population *the artefact
# it checks* — so the one edit that can break §1, a suite that BEGINS declaring
# without a manifest row, put no file into this guard's population. The guard
# was then correctly excluded by `guards-for-diff`, appeared under CONSIDERED
# AND EXCLUDED rather than in the blind-spot count, and the run exited 0. Every
# signal read clean and every one of them was telling the truth. The probe
# shared a model with the probed, so it could not fail for the single defect it
# exists to prevent — measured, with a casualty: the `#1166` merge turned `dev`
# red behind an `8 of 8 selected guards PASS` gate.
#
# The union costs NOTHING in the healthy case, which is the property that makes
# it the right shape rather than a widening: when the two derivations agree —
# which is exactly what §1 asserts — the union IS either one of them, so the
# declared population is byte-identical to what it was before. It widens only
# in the state that is already a defect, and it widens by precisely the file
# whose edit created that state. Contrast the alternative of unioning in every
# tracked suite: that selects this expensive guard on any test-file edit
# whatever, which is a cost paid continuously for a defect that is rare.
DECL='gp_handle "$@"'
DECL2='gp_population()'

_tgfd_recorded() {   # the manifest's rows: column 1 of every non-comment line
    "$REAL_GREP" -v '^#' "$MANIFEST" | "$REAL_GREP" -v '^[[:space:]]*$' | cut -f1
}

# THE SENTINEL AXIS (your-org/nexus-code#1226) — column 4, not column 1.
#
# `#1170` widened which files count as DECLARING a population. It did not touch
# a second axis: a file that is some row's declared SENTINEL, but is itself
# neither a suite nor the manifest, was OUTSIDE this suite's population. So the
# sentinel assertion in §2 — the thing that exists to catch a population
# NARROWING — was not selectable BY that narrowing. The guard against the
# failure could not be reached by the failure.
#
# WHAT REACHES THIS ASSERTION, enumerated rather than assumed. Row X's declared
# sentinel S can stop being in X's population three ways:
#
#   1. an edit to X itself            — X is a suite, already in this population
#   2. an edit to the manifest        — already in this population
#   3. an edit to S that removes S from X's ENUMERATOR's output — the gap
#
# (3) is the #1224 shape and it is not hypothetical: dropping `--yes` at
# `monitor/public-mirror/sync-base.sh:104` removed that caller from
# `test-public-mirror-build-entry-guard.sh`'s population and DESELECTED the
# guard — 6 selected before the edit, 5 after, exit 0, the report full and every
# surviving line true.
#
# DELETING S is deliberately NOT in that list, and that is load-bearing rather
# than an oversight: a population row naming a path that no longer exists is
# refused by `gp_render`'s rot check (rc 3), which takes the whole index to
# exit 2. That direction is already loud through a different mechanism, so this
# population does not have to buy it.
#
# THE COST, MEASURED, BECAUSE #1226 REQUIRES THE SIZE AND NOT ONLY THE FIX.
#
# EVERY COUNT BELOW IS CONSUMER-VISIBLE — the rows `gp_render` emits, which is
# what `guards-for-diff` intersects with a diff. Counting raw `gp_population`
# instead answers 72, because `$PROTO` and `$MANIFEST` are emitted absolutely
# there and again relatively as sentinels, and `sort -u` cannot merge two
# spellings of one file. Two numbers, one population; the consumer's is the one
# that means anything, and the assertion below now pins that one.
#
# Selection measured over the last 120 first-parent commits with a non-empty
# diff (`git diff-tree -r --no-commit-id --name-only <sha>^ <sha>`), intersected
# with each population. Population sizes are properties of the ref that produced
# them, so each carries its own:
#
#     population                       ref         selects on
#     28  current (pre-#1226)          989b8880    66/120  (55%)   sentinel axis UNREACHABLE
#     70  the #1226 fix, as merged     d3b45c19   100/120  (83%)   whole axis covered
#     38  narrower, measured+rejected  d3b45c19    71/120  (59%)   content-keyed rows' sentinels only
#     73  dev today                    5bd6d400    97/120  (81%)   whole axis covered
#
# Each row was measured in a worktree AT the ref named, with the HEAD guard and a
# tracked-file positive control run first. The series across this branch is
# 28 (989b8880) -> 28 (859d9bee) -> 68 (c4c3d624) -> 70 (d3b45c19); "68" appears
# in this branch's history and is a true measurement of a different tree, not a
# contradiction of this one.
#
# WHY THE LAST ROW EXISTS, AND WHAT IT COSTS TO ADD ONE. `70` was measured at
# `d3b45c19` and merged as `#1297`; twelve minutes later `#1299` (`07bd3676`)
# enrolled `test-grep-delegation-arms.sh`, whose row brought three files that
# were in no other population — the suite itself, `monitor/grep-delegation-arms.sh`
# and `monitor/grep-delegation-arms.manifest` — and dev went red at 73. NOTHING
# ELSE MOVED: this suite, `monitor/guards-for-diff.sh` and
# `monitor/_guard_population.sh` are byte-identical across that merge
# (`c5f5b858`, `5334f13c`, `7c6c564c` at both `b5cbb0da` and `07bd3676`); only
# the manifest blob changed, `3c885c88` -> `e074d7f5`. That is the ratchet
# working as designed and NOT a defect in `#1299`: enrolling a guard is
# supposed to oblige this re-measurement, and `#1299`'s branch was cut before
# `70` existed, so its author could not have seen the pin.
#
# The re-measurement itself, so the next person does not have to re-derive the
# method from this paragraph:
#
#     bash monitor/watcher/test-guards-for-diff.sh --population | sort -u | wc -l
#
# for the pin, and the selection rate by intersecting that set with
# `git diff-tree -r --no-commit-id --name-only <sha>^ <sha>` over
# `git rev-list --first-parent -n 120 <ref>`.
#
# TWO NUMBERS THAT LOOK LIKE THE SAME NUMBER AND ARE NOT. The pre-#1226
# population is 28; the assertion below prints 29 as its no-sentinel arm. Both
# are correct: 28 is dev with 25 declaring guards, 29 is THIS tree with 26,
# because the #1193 enrolment added one. An earlier draft of this table wrote 29
# in the "current" row, which silently attributed a property of the tip to dev —
# the exact defect this file exists to catch, so it is recorded rather than just
# fixed.
#
# THE NARROWER SET WAS MEASURED AND REJECTED, on this bundle's own subject
# matter. It keys on "does this row's enumerator search CONTENT?", derived by
# grepping each suite for `git grep -l`-shaped calls — which is a predicate over
# SOURCE TEXT standing in for a runtime property, i.e. exactly the proxy this
# file exists to catch, and it under-counts in the silent direction: a
# content-keyed enumerator spelled some other way reads as a corpus walk and its
# sentinel stays unreachable, indistinguishably from today. It was MEASURED and
# rejected, not built — no artefact of it exists in this branch. 24 percentage points
# is not worth buying with a predicate that can drift, so the full union is
# taken and its price is written down here rather than discovered later.
_tgfd_sentinels() {   # column 4 of every row, comma-separated
    "$REAL_GREP" -v '^#' "$MANIFEST" | "$REAL_GREP" -v '^[[:space:]]*$' \
        | cut -f4 | tr ',' '\n' | "$REAL_GREP" -v '^[[:space:]]*$'
}

# The predicate is the protocol CALL — the implementation itself, not a name, a
# directory, or a comment that could drift away from it. Re-derived here rather
# than imported from `guards-for-diff.sh`, deliberately, so the index and this
# suite CAN disagree and §1 can notice.
#
# `:(glob)`, and it is load-bearing (your-org/nexus-code#1111, #954): git matches
# pathspecs with `fnmatch` WITHOUT `FNM_PATHNAME`, so a bare `*` CROSSES `/` and
# `'*test-*.sh'` also matches this repo's `monitor/watcher/test-integration/`
# directory component. Run in a SUBSHELL so the `cd` cannot leak to the caller.
_tgfd_discovered() {
    (
        cd "$REPO_ROOT" || exit 1
        git ls-files -- ':(glob)**/test-*.sh' 2>/dev/null | while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            "$REAL_GREP" -qF -- "$DECL" "$f" 2>/dev/null || continue
            "$REAL_GREP" -qF -- "$DECL2" "$f" 2>/dev/null && printf '%s\n' "$f"
        done
        # AN ENUMERATOR'S EXIT STATUS MUST DESCRIBE THE ENUMERATION, NOT ITS
        # LAST CANDIDATE. A `while` loop's rc is its final iteration's, so this
        # one returns 1 whenever the alphabetically-last suite does not declare
        # — which is the ordinary case — and `set -o pipefail` at the top of
        # this file then carries that 1 out of `gp_population`, where
        # `gp_render` reads it as "the enumerator FAILED" and REFUSES (rc 3).
        # The whole index would exit 2 on a healthy tree. Measured before this
        # line existed. Same idiom as `_env_suite_files` in
        # test-empty-needle-vacuous-helpers.sh, for the same reason.
        true
    )
}

gp_population() {
    printf '%s\n' "$INDEX" "$PROTO" "$MANIFEST"
    # Every guard this suite probes — it RUNS each of their `--population`
    # probes, so an edit to any of them can change this suite's verdict. Read
    # from the manifest rather than listed, so enrolling a guard extends this
    # population without an edit here…
    _tgfd_recorded
    # …AND from the tree, so a suite that BEGINS declaring is in this
    # population on the very commit that makes §1 able to fail (#1170). Neither
    # side alone is sufficient: the manifest side carries a suite that STOPPED
    # declaring, the tree side carries one that has STARTED.
    _tgfd_discovered
    # …AND the SENTINEL axis, so that an edit which narrows a guard's population
    # away from a sentinel it declares can REACH the assertion that catches it
    # (#1226). See _tgfd_sentinels for what this costs and what was rejected.
    _tgfd_sentinels
}
gp_handle "$@"

for f in "$INDEX" "$PROTO" "$MANIFEST"; do
    [[ -r "$f" ]] || { echo "FAIL: missing $f" >&2; exit 1; }
done

# ===========================================================================
# 1. THE MANIFEST IS THE BOUNDARY: the declaring set is EXACTLY these rows.
#
#    Set equality in BOTH directions, and that is the whole mechanism. A guard
#    newly taught the protocol lands here RED and undeclared rather than
#    silently widening what the index covers; a guard that stops declaring
#    lands red rather than silently narrowing it. A one-directional check
#    (every row is real) would pass while the index grew a guard nobody
#    reviewed.
# ===========================================================================
echo "=== 1. the declaring set equals the manifest ==="

# The SAME two enumerators `gp_population` above declares with — called, not
# re-implemented. A copy here would be a second implementation of the very set
# whose two derivations this section exists to compare, and a second
# implementation drifts.
discovered=$(_tgfd_discovered | sort)
recorded=$(_tgfd_recorded | sort)

assert_eq "the guards that DECLARE a population are exactly the manifest's rows" \
    "$discovered" "$recorded"

# REPORT THE DISAGREEMENT, NOT THE TOTALS. `assert_eq` prints two twenty-line
# blobs and leaves the reader to diff them by eye — and the reading that costs
# real time is the one where the two TOTALS match while membership differs by
# one each way. That is this repo's own errors-that-cancel shape (#946 F1,
# #931): a number that reconciles because its errors cancel is not verified,
# and the agreement is what stops anyone looking. `comm` names the sides, and
# labels each with the direction it means.
if [[ "$discovered" != "$recorded" ]]; then
    # Each SIDE is printed only when it has members. A header over an empty list
    # reads as a second, distinct problem — and this section exists to stop one
    # cause looking like several.
    _dis_add=$(comm -23 <(printf '%s\n' "$discovered") <(printf '%s\n' "$recorded") | "$REAL_GREP" -v '^$' || true)
    _dis_del=$(comm -13 <(printf '%s\n' "$discovered") <(printf '%s\n' "$recorded") | "$REAL_GREP" -v '^$' || true)
    if [[ -n "$_dis_add" ]]; then
        printf '  DISAGREEMENT — declares in the TREE, no row in the MANIFEST (the #1170 transition):\n' >&2
        printf '%s\n' "$_dis_add" | sed 's/^/      + /' >&2
        printf '      Fix by ADDING a manifest row (floor + sentinels) for each `+` above.\n' >&2
    fi
    if [[ -n "$_dis_del" ]]; then
        printf '  DISAGREEMENT — row in the MANIFEST, no longer declares in the TREE (coverage LOST):\n' >&2
        printf '%s\n' "$_dis_del" | sed 's/^/      - /' >&2
        printf '      A `-` row is a guard that STOPPED declaring: a regression in coverage,\n' >&2
        printf '      to be argued for in the commit message, not absorbed by regenerating\n' >&2
        printf '      this manifest.\n' >&2
    fi
fi

n_declaring=$(printf '%s\n' "$recorded" | "$REAL_GREP" -c . || true)
# NON-VACUITY of this suite's own enumeration. If `git ls-files` came back
# empty the equality above would compare "" with "" on a corrupted manifest and
# pass — the exact shape being guarded against, inside the guard.
if (( n_declaring >= 3 )); then
    printf '  PASS: %s\n' "the manifest is non-empty ($n_declaring guards) — the equality above is not a comparison of two nothings"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s\n' "manifest has $n_declaring rows; the set equality would be vacuous" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ===========================================================================
# 1b. THIS GUARD'S OWN POPULATION IS SELF-COMPLETING (your-org/nexus-code#1170).
#
#     §1 above is the assertion that catches a suite which begins declaring
#     without a manifest row. It is worth nothing if `guards-for-diff` cannot
#     SELECT this guard on the commit that makes it able to fail — and it could
#     not, because this guard's declared population used to be derived from the
#     manifest alone, i.e. from the artefact §1 checks. A suite gaining
#     `gp_handle` put no file into this population, so the guard was excluded,
#     truthfully, and the gate read 0.
#
#     THE CONTROL NARROWS THE MANIFEST, NOT THE TREE, and that is the only way
#     to build this fixture honestly: the discriminating state is "a suite the
#     TREE says declares and the MANIFEST does not name", and the tree half
#     cannot be planted without a tracked file this suite has no business
#     creating. Removing a row from a COPY of the manifest produces exactly the
#     same disagreement from the other side. Same shape as §2c below, which
#     narrows a real population rather than inventing one.
#
#     ALL THREE ASSERTIONS ARE REQUIRED and none of them is ceremony. The first
#     proves the narrowing actually took (a fixture that did not apply and a
#     real result are byte-identical here). The second proves the tree side is
#     independently non-empty on that path. Only then does the third mean what
#     it says — without the first two it would pass on a manifest that was
#     never narrowed.
# ===========================================================================
echo "=== 1b. this guard's population self-completes from the TREE, not just the manifest (#1170) ==="

# Exact LINE membership, never a substring: `.../test-pane-state.sh` is a
# substring of nothing here today and would be of `.../test-pane-state-x.sh`
# tomorrow, and a membership test that silently widens is the defect class this
# file is about.
_gp_has() {   # _gp_has <newline-list> <path> -> yes|no
    # HERESTRING, NOT A PIPE, and the CI failure that forced it is the whole
    # argument. `grep -q` exits the instant it matches, without draining; if the
    # writer still has bytes, it takes SIGPIPE; `set -uo pipefail` (line 30) then
    # carries the WRITER's non-zero out of the pipeline, so `if` takes the `else`
    # branch and this function answers `no` FOR INPUT THAT MATCHES. Observed, not
    # theorised: run 33696218128, `unit suite (NEXUS_ROOT exported)`, printed
    #   test-guards-for-diff.sh: line 362: printf: write error: Broken pipe
    # immediately above
    #   FAIL: CONTROL: …and the TREE-side derivation still names it — got no want yes
    # while the same commit's `NEXUS_ROOT unset` band passed. The band
    # correlation is NOT root sensitivity — it is this race resolving under the
    # heavier job, and both bands reported `0 of those TIMEOUT`.
    #
    # Forced deterministically here before fixing (the lint's own technique —
    # match on line 1, payload past the pipe buffer): at 220,050 bytes the piped
    # form answers `no` and the herestring answers `yes`. The two forms were then
    # checked EQUIVALENT on eight small-payload cases including BOTH empty ones
    # (empty list + real needle, empty list + empty needle), because the
    # herestring remedy is known to invert the empty case at some call sites —
    # it does not at this one: `printf '%s\n' ""` and `<<<""` both feed grep
    # exactly one empty line.
    #
    # This site is INVISIBLE to `test-sigpipe-assertion-lint.sh` by that lint's
    # own DECLARED boundary (its `_GREPQ_READER` requires the literal token
    # `grep`; here the reader is `"$REAL_GREP"`, a variable). That lint passed
    # 47/0 in the same run this assertion failed in.
    if "$REAL_GREP" -qxF -- "$2" <<<"$1"; then printf 'yes'; else printf 'no'; fi
}

# Chosen from the live set rather than hard-coded, so it cannot rot; and NOT
# this file, whose row is the one a reader would suspect of being special-cased.
_ctl_victim=$(printf '%s\n' "$recorded" \
              | "$REAL_GREP" -vxF -- "monitor/watcher/test-guards-for-diff.sh" \
              | "$REAL_GREP" -v '^$' | sed -n '1p')
# Drop only the ROW whose column 1 is the victim. A plain `grep -vF` would also
# delete every COMMENT line that mentions the path, silently shrinking the
# fixture in ways that have nothing to do with what is being tested.
awk -F'\t' -v v="$_ctl_victim" '$1 != v' "$MANIFEST" > "$WORK/manifest.narrowed"

if [[ -n "$_ctl_victim" ]]; then
    assert_eq "CONTROL: the narrowing APPLIED — the victim is gone from the manifest-side derivation" \
        "$(_gp_has "$( MANIFEST="$WORK/manifest.narrowed"; _tgfd_recorded )" "$_ctl_victim")" "no"
    assert_eq "CONTROL: …and the TREE-side derivation still names it, so the two really are independent" \
        "$(_gp_has "$(_tgfd_discovered)" "$_ctl_victim")" "yes"
    # THE WITNESS. Pre-#1170 this answered `no`: gp_population was the manifest
    # side alone, so a declaring suite with no row was in no population, and the
    # guard that would have caught it could not be selected.
    assert_eq "so gp_population SELF-COMPLETES: a suite that declares with NO manifest row is still in this guard's population" \
        "$(_gp_has "$( MANIFEST="$WORK/manifest.narrowed"; gp_population )" "$_ctl_victim")" "yes"
else
    printf '  FAIL: CONTROL could not pick a victim row — the manifest holds no guard other than this one\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

# THE MUST-NOT-FIRE HALF: on the HEALTHY tree the union must be a no-op. This is
# what makes the union a REPAIR rather than a widening — if it changed the
# population when the two derivations agree, this guard would start selecting on
# edits it has no business being run for, and the cost would be paid on every
# commit instead of on the rare broken one.
#
# GUARDED BY ITS OWN PRECONDITION (your-org/nexus-code#1223 F-D). The claim is
# stated conditionally — "on a tree where the two derivations AGREE" — and used
# to be implemented unconditionally, so in the very state §1b exists to witness
# (a suite declaring with no manifest row) it reddened for a NON-DEFECT reason
# with a message pointing away from the cause. §1 above is already red in that
# state, loudly and correctly; this assertion adding a second red with worse
# wording made one cause look like two. A skeptic hit exactly that while
# planting the transition.
#
# SKIPPED, NOT SILENTLY PASSED, and the distinction is the point of this file:
# a precondition that is not met is not evidence of anything, and reporting it
# as a pass would be the silence-as-absence shape. §1 owns the disagreement.
if [[ "$discovered" == "$recorded" ]]; then
    # THE BASELINE CARRIES THE SENTINELS TOO, so this assertion still isolates
    # the variable it is about (your-org/nexus-code#1226). The claim here is
    # about the DECLARING-SET union — that `_tgfd_discovered` adds nothing when
    # the two derivations agree. The sentinel axis is a SEPARATE and deliberate
    # widening, and leaving it out of the baseline would make this assertion red
    # for a reason it does not name, which is the precise defect the paragraph
    # above records a skeptic hitting.
    _pop_union=$(gp_population | sort -u)
    _pop_manifest_only=$( { printf '%s\n' "$INDEX" "$PROTO" "$MANIFEST"
                            _tgfd_recorded; _tgfd_sentinels; } | sort -u )
    assert_eq "on a tree where the two derivations AGREE, the declaring-set union adds nothing" \
        "$_pop_union" "$_pop_manifest_only"

    # THE SENTINEL AXIS, PINNED ON THE NUMBER A CONSUMER ACTUALLY SEES.
    #
    # COUNTED THROUGH `gp_render`, NOT off raw `gp_population`, and that is the
    # whole correction. `gp_population` emits `$INDEX`/`$PROTO`/`$MANIFEST` as
    # ABSOLUTE paths while `_tgfd_sentinels` emits two of the same three files
    # RELATIVELY, so `sort -u` over the raw output cannot merge them: it counts
    # 72 where `gp_render` — which canonicalises and relativises before
    # de-duplicating — emits 70. The suite was pinning a number no consumer ever
    # sees, and the two spellings of one file are your-org/nexus-code#1218's own
    # defect sitting inside the branch that fixes #1218.
    #
    # `gp_render` is CALLED, never re-implemented: normalising here by hand
    # would be the second implementation this protocol's own header forbids, and
    # it would drift from the renderer the consumer uses. The no-sentinel arm
    # redefines `gp_population` inside a COMMAND SUBSTITUTION, so the override
    # lives and dies in that subshell and cannot leak into the assertions below.
    #
    # EXACT, NOT A BAND, and this is a deliberate change of claim. The previous
    # form accepted `(29, 120]` — ninety values wide — which is a NON-VACUITY
    # check wearing an affordability claim's name, and it duly failed to notice a
    # two-file drift inside this very branch. An exact pin is what makes it an
    # affordability claim: the population size and the selection cost are the
    # same fact measured two ways, so a change to one obliges a re-measurement of
    # the other, and the only way to make this assertion green again is to take
    # that measurement. Brittleness against a new manifest sentinel is the POINT
    # of #1226, not a cost of it.
    #
    # MEASURED AT 5bd6d40037b9b792c9cd1a979195741b66ccc5a3 (dev), nothing
    # staged, working tree clean:
    #   consumer-visible population  73   (`bash <this suite> --population | sort -u | wc -l`;
    #                                      the emit is 73 raw AND deduped, so the
    #                                      73-vs-75 gap is entirely in the counting,
    #                                      not in the protocol output)
    #   without the sentinel axis    30
    #   selection                     97/120 = 81% of the last 120 first-parent
    #                                commits, against 62/120 = 52% at population 30
    #                                (`git diff-tree -r --no-commit-id --name-only <sha>^ <sha>`
    #                                 over `git rev-list --first-parent -n 120 5bd6d400`;
    #                                 all 120 had a non-empty diff)
    #
    # The previous pin was 70/29, measured at d3b45c19 and recorded in the cost
    # table above; both readings are true of the tree that produced them, which
    # is why the old one is kept as a row rather than overwritten.
    #
    # MEASURED AT 85458bf8 + your-org/nexus-code#1219's enrolment, ALL FILES
    # STAGED (the population reads `git ls-files`, so trackedness is a third
    # axis alongside command and ref):
    #   consumer-visible population 103  (`bash <this suite> --population | sort -u | wc -l`)
    #   without the sentinel axis    54  (this suite's own arm prints 54 -> 103;
    #                                an independent reconstruction — manifest
    #                                rows + index + protocol + this suite —
    #                                also answers 54, and that agreement at the
    #                                base is what licenses the rate below)
    #   selection                   105/120 = 87% of the last 120 first-parent
    #                                commits, against 67/120 = 55% at population 54
    #                                (`git diff-tree -r --no-commit-id --name-only <sha>^ <sha>`
    #                                 over `git log --first-parent -n 120 85458bf8`)
    #
    # WHY IT MOVED 73 -> 103, and why a MODIFICATION would not have. #1219
    # enrols 23 previously-undeclared guards (the 22-member CLAUDE.md pin family
    # plus its ratchet, and a gh-stub contract guard), each contributing its
    # suite path and its sentinels to the union. A commit that merely MODIFIES a
    # file already in the union moves this number not at all — that is why
    # #1324, which touched population files and enrolled nothing, re-derived 73
    # UNCHANGED. Enrolment is the axis this pin is sensitive to; the direction
    # was predicted before measurement and a reproduction of 73 here would have
    # meant the enrolment had not taken.
    #
    # RE-DERIVED after enrolling `test-claude-md-marker-ownership.sh`, which
    # arrived on `dev` after this branch was cut and which this branch's own
    # `test-claude-md-population-enrolment.sh` correctly reddened on: it READS
    # CLAUDE.md and declared nothing, so it joined the "reads but does not
    # declare" set that ratchet pins. 103 -> 105: its own suite path plus one
    # sentinel not already in the union (the other two sentinels, CLAUDE.md and
    # the marker manifest, were already members). Measured with everything
    # STAGED, same command as above.
    #
    # RE-DERIVED ON THE MERGE of your-org/nexus-code#1376 into the post-#1330
    # tree: 105 -> 112. #1330 enrolled the CLAUDE.md family (73 -> 105) and this
    # branch enrols #1301's three repo-wide construct lints (73 -> 80); the two
    # sets are DISJOINT, so the union is 105 + 80 - 73 = 112.
    #
    # THE IDENTITY WAS PREDICTED BEFORE THE MERGE AND HELD THROUGH IT. 112 was
    # measured on a throwaway trial-merge while both PRs were still open and
    # published on both; re-measured here after #1330, #1381 and #1356 had all
    # landed, it is 112 again. That is the useful part: inclusion-exclusion
    # holding exactly is what ESTABLISHES the two enrolments are disjoint, which
    # no single count can show — and the two intervening merges touched no
    # population, which is why the figure survived them.
    #
    # Measured with everything STAGED (populations read `git ls-files` and
    # `find`, so trackedness is a third axis alongside command and ref — #1054).
    #
    # +3 for W2-18's reduced set (your-org/nexus-code#1275): ONE guard enrolled
    # (test-operator-path-literals-manifest.sh), contributing its own suite path
    # plus two sentinels not already members — monitor/README.md and
    # monitor/boot-recover.session-start-hook.json. RE-DERIVED against dev's
    # union at THIS base (112 members) rather than carried from the previous
    # rebase, because dev enrolled guards of its own in between and my three
    # members could have become members via their rows. They had not; the delta
    # is still 3, and that is a measurement, not an assumption.
    #
    # THE BASE FIGURE, AND WHY NOT TO DERIVE IT THE WAY I FIRST DID (skeptic
    # item 6c). This assertion compares against `gp_render`, and `gp_render`
    # answers 115 here — verified by this suite passing, which is the only
    # authority for it. Dev's base is therefore 112 and the delta is +3.
    #
    # A hand-rolled count over the manifest —
    # `cut -f1,4 | tr "\t," "\n" | sort -u | wc -l` — answers **111** for the
    # same dev tree, i.e. short by one, and I published that 111 before checking
    # it against the tool. I do NOT know which member it drops: my first
    # explanation was that `gp_handle` adds `monitor/_guard_population.sh` for
    # free and a manifest cut cannot see it (#1197) — measured, the cut already
    # includes it, so that explanation is wrong and is not recorded here as if
    # it were right. What is established is narrower and sufficient: a cut of
    # this manifest is NOT `gp_render`, it is off by one against it on this
    # tree, and the pin must be reconciled against `gp_render` or against this
    # suite's own verdict. Never against the cut.
    # MEASURED AT d4cce33c (dev) + the W2-19 bundle's #1393 enrolment
    # (test-claude-md-nullcmd-redirect.sh declaring CLAUDE.md,
    # bash-footgun-patterns.conf and hooks/bash-footgun-guard.sh), ALL FILES
    # STAGED:
    #   consumer-visible population 118  (`bash <this suite> --population | sort -u | wc -l`;
    #                                     115 at d4cce33c without the enrolment — the
    #                                     +3 is exactly the new suite and its two
    #                                     sentinels, `diff` of the two sorted emits)
    #   without the sentinel axis    60
    #   selection                   105/120 = 88% of the last 120 first-parent
    #                                commits from d4cce33c, against 103/120 = 86%
    #                                at population 115 on the same 120 commits
    #                                (`git diff-tree -r --no-commit-id --name-only <sha>^ <sha>`
    #                                 matched with `grep -qxF -f <population>`).
    #                                One enrolment, +2 percentage points: the two
    #                                sentinels are edited often enough to select
    #                                two more of the 120, which is the cost the
    #                                pin exists to make visible.
    #
    # +2 ON THE W2-17 MERGE (your-org/nexus-code#1378), RE-DERIVED against dev's
    # 115 at 6df5d6b9 rather than carried from #1378's own 80: #1378 enrolled
    # three guards that dev had enrolled independently in the meantime
    # (#1376/#1330 — argloop, shell-files, skeptic-evidence-class-agreement),
    # so of its four rows only test-subshell-exit-guards.sh is NEW to the union.
    # Its two contributions are its own suite path and its manifest sentinel
    # (monitor/watcher/subshell-exit-guards.manifest); its other three sentinels
    # (monitor/ng, test-integration/_harness.sh, shellenv/.zshenv) were already
    # members. 115 + 2 = 117, measured with everything STAGED, same command as
    # above; the two-member delta was reconciled by set difference against the
    # dev tree, not by count.
    #
    # +3 ON THE SAME MERGE for your-org/nexus-code#1435's enrolment of
    # test-flock-fd-cloexec.sh (folded in because this PR already holds the
    # manifest and this pin): its own suite path plus two sentinels not already
    # members, monitor/_install-lib.sh and monitor/watcher/subshell-exit-guards.sh;
    # its third sentinel, monitor/ng, was already a member. 117 + 3 = 120,
    # same command, everything STAGED, delta reconciled by set difference.
    #
    # RE-DERIVED ON THE MERGE OF W2-19 (#1437, dev f1d89cd2) INTO THIS BRANCH:
    # dev's 118 (115 + W2-19's #1393 enrolment) and this branch's 120 (115 + 5)
    # share the 115 base and their enrolments are DISJOINT sets of files, so
    # the union is 118 + 5 = 123. Measured with everything STAGED, same command;
    # the +5 over dev's tree reconciled by set difference, not by count.
    #
    # +2 for your-org/nexus-code#1427's enrolment of test-backtick-label-lint.sh
    # in the same bundle: its own suite path and one sentinel not already a
    # member (monitor/test-obligations.sh — one of the two live sites the lint
    # found on enrolment); its other two sentinels were members. 123 + 2 = 125,
    # same command, everything STAGED, the delta reconciled by set difference.
    #
    # +3 for your-org/nexus-code#1403's enrolment of test-errexit-assignment-status.sh
    # in the same bundle: its own suite path plus two sentinels not already
    # members (monitor/shell-files.sh, monitor/upload-asset.sh); monitor/ng was
    # a member. 125 + 3 = 128, same command, everything STAGED, set difference.
    #
    # +1 for test-th-require-fixture-repo.sh (#1429) declaring its population on
    # creation (its three sentinels were already members): 128 + 1 = 129.
    #
    # +3 for test-heartbeat-schema-agreement.sh (your-org/nexus-code#1374)
    # declaring its population on creation: its own suite path plus two
    # sentinels not already members (monitor/worker-heartbeat.sh,
    # monitor/hooks/async-launch-detect.sh — neither named by any manifest row
    # or inline declaration at bbf8fa86); monitor/pane-state.sh was a member.
    # 129 + 3 = 132, same command, everything STAGED, set difference.
    #
    # +3 for test-awk-v-escape-lint.sh (your-org/nexus-code#1420) declaring its
    # population on creation: its own suite path plus two sentinels not already
    # members (monitor/watcher/awk-v-escape-lint.sh, the lint itself, and
    # monitor/notifywrap/sandbox-notify — the shebang-only wrapper no *.sh
    # glob sees; named by no other row at 741191c8); its third sentinel,
    # monitor/ng, was a member. 132 + 3 = 135, same command, everything
    # STAGED (measured 132 -> 135 with the three new files tracked), set
    # difference.
    #
    # +2 for test-helper-honesty.sh's row (your-org/nexus-code#1364): the
    # undefined-helper lint's population widened from the 261 helper-sourcing
    # suites to every tracked test-* suite (454), and the row gained two
    # sentinels from the corners the OLD population dropped —
    # monitor/test-conflict-marker-lint.sh (a non-sourcing suite outside
    # monitor/watcher/ that defines its own ok/bad) and
    # monitor/watcher/test-integration/test-graceful-exit-relaunch.sh (a nested
    # path). The 193 newly-enrolled suites were ALREADY consumer-visible
    # through the stub-claude and summary-honesty populations, so the widening
    # itself moved nothing; the two sentinels were the only new members.
    # 132 + 2 = 134 at 00202d40, same command, everything STAGED, set
    # difference (measured: 134 with the row, 132 without it).
    #
    # MERGE (w222): the two increments above are DISJOINT sets — the lint's
    # three (own suite, awk-v-escape-lint.sh, notifywrap/sandbox-notify) and
    # the honesty row's two (test-conflict-marker-lint.sh,
    # test-integration/test-graceful-exit-relaunch.sh) share no member — so
    # 132 + 3 + 2 = 137 by set difference; measured on the merged tree with
    # everything STAGED (see the W2-22 report for the run).
    #
    # w223 RECONCILIATION (your-org/nexus-code#1464's enrolment found it): the
    # three w223 rows — test-entry-signals.sh (#1445), test-claude-md-grep-h-order.sh
    # (#1461), test-assets-untracked.sh (#1458) — each bumped this pin by +1 for
    # their own suite path, but their sentinels brought THREE more members no
    # other row named: monitor/watcher/_entry_signals.sh,
    # monitor/watcher/test-startup-window-signal.sh and .gitignore
    # (monitor/upload-asset.sh was already a member via the errexit row). So
    # 137 + 6 = 143, MEASURED at b810d67b on a clean tree with
    # `bash monitor/watcher/test-guards-for-diff.sh --population | sort -u | wc -l`
    # — the pin read 140 and was red by 3 before this change.
    #
    # +1 for test-claude-md-count-vs-list.sh (your-org/nexus-code#1464)
    # declaring its population on creation: its own suite path; both sentinels
    # (CLAUDE.md, monitor/watcher/_test_helpers.sh) were already members.
    # 143 + 1 = 144, same command, everything STAGED, set difference.
    #
    # +3 for test-guard-closure-boundary.sh's row (your-org/nexus-code#1301,
    # the operator's "fix" instance: the guard that caught the #1448 jq red and
    # was invisible to the index for the same diff): its own suite path plus
    # two sentinels no other row named — monitor/cc-harness/gate.sh (the
    # incident file) and monitor/guard-block.sh.in (the `.sh.in` template).
    # Its other two sentinels, monitor/ng and monitor/bash-footgun-patterns.conf,
    # were already members. 145 + 3 = 148, same command, everything STAGED,
    # set difference (measured at d733d7be: 145 without the row, 148 with it).
    #
    # +11 for the four W2-25 ratchets (your-org/nexus-code#1264 R4/R5, #1301
    # item 3, #904): their four suite paths (test-guard-positive-controls.sh,
    # test-skills-catalog.sh, test-suite-declaration-census.sh,
    # test-claude-md-entry-budget.sh) plus SEVEN sentinels no other row named
    # — docs/reference/skills.md, monitor/test-ci-trigger-audit.sh,
    # monitor/watcher/claude-md-entry-budget.manifest,
    # monitor/watcher/guard-positive-controls.manifest,
    # monitor/watcher/suite-declarations.manifest,
    # skills/nexus.cc-update/GUIDE.md, skills/nexus.claims/SKILL.md. Their
    # other sentinels (CLAUDE.md, guard-populations.manifest,
    # test-spawn-shape-manifest.sh, test-guards-for-diff.sh) were already
    # members. 148 + 4 + 7 = 159, same command, everything STAGED, set
    # difference measured on the W2-25 tree (152 with the suites tracked but
    # their rows stashed — the four paths arrive by DISCOVERY — 159 with the rows).
    #
    # +2 for test-ci-band-coverage.sh (your-org/nexus-code#1474 finding 1): its
    # own suite path plus its one sentinel, monitor/ci-band-coverage.sh, which no
    # other row named. 159 + 2 = 161, same command, everything STAGED.
    #
    # +9 for the four rows added by the w230 bundle (your-org/nexus-code#1494,
    # #1301 item 2, #1490): their FOUR suite paths — test-count-fallback-lint.sh,
    # test-tmux-shim-gate3-safety.sh, test-cc-auto-update.sh (the three the
    # index could not see on PR #1493, two of which CI reddened on) and
    # test-tee-reopen-lint.sh (a new lint, declaring at BIRTH rather than
    # retrofitted) — plus FIVE sentinels no other row named:
    # .github/workflows/tests.yml, monitor/cc-auto-update-prompt.md,
    # monitor/watcher/_cc_update.sh, monitor/watcher/_tmux-fixture.sh and
    # monitor/watcher/_tmux_shim_scan.awk. Their remaining sentinels
    # (monitor/ng, monitor/shellenv/.zshenv, monitor/watcher/_shell_quotes.awk,
    # monitor/pane-state.sh, monitor/notifywrap/sandbox-notify,
    # monitor/watcher/_test_helpers.sh) were already members. 161 + 9 = 170,
    # same command, everything STAGED, measured as a SET DIFFERENCE against a
    # detached worktree at 1fadbc67 rather than as two totals: 161 there, 170
    # here, NINE added and ZERO removed, each explicable. A matching total is
    # not evidence and neither is a matching delta; the membership is.
    #
    # +3 for test-cc-auto-update-default-docs.sh's row (your-org/nexus-code#1476,
    # declaring at birth): its own suite path plus two sentinels no other row
    # named — config/nexus.example.yml and docs/reference/watcher-protocol.md.
    # Its third sentinel, monitor/watcher/_config.sh, was already a member.
    # 170 + 3 = 173, same command, everything STAGED, measured as a SET
    # DIFFERENCE against a detached worktree at 4f73e0e7: three added, zero
    # removed, each named above.
    #
    # +2 for test-report-schema-disposition-doc.sh's row (your-org/nexus-code#1512,
    # declaring at birth): its own suite path plus one sentinel no other row
    # named — skills/nexus.report/SKILL.md. Its other sentinel, monitor/ng, was
    # already a member. 173 + 2 = 175, same command, everything STAGED, set
    # difference against the tree one commit earlier (c34942c4): two added,
    # zero removed.
    #
    # +2 for test-pane-state-restart-quiescence.sh (w234, the cc-update restart's
    # turn-boundary gate) declaring its population on creation: its own suite
    # path plus one sentinel no other row named,
    # monitor/watcher/fixtures/idle-empty-synthetic.ansi. Its other sentinels
    # (monitor/pane-state.sh, monitor/cc-auto-update-apply.sh) and its sourced
    # library were already members. 170 + 2 = 172, same command, everything
    # STAGED, measured as a SET DIFFERENCE against a detached worktree at
    # 4f73e0e7: TWO added, ZERO removed. Selection rate over the last 120
    # first-parent commits of origin/dev @ 4f73e0e7: 77/120 with the 170-member
    # set and 77/120 with the 172-member set, so the cost moved by nothing
    # measurable.
    #
    # INTEGRATION (w239 bundle). The two increments above are disjoint, so
    # the merge first pinned their SUM, 177 — a number no instrument had
    # measured. This suite's own probe on the merged tree 8d0cff30 never
    # reached this assertion (the manifest-census failure above it
    # short-circuited the run), and a replica of gp_population's three
    # enumerators on that tree gives 178: the sum was already off by one,
    # because "already a member" is a claim about ONE tree and the two
    # authors made it on different trees.
    #
    # +3 for test-auth-hold.sh's row (your-org/nexus-code#1518, enrolled by
    # the w239 integration after the census reddened on the declaring,
    # row-less suite): its three sentinels, none previously a member —
    # monitor/_bookkeeping.sh, monitor/watcher/_auth_hold.sh and
    # monitor/watcher/fixtures/blocked-login-method-realmodel-268.ansi. The
    # suite path itself was already present by DISCOVERY. Set difference
    # 8d0cff30 -> f30fff00 by the replica: three added, zero removed, each
    # named. THIS suite's measurement on f30fff00: 181, same command,
    # everything STAGED — the pin is the instrument's reading, not a sum.
    # +3 for test-trap-bare-return-lint.sh's row (your-org/nexus-code#1513,
    # w239 D10, declaring at birth): its own suite path plus the two
    # sentinels no other row named — monitor/watcher/_trap_bare_return.awk
    # (the classifier) and monitor/watcher/trap-bare-return.allowlist (the
    # data that silences it). Its other sentinels (monitor/ng,
    # monitor/shellenv/.zshenv, monitor/watcher/_shell_quotes.awk) were
    # already members. MEASURED as a set difference against a detached
    # worktree at the merge commit 8d0cff30, same command, everything STAGED:
    # THREE added, ZERO removed, each named above. The base itself measured
    # 178 there, not the 177 the line above records — one member the
    # integration sum did not account for, present at the merge commit
    # before this row existed (reported in the w239 D10 report; the pin
    # below is the measured 178 + 3, not 177 + 3).
    #
    # MERGED (w239): the two +3 increments above are disjoint (auth-hold's
    # sentinels vs the D10 lint's suite path, classifier and allowlist),
    # both measured against the same base 8d0cff30 whose replica reading is
    # 178; the pin is 178 + 3 + 3 = 184, confirmed by this suite's own run
    # on the final bundle tree (see the w239 report for command + sha).
    #
    # +2 for test-tmux-selection-restore.sh's row (your-org/nexus-code#1528,
    # w240, declaring at birth): its own suite path (by DISCOVERY) and the one
    # sentinel no other row named, monitor/watcher/_respawn.sh — the single
    # restore site under test. Its other sentinels (monitor/_tmux-window.sh,
    # monitor/cc-auto-update-apply.sh) were already members. MEASURED as a set
    # difference against a detached worktree at the base 353867a0 (which reads
    # 184 there, this suite's own --population, sorted unique), everything
    # STAGED on the w240 tree: TWO added, ZERO removed, each named. Selection
    # rate over the last 120 first-parent commits of 353867a0: 82/120 with the
    # 184-member set, 84/120 with the 186-member set — the two extra commits
    # are the ones touching _respawn.sh, which is the cost of enrolling it.
    #
    # +3 for test-cc-update-no-remote-code.sh's row (your-org/nexus-code#1529,
    # w241, declaring at birth): its own suite path plus the two sentinels no
    # other row named — monitor/cc-harness/mock-backend.py (the non-shell
    # harness member) and monitor/watcher/_version_restart.sh (the module that
    # only PRINTS the deploy advisory the guard pins to `main`). Its other
    # sentinels (monitor/cc-auto-update-prompt.md, skills/nexus.cc-update/
    # GUIDE.md) were already members. 184 + 3 = 187, same command, everything
    # STAGED, measured as a SET DIFFERENCE against a detached worktree at
    # 353867a0 (HEAD equality and a tracked-file positive control checked
    # first): THREE added, ZERO removed, each named above. Selection rate over
    # the last 120 first-parent commits of 353867a0: 81/120 with the 184-member
    # set and 81/120 with the 187-member set — the cost moved by nothing
    # measurable.
    #
    # MERGED (bundle-2609, w240 + w241 on 353867a0): the +2 and +3 above are
    # disjoint (w240: _respawn.sh and its own suite path; w241: its own suite
    # path, mock-backend.py and _version_restart.sh), so 184 + 2 + 3 = 189 is
    # the arithmetic — and 189 is what THIS suite measured on the merged
    # tree with everything STAGED:
    #     bash monitor/watcher/test-guards-for-diff.sh --population | sort -u | wc -l
    # The pin is that reading, not the sum.
    _TGFD_POP_EXPECTED=189
    _n_pop=$( gp_render "" 2>/dev/null | sort -u | "$REAL_GREP" -c . )
    _n_nosent=$(
        gp_population() { printf '%s\n' "$INDEX" "$PROTO" "$MANIFEST"
                          _tgfd_recorded; _tgfd_discovered; }
        gp_render "" 2>/dev/null | sort -u | "$REAL_GREP" -c .
    )
    if (( _n_pop > _n_nosent )); then
        printf '  PASS: %s\n' "the sentinel axis widens the consumer-visible population ($_n_nosent -> $_n_pop) — non-vacuity"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "the sentinel axis adds nothing: without it $_n_nosent, with it $_n_pop (your-org/nexus-code#1226)" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    if (( _n_pop == _TGFD_POP_EXPECTED )); then
        printf '  PASS: %s\n' "the consumer-visible population is exactly $_TGFD_POP_EXPECTED — the affordability claim still holds"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "consumer-visible population is $_n_pop, pinned at $_TGFD_POP_EXPECTED." >&2
        printf '        This guard runs %d --population probes when selected, so its size IS\n' "$n_declaring" >&2
        printf '        its cost. Do NOT just edit the constant: re-measure the selection rate\n' >&2
        printf '        over the last 120 first-parent commits and update it, the constant, and\n' >&2
        printf '        the comment above together (your-org/nexus-code#1226).\n' >&2
        printf '        Re-measure with:\n' >&2
        printf '          bash %s --population | sort -u | wc -l\n' "${BASH_SOURCE[0]}" >&2
        printf '          # then intersect that set with, for each of\n' >&2
        printf '          #   git rev-list --first-parent -n 120 <ref>\n' >&2
        printf '          #   git diff-tree -r --no-commit-id --name-only <sha>^ <sha>\n' >&2
        printf '        A population that grew usually means a guard was ENROLLED in the\n' >&2
        printf '        manifest and brought paths no other row named; that is the ratchet\n' >&2
        printf '        working, not a defect in the enrolling PR.\n' >&2
        FAIL=$(( FAIL + 1 ))
    fi
else
    printf '  SKIP: the union no-op check needs the two derivations to AGREE, and they do not\n' >&2
    printf '        on this tree — which is §1'"'"'s red above, not a second defect. Fix the\n' >&2
    printf '        manifest row and this check becomes meaningful again.\n' >&2
fi

# ===========================================================================
# 2. EVERY DECLARED POPULATION IS REAL: above its floor, and every path exists.
#
#    The floor is the non-vacuity ratchet. The existence check is
#    about ROT: a population naming a deleted file no longer describes what the
#    guard reads, and it is the kind of staleness nothing else in the repo
#    would notice.
# ===========================================================================
echo "=== 2. each declared population is above its floor, and every path is real ==="

# THE PROBE BUDGET IS THE INDEX'S, NOT THIS SUITE'S OWN (your-org/nexus-code#1197).
#
# These two numbers used to disagree: the index probed each guard under
# `timeout 180` and this suite probed the SAME guards under `timeout 300`. A
# guard whose population probe lands anywhere in the 181-300 s band is
# therefore GREEN here and REFUSED — exit 2, the whole index down — in the tool
# this file exists to guard. That is a second, independent mechanism for
# "guards-for-diff is DOWN and its own suite cannot notice", alongside the
# unbounded untracked walk #1197 is filed about, and it is not reachable by any
# amount of care in the probes themselves: the guard was measuring a different
# threshold from the one that decides the outcome.
#
# Two derivations of the same threshold is one too many, so the literal lives
# here and the assertion below pins the index to it. A drift in either
# direction reds this suite rather than silently re-opening the band.
GFD_PROBE_BUDGET=180
assert_contains "the index probes with the SAME budget this suite enforces — a probe that would REFUSE the tool must RED the guard" \
    "$(cat "$INDEX")" "timeout $GFD_PROBE_BUDGET bash \"\$suite\" --population"
# `_sentinels_missing <pop-file> <comma-list>` — which named members are ABSENT
# from a declared population. Extracted so §2b's live check and §2c's planted
# control run the SAME predicate; a control that re-implements what it controls
# for is checking its own copy (your-org/nexus-code#839's third-source point).
_sentinels_missing() {
    local popfile="$1" list="$2" s missing=""
    # No `read -ra`: this suite runs under bash, but the idiom is one zsh
    # paste away from an empty array at rc 127, and an empty sentinel array
    # would report every row clean. Split with the shell-agnostic form.
    local IFS_SAVE="$IFS"; IFS=','
    for s in $list; do
        [[ -n "$s" ]] || continue
        "$REAL_GREP" -qxF -- "$s" "$popfile" || missing+="$s "
    done
    IFS="$IFS_SAVE"
    printf '%s' "$missing"
}
n_sentinels_checked=0
while IFS=$'\t' read -r suite floor kind sentinels _reason; do
    [[ -n "$suite" ]] || continue
    pop="$WORK/pop.$(basename "$suite")"
    if ! ( cd "$REPO_ROOT" && timeout "$GFD_PROBE_BUDGET" bash "$suite" --population ) > "$pop" 2>"$pop.err"; then
        printf '  FAIL: %s --population failed\n' "$suite" >&2
        sed 's/^/      /' "$pop.err" >&2
        FAIL=$(( FAIL + 1 ))
        continue
    fi
    n=$(wc -l < "$pop" | tr -d ' ')
    if (( n >= floor )); then
        printf '  PASS: %s\n' "$suite declares $n files (floor $floor, $kind)"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s declares %d files, below its floor of %s — an enumerator that went blind reads as "does not scan your diff"\n' \
            "$suite" "$n" "$floor" >&2
        FAIL=$(( FAIL + 1 ))
    fi

    missing=""
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        [[ -e "$REPO_ROOT/$p" ]] || missing+="$p "
    done < "$pop"
    assert_eq "$suite's declared population names only paths that exist" \
        "$missing" ""

    # 2b. THE LOAD-BEARING HALF (your-org/nexus-code#943). The floor above is a
    # size bound, so it is satisfied by any N and can only catch an enumerator
    # that returned NOTHING. Measured on `e256d4a`, these floors sit at 38-62%
    # of their live populations, so a guard could lose a third of what it reads
    # and stay green while the index told every worker "does not read your
    # diff". Sentinels are named members from structurally different corners:
    # a narrowing that clears the floor still has to keep every one.
    [[ -n "$sentinels" ]] || { printf '  FAIL: %s declares no sentinels — column 4 is not optional (#943)\n' "$suite" >&2; FAIL=$(( FAIL + 1 )); continue; }
    s_missing=$(_sentinels_missing "$pop" "$sentinels")
    n_sentinels_checked=$(( n_sentinels_checked + $(tr ',' '\n' <<<"$sentinels" | "$REAL_GREP" -c .) ))
    assert_eq "$suite's population contains every sentinel it declares" \
        "$s_missing" ""
done < <("$REAL_GREP" -v '^#' "$MANIFEST" | "$REAL_GREP" -v '^[[:space:]]*$')

# 2c. THE POSITIVE CONTROL, because a membership check that names nothing
#     passes forever, and because the whole point of #943 is that a bound which
#     cannot fail is not protection. Take a REAL declared population, delete one
#     sentinel from it while leaving it far above its floor, and require the
#     same predicate §2b uses to see the loss.
#
#     THE FLOOR MUST STILL BE CLEARED IN THIS FIXTURE. If the narrowed copy fell
#     below the floor, the floor would catch it and this control would prove
#     nothing about sentinels — it would be measuring the mechanism it exists to
#     show is insufficient.
_ctl_pop="$WORK/pop.test-ambient-shell-option-scope.sh"
_ctl_sent="monitor/ng"
_ctl_floor=300
if [[ -s "$_ctl_pop" ]]; then
    "$REAL_GREP" -vxF -- "$_ctl_sent" "$_ctl_pop" > "$WORK/pop.narrowed" || true
    _ctl_n=$(wc -l < "$WORK/pop.narrowed" | tr -d ' ')
    assert_eq "CONTROL: the narrowed fixture still CLEARS the floor, so only the sentinel check can catch it" \
        "$(( _ctl_n >= _ctl_floor ? 1 : 0 ))" "1"
    assert_eq "CONTROL: dropping one sentinel from a real population IS seen — the check is not vacuous" \
        "$(_sentinels_missing "$WORK/pop.narrowed" "$_ctl_sent")" "$_ctl_sent "
    assert_eq "CONTROL: …and the unmodified population is clean under the same predicate" \
        "$(_sentinels_missing "$_ctl_pop" "$_ctl_sent")" ""
else
    printf '  FAIL: CONTROL fixture missing — %s was not produced above\n' "$_ctl_pop" >&2
    FAIL=$(( FAIL + 1 ))
fi
printf '  note: %d sentinel membership(s) checked across the manifest\n' "$n_sentinels_checked"

# ===========================================================================
# 3. SELECTION, PLANTED BOTH WAYS.
#
#    3a is the #803 occurrence-1 shape reduced to one line: `monitor/ng` is in
#    the ambient-shell-option guard's population and in no directory a worker
#    editing `ng` would think to look. 3b is the case that matters more for
#    honesty — an empty selection must be a SENTENCE with the considered list
#    attached, never a silent success.
# ===========================================================================
echo "=== 3. selection: a scanned file selects, an unscanned one says so out loud ==="

printf 'monitor/ng\n' > "$WORK/changed-ng.txt"
out=$(cd "$REPO_ROOT" && bash "$INDEX" --changed-files "$WORK/changed-ng.txt" 2>&1); rc=$?
assert_rc "a diff touching monitor/ng selects at least one guard (rc 0)" "$rc" 0
assert_contains "…and it is the guard whose population monitor/ng is in (#803 occurrence 1)" \
    "$out" "test-ambient-shell-option-scope.sh"
assert_contains "…with the REASON named, not just the suite" \
    "$out" "because it reads: monitor/ng"

# A path no guard's enumerator can produce: not tracked, not shell, not under
# monitor/. It must survive the `--changed-files` route unchanged.
printf 'docs/nothing-any-guard-reads.txt\n' > "$WORK/changed-none.txt"
out=$(cd "$REPO_ROOT" && bash "$INDEX" --changed-files "$WORK/changed-none.txt" 2>&1); rc=$?
assert_rc "an unscanned diff exits 3 — its own code, distinct from a selection" "$rc" 3
assert_contains "…and SAYS the selection is empty rather than printing nothing" \
    "$out" "SELECTED: NONE."
assert_contains "…and states how many guards were CONSIDERED" \
    "$out" "guards were CONSIDERED"
# The load-bearing half: the considered list must be NON-EMPTY. "0 selected"
# with an empty considered list is indistinguishable from an index that never
# ran, which is the defect class this whole file is about.
considered=$(printf '%s\n' "$out" | sed -n '/^CONSIDERED AND EXCLUDED/,/^$/p' \
             | "$REAL_GREP" -c 'population [0-9]* files' || true)
if (( considered >= 3 )); then
    printf '  PASS: %s\n' "the empty selection ships a NON-EMPTY considered list ($considered guards, each with its population size)"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s\n' "empty selection listed only $considered considered guards — a silent zero wearing a report's clothes" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ===========================================================================
# 4. THE RESIDUAL IS PRINTED, AND IT IS THE REAL NUMBER.
#
#    The index's honesty rests on this line: it names the guards it knows and
#    then says how many suites it does NOT know. A hard-coded or stale number
#    there would be a coverage claim nobody checked.
# ===========================================================================
echo "=== 4. the invisible residual is stated, and matches the live count ==="
# `:(glob)`, MIRRORING THE TOOL EXACTLY (your-org/nexus-code#1111). This line
# re-implements the index's own suite predicate in order to assert the number
# the index prints, so the two must agree by construction. They did not: both
# used `'*test-*.sh'`, whose `*` CROSSES `/` (git matches pathspecs with
# `fnmatch` WITHOUT `FNM_PATHNAME`), so both counted
# `monitor/watcher/test-integration/_harness.sh` and `.../stub-claude.sh` —
# a shared library and a `claude` shim — as tracked test suites. 368 against a
# true 366 at 7c4ddbb.
#
# The check PASSED throughout, and that is the instructive part: an assertion
# that re-derives a number with the SAME predicate the subject used confirms
# the two agree, never that either describes what the label claims. Both sides
# were wrong by exactly 2 and reconciled perfectly. Reconciliation between two
# implementations of the same mistake is not verification — the independent
# check is `find monitor .github -name "test-*.sh" -type f` (366), which is how
# run-tests.sh actually dispatches, and it disagreed with both.
n_suites=$(cd "$REPO_ROOT" && git ls-files -- ':(glob)**/test-*.sh' | "$REAL_GREP" -c . || true)
# THE EXPECTED RESIDUAL IS COMPUTED FROM THE **TREE**, NOT FROM THE MANIFEST
# (your-org/nexus-code#1223 F-E). `n_declaring` above is derived from `$recorded`
# — the manifest — while `guards-for-diff` derives its own declaring count from
# the TREE. On a healthy tree the two agree and either works; in the #1170
# transition state they differ by one, and this assertion then reddened with
# `expected to find: 358 of 381` against the index's true `357 of 381` — sending
# a triager at the INDEX'S ARITHMETIC rather than at the missing manifest row.
#
# It failed LOUD, so it was never the silent class and never a defect. But it is
# #1170's own shape one level down — an assertion ABOUT the index keyed on the
# artefact rather than on what the index actually reads — and the composite cost
# was that one cause produced three reds, two of them misdirecting. Keyed on the
# tree, this check now agrees with the index by construction and §1 is left to
# own the disagreement, which is the only place it belongs.
n_declaring_tree=$(printf '%s\n' "$discovered" | "$REAL_GREP" -c . || true)
want_residual=$(( n_suites - n_declaring_tree ))
assert_contains "the report states the residual as <not-declaring> of <all suites>" \
    "$out" "$want_residual of $n_suites tracked test suites"
assert_contains "…and says plainly that it is not a substitute for the full suite" \
    "$out" "not a substitute for the full suite"

# 4b. The UNTRACKED warning. Several enrolled guards enumerate via
#     `git ls-files`, which cannot see a file that has not been `git add`ed —
#     so the index under-selects for the change most likely to ENTER a
#     population, namely adding one. Silence there would be an exclusion the
#     reader has no way to distrust.
# A REAL untracked file, not a path that merely reads like one. It used to be
# the literal string `monitor/definitely-not-added-yet.sh`, which named nothing
# on disk — so this assertion passed on a tree in which the fixture could not
# exist, and could not distinguish "absent from the index" from "absent
# altogether". That distinction IS your-org/nexus-code#1179, so the fixture had
# to become the thing it stands for before the fix could be tested at all.
_U_ADD="$_PLANT/definitely-not-added-yet.sh"
printf '#!/usr/bin/env bash\n# planted untracked fixture\n' > "$REPO_ROOT/$_U_ADD"
printf '%s\n' "$_U_ADD" > "$WORK/changed-untracked.txt"
uout=$(cd "$REPO_ROOT" && bash "$INDEX" --changed-files "$WORK/changed-untracked.txt" 2>&1)
assert_contains "an untracked changed file is NAMED as untracked, not silently excluded" \
    "$uout" "$_U_ADD"
assert_contains "…with the reason and the remedy" \
    "$uout" "CANNOT SEE these"
# The control: a TRACKED file must NOT raise the warning, or it would fire on
# every run and mean nothing.
assert_not_contains "a tracked-only diff raises no untracked warning (the control)" \
    "$(cd "$REPO_ROOT" && bash "$INDEX" --changed-files "$WORK/changed-ng.txt" 2>&1)" \
    "UNTRACKED ("

# 4c. THE SELECTED DIRECTION (your-org/nexus-code#1054). 4b above covers
#     EXCLUSIONS — a guard that shows as reading nothing. The opposite and more
#     dangerous case is a guard that IS selected, RUNS, and returns a confident
#     GREEN while blind to an untracked file in the same diff. A reader who
#     finds their guard under SELECTED reasonably concludes 4b's caveat is not
#     about them, which is exactly what happened: a worker recorded two guards
#     green and its skeptic measured them red at the same commit, and the
#     discriminating variable was THE INDEX, not the ref.
#
#     Measured on this tree at 2d32449, content held constant and trackedness
#     the only variable: a planted file with one early-exit reader scored
#     `21 passed, 0 failed` untracked and `20 passed, 1 failed` once `git add`ed.
#     The plant is absent from the guard's population while untracked and
#     present once staged — which is why the green is a claim about a tree that
#     does not contain it.
#
#     BOTH DIRECTIONS ARE ASSERTED. A green that cannot see an untracked
#     changed file must print UNVERIFIED and exit 4; a tracked-only diff must
#     still print PASS and exit 0, or the qualifier fires on every run and means
#     nothing.
echo "=== 4c. a green from a guard blind to an untracked file is UNVERIFIED (#1054) ==="
# Again a REAL untracked file (your-org/nexus-code#1179): it must EXIST on disk
# and be absent from the index, because that pair is exactly the #1054 hazard
# and existence is now what separates it from a deleted path.
_U_BLIND="$_PLANT/test-zz-1054-not-added.sh"
printf '#!/usr/bin/env bash\n# planted untracked fixture\n' > "$REPO_ROOT/$_U_BLIND"
printf 'monitor/watcher/early-exit-readers.sh\n%s\n' "$_U_BLIND" \
    > "$WORK/changed-blind.txt"
printf 'monitor/watcher/test-early-exit-reader-manifest.sh\n' > "$WORK/suites-eer.txt"
bout=$(cd "$REPO_ROOT" && bash "$INDEX" --changed-files "$WORK/changed-blind.txt" \
        --suites-from "$WORK/suites-eer.txt" --run 2>&1); brc=$?
assert_contains "the SELECTED listing names what the guard is BLIND TO" \
    "$bout" "BLIND TO (untracked, absent from its population): $_U_BLIND"
assert_contains "the VERDICT itself is downgraded, not merely warned beside" \
    "$bout" "UNVERIFIED monitor/watcher/test-early-exit-reader-manifest.sh"
assert_contains "…and says which tree the green is actually about" \
    "$bout" "its population does not contain"
assert_not_contains "a downgraded guard does NOT also print PASS" \
    "$bout" "    PASS monitor/watcher/test-early-exit-reader-manifest.sh"
assert_eq "…and --run exits 4, distinct from 0/2/3 so it cannot read as a clearance" \
    "$brc" "4"
assert_contains "the exit is labelled as not a clearance" \
    "$bout" "NOT A CLEARANCE (exit 4)"

# THE MUST-NOT-FIRE CONTROL. Same guard, same command, tracked-only diff.
printf 'monitor/watcher/early-exit-readers.sh\n' > "$WORK/changed-tracked-only.txt"
tout=$(cd "$REPO_ROOT" && bash "$INDEX" --changed-files "$WORK/changed-tracked-only.txt" \
        --suites-from "$WORK/suites-eer.txt" --run 2>&1); trc=$?
assert_contains "a tracked-only diff still yields a real PASS" \
    "$tout" "    PASS monitor/watcher/test-early-exit-reader-manifest.sh"
assert_not_contains "…and no UNVERIFIED verdict (the qualifier must not fire on every run)" \
    "$tout" "UNVERIFIED monitor/"
assert_not_contains "…and no BLIND TO line" "$tout" "BLIND TO"
assert_eq "…and it exits 0, a genuine clearance" "$trc" "0"

# ===========================================================================
# 4d. A DELETED PATH IS NOT AN UNTRACKED ONE (your-org/nexus-code#1179).
#
#     #1054's predicate asked "is this path in the index". True, and the wrong
#     question: a path absent from the index because it was DELETED is one the
#     guard CORRECTLY does not see, and there is nothing there to be blind to.
#     So `git rm` — and every rename git does not resolve to an `R` — marked
#     every selected guard BLIND TO the vanished path and downgraded every
#     green to UNVERIFIED, exit 4, on a fully committed clean tree.
#
#     What made that corrosive rather than merely noisy is that the printed
#     remedy was UNREACHABLE: you cannot `git add` a path that does not exist
#     into `git ls-files`, so no state existed in which that diff returned 0.
#     Exit 4 exists so an unverified green cannot read as a clearance; a code
#     that fires on every deletion and cannot be cleared is one the reader
#     learns to dismiss, and the next time it fires for the real #1054 reason
#     it will look identical.
#
#     THE PAIR IS THE ASSERTION, and EXISTENCE IS THE ONLY VARIABLE. Same
#     supplied diff, same guard, same command, same repo-relative path — the
#     file is present in the first arm and absent in the second. Either arm
#     alone proves nothing: "does not fire" is satisfied by a predicate that
#     never fires, and "fires" by one that always does.
# ===========================================================================
echo "=== 4d. a DELETED path is not an untracked one — existence is the only variable (#1179) ==="

#     THE GUARD HERE IS A PLANTED TRIVIAL ONE, not the real
#     early-exit-reader-manifest §4c uses, and that is a deliberate choice in
#     both directions. It ISOLATES the variable — the verdict then depends on
#     nothing but the index's own classification, where borrowing a real guard
#     would make this section's result contingent on that guard's corpus — and
#     it costs milliseconds instead of a corpus walk per arm, which matters
#     because this section runs the index FOUR times. It lives INSIDE the repo
#     because `gp_handle` prepends the guard's own path to its population and
#     `gp_render` refuses a path that does not resolve under the repo root.
_gfd_g="$_PLANT/test-zz-1179-guard.sh"
cat > "$REPO_ROOT/$_gfd_g" <<GUARD
#!/usr/bin/env bash
source "$REPO_ROOT/monitor/_guard_population.sh"
gp_population() { printf '%s\n' "monitor/guards-for-diff.sh"; }
gp_handle "\$@"
exit 0
GUARD
printf '%s\n' "$_gfd_g" > "$WORK/suites-1179.txt"

_U_DEL="$_PLANT/test-zz-1179-deleted.sh"
# `monitor/guards-for-diff.sh` is the TRACKED half — it is what selects the
# planted guard, so the run reaches a verdict in both arms and the two are
# comparable. Without it ARM 2 would select nothing and exit 3, which is a
# different code for a different reason and would prove nothing about blindness.
printf 'monitor/guards-for-diff.sh\n%s\n' "$_U_DEL" > "$WORK/changed-1179.txt"

# ARM 1 — the path EXISTS and is not in the index. This is a real #1054 blind
# spot and must still be reported as one.
printf '#!/usr/bin/env bash\n# planted untracked fixture\n' > "$REPO_ROOT/$_U_DEL"
dout=$(cd "$REPO_ROOT" && bash "$INDEX" --changed-files "$WORK/changed-1179.txt" \
        --suites-from "$WORK/suites-1179.txt" --run 2>&1); drc=$?
assert_contains "ARM 1 (file EXISTS, not in index): still named as untracked" "$dout" "UNTRACKED ("
assert_contains "ARM 1: …and the guard is still marked BLIND TO it" "$dout" "BLIND TO"
assert_contains "ARM 1: …and its green is downgraded" "$dout" "UNVERIFIED "
assert_eq       "ARM 1: …and --run exits 4 — the #1054 protection is intact" "$drc" "4"

# ARM 2 — the SAME path, same command, now absent from disk, exactly as a
# `git rm` leaves it. Existence is the only thing that changed.
rm -f "$REPO_ROOT/$_U_DEL"
dout=$(cd "$REPO_ROOT" && bash "$INDEX" --changed-files "$WORK/changed-1179.txt" \
        --suites-from "$WORK/suites-1179.txt" --run 2>&1); drc=$?
assert_not_contains "ARM 2 (same path, DELETED): no UNTRACKED section" "$dout" "UNTRACKED ("
assert_not_contains "ARM 2: …no guard is marked BLIND TO a path that is not there" "$dout" "BLIND TO"
assert_not_contains "ARM 2: …and no green is downgraded" "$dout" "UNVERIFIED "
assert_contains     "ARM 2: …the guard returns a real PASS" "$dout" "    PASS $_gfd_g"
assert_eq           "ARM 2: …and --run exits 0 — a state the author can actually reach" "$drc" "0"

# ===========================================================================
# 5. FAIL-CLOSED: a guard the index cannot ASK is a REFUSAL, never a silent
#    exclusion. This is the assertion that separates this index from one that
#    quietly under-covers: a broken guard and an inapplicable guard produce the
#    same "not selected" line, and only one of them is an answer.
# ===========================================================================
echo "=== 5. a guard whose probe fails makes the whole index REFUSE ==="
mkdir -p "$WORK/plant"
cat > "$WORK/plant/test-broken-guard.sh" <<'EOF'
#!/usr/bin/env bash
# A guard that DECLARES the protocol — both discovery tokens present — and
# cannot answer it: it never sources the library, so `gp_handle` is not a
# command and the probe dies rc 127. The realistic shape of a half-enrolment.
gp_population() { printf 'monitor/ng
'; }
gp_handle "$@"
EOF
printf '%s\n' "$WORK/plant/test-broken-guard.sh" > "$WORK/suites-broken.txt"
out=$(cd "$REPO_ROOT" && bash "$INDEX" --changed-files "$WORK/changed-ng.txt" \
        --suites-from "$WORK/suites-broken.txt" 2>&1); rc=$?
assert_rc "an unanswerable guard is exit 2 REFUSED, not a quiet exclusion" "$rc" 2
assert_contains "…and the refusal names the guard it could not ask" \
    "$out" "test-broken-guard.sh"
assert_contains "…and says why silence would be worse than refusing" \
    "$out" "looks exactly like a guard that"
# The rc in that diagnostic must be the PROBE's, not the negated condition's.
# `$?` read inside an `if ! cmd; then` block is 0 or 1 whatever the command
# did — and 124 (timeout) is precisely the case where the number IS the
# diagnosis. The plant dies rc 127 (`gp_handle` is not a command).
assert_contains "…and reports the probe's REAL exit code, not the negated condition's" \
    "$out" "failed (rc 127)"

# The control for 5: the SAME seam with a working guard must select normally.
# Without it, the refusal above could be the seam being broken rather than the
# probe.
printf '%s\n' "monitor/watcher/test-ambient-shell-option-scope.sh" > "$WORK/suites-ok.txt"
out=$(cd "$REPO_ROOT" && bash "$INDEX" --changed-files "$WORK/changed-ng.txt" \
        --suites-from "$WORK/suites-ok.txt" 2>&1); rc=$?
assert_rc "the same seam with a WORKING guard selects (rc 0) — the refusal above is the probe, not the seam" \
    "$rc" 0

# ===========================================================================
# 6. THE PROTOCOL'S OWN REFUSALS, tested at the library rather than through
#    the index. Each of these is a way a guard can answer WRONGLY while looking
#    like it answered, and each one, unfixed, produces a confident exclusion.
# ===========================================================================
echo "=== 6. the protocol refuses an empty, an absent and an unimplemented population ==="
_gp_case() {   # <body> -> sets GPOUT / GPRC
    cat > "$WORK/case.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
GP_REPO_ROOT="$REPO_ROOT"
# Explicitly EMPTY: this fixture lives outside the repo, and what is under test
# is the guard's own declaration, not the self-path convenience.
GP_SELF=
. "$PROTO"
$1
gp_handle "\$@"
echo "SUITE-BODY-RAN"
EOF
    GPOUT=$(bash "$WORK/case.sh" --population 2>&1); GPRC=$?
}

_gp_case 'gp_population() { printf "monitor/ng\n"; }'
assert_rc "a valid declaration answers rc 0" "$GPRC" 0
assert_contains "…and emits the path" "$GPOUT" "monitor/ng"
assert_not_contains "…and the suite body does NOT run — a probe is not a test run" \
    "$GPOUT" "SUITE-BODY-RAN"

_gp_case 'gp_population() { :; }'
assert_rc "an EMPTY population is refused (rc 3), never reported as 'reads nothing of yours'" \
    "$GPRC" 3
assert_contains "…and the refusal says the two are indistinguishable downstream" \
    "$GPOUT" "is EMPTY"

_gp_case 'gp_population() { printf "monitor/no-such-file-anywhere.sh\n"; }'
assert_rc "a population naming a path that does not exist is refused (rc 3)" "$GPRC" 3
assert_contains "…and names the rotted path" "$GPOUT" "no-such-file-anywhere.sh"

_gp_case 'gp_population() { return 7; }'
assert_rc "an enumerator that FAILS is refused, not read as an empty answer" "$GPRC" 3
assert_contains "…and reports the enumerator's own rc" "$GPOUT" "rc 7"

_gp_case ':'
assert_rc "declaring the protocol without implementing it is refused (rc 3)" "$GPRC" 3
assert_contains "…and says which half is missing" "$GPOUT" "implements no gp_population"

# ── SPELLING: A ROW MUST BE THE STRING GIT EMITS (your-org/nexus-code#1218) ──
# `gp_render` validated rows against the FILESYSTEM's vocabulary (`[[ -e ]]`,
# "does this resolve?") while the consumer intersects them with GIT's ("is this
# the string `git diff --name-only` emits?"). Every spelling in the gap names a
# real file, passes every check, and can never be intersected with a diff — the
# quietest failure available, because the population NAMES the file and the
# report stays full and truthful.
#
# `#1197` closed ONE member with `case "$line" in /*/../*|/*/..)` — a denylist
# of noticed spellings with a permissive default arm. One control per row of
# #1218's table, so the remaining three cannot regress silently, plus the
# already-fixed absolute form as a non-regression.
#
# THESE CONTROLS EXERCISE THE BROKEN PATH ON PURPOSE. Measured over all 25
# enrolled guards, canonicalisation changed ZERO populations — the healthy tree
# is a no-op, exactly as #1226 warns, so a test that only ran the healthy path
# would certify something free.
for _spell in \
    'monitor/watcher/../ng:relative ..' \
    './monitor/ng:leading ./' \
    'monitor//ng:doubled /' \
    '$GP_REPO_ROOT/monitor/watcher/../ng:absolute .. (#1197)'
do
    _p="${_spell%%:*}"; _d="${_spell#*:}"
    _gp_case "gp_population() { printf '%s\\n' \"$_p\"; }"
    assert_rc "SPELLING [$_d] is accepted, not refused" "$GPRC" 0
    assert_contains "SPELLING [$_d] renders as git's own spelling" "$GPOUT" "monitor/ng"
    # The row must be EXACTLY `monitor/ng`. `assert_contains` alone would pass on
    # the unusable spelling too, since it CONTAINS the canonical one as a
    # substring — which is how this class survives a careless control.
    assert_eq "SPELLING [$_d] emits no unmatchable variant" \
        "$(printf '%s\n' "$GPOUT" | grep -cE '(^\./)|(//)|(/\.\./)' || true)" "0"
done

# ── UNTRACKED TEXT BUDGET (your-org/nexus-code#1254) ────────────────────────
# The probe used to be O(untracked TEXT bytes) with NO budget: at roughly 25 GB
# it exhausts guards-for-diff's 180 s probe budget and the tool exits 2 with
# nothing named. The bound is exercised here rather than merely installed
# (`#965`: an untested ceiling is machinery whose failure path nobody has ever
# reached), and BOTH directions matter.
_budget_tree() {   # <dir> — a scratch repo with an untracked payload
    rm -rf "$1"; mkdir -p "$1"; ( cd "$1" && git init -q . \
        && git config user.email t@t && git config user.name t \
        && echo x > tracked.txt && git add -A && git commit -qm base ) >/dev/null 2>&1
}
_BT="$WORK/budget"; _budget_tree "$_BT"
head -c 2000000 /dev/urandom | base64 > "$_BT/bulk.txt"          # ~2.7 MB of TEXT
head -c 8000000 /dev/zero                > "$_BT/blob.bin"        # 8 MB of BINARY

# OVER budget on TEXT -> refuse, fast, and NAME the offender.
_bo=$( GP_UNTRACKED_TEXT_BUDGET_BYTES=1000000 bash -c \
        '. "$1"; gp_untracked_matching "$2" "assert_contains"' _ "$PROTO" "$_BT" 2>&1 ); _brc=$?
assert_rc "an over-budget untracked TEXT tree is REFUSED, not silently truncated" "$_brc" 3
assert_contains "…and the refusal names the budget" "$_bo" "UNTRACKED TEXT BUDGET EXCEEDED"

# THE DIRECTION THAT MUST NOT FIRE. A TOTAL-bytes bound would refuse the
# operator's real tree — 42.6 GB of which 41.5 GB is ten `.h5ad` files — which
# is precisely the tree `#1223`'s `-I` already handles in ~16 s. Bounding the
# wrong quantity would be a regression wearing a bound's clothes, so the binary
# payload here is 8x the budget and must pass.
_bo2=$( GP_UNTRACKED_TEXT_BUDGET_BYTES=1000000 bash -c \
        '. "$1"; gp_untracked_matching "$2" "assert_contains"' _ "$PROTO" "$_BT/../nonexistent-x" 2>&1 ) || true
rm -f "$_BT/bulk.txt"
_bo3=$( GP_UNTRACKED_TEXT_BUDGET_BYTES=1000000 bash -c \
        '. "$1"; gp_untracked_matching "$2" "assert_contains"' _ "$PROTO" "$_BT" 2>&1 ); _brc3=$?
assert_rc "a BINARY payload 8x over the budget does NOT refuse — the bound is on TEXT" "$_brc3" 0

# THE REFUSAL MUST SURVIVE A PIPELINE, which is the only reason it is in-band.
# Both production callers wrap the helper in a brace group and pipe it, so a
# pipeline's exit status is `sort -u`'s and an rc-only refusal is DESTROYED.
# Measured before the sentinel: diagnostic printed, probe exited 0, population
# silently narrowed.
head -c 2000000 /dev/urandom | base64 > "$_BT/bulk.txt"
_piped=$( GP_UNTRACKED_TEXT_BUDGET_BYTES=1000000 bash -c \
        '. "$1"; { gp_untracked_matching "$2" "assert_contains"; } | sort -u' _ "$PROTO" "$_BT" 2>/dev/null )
assert_contains "the budget refusal travels IN-BAND, so a pipeline cannot discard it" \
    "$_piped" "GP_REFUSAL"
_gp_case "gp_population() { printf '%s\\n' \"\$(printf '\\x01')GP_REFUSAL\$(printf '\\x01') planted\"; }"
assert_rc "gp_render fails CLOSED on an in-band refusal marker" "$GPRC" 3
assert_contains "…and says an enumerator refused, not that the population was empty" \
    "$GPOUT" "an enumerator REFUSED"

# The no-flag control: sourcing the protocol must not change what a suite does
# when it is run normally. If it did, enrolling a guard would be a behaviour
# change and nobody would enrol one.
_gp_case 'gp_population() { printf "monitor/ng\n"; }'
GPOUT=$(bash "$WORK/case.sh" 2>&1); GPRC=$?
assert_rc "without --population the suite runs normally (rc 0)" "$GPRC" 0
assert_contains "…and its body DOES run — gp_handle is inert off the flag" \
    "$GPOUT" "SUITE-BODY-RAN"

# ===========================================================================
# 6b. THE SHARED UNTRACKED SCAN, AND THE TWO THINGS gp_render NOW SUPPLIES
#     (your-org/nexus-code#1197).
# ===========================================================================
echo "=== 6b. the shared untracked scan, and what gp_render supplies for free (#1197) ==="

# --- the declared narrowing, pinned as DATA rather than argued in a comment ---
#
# `gp_untracked_matching` scans with `grep -I`, which decides a file is binary
# from its FIRST BUFFER and stops. That is what bounds the cost — measured on
# the operator nexus's 4,374-file untracked tree with the guards' real regex,
# each arm under a 300 s bound: per-file loop >300 s, xargs batch without `-I`
# >300 s, xargs batch WITH `-I` 21 s. Ten `.h5ad` files are 41.5 GB of the
# 42.6 GB total, and `-I` reads one buffer of each instead of all of it.
#
# It is a REAL NARROWING, not a free speed-up: a file whose first buffer holds
# a NUL is skipped even though its later bytes match. Both arms below are
# therefore required. The first says the scan still works; the second says
# exactly what it stopped seeing. The trade — these guards EXTRACT the matched
# definition and EXECUTE it as bash, so a NUL-bearing file could never have
# contributed one — is argued in the library, and this is where it is checked,
# so the day someone disagrees with it they find it as an assertion.
_needle='zzz_1197_fixture_needle'
printf '%s\n' "$_needle"            > "$REPO_ROOT/$_PLANT/enc-plain.txt"
printf '\000binary\n%s\n' "$_needle" > "$REPO_ROOT/$_PLANT/enc-binary.bin"
_uhits=$(gp_untracked_matching "$REPO_ROOT" "$_needle")
assert_eq "a matching UNTRACKED TEXT file IS found by the shared scan" \
    "$(_gp_has "$_uhits" "$_PLANT/enc-plain.txt")" "yes"
assert_eq "…and a matching file carrying a NUL is SKIPPED — the narrowing -I buys, as data" \
    "$(_gp_has "$_uhits" "$_PLANT/enc-binary.bin")" "no"
# NON-VACUITY: without the first arm the second is satisfied by a scan that
# finds nothing at all, which is the silent-zero shape this whole file is about.
assert_eq "…and the scan is not simply empty (the non-vacuity half)" \
    "$( [[ -n "${_uhits//[[:space:]]/}" ]] && echo yes || echo no )" "yes"
rm -f "$REPO_ROOT/$_PLANT/enc-plain.txt" "$REPO_ROOT/$_PLANT/enc-binary.bin"

# --- gp_render supplies the protocol library, canonically ------------------
#
# Every declaring guard sources this library, so an edit to it can change any
# of their verdicts — and at 50c36efc7ef3 only 7 of 23 enrolled guards had it
# in their declared population, all but one of those incidentally (they sweep
# every shell file under monitor/ and pick it up as corpus). It is added by the
# protocol now, for the same reason the suite's own path is: a dependency every
# guard has BY CONSTRUCTION must not be one each guard has to remember.
_gp_case 'gp_population() { printf "monitor/ng\n"; }'
assert_rc "a guard that declares only monitor/ng still answers rc 0" "$GPRC" 0
assert_contains "…and gp_render supplies the protocol library it sources, undeclared" \
    "$GPOUT" "monitor/_guard_population.sh"

# BEING ABSOLUTE IS NOT BEING CANONICAL. Guards source this library as
# `"$_test_dir/../_guard_population.sh"` — absolute, and carrying a `..`.
# Rendered as spelled that is `monitor/watcher/../_guard_population.sh`, a path
# which EXISTS (so the rot check waves it through) and which `git diff` never
# produces (so `guards-for-diff`'s intersection can never match it). The
# population would NAME the file and still fail to select on it.
# test-knob-default-agrees.sh declares exactly that path on purpose and was
# measured emitting the unusable spelling.
_gp_case 'gp_population() { printf "%s\n" "$GP_REPO_ROOT/monitor/watcher/../_guard_population.sh"; }'
assert_rc "a declared path containing .. is rendered, not refused" "$GPRC" 0
assert_contains "…canonicalised to the spelling git actually produces" \
    "$GPOUT" "monitor/_guard_population.sh"
assert_not_contains "…and NOT the ../ spelling, which exists and can never be matched" \
    "$GPOUT" "watcher/../"

# ===========================================================================
# --timeout AND ITS EXIT 5 (your-org/nexus-code#965, #1135 skeptic)
# ===========================================================================
#
# WHY THIS EXISTS AT ALL, because its absence was the finding. `--timeout` and
# exit 5 shipped with NO caller and NO assertion: no suite in the corpus
# contained "NO VERDICT", "NOT FINISHED" or a check for rc 5. The consequence
# is worse than a coverage gap — every mutation of that code left the corpus
# GREEN BY CONSTRUCTION, so the mutation testing that appeared to validate the
# #965 fix validated nothing about it. A remedy with no reachable invocation
# and no assertion is indistinguishable from one that does not work.
echo "=== --timeout: a budget-truncated --run is not a clean one ==="

# INSIDE THE REPO, not $TMPDIR, and this is a real constraint rather than
# tidiness: `gp_handle` prepends the guard's OWN path to its declared
# population and REFUSES (rc 3) when a declared path does not resolve under
# the repo root. A guard planted in /tmp therefore cannot answer --population
# at all, and `guards-for-diff` exits 2 REFUSED before any of these assertions
# reaches the code it is about. The first cut of this section did exactly
# that: rc 2 where 5 was expected, and a "-k grace" check that PASSED in 0s
# because the guard never ran — a green from a probe that never reached its
# subject, which is the failure mode this whole branch is about.
_gfd_t=$(mktemp -d "$REPO_ROOT/.gfd-timeout-XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
# No `trap` here. The single EXIT handler installed at the top of this file
# already names $_gfd_t; re-installing one would REPLACE that handler and
# orphan $WORK and the planted fixture, which is the bug this consolidation
# removed.
_mk_guard(){ # $1 = name, $2 = body
    cat > "$_gfd_t/test-$1.sh" <<GUARD
#!/usr/bin/env bash
source "$REPO_ROOT/monitor/_guard_population.sh"
gp_population() { printf '%s\n' "monitor/guards-for-diff.sh"; }
gp_handle "\$@"
$2
GUARD
    chmod +x "$_gfd_t/test-$1.sh"
}
_mk_guard slow 'sleep 30'
# 90, NOT 30, AND THE NUMBER IS THE ASSERTION. With `sleep 30` and a
# threshold of 30 the bounded case (~18 s) and the UNBOUNDED case (~30 s) both
# satisfied `<= 30`, so this check had NO DISCRIMINATING POWER: removing the
# `-k` it exists to protect left the suite 100/0 with the edit proven applied.
# A test whose fixture duration equals its own threshold is green by
# construction — which is the exact finding (#965's untested remedy) that
# caused this section to be written, reproduced inside it.
# Now: bounded ~18 s (3 budget + 15 grace), unbounded ~90 s, threshold 45.
_mk_guard term 'trap "" TERM; sleep 90'
_mk_guard fast 'exit 0'
printf '%s\n' "monitor/guards-for-diff.sh" > "$_gfd_t/changed"

# A guard that outlives the budget: exit 5, NOT a pass and NOT a FAIL.
printf '%s\n' "$_gfd_t/test-slow.sh" > "$_gfd_t/suites"
TOUT=$(cd "$REPO_ROOT" && timeout 90 bash "$INDEX" --changed-files "$_gfd_t/changed" \
        --suites-from "$_gfd_t/suites" --run --timeout 3 2>&1); TRC=$?
assert_rc      "a guard that outlives --timeout exits 5, not 0 and not 1" "$TRC" 5
assert_contains "…the guard is reported NOT FINISHED, never FAIL" "$TOUT" "NOT FINISHED"
assert_contains "…and named as returning NO VERDICT"              "$TOUT" "NO VERDICT"
assert_contains "…with the reconciliation line saying how far it got" "$TOUT" "reached 0 of 1"

# `-k`: a guard that IGNORES TERM must still be bounded (#1135 skeptic F2).
# Without `-k` this took 40s under `--timeout 5` while the help promised a
# bound — the #1041 item 6 defect in the other file.
printf '%s\n' "$_gfd_t/test-term.sh" > "$_gfd_t/suites"
_t0=$SECONDS
# The outer bound must OUTLIVE the unbounded case (~90 s) or it truncates the
# very measurement being made and the check passes for the wrong reason.
TOUT=$(cd "$REPO_ROOT" && timeout 200 bash "$INDEX" --changed-files "$_gfd_t/changed" \
        --suites-from "$_gfd_t/suites" --run --timeout 3 2>&1); TRC=$?
_elapsed=$(( SECONDS - _t0 ))
assert_rc "a TERM-IGNORING guard is still bounded, and exits 5" "$TRC" 5
# 45 sits between the two outcomes, not on top of one of them.
if (( _elapsed <= 45 )); then
    _th_pass; printf '  PASS: …killed via the -k grace (%ds; unbounded it would run its full 90s sleep)\n' "$_elapsed"
else
    _th_fail; printf '  FAIL: a TERM-ignoring guard ran %ds — --timeout is not a bound (#1135 F2)\n' "$_elapsed" >&2
fi

# THE CONTROL THAT MAKES THE ABOVE MEAN SOMETHING: an ample budget must NOT
# manufacture a timeout. Without this, "exits 5" is satisfied by a tool that
# always exits 5.
printf '%s\n' "$_gfd_t/test-fast.sh" > "$_gfd_t/suites"
TOUT=$(cd "$REPO_ROOT" && timeout 90 bash "$INDEX" --changed-files "$_gfd_t/changed" \
        --suites-from "$_gfd_t/suites" --run --timeout 60 2>&1); TRC=$?
assert_rc      "an ample --timeout does NOT manufacture a truncation" "$TRC" 0
assert_contains "…and the guard reports PASS"        "$TOUT" "PASS"
assert_contains "…with a full reconciliation line"   "$TOUT" "reached 1 of 1"

# A valueless --timeout is EX_USAGE, matching #990's unification.
(cd "$REPO_ROOT" && timeout 20 bash "$INDEX" --run --timeout >/dev/null 2>&1); TRC=$?
assert_rc "a valueless --timeout is EX_USAGE 64 (#990)" "$TRC" 64

th_summary_and_exit
