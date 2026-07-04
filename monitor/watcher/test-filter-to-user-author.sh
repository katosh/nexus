#!/usr/bin/env bash
# Unit tests for `_filter_to_user_author` — the single chokepoint that
# enforces the user-author rule across every comment-surfacing source
# (issue #86). The function reads emit blocks on stdin and drops any
# whose `author=<login>` token doesn't equal $USER_LOGIN. Body
# continuation lines (`  body: ...`) are dropped alongside their
# header. Lines that aren't a recognized header / body shape pass
# through unchanged so unrelated stdout (e.g. `watcher_alert=`
# sentinels) isn't accidentally swallowed.
#
# Run: bash monitor/watcher/test-filter-to-user-author.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0
FAIL=0

assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         got:\n%s\n'  "$got"  | sed 's/^/           /' >&2
        printf '         want:\n%s\n' "$want" | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
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
        FAIL=$(( FAIL + 1 ))
    fi
}

USER_LOGIN="operator"
export USER_LOGIN

# Source the unit under test.
. "$_test_dir/_github.sh"

# ---- the six emit-header shapes × three authors ----

echo '=== every header shape: user-authored surfaces, bot/other drop ==='

# Build a synthetic stream covering all six emit-line prefixes
# (issue, pr, pr_review, issue_new, mention, cross_repo) × three
# authors (huangy57-nexus-bot[bot], your-org-bot[bot], operator).
#
# Each block is a `<header>\n  body: <preview>\n` pair. The chokepoint
# must drop the bot blocks (header + body) and pass through the
# operator blocks intact.
STREAM=$'issue=1 id=101 author=huangy57-nexus-bot[bot]\n'\
$'  body: sibling bot issue comment\n'\
$'issue=1 id=102 author=your-org-bot[bot]\n'\
$'  body: self bot issue comment\n'\
$'issue=1 id=103 author=operator\n'\
$'  body: operator issue comment\n'\
$'pr=2 id=201 author=huangy57-nexus-bot[bot]\n'\
$'  body: sibling bot pr comment\n'\
$'pr=2 id=202 author=your-org-bot[bot]\n'\
$'  body: self bot pr comment\n'\
$'pr=2 id=203 author=operator\n'\
$'  body: operator pr comment\n'\
$'pr_review=3 id=301 author=huangy57-nexus-bot[bot] path=src/a.py\n'\
$'  body: sibling bot review comment\n'\
$'pr_review=3 id=302 author=your-org-bot[bot] path=src/a.py\n'\
$'  body: self bot review comment\n'\
$'pr_review=3 id=303 author=operator path=src/a.py\n'\
$'  body: operator review comment\n'\
$'issue_new=4 id=4 author=huangy57-nexus-bot[bot]\n'\
$'  body: sibling bot opened issue\n'\
$'issue_new=5 id=5 author=your-org-bot[bot]\n'\
$'  body: self bot opened issue\n'\
$'issue_new=6 id=6 author=operator\n'\
$'  body: operator opened issue\n'\
$'mention=external/repo kind=issue n=7 id=701 author=huangy57-nexus-bot[bot]\n'\
$'  body: sibling bot cross-repo mention\n'\
$'mention=external/repo kind=issue n=7 id=702 author=your-org-bot[bot]\n'\
$'  body: self bot cross-repo mention\n'\
$'mention=external/repo kind=issue n=7 id=703 author=operator\n'\
$'  body: operator cross-repo mention\n'\
$'cross_repo=ext/repo kind=pr n=8 id=801 author=huangy57-nexus-bot[bot]\n'\
$'  body: sibling bot mention search hit\n'\
$'cross_repo=ext/repo kind=pr n=8 id=802 author=your-org-bot[bot]\n'\
$'  body: self bot mention search hit\n'\
$'cross_repo=ext/repo kind=pr n=8 id=803 author=operator src=body\n'\
$'  body: operator self-mention\n'

out=$(printf '%s' "$STREAM" | _filter_to_user_author)

