#!/usr/bin/env bash
# Executes the `guards-for-diff` pointer CLAUDE.md documents
# (your-org/nexus-code#834, a #803 follow-up), against this repo's own tree.
#
# Run: bash monitor/watcher/test-claude-md-guards-for-diff.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS SUITE EXISTS. `#803` shipped a reverse index — "which guards READ
# the files I just changed?" — and `#834` observed that the index was itself
# as undiscoverable as the guards it indexes: reachable as `ng guards-for-diff`
# and in `ng --help`, mentioned nowhere in the file auto-loaded into every
# agent's context. The remedy is a CLAUDE.md bullet. But a POINTER is prose,
# and prose cannot be made to fail: the verb can be renamed, the exit-code
# contract can shift, and the bullet keeps reading plausibly either way. So the
# bullet's load-bearing claims are extracted and EXECUTED here, on the same
# contract as the #618-remedies, LSTREE-PATHSPEC and ANCESTOR-TIMELINE blocks —
# a documented form that stops behaving as documented turns this suite red
# rather than quietly misinforming the next reader.
#
# THE CLAIMS UNDER TEST (each is a sentence in the bullet, not a paraphrase):
#   1. The documented spelling dispatches.   `monitor/ng guards-for-diff` — via
#      `ng`, because that is what the bullet tells a reader to type. A verb that
#      still works as `bash monitor/guards-for-diff.sh` but was dropped from
#      `ng`'s dispatch table would leave the bullet false and this suite red,
#      which is the correct polarity.
#   2. `--run` is accepted.
#   3. Exit 3 means NO registered guard reads your diff — "a measured answer,
#      not a green light".
#   4. Exit 3 still PRINTS the considered list, so "0 selected" is
#      distinguishable from "the index did not run". That conflation is this
#      repo's dominant defect class and the whole reason 3 is not 0.
#   5. Exit 2 means REFUSED (fail-closed).
#   6. It "prints that blind spot as a count on every run".
#   7. The bullet quotes NO enrolled-vs-tracked ratio. See ROT GUARD below.
#
# ROT GUARD (assertion 7) — the one claim about the DOC rather than the tool.
# `#834`'s own body quoted "291 of 297 today"; by the time the fix was written
# the tool reported a different pair against the same question. A ratio pinned
# in CLAUDE.md is therefore wrong on a timescale of about a day, and wrong in
# the confident direction — a reader who trusts it under-reads the blind spot.
# The bullet accordingly defers to the tool's own per-run line, and this
# assertion holds it to that. It fails if anyone re-introduces a literal.
#
# NON-VACUITY. "The commands ran" proves nothing on its own — a botched
# extraction yielding zero commands passes every assertion by having none to
# make (#618's own shape, reproduced inside #618's own remedy at #707). So:
#   Control A — the extracted command count is PINNED at 2.
#   Control B — the HIT case is checked against a population membership derived
#               INDEPENDENTLY of the tool, by asking the guard itself for its
#               `--population`. An expectation sourced from the thing under test
#               is measuring itself.
#   Control C — the MISS fixture is asserted to be genuinely absent from that
#               same independently-derived population, so exit 3 is a real
#               negative and not an artifact of a typo'd path.
#   Control D — exit 2 is provoked deliberately (a planted guard that errors on
#               its population probe), proving the fail-closed arm exists rather
#               than assuming it.
#
# COVERAGE BOUNDARY, on the axis the mechanism varies on. The mechanism here is
# the CLAUDE.md text ↔ `guards-for-diff` behaviour COUPLING, and that varies on
# edits to either side — so both sides are read from disk at run time and
# neither is transcribed into this file. What is NOT covered: which guards are
# enrolled (that is the tool's own `--population` protocol, guarded by
# test-guards-for-diff.sh), and whether the selection is CORRECT for a real git
# diff (this suite pins the exit-code contract and passes `--changed-files`, a
# documented first-class flag, so it never depends on `origin/dev` resolving —
# a CI checkout with a shallow fetch would otherwise red here for reasons that
# have nothing to do with the doc).
#
# NO `| head -N` AND NO `grep -q` IN A PIPELINE anywhere below, deliberately:
# both close the pipe early, the upstream takes SIGPIPE, and this file runs
# under `set -o pipefail` — the #622 class, which would put fresh rows into
# test-early-exit-reader-manifest.sh's pinned population. Counts are taken with
# `grep -c` and compared.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

