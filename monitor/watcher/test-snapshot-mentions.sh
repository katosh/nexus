#!/usr/bin/env bash
# Mock-gh unit tests for monitor/watcher/_mentions.sh.
#
# Run: bash monitor/watcher/test-snapshot-mentions.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: shadow the `gh` builtin with a bash function that branches
# on the GraphQL `q=` argument and emits canned JSON. The unit-under-
# test passes the mentions search query as `-f q="mentions:<user>
# sort:updated-desc"`; the mock matches on the leading `mentions:` so
# fixture mutation between tests can swap the response without
# touching the call shape.

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
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness ----

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/state"
mkdir -p "$STATE_DIR"
REPO="your-org/your-nexus"
USER_LOGIN="operator"
# Pre-populate the bot-installed cache so the test doesn't try to
# mint a real installation token. Empty (no installed repos beyond
# $REPO) — individual tests that exercise the bot-skip behaviour
# overwrite this file directly.
BOT_REPOS_CACHE="$STATE_DIR/bot-installed-repos.txt"
: > "$BOT_REPOS_CACHE"
# MINT_TOKEN_BIN points at a stub; the cache is fresh so the mint
# path is never invoked. Stub still emits a marker on call so a
# regression that bypasses the cache shows up loudly.
MINT_TOKEN_BIN="$WORK/mint-token-stub.sh"
cat > "$MINT_TOKEN_BIN" <<'STUB'
#!/usr/bin/env bash
echo "ERROR: mint-token stub called — cache should have been hit" >&2
exit 1
STUB
chmod +x "$MINT_TOKEN_BIN"

export STATE_DIR REPO USER_LOGIN MINT_TOKEN_BIN

# Source the unit under test. `_github.sh` is sourced for the
# `_filter_to_user_author` chokepoint — the issue #86 test below
# pipes `snapshot_mentions` output through it to model production.
. "$_test_dir/_github.sh"
. "$_test_dir/_mentions.sh"

# Default search response. Five candidate nodes:
#   - cross-repo issue with one comment that mentions operator (eligible)
#   - cross-repo PR with two comments (one mention, one no-mention)
#   - in-repo ($REPO) issue with comment mention (must be SKIPPED)
#   - bot-installed-repo issue with comment mention (filled in per-test)
#   - cross-repo issue body itself mentions operator (src=body emit)
SEARCH_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "__typename": "Issue",
          "number": 11,
          "databaseId": 5001,
          "author": {"login": "alice"},
          "body": "no mention here",
          "repository": {"nameWithOwner": "external/repo-a"},
          "reactions": {"nodes": []},
          "comments": {
            "nodes": [
              {
                "databaseId": 9001,
                "author": {"login": "alice"},
                "body": "Hey @operator, thoughts?",
                "reactions": {"nodes": []}
              }
            ]
          }
        },
        {
          "__typename": "PullRequest",
          "number": 22,
          "databaseId": 5002,
          "author": {"login": "bob"},
          "body": "PR description without ping",
          "repository": {"nameWithOwner": "external/repo-b"},
          "reactions": {"nodes": []},
          "comments": {
            "nodes": [
              {
                "databaseId": 9002,
                "author": {"login": "bob"},
                "body": "ping @operator please review",
                "reactions": {"nodes": []}
              },
              {
                "databaseId": 9003,
                "author": {"login": "carol"},
                "body": "no mention in this comment",
                "reactions": {"nodes": []}
              }
            ]
          }
        },
        {
          "__typename": "Issue",
          "number": 33,
          "databaseId": 5003,
          "author": {"login": "operator"},
          "body": "I (@operator) am tracking this here",
          "repository": {"nameWithOwner": "external/repo-c"},
          "reactions": {"nodes": []},
          "comments": {"nodes": []}
        },
        {
          "__typename": "Issue",
          "number": 44,
          "databaseId": 5004,
          "author": {"login": "operator"},
          "body": "in-repo issue body",
          "repository": {"nameWithOwner": "your-org/your-nexus"},
          "reactions": {"nodes": []},
          "comments": {
            "nodes": [
              {
                "databaseId": 9004,
                "author": {"login": "dave"},
                "body": "@operator fyi (in-repo, must be skipped)",
                "reactions": {"nodes": []}
              }
            ]
          }
        },
        {
          "__typename": "PullRequest",
          "number": 55,
          "databaseId": 5005,
          "author": {"login": "eve"},
          "body": "bot-installed-but-not-$REPO PR",
          "repository": {"nameWithOwner": "your-org/another-installed-repo"},
          "reactions": {"nodes": []},
          "comments": {
            "nodes": [
              {
                "databaseId": 9005,
                "author": {"login": "eve"},
                "body": "@operator — bot is installed here, deliveries covers it",
                "reactions": {"nodes": []}
              }
            ]
          }
        }
      ]
    }
  }
}'

