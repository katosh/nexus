#!/usr/bin/env bash
# nullglob-bare-form.sh — enumerate every site in this repo that pairs a
# possibly-empty GLOB with a command that has a MEANINGFUL BARE FORM, so the
# boundary is CHECKABLE rather than asserted in a commit message.
# your-org/nexus-code#1214 S1.
#
# Usage:  bash monitor/watcher/nullglob-bare-form.sh [--files|--locate] [<repo-root>]
#   default   one row per site, and these five columns ARE the manifest's five
#             KEY columns, in order:
#                 <file>\t<normalized-line>\t<occurrence>\t<command>\t<glob>
#             That identity is the point: the guard compares `cut -f1-5` of
#             this output against `cut -f1-5` of the manifest, so there is one
#             definition of a key and not two.
#   --locate  the same three key columns plus the site's CURRENT LINE NUMBER:
#                 <file>\t<normalized-line>\t<occurrence>\t<line>
#             Diagnostics ONLY. The line number is deliberately NOT recorded in
#             the manifest -- it is the thing that moved -- but a human reading
#             a red still needs to be told where to look, so the guard joins
#             against this to print `file:line` beside every added/removed key.
#   --files   the POPULATION -- one path per line, every file this classifier
#             reads. Exists so the guard's `gp_population` can call THIS
#             enumerator rather than keep a second copy of it: a copy is a
#             second implementation of the population, and a second
#             implementation drifts until the index reports, with total
#             confidence, that a guard does not read a file it does read.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS, AND WHY PROSE WAS NOT ENOUGH
#
# `#1214` D1 found `ls "$FIX_DIR"/blocked-*.ansi 2>/dev/null | head -1` under a
# file-level `shopt -s nullglob`. When the glob matches nothing it VANISHES
# rather than staying literal, so `ls` runs BARE, lists the CURRENT WORKING
# DIRECTORY, and `head -1` takes its first entry. Measured: the assertion ran
# against `CHANGELOG.md`, and the honest `else` SKIP branch was unreachable
# whenever the cwd is non-empty — which it always is.
#
# That instance was fixed and an enumeration was written into a commit message.
# A count in a commit message closes NEITHER the class NOR its instances:
# nothing fails when site N+1 appears, and the knowledge sits where no future
# author will read it. This file is that enumeration made executable.
#
# ---------------------------------------------------------------------------
# THE AXIS, STATED SO IT CAN BE DISAGREED WITH
#
#   1. THE PAIRING IS THE AXIS — not `ls `, and not a glob spelling. A vanishing
#      glob is HARMLESS beside a command that ERRORS with no arguments (`stat`,
#      `rm`, `chmod`): the command complains and you find out. It is a DEFECT
#      beside a command that does something MEANINGFUL with none — `ls`/`du`
#      act on the CWD, `cat`/`grep`/`wc`/`sort` read STDIN. Only the second kind
#      converts a vanished glob into a confident wrong answer.
#
#   2. THE POPULATION IS SHELL-WIDE, NOT THE FILES THAT CARRY THE `shopt`.
#      `#1214`'s first enumeration scoped itself to "the files under monitor/
#      that set nullglob" -- and got that number wrong too, saying 14 where the
#      answer is 15, because its `*.sh` pathspec could not see `monitor/ng`, a
#      shell file by SHEBANG that holds three of the sites. It then
#      UNDER-COUNTED again for a reason its own skeptic
#      demonstrated: `nullglob` is a SHELL option, so it reaches SOURCED code
#      that never mentions it. A library sourced by a nullglob-setting caller is
#      exposed while containing no `shopt` at all. So the population here is
#      every git-tracked shell file under `monitor/`, decided by the SHARED
#      predicate `monitor/shell-files.sh:shf_is_shell` rather than by a fourth
#      local implementation of "is this a shell file" (`#792`, `#775`).
#
#   3. QUOTED SPANS ARE BLANKED before matching, because a `*` inside a `sed`
#      or `grep` PATTERN is not a pathname glob. That single distinction is the
#      difference between 33 raw regex hits and the real sites, and skipping it
#      would bury the signal under its own false positives.
#
# ---------------------------------------------------------------------------
# THE KEY IS CONTENT, NOT A LINE NUMBER
#
# The manifest used to key each site by `<file>:<LINE>`. That is load-bearing on
# a number that MOVES, and it broke silently across a merge: `#1238` inserts ONE
# line at `monitor/ng:548`, the three rows recorded at 1316/1326/1329 shift to
# 1317/1327/1330, and this guard reports three NEW sites and three REMOVED ones
# for a tree in which nothing was added or removed. Neither PR touches the
# other's file, so there is no textual overlap and therefore NO diff-level trace
# of the dependency -- the two merge cleanly, rc 0 both times, and the guard is
# the only thing that disagrees.
#
# So the key is `<file>` + `<normalized source line>` + `<occurrence ordinal>`:
#
#   * NORMALIZED LINE -- the raw source text with whitespace runs collapsed to a
#     single space and the ends trimmed. Insensitive to insertion elsewhere in
#     the file and to reindentation; sensitive to a change in the site's own
#     text, which is when a recorded disposition should stop being trusted.
#
#   * OCCURRENCE -- 1-based, among sites in the SAME file with the SAME
#     normalized line, ascending by line number. Needed because identical lines
#     are common here: measured at 73 sites, 41 distinct (file, line) pairs and
#     36 sites inside just four duplicate groups (13, 13, 5, 5). It is 1 for the
#     other 37, and 1 for every site carrying a `defect` or `safe` verdict.
#
# WHAT WOULD STILL BREAK IT, because a key with an unstated failure mode is the
# defect being removed:
#
#   1. ORDINAL CHURN -- and the red MIS-NAMES the site. Inserting or deleting a
#      BYTE-IDENTICAL site above its identical siblings shifts their ordinals.
#      An earlier version of this line called the resulting red "attributable,
#      because the offending line is in that file's own diff". Measured, it is
#      not (`#1214` sk F1): one identical sibling inserted above
#      `test-respawn.sh:154` reds naming line **1638**, the LAST sibling, 1,484
#      lines away, while the shifted dispositions re-attribute SILENTLY. Because
#      no content-derived key can distinguish members of a duplicate group, the
#      guard REFUSES to hold a reviewed verdict inside one (8/8 singletons
#      today). See the manifest header for the full measurement.
#   2. FILE RENAME rekeys every row in the file, exactly as before.
#   3. DELETE+ADD OF AN IDENTICAL SITE (net-zero). Moving one of N identical
#      lines into a different function leaves file, normalized line and the
#      ordinal SET unchanged, so the guard stays GREEN while the CALL PATH
#      changed. This is INHERENT to content-derivation: identical text is
#      indistinguishable, and line-keying did not close it either (swapping two
#      identical sites leaves the same set of line-keys occupied). It is the
#      bound, not a regression.
#
# And the bound that no key of any kind can carry: a `safe (b)` verdict is a
# claim about REACHABILITY, not about text. A stable key tells you the text is
# unchanged; it never revalidates the argument.
#
# ---------------------------------------------------------------------------
# WHAT THIS DOES NOT DECIDE. Whether a given glob CAN actually match nothing is
# a question about the tree at runtime, not about the source, and this
# classifier does not pretend to answer it. It enumerates the PAIRING; the
# per-site verdict lives in `nullglob-bare-form.manifest` and is a human's.
# A row's presence is therefore not an accusation — an unreviewed row says
# exactly that.