# ── this suite DECLARES its own population (the --population protocol) ──
# Not optional bookkeeping — it is the honest resolution of a discovery
# ambiguity this file would otherwise create. Control D below plants a COMPLETE
# protocol fixture, so this file's bytes carry both discovery tokens
# (`gp_population()` and the literal `gp_handle "$@"` call) while only QUOTING
# them. `guards-for-diff.sh`'s header states that no text predicate can
# separate quoting from implementing — that would need a parse, and a
# heredoc-blind one is the defect this repo keeps re-learning — and prescribes
# the remedy: such a suite must ITSELF implement the protocol and declare in
# guard-populations.manifest. test-guards-for-diff.sh already does this for the
# same reason. Skipping it is LOUD, not silent (the probe runs the suite, no
# population comes back, and the index REFUSES) — which is how this was caught.
#
# The population is what this suite actually READS to reach a verdict, and
# every member can change its answer: the doc it pins, the tool whose exit-code
# contract it pins, the dispatcher the documented spelling goes through, the
# protocol library Control D's fixture sources, and the guard whose own
# --population supplies Controls B/C.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' \
        CLAUDE.md \
        monitor/guards-for-diff.sh \
        monitor/ng \
        monitor/_guard_population.sh \
        monitor/watcher/test-guards-for-diff.sh
}
gp_handle "$@"

. "$_test_dir/_test_helpers.sh"

# Every assertion helper this file calls must EXIST before any of them is
# called. An undefined `assert_*` is not a failing assertion — it is
# `command not found`, rc 127 under `set -uo pipefail` without `-e`, tallied by
# no counter, invisible in the footer. A suite can lose assertions this way and
# still print ALL TESTS PASSED. Fail here, loudly, instead.
for _th in assert_eq th_summary_and_exit; do
    declare -F "$_th" >/dev/null 2>&1 || {
        echo "FATAL: assertion helper '$_th' is not defined by _test_helpers.sh." >&2
        echo "       Every call to it would exit 127 and be counted by nothing." >&2
        exit 1
    }
done

# `yn <cond-rc>` renders a non-equality check as an assert_eq operand. There is
# no assert_gt in the shared helpers, and hand-rolling a local ok/bad pair would
# opt this suite out of the ledger (summary-honesty.manifest, ledger=no) — the
# exact standard this file is being added under.
yn() { (( $1 )) && echo yes || echo no; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cmgfd.XXXXXX") || { echo "mktemp -d failed" >&2; exit 1; }

# Control D plants a guard fixture INSIDE the repo (a relative suite path has to
# resolve from the repo root), so unlike $WORK it cannot be left behind: that
# fixture implements the discovery protocol and ERRORS on --population, so a
# leaked copy makes `guards-for-diff` REFUSE (exit 2) for everyone until someone
# deletes it. A control that poisons the index it is testing is worse than no
# control. The inline `rm` after Control D is the fast path; this is the one
# that holds when the suite does not reach it.
BROKEN_GUARD=""
cleanup() {
    rm -rf "$WORK" 2>/dev/null
    [[ -n "$BROKEN_GUARD" ]] && rm -f "$BROKEN_GUARD" 2>/dev/null
    return 0
}
trap cleanup EXIT
# An uncaught SIGINT/SIGTERM does NOT run the EXIT trap — same reasoning as
# test-channel-integration.sh's fixture sshd, and the same idiom.
#
# UNGUARDED, and measured to be so: Control E aborts with `exit 9`, which the
# EXIT trap alone handles, so removing this line changes no verdict in this file
# (checked: still 22/0). It is defence for a signal path the suite does not
# exercise — NOT a tested behaviour. Said out loud because the alternative is a
# line that reads as covered because it sits next to lines that are.
trap 'cleanup; trap - INT TERM EXIT; exit 130' INT TERM

# The guard used as the fixture universe: small (population ~10), already
# enrolled, and stable — `--suites-from` restricts consideration to it so this
# suite neither depends on the repo-wide enrolment count nor pays for probing
# every guard's population.
FIXTURE_GUARD='monitor/watcher/test-guards-for-diff.sh'

# ---- extract the documented forms from CLAUDE.md --------------------------
echo '=== Extraction: pull the delimited block out of CLAUDE.md ==='
BEGIN_MARK='<!-- BEGIN GUARDS-FOR-DIFF -->'
END_MARK='<!-- END GUARDS-FOR-DIFF -->'

assert_eq "CLAUDE.md is readable at $CLAUDE_MD" "$(yn "$([[ -r "$CLAUDE_MD" ]] && echo 1 || echo 0)")" "yes"
[[ -r "$CLAUDE_MD" ]] || th_summary_and_exit

FORMS=$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    index($0, b) { inb = 1; next }
    index($0, e) { inb = 0 }
    inb' "$CLAUDE_MD" \
    | sed -E 's/^[[:space:]]+//' \
    | grep -vE '^```' \
    | sed -E 's/[[:space:]]+#.*$//' \
    | sed -E 's/[[:space:]]+$//' \
    | grep -E '^monitor/ng guards-for-diff')

