#!/usr/bin/env bash
# Regression tests for the eligibility-filter resurface bug surfaced by
# other-nexus#9 / comment 4558979011 (2026-05-27):
#
#   Symptom — every poll cycle, watcher re-emits comments that already
#   carry bot eyes + bot rocket reactions, even though the eligibility
#   filter at `_snapshot_issue_comments` (and siblings) is supposed to
#   drop them.
#
# Root-cause hypothesis (verified by these tests): when the reaction's
# `.user` field is `null` (which happens for App / Bot-account
# reactions on some GitHub paths — App reactions don't always populate
# a User node), the predicate
#
#     .content == "EYES" and .user.login != $login
#
# evaluates to `null` (because `null.login` is `null`, and
# `null != $login` is null/falsy in jq), so the EYES branch fails to
# match and the comment is NOT excluded. ROCKET is content-only and
# stays correct, but if a comment has bot-eyes WITHOUT a bot-rocket,
# the filter degrades to no-op and the comment re-surfaces every poll.
#
# Tests below assert null-safe behaviour. They are RED on the current
# (pre-fix) `_github.sh` and GREEN after the `.user.login // ""`
# fix lands. Run: `bash monitor/watcher/test-eligibility-resurface.sh`.

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
        printf '         expected to find: %s\n' "$needle" >&2
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
        printf '         did NOT expect: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness ----

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/state"
mkdir -p "$STATE_DIR"
REPO="your-org/other-nexus"
USER_LOGIN="tjbencomo"
BOT_LOGIN="other-nexus-bot"

MINT_STUB="$WORK/mint-token.sh"
printf '#!/usr/bin/env bash\nprintf %%s test-token\n' > "$MINT_STUB"
chmod +x "$MINT_STUB"
MINT_TOKEN_BIN="$MINT_STUB"
export STATE_DIR REPO USER_LOGIN BOT_LOGIN MINT_TOKEN_BIN

. "$_test_dir/_github.sh"

# Mock gh: dispatch on q= contents. Tests below mutate the *_FIXTURE
# globals between calls.
ISSUE_FIXTURE='{"data":{"search":{"nodes":[]}}}'
PR_FIXTURE='{"data":{"search":{"nodes":[]}}}'
NEW_ISSUES_FIXTURE='{"data":{"search":{"nodes":[]}}}'

gh() {
    [[ "$1" == "api" && "$2" == "graphql" ]] || return 1
    shift 2
    local q=""
    while (( $# > 0 )); do
        case "$1" in
            -f) case "$2" in q=*) q="${2#q=}" ;; esac; shift 2 ;;
            *)  shift ;;
        esac
    done
    if [[ "$q" == *"is:issue"* && "$q" == *"author:"* ]]; then
        printf '%s' "$NEW_ISSUES_FIXTURE"
    elif [[ "$q" == *"is:issue"* ]]; then
        printf '%s' "$ISSUE_FIXTURE"
    elif [[ "$q" == *"is:pr"* ]]; then
        printf '%s' "$PR_FIXTURE"
    else
        printf '{}'
    fi
    return 0
}
export -f gh

# `timeout` shadow (issue #367). `_snapshot_graphql` wraps each gh call
# in `timeout -k <k> <s> gh …`; the real binary can't exec the `gh`
# bash-function shadow above, so intercept it: strip the `-k <k>` flag
# and the duration, then run the remaining argv (`gh …`) so the mock
# keeps serving fixtures (without this, the real gh runs and returns
# empty, making positive assertions silently fail).
timeout() {
    while [[ "${1:-}" == -* ]]; do
        case "$1" in
            -k|--kill-after) shift 2 ;;
            *)               shift ;;
        esac
    done
    shift   # drop the duration argument
    "$@"
}
export -f timeout

# ---- 1. eyes+rocket'd comment doesn't re-emit -------------------------
# Comment has BOTH bot-eyes and bot-rocket. The filter MUST drop it.
# Pre-fix behaviour: ROCKET branch matches independent of `.user`, so
# this case is already excluded → this test should be GREEN both before
# and after, acting as a regression guard.
echo '=== eyes+rocket'\''d comment is dropped by reactions filter ==='
ISSUE_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "number": 9,
          "comments": {
            "nodes": [
              {
                "databaseId": 4558868003,
                "author": {"login": "tjbencomo"},
                "body": "cron request from user",
                "reactions": {"nodes": [
                  {"content": "EYES",   "user": {"login": "other-nexus-bot"}},
                  {"content": "ROCKET", "user": {"login": "other-nexus-bot"}}
                ]}
              }
            ]
          }
        }
      ]
    }
  }
}'
out=$(snapshot_github)
assert_not_contains "eyes+rocket comment excluded" "$out" "id=4558868003"

# ---- 2. eyes-only with NULL reaction-user (the actual bug) -----------
# This is the runtime divergence in the bot report. App / Bot-account
# reactions sometimes return `.user = null` from GraphQL. The pre-fix
# predicate `EYES and .user.login != $login` then evaluates to null
# (falsy), so the comment is NOT excluded. After the fix it MUST be
# excluded by the `(.user.login // "") != $login` form (empty-string is
# != $login when $login is non-empty).
echo '=== eyes-only with .user=null is dropped (null-safe filter) ==='
ISSUE_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "number": 12,
          "comments": {
            "nodes": [
              {
                "databaseId": 4558999001,
                "author": {"login": "tjbencomo"},
                "body": "user comment, bot eyes with null user",
                "reactions": {"nodes": [
                  {"content": "EYES", "user": null}
                ]}
              }
            ]
          }
        }
      ]
    }
  }
}'
out=$(snapshot_github)
assert_not_contains "null-user EYES still excludes" "$out" "id=4558999001"

