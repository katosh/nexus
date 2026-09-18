#!/usr/bin/env bash
# test-claude-md-merge-enumeration.sh — execute CLAUDE.md's MERGE-ENUMERATION
# block (inside the count-provenance entry).
#
# WHY THIS SUITE EXISTS. your-org/nexus-code#931: `grep 'Merge pull request #'`
# does not enumerate merged PRs, because a SQUASH-merged PR carries no such
# subject — its subject is the PR title ending in `(#N)`. It produced a wrong
# DENOMINATOR in a number that had already been published.
#
# WHAT IS ACTUALLY PINNED. Not "grep works". The claim: on a tree containing
# both merge styles, the merge-subject filter UNDERCOUNTS, silently and at rc 0,
# while an unfiltered first-parent walk sees every one.
#
# AND WHAT IS NOT PINNED, DELIBERATELY (your-org/nexus-code#946 F1). Every
# bucket here keys on a SUBJECT SHAPE. A shape is a PROXY for "a merged PR",
# never the property itself, and an earlier revision of this file asserted
# `live_squash == 25` under the label "CLAUDE.md's cited squashed count still
# holds" — a proxy wearing a property's name, inside the entry that teaches
# count provenance. The label is now what the predicate checks. The property
# needs `merge_commit_sha` from the GitHub API, which no hermetic fixture can
# reach; CLAUDE.md carries that command and its measured 294 instead, and the
# two commits below are the local, checkable evidence that shape != property.
#
# CONTROLS:
#   A — extracted form count PINNED at 3 (#618's shape).
#   B — POSITIVE control: the unfiltered walk must find BOTH styles, so the
#       assertions measure the FILTER and not a fixture that only has one PR.
#   C — a DECOY commit belonging to neither style (a direct push), so the
#       numbers measure the predicate rather than the size of the history.
#   D — the undercounting form EXITS 0. The defect is that it succeeds.
#   E — a THIRD subject shape (`Merge PR #N:`), which exists in this repo's own
#       history and is invisible to BOTH of the first two buckets.
#
# The live numbers the entry cites (269 / 25 at e256d4a) are checked against
# that exact ref when it is present, and SKIPPED with a reason when it is not —
# a shallow or truncated clone must not silently pass this.

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
th_claude_md_block_coverage MERGE-ENUMERATION   # the entry's UNCHECKED share, in this suite's own output (#1239)

WORK=$(mktemp -d -t nexus-mergeenum-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

echo '=== Extraction: pull the delimited block out of CLAUDE.md ==='
[[ -r "$CLAUDE_MD" ]] || th_abort "CLAUDE.md not readable at $CLAUDE_MD"
assert_file_exists "CLAUDE.md is readable" "$CLAUDE_MD"

FORMS=$(awk -v b='<!-- BEGIN MERGE-ENUMERATION -->' -v e='<!-- END MERGE-ENUMERATION -->' '
    index($0, b) { inb = 1; next }
    index($0, e) { inb = 0 }
    inb' "$CLAUDE_MD" \
    | sed -E 's/^[[:space:]]+//' \
    | grep -vE '^```' \
    | sed -E 's/[[:space:]]{2,}#.*$//' \
    | grep -E '^git log ')

FORM_COUNT=$(printf '%s\n' "$FORMS" | grep -c '^git log ')
assert_eq "extracted exactly 4 documented forms" "$FORM_COUNT" "4"
if [[ "$FORM_COUNT" != "4" ]]; then
    th_abort "block malformed — refusing to draw conclusions from it"
fi
assert_contains "form 1 is the merge-subject filter"     "$(printf '%s\n' "$FORMS" | sed -n '1p')" 'Merge pull request'
assert_contains "form 2 is the unfiltered walk"          "$(printf '%s\n' "$FORMS" | sed -n '2p')" '%h|%p|%s'
assert_contains "form 3 classifies on all THREE shapes"  "$(printf '%s\n' "$FORMS" | sed -n '3p')" 'Merge PR #'
# your-org/nexus-code#1271. Form 4 surfaces the CANDIDATES: one-parent commits
# matching NO shape. Every rebase-merged PR is in that set, and so is every
# direct push, and nothing in the commit can separate them.
assert_contains "form 4 selects ONE-parent commits"     "$(printf '%s\n' "$FORMS" | sed -n '4p')" 'split($2,a," ")==1'
assert_contains "form 4 emits the FULL sha, not %h (#1122)"  "$(printf '%s\n' "$FORMS" | sed -n '4p')" "%H"
assert_contains "form 4 walks the FULL history, no -n"  "$(printf '%s\n' "$FORMS" | sed -n '4p')" '--first-parent --format' 

echo
echo '=== Fixture: one repo carrying BOTH merge styles plus a decoy ==='
FIX="$WORK/repo"
mkdir -p "$FIX"
git -C "$FIX" init -q .
git -C "$FIX" config user.email t@t
git -C "$FIX" config user.name t
echo base > "$FIX/f"; git -C "$FIX" add f
git -C "$FIX" commit -qm "initial commit"

# (1) a TRUE merge commit — the style the grep can see
git -C "$FIX" checkout -q -b feat-a
echo a > "$FIX/a"; git -C "$FIX" add a; git -C "$FIX" commit -qm "work on a"
git -C "$FIX" checkout -q master 2>/dev/null || git -C "$FIX" checkout -q main
git -C "$FIX" merge -q --no-ff feat-a -m "Merge pull request #101 from org/feat-a"

# (2) a SQUASH-merged PR — no merge subject at all
echo b > "$FIX/b"; git -C "$FIX" add b
git -C "$FIX" commit -qm "add the b feature (#102)"

# (3) CONTROL C — a decoy direct push, belonging to neither style
echo c > "$FIX/c"; git -C "$FIX" add c
git -C "$FIX" commit -qm "typo fix, pushed straight to the branch"

# (4) CONTROL E — a THIRD subject shape, hand-edited on a real merge. This is
# not hypothetical: a2a28f2 in this repo is PR #443's merge commit written
# `Merge PR #443: …`, and BOTH of the first two buckets miss it.
git -C "$FIX" checkout -q -b feat-d
echo d > "$FIX/d"; git -C "$FIX" add d; git -C "$FIX" commit -qm "work on d"
git -C "$FIX" checkout -q master 2>/dev/null || git -C "$FIX" checkout -q main
git -C "$FIX" merge -q --no-ff feat-d -m "Merge PR #104: the third shape"

# (5) your-org/nexus-code#1271 — a REBASE-merged PR. GitHub REPLAYS the branch
# commits onto the base, so the merge_commit_sha is an ORDINARY one-parent
# commit wearing the AUTHOR'S OWN subject, verbatim: no merge subject, no
# `(#N)`. It is therefore structurally IDENTICAL to the decoy at (3), and that
# is the whole point — this suite previously asserted that this exact shape is
# correctly EXCLUDED as "not a PR", which is false 13 times on this repo's own
# `dev` line. A fast-forward is what a rebase merge leaves behind.
git -C "$FIX" checkout -q -b feat-e
echo e > "$FIX/e"; git -C "$FIX" add e
git -C "$FIX" commit -qm "watcher: bound the respawn probe (issue #105)"
git -C "$FIX" checkout -q master 2>/dev/null || git -C "$FIX" checkout -q main
git -C "$FIX" merge -q --ff-only feat-e
# The fixture now holds FOUR merged PRs (#101 merge, #102 squash, #104 third
# shape, #105 rebase) plus ONE decoy direct push, on six first-parent commits.
FIXTURE_PRS=4

echo
echo '=== The documented forms are EXECUTED against the fixture (#946 S1) ==='
# WHY THIS EXISTS. An earlier revision counted the forms and substring-matched
# them, then re-typed equivalents inline — and the report claimed the block was
# "executed against fixtures". That is a PROXY answer (readership) to a PROPERTY
# question (execution), this document's own dominant defect class committed
# inside the suite that ships it. Measured by the reviewing skeptic: corrupting
# `Merge pull request #` inside form 3 passed ALL 22 CLAUDE.md-reading suites.
#
# It also had a second cost: the re-typed regex DIVERGED from the documented one
# (`Merge PR #[0-9]+` inline vs `^Merge PR #[0-9]+` in the document). Both give 2
# at e256d4a, so the divergence was inert — a property of this history, not a
# guarantee. Running the EXTRACTED text makes divergence impossible.
FORM1=$(printf '%s\n' "$FORMS" | sed -n '1p')
FORM2=$(printf '%s\n' "$FORMS" | sed -n '2p')
FORM3=$(printf '%s\n' "$FORMS" | sed -n '3p')
FORM4=$(printf '%s\n' "$FORMS" | sed -n '4p')

ev_wrong=$(cd "$FIX" && eval "$FORM1" 2>&1)
assert_eq "DOCUMENTED form 1, run on the fixture, sees only the ONE true merge" "$ev_wrong" "1"

ev_walk=$(cd "$FIX" && eval "$FORM2" 2>&1)
assert_eq "DOCUMENTED form 2, run on the fixture, returns every first-parent commit" \
          "$(printf '%s\n' "$ev_walk" | grep -c .)" "6"

# THE ASSERTION THAT CHANGED MEANING (#1271). This used to read "finds all
# THREE PRs" against a fixture holding three. The fixture now holds FOUR, and
# the union still answers 3 — the rebase merge is invisible to every documented
# shape. The label now says what the predicate checks.
ev_union=$(cd "$FIX" && eval "$FORM3" 2>&1)
assert_eq "DOCUMENTED form 3 finds only 3 of the fixture's 4 PRs" "$ev_union" "3"
assert_eq "…so the three-shape union UNDERCOUNTS by exactly the rebase merge" \
          "$(( FIXTURE_PRS - ev_union ))" "1"

# FORM 4 EXECUTED. It must surface the rebase merge — and the decoy WITH it.
# Asserting both is the point: the form names a CANDIDATE SET and does not
# pretend to resolve it, because nothing in the commit can.
ev_cand=$(cd "$FIX" && eval "$FORM4" 2>&1)
assert_eq "DOCUMENTED form 4 surfaces exactly the TWO one-parent no-shape commits" \
          "$(printf '%s\n' "$ev_cand" | grep -c .)" "2"
assert_contains "…including the REBASE merge, which form 3 cannot see" "$ev_cand" "bound the respawn probe"
assert_contains "…and the DECOY direct push, which is NOT a PR"        "$ev_cand" "typo fix"

echo
echo '=== The WRONG form undercounts, silently, at rc 0 ==='
wrong=$(git -C "$FIX" log --first-parent --format='%s' | grep -c 'Merge pull request #')
rc_wrong=$?
assert_eq "the merge-subject filter EXITS 0 (control D)" "$rc_wrong" "0"
assert_eq "…and sees only the ONE true merge commit"     "$wrong"    "1"

echo
echo '=== CONTROL B: the unfiltered walk sees every PR ==='
all=$(git -C "$FIX" log --first-parent --format='%h|%p|%s')
total=$(printf '%s\n' "$all" | grep -c .)
assert_eq "the unfiltered walk returns every first-parent commit" "$total" "6"
assert_contains "…including the true merge"      "$all" "Merge pull request #101"
assert_contains "…AND the squash-merged PR"      "$all" "(#102)"
assert_contains "…AND the third subject shape"   "$all" "Merge PR #104"
assert_contains "…and the decoy"                 "$all" "typo fix"
assert_contains "…AND the rebase-merged PR, wearing its author's own subject" "$all" "bound the respawn probe"

# Classify AFTER the walk, which is what the entry prescribes. Note this is
# still a SHAPE union, not the property — see the header. It is the best a
# git-local predicate can do, and the point of control E is that a two-shape
# union already misses a member sitting in this repo's real history.
two_shape=$(printf '%s\n' "$all" | grep -cE 'Merge pull request #|\(#[0-9]+\)$')
assert_eq "the TWO-shape union still misses the third shape" "$two_shape" "2"
prs=$(printf '%s\n' "$all" | grep -cE 'Merge pull request #|\(#[0-9]+\)$|Merge PR #[0-9]+')
assert_eq "classifying on all three shapes finds 3 — NOT every PR" "$prs" "3"

echo
echo '=== The gap is the defect: 1 reported vs 3 actual, with no error ==='
assert_eq "the merge-subject filter undercounts by the squash AND the third shape" \
          "$(( prs - wrong ))" "2"
# …and the BEST git-local predicate is itself short by the rebase merge, which
# is the gap no subject shape can close (#1271).
assert_eq "even the three-shape union is short by the rebase merge" \
          "$(( FIXTURE_PRS - prs ))" "1"

echo
echo '=== The live numbers the entry cites, checked at their cited ref ==='
CITED_REF=e256d4a
if git -C "$REPO_ROOT" cat-file -e "${CITED_REF}^{commit}" 2>/dev/null; then
    live_merge=$(git -C "$REPO_ROOT" log --first-parent -n 300 --format='%s' "$CITED_REF" | grep -c 'Merge pull request #')
    live_paren=$(git -C "$REPO_ROOT" log --first-parent -n 300 --format='%s' "$CITED_REF" | grep -cE '\(#[0-9]+\)$')
    live_third=$(git -C "$REPO_ROOT" log --first-parent -n 300 --format='%s' "$CITED_REF" | grep -cE '^Merge PR #[0-9]+')
    echo "  at $CITED_REF over 300 first-parent commits:" \
         "merge-subject=$live_merge trailing-(#N)=$live_paren Merge-PR-shape=$live_third"
    assert_eq "CLAUDE.md's cited merge-subject count still holds at $CITED_REF" "$live_merge" "269"
    # LABELLED AS THE PREDICATE, not as "squashed" (#946 F1). This counts
    # subjects ENDING in `(#N)`. Most are squash-merged PRs; the assertion
    # cannot and does not claim that of any individual member.
    assert_eq "…and 25 more subjects END in (#N) — a SHAPE, not a PR identity"  "$live_paren" "25"

    # THE EVIDENCE THAT SHAPE != PROPERTY, both members named and local.
    # These are why the correct total 294 is correct through OFFSETTING errors:
    # one shape-bucket member that is no PR's merge commit, and one real merge
    # commit that no shape bucket sees.
    # %H, NOT %h (your-org/nexus-code#1122). `%h`'s abbreviation width is chosen
    # by git from the READING repository's object count at read time — it is not
    # a property of the ref, so pinning CITED_REF (which this suite does
    # correctly) does not pin it. This anchor used to require a literal `|`
    # immediately after SEVEN characters; the primary clone has grown past the
    # uniqueness threshold and emits EIGHT, so the pattern matched nothing, the
    # capture came back EMPTY, and `assert_contains` failed against a blank
    # haystack. Measured at 50c36ef, same blob, width the ONLY variable:
    #   GIT_CONFIG_PARAMETERS="'core.abbrev=7'" -> 29 passed / 0 failed
    #   GIT_CONFIG_PARAMETERS="'core.abbrev=8'" -> 27 passed / 2 failed
    # %H is fixed at 40 characters, so it removes the axis rather than choosing
    # a value on it.
    false_member=$(git -C "$REPO_ROOT" log --first-parent -n 300 --format='%H|%s' "$CITED_REF" | grep '^348f2cef1c1af34b7b247967f582034626f639f9|')
    assert_contains "348f2ce is IN the (#N) bucket…" "$false_member" '(#493)'
    # …and #493 is an ISSUE, not a PR. Asserted on the shape locally; the 404
    # is recorded in CLAUDE.md with its command, since a fixture must not need
    # the network to reach a verdict.
    assert_eq "…yet its trailing (#N) is an ISSUE ref — one parent, not a merge" \
              "$(git -C "$REPO_ROOT" log -1 --format='%p' 348f2ce | wc -w)" "1"

    # %H for the same reason as the false_member capture above (#1122).
    missed_member=$(git -C "$REPO_ROOT" log --first-parent -n 300 --format='%H|%s' "$CITED_REF" | grep '^a2a28f24ef0ed689f2732403dfc78baa0a8c6214|')
    assert_contains "a2a28f2 wears the THIRD shape…"  "$missed_member" 'Merge PR #443:'
    assert_eq       "…is a real two-parent merge commit…" \
                    "$(git -C "$REPO_ROOT" log -1 --format='%p' a2a28f2 | wc -w)" "2"
    assert_eq "…and is invisible to BOTH documented buckets" \
              "$(printf '%s\n' "$missed_member" | grep -cE 'Merge pull request #|\(#[0-9]+\)$')" "0"
    assert_eq "the third shape is present at $CITED_REF at all — control E is not hypothetical" \
              "$( [[ "$live_third" -ge 1 ]] && echo yes || echo no )" "yes"

    # THE UNION IS PROPERTY + 1, AND THE ENTRY NOW SAYS SO (#946 S2). The
    # documented third form repairs the MISSED member and cannot repair the
    # FALSE one, so it answers 295 where the prose's property total is 294.
    # Pinned here so the one-off cannot drift back into agreement unnoticed and
    # quietly turn the caveat into a lie.
    live_union=$(git -C "$REPO_ROOT" log --first-parent -n 300 --format='%s' "$CITED_REF" \
                 | grep -cE 'Merge pull request #|\(#[0-9]+\)$|^Merge PR #[0-9]+')
    assert_eq "the three-shape UNION answers 295 at $CITED_REF — property 294 PLUS the false member" \
              "$live_union" "295"
    assert_eq "…and the union is 1 less than the raw bucket sum, because 76d27ac matches two shapes" \
              "$(( live_merge + live_paren + live_third - live_union ))" "1"
    # ── your-org/nexus-code#1271: the REBASE population, keyed on the PROPERTY ──
    # These are the merge_commit_shas of the 17 rebase-merged PRs, keyed on the
    # GitHub API — `merge_commit_sha` from `pulls?state=closed`, one parent, and
    # the discriminator CLAUDE.md states: the commit's subject EQUALS the subject
    # of the PR's last commit (`pulls/N/commits`), 17/17, against a 12-member
    # squash control at 0/12. Fetched 2026-09-03 from 632 merged PRs; recorded
    # as data so the check needs no network. FULL shas, per #1122.
    #
    # THE POPULATION IS THE PROPERTY, NOT THE OUTCOME. An earlier revision
    # recorded 13 shas "selected as the merges the union misses" and asserted
    # the union missed them — true by construction of the list, so it could not
    # fail, and it labelled the 13 "rebase-merged PRs" (the #946 F1 shape,
    # inside the entry that teaches it). Keying the list on the API property
    # and DERIVING visibility from the documented predicates makes every number
    # below falsifiable: a rebase merge whose subject happens to match a shape
    # moves from `invisible` to `visible`, and the counts change.
    REBASE_PRS='576	40b67fc1a5f73d6d19fa90788875c33344a67945
349	c4f356841d4f845f400914e9534f7020e0aae103
102	2fbdb11d470c883b633f3d455ac795969c89e648
101	a8981765e997647f4a6c0190eec468ad3f41466e
100	d8bf9a4dad808ed6c00843624febb0a0098eb9ab
99	551815e0cc320d8f539f0ca0c0d3c18315a1403d
98	28252b9a51ea67675e4156de663d59f76eef31ba
97	5edde6089e9b7da6fe13bc30a6f399b9b97220ec
92	e34cd576a7d5574a7afd312036f2ddf3af62cbc1
91	2010f02855e8bb4167d89af067cc08b548d69481
90	cafee51cff75b3e797dd23f46c14ae105351ea23
85	8fa9967fa8d565524da1583616ae3bb58ff68ab2
84	c6928d0b98e5d4031a56b5129322aa2182c546e3
83	b64714c7a0489b47e206d0642c951d75359ae4c0
82	fe430540b0d9c1b629438977882d7a066c332509
81	68bc7d1d4f3936ea1719b37fb29d40be8b185fa2
80	366182e111a6e654e486e4f1b4345066cb4addd6'
    UNION='Merge pull request #|\(#[0-9]+\)$|^Merge PR #[0-9]+'
    assert_eq "17 rebase-merged PRs are recorded as data (the API-keyed property)" \
              "$(printf '%s\n' "$REBASE_PRS" | grep -c .)" "17"

    # DERIVE, per member, at the cited ref: on the first-parent line or not,
    # and visible to the documented union or not. Nothing here is selected.
    git -C "$REPO_ROOT" log --first-parent --format='%H' "$CITED_REF" | sort -u > "$WORK/fp-all"
    git -C "$REPO_ROOT" log --first-parent -n 300 --format='%H' "$CITED_REF" | sort -u > "$WORK/fp-300"
    : > "$WORK/on-fp"; : > "$WORK/visible"; : > "$WORK/invisible"
    while IFS=$'\t' read -r _num _sha; do
        [[ -n "$_sha" ]] || continue
        grep -qx "$_sha" "$WORK/fp-all" || continue
        printf '%s\n' "$_sha" >> "$WORK/on-fp"
        if grep -qE "$UNION" <<<"$(git -C "$REPO_ROOT" log -1 --format='%s' "$_sha")"; then
            printf '%s\t%s\n' "$_num" "$_sha" >> "$WORK/visible"
        else
            printf '%s\n' "$_sha" >> "$WORK/invisible"
        fi
    done <<<"$REBASE_PRS"
    n_on_fp=$(grep -c . "$WORK/on-fp"); n_vis=$(grep -c . "$WORK/visible"); n_inv=$(grep -c . "$WORK/invisible")
    assert_eq "15 of the 17 sit on the first-parent line at $CITED_REF"                 "$n_on_fp" "15"
    assert_eq "…of which 13 are INVISIBLE to the documented union (the relabelled 13)"  "$n_inv"   "13"
    assert_eq "…and 2 are visible BY ACCIDENT — a shape matched, not the property"      "$n_vis"   "2"
    assert_eq "…namely PR #91 and #84, whose subjects end in ISSUE references" \
              "$(cut -f1 "$WORK/visible" | sort -n | tr '\n' ' ')" "84 91 "
    assert_eq "…each ending in a (#N) that is NOT its own PR number" \
              "$(while IFS=$'\t' read -r n h; do git -C "$REPO_ROOT" log -1 --format='%s' "$h" | grep -cE "\(#${n}\)\$"; done < "$WORK/visible" | sort -u)" "0"
    assert_eq "…and 15 = 13 + 2: the two labels partition the set"  "$(( n_inv + n_vis ))" "$n_on_fp"
    # THE DEPTH FLAG IS THE VARIABLE, on the invisible set. Same ref, one flag.
    assert_eq "ZERO of the 13 invisible fall inside the -n 300 window" \
              "$(comm -12 <(sort "$WORK/invisible") "$WORK/fp-300" | grep -c .)" "0"

    # THE BLINDNESS, measured on the DERIVED set rather than asserted of a
    # hand-picked one: the union sees none of the 13 — which is now a claim
    # about the 13 and the predicate, since membership was decided above by
    # the same predicate on the property-keyed list. If the union ever grew a
    # shape that caught one, `n_inv` above would drop and this line would too.
    n_seen=$(git -C "$REPO_ROOT" log --first-parent --format='%H%x09%s' "$CITED_REF" \
             | grep -Ff "$WORK/invisible" | cut -f2 | grep -cE "$UNION")
    assert_eq "the three-shape union sees 0 of the 13 invisible rebase merges" "$n_seen" "0"

    # THE CANDIDATE SET, derived at the CITED ref with the documented form 4's
    # own predicate (restated with the ref, since form 4 carries none — the
    # count-provenance rule this entry teaches). The entry cites 86 and 3.
    _cand_at() {   # <ref> [<-n N>…] -> one-parent no-shape shas on the first-parent walk
        git -C "$REPO_ROOT" log --first-parent "${@:2}" --format='%H%x09%p%x09%s' "$1" \
        | awk -F'\t' 'split($2,a," ")==1 && $3 !~ /Merge pull request #|\(#[0-9]+\)$|^Merge PR #[0-9]+/ {print $1}' | sort -u
    }
    _cand_at "$CITED_REF" > "$WORK/cand-all"; _cand_at "$CITED_REF" -n 300 > "$WORK/cand-300"
    assert_eq "form 4's predicate returns 86 candidates on the full walk at $CITED_REF (cited)" \
              "$(grep -c . "$WORK/cand-all")" "86"
    assert_eq "…and 3 over -n 300 (cited)" "$(grep -c . "$WORK/cand-300")" "3"
    assert_eq "every one of the 13 invisible rebase merges is IN the candidate set" \
              "$(comm -12 <(sort "$WORK/invisible") "$WORK/cand-all" | grep -c .)" "13"
    assert_eq "…and NEITHER accidentally-visible one is (they match a shape, so form 4 drops them)" \
              "$(comm -12 <(cut -f2 "$WORK/visible" | sort) "$WORK/cand-all" | grep -c .)" "0"
    assert_eq "…and none of the 3 at -n 300 is a rebase merge — the window is genuinely empty" \
              "$(comm -12 <(sort "$WORK/on-fp") "$WORK/cand-300" | grep -c .)" "0"

    # THE DOCUMENTED FORM 4, RUN ON THE REAL REPO, AS WRITTEN. It carries NO
    # ref, so like `git ls-files` it answers about YOUR CHECKOUT (a first cut
    # asserted its COUNT against the cited ref and got 87 where e256d4a has
    # 86: the form had walked HEAD). So what is pinned here is CONTAINMENT,
    # which is ref-robust and only strengthens as history grows.
    live_cand=$(cd "$REPO_ROOT" && eval "$FORM4" 2>/dev/null | cut -f1 | sort -u)
    assert_eq "the documented form 4 at HEAD contains all 13 invisible rebase merges" \
              "$(printf '%s\n' "$live_cand" | grep -Ff "$WORK/invisible" | wc -l | tr -d ' ')" "13"   # LINES are the unit here: live_cand is one sha per line by construction (cut -f1 | sort -u)
    assert_eq "…and the candidate set is a SUPERSET, not the 13 alone" \
              "$( [ "$(printf '%s\n' "$live_cand" | grep -c .)" -gt 13 ] && echo superset || echo exact )" "superset"

    # THE DEPTH BAND the entry cites, at ITS ref (5bd6d400), guarded by presence.
    BAND_REF=5bd6d400
    if git -C "$REPO_ROOT" cat-file -e "${BAND_REF}^{commit}" 2>/dev/null; then
        _band() { git -C "$REPO_ROOT" log --first-parent -n "$1" --format='%H' "$BAND_REF" | grep -cFf "$WORK/invisible"; }
        assert_eq "band at $BAND_REF: -n 537 sees 0 of the 13"   "$(_band 537)" "0"
        assert_eq "band at $BAND_REF: -n 538 sees the FIRST one" "$(_band 538)" "1"
        assert_eq "band at $BAND_REF: -n 554 sees all 13"        "$(_band 554)" "13"
        BAND_REF_PRESENT=yes
    else
        BAND_REF_PRESENT=no
        th_skip "depth-band check" "$BAND_REF is not present in this clone — the entry's 537/538/554 band could not be re-measured"
    fi

    # A NAMED MEMBER, so the aggregate cannot drift into vacuity: PR #80.
    rb_subj=$(git -C "$REPO_ROOT" log -1 --format='%s' 366182e111a6e654e486e4f1b4345066cb4addd6)
    assert_eq "PR #80's merge commit has ONE parent, like a squash" \
              "$(git -C "$REPO_ROOT" log -1 --format='%p' 366182e111a6e654e486e4f1b4345066cb4addd6 | wc -w)" "1"
    assert_eq "…and matches NO documented shape — unlike a squash" \
              "$(printf '%s\n' "$rb_subj" | grep -cE "$UNION")" "0"

    CITED_REF_PRESENT=yes
else
    CITED_REF_PRESENT=no; BAND_REF_PRESENT=no
    th_skip "cited-ref check" \
            "$CITED_REF is not present in this clone (shallow?) — the entry's live numbers could not be re-measured here"
fi

# ---- assertion-count guard (your-org/nexus-code#946 F6) -------------------
# A missing assert_* helper (a typo → rc 127) is counted by NOTHING: the suite
# still prints ALL TESTS PASSED with a quietly smaller total. Pinned against the
# configuration ACTUALLY DETECTED — an unconditional pin would go red in a
# shallow clone where the cited ref is absent, turning a documented SKIP into a
# false RED.
#   extraction + planted-fixture arms (need no cited ref)        = 18
#     …of which 3 are the DOCUMENTED forms executed (#946 S1)
#   + the live block at the cited ref, pre-#1271 part                = 10
#     …of which 2 pin the union at property+1 (#946 S2)
#   + the live block at the cited ref (your-org/nexus-code#1271: the
#     property-keyed rebase population and its derived split)         = 28
#   + the depth band at 5bd6d400, when that ref is present             =  3
EXPECTED_ASSERTIONS=27
[[ "$CITED_REF_PRESENT" == "yes" ]] && EXPECTED_ASSERTIONS=$(( EXPECTED_ASSERTIONS + 28 ))
[[ "${BAND_REF_PRESENT:-no}" == "yes" ]] && EXPECTED_ASSERTIONS=$(( EXPECTED_ASSERTIONS + 3 ))
TOTAL_ASSERTIONS=$(( PASS + FAIL ))
assert_eq "assertion TOTAL matches the EXPECTED total (cited ref present=$CITED_REF_PRESENT)" \
          "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
