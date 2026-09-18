#!/usr/bin/env bash
# Guard: `nexus.self-fix`'s pre-flight tracker search is CHECKED, not asserted.
# (your-org/nexus-code#937.)
#
# Run: bash monitor/watcher/test-self-fix-tracker-search.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS EXISTS. The gate had four checks and none of them was "look whether
# somebody already reported this." Five agents filed one
# `monitor/force-push-check.sh` defect (#898 #909 #910 #912 #920, three inside
# 39 minutes). Check 5 closes it, and this file stops the check from decaying
# into prose that no longer runs — the failure mode a skill step is MOST prone
# to, because a command in a markdown fence is never executed by anything.
#
# WHAT IS AND IS NOT EXERCISED HERE, stated up front because the boundary is
# the interesting part:
#
#   * Probe (c), the unmerged-branch scan, IS EXECUTED. It is extracted from
#     the skill's own fenced block and run against a purpose-built git fixture.
#     It is also the only one of the three that can be, being pure git — and
#     the only one with non-obvious moving parts (the ancestor filter and the
#     file-count cap), so it is the one worth the teeth.
#   * Probes (a) and (b) hit the GitHub API. Executing them would make this
#     suite network-dependent and non-hermetic, which buys a worse guard than
#     it costs. They are pinned STRUCTURALLY instead — on the two properties
#     that make each one work at all, each with the wrong form as an explicit
#     negative control, so "pinned structurally" does not quietly become
#     "grepped for a word".
#
# The extraction is deliberate rather than a copy. A copy of the snippet here
# would be a second spelling that drifts from the skill's — precisely the
# two-defaults hazard #966 spent a branch on — and this suite would then
# certify a command nobody reads.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
. "$_test_dir/_test_helpers.sh"

SKILL="$_repo_root/skills/nexus.self-fix/SKILL.md"
[[ -r "$SKILL" ]] || th_abort "missing skill: $SKILL"
skill_txt=$(<"$SKILL")

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---- §1 the gate says five, everywhere it says a number ------------------
#
# An amended list whose lead-in still says "four" is worse than no amendment:
# the reader counts four, stops, and the fifth reads as an appendix.
echo "=== §1 the check count agrees with the list ==="
assert_eq "the lead-in asks for five checks" \
    "$(grep -c 'Run these five checks' <<<"$skill_txt")" "1"
assert_eq "no 'four checks' / 'all four' survives in this skill" \
    "$(grep -cE 'these four checks|Pass all four|the four checks pass' <<<"$skill_txt")" "0"
assert_eq "a numbered item 5 exists under the gate" \
    "$(grep -c '^5\. \*\*Search the tracker by PATH' <<<"$skill_txt")" "1"

# ---- §2 probes (a) and (b): the property, not the word -------------------
#
# Each assertion below names the ONE thing that makes that probe non-vacuous:
# a rewrite that drops `--state all` (so a closed duplicate reads as "never
# reported") or swaps the PR probe's path selector for a text search (so it
# stops seeing paths) is exactly what would pass otherwise. The two `_not_`
# assertions at the end of the section are the controls that make the rest
# mean something — without at least one falsifiable direction, a section of
# `assert_contains` over a document only proves the document is long.
echo "=== §2 the two API probes carry the properties that make them work ==="
# No `| head -N` here: it would close the pipe early and put this file on the
# EPIPE-under-pipefail axis `early-exit-readers.sh` tracks (#622). Each pattern
# occurs exactly once in the skill — asserted below rather than assumed, since
# a second occurrence would silently widen these windows and every structural
# assertion in this section would then be reading the wrong bytes.
issue_line=$(grep -A2 'gh issue list --repo "\$REPO"' <<<"$skill_txt")
pr_line=$(grep -A3 'gh pr list --repo "\$REPO"' <<<"$skill_txt")
assert_eq "the issue probe appears exactly once in the skill" \
    "$(grep -c 'gh issue list --repo "\$REPO"' <<<"$skill_txt")" "1"
assert_eq "the PR probe appears exactly once in the skill" \
    "$(grep -c 'gh pr list --repo "\$REPO"' <<<"$skill_txt")" "1"

