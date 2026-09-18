#!/usr/bin/env bash
# test-claude-md-block-coverage.sh — every CLAUDE.md marker pair must have a
# READER, and every green must carry its own coverage boundary
# (your-org/nexus-code#1239).
#
# Run: bash monitor/watcher/test-claude-md-block-coverage.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS SUITE EXISTS. A `<!-- BEGIN X -->` / `<!-- END X -->` pair in
# CLAUDE.md is a PROMISE: entries end with some variant of "executed against a
# planted fixture by `test-claude-md-<x>.sh`, so this block is checked, not
# asserted", and that sentence is the reason a reader trusts the block. `#1239`
# found a pair keeping none of it — `WINDOW-KEY-VOCABULARY`, 22 lines of prose
# wearing block markers, read by nothing. "Markers with no reader are worse
# than no markers, because they signal a guarantee nobody provides."
#
# THE ONE-OFF REPAIR IS NOT THE FIX. A pair can lose its reader at any time —
# a suite is renamed, retired, or its extraction stops naming the marker — and
# nothing reddens, because the PROMISE lives in prose and prose cannot fail.
# So this is a RATCHET: a NEW unread pair is a red, not a discovery.
#
# THE PREDICATE, AND THE ONE THAT LOOKS RIGHT AND IS NOT. `#1239`'s own test
# was `git grep <marker>` -> "two hits, both in CLAUDE.md". At `5bd6d400` that
# command returns THREE files for `WINDOW-KEY-VOCABULARY`, so the issue's test
# now reports the defect FIXED. It is not: the third hit is a COMMENT in
# `test-pane-state-claude-identity.sh` that mentions the block while asserting
# something else. A NAME-MENTION predicate cannot separate a reader from a
# citation, and it fails toward "covered" — which is this workspace's dominant
# defect class arriving inside the detector for it.
#
# So the predicate here is a CODE reference: the marker named on a line that
# is not comment-only, in a file outside CLAUDE.md. It is keyed on
# APPLICABILITY, never on conformance (`monitor/_guard_population.sh`): the
# population is every marker pair the DOCUMENT declares, so a pair cannot
# leave the population by failing.
#
# ITS COVERAGE BOUNDARY, stated rather than implied, because a predicate over
# source text for a runtime property is an approximation and you should be
# able to say which way it errs. IT ERRS IN BOTH DIRECTIONS, and an earlier
# version of this paragraph said otherwise — it claimed the predicate "does not
# UNDER-accept … no pair with a real extractor is reported unread", an absolute
# the predicate cannot support, measured FALSE in the #1239 skeptic pass.
#
#   OVER-accepts, and MORE WIDELY than that version stated: any file
#   `git grep --untracked` can see, of any type, whose marker-mentioning line
#   does not START with `#`, `//` or `<!--`. That exclusion is line-anchored,
#   so the marker's own canonical spelling is accepted mid-sentence. Measured:
#   a `.orig` backup and a one-line prose note EACH kept a marker "read" with
#   its real reader deleted. §2's TRACKED-reader assertion names that reliance.
#
#   UNDER-accepts: a GENERIC extractor — one deriving the marker list at
#   runtime and extracting all 24 blocks, a real reader by any definition —
#   names no marker literally, so a pair whose only reader is generic is
#   reported UNREAD (measured, rc 1). The direction is SAFE, a false RED rather
#   than a false green, and that is exactly why the predicate stays keyed on
#   the literal name: tightening it to kill the over-accept would trade a safe
#   false red for an unsafe false green.
#
# Both directions are exercised by §2's controls rather than asserted here.
#
# AND §3 IS A REPORT, NOT AN ASSERTION, DELIBERATELY. `#1239` measured that
# these suites execute ~5.8% of the entries they guard and NOTHING exceeds
# 18%: a suite executes the FENCED COMMANDS, while the thing a reader ACTS ON
# is the PARAGRAPH. §3 prints that ratio and the UNCHECKED residual on every
# run. It catches no defect on its own and is not meant to — its job is to
# stop a green being read as coverage of the paragraph.
#
# WHAT IS DECLINED, AND THE DECLINING IS THE USEFUL HALF. `#1239`'s second
# action asks to generalise `test-claude-md-pane-state-vocabulary.sh`'s
# hand-maintained-COUNT assertion from one entry to all of them. That is NOT
# implemented here, on the issue's OWN reasoning: it worked two candidate
# prose lints and reported both FAIL on F3, the only real test case available.
# A remedy that misses its own motivating instance is `#1158`'s shape. A
# lint that reddened on every entry mentioning a number would be suppressed
# and then deleted, and in the meantime would read as coverage while providing
# none. The honest output is this stated limit plus §3's number.
#
# `#1464` later landed that generalisation as `test-claude-md-count-vs-list.sh`,
# keyed on the ENUMERATION's shape rather than on prose mentioning a number —
# which is why the objection above does not reach it: a sentence enters its
# population only by carrying a list the scanner can count exactly, and it
# under-counts by design. Still NOT implemented here; §3 stays a report.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }
assert_eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "got [$2] want [$3]"; }

