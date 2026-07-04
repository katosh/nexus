#!/usr/bin/env bash
# Unit tests for `_filter_cross_repo_surface` — the cross-repo emit
# gate that drops `mention=` / `cross_repo=` blocks whose body doesn't
# `@`-mention the bot, with mode-driven escape hatches for operators
# who want the legacy broad view or no cross-repo emits at all.
# Sibling chokepoint to `_filter_to_user_author` (issue #86); same
# file, same test style.
#
# Run: bash monitor/watcher/test-cross-repo-mention-filter.sh
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
        FAIL=$(( FAIL + 1 ))
    fi
}
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

# Source the unit under test.
. "$_test_dir/_github.sh"

# `_filter_to_user_author` runs upstream in production, so every block
# fed to `_filter_cross_repo_surface` already has author=$USER_LOGIN.
# Pin one author throughout — focus is on the body-mention rule, not
# author handling.
USER_LOGIN="operator"
BOT_LOGIN="your-org-bot"
export USER_LOGIN BOT_LOGIN

# Synthetic stream covering: in-`$REPO` shapes (issue=, pr=,
# pr_review=, issue_new=), cross-repo shapes (mention=, cross_repo=),
# bodies with and without an `@<BOT_LOGIN>` token, plus a
# `watcher_alert=` sentinel that must always survive.
make_stream() {
    cat <<'EOF'
issue=10 id=1000 author=operator
  body: in-repo issue comment without bot mention
pr=20 id=2000 author=operator
  body: in-repo PR comment without bot mention
pr_review=30 id=3000 author=operator path=src/foo.py
  body: in-repo PR review comment without bot mention
issue_new=40 id=40 author=operator
  body: in-repo new issue without bot mention
mention=external/repo-a kind=issue n=11 id=8001 author=operator
  body: cross-repo deliveries comment with no bot mention here
mention=external/repo-b kind=pr n=12 id=8002 author=operator
  body: cross-repo deliveries comment hey @your-org-bot can you help
cross_repo=external/repo-c kind=issue n=13 id=8003 author=operator
  body: cross-repo mentions-search hit without bot mention
cross_repo=external/repo-d kind=pr n=14 id=8004 author=operator
  body: cross-repo mentions-search hit pinging @your-org-bot please look
watcher_alert=rate-limit surface=issue_comments reset=1700000000
  body: GraphQL bucket exhausted; suppressing issue_comments snapshot until later.
EOF
}

# ---- mode=mention_only (default) ----------------------------------------

echo '=== mode=mention_only: cross-repo without @bot drops; in-repo passes ==='
CROSS_REPO_SURFACE=mention_only
out=$(make_stream | _filter_cross_repo_surface)

# In-repo shapes always survive — they bypass the gate.
assert_contains    "in-repo issue= surfaces"      "$out" "issue=10 id=1000 author=operator"
assert_contains    "in-repo pr= surfaces"         "$out" "pr=20 id=2000 author=operator"
assert_contains    "in-repo pr_review= surfaces"  "$out" "pr_review=30 id=3000 author=operator"
assert_contains    "in-repo issue_new= surfaces"  "$out" "issue_new=40 id=40 author=operator"
assert_contains    "in-repo body without mention survives" \
                   "$out" "in-repo issue comment without bot mention"

# Cross-repo without @bot body: dropped.
assert_not_contains "mention= without @bot dropped (header)" "$out" "id=8001"
assert_not_contains "mention= without @bot dropped (body)"   "$out" "cross-repo deliveries comment with no bot mention here"
assert_not_contains "cross_repo= without @bot dropped (header)" "$out" "id=8003"
assert_not_contains "cross_repo= without @bot dropped (body)"   "$out" "cross-repo mentions-search hit without bot mention"

# Cross-repo with @bot body: surfaces.
assert_contains    "mention= with @bot surfaces"     "$out" "mention=external/repo-b kind=pr n=12 id=8002"
assert_contains    "mention= with @bot body inlined" "$out" "hey @your-org-bot can you help"
assert_contains    "cross_repo= with @bot surfaces"  "$out" "cross_repo=external/repo-d kind=pr n=14 id=8004"
assert_contains    "cross_repo= with @bot body inlined" "$out" "pinging @your-org-bot please look"

# Sentinel survives untouched.
assert_contains    "watcher_alert= passes through" "$out" "watcher_alert=rate-limit"
assert_contains    "watcher_alert body inlined"    "$out" "GraphQL bucket exhausted"

# ---- mode=author_only (legacy) ------------------------------------------

