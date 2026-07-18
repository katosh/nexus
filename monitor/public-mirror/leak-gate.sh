#!/usr/bin/env bash
# leak-gate.sh — fail (nonzero) if any denied internal token survives in the
# tracked tree. Patterns are read from the mapping file (`deny`/`keep` lines);
# this script hardcodes NO identifiers, so its own public copy is clean.
#
#   leak-gate.sh <mapping.tsv> [<repo-dir>]
#
# Exit 0 = clean. Exit 1 = leak (offending lines printed).
set -uo pipefail
export LC_ALL=C
MAP="${1:?usage: leak-gate.sh <mapping.tsv> [repo-dir]}"
DIR="${2:-.}"
cd "$DIR"

DENY=$(awk -F'\t' '$1=="deny"{print $2}' "$MAP" | paste -sd'|')
KEEP=$(awk -F'\t' '$1=="keep"{print $2}' "$MAP" | paste -sd'|')
[ -n "$DENY" ] || { echo "leak-gate: empty denylist in $MAP" >&2; exit 2; }

# Dictionary guard: the `exclude` paths hold the ONE un-scrubbed copy of the
# internal dictionary (it names every source identifier by design). It must
# never appear in a tree bound for publication. build.sh drops it; this is the
# independent second check so the gate catches a leaked dictionary even when run
# on a hand-assembled tree. (your-org/nexus-code#537)
excl_present=0
while IFS= read -r ex; do
    [ -n "$ex" ] || continue
    if [ -e "$ex" ]; then
        echo "LEAK GATE: FAIL — excluded internal-dictionary path present: $ex"
        excl_present=$((excl_present+1))
    fi
done < <(awk -F'\t' '$1=="exclude"{print $2}' "$MAP")
[ "$excl_present" -eq 0 ] || exit 1

hits=$(git grep -inE "$DENY" -- . 2>/dev/null)
# also scan any file present but untracked (a hand-assembled tree may not be a
# git checkout); fall back to a plain recursive grep when git-grep finds nothing
if [ -z "$hits" ] && ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    hits=$(grep -rinE "$DENY" --exclude-dir=.git . 2>/dev/null)
fi
[ -n "$KEEP" ] && hits=$(printf '%s\n' "$hits" | grep -vE "$KEEP")
hits=$(printf '%s\n' "$hits" | sed '/^$/d')

if [ -n "$hits" ]; then
    echo "LEAK GATE: FAIL"
    printf '%s\n' "$hits"
    exit 1
fi
echo "LEAK GATE: PASS — zero denied tokens (keep-list applied)"
exit 0