# --- the enumerators, defined BEFORE gp_population so it can CALL them ------

# _bc_markers <doc> — every marker NAME the document declares, sorted, unique.
# APPLICABILITY: derived from the BEGIN lines the doc itself carries, so a pair
# cannot leave this set by being broken.
_bc_markers() {
    command grep -o '<!-- BEGIN [A-Z0-9-]* -->' "$1" \
        | sed -e 's/<!-- BEGIN //' -e 's/ -->//' | sort -u
}

# _bc_code_refs <marker> <file>... — prints each file carrying a NON-COMMENT
# reference to the marker. A comment-only mention is a citation, not a reader.
_bc_code_refs() {
    local m="$1"; shift
    local f hits
    for f in "$@"; do
        [[ -r "$f" ]] || continue
        # A HERESTRING, NOT A PIPE, INTO `grep -q` (your-org/nexus-code#622,
        # test-sigpipe-assertion-lint). `grep -q` exits the instant it matches
        # without draining, the upstream writer takes SIGPIPE, and under
        # `set -o pipefail` the pipeline reports 141 — a FALSE FAILURE on input
        # that DOES match. `grep -q … <<<"$var"` has no pipe and no writer to
        # kill. Caught by the lint on this branch before it was pushed.
        #
        # THE `-n` GUARD IS LOAD-BEARING AND IS NOT DEFENSIVE CLUTTER. A
        # herestring of an EMPTY variable feeds grep ONE EMPTY LINE, and an
        # empty line does not match the comment pattern, so `grep -qv` would
        # return 0 and report a file with NO mention at all as a READER. The
        # piped form got that case right for free (no output, no lines, rc 1);
        # the rewrite has to earn it. Controls A and B in §2 are what would
        # catch its loss.
        hits=$(command grep -n -F -e "$m" "$f" 2>/dev/null) || continue
        [[ -n "$hits" ]] || continue
        if command grep -qvE '^[0-9]+:[[:space:]]*(#|//|<!--)' <<<"$hits"; then
            printf '%s\n' "$f"
        fi
    done
}

