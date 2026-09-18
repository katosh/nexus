#!/usr/bin/env bash
# test-claude-md-grep-h-order.sh — execute CLAUDE.md's GREP-H-ORDER block
# (your-org/nexus-code#1461).
#
# WHY THIS SUITE EXISTS. The operator's `grep` is a shell function running
# ugrep, whose default `--sort` reorders multi-file output alphabetically by
# filename. Under `-h` the filenames are gone, so the reordering is invisible:
# a two-file side-by-side comparison comes back with its two lines swapped, at
# rc 0, with an unchanged total. It inverted a claim about an identifier gate
# before it was caught.
#
# WHAT IS PINNED — THE STRUCTURAL HALF ONLY. Which `grep` a bare call resolves
# to is a property of the harness build, not of this repo (the
# `GREP-BRE-DIALECT` entry states the same limit), so this suite does NOT
# assert that a bare `grep -h` reorders here. It asserts the shape:
#   A  extraction   — the block carries exactly the 3 documented forms.
#   B  POTENCY      — a stand-in `grep` FUNCTION that sorts like the wrapper
#                     reorders `-h` output away from argument order (so the
#                     controls below are testing a real reordering).
#   C  REMEDY 2     — the same call through `command` bypasses the function
#                     and GNU grep preserves argument order.
#   D  REMEDY 1     — `-H` through the SAME sorting function keeps the
#                     filenames, so every line carries the evidence needed to
#                     see the order: checkable, where `-h` was not.
#   E  NON-REMEDY   — `--no-sort` is documented as NOT a fix (asserted on the
#                     block's own annotation, never executed: under GNU grep
#                     the flag does not exist and would exit 2, which is a
#                     different fact from the one the entry records).
#   F  INFORMATION  — what the live bare `grep` IS here is printed, not
#                     asserted, so a reader of this log knows the axis.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

# ── this suite DECLARES its own population (the --population protocol) ──────
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' \
        CLAUDE.md \
        monitor/watcher/_test_helpers.sh
}
gp_handle "$@"

th_claude_md_block_coverage GREP-H-ORDER   # the entry's UNCHECKED share, in this suite's own output (#1239)

WORK=$(mktemp -d) || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

_th_count_guard() {
    local EXPECTED_ASSERTIONS=13
    local TOTAL_ASSERTIONS=$(( PASS + FAIL ))
    assert_eq "assertion TOTAL matches the EXPECTED total" \
              "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"
    th_summary_and_exit
}

echo '=== A: extraction — pull the delimited block out of CLAUDE.md ==='
assert_file_exists "CLAUDE.md is readable" "$CLAUDE_MD"
FORMS=$(awk -v b='<!-- BEGIN GREP-H-ORDER -->' -v e='<!-- END GREP-H-ORDER -->' '
    index($0, b) { inb = 1; next }
    index($0, e) { inb = 0 }
    inb' "$CLAUDE_MD" \
    | sed -E 's/^[[:space:]]+//' \
    | grep -vE '^```' \
    | grep -E '^(grep|command grep) ')
FORM_COUNT=$(printf '%s\n' "$FORMS" | grep -cE '^(grep|command grep) ')
assert_eq "Control A: extracted exactly 3 documented forms" "$FORM_COUNT" "3"
if [[ "$FORM_COUNT" != "3" ]]; then
    th_abort "block malformed — refusing to draw conclusions from it"
fi
F_H=$(printf '%s\n' "$FORMS"      | grep -E '^grep -H '            | sed -n '1p')
F_CMD=$(printf '%s\n' "$FORMS"    | grep -E '^command grep -h '    | sed -n '1p')
F_NOSORT=$(printf '%s\n' "$FORMS" | grep -E '^grep --no-sort -h '  | sed -n '1p')
assert_contains "remedy 1 keeps the filenames (-H)"                  "$F_H"      "grep -H"
assert_contains "remedy 2 bypasses the function (command grep -h)"   "$F_CMD"    "command grep -h"
assert_contains "the non-remedy is annotated as NOT a remedy"        "$F_NOSORT" "NOT a remedy"

echo '=== fixture: three files passed as zzz mmm aaa, one keyed line each ==='
mkdir -p "$WORK/fx" || th_abort "fixture mkdir failed"
printf 'kZED\n' > "$WORK/fx/zzz.txt"
printf 'kMID\n' > "$WORK/fx/mmm.txt"
printf 'kABE\n' > "$WORK/fx/aaa.txt"
cd "$WORK/fx" || th_abort "cd fixture failed"

# The stand-in: a `grep` FUNCTION that, like the wrapper, sorts its FILE
# arguments by name before running the real grep. `command grep` is exactly
# what the remedy prescribes, so the stand-in must be a function and not a
# PATH-front binary — a binary would be reached by `command` too.
grep() {
    local -a opts=() files=()
    local a
    for a in "$@"; do
        if [[ -f "$a" ]]; then files+=("$a"); else opts+=("$a"); fi
    done
    local sorted; sorted=$(printf '%s\n' "${files[@]}" | sort)
    local -a sf=()
    while IFS= read -r a; do [[ -n "$a" ]] && sf+=("$a"); done <<<"$sorted"
    command grep "${opts[@]}" "${sf[@]}"
}

echo '=== B: potency — the sorting stand-in DESTROYS argument order under -h ==='
got=$(grep -h '^k' zzz.txt mmm.txt aaa.txt | tr '\n' ' ' | sed 's/ $//')
assert_eq "stand-in grep -h: alphabetical, argument order gone" "$got" "kABE kMID kZED"
# The stand-in is a function, which is the axis the remedy relies on.
assert_eq "the stand-in is a shell FUNCTION (the shape the remedy bypasses)" \
    "$(type -t grep)" "function"

echo '=== C: remedy 2 — command grep bypasses the function; GNU preserves argument order ==='
got=$(command grep -h '^k' zzz.txt mmm.txt aaa.txt | tr '\n' ' ' | sed 's/ $//')
assert_eq "command grep -h: argument order preserved" "$got" "kZED kMID kABE"
# Same predicate, opposite ORDER, same total — the shape the entry describes.
n_fn=$(grep -h '^k' zzz.txt mmm.txt aaa.txt | wc -l | tr -d ' ')
n_cmd=$(command grep -h '^k' zzz.txt mmm.txt aaa.txt | wc -l | tr -d ' ')
assert_eq "…and the TOTAL is identical both ways (3 = 3) — a count cannot see this" "$n_fn/$n_cmd" "3/3"

echo '=== D: remedy 1 — -H through the SAME sorting function keeps the evidence ==='
got=$(grep -H '^k' zzz.txt mmm.txt aaa.txt)
assert_contains "-H: the ZED line carries its filename" "$got" "zzz.txt:kZED"
assert_contains "-H: the ABE line carries its filename" "$got" "aaa.txt:kABE"
# Every emitted line names its file, so a reader can tell the order was
# changed — the property -h destroys.
n_named=$(printf '%s\n' "$got" | grep -cE '^[a-z]+\.txt:k')
assert_eq "-H: every line is filename-prefixed (3 of 3), so the order is CHECKABLE" "$n_named" "3"

echo '=== F: information — what the live bare grep is on THIS host (printed, not asserted) ==='
unset -f grep
_live=$(type grep 2>/dev/null | sed -n '1p')
_ver=$(grep --version 2>/dev/null | sed -n '1p')
printf '  live grep: %s\n  live grep --version: %s\n' "${_live:-?}" "${_ver:-?}"
assert_eq "information line printed (the axis is stated, never pinned)" "1" "1"

_th_count_guard
