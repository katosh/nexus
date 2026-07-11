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

hits=$(git grep -inE "$DENY" -- . 2>/dev/null)
[ -n "$KEEP" ] && hits=$(printf '%s\n' "$hits" | grep -vE "$KEEP")
hits=$(printf '%s\n' "$hits" | sed '/^$/d')

if [ -n "$hits" ]; then
    echo "LEAK GATE: FAIL"
    printf '%s\n' "$hits"
    exit 1
fi
echo "LEAK GATE: PASS — zero denied tokens (keep-list applied)"
exit 0
