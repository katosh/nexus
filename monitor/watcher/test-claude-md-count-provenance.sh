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
#
# ── THE LOCATION ARM (your-org/nexus-code#1163) ──────────────────────────
#
# A LINE NUMBER IS A COUNT'S TWIN, and it is worse when stale. A stale count
# LOOKS wrong. A stale `path:line` points at DIFFERENT CODE THAT STILL PARSES,
# so the reader lands somewhere real, reads something coherent, and concludes
# the citation was about that. The originating instance: one construct sat at
# line 1036 at one ref and 1055 at another; both citations were correct about
# their own ref, neither carried a ref, so the pair read as a contradiction.
#
# It reuses THIS suite's instrument on purpose — the same two-ref fixture, one
# more tracked file, one more commit — because the amendment is to the same
# entry and the hazard has the same shape: a number that is a property of a
# tree, asserted about a tree nobody named.
#
# WHAT THE LOCATION ARM PINS. Three properties, and the second is the one the
# issue was filed for:
#   (i)   a line number MOVES between refs with no error, while the CONTENT at
#         it is byte-identical — which is what makes both citations true at once;
#   (ii)  THE DELTA CHECK IS VACUOUS. It is pinned POSITIVELY: the bad check
#         PASSES. Three sites all below the insertion point shift by the SAME
#         delta, so a delta-D reconciliation is satisfied by 3 of 3 candidates
#         and selects none — and the same two NUMBERS are delta-consistent for
#         a pairing of two DIFFERENT sites. Only the CONTENT at the line
#         narrows to 1 of 3. A suite that asserted only "the sound check works"
#         would be green while the documented hazard went unpinned;
#   (iii) a wrong PATH is the LESSER hazard because it is LOUD —
#         `git cat-file -e "${ref}:${path}"` refuses, where a wrong LINE in a
#         real file exits 0 and hands back plausible code.
#
# THE VACUITY IS STATED PRECISELY, because the obvious stronger claim is FALSE
# and a reader who expects it will think this arm is weak. Under a UNIFORM
# shift of D, the cross-ref pairs (old_i, new_j) satisfying `new_j - old_i == D`
# are EXACTLY the true pairs i == j: since new_j = old_j + D, a match forces
# old_i == old_j. So one cannot build a cross-ref delta-D pair naming two
# different sites — that is arithmetic, not a fixture shortcoming. The real
# vacuity, and what is asserted here, is the two facts above: a delta-D claim
# is satisfied by EVERY site, and a bare `path:line` carries no ref, so the
# SAME NUMBER names different constructs at the two refs and the delta
# "reconciles" whichever one the reader happened to open.
#
# WHAT ITS GREEN DOES NOT CERTIFY. Not that any citation in this repo is
# fresh — this is a fixture-local demonstration of a GIT property, not an audit
# of the corpus. Not that `grep -n` is the right locator for every construct;
# a multi-line construct, or one whose text repeats, is unpinned here. Not
# anything host-specific: measured with git 2.17.1, and the properties are the
# git object model's, not this machine's. And NOT the prose remedy's coverage —
# `git cat-file -e` is prose in the entry, not one of the two fenced forms, so
# its execution below is suite-side rather than block-verbatim, and a mutation
# to that prose would not turn this arm red.
#
# ADDITIONAL NON-VACUITY CONTROLS:
#   E — the location block's extracted form count is PINNED at 2, separately
#       from CONTROL A. An empty extraction aborts rather than passing by
#       having nothing to assert.
#   F — the POSITIVE control for this arm derives its expected line numbers by
#       a DIFFERENT mechanism than the one under test: `awk '/…/ {print NR}'`,
#       never the block's `grep -n`. Both are then checked against constants
#       known from the fixture's construction, so no expectation comes from
#       the thing being tested.
#   G — the pipeline-status control. The block's first form is a PIPELINE, so
#       its rc is `grep`'s and never `git show`'s: against a BOGUS path,
#       `git show` exits 128 and the pipeline still reports grep's 1 —
#       indistinguishable from "the path is fine, the construct is absent".
#       That is why the loud path check is `git cat-file -e`, not this form's rc.
#
# A ZSH HAZARD THIS BLOCK WALKS STRAIGHT INTO, recorded because the form is
# documented with `${path}` in it: in zsh `path` IS `$PATH` (a tied array), so
# supplying it as a shell variable — `path=monitor/x; git show "${ref}:${path}"`
# — DESTROYS `$PATH` at rc 0, and `git` is gone by the next command
# (your-org/nexus-code#945). It fired while this arm was being measured. Every
# form below is therefore run with `ref`/`path` as an ENV PREFIX to an explicit
# `bash -c`, where no tie exists; a zsh caller should rename the variable.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