echo '=== mode=author_only: every cross-repo emit surfaces ==='
CROSS_REPO_SURFACE=author_only
out=$(make_stream | _filter_cross_repo_surface)
assert_contains "mention= without @bot SURFACES (legacy)"    "$out" "id=8001"
assert_contains "mention= body inlined (legacy, no mention)" "$out" "cross-repo deliveries comment with no bot mention here"
assert_contains "mention= with @bot still surfaces"          "$out" "id=8002"
assert_contains "cross_repo= without @bot SURFACES (legacy)" "$out" "id=8003"
assert_contains "cross_repo= with @bot still surfaces"       "$out" "id=8004"
assert_contains "in-repo issue= surfaces (legacy)"           "$out" "issue=10 id=1000"

# ---- mode=off -----------------------------------------------------------

echo '=== mode=off: every cross-repo emit dropped, even with @bot ==='
CROSS_REPO_SURFACE=off
out=$(make_stream | _filter_cross_repo_surface)
assert_not_contains "mention= dropped (no @bot)"     "$out" "id=8001"
assert_not_contains "mention= dropped (with @bot)"   "$out" "id=8002"
assert_not_contains "cross_repo= dropped (no @bot)"  "$out" "id=8003"
assert_not_contains "cross_repo= dropped (with @bot)" "$out" "id=8004"
assert_contains    "in-repo issue= still surfaces (off)" "$out" "issue=10 id=1000"
assert_contains    "in-repo pr= still surfaces (off)"    "$out" "pr=20 id=2000"
assert_contains    "watcher_alert still passes (off)"    "$out" "watcher_alert=rate-limit"

# ---- case-insensitive bot match ----------------------------------------

echo '=== mention_only: @bot match is case-insensitive ==='
CROSS_REPO_SURFACE=mention_only
out=$(printf 'mention=ext/r kind=issue n=1 id=9100 author=operator\n  body: hey @Your-Org-Bot please review\n' \
    | _filter_cross_repo_surface)
assert_contains "@YourOrgBotMixedCase matches" "$out" "id=9100"

out=$(printf 'mention=ext/r kind=issue n=1 id=9101 author=operator\n  body: HEY @YOUR-ORG-BOT FYI\n' \
    | _filter_cross_repo_surface)
assert_contains "all-uppercase @bot matches" "$out" "id=9101"

# ---- word-boundary checks: `@<bot>foo` does NOT match -----------------

echo '=== mention_only: word-boundary guards on the trailing edge ==='
CROSS_REPO_SURFACE=mention_only

# Trailing alnum extends the slug — different login, should not match.
out=$(printf 'mention=ext/r kind=issue n=1 id=9200 author=operator\n  body: ping @your-org-botxyz unrelated\n' \
    | _filter_cross_repo_surface)
assert_not_contains "@<bot>xyz does NOT match (alnum extension)" "$out" "id=9200"

# Trailing dash also extends slug — GitHub allows hyphens in logins.
out=$(printf 'mention=ext/r kind=issue n=1 id=9201 author=operator\n  body: ping @your-org-bot-staging\n' \
    | _filter_cross_repo_surface)
assert_not_contains "@<bot>-staging does NOT match (dash extension)" "$out" "id=9201"

# Trailing underscore extends slug.
out=$(printf 'mention=ext/r kind=issue n=1 id=9202 author=operator\n  body: ping @your-org-bot_alt\n' \
    | _filter_cross_repo_surface)
assert_not_contains "@<bot>_alt does NOT match (underscore extension)" "$out" "id=9202"

# Trailing `[bot]` suffix: ends the slug at `t`, then `[` is non-word —
# this DOES match (GitHub renders @<slug>[bot] as a real ping for App
# accounts; the body explicitly invokes the bot).
out=$(printf 'mention=ext/r kind=issue n=1 id=9203 author=operator\n  body: ping @your-org-bot[bot] hello\n' \
    | _filter_cross_repo_surface)
assert_contains "@<bot>[bot] matches (separator-terminated)" "$out" "id=9203"

# Trailing punctuation (comma, period, paren, end-of-line).
out=$(printf 'mention=ext/r kind=issue n=1 id=9204 author=operator\n  body: hi @your-org-bot, please\n' \
    | _filter_cross_repo_surface)
assert_contains "@<bot>, matches (comma-terminated)"   "$out" "id=9204"
out=$(printf 'mention=ext/r kind=issue n=1 id=9205 author=operator\n  body: end of line @your-org-bot\n' \
    | _filter_cross_repo_surface)
assert_contains "@<bot> at line end matches" "$out" "id=9205"

# Leading edge: email-like context must NOT match.
echo '=== mention_only: word-boundary guard on the leading edge ==='
out=$(printf 'mention=ext/r kind=issue n=1 id=9210 author=operator\n  body: email foo@your-org-bot.example here\n' \
    | _filter_cross_repo_surface)