# Mock gh. Branch on q=...; only the mentions: query is interesting
# here. Pass-through any other call would normally return empty, but
# `_bot_installed_repos_cache` doesn't reach `gh` in tests because
# the cache file is fresh — so the only hit is the search query.
gh() {
    [[ "$1" == "api" ]] || return 1
    # /installation/repositories live calls are NOT expected — fail
    # loudly so a regression that bypasses the cache shows up.
    case "$2" in
        graphql) ;;
        *) echo "ERROR: unexpected gh api $2 call (cache should suffice)" >&2; return 1 ;;
    esac
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
    if [[ "$q" == mentions:* ]]; then
        printf '%s' "$SEARCH_FIXTURE"
    else
        printf '{}'
    fi
    return 0
}
export -f gh

# `timeout` shadow (issue #367). snapshot_mentions now wraps its
# `gh api graphql` in `timeout -k <k> <s> gh …`; the real binary can't
# exec the `gh` bash-function shadow above, so intercept it: strip the
# `-k <k>` flag and the duration, then run the remaining argv (`gh …`)
# so the mock keeps serving the search fixture.
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

# ---- snapshot_mentions: line shape, $REPO skip, in/cross-repo ----

echo '=== snapshot_mentions: cross-repo comment + body mentions surface ==='
out=$(snapshot_mentions 2>/dev/null)
assert_contains "external comment -> cross_repo= shape (issue)" "$out" "cross_repo=external/repo-a kind=issue n=11 id=9001 author=alice"
assert_contains "external PR comment -> cross_repo= shape (pr)" "$out" "cross_repo=external/repo-b kind=pr n=22 id=9002 author=bob"
assert_contains "external issue body mention -> src=body" "$out" "cross_repo=external/repo-c kind=issue n=33 id=5003 author=operator src=body"
assert_contains "external comment body inlined" "$out" "Hey @operator, thoughts?"
assert_contains "external PR comment body inlined" "$out" "ping @operator please review"
assert_not_contains "comment without mention NOT surfaced" "$out" "id=9003"
assert_not_contains "in-repo (your-org/your-nexus) skipped — comment" "$out" "id=9004"
assert_not_contains "in-repo (your-org/your-nexus) skipped — issue#44" "$out" "n=44"

echo '=== cursor advances to newest databaseId emitted ==='
# With an empty bot-installed cache the "another-installed-repo"
# node is NOT skipped, so id=9005 emits and pushes the cursor.
# max(9001,9002,5003,9005) = 9005.
got_cursor=$(cat "$STATE_DIR/last-mention-cursor.txt" 2>/dev/null)
assert_eq "cursor max id seen = 9005" "$got_cursor" "9005"

# ---- second run: cursor short-circuits everything ----

echo '=== second run: cursor at 9005 -> no output ==='
out=$(snapshot_mentions 2>/dev/null)
assert_eq "empty output on second run" "$out" ""

# ---- bot-installed cache skip ----

echo '=== bot-installed repos are skipped via cache ==='
rm -f "$STATE_DIR/last-mention-cursor.txt"
printf 'your-org/another-installed-repo\n' > "$BOT_REPOS_CACHE"
out=$(snapshot_mentions 2>/dev/null)
assert_not_contains "bot-installed repo skipped" "$out" "your-org/another-installed-repo"
assert_not_contains "bot-installed comment id 9005 not emitted" "$out" "id=9005"
assert_contains "external repo still surfaces" "$out" "cross_repo=external/repo-a"
: > "$BOT_REPOS_CACHE"

# ---- eligibility filter: ROCKET / non-self EYES suppress ----

echo '=== eligibility: ROCKET on comment suppresses ==='
SEARCH_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "__typename": "Issue",
          "number": 11,
          "databaseId": 5001,
          "author": {"login": "alice"},
          "body": "",
          "repository": {"nameWithOwner": "external/repo-a"},
          "reactions": {"nodes": []},
          "comments": {
            "nodes": [
              {
                "databaseId": 9001,
                "author": {"login": "alice"},
                "body": "@operator look",
                "reactions": {"nodes": [
                  {"content": "ROCKET", "user": {"login": "operator"}}
                ]}
              }
            ]
          }
        }
      ]
    }
  }
}'
rm -f "$STATE_DIR/last-mention-cursor.txt"
out=$(snapshot_mentions 2>/dev/null)
assert_not_contains "rocketed comment suppressed" "$out" "id=9001"