# ── this suite DECLARES its own population (the --population protocol) ──────
# your-org/nexus-code#1219. CLAUDE.md is the document this suite EXECUTES, so
# an edit to the fenced block it pins is exactly the edit that can change its
# verdict — and until #1219 no such edit could SELECT it: a suite that declares
# no population is INVISIBLE to `guards-for-diff` rather than excluded by it
# (#1078), appearing in neither SELECTED nor CONSIDERED AND EXCLUDED, so its
# absence reads as a considered exclusion. `gp_handle` adds this suite's own
# path and `monitor/_guard_population.sh` for free; everything else is declared
# because this suite READS ITS BYTES to reach a verdict.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' \
        CLAUDE.md \
        monitor/watcher/_test_helpers.sh
}
gp_handle "$@"
th_claude_md_block_coverage COUNT-PROVENANCE LOCATION-PROVENANCE   # the entry's UNCHECKED share, in this suite's own output (#1239)

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
assert_eq "extracted exactly 4 documented forms" "$n_forms" "4"
if (( n_forms != 4 )); then
    th_abort "extraction produced $n_forms form(s); refusing to draw conclusions from it"
fi
CHECKOUT_FORM=$(printf '%s\n' "$FORMS" | grep -F 'ls-files'  | head -1)
REF_FORM=$(printf '%s\n'      "$FORMS" | grep -F 'ls-tree'   | head -1)
# Forms 3 and 4 are BOTH `rev-parse` and are selected on the flag that
# distinguishes them, never on position — a first-line read over a two-member set is a
# silent dependence on the block's line ORDER, which nothing asserts.
SHA_FORM=$(printf '%s\n'      "$FORMS" | grep -F 'rev-parse' | grep -F -- '--short' | head -1)
FULL_SHA_FORM=$(printf '%s\n' "$FORMS" | grep -F 'rev-parse' | grep -vF -- '--short' | sed -n '1p')
assert_contains "form 1 counts the CHECKOUT (ls-files)"   "$CHECKOUT_FORM" "ls-files"
assert_contains "form 2 counts a REF (ls-tree, filtered)" "$REF_FORM"      'name-only "${ref}"'
assert_contains "form 3 reports the ref beside the count" "$SHA_FORM"      "rev-parse"
# your-org/nexus-code#1249 item 3. Form 4 exists because an ABBREVIATED hash's
# WIDTH is a property of the READING repository, not of the ref — so a pinned
# ref is necessary and insufficient wherever the output will be MATCHED.
assert_contains "form 4 is the FULL sha (no --short), for output that is MATCHED" \
                "$FULL_SHA_FORM" 'rev-parse "${ref}"'
assert_eq "form 4 carries no abbreviating flag" \
          "$( [[ "$FULL_SHA_FORM" == *--short* ]] && echo abbreviated || echo full )" "full"

