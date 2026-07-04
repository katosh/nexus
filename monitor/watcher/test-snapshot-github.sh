#!/usr/bin/env bash
# Mock-gh unit tests for monitor/watcher/_github.sh.
#
# Run: bash monitor/watcher/test-snapshot-github.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Assertions are made against `snapshot_github | _filter_to_user_author`
# — the production pipeline. `snapshot_github` alone no longer
# enforces the user-author rule (issue #86 moved it to the
# `_filter_to_user_author` chokepoint); tests exercise the combined
# behaviour to match what `_gh_filter_dedup_pipeline` in main.sh
# actually surfaces.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0
FAIL=0

assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"
        PASS=$(( PASS + 1 ))
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
        printf '  PASS: %s\n' "$label"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         did NOT expect: %s\n' "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- Mock harness ------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/state"
mkdir -p "$STATE_DIR"
REPO="your-org/your-nexus"
USER_LOGIN="operator"

# snapshot_github mints an installation token via $MINT_TOKEN_BIN
# (defaults to ./monitor/mint-token.sh, relative to cwd). On an
# operator's dev box the real mint-token.sh is reachable and returns
# a token; on a hermetic CI runner it has no GitHub App credentials
# and exits nonzero, which causes `_gh_token=$(...) || return 0` to
# silently abort the entire pipeline. Pin a stub that returns a
# fixed string so the rest of snapshot_github runs against the
# `gh()` function override below.
MINT_STUB="$WORK/mint-token.sh"
printf '#!/usr/bin/env bash\nprintf %%s test-token\n' > "$MINT_STUB"
chmod +x "$MINT_STUB"
MINT_TOKEN_BIN="$MINT_STUB"
export STATE_DIR REPO USER_LOGIN MINT_TOKEN_BIN

# Source the unit under test.
. "$_test_dir/_github.sh"

# Issue search response (comment-source query: q="repo:... is:issue
# is:open"). Issue #1 has one fresh user comment, plus a user comment
# that already has a non-user EYES reaction (suppressed) and a comment
# from a different author (suppressed).
ISSUE_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "number": 1,
          "comments": {
            "nodes": [
              {
                "databaseId": 1001,
                "author": {"login": "operator"},
                "body": "fresh issue comment",
                "reactions": {"nodes": []}
              },
              {
                "databaseId": 1002,
                "author": {"login": "operator"},
                "body": "already-eyes",
                "reactions": {"nodes": [
                  {"content": "EYES", "user": {"login": "your-org-bot"}}
                ]}
              },
              {
                "databaseId": 1003,
                "author": {"login": "someone-else"},
                "body": "non-user comment",
                "reactions": {"nodes": []}
              }
            ]
          }
        }
      ]
    }
  }
}'

# PR search response: PR #42 with one conversation comment + one review-
# thread comment (inline on diff). Plus a self-rocketed conversation
# comment (suppressed: user marked it skip).
PR_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "number": 42,
          "comments": {
            "nodes": [
              {
                "databaseId": 2001,
                "author": {"login": "operator"},
                "body": "watcher should also unstick rate-limit prompts",
                "reactions": {"nodes": []}
              },
              {
                "databaseId": 2002,
                "author": {"login": "operator"},
                "body": "self-rocket opt-out",
                "reactions": {"nodes": [
                  {"content": "ROCKET", "user": {"login": "operator"}}
                ]}
              }
            ]
          },
          "reviewThreads": {
            "nodes": [
              {
                "comments": {
                  "nodes": [
                    {
                      "databaseId": 2050,
                      "author": {"login": "operator"},
                      "body": "this regex misses the third option",
                      "path": "monitor/watcher/_unstick.sh",
                      "reactions": {"nodes": []}
                    }
                  ]
                }
              }
            ]
          }
        }
      ]
    }
  }
}'

# New-issues source response (q="repo:... is:issue is:open
# author:<login>"). One fresh user-authored issue (surfaces), plus
# fixtures the per-test code below will mutate to assert filters.
NEW_ISSUES_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "number": 7,
          "author": {"login": "operator"},
          "body": "fresh issue body — please look at this",
          "reactions": {"nodes": []}
        }
      ]
    }
  }
}'

