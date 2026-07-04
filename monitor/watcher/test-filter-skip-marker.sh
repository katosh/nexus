#!/usr/bin/env bash
# Unit tests for `_filter_skip_marker` — the operator opt-out filter
# that drops emit blocks the operator has flagged "don't act on this".
#
# Two recognized forms, matched against the `  body:` continuation line:
#   PRIMARY   the body's first non-empty line, trimmed and
#             case-insensitive, is exactly `/skip` (synonym
#             `/nexus-skip`). Because the emitter collapses newlines to
#             spaces before this filter sees the body, "first non-empty
#             line" re-expresses as "begins with the token after
#             trimming leading whitespace".
#   SECONDARY the invisible `<!-- nexus:skip -->` HTML marker anywhere
#             in the body.
#
# Hard safety rule: drop ONLY on an unambiguous match. A `/skip` buried
# mid-body, a `/skipfoo`/`/skip-x` lookalike, or prose like "let's skip
# this" must all still surface. Drop diagnostics go to watcher.log /
# stderr, never to stdout.
#
# Run: bash monitor/watcher/test-filter-skip-marker.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0
FAIL=0

assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         missing: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if ! grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         unexpected: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# Drop diagnostics target $STATE_DIR/watcher.log; point it at a temp dir
# so they never reach the test's stdout capture and we can assert on it.
STATE_DIR=$(mktemp -d)
export STATE_DIR
trap 'rm -rf "$STATE_DIR"' EXIT

# Source the unit under test.
. "$_test_dir/_github.sh"

# Helper: the emitter collapses newlines to a single space before the
# body reaches this filter. Mirror that so test fixtures match what the
# filter actually sees in production. Input uses literal `\n` markers.
collapse() { printf '%s' "$1" | tr '\n\r\t' '   '; }

echo '=== PRIMARY /skip on the first line → dropped ==='
# Operator types `/skip` on line 1, note below. After collapse the body
# preview begins with `/skip `.
body=$(collapse '/skip
this is just a side note, do not act')
out=$(printf 'issue=1 id=101 author=operator\n  body: %s\n' "$body" | _filter_skip_marker)
assert_not_contains "leading /skip header dropped" "$out" "id=101"
assert_not_contains "leading /skip body dropped"   "$out" "side note"

echo '=== whole comment is just `/skip` → dropped ==='
out=$(printf 'pr=2 id=201 author=operator\n  body: /skip\n' | _filter_skip_marker)
assert_not_contains "bare /skip dropped" "$out" "id=201"

echo '=== case-insensitive: `/SKIP`, `/Skip` → dropped ==='
out=$(printf 'issue=3 id=301 author=operator\n  body: %s\n' "$(collapse '/SKIP
note')" | _filter_skip_marker)
assert_not_contains "/SKIP dropped" "$out" "id=301"
out=$(printf 'issue=3 id=302 author=operator\n  body: %s\n' "$(collapse '/Skip
note')" | _filter_skip_marker)
assert_not_contains "/Skip dropped" "$out" "id=302"

echo '=== synonym `/nexus-skip` on the first line → dropped ==='
out=$(printf 'issue_new=4 id=4 author=operator\n  body: %s\n' "$(collapse '/nexus-skip
opening a tracker, no action please')" | _filter_skip_marker)
assert_not_contains "/nexus-skip header dropped" "$out" "issue_new=4"
assert_not_contains "/nexus-skip body dropped"   "$out" "opening a tracker"

echo '=== SECONDARY HTML marker anywhere in body → dropped ==='
out=$(printf 'pr_review=5 id=501 author=operator path=src/a.py\n  body: %s\n' \
    "$(collapse 'real-looking review comment <!-- nexus:skip --> trailing')" | _filter_skip_marker)
assert_not_contains "HTML marker (mid-body) dropped" "$out" "id=501"

echo '=== `/skip` NOT on the first line → forwarded (no over-match) ==='
# `/skip` appears on line 3; after collapse it lands mid-string and must
# NOT trigger the leading-token match.
body=$(collapse 'here is some context
and more detail
/skip
trailing')
out=$(printf 'issue=6 id=601 author=operator\n  body: %s\n' "$body" | _filter_skip_marker)
assert_contains "mid-body /skip header surfaces" "$out" "id=601"
assert_contains "mid-body /skip body surfaces"   "$out" "here is some context"

echo '=== prose "let'\''s skip this" → forwarded (no over-match) ==='
out=$(printf 'issue=7 id=701 author=operator\n  body: %s\n' \
    "$(collapse "let's skip this validation and move on")" | _filter_skip_marker)
assert_contains "prose skip surfaces" "$out" "id=701"
assert_contains "prose body surfaces" "$out" "let's skip this validation"

echo '=== lookalike tokens `/skipfoo`, `/skip-x` → forwarded ==='
out=$(printf 'issue=8 id=801 author=operator\n  body: /skipfoo bar baz\n' | _filter_skip_marker)
assert_contains "/skipfoo surfaces (not a token)" "$out" "id=801"
out=$(printf 'issue=8 id=802 author=operator\n  body: /skip-extra note\n' | _filter_skip_marker)
assert_contains "/skip-extra surfaces (hyphen not /nexus-skip)" "$out" "id=802"

echo '=== plain comment with no marker → forwarded ==='
out=$(printf 'issue=9 id=901 author=operator\n  body: please rebase the PR and rerun CI\n' | _filter_skip_marker)
assert_contains "ordinary directive surfaces" "$out" "id=901"
assert_contains "ordinary directive body surfaces" "$out" "rebase the PR"

echo '=== leading blank line(s) before /skip → still dropped ==='
# A body starting with blank lines collapses to leading whitespace; the
# filter trims it, so the first NON-EMPTY line is what matters.
out=$(printf 'issue=10 id=1001 author=operator\n  body: %s\n' \
    "$(collapse '

/skip
note after blanks')" | _filter_skip_marker)
assert_not_contains "blank-led /skip dropped" "$out" "id=1001"

echo '=== mixed stream: only flagged blocks drop, rest intact ==='
STREAM=$(printf 'issue=11 id=1101 author=operator\n  body: %s\nissue=11 id=1102 author=operator\n  body: act on this one please\npr=12 id=1201 author=operator\n  body: %s\n' \
    "$(collapse '/skip
quiet note')" \
    "$(collapse 'normal pr comment')")
out=$(printf '%s\n' "$STREAM" | _filter_skip_marker)
assert_not_contains "flagged issue dropped"   "$out" "id=1101"
assert_contains    "unflagged issue surfaces" "$out" "id=1102"
assert_contains    "unflagged pr surfaces"    "$out" "id=1201"

echo '=== non-header lines pass through unchanged ==='
out=$(printf 'watcher_alert=rate-limit surface=issue_comments reset=1700000000\n  body: bucket exhausted\n--- relaunch ---\nbanner\n' \
    | _filter_skip_marker)
assert_contains "watcher_alert= passes through" "$out" "watcher_alert=rate-limit"
assert_contains "separator passes through"      "$out" "--- relaunch ---"
assert_contains "banner passes through"         "$out" "banner"

echo '=== drop diagnostics go to watcher.log, never stdout ==='
printf 'issue=13 id=1301 author=operator\n  body: %s\n' "$(collapse '/skip
secret note')" | _filter_skip_marker >/dev/null
assert_contains "drop logged to watcher.log" "$(cat "$STATE_DIR/watcher.log" 2>/dev/null)" "[skip-marker] dropped emit"
assert_contains "logged header identifies the block" "$(cat "$STATE_DIR/watcher.log" 2>/dev/null)" "id=1301"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
