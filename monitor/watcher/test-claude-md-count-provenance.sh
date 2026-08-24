#!/usr/bin/env bash
# Executes the count-provenance forms CLAUDE.md documents, against a
# purpose-built two-ref fixture repo.
#
# Run: bash monitor/watcher/test-claude-md-count-provenance.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS SUITE EXISTS. A count is a property of a TREE, and the most
# natural counting commands answer about your CHECKOUT rather than about a
# ref. `git ls-files`, `find`, `wc -l` over a glob, `grep -c` — all of them
# read the index or the working tree. So "N files at <ref>" is true only
# when your checkout IS <ref>, and a worker on a feature branch, or with one
# extra file added since, reports a number that is off by exactly that and
# looks entirely plausible. Nothing errors at any step.
#
# It is the sibling of the ancestor-timeline entry: that one is about reading
# a SERIES across refs as history, this one about asserting a SINGLE count
# ABOUT a ref you did not measure.
#
# WHAT IS ACTUALLY PINNED. Not "git behaves". The CLAIM the block makes —
# that the two documented forms answer DIFFERENT questions, and disagree by
# exactly the tree difference — executed against a fixture whose true content
# is known by construction, so the expectation never comes from the thing
# under test.
#
# NON-VACUITY CONTROLS, because "the commands ran" proves nothing:
#   A — the extracted form count is PINNED at 3. A botched extraction
#       yielding zero forms would otherwise satisfy every assertion by having
#       none to make, which is `#618`'s own shape.
#   B — the POSITIVE control. At the ref that IS the checkout, the two forms
#       must AGREE. Without it, a ref-form that always returned a smaller
#       number would satisfy the disagreement assertion and prove nothing.
#   C — the DECOY control. A file matching neither predicate is counted by
#       neither, so the numbers below are not just "how many files exist".
#   D — the wrong reading EXITS 0. The defect is not that it fails; it is
#       that it succeeds while measuring a different tree than it claims.
#
# COVERAGE BOUNDARY, on the axis the mechanism varies on: this pins GIT's
# index-versus-tree distinction, a property of the git BINARY. NOT covered:
# counts taken by non-git tools (`find`, `rg`) — they share the hazard
# (they read the worktree) but not the remedy, since there is no `<ref>` to
# pass them; the block's answer for those is to check out the ref first, and
# that is prose here rather than an executed form.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

WORK=$(mktemp -d -t nexus-countprov-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---- extract the documented block ---------------------------------------
echo '=== Extraction: pull the delimited block out of CLAUDE.md ==='
BEGIN_MARK='<!-- BEGIN COUNT-PROVENANCE -->'
END_MARK='<!-- END COUNT-PROVENANCE -->'

[[ -r "$CLAUDE_MD" ]] || th_abort "CLAUDE.md not readable at $CLAUDE_MD"
assert_file_exists "CLAUDE.md is readable" "$CLAUDE_MD"

FORMS=$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    index($0, b) { inb = 1; next }
    index($0, e) { inb = 0 }
    inb' "$CLAUDE_MD" \
    | sed -E 's/^[[:space:]]+//' \
    | grep -vE '^```' \
    | sed -E 's/[[:space:]]{2,}#.*$//' \
    | grep -E '^git ')

# CONTROL A — pin the count. Under bash explicitly: this suite's interactive
# caller is zsh, where a `mapfile`-style read fails as an EMPTY ARRAY and a
# zero population reads as "everything passed".
n_forms=$(printf '%s\n' "$FORMS" | grep -c '^git ' || true)
assert_eq "extracted exactly 3 documented forms" "$n_forms" "3"
if (( n_forms != 3 )); then
    th_abort "extraction produced $n_forms form(s); refusing to draw conclusions from it"
fi
CHECKOUT_FORM=$(printf '%s\n' "$FORMS" | grep -F 'ls-files'  | head -1)
REF_FORM=$(printf '%s\n'      "$FORMS" | grep -F 'ls-tree'   | head -1)
SHA_FORM=$(printf '%s\n'      "$FORMS" | grep -F 'rev-parse' | head -1)
assert_contains "form 1 counts the CHECKOUT (ls-files)"   "$CHECKOUT_FORM" "ls-files"
assert_contains "form 2 counts a REF (ls-tree, filtered)" "$REF_FORM"      'name-only "${ref}"'
assert_contains "form 3 reports the ref beside the count" "$SHA_FORM"      "rev-parse"

# ---- build the fixture ---------------------------------------------------
# Two refs, one repo, differing by exactly ONE matching file:
#
#     OLD  ── NEW            OLD: test-a, test-b        (2 matching)
#                            NEW: test-a, test-b, test-c (3 matching)
#
# `notes.md` exists on both and matches NEITHER predicate — CONTROL C, so the
# numbers below are a property of the predicate, not just of file existence.
echo
echo '=== Fixture: two refs differing by exactly one matching file ==='
FIX="$WORK/repo"
mkdir -p "$FIX/monitor" || th_abort "fixture mkdir failed"
(
    set -e
    cd "$FIX"
    git init -q .
    git config user.email t@example.invalid
    git config user.name  t
    git config commit.gpgsign false
    printf 'x\n' > monitor/test-a.sh
    printf 'x\n' > monitor/test-b.sh
    printf 'x\n' > monitor/notes.md
    git add -A && git commit -qm old
    printf 'x\n' > monitor/test-c.sh
    git add -A && git commit -qm new
) >/dev/null 2>&1 || th_abort "fixture repo construction failed"

