#!/usr/bin/env bash
# Lint: no TRACKED file in this repo may contain a merge-conflict marker
# (your-org/nexus-code#774).
#
# THE DEFECT. One marker reached `dev` and survived SEVEN consecutive merges.
# `CHANGELOG.md:394` carried a `|||||||` line. Measured from history in this
# repo (merge, then its two parents, counting marker lines in CHANGELOG.md):
#
#   merge     PR     merge  p1(dev)  p2(PR head)
#   a62e375   #760     0       0        0
#   a6f4021   #759     1       0        1   <- INTRODUCED, on the PR head
#   342e882   #758     1       1        0      inherited from dev
#   8b6474b   #761     0       1        0   <- a rebase resolution removed it
#   9922770   #766     0       0        0
#   ba09e34   #756     1       0        2   <- REINTRODUCED, on the PR head
#   7ebca80   #772     1       1        0      inherited from dev
#
# NON-MONOTONIC, and that is the point. Introduced, silently repaired by an
# unrelated rebase, silently reintroduced by another. No step in that sequence
# was aware of the marker; nothing in this repo looked.
#
# WHY THE FAMILIAR PAIR IS THE WRONG THING TO CHECK. Every marker that has
# ever been in this repo's history was `|||||||` — never `<<<<<<<`, never
# `>>>>>>>`. The `|||||||` line appears only under
# `merge.conflictStyle = diff3`, and unlike the angle-bracket pair it does not
# LOOK like damage: rendered in a Markdown changelog between two bullet blocks
# it reads as a stray separator. A guard that checks only the two familiar
# markers reproduces the bug exactly. All four canonical markers are checked
# here, and the `|||||||` case is the one with a proven occurrence.
#
# WHY TREE-WIDE, AND WHY THIS FILE HAS NO FILENAME ALLOWLIST. The carrier was
# DOCUMENTATION — a file no suite executes — so no per-suite check could have
# seen it. The hazard is a property of every tracked byte, not of a directory,
# so the scan is `git ls-files` with no path restriction.
#
# That forces the self-reference problem: a lint for a textual pattern usually
# has to contain that pattern, and the usual escape is to exempt itself BY
# FILENAME. That escape is this repo's known blind spot — a filename allowlist
# stops policing the one file most likely to be edited into violation, and
# grows silently as files are added to it. So there is no allowlist here, and
# this file is scanned like any other.
#
# WHAT MAKES THAT SAFE — read this before writing about conflict markers
# ANYWHERE in this repo:
#
#     MARKERS ARE MATCHED ONLY AT LINE START. Never begin a line with one.
#     To show a marker at the start of a line, indent it by one space.
#
# That, and only that, is the property. An earlier version of this comment
# claimed the file "carries no literal marker run anywhere" and that nothing
# below was a literal marker — both FALSE, as the #776 skeptic found: the
# trailing comments on the pattern constructors below are literal seven-runs,
# and so is prose in CHANGELOG.md. They are harmless because they sit MID-LINE,
# not because they are absent.
#
# The distinction is not pedantry. This lint has NO exemption mechanism and runs
# on a workflow that gates every PR in the repo with no `paths:` filter. An
# author who believes "there are no literals, so there is nothing to avoid" has
# no reason not to open a line with a marker — and a fenced block in CHANGELOG.md
# illustrating what a conflict looks like is an entirely natural thing to write
# WHEN DOCUMENTING THIS VERY FEATURE. That reddens the gate against the whole
# repo with no escape but the one stated above. Runtime construction (`_rep`) is
# still worth doing — it keeps the executable patterns unambiguous — but it is
# not what makes the file safe to scan.
#
# WHERE IT RUNS, AND WHAT THAT DOES NOT COVER. Discovered automatically by the
# unit band (`find monitor -maxdepth 1 -name 'test-*.sh'`), but the unit band
# is gated on `paths:` that CHANGELOG.md does not match — so the suite alone
# would be blind to exactly the file that carried the defect (the #765 defect
# class). `.github/workflows/conflict-markers.yml` therefore runs this script
# with NO `paths:` and NO `branches:` filter, on both `pull_request` and
# `push`. See that file's header for the coverage argument.
#
# Run: bash monitor/test-conflict-marker-lint.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/.." && pwd)

PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

# --- marker construction ---------------------------------------------------
# Build every 7-character run at runtime, so the executable patterns are
# unambiguous. NOTE the trailing comments on the four assignments below ARE
# literal seven-runs; they are safe because they sit mid-line, which is the
# actual property (see the header). Do not "fix" them by moving one to column 0.
_rep() {  # _rep <count> <string>
    local n=$1 s=$2 out='' i
    for (( i = 0; i < n; i++ )); do out="$out$s"; done
    printf '%s' "$out"
}

M_OURS=$(_rep 7 '<')      # <<<<<<<  ours
M_BASE=$(_rep 7 '|')      # |||||||  merged common ancestors   (diff3 only)
M_SEP=$(_rep 7 '=')       # =======
M_THEIRS=$(_rep 7 '>')    # >>>>>>>  theirs

# ERE: `|` is alternation, so the diff3 marker needs each pipe escaped.
M_BASE_RE=$(_rep 7 '\|')

# A marker line is EXACTLY seven of the character, then whitespace or end of
# line. The `(space|$)` tail is what makes it exactly seven: an eighth
# character of the same kind fails the tail and does not match — so a Markdown
# rule of many `=` or a shell banner of many `#`-adjacent `=` cannot trip it.
# `=======` is the one marker with no label, so it must be a whole line.
_eol='([[:space:]]|$)'
PATTERN="^(${M_OURS}${_eol}|${M_BASE_RE}${_eol}|${M_THEIRS}${_eol}|${M_SEP}$)"

# --- 1. the pattern matches every real marker (anti-vacuous) ---------------
# A lint that cannot fail is not a lint. Feed it each canonical marker,
# including the exact bytes git writes, and assert every one matches. A future
# regex edit that silently stops matching is caught here rather than by the
# next marker to reach dev.
probe=$(mktemp); trap 'rm -f "$probe" "$probe.safe"' EXIT

_expect_match() {  # _expect_match <label> <line>
    printf '%s\n' "$2" > "$probe"
    if grep -qE "$PATTERN" "$probe"; then
        ok "matches $1"
    else
        bad "anti-vacuous guard" "pattern failed to match $1: [$2]"
    fi
}

_expect_no_match() {  # _expect_no_match <label> <line>
    printf '%s\n' "$2" > "$probe"
    if grep -qE "$PATTERN" "$probe"; then
        bad "false-positive guard" "pattern matched a SAFE line ($1): [$2]"
    else
        ok "does not match $1"
    fi
}

_expect_match "the ours marker with a label"      "${M_OURS} HEAD"
_expect_match "the ours marker bare"              "${M_OURS}"
_expect_match "the diff3 base marker (the one this repo actually had)" \
                                                  "${M_BASE} merged common ancestors"
_expect_match "the diff3 base marker with a path" "${M_BASE} CHANGELOG.md"
_expect_match "the separator"                     "${M_SEP}"
_expect_match "the theirs marker with a label"    "${M_THEIRS} feature/branch"
_expect_match "the theirs marker bare"            "${M_THEIRS}"

# --- 2. it does NOT match the lookalikes this repo is full of --------------
# 454 lines in this tree start with a run of `=`. Every one is a documentation
# rule or a banner, and none is exactly seven. If this lint fired on those it
# would be turned off within a day, so the discrimination is asserted, not
# assumed.
_expect_no_match "an 8-wide = run"                "$(_rep 8 '=')"
_expect_no_match "a 24-wide = rule"               "$(_rep 24 '=')"
_expect_no_match "a 6-wide = run"                 "$(_rep 6 '=')"
_expect_no_match "an 8-wide < run"                "$(_rep 8 '<')"
_expect_no_match "a 7-wide = run with a trailing label (a rule, not a marker)" \
                                                  "${M_SEP} section ${M_SEP}"
_expect_no_match "a shell here-doc operator"      'cat <<EOF'
_expect_no_match "a markdown blockquote"          '>>> quoted'
_expect_no_match "an indented marker-like run"    "    ${M_BASE} not at line start"
_expect_no_match "a table row of pipes"           '| a | b | c | d | e | f |'