set -uo pipefail

_gen_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MODE=""
case "${1:-}" in
    --files|--locate) MODE="$1"; shift ;;
esac
ROOT="${1:-$(cd "$_gen_dir/../.." && pwd)}"
AWKF="$_gen_dir/_nullglob_bare_form.awk"
[[ -r "$AWKF" ]] || { echo "classifier missing: $AWKF" >&2; exit 1; }

# shellcheck disable=SC1091
. "$ROOT/monitor/shell-files.sh" 2>/dev/null || {
    echo "cannot source monitor/shell-files.sh — the population predicate is shared, not re-implemented" >&2
    exit 1
}
declare -F shf_is_shell >/dev/null || {
    echo "shf_is_shell not defined after sourcing shell-files.sh" >&2; exit 1; }

cd "$ROOT" || exit 1

_ngbf_population() {
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        [[ -f "$f" ]] || continue
        shf_is_shell "$f" || continue
        printf '%s\n' "$f"
    done < <(git ls-files -- monitor 2>/dev/null)
}

if [[ "${MODE:-}" == "--files" ]]; then
    _ngbf_population | LC_ALL=C sort
    exit 0
fi

# One row per site. The OCCURRENCE ordinal is counted per file, in ascending
# line order (which is the order awk emits), over the NORMALIZED LINE. `seen` is
# reset per file, so an ordinal is never global and a change in one file cannot
# renumber another.
_ngbf_emit() {
    local f ln cmd tok nl occ
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        [[ -f "$f" ]] || continue
        shf_is_shell "$f" || continue
        local -A seen=()
        while IFS=$'\t' read -r ln cmd tok nl; do
            [[ -n "$ln" ]] || continue
            occ=$(( ${seen["$nl"]:-0} + 1 ))
            seen["$nl"]=$occ
            if [[ "$MODE" == "--locate" ]]; then
                printf '%s\t%s\t%s\t%s\n' "$f" "$nl" "$occ" "$ln"
            else
                printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$nl" "$occ" "$cmd" "$tok"
            fi
        done < <(awk -f "$AWKF" "$f" 2>/dev/null)
        unset seen
    done < <(git ls-files -- monitor 2>/dev/null)
}

_ngbf_emit | LC_ALL=C sort