assert_contains "(a) searches CLOSED issues too (--state all)" "$issue_line" '--state all'
assert_contains "(a) searches the BODY, not the title alone" "$issue_line" '.title + \" \" + .body'
assert_contains "(b) matches an exact PATH, not PR text (--json …,files)" "$pr_line" 'files'
assert_contains "(b) selects ON that path" "$pr_line" '.files[].path'
# The gap that makes (b) necessary at all must be stated, or a later reader
# deletes it as redundant with (a).
assert_contains "the skill says WHY (b) is not redundant: issue list excludes PRs" \
    "$skill_txt" 'does NOT return PRs'
# And the gap that makes (c) necessary.
assert_contains "the skill says WHY (c) is not redundant: work with no PR at all" \
    "$skill_txt" 'never submitted'

# The falsifiable direction. Each names a WRONG form that would look right in
# review and quietly halve the probe.
assert_not_contains "(a) is not scoped to OPEN issues (a closed duplicate is still the answer)" \
    "$issue_line" '--state open'
assert_not_contains "(b) does not select on PR TEXT — that is (a)'s job and it misses paths" \
    "$pr_line" 'select(.title'

# ---- §3 probe (c), EXECUTED against a fixture ---------------------------
echo "=== §3 the branch probe, extracted from the skill and run ==="

# Extract the fenced block between the markers. Anchored on the markers rather
# than on "the first ```zsh after check 5" so that adding an example above it
# cannot silently re-point the extraction at different bytes.
snippet=$(awk '/BEGIN SELF-FIX-TRACKER-SEARCH/{f=1;next} /END SELF-FIX-TRACKER-SEARCH/{f=0} f' <<<"$skill_txt" \
            | sed -n '/^   ```zsh$/,/^   ```$/p' | sed '1d;$d' | sed 's/^   //')
assert_eq "the marked block extracted a non-empty snippet" \
    "$([[ -n "$snippet" ]] && echo yes || echo no)" "yes"

# Isolate loop (c). Everything from the `for b in` line to its `done`.
loop=$(awk '/^for b in /{f=1} f{print} f && /^done$/{exit}' <<<"$snippet")
assert_eq "loop (c) isolated from the snippet" \
    "$([[ "$loop" == *'for b in '* && "$loop" == *$'\ndone' ]] && echo yes || echo no)" "yes"
# NON-VACUITY: the three moving parts must actually be in the extracted bytes,
# or §3's green certifies a loop that filters nothing.
assert_contains "…and it carries the merged-branch filter" "$loop" 'merge-base --is-ancestor'
assert_contains "…and the file-count cap" "$loop" '-gt 60'
assert_contains "…and it diffs against origin/dev, not HEAD" "$loop" 'origin/dev...'

# ---- the fixture ---------------------------------------------------------
#
# Four remote branches modelling every arm the loop has:
#   feature-hit   — 1 file, the target path, NOT merged      -> must be found
#   feature-miss  — 1 file, a different path, NOT merged     -> must not
#   already-in    — merged into dev                          -> must not
#   mirror-root   — 80 unrelated files incl. the target path -> must not
#
# `mirror-root` is the arm that matters and it is drawn from a measurement,
# not invented: on the real repo, `gh-pages` (755 files vs dev),
# `public-mirror-squash-v2` (574) and `strip-institutional` (241) each match
# EVERY path you ask about. Three confident false positives around one true
# hit is how a probe teaches the reader to skim its output.
FIX="$WORK/repo"
TARGET=monitor/force-push-check.sh
(
    set -e
    mkdir -p "$FIX"; cd "$FIX"
    git init -q .
    git config user.email t@t; git config user.name t
    git config commit.gpgsign false
    mkdir -p monitor
    echo base > "$TARGET"; echo base > monitor/other.sh
    git add -A; git commit -qm base
    git branch -M dev

    git checkout -qb feature-hit
    echo changed >> "$TARGET"; git commit -qam hit

    git checkout -q dev; git checkout -qb feature-miss
    echo changed >> monitor/other.sh; git commit -qam miss

    git checkout -q dev; git checkout -qb already-in
    echo merged >> monitor/other.sh; git commit -qam merged
    git checkout -q dev; git merge -q --no-ff -m merge already-in

    git checkout -q dev; git checkout -qb mirror-root
    for i in $(seq 1 80); do printf 'x\n' > "f$i.txt"; done
    echo mirror >> "$TARGET"
    git add -A; git commit -qm mirror

    git checkout -q dev
    # Present the branches as remote refs, which is what the loop enumerates.
    for b in feature-hit feature-miss already-in mirror-root dev; do
        git update-ref "refs/remotes/origin/$b" "refs/heads/$b"
    done
) >/dev/null 2>&1 || th_abort "could not build the git fixture"