# --- 2b. the ANCHORING property, checked rather than asserted --------------
# The header states the only rule that keeps this repo's own documentation out
# of the results: markers match at LINE START only, and one leading space is the
# escape. Both directions are pinned here, because that rule is what a future
# author will rely on when writing about conflicts — and because the previous
# justification ("no literals exist") was false and nothing caught it.
_expect_match    "a marker at column 0"                     "${M_BASE} merged common ancestors"
_expect_no_match "the SAME marker indented by one space"    " ${M_BASE} merged common ancestors"
_expect_no_match "a marker mid-line (prose or a trailing comment)" \
                                                            "M_BASE=\$(_rep 7 '|')   # ${M_BASE}  diff3"
_expect_no_match "a marker inside backticks in prose"       "history was \`${M_BASE}\` only"

# --- 3. the tree itself is clean -------------------------------------------
# `git ls-files` scopes this to TRACKED files only — no sweep of work/, of
# reports/, or of an operator's untracked scratch. `grep -I` skips binaries.
#
# NO FILENAME EXCLUSIONS, and no exemption mechanism at all. What keeps this
# file (and every doc that discusses markers) out of the results is that the
# pattern is `^`-ANCHORED — mid-line mentions never match. The only way to
# write a marker at the start of a line is to indent it by one space.
cd "$REPO_ROOT" || { bad "chdir" "cannot cd to $REPO_ROOT"; }

files=()
while IFS= read -r -d '' f; do files+=("$f"); done < <(git ls-files -z 2>/dev/null)

# Enumeration honesty (your-org/nexus-code#721): a count behind a claim is
# sanity-checked, because an empty enumeration reads as "the population is
# clean" when it means "I could not look". 586 tracked files at 954222bc; the
# floor is deliberately far below that so it flags a BROKEN enumeration
# without tripping on ordinary growth or pruning.
if (( ${#files[@]} < 100 )); then
    bad "file enumeration" "git ls-files returned ${#files[@]} files (<100) — the lint would vacuously pass; this is a broken enumeration, not a clean tree"
else
    ok "enumerated ${#files[@]} tracked files"

    hits=$(grep -nIE "$PATTERN" -- "${files[@]}" 2>/dev/null || true)
    if [[ -z "$hits" ]]; then
        ok "no tracked file contains a merge-conflict marker"
    else
        bad "merge-conflict marker in a tracked file" "$(printf '\n%s' "$hits")"
        printf '\n' >&2
        printf '  A conflict resolution left a marker behind. The diff3 marker\n' >&2
        printf '  (seven pipes) is the one that has actually reached dev here — it does\n' >&2
        printf '  not look like damage in rendered Markdown. Remove the marker line and\n' >&2
        printf '  the stale side of the conflict, then re-run.\n' >&2
    fi
fi

# --- 4. the scan really covers files no suite executes ---------------------
# The whole point is coverage of documentation. Assert that the enumeration
# actually reached the file that carried the defect, so a future narrowing of
# the scan (a pathspec, a directory restriction) cannot quietly reintroduce
# the blind spot while every other assertion here still passes.
_carrier="CHANGELOG.md"
_covered=0
for f in "${files[@]}"; do [[ "$f" == "$_carrier" ]] && { _covered=1; break; }; done
if (( _covered )); then
    ok "the scan covers $_carrier (a file no suite executes — the #774 carrier)"
else
    bad "documentation coverage" "$_carrier is not in the scanned set; the scan has been narrowed away from the class of file that carried #774"
fi

# --- 5. the scan really covers THIS file (no self-exemption) ---------------
_self="monitor/$(basename "${BASH_SOURCE[0]}")"
_self_covered=0
for f in "${files[@]}"; do [[ "$f" == "$_self" ]] && { _self_covered=1; break; }; done
if (( _self_covered )); then
    ok "the scan covers this lint itself (no filename allowlist)"
else
    bad "self-exemption" "$_self is excluded from its own scan — the filename-allowlist blind spot has been reintroduced"
fi

echo
printf '=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then echo "ALL TESTS PASSED"; exit 0; fi
echo "FAILED" >&2; exit 1