echo '=== eligibility: non-self EYES suppresses ==='
SEARCH_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "__typename": "Issue",
          "number": 12,
          "databaseId": 5010,
          "author": {"login": "alice"},
          "body": "",
          "repository": {"nameWithOwner": "external/repo-x"},
          "reactions": {"nodes": []},
          "comments": {
            "nodes": [
              {
                "databaseId": 9010,
                "author": {"login": "alice"},
                "body": "@operator look",
                "reactions": {"nodes": [
                  {"content": "EYES", "user": {"login": "your-org-bot"}}
                ]}
              }
            ]
          }
        }
      ]
    }
  }
}'
rm -f "$STATE_DIR/last-mention-cursor.txt"
out=$(snapshot_mentions 2>/dev/null)
assert_not_contains "non-self EYES suppresses" "$out" "id=9010"

echo '=== eligibility: self EYES is fine (still surfaces) ==='
SEARCH_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "__typename": "Issue",
          "number": 13,
          "databaseId": 5011,
          "author": {"login": "alice"},
          "body": "",
          "repository": {"nameWithOwner": "external/repo-y"},
          "reactions": {"nodes": []},
          "comments": {
            "nodes": [
              {
                "databaseId": 9011,
                "author": {"login": "alice"},
                "body": "@operator look",
                "reactions": {"nodes": [
                  {"content": "EYES", "user": {"login": "operator"}}
                ]}
              }
            ]
          }
        }
      ]
    }
  }
}'
rm -f "$STATE_DIR/last-mention-cursor.txt"
out=$(snapshot_mentions 2>/dev/null)
assert_contains "self-EYES does not suppress" "$out" "id=9011"

# ---- processed-comments dedup ----

echo '=== processed-comments dedup hides comment / body emits ==='
SEARCH_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "__typename": "Issue",
          "number": 21,
          "databaseId": 6020,
          "author": {"login": "operator"},
          "body": "I (@operator) opened this",
          "repository": {"nameWithOwner": "external/repo-d"},
          "reactions": {"nodes": []},
          "comments": {
            "nodes": [
              {
                "databaseId": 9020,
                "author": {"login": "alice"},
                "body": "@operator ping",
                "reactions": {"nodes": []}
              }
            ]
          }
        }
      ]
    }
  }
}'
rm -f "$STATE_DIR/last-mention-cursor.txt"
printf 'mention:9020\nmention:issue:21\n' > "$STATE_DIR/processed-comments.txt"
out=$(snapshot_mentions 2>/dev/null)
assert_not_contains "comment 9020 hidden by mention: dedup" "$out" "id=9020"
assert_not_contains "issue 21 body hidden by mention:issue: dedup" "$out" "n=21"
rm -f "$STATE_DIR/processed-comments.txt"

# ---- word-boundary mention regex ----

echo '=== mention regex: false-positive guards ==='
SEARCH_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "__typename": "Issue",
          "number": 31,
          "databaseId": 7001,
          "author": {"login": "alice"},
          "body": "",
          "repository": {"nameWithOwner": "external/repo-e"},
          "reactions": {"nodes": []},
          "comments": {
            "nodes": [
              {
                "databaseId": 9100,
                "author": {"login": "alice"},
                "body": "email me at foo@operator.com (no real mention)",
                "reactions": {"nodes": []}
              },
              {
                "databaseId": 9101,
                "author": {"login": "alice"},
                "body": "longer slug @operator-staging not a match",
                "reactions": {"nodes": []}
              },
              {
                "databaseId": 9102,
                "author": {"login": "alice"},
                "body": "real mid-sentence cc @operator, fyi",
                "reactions": {"nodes": []}
              },
              {
                "databaseId": 9103,
                "author": {"login": "alice"},
                "body": "leading @operator",
                "reactions": {"nodes": []}
              },
              {
                "databaseId": 9104,
                "author": {"login": "alice"},
                "body": "trailing here @operator",
                "reactions": {"nodes": []}
              }
            ]
          }
        }
      ]
    }
  }
}'
rm -f "$STATE_DIR/last-mention-cursor.txt"
out=$(snapshot_mentions 2>/dev/null)
assert_not_contains "domain-suffix in email NOT a mention (id=9100)" "$out" "id=9100"
assert_not_contains "longer-slug NOT a mention (id=9101)" "$out" "id=9101"
assert_contains "mid-sentence mention surfaces (id=9102)" "$out" "id=9102"
assert_contains "leading mention surfaces (id=9103)" "$out" "id=9103"
assert_contains "trailing mention surfaces (id=9104)" "$out" "id=9104"