# ---- build the fixture ---------------------------------------------------
# Two refs, one repo, differing by exactly ONE matching file:
#
#     OLD  ── NEW            OLD: test-a, test-b        (2 matching)
#                            NEW: test-a, test-b, test-c (3 matching)
#
# `notes.md` exists on both and matches NEITHER predicate — CONTROL C, so the
# numbers below are a property of the predicate, not just of file existence.
#
# The NEW commit also carries `monitor/sites.py`, which the location arm at the
# bottom of this file needs and which matches neither predicate. OLD's file set
# is untouched, so CONTROL C's total stays 3.
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
    # ADDITIVE (the location arm): a tracked file matching NEITHER count
    # predicate, so every count above is unchanged by its presence. Three sites
    # bearing the block's placeholder token, spaced 4 apart, all below line 1 —
    # so a single insertion at the top shifts all three by the SAME delta.
    cat > monitor/sites.py <<'PY_FIXTURE'
import os


def walk_a(root_a):
    return os.listdir(root_a)   # CONSTRUCT site-a


def walk_b(root_b):
    return os.listdir(root_b)   # CONSTRUCT site-b


def walk_c(root_c):
    return os.listdir(root_c)   # CONSTRUCT site-c
PY_FIXTURE
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

# ---- THE WIDTH AXIS (your-org/nexus-code#1249 item 3, worked example #1122)
# `#1122` pinned its ref correctly and broke anyway: it matched a hard-coded
# 7-character prefix against `--format=%h` in a repository that had grown
# enough for git to print 8. The reported measurement is across two clones with
# different in-pack counts, which no fixture can afford to build. What IS
# cheaply demonstrable, and is the same claim, is that the abbreviated width is
# settable BY THE READER while the ref is held constant — so it cannot be a
# property of the ref.
_run_form "$FULL_SHA_FORM" "$OLD"; full=$_FORM_OUT
assert_eq "form 4 emits the FULL 40-hex sha" \
    "$( [[ "$full" =~ ^[0-9a-f]{40}$ ]] && echo 40hex || echo "other:$full" )" "40hex"
assert_eq "form 4 resolves the SAME object form 3 abbreviates" \
    "$( [[ "$full" == "$OLD" ]] && echo same || echo differ )" "same"
# THE CLAIM: one ref, one repository, two widths — chosen by the READER.
w7=$(git -C "$FIX" -c core.abbrev=7  rev-parse --short "$OLD" | tr -d '[:space:]')
w12=$(git -C "$FIX" -c core.abbrev=12 rev-parse --short "$OLD" | tr -d '[:space:]')
assert_eq "the same ref abbreviates to 7 when the READER asks for 7"   "${#w7}"  "7"
assert_eq "…and to 12 when the READER asks for 12 — one ref, two widths" "${#w12}" "12"
# CONTROL — the full form is NOT settable the same way, which is exactly why
# it is the one to match on. Without this, the pair above would be consistent
# with "git just does what -c says", rather than with the asymmetry claimed.
full12=$(git -C "$FIX" -c core.abbrev=12 rev-parse "$OLD" | tr -d '[:space:]')
assert_eq "CONTROL: the FULL form ignores core.abbrev and stays 40" "${#full12}" "40"

# ════════════════════════════════════════════════════════════════════════
# THE LOCATION ARM — a line number is a count's twin (`#1163`)
# ════════════════════════════════════════════════════════════════════════

# ---- extract the location block ------------------------------------------
echo
echo '=== Extraction: pull the LOCATION-PROVENANCE block out of CLAUDE.md ==='
LOC_BEGIN_MARK='<!-- BEGIN LOCATION-PROVENANCE -->'
LOC_END_MARK='<!-- END LOCATION-PROVENANCE -->'

LOC_FORMS=$(awk -v b="$LOC_BEGIN_MARK" -v e="$LOC_END_MARK" '
    index($0, b) { inb = 1; next }
    index($0, e) { inb = 0 }
    inb' "$CLAUDE_MD" \
    | sed -E 's/^[[:space:]]+//' \
    | grep -vE '^```' \
    | sed -E 's/[[:space:]]{2,}#.*$//' \
    | grep -E '^git ')

