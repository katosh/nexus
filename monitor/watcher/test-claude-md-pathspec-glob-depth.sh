#!/usr/bin/env bash
# Executes the `git ls-files` pathspec-depth pair CLAUDE.md documents
# (your-org/nexus-code#954), on a PLANTED repo with a known layout and then
# against this repo's own HEAD.
#
# Run: bash monitor/watcher/test-claude-md-pathspec-glob-depth.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS SUITE EXISTS. CLAUDE.md's LSTREE-PATHSPEC entry teaches "ls-tree
# pathspecs are path PREFIXES, ls-files pathspecs are GLOBS" and prescribes
# `git ls-files -- '*.sh'`. It stops one step short: git's glob `*` CROSSES `/`
# (pathspecs are fnmatch WITHOUT FNM_PATHNAME by default), so `monitor/*.sh` is
# not "the .sh files in monitor/" — it is every .sh at any depth beneath it. A
# reader who learned the first half gets the right tool and the wrong scope, and
# the number that comes back is plausible. It produced a wrong published count
# in your-org/nexus-code#903 (`103 unguarded arms across 24 files`, built on a
# pathspec that swept in the entire test suite).
#
# The counts in that entry are TREE-DEPENDENT — measured 464/339 on #903's
# branch and 471/346 on dev the same day — so this suite DERIVES rather than
# pins them against the live tree, and pins only against a planted fixture whose
# layout it created itself.
#
# NON-VACUITY. "Both forms ran" proves nothing: on a FLAT repo the trapped and
# correct forms agree, and every assertion would pass while witnessing nothing.
# So:
#   Control A — the extracted command count is PINNED.
#   Control B — on the planted repo, the two forms must DISAGREE, by the exact
#               margin the planted layout creates.
#   Control C — the trapped form's exit status is asserted to be 0. The defect
#               is a wrong answer at SUCCESS, not an error.
#   Control D — the correct form is checked against an INDEPENDENT total (the
#               SHELL glob, which does not cross `/`), never against the thing
#               under test.
#   Control E — on the LIVE tree the two forms must still disagree, or the
#               documented trap has stopped being live and the entry is stale.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
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
th_claude_md_block_coverage PATHSPEC-GLOB-DEPTH   # the entry's UNCHECKED share, in this suite's own output (#1239)

WORK=$(mktemp -d -t nexus-pathspec-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# The documented block, extracted VERBATIM.
# ---------------------------------------------------------------------------
BLOCK="$WORK/block.txt"
awk '/<!-- BEGIN PATHSPEC-GLOB-DEPTH -->/{f=1;next} /<!-- END PATHSPEC-GLOB-DEPTH -->/{f=0} f' \
    "$CLAUDE_MD" | sed -n '/^[[:space:]]*```/,/^[[:space:]]*```/p' | sed '1d;$d' > "$BLOCK"

_CMDS=$(grep -cE '^[[:space:]]*git ' "$BLOCK")
if (( _CMDS == 3 )); then
    printf '  PASS: A the documented block yielded its 3 commands\n'; _th_pass
else
    printf '  FAIL: A extracted %d git commands from PATHSPEC-GLOB-DEPTH, expected 3 — the block moved or the markers broke\n' "$_CMDS" >&2
    _th_fail
fi

# ---------------------------------------------------------------------------
# A PLANTED repo, so the expected numbers are ones this suite created.
#   sub/a.sh sub/b.sh          -> 2 at depth 1 under sub/
#   sub/deep/c.sh sub/deep/nested/d.sh -> 2 deeper
# Trapped form must see 4; correct form must see 2.
# ---------------------------------------------------------------------------
FIX="$WORK/fixture"
mkdir -p "$FIX/sub/deep/nested"
: > "$FIX/sub/a.sh"; : > "$FIX/sub/b.sh"
: > "$FIX/sub/deep/c.sh"; : > "$FIX/sub/deep/nested/d.sh"
git -C "$FIX" init -q
git -C "$FIX" add -A >/dev/null 2>&1
git -C "$FIX" -c user.email=t@t -c user.name=t commit -qm f >/dev/null 2>&1

_trapped=$(git -C "$FIX" ls-files -- 'sub/*.sh' | wc -l)
# Capture git's OWN rc, unpiped. `_trapped_rc=$?` after the pipeline above would
# be `wc -l`'s status — always 0 — so Control C could never fail
# (your-org/nexus-code#928, a pipeline's status is its LAST command's). Asserting
# a constant is not a control.
git -C "$FIX" ls-files -- 'sub/*.sh' >/dev/null 2>&1
_trapped_rc=$?
_correct=$(git -C "$FIX" ls-files -- ':(glob)sub/*.sh' | wc -l)
_shell=$(cd "$FIX" && echo sub/*.sh | wc -w)

assert_eq "B the trapped form crosses / on the planted layout" "$_trapped" "4"
assert_eq "B …and the :(glob) form does not"                   "$_correct" "2"
assert_eq "C the trapped form exits 0 — a wrong answer at SUCCESS, not an error" "$_trapped_rc" "0"
assert_eq "D the correct form agrees with the SHELL glob (independent total)"    "$_correct" "$_shell"

# ---------------------------------------------------------------------------
# The LIVE tree. Numbers derived, never pinned — they move per tree, which is
# half of why the trap published a wrong figure.
# ---------------------------------------------------------------------------
_live_trapped=$(git -C "$REPO_ROOT" ls-files -- 'monitor/*.sh' | wc -l)
_live_correct=$(git -C "$REPO_ROOT" ls-files -- ':(glob)monitor/*.sh' | wc -l)
_live_shell=$(cd "$REPO_ROOT" && echo monitor/*.sh | wc -w)

if (( _live_trapped > _live_correct )); then
    printf '  PASS: E the trap is still live on this tree (%d vs %d)\n' "$_live_trapped" "$_live_correct"; _th_pass
else
    printf '  FAIL: E trapped=%d correct=%d — the forms agree, so this suite witnesses nothing here\n' \
        "$_live_trapped" "$_live_correct" >&2; _th_fail
fi
assert_eq "E …and the correct form matches the shell glob on the live tree" "$_live_correct" "$_live_shell"

# ---------------------------------------------------------------------------
# CONTROL F — EXECUTE THE BLOCK, do not merely count it.
#
# Controls A-E above ran commands this SUITE hardcodes; A only counted the
# block's lines. Measured: replacing the block's `:(glob)` form with the trapped
# one left this suite at 7/7 green. A block that is asserted ABOUT rather than
# RUN is prose, and prose cannot be made to fail — which is the whole reason
# CLAUDE.md's blocks are delimited in the first place.
#
# So each documented command is run verbatim against the live tree and checked
# against an INDEPENDENT oracle: the trapped and wide forms must equal the
# crossing count, and the correct form must equal the SHELL glob — never a
# number this suite also derived from git.
_n=0
while IFS= read -r _cmd; do
    [[ "$_cmd" =~ ^[[:space:]]*git[[:space:]] ]] || continue
    _n=$(( _n + 1 ))
    _got=$(cd "$REPO_ROOT" && eval "$_cmd" 2>/dev/null | wc -l)
    case "$_n" in
        1) assert_eq "F block line 1 (trapped) runs and crosses / — $_got" "$_got" "$_live_trapped" ;;
        2) assert_eq "F block line 2 (:(glob)) runs and matches the SHELL glob — $_got" "$_got" "$_live_shell" ;;
        3) assert_eq "F block line 3 (wide) runs and matches the crossing count — $_got" "$_got" "$_live_trapped" ;;
    esac
done < "$BLOCK"

# ---------------------------------------------------------------------------
# EXPECTED-COUNT GUARD.
#   1  A: the block extracted its commands
# + 4  B/C/D: the planted-layout pair, its rc, and the independent total
# + 2  E: the live-tree liveness check and its independent total
EXPECTED=$(( 1 + 4 + 2 + 3 ))   # +3: Control F executes each documented command
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