n_forms=$(printf '%s\n' "$FORMS" | grep -c '^monitor/ng guards-for-diff' || true)
# Control A — a botched extraction must not pass by having nothing to run.
assert_eq "Control A: exactly 2 ng forms extracted from CLAUDE.md" "$n_forms" "2"

plain_form=$(printf '%s\n' "$FORMS" | grep -vE -- '--run' || true)
run_form=$(printf   '%s\n' "$FORMS" | grep -E  -- '--run' || true)
assert_eq "the plain form is exactly 'monitor/ng guards-for-diff'" \
    "$plain_form" 'monitor/ng guards-for-diff'
assert_eq "the --run form is exactly 'monitor/ng guards-for-diff --run'" \
    "$run_form" 'monitor/ng guards-for-diff --run'

# Everything below EVALUATES the extracted forms. If extraction did not yield
# exactly the two expected commands, evaluating them would run something this
# suite never vetted — stop instead. The assertion-count guard at the foot is
# skipped on this path, which is correct: the suite is already red, and a count
# mismatch reported on top of a botched extraction would only obscure it.
(( FAIL > 0 )) && th_summary_and_exit

# ---- Controls B and C: an INDEPENDENTLY derived population ----------------
echo '=== Controls B/C: fixture paths checked against the guard own --population ==='
# Derived by asking the guard directly — not by asking guards-for-diff, which
# is the thing under test.
pop="$WORK/pop.txt"
(cd "$REPO_ROOT" && bash "$FIXTURE_GUARD" --population) > "$pop" 2>"$WORK/pop.err"
pop_rc=$?
assert_eq "the fixture guard answers --population (rc 0)" "$pop_rc" "0"
pop_n=$(grep -c . "$pop" || true)
assert_eq "the fixture guard declares a non-empty population (got $pop_n files)" \
    "$(yn "$(( pop_n > 0 ))")" "yes"
(( pop_rc == 0 && pop_n > 0 )) || th_summary_and_exit

HIT_PATH='monitor/guards-for-diff.sh'
MISS_PATH='docs/no-such-file-for-guards-for-diff-fixture.md'

hit_in=$(grep -cxF "$HIT_PATH" "$pop" || true)
miss_in=$(grep -cxF "$MISS_PATH" "$pop" || true)
# Control B — the HIT fixture really is in the population, per the guard itself.
assert_eq "Control B: HIT fixture is in the guard's own population" "$hit_in" "1"
# Control C — the MISS fixture really is absent, so exit 3 is a real negative.
assert_eq "Control C: MISS fixture is absent from that population" "$miss_in" "0"

printf '%s\n' "$FIXTURE_GUARD" > "$WORK/suites"
printf '%s\n' "$HIT_PATH"      > "$WORK/hit"
printf '%s\n' "$MISS_PATH"     > "$WORK/miss"

# ---- Claim 1: the documented spelling dispatches and SELECTS --------------
echo '=== Claims 1+2: the documented spelling dispatches; --run is accepted ==='
hit_out="$WORK/hit.out"
(cd "$REPO_ROOT" && eval "$plain_form" --suites-from "$WORK/suites" \
     --changed-files "$WORK/hit") > "$hit_out" 2>&1