# _bc_corpus — every tracked file that mentions ANY marker at all. This is the
# guard's read set beyond the doc: its verdict depends on those bytes.
# THE `--untracked` IS LOAD-BEARING, AND ITS ABSENCE PRODUCED A FALSE RED HERE
# (your-org/nexus-code#1054). `git grep` reads the INDEX; the file that gives a
# marker its first reader is, by definition, one an author has only just
# written. Without `--untracked` this guard reddens on a pair whose reader is
# sitting in the working tree unstaged — a confident answer about a tree that
# does not contain the fix. Measured while building this suite: the ratchet
# reported WINDOW-KEY-VOCABULARY UNREAD while its new reader was open in the
# same working tree, and `git add` alone flipped it.
#
# ONE WALK, NOT ONE PER MARKER (your-org/nexus-code#1487). This loop ran a full
# `git grep` per marker, and the corpus it wants is the UNION of those matches —
# so a single multi-pattern `git grep -e m1 -e m2 …` returns THE SAME SET by
# construction, in one traversal instead of 27.
#
# MEASURED 2026-09-07 on the primary clone (the one operators actually work in,
# which hosts 1,061 `work/` analysis trees): the per-marker loop took 599 s for
# 27 markers, against `guards-for-diff`'s 180 s per-probe budget. So
# `--population` was killed at rc 124 EVERY TIME, and `ng guards-for-diff` —
# the pre-push step CLAUDE.md prescribes — could not answer at all in the one
# clone where it matters. Its refusal was CORRECT and fail-closed; what was
# wrong was making it unanswerable. In a fresh clone the same probe returned
# 50 paths in about a second, so the defect was invisible exactly where CI runs.
#
# THE DISCRIMINATOR IS THE ANSWER, NOT THE EXIT CODE. A probe that is merely
# slower in the primary and a probe that means something DIFFERENT there look
# identical from a rc. Run it in both trees and compare the SETS.
_bc_corpus() {
    local m
    local -a pats=()
    for m in $(_bc_markers "$CLAUDE_MD"); do pats+=(-e "$m"); done
    # No markers ⇒ no corpus. Without this guard the call below degenerates to
    # a pattern-less `git grep`, which is a usage error, not an empty set — and
    # `|| true` would then hand back a confident zero.
    if (( ${#pats[@]} == 0 )); then return 0; fi
    # `-I` SKIPS BINARY FILES, and on a real operator tree that is most of the
    # cost rather than a micro-optimisation. `--untracked` walks untracked files
    # too, and the primary clone carries ~41 GB of untracked `.h5ad` analysis
    # data that can never contain a marker. Measured on the primary, same 27
    # patterns, IDENTICAL 50-path answer both ways: 171 s without `-I`, 17 s
    # with. Without it the fixed probe still sat at 166-171 s against
    # guards-for-diff's 180 s budget — an 8% margin on a shared node, which is
    # a flake waiting to happen, and a fail-closed refusal that flakes trains
    # people to stop running the tool. That is the adaptation #1487 warns about,
    # reached by a slower road.
    #
    # It cannot change the ANSWER here: every marker-bearing file in this repo
    # is text, and the equality above was measured on the worst tree available.
    git -C "$REPO_ROOT" grep -I -l --untracked -F "${pats[@]}" -- . 2>/dev/null \
        | sort -u \
        | command grep -v '^CLAUDE\.md$' \
        | command grep -v '^monitor/watcher/test-claude-md-block-coverage\.sh$' \
        | command grep -v '^monitor/watcher/guard-populations\.manifest$' \
        | command grep -v '^monitor/watcher/summary-honesty\.manifest$' \
        || true
}
# THIS GUARD EXCLUDES ITS OWN SOURCE AND THE TWO ENROLMENT MANIFESTS, AND THAT
# IS NOT HYGIENE — IT IS THE DIFFERENCE BETWEEN A RATCHET AND A TAUTOLOGY. The
# generalisation, which is what makes the list the right length: A STATEMENT
# ABOUT A GUARD IS NOT A USE OF THE BLOCK. Three kinds of file make such
# statements. §2's own controls and diagnostics name marker strings on CODE
# lines (an assertion label is not a comment), so without the self-exclusion
# the guard is a "reader" of every marker it complains about and the complaint
# can never fire. `guard-populations.manifest` and `summary-honesty.manifest`
# name a marker only inside a free-text DESCRIPTION of a guard — an enrolment
# RECORD about a suite, never a use of the block.
#
# BOTH WERE MEASURED, NOT ANTICIPATED, AND THE SECOND IS THE WORSE ONE. With
# the guard in its own corpus, deleting the ONLY real reader of
# WINDOW-KEY-VOCABULARY left this suite GREEN. With the manifests in it, the
# same deletion ALSO left it green — because this guard's own manifest row
# describes WINDOW-KEY-VOCABULARY by name, and the sentence in that row denying
# that a citation is readership is itself the citation that supplied it. That
# is the exact failure this header claims the ratchet prevents, on the one
# marker the guard was built for (your-org/nexus-code#1239, skeptic S-2c).
#
# NOT manifests as a CLASS, deliberately: `monitor/grep-delegation-arms.manifest`
# cites a block because that block's ARMS are its data — a functional reference
# and a real reader, and one of this guard's own declared sentinels. Excluding
# the class would drop it and re-create the under-accept direction below.

# `--population`: CLAUDE.md plus every file this guard greps for a marker.
# gp_population CALLS the enumerator; it never restates what it returns.
# shellcheck disable=SC1091
. "$REPO_ROOT/monitor/_guard_population.sh"
gp_population() {
    printf '%s\n' "$CLAUDE_MD"
    local f
    while IFS= read -r f; do
        [[ -n "$f" ]] && printf '%s\n' "$REPO_ROOT/$f"
    done < <(_bc_corpus)
}
gp_handle "$@"

WORK=$(mktemp -d -t nexus-bc-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ===========================================================================
echo '=== §1 The marker pairs are WELL-FORMED — every BEGIN has its END ==='
# ===========================================================================
if [[ -r "$CLAUDE_MD" ]]; then
    ok "CLAUDE.md is readable at $CLAUDE_MD"
else
    bad "CLAUDE.md is readable" "not readable at $CLAUDE_MD"
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi

BEGINS=$(command grep -c '<!-- BEGIN [A-Z0-9-]* -->' "$CLAUDE_MD" || true)
ENDS=$(command grep -c '<!-- END [A-Z0-9-]* -->' "$CLAUDE_MD" || true)
MARKERS=$(_bc_markers "$CLAUDE_MD")
N_MARKERS=$(printf '%s\n' "$MARKERS" | command grep -c . || true)

# NON-VACUITY. An extraction returning nothing would pass every assertion below
# by having none to make — the #618 silent-zero shape, inside the probe.
[[ "$N_MARKERS" -ge 10 ]] && ok "the document declares $N_MARKERS marker pairs" \
    || bad "the document declares a plausible number of marker pairs" \
           "found $N_MARKERS — the extraction is broken, not the document"
assert_eq "every BEGIN has a matching END" "$BEGINS" "$ENDS"
assert_eq "no marker name is declared twice" "$N_MARKERS" "$BEGINS"

if (( FAIL > 0 )); then
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi

# ===========================================================================
echo '=== §2 THE RATCHET: every marker pair has a CODE reader ==='
# ===========================================================================
CORPUS=()
while IFS= read -r f; do [[ -n "$f" ]] && CORPUS+=("$REPO_ROOT/$f"); done < <(_bc_corpus)
[[ "${#CORPUS[@]}" -gt 0 ]] && ok "the corpus of marker-mentioning files is non-empty (${#CORPUS[@]} files)" \
    || bad "the corpus of marker-mentioning files is non-empty" \
           "zero files — the enumerator is blind, and every 'unread' verdict below is a false zero"

UNREAD=""
for m in $MARKERS; do
    refs=$(_bc_code_refs "$m" "${CORPUS[@]}")
    [[ -z "$refs" ]] && UNREAD="$UNREAD $m"
done
if [[ -z "$UNREAD" ]]; then
    ok "all $N_MARKERS marker pairs have at least one CODE reference outside CLAUDE.md"
else
    bad "all $N_MARKERS marker pairs have at least one CODE reference outside CLAUDE.md" \
        "UNREAD:$UNREAD — a marker pair promises the block is checked; give it a reader or remove the markers (your-org/nexus-code#1239)"
fi

# --- Controls. The predicate must react to a built input, both directions ---
# A control that never invokes the predicate is not a control: each of these
# constructs the offending input, RUNS _bc_code_refs, and observes the verdict.
mkdir -p "$WORK/ctl"
printf 'nothing here mentions any marker\n' > "$WORK/ctl/silent.sh"
printf '# a CITATION: the FAKE-CONTROL-MARKER block says things\n' > "$WORK/ctl/comment.sh"
printf 'BEGIN_MARK="<!-- BEGIN FAKE-CONTROL-MARKER -->"\n' > "$WORK/ctl/reader.sh"

n=$(_bc_code_refs FAKE-CONTROL-MARKER "$WORK/ctl/silent.sh" | command grep -c . || true)
assert_eq "Control A (no mention at all): reported UNREAD" "$n" "0"

n=$(_bc_code_refs FAKE-CONTROL-MARKER "$WORK/ctl/comment.sh" | command grep -c . || true)
assert_eq "Control B (COMMENT-ONLY mention): reported UNREAD — this is WINDOW-KEY-VOCABULARY's exact shape, and the shape a name-mention predicate calls covered" \
    "$n" "0"

n=$(_bc_code_refs FAKE-CONTROL-MARKER "$WORK/ctl/reader.sh" | command grep -c . || true)
assert_eq "Control C (CODE reference): reported READ — the predicate is not simply refusing everything" \
    "$n" "1"

n=$(_bc_code_refs FAKE-CONTROL-MARKER "$WORK/ctl/comment.sh" "$WORK/ctl/reader.sh" | command grep -c . || true)
assert_eq "Control D (a citation AND a reader): reported READ, counting only the reader" "$n" "1"

# A MARKER KEPT READ ONLY BY AN UNTRACKED FILE IS THE ACCIDENT CASE, and it is
# named here rather than left silent. The corpus MUST keep `--untracked` for
# the #1054 reason above, so this cannot be fixed by tightening the corpus —
# and it must not be fixed by tightening the PREDICATE either, because a
# generic extractor that derives the marker list at runtime names no marker
# literally and would then be reported UNREAD (the under-accept direction in
# the header). Measured in the #1239 skeptic pass: a `.orig` backup of a
# deleted suite, and a one-line prose note at the repo root, EACH satisfied
# this ratchet on their own. An untracked file appears in no diff, so the
# reliance is invisible in review; this assertion makes it visible instead.
UNTRACKED_ONLY=""
for m in $MARKERS; do
    _any=0; _tracked=0
    while IFS= read -r r; do
        [[ -n "$r" ]] || continue
        _any=1
        git -C "$REPO_ROOT" ls-files --error-unmatch -- "${r#$REPO_ROOT/}" \
            >/dev/null 2>&1 && _tracked=1
    done < <(_bc_code_refs "$m" "${CORPUS[@]}")
    (( _any == 1 && _tracked == 0 )) && UNTRACKED_ONLY="$UNTRACKED_ONLY $m"
done
[[ -z "$UNTRACKED_ONLY" ]] \
    && ok "every marker pair has at least one TRACKED code reader" \
    || bad "every marker pair has at least one TRACKED code reader" \
           "kept READ only by an UNTRACKED file:$UNTRACKED_ONLY — an untracked reader is in no diff; stage the real reader or confirm it is one"

# ===========================================================================
echo '=== §3 COVERAGE REPORT — what a green here does NOT cover ==='
# ===========================================================================
# NOT AN ASSERTION. See the header: this prints the boundary so a green is not
# read as coverage of the paragraph. #1239 measured 5.8% overall, nothing above
# 18%; the numbers below are re-derived on every run rather than quoted.
ENTRY_STARTS=$(command grep -n '^- \*\*' "$CLAUDE_MD" | cut -d: -f1)
DOC_LINES=$(command grep -c '' "$CLAUDE_MD")
tot_exec=0; tot_entry=0; worst_name=""; worst_pct=101
seen_starts=""; unattributed=""
printf '  %-26s %8s %8s %6s\n' 'ENTRY BLOCK' 'EXEC' 'ENTRY' 'PCT'
for m in $MARKERS; do
    # `sed -n '1p'`, never `head -1`: under `set -o pipefail` head exits early,
    # the upstream grep takes SIGPIPE and the status becomes 141 (#622, #1130).
    # `sed -n '<n>p'` and `tail` both DRAIN, so neither is an early-exit reader.
    bline=$(command grep -n -F -e "<!-- BEGIN $m -->" "$CLAUDE_MD" | cut -d: -f1 | sed -n '1p')
    [[ -n "$bline" ]] || continue
    # the entry is the top-level bullet the block sits inside
    start=$(printf '%s\n' "$ENTRY_STARTS" | awk -v b="$bline" '$1 < b' | tail -1)
    end=$(printf '%s\n' "$ENTRY_STARTS" | awk -v b="$bline" '$1 > b' | sed -n '1p')
    # A BLOCK IN NO TOP-LEVEL ENTRY IS REFUSED, NOT GUESSED. The old fallbacks
    # (`start=1`, `end=<document end>`) manufactured a denominator out of an
    # unrelated span: a pair planted before the first bullet scored a 6-line
    # block against 185 lines, and one planted in a bullet-less trailing
    # section was attributed to an unrelated entry — both GREEN
    # (your-org/nexus-code#1239, skeptic S-3b/S-3c).
    if [[ -z "$start" ]]; then
        printf '  %-26s %8s %8s %6s  NOT INSIDE ANY TOP-LEVEL ENTRY\n' "$m" "-" "-" "-"
        unattributed="$unattributed $m"
        continue
    fi
    [[ -n "$end" ]] || end="$DOC_LINES"
    entry_n=$(( end - start ))
    body=$(awk -v b="<!-- BEGIN $m -->" -v e="<!-- END $m -->" \
             'index($0,b){f=1;next} index($0,e){f=0} f' "$CLAUDE_MD")
    # EXEC counts lines INSIDE a ``` fence, never "block lines minus fences".
    # THE SUBTRACTION FORM IS THE OVER-READ #1239 IS ABOUT, AND IT FIRED HERE
    # FIRST. A pair carrying ZERO fences has no executable line at all, yet the
    # subtraction scores all of its prose as executed: this suite's first cut
    # rated WINDOW-KEY-VOCABULARY the BEST-covered entry at 30%, when its
    # fenced surface is 0. That is precisely the mistake #1239's own reviewer
    # published and corrected against itself — the over-read reappearing in the
    # instrument built to measure the over-read.
    exec_n=$(printf '%s\n' "$body" | awk '
        /^[[:space:]]*```/ { inf = !inf; next }
        inf && NF { n++ }
        END { print n + 0 }')
    (( entry_n > 0 )) || continue
    pct=$(( exec_n * 100 / entry_n ))
    tot_exec=$(( tot_exec + exec_n ))
    # THE DENOMINATOR IS PER ENTRY, THE NUMERATOR PER MARKER, AND THE ASYMMETRY
    # IS THE FIX. Five entries carry two or three marker pairs each, so summing
    # the entry span once per MARKER counted 760 lines two or three times:
    # 2280 printed against a correct 1520, in a 2043-line document. `tot_exec`
    # stays per-marker because two pairs in one entry really are two distinct
    # fenced surfaces (skeptic S-3a).
    case " $seen_starts " in
        *" $start "*) shared=" (shared entry)" ;;
        *) seen_starts="$seen_starts $start"
           tot_entry=$(( tot_entry + entry_n )); shared="" ;;
    esac
    printf '  %-26s %8d %8d %5d%%%s\n' "$m" "$exec_n" "$entry_n" "$pct" "$shared"
    (( pct < worst_pct )) && { worst_pct=$pct; worst_name="$m"; }
done
overall=0
(( tot_entry > 0 )) && overall=$(( tot_exec * 100 / tot_entry ))
printf '\n  UNCHECKED: %d of %d entry lines (%d%%) lie OUTSIDE every fenced block.\n' \
    "$(( tot_entry - tot_exec ))" "$tot_entry" "$(( 100 - overall ))"
printf '  A green from any sibling suite covers the %d%% inside the fences. The\n' "$overall"
printf '  paragraph a reader ACTS ON is in the remainder; worst entry is %s at %d%%.\n' \
    "$worst_name" "$worst_pct"
printf '  This report asserts NOTHING (your-org/nexus-code#1239) — it exists so the\n'
printf '  green above is not read as coverage of the prose.\n\n'

# The report must not be able to go silently empty — that would remove the
# boundary while leaving the suite green, which is the failure it documents.
[[ "$tot_entry" -gt 0 && "$tot_exec" -gt 0 ]] \
    && ok "the coverage report is non-vacuous ($tot_exec executed / $tot_entry entry lines)" \
    || bad "the coverage report is non-vacuous" \
           "exec=$tot_exec entry=$tot_entry — the boundary printed above is meaningless"

# THE IMPLAUSIBILITY CHECK, AND IT IS THE CHEAP ONE THAT WOULD HAVE CAUGHT THE
# DOUBLE-COUNT ON DAY ONE: is this number larger than the container could
# possibly hold (your-org/nexus-code#954)? The shipped first cut printed 2280
# entry lines for a 2043-line document and stayed green, because nothing asked.
[[ "$tot_entry" -le "$DOC_LINES" ]] \
    && ok "the coverage denominator does not exceed the document ($tot_entry <= $DOC_LINES lines)" \
    || bad "the coverage denominator does not exceed the document" \
           "$tot_entry entry lines against a $DOC_LINES-line document — entries are being counted more than once, so every percentage above is wrong"

# ===========================================================================
EXPECTED_ASSERTIONS=13
if (( PASS + FAIL != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED_ASSERTIONS" >&2
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d assertions, %d marker pairs)\n' "$PASS" "$N_MARKERS"
    exit 0
else
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi
