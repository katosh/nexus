#!/usr/bin/env bash
# test-claude-md-worktree-blind-spot.sh — execute CLAUDE.md's
# WORKTREE-BLIND-SPOT block.
#
# WHY THIS SUITE EXISTS. your-org/nexus-code#1150: the "check `dev` in
# ISOLATION" entry sends every agent to `git worktree add --detach`, and it is
# RIGHT to — checking `dev` out in the main clone silently breaks the running
# watcher. But a worktree contains neither GITIGNORED nor UNTRACKED files, so
# the population an agent tests is not the population its tree has, and nothing
# errors. The dangerous direction is the SKIP: a fixture-gated test whose data
# is gitignored skips in BOTH arms, so it cannot fail at base and cannot be
# seen to STOP failing.
#
# WHAT IS ACTUALLY PINNED:
#   the BLIND SPOT   — at the SAME commit, a tracked file is present in both
#                      trees while a gitignored file and an untracked file are
#                      present only in the source.
#   the `-q` TRAP    — `git worktree add -q` is rejected at git 2.17.1, the
#                      version on this host, and leaves NO worktree behind.
#                      That is how #1150's author manufactured a false zero
#                      while writing up false zeroes.
#   the SET-vs-TOTAL — `comm -3` finds a one-each-way membership difference
#                      between two ID sets whose TOTALS are equal. A matching
#                      total is not evidence, and the block says so.
#
# CONTROLS:
#   A — the extracted form count is PINNED at 5 (#618's shape: an empty
#       extraction satisfies every assertion by having none to make).
#   B — POSITIVE CONTROL, and it is the whole reason this suite is safe to
#       believe: a TRACKED file must be VISIBLE in the worktree before any
#       absence below is read as a blind spot. When this suite's fixture was
#       first drafted its `git commit` never ran, the worktree was never
#       created, and the tracked control read absent too — the identical
#       signature to the `-q` accident, caught by this control alone.
#   C — the GUARD: both trees report the SAME HEAD. A comparison across two
#       different commits answers a different question and looks the same.
#   D — the `-q` form FAILS. Asserting only that the plain form works would
#       leave the trap this entry documents unmeasured.
#
# HERMETIC: every git operation happens inside a fresh mktemp repository. This
# suite never touches the clone it ships in, and never creates a worktree of it.

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
th_claude_md_block_coverage WORKTREE-BLIND-SPOT   # the entry's UNCHECKED share, in this suite's own output (#1239)

GITV=$(git --version 2>&1)

WORK=$(mktemp -d) || th_abort "mktemp failed"
# `git worktree add` registers metadata inside the fixture repo; both live
# under $WORK, so one rm reclaims everything.
trap 'rm -rf "$WORK"' EXIT

_th_count_guard() {
    local EXPECTED_ASSERTIONS=36
    local TOTAL_ASSERTIONS=$(( PASS + FAIL ))
    assert_eq "assertion TOTAL matches the EXPECTED total" \
              "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"
    th_summary_and_exit
}

echo '=== Extraction: pull the delimited block out of CLAUDE.md ==='
[[ -r "$CLAUDE_MD" ]] || th_abort "CLAUDE.md not readable at $CLAUDE_MD"
assert_file_exists "CLAUDE.md is readable" "$CLAUDE_MD"

FORMS=$(awk -v b='<!-- BEGIN WORKTREE-BLIND-SPOT -->' -v e='<!-- END WORKTREE-BLIND-SPOT -->' '
    index($0, b) { inb = 1; next }
    index($0, e) { inb = 0 }
    inb' "$CLAUDE_MD" \
    | sed -E 's/^[[:space:]]+//' \
    | grep -vE '^```' \
    | sed -E 's/[[:space:]]{2,}#.*$//' \
    | grep -E '^(git|comm) ')

FORM_COUNT=$(printf '%s\n' "$FORMS" | grep -cE '^(git|comm) ')
assert_eq "Control A: extracted exactly 6 documented forms" "$FORM_COUNT" "6"
if [[ "$FORM_COUNT" != "6" ]]; then
    th_abort "block malformed — refusing to draw conclusions from it"
fi