# CONTROL E — pin this block's count separately. Sharing CONTROL A's number
# would let a botched location extraction hide behind the count block's health.
n_loc_forms=$(printf '%s\n' "$LOC_FORMS" | grep -c '^git ' || true)
assert_eq "extracted exactly 2 documented location forms" "$n_loc_forms" "2"
if (( n_loc_forms != 2 )); then
    th_abort "location extraction produced $n_loc_forms form(s); refusing to draw conclusions from it"
fi
CONTENT_FORM=$(printf '%s\n' "$LOC_FORMS" | grep -F 'git show'      | sed -n '1p')
BLOB_FORM=$(printf '%s\n'    "$LOC_FORMS" | grep -F 'git rev-parse' | sed -n '1p')
assert_contains "location form 1 reads the CONTENT at the line" "$CONTENT_FORM" 'grep -n'
# your-org/nexus-code#1249 item 2. Form 2 had this assertion and form 1 did
# not, so unbracing form 1 — leaving CLAUDE.md prescribing the very shape the
# neighbouring zsh-modifier entry tells you to brace ALWAYS — survived every
# guard in the repo: this suite stayed 34/0 and `test-zsh-modifier-lint.sh`
# stayed 10/0. The lint cannot cover it and adding CLAUDE.md to that lint's
# population would not: its pattern needs a LITERAL modifier letter after the
# colon, and `"$ref:$path"` has a `$` there (measured — the lint's own
# positive control matches, this line does not). So the assertion has to live
# beside the form it is about.
assert_contains "location form 1 BRACES the ref and path" "$CONTENT_FORM" 'git show "${ref}:${path}"'
assert_contains "location form 2 names the BLOB beside the line" "$BLOB_FORM" 'rev-parse "${ref}:${path}"'

# ---- extend the fixture: the same repo, one commit that inserts ABOVE ----
# `monitor/sites.py` was written into the NEW commit above. It matches NEITHER
# count predicate, so every pre-existing count is untouched by its presence.
#
#     OLD ── NEW(=LOC_A) ── LOC_B  [branch loc-after]
#
# LOC_B prepends exactly 4 lines ABOVE all three sites, so every site shifts by
# the SAME delta — which is the whole point of (ii). HEAD is restored to its
# original branch afterwards, so the checkout stays NEW and this extension is
# ORDER-INDEPENDENT with respect to the count arm above.
echo
echo '=== Fixture extension: 4 lines inserted above three identical-delta sites ==='
LOC_A="$NEW"
SITES='monitor/sites.py'
(
    set -e
    cd "$FIX"
    orig_branch=$(git rev-parse --abbrev-ref HEAD)
    [[ -n "$orig_branch" && "$orig_branch" != HEAD ]] || exit 98
    git checkout -q -b loc-after
    { printf '%s\n' '"""Fixture module."""' '' 'from __future__ import annotations' ''
      cat "$SITES"; } > "$WORK/sites.next"
    mv "$WORK/sites.next" "$SITES"
    git add -A && git commit -qm 'insert 4 lines above every site'
    git checkout -q "$orig_branch"
) >/dev/null 2>&1 || th_abort "location fixture extension failed"
LOC_B=$(git -C "$FIX" rev-parse loc-after)
[[ "$LOC_B" =~ ^[0-9a-f]{40}$ ]] || th_abort "loc-after did not resolve"
[[ "$(git -C "$FIX" rev-parse HEAD)" == "$LOC_A" ]] \
    || th_abort "HEAD was not restored to NEW; the count arm above would no longer hold"

