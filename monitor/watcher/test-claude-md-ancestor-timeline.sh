#!/usr/bin/env bash
# Executes the ancestor-precondition check CLAUDE.md documents
# (your-org/nexus-code#804), against a purpose-built fixture repo.
#
# Run: bash monitor/watcher/test-claude-md-ancestor-timeline.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS SUITE EXISTS. `git show <ref>:<path>` answers "what did this tree
# contain", never "what happened in what order". Sample a value at several
# refs and the series LOOKS like history — but it is history only when each
# ref is an ancestor of the next. On divergent branches you get a well-formed
# series answering a different question, with nothing to notice: no error, no
# warning, and an output shape (a monotone count series) that reads as a
# narrative. It is the git member of this workspace's dominant family, and the
# most dangerous, because the other members return an obviously boring `0`
# while this one returns a STORY.
#
# It has already published a wrong mechanism: `#790`'s skeptic pass derived
# "`#791` fixed it and `#781`'s merge resurrected it" from a 3 → 0 → 0 → 1
# series across four unrelated branch tips, and the function being counted did
# not exist on `#791`'s branch at all. Retracted.
#
# WHAT IS ACTUALLY PINNED. Not "git behaves". The CHECK — that
# `git merge-base --is-ancestor` distinguishes the two topologies — and the
# CLAIM that the naive series is misleading on the divergent one. Both are
# executed here against a fixture whose true history is known by construction,
# so the expectation never comes from the thing under test.
#
# NON-VACUITY CONTROLS, because "the commands ran" proves nothing:
#   A — the extracted command count is PINNED at 2. A botched extraction
#       yielding zero commands would otherwise satisfy every assertion by
#       having none to make, which is `#618`'s own shape.
#   B — the POSITIVE control. A linear chain must be ACCEPTED (rc 0). Without
#       it, `--is-ancestor` returning nonzero unconditionally would pass the
#       negative assertion and the check would be worthless.
#   C — the naive series is asserted to be MISLEADING on the divergent pair —
#       i.e. the trap is reproduced, not merely guarded against. If a future
#       git made this impossible the suite goes red, which is the signal.
#   D — the WRONG reading exits 0. The defect is not that it fails; it is that
#       it SUCCEEDS while lying.
#
# COVERAGE BOUNDARY, on the axis the mechanism varies on: this pins GIT's
# reachability semantics, a property of the git BINARY, and the zsh line pins
# ZSH's history-modifier expansion, a property of the zsh BINARY. The zsh half
# SKIPS (loudly) where zsh is absent rather than passing silently — CI images
# vary and a silent skip is the failure this repo keeps meeting. NOT covered:
# `--is-ancestor` across grafted/shallow clones, where reachability is a
# property of the local object store rather than of the true history.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

WORK=$(mktemp -d -t nexus-ancestor-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

GITV=$(git --version 2>&1)

# ---- extract the documented block ---------------------------------------
echo '=== Extraction: pull the delimited block out of CLAUDE.md ==='
BEGIN_MARK='<!-- BEGIN ANCESTOR-TIMELINE -->'
END_MARK='<!-- END ANCESTOR-TIMELINE -->'

[[ -r "$CLAUDE_MD" ]] || th_abort "CLAUDE.md not readable at $CLAUDE_MD"
assert_file_exists "CLAUDE.md is readable" "$CLAUDE_MD"

FORMS=$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    index($0, b) { inb = 1; next }
    index($0, e) { inb = 0 }
    inb' "$CLAUDE_MD" \
    | sed -E 's/^[[:space:]]+//' \
    | grep -vE '^```' \
    | sed -E 's/[[:space:]]+#.*$//' \
    | grep -E '^git ')

# CONTROL A — pin the count. Under bash explicitly: this suite's interactive
# caller is zsh, where a `mapfile`-style read fails as an EMPTY ARRAY and a
# zero population reads as "everything passed".
n_forms=$(printf '%s\n' "$FORMS" | grep -c '^git ' || true)
assert_eq "extracted exactly 2 documented forms" "$n_forms" "2"
if (( n_forms != 2 )); then
    th_abort "extraction produced $n_forms form(s); refusing to draw conclusions from it"