# SELECT BY CONTENT, NOT BY POSITION. `sed -n '4p'` was fine while exactly one
# form said `--ignored`; your-org/nexus-code#1228 added a SECOND, and a
# positional read would then silently hand every later assertion the wrong
# form. The two `--ignored` forms differ by the TREE they target, which is the
# whole point of the pair, so that is what selects them.
F_ADD=$(printf      '%s\n' "$FORMS" | grep -F 'worktree add'   | sed -n '1p')
F_GUARD=$(printf    '%s\n' "$FORMS" | grep -F 'rev-parse HEAD' | sed -n '1p')
# `-- ` IS LOAD-BEARING: the pattern begins with `-`, so without it grep parses
# `-C` as the context OPTION and the selection is EMPTY at rc 1 — CLAUDE.md's
# own DASH-PATTERN-OPTION entry (your-org/nexus-code#1186), met while writing
# this. It cost four downstream assertions, each of which failed for a reason
# that had nothing to do with what it was testing.
F_WTSTATUS=$(printf '%s\n' "$FORMS" | grep -F -- '-C WT status'   | sed -n '1p')
F_CONTROL=$(printf  '%s\n' "$FORMS" | grep -F 'ls-files'       | sed -n '1p')
F_STATUS=$(printf   '%s\n' "$FORMS" | grep -F -- '-C SRC status'  | sed -n '1p')
F_COMM=$(printf     '%s\n' "$FORMS" | grep -F 'comm -3'        | sed -n '1p')

assert_contains "form 1 creates the worktree"            "$F_ADD"      "worktree add --detach"
assert_contains "form 2 is the HEAD guard"               "$F_GUARD"    "rev-parse HEAD"
assert_contains "form 3 is the WORKTREE plant guard"     "$F_WTSTATUS" "status --porcelain --ignored"
assert_contains "form 4 is the tracked positive control" "$F_CONTROL"  "ls-files"
assert_contains "form 5 enumerates ignored + untracked"  "$F_STATUS"   "--ignored"
assert_contains "form 6 diffs the SETS"                  "$F_COMM"     "comm -3"

# ---- the planted repository ---------------------------------------------
SRC="$WORK/src"
WT="$WORK/wt"
mkdir -p "$SRC/reports"
git -C "$SRC" init -q                       >/dev/null 2>&1
git -C "$SRC" config user.email fixture@local
git -C "$SRC" config user.name  fixture
# A tracked CLAUDE.md so form 3 runs VERBATIM, with no substitution of the
# thing it is meant to prove is visible.
printf 'fixture CLAUDE.md\n' > "$SRC/CLAUDE.md"
# `reports/.gitignore` is a bare `*` — this repo's real shape, and it ignores
# ITSELF, which is why it needs -f. Getting that wrong is what silently
# aborted the first draft of this fixture.
printf '%s\n' '*' > "$SRC/reports/.gitignore"
git -C "$SRC" add CLAUDE.md                 >/dev/null 2>&1
git -C "$SRC" add -f reports/.gitignore     >/dev/null 2>&1
git -C "$SRC" commit -qm fixture            >/dev/null 2>&1
REF=$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)
[[ -n "$REF" ]] || th_abort "fixture commit failed — nothing below could be believed"

printf 'gitignored payload\n' > "$SRC/reports/ignored_fixture.txt"
printf 'untracked payload\n'  > "$SRC/untracked_fixture.txt"

# Fixture sanity: git must AGREE the ignored file is ignored. Without this the
# blind-spot assertions could pass against a file that is merely missing.
git -C "$SRC" check-ignore -q reports/ignored_fixture.txt
assert_eq "fixture: reports/ignored_fixture.txt IS gitignored" "$?" "0"
assert_eq "fixture: untracked_fixture.txt IS untracked" \
    "$(git -C "$SRC" status --porcelain -- untracked_fixture.txt | sed -n 1p | cut -c1-2)" "??"