hit_rc=$?
assert_eq "Claim 1: the documented form exits 0 when a guard reads your diff" "$hit_rc" "0"
sel_n=$(grep -cF "$FIXTURE_GUARD" "$hit_out" || true)
assert_eq "…and names the selecting guard in its output (see $hit_out)" \
    "$(yn "$(( sel_n > 0 ))")" "yes"

# `--run` on a MISS selects nothing, so nothing heavy is executed — but an
# UNKNOWN flag exits 2, so 3 here distinguishes "accepted" from "rejected".
run_out="$WORK/run.out"
(cd "$REPO_ROOT" && eval "$run_form" --suites-from "$WORK/suites" \
     --changed-files "$WORK/miss") > "$run_out" 2>&1
run_rc=$?
assert_eq "Claim 2: --run is an accepted flag (3 = nothing selected, not 2 = unknown arg)" \
    "$run_rc" "3"
unknown_n=$(grep -ci 'unknown argument' "$run_out" || true)
assert_eq "…and it was not rejected as an unknown argument" "$unknown_n" "0"

# ---- Claims 3+4: exit 3 is a measured answer, not silence -----------------
echo '=== Claims 3+4: exit 3 = none selected, and it still shows its work ==='
miss_out="$WORK/miss.out"
(cd "$REPO_ROOT" && eval "$plain_form" --suites-from "$WORK/suites" \
     --changed-files "$WORK/miss") > "$miss_out" 2>&1
miss_rc=$?
assert_eq "Claim 3: exit 3 when NO registered guard reads your diff" "$miss_rc" "3"
considered_n=$(grep -cF "$FIXTURE_GUARD" "$miss_out" || true)
# Without this, '0 selected' is indistinguishable from 'the index did not run'.
assert_eq "Claim 4: the CONSIDERED list is printed even when nothing is selected (see $miss_out)" \
    "$(yn "$(( considered_n > 0 ))")" "yes"

# ---- Claim 5: exit 2 = REFUSED, fail-closed -------------------------------
echo '=== Claim 5: a guard whose population probe errors REFUSES (exit 2) ==='
# Control D — provoke the fail-closed arm rather than assume it. The planted
# guard implements the discovery predicate (a `gp_population` definition plus
# the literal `gp_handle "$@"` call) so it IS discovered, then errors when
# asked. It lives under the repo so a relative suite path resolves.
broken_rel="monitor/watcher/.cmgfd-broken-guard.$$.sh"
broken_abs="$REPO_ROOT/$broken_rel"
# Armed BEFORE the file exists, so the trap covers the create itself — arming
# it after `cat` would leave a window that is exactly the bug being fixed.
#
# THAT ORDERING IS REASONED, NOT MEASURED, and this note exists because a
# comment claiming coverage it does not have is the exact defect this file was
# written to prevent. Control E's abort hook fires AFTER both the arming and the
# `cat`, so no assertion here distinguishes arm-before-create from
# arm-after-create (checked: moving this line below the heredoc still gives
# 22/0). Guarding it would need a second abort point inside the create window;
# judged not worth a test, but not worth an unqualified claim either.
BROKEN_GUARD="$broken_abs"
cat > "$broken_abs" <<'BROKEN'
#!/usr/bin/env bash
# Transient fixture planted by test-claude-md-guards-for-diff.sh (Control D).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../_guard_population.sh"
gp_population() { echo "deliberate population-probe failure" >&2; return 1; }
gp_handle "$@"
BROKEN
# Control E's abort hook (see below). Fires ONLY in the recursive self-probe,
# at the one instant that matters: fixture on disk, inline `rm` not yet reached.
if [[ -n "${CMGFD_SELF_ABORT:-}" ]]; then
    [[ -f "$broken_abs" ]] || { echo "self-probe: fixture absent, nothing to leak" >&2; exit 8; }
    exit 9
fi
printf '%s\n' "$broken_rel" > "$WORK/suites-broken"
broken_out="$WORK/broken.out"
(cd "$REPO_ROOT" && eval "$plain_form" --suites-from "$WORK/suites-broken" \
     --changed-files "$WORK/hit") > "$broken_out" 2>&1