# Per id: id=10[123] is the issue trio, 20[123] pr, 30[123] pr_review,
# 4/5/6 issue_new, 70[123] mention, 80[123] cross_repo.
for id in 101 102 201 202 301 302 701 702 801 802; do
    assert_not_contains "bot-authored id=$id dropped" "$out" "id=$id"
done
for id_x4 in 4 5; do
    assert_not_contains "bot-authored issue_new=$id_x4 dropped" "$out" "issue_new=$id_x4"
done
for id in 103 203 303 703 803; do
    assert_contains "operator id=$id surfaces" "$out" "id=$id"
done
assert_contains "operator issue_new=6 surfaces" "$out" "issue_new=6 id=6 author=operator"

# Body previews must drop with their headers.
for body in 'sibling bot issue comment' \
            'self bot issue comment' \
            'sibling bot pr comment' \
            'self bot pr comment' \
            'sibling bot review comment' \
            'self bot review comment' \
            'sibling bot opened issue' \
            'self bot opened issue' \
            'sibling bot cross-repo mention' \
            'self bot cross-repo mention' \
            'sibling bot mention search hit' \
            'self bot mention search hit'; do
    assert_not_contains "body preview dropped: $body" "$out" "$body"
done
for body in 'operator issue comment' \
            'operator pr comment' \
            'operator review comment' \
            'operator opened issue' \
            'operator cross-repo mention' \
            'operator self-mention'; do
    assert_contains "body preview surfaces: $body" "$out" "$body"
done

# ---- unrelated lines pass through ----

echo '=== non-header lines pass through unchanged ==='
out=$(printf 'watcher_alert=rate-limit surface=issue_comments reset=1700000000\n  body: GraphQL bucket exhausted; suppressing issue_comments snapshot until 2020-11-14T22:13:20Z.\n--- relaunch ---\nstartup-sweep banner\n' \
    | _filter_to_user_author)
assert_contains "watcher_alert= sentinel passes through" "$out" "watcher_alert=rate-limit"
assert_contains "watcher_alert body inlined"             "$out" "GraphQL bucket exhausted"
assert_contains "separator passes through"               "$out" "--- relaunch ---"
assert_contains "banner passes through"                  "$out" "startup-sweep banner"

# ---- empty USER_LOGIN: nothing surfaces ----

echo '=== empty USER_LOGIN: every header is dropped (fail-closed) ==='
saved_user="$USER_LOGIN"
USER_LOGIN=""
out=$(printf 'issue=1 id=1 author=operator\n  body: would-have-surfaced\n' \
    | _filter_to_user_author)
assert_eq "no headers surface when USER_LOGIN unset" "$out" ""
USER_LOGIN="$saved_user"

# ---- author tokens with [bot] suffix and unusual chars ----

echo '=== exact-match: [bot] suffix only matches itself ==='
out=$(printf 'issue=1 id=1 author=operator-staging\n  body: lookalike\nissue=1 id=2 author=operator[bot]\n  body: wrapped-bot\nissue=1 id=3 author=operator\n  body: real\n' \
    | _filter_to_user_author)
assert_not_contains "lookalike login dropped"   "$out" "id=1"
assert_not_contains "[bot]-wrapped login dropped" "$out" "id=2"
assert_contains    "exact match surfaces"        "$out" "id=3 author=operator"

# ---- body line containing `author=` text is gated by header ----

echo '=== body line with `author=` substring inherits header gate ==='
out=$(printf 'issue=1 id=1 author=operator\n  body: user note saying author=anyone here\nissue=1 id=2 author=huangy57-nexus-bot[bot]\n  body: bot note saying author=operator here\n' \
    | _filter_to_user_author)
assert_contains    "operator header survives, body inlined" "$out" "id=1 author=operator"
assert_contains    "operator body inlined as a whole"       "$out" "user note saying author=anyone here"
assert_not_contains "bot header dropped"                  "$out" "id=2"
assert_not_contains "bot body dropped even with author=operator substring" "$out" "bot note saying author=operator here"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