# Run the EXTRACTED loop. `git fetch --prune origin` is dropped: the fixture
# has no remote, and the loop's own text carries the fetch as a separate line
# above it (asserted below) precisely because it is a distinct step.
run_probe() (
    cd "$FIX" || return 1
    BASENAME="$1"
    export BASENAME
    # shellcheck disable=SC2086
    eval "$loop" 2>/dev/null | sed 's/^ *//' | sort
)

got=$(run_probe force-push-check.sh)
assert_eq "(c) finds the unmerged branch that touches the path" \
    "$(grep -c '^origin/feature-hit$' <<<"$got")" "1"
assert_eq "(c) does NOT report a branch touching a different path" \
    "$(grep -c '^origin/feature-miss$' <<<"$got")" "0"
assert_eq "(c) does NOT report a branch already merged into dev" \
    "$(grep -c '^origin/already-in$' <<<"$got")" "0"
assert_eq "(c) does NOT report the 80-file mirror root that touches everything" \
    "$(grep -c '^origin/mirror-root$' <<<"$got")" "0"
assert_eq "(c) reports exactly one branch for this path" \
    "$(grep -c . <<<"$got")" "1"

# NEGATIVE CONTROL on the cap: with the cap removed the mirror root DOES
# surface. Without this, all four assertions above pass for a loop whose cap
# is set so low it rejects everything, and "0 false positives" would be
# indistinguishable from "0 results".
loop_nocap=${loop//-gt 60/-gt 100000}
got_nocap=$( cd "$FIX" && BASENAME=force-push-check.sh eval "$loop_nocap" 2>/dev/null | sed 's/^ *//' | sort )
assert_eq "control: REMOVING the file-count cap resurrects the mirror-root false positive" \
    "$(grep -c '^origin/mirror-root$' <<<"$got_nocap")" "1"

# THE ANCESTOR FILTER IS A COST FILTER, NOT A CORRECTNESS ONE — measured, and
# recorded here because the obvious control CANNOT FIRE and writing one that
# looked like it did would be the vacuity this file is built to refuse.
#
# I expected `merge-base --is-ancestor` to be what keeps an already-merged
# branch out of the results. It is not. A three-dot diff `origin/dev...B` is
# "what changed on B since the merge base", and when B is an ancestor of dev
# the merge base IS B, so the diff is empty and the branch drops out on the
# next line anyway. Removing the filter therefore leaves the ANSWER identical
# and only makes the loop do a full `git diff` per merged ref — on 279 refs
# that is most of the runtime. So the property to pin is EQUALITY, not a
# resurrected false positive.
loop_noanc=$(sed 's/.*merge-base --is-ancestor.*//' <<<"$loop")
got_noanc=$( cd "$FIX" && BASENAME=force-push-check.sh eval "$loop_noanc" 2>/dev/null | sed 's/^ *//' | sort )
assert_eq "the merged-branch filter is an OPTIMISATION: dropping it changes no result" \
    "$got_noanc" "$got"
assert_eq "…and the already-merged branch is excluded either way (by the empty diff)" \
    "$(grep -c '^origin/already-in$' <<<"$got_noanc")" "0"

# The fetch is a SEPARATE line and must stay: refs/remotes is the local store,
# so an unfetched clone answers about whenever it last synced — the #814 trap,
# which is the same class of confident-wrong-zero this whole check exists for.
assert_contains "the snippet fetches before reading refs/remotes" "$snippet" 'git fetch --prune origin'

# ---- assertion-count guard ----------------------------------------------
EXPECTED_ASSERTIONS=27
TOTAL=$(( PASS + FAIL ))
if (( TOTAL != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count %d != expected %d — an assertion was silently dropped\n' \
        "$TOTAL" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
fi

th_summary_and_exit