broken_rc=$?
rm -f "$broken_abs"; BROKEN_GUARD=""
assert_eq "Claim 5: a guard that cannot answer its population REFUSES (exit 2)" \
    "$broken_rc" "2"

# ---- Control E: the cleanup trap actually covers the in-repo fixture ------
# This PR's thesis is that a documented behaviour must be EXECUTABLE or it
# rots. The fixture-leak fix is a behaviour of this file, so exempting it
# because it is "only four lines" would be the PR carving out an exception to
# its own rule — a shape this repo hit repeatedly the same night. It is guarded
# here instead.
#
# It cannot be asserted in-process: `cleanup` also removes $WORK, so calling it
# mid-suite would saw off the branch. So the probe re-invokes THIS FILE with the
# abort hook armed, which aborts with the fixture on disk and the inline `rm`
# unreached — the exact state the trap exists for — and then checks the tree.
#
# NON-VACUOUS BY CONSTRUCTION: rc 9 is asserted, not just the absence of
# residue. A self-probe that died early (rc 8 = fixture never planted, or any
# other code) would leave no residue either, and "no residue" alone would then
# pass while testing nothing. The residue check is only meaningful once rc 9
# says the abort fired at the right instant.
if [[ -z "${CMGFD_SELF_ABORT:-}" ]]; then
    echo '=== Control E: an abort between plant and rm must leave no fixture ==='
    CMGFD_SELF_ABORT=1 bash "${BASH_SOURCE[0]}" >/dev/null 2>&1
    _probe_rc=$?
    assert_eq "Control E: the self-probe aborted with the fixture planted (rc 9)" \
        "$_probe_rc" "9"
    _residue=$(find "$REPO_ROOT/monitor/watcher" -maxdepth 1 \
                   -name '.cmgfd-broken-guard.*.sh' 2>/dev/null | grep -c . || true)
    assert_eq "Control E: …and the trap removed it anyway (0 files left behind)" \
        "$_residue" "0"
fi

# ---- Claim 6: the blind spot is printed as a count, every run -------------
echo '=== Claim 6: every run prints the invisible-suite count ==='
# The bullet tells the reader to trust THIS line instead of any ratio in the
# doc. If the line disappears, the bullet's advice points at nothing.
for label in hit miss; do
    f="$WORK/$label.out"
    inv_n=$(grep -cE 'do not declare a population and are' "$f" || true)
    # If this line goes away, the bullet's advice points at nothing.
    assert_eq "the invisible-suite count line is present on the $label run (see $f)" \
        "$(yn "$(( inv_n > 0 ))")" "yes"
done

# ---- Claim 7: the ROT GUARD — no enrolment ratio pinned in the doc --------
echo '=== Claim 7: the CLAUDE.md bullet quotes no enrolled-vs-tracked ratio ==='
bullet="$WORK/bullet.txt"
# The bullet runs from its own list marker to the start of the next section.
awk '/^- \*\*Before you push a change under/ { inb = 1 }
     inb && /^## / { inb = 0 }
     inb' "$CLAUDE_MD" > "$bullet"
bullet_n=$(grep -c . "$bullet" || true)
# Without a located bullet the ratio check below has nothing to search and
# would pass by vacuity — the #618 shape this repo keeps re-deriving.
assert_eq "the guards-for-diff bullet was located ($bullet_n lines)" \
    "$(yn "$(( bullet_n > 0 ))")" "yes"

ratio_n=$(grep -cE '[0-9]+ of [0-9]+' "$bullet" || true)
assert_eq "Claim 7: no 'N of M' enrolment literal in the bullet (it would rot in a day)" \
    "$ratio_n" "0"

# ---- assertion-count guard ------------------------------------------------
# `th_summary_and_exit` reports the assertions that RAN. One that never ran is
# invisible to it: an undefined assert_* is `command not found`, rc 127, tallied
# nowhere, and the footer still says ALL TESTS PASSED with a quieter number.
# This suite has no conditional cases on the green path, so the count is exact.
# Bump it deliberately when adding a case; a DROP means a case stopped running.
_EXPECTED_ASSERTIONS=21
_ran=$(( PASS + FAIL ))
assert_eq "every declared assertion executed ($_EXPECTED_ASSERTIONS)" \
    "$_ran" "$_EXPECTED_ASSERTIONS"

th_summary_and_exit