fi
ANCESTOR_FORM=$(printf '%s\n' "$FORMS" | grep -F 'merge-base' | head -1)
SHOW_FORM=$(printf '%s\n' "$FORMS" | grep -F 'git show' | head -1)
assert_contains "form 1 is the ancestor check" "$ANCESTOR_FORM" "--is-ancestor"
assert_contains "form 2 is the braced git show" "$SHOW_FORM" '${ref}:${path}'

# ---- build the fixture ---------------------------------------------------
# Two topologies, one repo:
#
#     root ── mainline1 ── mainline2      (LINEAR: the #774 shape)
#        \
#         └── sidetrack                   (DIVERGENT: the #790 shape)
#
# `count.txt` carries a different value on each, so the naive cross-ref series
# is well-formed and non-monotonic — the exact thing that reads as a story.
echo
echo '=== Fixture: a divergent branch and a linear chain, known by construction ==='
FIX="$WORK/repo"
mkdir -p "$FIX/results" || th_abort "fixture mkdir failed"
(
    set -e
    cd "$FIX"
    git init -q .
    git config user.email t@example.invalid
    git config user.name  t
    git config commit.gpgsign false
    printf '3\n' > results/count.txt
    git add -A && git commit -qm root
    printf '0\n' > results/count.txt
    git add -A && git commit -qm mainline1
    printf '1\n' > results/count.txt
    git add -A && git commit -qm mainline2
    git branch -f sidetrack "$(git rev-list --max-parents=0 HEAD)"
    git checkout -q sidetrack
    printf '0\n' > results/count.txt
    git add -A && git commit -qm sidetrack-only
    git checkout -q -
) >/dev/null 2>&1 || th_abort "fixture repo construction failed"

ROOT=$(git -C "$FIX" rev-parse HEAD~2)
MAIN1=$(git -C "$FIX" rev-parse HEAD~1)
MAIN2=$(git -C "$FIX" rev-parse HEAD)
SIDE=$(git -C "$FIX" rev-parse sidetrack)
for v in ROOT MAIN1 MAIN2 SIDE; do
    [[ "${!v}" =~ ^[0-9a-f]{7,}$ ]] || th_abort "fixture ref $v did not resolve"
done

# ---- run the documented ancestor check -----------------------------------
echo
echo '=== The documented check, run verbatim from the block ==='
_run_ancestor() {   # $1 A · $2 B → echoes the rc
    A="$1" B="$2" FORM="$ANCESTOR_FORM" bash -c '
        cd "$0" || exit 99
        eval "$FORM"
        printf %s "$?"
    ' "$FIX"
}

# CONTROL B — the POSITIVE control. A linear chain must be accepted, or the
# negative below is satisfied by a check that always says no.
assert_eq "linear pair root→mainline1 ACCEPTED (rc 0)"   "$(_run_ancestor "$ROOT"  "$MAIN1")" "0"
assert_eq "linear pair mainline1→mainline2 ACCEPTED"     "$(_run_ancestor "$MAIN1" "$MAIN2")" "0"
# The negative: the divergent pair must be REJECTED, in both orders — neither
# tip reaches the other, which is precisely what makes the series meaningless.
rc_fwd=$(_run_ancestor "$MAIN2" "$SIDE")
rc_rev=$(_run_ancestor "$SIDE"  "$MAIN2")
[[ "$rc_fwd" != "0" ]] && _th_pass && printf '  PASS: divergent pair mainline2→sidetrack REJECTED (rc %s)\n' "$rc_fwd" \
    || { _th_fail; printf '  FAIL: divergent pair was ACCEPTED — the check cannot distinguish the topologies (%s)\n' "$GITV" >&2; }
[[ "$rc_rev" != "0" ]] && _th_pass && printf '  PASS: divergent pair sidetrack→mainline2 REJECTED (rc %s)\n' "$rc_rev" \
    || { _th_fail; printf '  FAIL: reverse divergent pair was ACCEPTED (%s)\n' "$GITV" >&2; }

