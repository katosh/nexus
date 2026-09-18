#!/usr/bin/env bash
# claude-md-block-coverage.sh MARKER... — the per-suite coverage boundary of a
# CLAUDE.md block (your-org/nexus-code#1239, action 1).
#
# A `test-claude-md-<x>.sh` suite executes the FENCED lines between
# `<!-- BEGIN X -->` and `<!-- END X -->`; the thing a reader ACTS ON is the
# PARAGRAPH the block sits in. `#1239` measured the executed share at ~5.8%
# overall and never above 18%, so a green from such a suite is systematically
# narrower than the claim it appears to license. `test-claude-md-block-coverage.sh`
# §3 prints that table once, for every pair; this prints ONE line for the
# marker(s) a given suite names, in that suite's own output, where the green
# is read — the `#1078` blind-spot-count pattern:
#
#     CLAUDE.md block X: N of M entry lines are executed here; UNCHECKED: M-N (P%)
#
# THE ARITHMETIC IS THE SAME AS §3's, and it must stay so — a per-suite line
# that disagreed with the aggregate would be two instruments for one number.
# The ENTRY is the top-level `- **` bullet the marker sits inside, up to the
# next such bullet (or the end of the document); N counts lines INSIDE a ```
# fence between the markers, never "block lines minus fences" (the over-read
# §3's own first cut fell into: a fence-less block scored all its prose as
# executed). A marker in NO top-level entry is REFUSED rather than given a
# manufactured denominator; a marker the document does not carry is reported
# UNKNOWN. Neither exits non-zero: this is a REPORT that asserts nothing, and
# the ratchets that make missing or unowned markers RED are
# `test-claude-md-block-coverage.sh` and `test-claude-md-marker-ownership.sh`.
#
# Usage: claude-md-block-coverage.sh [--doc PATH] MARKER [MARKER...]
set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DOC="$(cd "$_self_dir/../.." && pwd)/CLAUDE.md"
if [[ "${1:-}" == --doc ]]; then DOC="$2"; shift 2; fi
(( $# > 0 )) || { echo "usage: claude-md-block-coverage.sh [--doc PATH] MARKER..." >&2; exit 2; }
[[ -r "$DOC" ]] || { printf 'CLAUDE.md block %s: UNKNOWN — document not readable at %s\n' "$*" "$DOC"; exit 0; }

ENTRY_STARTS=$(command grep -n '^- \*\*' "$DOC" | cut -d: -f1)
DOC_LINES=$(command grep -c '' "$DOC")
for m in "$@"; do
    # `sed -n '1p'`, never `head -1` (#622: an early-exit reader under pipefail).
    bline=$(command grep -n -F -e "<!-- BEGIN $m -->" "$DOC" | cut -d: -f1 | sed -n '1p')
    if [[ -z "$bline" ]]; then
        printf 'CLAUDE.md block %s: UNKNOWN — the document declares no such marker (the ownership ratchet is what reds on that)\n' "$m"
        continue
    fi
    start=$(printf '%s\n' "$ENTRY_STARTS" | awk -v b="$bline" '$1 < b' | tail -1)
    end=$(printf '%s\n' "$ENTRY_STARTS" | awk -v b="$bline" '$1 > b' | sed -n '1p')
    if [[ -z "$start" ]]; then
        printf 'CLAUDE.md block %s: NOT INSIDE ANY TOP-LEVEL ENTRY — no ratio (a denominator would be manufactured)\n' "$m"
        continue
    fi
    [[ -n "$end" ]] || end="$DOC_LINES"
    entry_n=$(( end - start ))
    exec_n=$(awk -v b="<!-- BEGIN $m -->" -v e="<!-- END $m -->" '
        index($0,b) { f = 1; next }
        index($0,e) { f = 0 }
        f && /^[[:space:]]*```/ { inf = !inf; next }
        f && inf && NF { n++ }
        END { print n + 0 }' "$DOC")
    if (( entry_n <= 0 )); then
        printf 'CLAUDE.md block %s: NOT INSIDE ANY TOP-LEVEL ENTRY — no ratio\n' "$m"
        continue
    fi
    pct=$(( exec_n * 100 / entry_n ))
    printf 'CLAUDE.md block %s: %d of %d entry lines are executed here; UNCHECKED: %d (%d%% of the entry is prose no suite runs — #1239)\n' \
        "$m" "$exec_n" "$entry_n" "$(( entry_n - exec_n ))" "$(( 100 - pct ))"
done
exit 0