# Mock gh: branch on the q="..." argument. Three buckets:
#   (a) "is:issue ... author:<login>" -> NEW_ISSUES_FIXTURE
#       (the issue-itself source — must check author: BEFORE is:issue
#        because both contain "is:issue".)
#   (b) "is:issue" without author:    -> ISSUE_FIXTURE   (comment source)
#   (c) "is:pr"                       -> PR_FIXTURE      (PR + review-thread)
gh() {
    [[ "$1" == "api" && "$2" == "graphql" ]] || return 1
    shift 2
    local q=""
    while (( $# > 0 )); do
        case "$1" in
            -f) case "$2" in
                    q=*) q="${2#q=}" ;;
                esac
                shift 2 ;;
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
# keeps serving fixtures on the happy path.
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

# ---- snapshot_github runs both queries ---------------------------------

echo '=== snapshot_github unions issue + PR + PR-review comments + new issues ==='
out=$(snapshot_github | _filter_to_user_author)
assert_contains "issue line for #1" "$out" "issue=1 id=1001 author=operator"
assert_contains "issue body inlined" "$out" "fresh issue comment"
assert_not_contains "issue 1002 (eyes-by-bot) suppressed" "$out" "id=1002"
assert_not_contains "issue 1003 (non-user) suppressed"   "$out" "id=1003"
assert_contains "pr line for #42" "$out" "pr=42 id=2001 author=operator"
assert_contains "pr body inlined" "$out" "watcher should also unstick rate-limit prompts"
assert_not_contains "pr 2002 (self-rocket) suppressed" "$out" "id=2002"
assert_contains "pr_review line for #42" "$out" "pr_review=42 id=2050 author=operator path=monitor/watcher/_unstick.sh"
assert_contains "pr_review body inlined" "$out" "this regex misses the third option"
assert_contains "issue_new line for #7" "$out" "issue_new=7 id=7 author=operator"
assert_contains "issue_new body inlined" "$out" "fresh issue body — please look at this"

# ---- processed-comments dedup applies across all four sources ------

echo '=== processed-comments.txt suppresses comments + issues cross-source ==='
printf 'comment:1001\ncomment:2001\ncomment:2050\nissue:7\n' > "$STATE_DIR/processed-comments.txt"
out=$(snapshot_github | _filter_to_user_author)
assert_not_contains "1001 hidden by dedup" "$out" "id=1001"
assert_not_contains "2001 hidden by dedup" "$out" "id=2001"
assert_not_contains "2050 hidden by dedup" "$out" "id=2050"
assert_not_contains "issue_new=7 hidden by dedup" "$out" "issue_new=7"
rm -f "$STATE_DIR/processed-comments.txt"

# ---- new-issues source: filter / portability assertions -----------

echo '=== new-issues filter: non-user author suppressed ==='
NEW_ISSUES_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "number": 56,
          "author": {"login": "your-org-bot"},
          "body": "bot-opened issue (eg dispatched by routine)",
          "reactions": {"nodes": []}
        }
      ]
    }
  }
}'
out=$(snapshot_github | _filter_to_user_author)
assert_not_contains "bot-authored issue not surfaced" "$out" "issue_new=56"

echo '=== new-issues filter: non-user EYES suppresses ==='
NEW_ISSUES_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "number": 8,
          "author": {"login": "operator"},
          "body": "user issue, bot already has eyes",
          "reactions": {"nodes": [
            {"content": "EYES", "user": {"login": "your-org-bot"}}
          ]}
        }
      ]
    }
  }
}'
out=$(snapshot_github | _filter_to_user_author)
assert_not_contains "non-user EYES suppresses issue_new" "$out" "issue_new=8"

echo '=== new-issues filter: ROCKET from anyone suppresses ==='
NEW_ISSUES_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "number": 9,
          "author": {"login": "operator"},
          "body": "user issue, self-rocketed (skip)",
          "reactions": {"nodes": [
            {"content": "ROCKET", "user": {"login": "operator"}}
          ]}
        },
        {
          "number": 10,
          "author": {"login": "operator"},
          "body": "user issue, bot rocketed (done)",
          "reactions": {"nodes": [
            {"content": "ROCKET", "user": {"login": "your-org-bot"}}
          ]}
        }
      ]
    }
  }
}'
out=$(snapshot_github | _filter_to_user_author)
assert_not_contains "self-rocket suppresses issue_new=9" "$out" "issue_new=9"
assert_not_contains "bot-rocket suppresses issue_new=10" "$out" "issue_new=10"

echo '=== new-issues filter: self-eye still surfaces (portability rule) ==='
NEW_ISSUES_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "number": 11,
          "author": {"login": "operator"},
          "body": "user issue, only the user has eyed it",
          "reactions": {"nodes": [
            {"content": "EYES", "user": {"login": "operator"}}
          ]}
        }
      ]
    }
  }
}'
out=$(snapshot_github | _filter_to_user_author)
assert_contains "self-eye does NOT suppress" "$out" "issue_new=11"

# Restore the default new-issues fixture for the remaining tests.
NEW_ISSUES_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "number": 7,
          "author": {"login": "operator"},
          "body": "fresh issue body — please look at this",
          "reactions": {"nodes": []}
        }
      ]
    }
  }
}'

# ---- Empty PR fixture: comments + new-issues still surface --------

echo '=== empty PR result still returns issue comments + new issues ==='
PR_FIXTURE='{"data":{"search":{"nodes":[]}}}'
out=$(snapshot_github | _filter_to_user_author)
assert_contains "issue line still present" "$out" "issue=1 id=1001"
assert_contains "issue_new still present"  "$out" "issue_new=7 id=7"
assert_not_contains "no pr lines" "$out" "pr="
assert_not_contains "no pr_review lines" "$out" "pr_review="

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
