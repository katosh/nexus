#!/usr/bin/env bash
# subshell-exit-guards.sh — enumerate every site in this repo where a command
# word that CAN TERMINATE THE SHELL is evaluated inside a SUBSHELL, so the
# boundary is CHECKABLE rather than asserted in a commit message.
# your-org/nexus-code#1339.
#
# Usage:  bash monitor/watcher/subshell-exit-guards.sh [--files|--locate|--terminators] [<repo-root>]
#   default        one row per site; these five columns ARE the manifest's five
#                  columns, in order:
#                      <file>\t<normalized-line>\t<occurrence>\t<word>\t<chain>
#                  Fields 1-3 are the KEY, 4-5 the extraction. The guard
#                  compares `cut -f1-3` of this against `cut -f1-3` of the
#                  manifest, so there is ONE definition of a key, not two.
#   --locate       the key columns plus the site's CURRENT line number and
#                  enclosing function. DIAGNOSTICS ONLY — the line number is
#                  deliberately NOT in the manifest, it is the thing that moves
#                  (`#1214`: one inserted line elsewhere rekeyed three rows and
#                  the guard reported 3 added / 3 removed for an unchanged tree).
#   --terminators  <file>\t<function>\t<chain> for every function the fixpoint
#                  found can terminate the shell. The ANSWER TO "did you assume
#                  `die` is the only one" — it is derived, never listed.
#   --files        the POPULATION: one path per line, every file this
#                  classifier reads. Exists so the guard's `gp_population` can
#                  call THIS enumerator rather than keep a second copy, because
#                  a copy is a second implementation and a second
#                  implementation drifts until the index reports, with total
#                  confidence, that a guard does not read a file it does read.
#
# ---------------------------------------------------------------------------
# THE DEFECT
#
# `monitor/jupyter-up.sh` (on `operator/w2-15-reg`) gained a fail-closed guard
# `_registry_must_be_readable`, which `die`s — and `die` is `exit 1`. It is
# reached ONLY through two lookup helpers whose callers invoke them in a
# command substitution, so the `exit` terminated the SUBSHELL:
#
#     --down    refusal printed, then "stopping any bare labsh server
#               anyway"                                             rc 0
#     --status  "(unregistered)  healthy  supervisor:-"             rc 0
#
# The guard RAN, DECIDED CORRECTLY, PRINTED ITS REFUSAL, AND DID NOT GATE. It
# is invisible to `bash -n` (the syntax is valid), to a unit test that calls
# the function directly (in isolation it exits correctly), and to review (it
# reads exactly like a guard). It fails OPEN with a reassuring diagnostic.
#
# ---------------------------------------------------------------------------
# WHY THIS IS NOT A grep, AND WHY THE ISSUE REFUSED TO QUOTE A COUNT
#
# `grep 'die' | grep '\$('` over-counts wildly and UNDER-COUNTS SILENTLY. The
# measured instance's `die` is two levels below the substituted word:
#
#     name=$(_registry_name_for_workdir "$PROJECT_DIR") || name='(unregistered)'
#       _registry_name_for_workdir() { _registry_must_be_readable; … }
#         _registry_must_be_readable() { … || die "…" }
#           die() { echo … >&2; exit 1; }
#
# The substituted word is neither `die` nor `exit`. So the predicate here is a
# CALL GRAPH with a least fixpoint over "can terminate the shell", crossed with
# a quote-aware, nesting-aware notion of "is this word evaluated in a
# subshell". `_subshell_exit_scan.py` is that machine; this file is its
# population and its output contract.
#
# ---------------------------------------------------------------------------
# WHAT THIS DOES NOT DECIDE, stated because a row is NOT an accusation
#
# A subshell `exit` is a DEFECT only when the exit was the gate. It is
# perfectly correct when the caller checks the substitution's status
# (`x=$(f) || die …`), when the subshell IS the unit of work (`( flock -w 10 9
# || exit 9; … )`), or when the function's exit is incidental to a value it
# returns. Deciding which is a human's job, and the verdict lives in
# `subshell-exit-guards.manifest` (`defect | safe | unreviewed`). An
# `unreviewed` row says exactly that and nothing more.

set -uo pipefail

_gen_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MODE=""
case "${1:-}" in
    --files|--locate|--terminators) MODE="$1"; shift ;;
esac
ROOT="${1:-$(cd "$_gen_dir/../.." && pwd)}"
CORE="$_gen_dir/_subshell_exit_scan.py"
[[ -r "$CORE" ]] || { echo "classifier missing: $CORE" >&2; exit 1; }

# shellcheck disable=SC1091
. "$ROOT/monitor/shell-files.sh" 2>/dev/null || {
    echo "cannot source monitor/shell-files.sh — the population predicate is shared, not re-implemented" >&2
    exit 1
}
declare -F shf_is_shell >/dev/null || {
    echo "shf_is_shell not defined after sourcing shell-files.sh" >&2; exit 1; }

cd "$ROOT" || exit 1

# THE SHARED PREDICATE, NOT A `*.sh` GLOB. `monitor/ng` is a shell file by
# SHEBANG with no extension and is this repo's main CLI; a `*.sh` pathspec
# misses it, and `#1214` got a count wrong for exactly that reason.
_seg_population() {
    local f
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        [[ -f "$f" ]] || continue
        shf_is_shell "$f" || continue
        printf '%s\n' "$f"
    done < <(git ls-files -- monitor 2>/dev/null)
}

if [[ "${MODE:-}" == "--files" ]]; then
    _seg_population | LC_ALL=C sort
    exit 0
fi

# THE PRODUCER'S RC IS TESTED. `#935` mode 2: a python producer that dies
# leaves an EMPTY or TRUNCATED intermediate whose rc nothing consults, and the
# count is then produced by later steps that each succeed on their own terms.
# Here the intermediate is a file and its rc is read on the very next line.
_seg_list=$(mktemp -t seg-pop-XXXXXX) || exit 1
_seg_out=$(mktemp -t seg-out-XXXXXX) || { rm -f "$_seg_list"; exit 1; }
trap 'rm -f "$_seg_list" "$_seg_out"' EXIT
_seg_population > "$_seg_list"
if [[ ! -s "$_seg_list" ]]; then
    echo "subshell-exit-guards: population is EMPTY — refusing to report a" >&2
    echo "  clean sweep over a corpus this enumerator did not produce." >&2
    exit 3
fi

case "$MODE" in
    --locate)      export SEG_MODE=locate ;;
    --terminators) export SEG_MODE=terminators ;;
    *)             export SEG_MODE=sites ;;
esac
python3 "$CORE" "$ROOT" "$_seg_list" > "$_seg_out"
_seg_rc=$?
if (( _seg_rc != 0 )); then
    echo "subshell-exit-guards: scanner failed (rc $_seg_rc) — refusing to" >&2
    echo "  report a result it did not successfully produce." >&2
    exit 3
fi
LC_ALL=C sort "$_seg_out"