# ---- CONTROL C+D: reproduce the trap itself ------------------------------
echo
echo '=== The trap: the naive series is well-formed, misleading, and exits 0 ==='
# Sample the SAME value across the four refs, exactly as #790 did. The series
# 3 → 0 → 0 → 1 reads as "fixed, then regressed". Its true content is: three
# unrelated trees and one descendant.
series=""
series_rc=0
for ref in "$ROOT" "$MAIN1" "$SIDE" "$MAIN2"; do
    v=$(git -C "$FIX" show "${ref}:results/count.txt" 2>/dev/null) || series_rc=1
    series="${series}${v} "
done
assert_eq "the naive cross-ref series is 3 0 0 1 — the shape that reads as a repair-then-regression" \
          "${series% }" "3 0 0 1"
# CONTROL D — it SUCCEEDS while lying. That is the whole danger.
assert_eq "every git show in the misleading series exited 0" "$series_rc" "0"
# …and the pair the story hinges on (0 → 1, "it came back") is not a timeline.
assert_eq "the 0→1 step that carries the story is NOT an ancestor pair (rc!=0 ⇒ reported as 1)" \
          "$( [[ "$(_run_ancestor "$SIDE" "$MAIN2")" == "0" ]] && echo 0 || echo 1 )" "1"

# ---- the braced git show, and the zsh hazard it guards -------------------
echo
echo '=== The braced form works; the unbraced form is a zsh history modifier ==='
out=$(ref="$MAIN2" path=results/count.txt FORM="$SHOW_FORM" bash -c '
    cd "$0" || exit 99
    eval "$FORM"
' "$FIX" 2>/dev/null)
assert_eq "documented braced form reads the file" "$out" "1"

_zsh_asserts=0
if command -v zsh >/dev/null 2>&1; then
    # The claim CLAUDE.md makes about this exact call shape applies the `:r`
    # modifier (remove extension) and yields a wrong-but-plausible path,
    # silently. Asserted on zsh's own expansion.
    #
    # Two lines below carry the hazardous literal ON PURPOSE — it is the
    # subject under test — so each exempts itself from
    # test-zsh-modifier-lint.sh IN PLACE, with a reason, on its OWN line (the
    # lint filters hit lines, so a marker on the preceding line exempts
    # nothing — that was this edit's first draft). NOT by adding this filename
    # to that lint's allowlist: a filename allowlist erodes silently and would
    # blind this whole file, including any REAL violation a later edit
    # introduces three hundred lines from here.
    z_bad=$(zsh -fc 'b=main; print -r -- "$b:results/count.txt"' 2>/dev/null || true)  # zsh-modifier-lint: allow-demonstration  executes the documented trap against real zsh
    z_good=$(zsh -fc 'b=main; print -r -- "${b}:results/count.txt"' 2>/dev/null || true)
    assert_eq "unbraced \"\$b:results/…\" is eaten by the :r modifier" "$z_bad"  "mainesults/count.txt"  # zsh-modifier-lint: allow-demonstration  the assertion label must quote the form it is about
    assert_eq "braced \"\${b}:results/…\" is intact"                  "$z_good" "main:results/count.txt"
    _zsh_asserts=2
else
    th_skip "zsh not present — the history-modifier half of this block is UNVERIFIED on this host"
    _zsh_asserts=0
fi

# EXPECTED-COUNT GUARD (your-org/nexus-code#807; required by
# test-summary-honesty-manifest.sh at the `ledger=yes` protection level).
# DERIVED, because the zsh half legitimately skips where zsh is absent — a
# pinned literal would either fail on such a host or, worse, be lowered to the
# skipping count and stop noticing a lost assertion on hosts that DO have zsh.
#   1  CLAUDE.md readable
# + 3  extraction (count pinned at 2, plus the two form assertions)
# + 4  ancestor check: 2 linear (accept) + 2 divergent (reject)
# + 3  the trap reproduced: series value, exit status, non-ancestor step
# + 1  the braced git show reads the file
# + 2  zsh modifier pair, ONLY when zsh is present
EXPECTED=$(( 1 + 3 + 4 + 3 + 1 + _zsh_asserts ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