OLD=$(git -C "$FIX" rev-parse HEAD~1)
NEW=$(git -C "$FIX" rev-parse HEAD)
for v in OLD NEW; do
    [[ "${!v}" =~ ^[0-9a-f]{7,}$ ]] || th_abort "fixture ref $v did not resolve"
done
# The checkout is NEW. That is the whole setup: a worker sitting on one tree
# while reporting a number "about" another.

# ---- run the documented forms verbatim -----------------------------------
echo
echo '=== The documented forms, run verbatim from the block ==='
# Sets `_FORM_OUT` and RETURNS the form's rc. Deliberately not
# `out=$(_run_form …)`: command substitution runs the function in a SUBSHELL,
# so an rc stashed in a global there never reaches the caller — the assignment
# silently reads the parent's stale value, or trips `set -u`. Both counts and
# their exit statuses are load-bearing here, so the two travel separately.
_FORM_OUT=""
_run_form() {   # $1 form · $2 ref → sets _FORM_OUT, returns the form's rc
    _FORM_OUT=$(ref="${2:-}" FORM="$1" bash -c '
        cd "$0" || exit 99
        eval "$FORM"
    ' "$FIX" 2>/dev/null)
    return $?
}

_run_form "$CHECKOUT_FORM";    rc_checkout=$?; checkout_n=$_FORM_OUT
_run_form "$REF_FORM" "$OLD";  rc_old=$?;      old_n=$_FORM_OUT
_run_form "$REF_FORM" "$NEW";  rc_new=$?;      new_n=$_FORM_OUT

assert_eq "ls-files counts the CHECKOUT (NEW): 3" "$(printf '%s' "$checkout_n" | tr -d '[:space:]')" "3"
assert_eq "ls-tree at OLD counts THAT ref: 2"     "$(printf '%s' "$old_n"      | tr -d '[:space:]')" "2"
# CONTROL B — the POSITIVE control. At the ref that IS the checkout the two
# forms must agree, or the disagreement below proves nothing about refs.
assert_eq "ls-tree at NEW agrees with the checkout count: 3" \
    "$(printf '%s' "$new_n" | tr -d '[:space:]')" "3"

# THE CLAIM ITSELF: a bare number does not identify a tree.
#
# BOTH SIDES ARE REQUIRED TO BE NUMERIC, and that is not pedantry — it is a
# vacuity hole this assertion actually had. A mutated block whose ref-form no
# longer matches the extractor yields an EMPTY string, and `'' != '3'` is
# perfectly true, so the bare inequality reported `differ` and PASSED while
# measuring nothing at all. "Two values are unequal" is worthless unless both
# are values. Same shape as everything else in this file.
_o=$(printf '%s' "$old_n"      | tr -d '[:space:]')
_c=$(printf '%s' "$checkout_n" | tr -d '[:space:]')
assert_eq "the same predicate yields DIFFERENT counts on the two refs" \
    "$( [[ "$_o" =~ ^[0-9]+$ && "$_c" =~ ^[0-9]+$ && "$_o" != "$_c" ]] && echo differ || echo same )" \
    "differ"

# CONTROL D — it SUCCEEDS while measuring a different tree than claimed.
# Reporting `2` "at NEW", or `3` "at OLD", is a clean exit 0 either way.
assert_eq "every documented form exited 0 despite disagreeing" \
    "${rc_checkout}${rc_old}${rc_new}" "000"

# CONTROL C — the decoy. `notes.md` is on both refs and counted by neither,
# so these numbers measure the predicate, not the size of the tree.
total_old=$(git -C "$FIX" ls-tree -r --name-only "$OLD" | grep -c . || true)
assert_eq "OLD holds 3 files total but only 2 match — the decoy is excluded" \
    "$total_old" "3"

# The third form: the sha that must be reported beside the number.
_run_form "$SHA_FORM" "$OLD"; sha=$_FORM_OUT
assert_eq "rev-parse --short resolves the ref that scopes the count" \
    "$( [[ "$OLD" == "${sha}"* && -n "$sha" ]] && echo yes || echo no )" "yes"

# EXPECTED-COUNT GUARD (your-org/nexus-code#807; required by
# test-summary-honesty-manifest.sh at the `ledger=yes` protection level).
# Every assertion above is unconditional — this suite has no skipping arm —
# so this is a literal constant.
#   1  CLAUDE.md readable
# + 4  extraction (count pinned at 3, plus the three form assertions)
# + 3  the three counts
# + 1  the claim: the counts differ across refs
# + 1  the forms all exit 0 while disagreeing
# + 1  the decoy is excluded
# + 1  rev-parse resolves the scoping ref
EXPECTED=12
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