_sub() { local s="$1"; s=${s//WT/$WT}; s=${s//SRC/$SRC}; s=${s//REF/$REF}; printf '%s' "$s"; }

echo
echo '=== Control D: the -q accident — asserted where this git can reproduce it ==='
# The trap by which #1150's author produced a false zero. `-q` is inserted into
# the DOCUMENTED form so this measures the documented command, not a lookalike.
# TOOLCHAIN AXIS, and it is the reason this arm branches instead of asserting.
# `git worktree add -q` ARRIVED in a later git than this host's 2.17.1, and CI
# runs `ubuntu-latest`, whose git accepts it. An unconditional "the -q form
# fails" would therefore be RED on every runner and green only here — a suite
# that passes on the author's host and nowhere else. The documented trap is
# git-VERSION-specific and is asserted where it reproduces; where it does not,
# the arm SKIPS with the version named rather than quietly asserting nothing.
# Both branches contribute exactly 2 assertions so the count guard stays exact.
qform=$(_sub "${F_ADD/worktree add/worktree add -q}")
qform=${qform/$WT/${WT}-q}
eval "$qform" >/dev/null 2>&1; qrc=$?
if (( qrc != 0 )); then
    printf '  PASS: %s\n' "the -q form is REJECTED (rc $qrc) under $GITV"; PASS=$(( PASS + 1 ))
    assert_no_file "…and leaves NO worktree behind — every probe against it is a false zero" "${WT}-q"
else
    th_skip "Control D (the -q accident)" \
            "this git ($GITV) ACCEPTS \`worktree add -q\`, so the false zero #1150's author produced CANNOT occur here; the block's git-2.17.1 claim is UNTESTED on this runner, not refuted"
    assert_eq "…the -q form was accepted, so this git is not the one the trap needs" "$qrc" "0"
    assert_eq "…and it DID create the worktree, which is why no false zero follows" \
              "$( [[ -d "${WT}-q" ]] && echo YES || echo NO )" "YES"
    rm -rf "${WT}-q"
    git -C "$SRC" worktree prune >/dev/null 2>&1
fi

echo
echo '=== The documented sequence: create, GUARD, POSITIVE CONTROL ==='
eval "$(_sub "$F_ADD")" >/dev/null 2>&1
assert_eq "form 1 (no -q) creates the worktree" "$?" "0"
assert_eq "…and the worktree DIRECTORY exists" "$( [[ -d "$WT" ]] && echo YES || echo NO )" "YES"

wt_head=$(eval "$(_sub "$F_GUARD")" 2>/dev/null)
assert_eq "Control C (GUARD): the worktree HEAD equals the source HEAD" "$wt_head" "$REF"

ctrl=$(eval "$(_sub "$F_CONTROL")" 2>/dev/null)
assert_eq "Control B (POSITIVE): a TRACKED file IS visible in the worktree" "$ctrl" "CLAUDE.md"

echo
echo '=== NEGATIVE CONTROL: the GUARD and the POSITIVE CONTROL read the WORKTREE ==='
# your-org/nexus-code#1165 skeptic F2. Retargeting either form from `-C WT` to
# `-C SRC` left this suite at 26 passed / 0 failed, because the fixture cannot
# tell them apart: the worktree HEAD EQUALS the source HEAD by construction and
# CLAUDE.md is tracked in both. So the two probes whose entire purpose is to
# detect A WORKTREE THAT WAS NEVER CREATED were exactly the two the suite could
# not distinguish from versions that would fail to detect it — the `-q` accident
# the entry narrates, surviving inside the guard written to prevent it.
#
# The fix is BEHAVIOURAL, not textual. `assert_contains "$F_GUARD" "-C WT"`
# would also kill both mutants, but it pins a SPELLING; this aims both forms at
# a path that is not a worktree and requires them to answer NOTHING. A form
# reading the source answers anyway, and dies here.
_subneg() { local t="$1"; t=${t//WT/$WORK\/nowhere}; t=${t//SRC/$SRC}; t=${t//REF/$REF}; printf '%s' "$t"; }
assert_eq "NEG: the GUARD reads the WORKTREE, so an absent one yields no HEAD" \
          "$(eval "$(_subneg "$F_GUARD")" 2>/dev/null)" ""
assert_eq "NEG: the POSITIVE CONTROL reads the WORKTREE, not the source" \
          "$(eval "$(_subneg "$F_CONTROL")" 2>/dev/null)" ""

echo
echo '=== THE BLIND SPOT: same commit, two different populations ==='
_present() { [[ -e "$1" ]] && printf 'YES' || printf 'NO'; }
assert_eq "tracked      reports/../CLAUDE.md      source=YES" "$(_present "$SRC/CLAUDE.md")" "YES"
assert_eq "gitignored   reports/ignored_fixture   source=YES" "$(_present "$SRC/reports/ignored_fixture.txt")" "YES"
assert_eq "untracked    untracked_fixture         source=YES" "$(_present "$SRC/untracked_fixture.txt")" "YES"
assert_eq "…and in the WORKTREE the tracked file is present"  "$(_present "$WT/CLAUDE.md")" "YES"
assert_eq "…the GITIGNORED file is ABSENT"                    "$(_present "$WT/reports/ignored_fixture.txt")" "NO"
assert_eq "…the UNTRACKED file is ABSENT"                     "$(_present "$WT/untracked_fixture.txt")" "NO"

status_out=$(eval "$(_sub "$F_STATUS")" 2>/dev/null)
assert_contains "form 4 names the untracked file the worktree will lack" "$status_out" "untracked_fixture.txt"
assert_contains "form 4 names the ignored path the worktree will lack"   "$status_out" "ignored_fixture.txt"

echo
echo '=== #1228: the FOUR plant cases — which guard actually fires ==='
# your-org/nexus-code#1228 reported a worktree carrying an unreverted mutation
# plant that PASSED the HEAD guard, and proposed `rev-parse HEAD^{tree}` as the
# better of two remedies. Measured here, that proposal is the WEAKER one and
# does not catch the case reported: `HEAD^{tree}` is a pure FUNCTION of `HEAD`,
# so wherever HEAD matches its tree matches by construction. This arm is the
# measurement, kept executable so the block's table cannot drift from it.
#
# `HEAD^{tree}` is computed here and is deliberately NOT a documented form —
# its presence in this suite is the evidence for its ABSENCE from the block.
_plant_wt() {   # $1 name -> echoes the worktree path
    local d="$WORK/$1"
    git -C "$SRC" worktree add --detach "$d" "$REF" >/dev/null 2>&1 || return 1
    printf '%s' "$d"
}
_sub_wt()   { printf '%s' "${1//WT/$2}"; }   # form 3 holds WT only
_head_of()  { git -C "$1" rev-parse HEAD 2>/dev/null; }
_tree_of()  { git -C "$1" rev-parse 'HEAD^{tree}' 2>/dev/null; }
_fires()    { [[ "$1" != "$2" ]] && printf 'FIRES' || printf 'passes'; }
_nonempty() { [[ -n "$1" ]] && printf 'FIRES' || printf 'passes'; }
SRC_TREE=$(git -C "$SRC" rev-parse 'HEAD^{tree}' 2>/dev/null)
[[ -n "$SRC_TREE" ]] || th_abort "could not read the source tree object — the matrix below would be vacuous"

# (a) UNCOMMITTED plant — the case #1228 actually hit.
WA=$(_plant_wt wt_a) || th_abort "case (a) worktree add failed"
printf 'MUTANT\n' >> "$WA/CLAUDE.md"
assert_eq "(a) uncommitted plant: the HEAD guard PASSES — the reported blind spot" \
          "$(_fires "$(_head_of "$WA")" "$REF")" "passes"
assert_eq "(a) …and #1228's proposed HEAD^{tree} ALSO passes — it adds nothing" \
          "$(_fires "$(_tree_of "$WA")" "$SRC_TREE")" "passes"
assert_eq "(a) …while form 3 (status --porcelain --ignored in WT) FIRES" \
          "$(_nonempty "$(eval "$(_sub_wt "$F_WTSTATUS" "$WA")" 2>/dev/null)")" "FIRES"

# (c) plant into a GITIGNORED path — the sharpest row, and the likely shape:
#     a mutation plant under reports/ or a fixture dir.
WC=$(_plant_wt wt_c) || th_abort "case (c) worktree add failed"
mkdir -p "$WC/reports"; printf 'MUTANT\n' > "$WC/reports/plant.txt"
assert_eq "(c) gitignored plant: the HEAD guard PASSES" \
          "$(_fires "$(_head_of "$WC")" "$REF")" "passes"
assert_eq "(c) …and a PLAIN status --porcelain passes too — no --ignored, no signal" \
          "$(_nonempty "$(git -C "$WC" status --porcelain 2>/dev/null)")" "passes"
assert_eq "(c) …only form 3, WITH --ignored, FIRES" \
          "$(_nonempty "$(eval "$(_sub_wt "$F_WTSTATUS" "$WC")" 2>/dev/null)")" "FIRES"

# (d) SAME tree, DIFFERENT commit — the row that shows HEAD^{tree} is strictly
#     more PERMISSIVE than the HEAD guard it was offered to strengthen.
WD=$(_plant_wt wt_d) || th_abort "case (d) worktree add failed"
git -C "$WD" -c user.email=fixture@local -c user.name=fixture \
    commit -q --allow-empty -m empty >/dev/null 2>&1
assert_eq "(d) empty commit: the HEAD guard FIRES" \
          "$(_fires "$(_head_of "$WD")" "$REF")" "FIRES"
assert_eq "(d) …but HEAD^{tree} PASSES — strictly weaker than the guard it would add to" \
          "$(_fires "$(_tree_of "$WD")" "$SRC_TREE")" "passes"

echo
echo '=== A MATCHING TOTAL IS NOT EVIDENCE: sets, not counts ==='
# Two failing-ID sets with EQUAL totals, differing by one member each way —
# the 45P/70F/4S/11E vs 48P/70F/1S/11E shape that was published as "zero tests
# changed state" and corrected.
SETA="$WORK/a.ids"; SETB="$WORK/b.ids"
printf '%s\n' t_alpha t_beta t_gamma > "$SETA"
printf '%s\n' t_alpha t_beta t_delta > "$SETB"
na=$(grep -c . "$SETA"); nb=$(grep -c . "$SETB")
assert_eq "the two sets have the SAME total — the reading that stops enquiry" "$na" "$nb"
diff_lines=$(eval "$(printf '%s' "${F_COMM/SETA/$SETA}" | sed "s|SETB|$SETB|")" 2>/dev/null | grep -c . || true)
assert_eq "…while comm -3 finds the one-each-way membership difference" "$diff_lines" "2"

_th_count_guard