# ---- empty USER_LOGIN guard ----

echo '=== empty USER_LOGIN: graceful skip ==='
saved_user="$USER_LOGIN"
USER_LOGIN=""
rm -f "$STATE_DIR/last-mention-cursor.txt"
out=$(snapshot_mentions 2>/dev/null)
assert_eq "no output when USER_LOGIN unset" "$out" ""
USER_LOGIN="$saved_user"

# ---- empty search response ----

echo '=== empty graphql response: graceful skip ==='
SEARCH_FIXTURE='{"data": {"search": {"nodes": []}}}'
rm -f "$STATE_DIR/last-mention-cursor.txt"
out=$(snapshot_mentions 2>/dev/null)
assert_eq "no output on empty search" "$out" ""
got_cursor=$(cat "$STATE_DIR/last-mention-cursor.txt" 2>/dev/null)
assert_eq "no cursor written on empty search" "$got_cursor" ""

# ---- cursor short-circuit: ids below cursor skipped ----

echo '=== cursor: ids below the cursor are skipped ==='
SEARCH_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "__typename": "Issue",
          "number": 41,
          "databaseId": 100,
          "author": {"login": "alice"},
          "body": "@operator in body",
          "repository": {"nameWithOwner": "external/repo-old"},
          "reactions": {"nodes": []},
          "comments": {
            "nodes": [
              {
                "databaseId": 200,
                "author": {"login": "alice"},
                "body": "@operator older comment",
                "reactions": {"nodes": []}
              },
              {
                "databaseId": 9999,
                "author": {"login": "alice"},
                "body": "@operator newest comment",
                "reactions": {"nodes": []}
              }
            ]
          }
        }
      ]
    }
  }
}'
printf '500\n' > "$STATE_DIR/last-mention-cursor.txt"
out=$(snapshot_mentions 2>/dev/null)
assert_not_contains "id below cursor not emitted (200)" "$out" "id=200"
assert_not_contains "issue body below cursor not emitted (n=41 src=body)" "$out" "n=41 id=100"
assert_contains "id above cursor still emitted (9999)" "$out" "id=9999"
got_cursor=$(cat "$STATE_DIR/last-mention-cursor.txt" 2>/dev/null)
assert_eq "cursor advances to 9999" "$got_cursor" "9999"

# ---- issue #86: chokepoint drops non-user-authored mentions ----
#
# `snapshot_mentions` still emits any author's @-mention of the user
# (its mandate is cross-repo *discovery*). The downstream chokepoint
# `_filter_to_user_author` then drops everything not authored by
# $USER_LOGIN. This test models the production pipeline by piping the
# two together.

echo '=== chokepoint: only USER_LOGIN-authored cross-repo content surfaces ==='
SEARCH_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "__typename": "Issue",
          "number": 91,
          "databaseId": 8901,
          "author": {"login": "other-nexus-bot[bot]"},
          "body": "@operator sibling bot opened this",
          "repository": {"nameWithOwner": "external/repo-foo"},
          "reactions": {"nodes": []},
          "comments": {
            "nodes": [
              {
                "databaseId": 9901,
                "author": {"login": "other-nexus-bot[bot]"},
                "body": "@operator sibling bot comment",
                "reactions": {"nodes": []}
              },
              {
                "databaseId": 9902,
                "author": {"login": "your-org-bot[bot]"},
                "body": "@operator self bot comment",
                "reactions": {"nodes": []}
              },
              {
                "databaseId": 9903,
                "author": {"login": "operator"},
                "body": "@operator self-mention in my own comment",
                "reactions": {"nodes": []}
              }
            ]
          }
        }
      ]
    }
  }
}'
rm -f "$STATE_DIR/last-mention-cursor.txt" "$STATE_DIR/processed-comments.txt"
out=$(snapshot_mentions 2>/dev/null | _filter_to_user_author)
assert_not_contains "otheruser bot issue-body mention dropped" "$out" "n=91 id=8901"
assert_not_contains "otheruser bot comment dropped"            "$out" "id=9901"
assert_not_contains "your-org bot comment dropped"            "$out" "id=9902"
assert_contains    "operator self-mention surfaces"             "$out" "id=9903 author=operator"
# Body previews of dropped headers must drop with them.
assert_not_contains "sibling bot body preview dropped" "$out" "sibling bot comment"
assert_not_contains "self bot body preview dropped"    "$out" "self bot comment"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