assert_not_contains "foo@<bot> (email-like) does NOT match" "$out" "id=9210"

# Leading edge with code-fence backticks — counts as a mention (the
# operator explicitly typed it; spec call documented in _github.sh).
out=$(printf 'mention=ext/r kind=issue n=1 id=9211 author=operator\n  body: literal `@your-org-bot` reference\n' \
    | _filter_cross_repo_surface)
assert_contains '`@<bot>` in backticks matches (explicit reference)' "$out" "id=9211"

# ---- BOT_LOGIN with `[bot]` suffix --------------------------------------

echo '=== mention_only: BOT_LOGIN with [bot] suffix is stripped before match ==='
CROSS_REPO_SURFACE=mention_only
saved_bot="$BOT_LOGIN"
BOT_LOGIN="your-org-bot[bot]"
out=$(printf 'mention=ext/r kind=issue n=1 id=9300 author=operator\n  body: ping @your-org-bot please\n' \
    | _filter_cross_repo_surface)
assert_contains "BOT_LOGIN trailing [bot] stripped; @<slug> still matches" "$out" "id=9300"
BOT_LOGIN="$saved_bot"

# ---- empty BOT_LOGIN under mention_only ---------------------------------

echo '=== mention_only with empty BOT_LOGIN: degrades to off (drop all cross-repo) ==='
CROSS_REPO_SURFACE=mention_only
saved_bot="$BOT_LOGIN"
BOT_LOGIN=""
out=$(make_stream | _filter_cross_repo_surface)
assert_not_contains "mention= dropped (empty BOT_LOGIN)"    "$out" "id=8001"
assert_not_contains "mention= dropped even with @bot body"  "$out" "id=8002"
assert_not_contains "cross_repo= dropped (empty BOT_LOGIN)" "$out" "id=8003"
assert_not_contains "cross_repo= dropped even with @bot body" "$out" "id=8004"
assert_contains    "in-repo issue= still surfaces"          "$out" "issue=10 id=1000"
BOT_LOGIN="$saved_bot"

# ---- unknown mode falls back to mention_only ----------------------------

echo '=== unknown mode falls back to mention_only ==='
CROSS_REPO_SURFACE="bogus-mode-name"
out=$(make_stream | _filter_cross_repo_surface)
assert_contains    "mention= with @bot surfaces under fallback"   "$out" "id=8002"
assert_not_contains "mention= without @bot dropped under fallback" "$out" "id=8001"
assert_contains    "in-repo issue= still surfaces under fallback" "$out" "issue=10 id=1000"

# ---- unset mode env -> default mention_only -----------------------------

echo '=== unset CROSS_REPO_SURFACE env -> default mention_only ==='
unset CROSS_REPO_SURFACE
out=$(make_stream | _filter_cross_repo_surface)
assert_contains    "default behaviour surfaces @bot-mentioning emit" "$out" "id=8002"
assert_not_contains "default behaviour drops non-mentioning emit"    "$out" "id=8001"

# ---- header-without-body edge case --------------------------------------

echo '=== header without trailing body line: in-repo passes, cross-repo dropped under mention_only ==='
CROSS_REPO_SURFACE=mention_only
out=$(printf 'issue=99 id=99 author=operator\nmention=ext/r kind=issue n=99 id=9999 author=operator\n' \
    | _filter_cross_repo_surface)
assert_contains    "in-repo header survives without body" "$out" "issue=99 id=99 author=operator"
assert_not_contains "cross-repo header without body dropped (no mention possible)" "$out" "id=9999"

# ---- empty stream -------------------------------------------------------

echo '=== empty stream -> empty output ==='
CROSS_REPO_SURFACE=mention_only
out=$(: | _filter_cross_repo_surface)
assert_eq "empty in -> empty out" "$out" ""

# ---- composed with _filter_to_user_author -------------------------------

echo '=== composed: _filter_to_user_author | _filter_cross_repo_surface ==='
CROSS_REPO_SURFACE=mention_only
out=$(printf 'mention=ext/r kind=issue n=1 id=9400 author=huangy57-nexus-bot[bot]\n  body: ping @your-org-bot from sibling bot\nmention=ext/r kind=issue n=2 id=9401 author=operator\n  body: ping @your-org-bot from operator\nmention=ext/r kind=issue n=3 id=9402 author=operator\n  body: chat with other operator, no bot mention\n' \
    | _filter_to_user_author | _filter_cross_repo_surface)
assert_not_contains "sibling bot drops at author chokepoint" "$out" "id=9400"
assert_contains    "operator + @bot mention surfaces"        "$out" "id=9401"
assert_not_contains "operator without @bot mention drops"    "$out" "id=9402"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