# ---- 3. eyes-only with explicit BOT login is dropped -----------------
# The canonical bot-eyes case (when GraphQL DOES populate the user
# node). Pre-fix this works; assert it stays working post-fix.
echo '=== eyes-only with explicit bot login is dropped ==='
ISSUE_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "number": 13,
          "comments": {
            "nodes": [
              {
                "databaseId": 4558999002,
                "author": {"login": "tjbencomo"},
                "body": "user comment, bot eyed explicitly",
                "reactions": {"nodes": [
                  {"content": "EYES", "user": {"login": "other-nexus-bot"}}
                ]}
              }
            ]
          }
        }
      ]
    }
  }
}'
out=$(snapshot_github)
assert_not_contains "explicit bot EYES excludes" "$out" "id=4558999002"

# ---- 4. self-eyes (user's own EYES) DOES surface --------------------
# Portability rule: a user EYE-ing their own comment should not be
# treated as "bot already processed". The filter must distinguish
# self-eye (surface) from bot-eye (drop). Asserts the fix doesn't
# overshoot.
echo '=== self-eye (user own login) does NOT exclude ==='
ISSUE_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "number": 14,
          "comments": {
            "nodes": [
              {
                "databaseId": 4558999003,
                "author": {"login": "tjbencomo"},
                "body": "user comment, user self-eyed",
                "reactions": {"nodes": [
                  {"content": "EYES", "user": {"login": "tjbencomo"}}
                ]}
              }
            ]
          }
        }
      ]
    }
  }
}'
out=$(snapshot_github)
assert_contains "self-eye still surfaces" "$out" "id=4558999003"

# ---- 5. empty USER_LOGIN: ROCKET still excludes ---------------------
# Regression guard for hypothesis 2 in the bot report. If USER_LOGIN is
# somehow unset in the snapshot subshell, the ROCKET predicate must
# still exclude because it's reaction-author-independent.
echo '=== empty USER_LOGIN: ROCKET still excludes comment ==='
ISSUE_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "number": 15,
          "comments": {
            "nodes": [
              {
                "databaseId": 4558999004,
                "author": {"login": "tjbencomo"},
                "body": "comment with bot rocket and no eyes",
                "reactions": {"nodes": [
                  {"content": "ROCKET", "user": {"login": "other-nexus-bot"}}
                ]}
              }
            ]
          }
        }
      ]
    }
  }
}'
(
    USER_LOGIN=""
    export USER_LOGIN
    out=$(snapshot_github)
    assert_not_contains "empty USER_LOGIN: ROCKET still excludes" "$out" "id=4558999004"
)

# ---- 6. dedup with EMPTY processed file: reactions filter still wins -
# Regression guard for hypothesis 1. The reactions filter must exclude
# eyes+rocket'd comments even when the processed-comments file is
# empty / missing.
echo '=== empty processed-comments: reactions filter still excludes ==='
rm -f "$STATE_DIR/processed-comments.txt"
ISSUE_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "number": 16,
          "comments": {
            "nodes": [
              {
                "databaseId": 4558999005,
                "author": {"login": "tjbencomo"},
                "body": "bot eyed + rocket, no dedup file present",
                "reactions": {"nodes": [
                  {"content": "EYES",   "user": {"login": "other-nexus-bot"}},
                  {"content": "ROCKET", "user": {"login": "other-nexus-bot"}}
                ]}
              }
            ]
          }
        }
      ]
    }
  }
}'
out=$(snapshot_github)
assert_not_contains "no-dedup: still excluded by reactions" "$out" "id=4558999005"

# ---- 7. PR comment path: same null-safety applies -------------------
echo '=== PR review-thread null-user EYES is dropped ==='
ISSUE_FIXTURE='{"data":{"search":{"nodes":[]}}}'
PR_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "number": 42,
          "comments": {
            "nodes": [
              {
                "databaseId": 4559000001,
                "author": {"login": "tjbencomo"},
                "body": "pr comment with null-user EYES",
                "reactions": {"nodes": [
                  {"content": "EYES", "user": null}
                ]}
              }
            ]
          },
          "reviewThreads": {"nodes": []}
        }
      ]
    }
  }
}'
out=$(snapshot_github)
assert_not_contains "PR null-user EYES excluded" "$out" "id=4559000001"

# ---- 8. new-issues path: same null-safety applies -------------------
echo '=== new-issues null-user EYES is dropped ==='
PR_FIXTURE='{"data":{"search":{"nodes":[]}}}'
NEW_ISSUES_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "number": 21,
          "author": {"login": "tjbencomo"},
          "body": "user issue, bot eyed with null user",
          "reactions": {"nodes": [
            {"content": "EYES", "user": null}
          ]}
        }
      ]
    }
  }
}'
out=$(snapshot_github)
assert_not_contains "new-issue null-user EYES excluded" "$out" "issue_new=21"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