# ---- run the documented location forms verbatim --------------------------
# Sets `_LOC_OUT` and RETURNS the form's rc, for the same subshell reason
# `_run_form` above does. Two env vars rather than one, and both are handed to
# an explicit `bash -c`: `path` is a TIED ARRAY in zsh and assigning it there
# would destroy `$PATH` (`#945`).
#
# NOTE ON THE RC IT RETURNS. Form 1 is a PIPELINE, and the inner shell sets no
# `pipefail`, so this rc is `grep`'s — never `git show`'s. That is not a defect
# in the capture; it is the fact CONTROL G pins.
_LOC_OUT=""
_run_loc_form() {   # $1 form · $2 ref · $3 path → sets _LOC_OUT, returns the form's rc
    _LOC_OUT=$(ref="${2:-}" path="${3:-}" FORM="$1" bash -c '
        cd "$0" || exit 99
        eval "$FORM"
    ' "$FIX" 2>/dev/null)
    return $?
}

echo
echo '=== The documented location forms, run verbatim from the block ==='
_run_loc_form "$CONTENT_FORM" "$LOC_A" "$SITES"; rc_loc_a=$?; loc_a_raw=$_LOC_OUT
_run_loc_form "$CONTENT_FORM" "$LOC_B" "$SITES"; rc_loc_b=$?; loc_b_raw=$_LOC_OUT

# The line numbers the BLOCK's form reports, space-joined.
_lines_of() { printf '%s\n' "$1" | sed -nE 's/^([0-9]+):.*/\1/p' | tr '\n' ' ' | sed -E 's/ $//'; }
loc_a_lines=$(_lines_of "$loc_a_raw")
loc_b_lines=$(_lines_of "$loc_b_raw")

# CONTROL F — the POSITIVE control, by a DIFFERENT mechanism. `awk` numbers the
# lines itself; the block's `grep -n` is not consulted. Expected values are the
# fixture's construction constants: sites written at 5/9/13, plus 4 inserted.
_awk_lines() {   # $1 ref → space-joined line numbers of the construct
    git -C "$FIX" show "${1}:${SITES}" \
        | awk '/CONSTRUCT/ { printf "%s%s", (n++ ? " " : ""), NR } END { print "" }'
}
awk_a=$(_awk_lines "$LOC_A")
awk_b=$(_awk_lines "$LOC_B")
assert_eq "CONTROL F: an independent locator finds the sites at LOC_A" "$awk_a" "5 9 13"
assert_eq "CONTROL F: an independent locator finds the sites at LOC_B" "$awk_b" "9 13 17"
assert_eq "block form 1 at LOC_A agrees with the independent locator" "$loc_a_lines" "$awk_a"
assert_eq "block form 1 at LOC_B agrees with the independent locator" "$loc_b_lines" "$awk_b"

# (i) THE LINE NUMBER MOVED. Both non-empty, so "unequal" is not the vacuous
# kind the count arm above had to close.
assert_eq "the SAME construct is at DIFFERENT lines on the two refs" \
    "$( [[ -n "$loc_a_lines" && -n "$loc_b_lines" && "$loc_a_lines" != "$loc_b_lines" ]] \
        && echo differ || echo same )" "differ"
assert_eq "both location pipelines exited 0 — nothing errors while the number moves" \
    "${rc_loc_a}${rc_loc_b}" "00"

# …and the CONTENT is byte-identical, which is exactly why BOTH citations are
# true and the pair reads as a contradiction. Compare the grep output with the
# line numbers stripped off.
_text_of() { printf '%s\n' "$1" | sed -E 's/^[0-9]+://'; }
assert_eq "the CONTENT at each site is identical across refs — both citations are TRUE" \
    "$( [[ "$(_text_of "$loc_a_raw")" == "$(_text_of "$loc_b_raw")" ]] && echo identical || echo changed )" \
    "identical"

# Form 2, verbatim: the BLOB is what makes a cited line checkable.
_run_loc_form "$BLOB_FORM" "$LOC_A" "$SITES"; blob_a=$_LOC_OUT
_run_loc_form "$BLOB_FORM" "$LOC_B" "$SITES"; blob_b=$_LOC_OUT
assert_eq "block form 2: the two BLOBS differ, and both name an object" \
    "$( [[ "$blob_a" =~ ^[0-9a-f]{40}$ && "$blob_b" =~ ^[0-9a-f]{40}$ && "$blob_a" != "$blob_b" ]] \
        && echo distinct || echo no )" "distinct"

# ---- (ii) THE DELTA CHECK IS VACUOUS — the headline ----------------------
echo
echo '=== The delta check: pinned POSITIVELY, by showing the BAD check PASSES ==='
read -r a1 a2 a3 <<<"$loc_a_lines"
read -r b1 b2 b3 <<<"$loc_b_lines"
for _v in a1 a2 a3 b1 b2 b3; do
    [[ "${!_v}" =~ ^[0-9]+$ ]] || th_abort "site line $_v did not parse from the block's output"
done

assert_eq "all three sites shift by exactly the SAME delta" \
    "$(( b1 - a1 )) $(( b2 - a2 )) $(( b3 - a3 ))" "4 4 4"

# THE BAD CHECK PASSES. A delta-4 reconciliation is satisfied by every one of
# the three candidate sites, so it selects NONE of them. `=` and not `==`:
# arithmetic assignment, and the summary-honesty classifier reads this line.
D=4
n_delta_ok=0
for _i in 1 2 3; do
    eval "_oa=\$a$_i; _ob=\$b$_i"
    (( _ob - _oa == D )) && n_delta_ok=$(( n_delta_ok + 1 ))
done
assert_eq "THE BAD CHECK PASSES: 3 of 3 candidate sites satisfy a delta-4 claim — it narrows NOTHING" \
    "$n_delta_ok" "3"

# The SOUND check, on the same three candidates: the CONTENT at the line.
# It narrows to exactly one where the delta narrowed to none.
n_content_ok=0
for _n in "$b1" "$b2" "$b3"; do
    _line=$(git -C "$FIX" show "${LOC_B}:${SITES}" | sed -n "${_n}p")
    [[ "$_line" == *'site-b'* ]] && n_content_ok=$(( n_content_ok + 1 ))
done
assert_eq "the SOUND check: the CONTENT at the line narrows 3 candidates to 1" \
    "$n_content_ok" "1"

# The same two NUMBERS, a WRONG pairing, the SAME delta. (9 → 13) is the true
# cross-ref pair for site-b; (9 → 13) is ALSO a pair of two DIFFERENT sites at
# ONE ref. The numbers cannot tell those apart, and a bare `path:line` carries
# no ref to break the tie — which is how the originating exchange reconciled
# against the wrong site and stopped looking.
assert_eq "the same two NUMBERS are delta-consistent for a WRONG pairing" \
    "$(( b2 - b1 ))" "$(( b2 - a2 ))"
_wrong_lo=$(git -C "$FIX" show "${LOC_B}:${SITES}" | sed -n "${b1}p")
_wrong_hi=$(git -C "$FIX" show "${LOC_B}:${SITES}" | sed -n "${b2}p")
assert_eq "…and that delta-consistent pair holds two DIFFERENT constructs" \
    "$( [[ "$_wrong_lo" != "$_wrong_hi" && "$_wrong_lo" == *'site-a'* && "$_wrong_hi" == *'site-b'* ]] \
        && echo different || echo same )" "different"

# The ref-ambiguity collision, stated as a single citation: `sites.py:9`.
_nine_a=$(git -C "$FIX" show "${LOC_A}:${SITES}" | sed -n '9p')
_nine_b=$(git -C "$FIX" show "${LOC_B}:${SITES}" | sed -n '9p')
assert_eq "one refless \`path:9\` names DIFFERENT constructs of the SAME shape at the two refs" \
    "$( [[ "$_nine_a" == *'site-b'* && "$_nine_b" == *'site-a'* \
          && "$_nine_a" == *'os.listdir('* && "$_nine_b" == *'os.listdir('* ]] \
        && echo ambiguous || echo no )" "ambiguous"

# ---- (iii) a wrong PATH is the LESSER hazard, because it is LOUD ---------
echo
echo '=== A wrong PATH refuses; a wrong LINE in a real file does not ==='
# ALWAYS braced. Unbraced, zsh applies a HISTORY MODIFIER — `"$ref:sites.py"`
# is not a path expression at all — and manufactures a confident FALSE
# existence answer. This is precisely that call site.
BOGUS='monitor/nope.py'
git -C "$FIX" cat-file -e "${LOC_A}:${BOGUS}" 2>/dev/null; rc_bogus_a=$?
git -C "$FIX" cat-file -e "${LOC_B}:${BOGUS}" 2>/dev/null; rc_bogus_b=$?
assert_eq "cat-file -e REFUSES a bogus path at LOC_A" \
    "$( (( rc_bogus_a != 0 )) && echo refused || echo accepted )" "refused"
assert_eq "cat-file -e REFUSES a bogus path at LOC_B" \
    "$( (( rc_bogus_b != 0 )) && echo refused || echo accepted )" "refused"
# The positive control for the refusal: the same probe ACCEPTS the real path at
# both refs, so the non-zero above is about the PATH and not about the probe.
git -C "$FIX" cat-file -e "${LOC_A}:${SITES}" 2>/dev/null; rc_real_a=$?
git -C "$FIX" cat-file -e "${LOC_B}:${SITES}" 2>/dev/null; rc_real_b=$?
assert_eq "…while ACCEPTING the real path at both refs" "${rc_real_a}${rc_real_b}" "00"

# The asymmetry that is the whole point: a stale LINE is SILENT. Citing site-a's
# LOC_A line (5) against LOC_B lands on real, coherent code at rc 0.
rc_stale=0; _stale=$(git -C "$FIX" show "${LOC_B}:${SITES}" | sed -n "${a1}p") || rc_stale=$?   # your-org/nexus-code#1403: never `x=$(…); rc=$?` under errexit
assert_eq "a stale LINE in a real file exits 0 and yields plausible code" \
    "$( [[ $rc_stale -eq 0 && -n "$_stale" && "$_stale" != *'CONSTRUCT'* ]] \
        && echo silent || echo loud )" "silent"

# CONTROL G — the pipeline-status control. Form 1's rc is grep's, so a bogus
# path is reported as "no match" (1), not as git's 128. A caller testing that rc
# cannot tell a missing PATH from a missing CONSTRUCT.
_run_loc_form "$CONTENT_FORM" "$LOC_A" "$BOGUS"; rc_pipe_bogus=$?
git -C "$FIX" show "${LOC_A}:${BOGUS}" >/dev/null 2>&1; rc_show_bogus=$?
assert_eq "CONTROL G: the form-1 PIPELINE reports grep's 1 where git show exits 128" \
    "${rc_pipe_bogus}/${rc_show_bogus}" "1/128"

# EXPECTED-COUNT GUARD (your-org/nexus-code#807; required by
# test-summary-honesty-manifest.sh at the `ledger=yes` protection level).
# Every assertion above is unconditional — this suite has no skipping arm —
# so this is a literal constant.
#   1  CLAUDE.md readable
# + 6  extraction (count pinned at 4, plus the three form assertions, plus the
#      two form-4 shape assertions — `#1249` item 3)
# + 3  the three counts
# + 1  the claim: the counts differ across refs
# + 1  the forms all exit 0 while disagreeing
# + 1  the decoy is excluded
# + 1  rev-parse resolves the scoping ref
# + 5  the WIDTH axis (`#1249` item 3): form 4 is 40 hex and is the same object
#      form 3 abbreviates, one ref abbreviates to 7 and to 12 at the READER's
#      choosing, and the CONTROL that the full form ignores core.abbrev
# --- the location arm (`#1163`) ---
# + 4  location extraction (count pinned at 2, the two form assertions, plus
#      form 1's BRACING assertion — `#1249` item 2)
# + 4  the block's form 1 vs an INDEPENDENT locator, at both refs
# + 3  the number moved, both pipelines exited 0, the content is identical
# + 1  the two blobs differ
# + 6  the delta arm: uniform shift, the BAD check passes, the sound check
#      narrows, the wrong pairing is delta-consistent and holds two different
#      constructs, and one refless line names two sites
# + 5  the wrong path refuses at both refs, accepts the real path, the stale
#      line is silent, and the pipeline reports grep's rc
EXPECTED=42
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
