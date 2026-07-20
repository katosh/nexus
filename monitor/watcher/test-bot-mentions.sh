#!/usr/bin/env bash
# Mock-curl unit tests for `snapshot_bot_mentions` in
# monitor/watcher/_mentions.sh — the webhook-FREE, poll-based channel
# that surfaces `@<bot>`-mentions on INSTALLED non-asset repos (the gap
# that opens when the deliveries webhook is unavailable/disabled; the
# real silent case was comment 4780061875 on your-org/nexus-code#334).
#
# Run: bash monitor/watcher/test-bot-mentions.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: shadow `curl` with a bash function that records its argv (so
# the wedge-safety assertion can prove --connect-timeout + --max-time are
# always passed) and emits a canned GraphQL search response. The
# bot-installed cache is pre-populated fresh so the mint path is never
# reached for repo enumeration; a separate mint stub supplies the curl
# token. Companion to test-snapshot-mentions.sh (the user-mention path)
# and test-cross-repo-mention-filter.sh (the downstream gate).

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
BOT_LOGIN="your-org-bot"
CROSS_REPO_SURFACE="mention_only"
MENTIONS_CONNECT_TIMEOUT=5
MENTIONS_MAX_TIME=20

# Pre-populate the bot-installed cache FRESH so `_bot_installed_repos_cache`
# never reaches `gh`/mint for enumeration. nexus-code is the installed
# non-asset repo the fix targets; $REPO is installed but skipped as the
# asset repo. external/* is deliberately absent (non-installed).
BOT_REPOS_CACHE="$STATE_DIR/bot-installed-repos.txt"
cat > "$BOT_REPOS_CACHE" <<EOF
your-org/your-nexus
your-org/nexus-code
EOF

# Token mint stub — supplies the curl Bearer token (separate from the
# cache path). Echoes a fake token; a real mint must never be invoked.
MINT_TOKEN_BIN="$WORK/mint-token-stub.sh"
cat > "$MINT_TOKEN_BIN" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'fake-installation-token'
STUB
chmod +x "$MINT_TOKEN_BIN"

export STATE_DIR REPO USER_LOGIN BOT_LOGIN CROSS_REPO_SURFACE \
       MENTIONS_CONNECT_TIMEOUT MENTIONS_MAX_TIME MINT_TOKEN_BIN

. "$_test_dir/_github.sh"
. "$_test_dir/_mentions.sh"

# Mock curl. Records argv to $CURL_ARGV_FILE (for the timeout-flag
# assertion), honours a forced-failure switch ($CURL_FAIL), else emits
# $SEARCH_FIXTURE. Note: the unit pipes the request body via -d; we
# ignore it and key the whole response on the fixture.
CURL_ARGV_FILE="$WORK/curl.argv"
CURL_FAIL=0
curl() {
    printf '%s\n' "$*" >> "$CURL_ARGV_FILE"
    if [[ "$CURL_FAIL" == "1" ]]; then
        return 28   # curl's "operation timed out" code
    fi
    printf '%s' "$SEARCH_FIXTURE"
    return 0
}
export -f curl

# Default fixture. Covers:
#   - installed non-asset repo (nexus-code) comment that @-mentions the
#     bot                                                  → MUST emit mention=
#   - installed non-asset repo comment WITHOUT @bot        → must NOT emit
#   - non-installed repo (external/repo-x) @bot comment    → must NOT emit
#   - $REPO (your-org/your-nexus) @bot comment            → must NOT emit
#   - installed non-asset repo issue BODY @-mentions bot   → src=body emit
SEARCH_FIXTURE='{
  "data": {
    "search": {
      "nodes": [
        {
          "__typename": "PullRequest",
          "number": 334,
          "databaseId": 5334,
          "author": {"login": "operator"},
          "body": "PR body, no ping",
          "repository": {"nameWithOwner": "your-org/nexus-code"},
          "reactions": {"nodes": []},
          "comments": {
            "nodes": [
              {
                "databaseId": 4780061875,
                "author": {"login": "operator"},
                "body": "@your-org-bot if ids are always resolved from the stable id NAME, is there a benefit",
                "reactions": {"nodes": []}
              },
              {
                "databaseId": 4780061900,
                "author": {"login": "operator"},
                "body": "follow-up with no bot mention here",
                "reactions": {"nodes": []}
              }
            ]
          }
        },
        {
          "__typename": "Issue",
          "number": 77,
          "databaseId": 5077,
          "author": {"login": "operator"},
          "body": "no body ping",
          "repository": {"nameWithOwner": "external/repo-x"},
          "reactions": {"nodes": []},
          "comments": {
            "nodes": [
              {
                "databaseId": 4000,
                "author": {"login": "operator"},
                "body": "@your-org-bot please look (non-installed repo)",
                "reactions": {"nodes": []}
              }
            ]
          }
        },
        {
          "__typename": "Issue",
          "number": 1,
          "databaseId": 5001,
          "author": {"login": "operator"},
          "body": "asset-repo body",
          "repository": {"nameWithOwner": "your-org/your-nexus"},
          "reactions": {"nodes": []},
          "comments": {
            "nodes": [
              {
                "databaseId": 4100,
                "author": {"login": "operator"},
                "body": "@your-org-bot in-asset-repo (snapshot_github covers it)",
                "reactions": {"nodes": []}
              }
            ]
          }
        },
        {
          "__typename": "Issue",
          "number": 99,
          "databaseId": 4780065000,
          "author": {"login": "operator"},
          "body": "tracking @your-org-bot in the issue body itself",
          "repository": {"nameWithOwner": "your-org/nexus-code"},
          "reactions": {"nodes": []},
          "comments": {"nodes": []}
        }
      ]
    }
  }
}'

# ---- core: installed non-asset @bot mention surfaces as mention= ----

echo '=== snapshot_bot_mentions: installed-repo @bot comment -> mention= ==='
out=$(snapshot_bot_mentions 2>/dev/null)
assert_contains "nexus-code @bot comment -> mention= (the #334 case)" \
    "$out" "mention=your-org/nexus-code kind=pr n=334 id=4780061875 author=operator"
assert_contains "comment body inlined" "$out" "if ids are always resolved from the stable id NAME"
assert_contains "installed-repo issue BODY @bot -> src=body" \
    "$out" "mention=your-org/nexus-code kind=issue n=99 id=4780065000 author=operator src=body"

assert_not_contains "comment without @bot NOT surfaced"          "$out" "id=4780061900"
assert_not_contains "non-installed repo @bot NOT surfaced"       "$out" "id=4000"
assert_not_contains "non-installed repo not present"             "$out" "external/repo-x"
assert_not_contains "asset repo (\$REPO) @bot NOT surfaced"      "$out" "id=4100"
assert_not_contains "asset repo skipped (no mention= line)"      "$out" "mention=your-org/your-nexus"

# ---- wedge-safety: every curl carries --connect-timeout + --max-time ----

echo '=== wedge-safety: bounded curl (connect + max timeouts) ==='
argv=$(cat "$CURL_ARGV_FILE" 2>/dev/null)
assert_contains "curl passed --connect-timeout" "$argv" "--connect-timeout 5"
assert_contains "curl passed --max-time"        "$argv" "--max-time 20"
assert_contains "curl POSTs to the graphql endpoint" "$argv" "https://api.github.com/graphql"

# ---- wedge-safety: a failed/timed-out curl is NON-FATAL ----

echo '=== wedge-safety: curl failure is non-fatal (loop never blocks) ==='
rm -f "$STATE_DIR/last-bot-mention-cursor.txt"
CURL_FAIL=1
out=$(snapshot_bot_mentions 2>/dev/null; echo "SENTINEL_RAN=$?")
CURL_FAIL=0
assert_contains "function returned 0 and sentinel ran after it" "$out" "SENTINEL_RAN=0"
assert_not_contains "no emit on curl failure" "$out" "mention=your-org/nexus-code"

# ---- cursor: advance to newest emitted id, then short-circuit ----

echo '=== cursor advances to newest emitted databaseId ==='
rm -f "$STATE_DIR/last-bot-mention-cursor.txt"
out=$(snapshot_bot_mentions 2>/dev/null)
got_cursor=$(cat "$STATE_DIR/last-bot-mention-cursor.txt" 2>/dev/null)
# max emitted id = max(4780061875, 4780065000) = 4780065000
assert_eq "cursor = newest emitted id" "$got_cursor" "4780065000"

echo '=== second run: cursor short-circuits everything ==='
out=$(snapshot_bot_mentions 2>/dev/null)
assert_eq "empty output on second run" "$out" ""

# ---- processed-comments dedup (botmention: prefix) ----

echo '=== processed-comments dedup hides the comment / body emit ==='
rm -f "$STATE_DIR/last-bot-mention-cursor.txt"
printf 'botmention:4780061875\nbotmention:issue:99\n' > "$STATE_DIR/processed-comments.txt"
out=$(snapshot_bot_mentions 2>/dev/null)
assert_not_contains "comment hidden by botmention: dedup"      "$out" "id=4780061875"
assert_not_contains "issue body hidden by botmention:issue: dedup" "$out" "n=99 id=4780065000"
rm -f "$STATE_DIR/processed-comments.txt"

# ---- eligibility: ROCKET / non-self EYES suppress ----

echo '=== eligibility: ROCKET on comment suppresses ==='
SEARCH_FIXTURE='{
  "data": { "search": { "nodes": [
    { "__typename": "Issue", "number": 5, "databaseId": 6005,
      "author": {"login": "operator"}, "body": "",
      "repository": {"nameWithOwner": "your-org/nexus-code"},
      "reactions": {"nodes": []},
      "comments": { "nodes": [
        { "databaseId": 6100, "author": {"login": "operator"},
          "body": "@your-org-bot look",
          "reactions": {"nodes": [{"content":"ROCKET","user":{"login":"operator"}}]} } ] } } ] } } }'
rm -f "$STATE_DIR/last-bot-mention-cursor.txt"
out=$(snapshot_bot_mentions 2>/dev/null)
assert_not_contains "rocketed comment suppressed" "$out" "id=6100"

echo '=== eligibility: non-self EYES suppresses; self EYES surfaces ==='
SEARCH_FIXTURE='{
  "data": { "search": { "nodes": [
    { "__typename": "Issue", "number": 6, "databaseId": 6006,
      "author": {"login": "operator"}, "body": "",
      "repository": {"nameWithOwner": "your-org/nexus-code"},
      "reactions": {"nodes": []},
      "comments": { "nodes": [
        { "databaseId": 6200, "author": {"login": "operator"},
          "body": "@your-org-bot one",
          "reactions": {"nodes": [{"content":"EYES","user":{"login":"your-org-bot"}}]} },
        { "databaseId": 6201, "author": {"login": "operator"},
          "body": "@your-org-bot two",
          "reactions": {"nodes": [{"content":"EYES","user":{"login":"operator"}}]} } ] } } ] } } }'
rm -f "$STATE_DIR/last-bot-mention-cursor.txt"
out=$(snapshot_bot_mentions 2>/dev/null)
assert_not_contains "non-self EYES suppresses (id=6200)" "$out" "id=6200"
assert_contains    "self EYES still surfaces (id=6201)"  "$out" "id=6201"

# ---- word-boundary mention regex ----

echo '=== mention regex: false-positive guards ==='
SEARCH_FIXTURE='{
  "data": { "search": { "nodes": [
    { "__typename": "Issue", "number": 7, "databaseId": 7007,
      "author": {"login": "operator"}, "body": "",
      "repository": {"nameWithOwner": "your-org/nexus-code"},
      "reactions": {"nodes": []},
      "comments": { "nodes": [
        { "databaseId": 7100, "author": {"login": "operator"},
          "body": "email foo@your-org-bot.example (not a real ping)",
          "reactions": {"nodes": []} },
        { "databaseId": 7101, "author": {"login": "operator"},
          "body": "longer slug @your-org-bot-staging no match",
          "reactions": {"nodes": []} },
        { "databaseId": 7102, "author": {"login": "operator"},
          "body": "real ping cc @your-org-bot, thanks",
          "reactions": {"nodes": []} } ] } } ] } } }'
rm -f "$STATE_DIR/last-bot-mention-cursor.txt"
out=$(snapshot_bot_mentions 2>/dev/null)
assert_not_contains "email-suffix NOT a mention (id=7100)"  "$out" "id=7100"
assert_not_contains "longer-slug NOT a mention (id=7101)"   "$out" "id=7101"
assert_contains    "real mid-sentence mention (id=7102)"    "$out" "id=7102"

# ---- BOT_LOGIN with [bot] suffix is stripped before search/match ----

echo '=== BOT_LOGIN [bot] suffix stripped ==='
SEARCH_FIXTURE='{
  "data": { "search": { "nodes": [
    { "__typename": "Issue", "number": 8, "databaseId": 8008,
      "author": {"login": "operator"}, "body": "",
      "repository": {"nameWithOwner": "your-org/nexus-code"},
      "reactions": {"nodes": []},
      "comments": { "nodes": [
        { "databaseId": 8100, "author": {"login": "operator"},
          "body": "@your-org-bot hi",
          "reactions": {"nodes": []} } ] } } ] } } }'
saved_bot="$BOT_LOGIN"
BOT_LOGIN="your-org-bot[bot]"
rm -f "$STATE_DIR/last-bot-mention-cursor.txt"
out=$(snapshot_bot_mentions 2>/dev/null)
assert_contains "[bot]-suffixed BOT_LOGIN still matches @<slug>" "$out" "id=8100"
BOT_LOGIN="$saved_bot"

# ---- empty BOT_LOGIN guard (load-bearing now the channel is default-ON) ----
# Defaulting bot_mentions ON must NOT break or spam operators with no bot
# identity: the empty-handle path must be a clean no-op — no emit, no error,
# and crucially NO curl (an `@`-query with no slug would be malformed, and
# even a well-formed-but-handle-less search would burn a GraphQL point every
# cycle for nothing). main.sh carries the one-time startup warning instead.

echo '=== empty BOT_LOGIN: graceful no-op (no emit, no curl, no error) ==='
saved_bot="$BOT_LOGIN"
BOT_LOGIN=""
rm -f "$STATE_DIR/last-bot-mention-cursor.txt"
: > "$CURL_ARGV_FILE"   # reset the curl-invocation ledger
out=$(snapshot_bot_mentions 2>/dev/null; echo "RC=$?")
assert_contains "empty BOT_LOGIN returns 0 (non-fatal no-op)" "$out" "RC=0"
assert_not_contains "no output when BOT_LOGIN unset" "$out" "mention="
curl_after=$(cat "$CURL_ARGV_FILE" 2>/dev/null)
assert_eq "no curl issued with an empty handle" "$curl_after" ""
BOT_LOGIN="$saved_bot"

# ---- empty installed cache -> no emits (safe direction) ----

echo '=== empty installed-repo cache: no false mention= ==='
SEARCH_FIXTURE='{
  "data": { "search": { "nodes": [
    { "__typename": "Issue", "number": 9, "databaseId": 9009,
      "author": {"login": "operator"}, "body": "",
      "repository": {"nameWithOwner": "your-org/nexus-code"},
      "reactions": {"nodes": []},
      "comments": { "nodes": [
        { "databaseId": 9100, "author": {"login": "operator"},
          "body": "@your-org-bot hi",
          "reactions": {"nodes": []} } ] } } ] } } }'
saved_cache=$(cat "$BOT_REPOS_CACHE")
: > "$BOT_REPOS_CACHE"
rm -f "$STATE_DIR/last-bot-mention-cursor.txt"
out=$(snapshot_bot_mentions 2>/dev/null)
assert_eq "empty cache -> no emit" "$out" ""
printf '%s\n' "$saved_cache" > "$BOT_REPOS_CACHE"

# ---- production pipeline: author chokepoint + mention_only gate ----

echo '=== composed: _filter_to_user_author | _filter_cross_repo_surface ==='
SEARCH_FIXTURE='{
  "data": { "search": { "nodes": [
    { "__typename": "PullRequest", "number": 40, "databaseId": 7400,
      "author": {"login": "operator"}, "body": "",
      "repository": {"nameWithOwner": "your-org/nexus-code"},
      "reactions": {"nodes": []},
      "comments": { "nodes": [
        { "databaseId": 7401, "author": {"login": "operator"},
          "body": "@your-org-bot operator addressing the bot",
          "reactions": {"nodes": []} },
        { "databaseId": 7402, "author": {"login": "other-nexus-bot[bot]"},
          "body": "@your-org-bot sibling bot addressing the bot",
          "reactions": {"nodes": []} } ] } } ] } } }'
rm -f "$STATE_DIR/last-bot-mention-cursor.txt" "$STATE_DIR/processed-comments.txt"
out=$(snapshot_bot_mentions 2>/dev/null | _filter_to_user_author | _filter_cross_repo_surface)
assert_contains    "operator @bot survives the full pipeline" "$out" "id=7401 author=operator"
assert_not_contains "sibling-bot author dropped at chokepoint"  "$out" "id=7402"

# ---- config default: bot_mentions_enabled defaults to true ----
# The operator decision (2026-06-23) made the channel default-ON. Assert the
# effective default that `_config.sh` resolves when the key is ABSENT from
# nexus.yml (and no MONITOR_BOT_MENTIONS_ENABLED env override). Run in a
# clean `bash` so sourcing `_config.sh` (which sets ~50 globals) can't clobber
# this harness's state. The `_cfg` stub mimics an absent key by echoing the
# caller-supplied default ($2), exactly as `config/load.sh` does on a miss.

echo '=== config default: bot_mentions_enabled defaults to true ==='
CFG_STUB="$WORK/cfg-default-stub.sh"
cat > "$CFG_STUB" <<'STUB'
#!/usr/bin/env bash
# $1 = config key, $2 = default. Absent-key behaviour: echo the default.
printf '%s' "${2:-}"
STUB
chmod +x "$CFG_STUB"
default_val=$(env -u MONITOR_BOT_MENTIONS_ENABLED \
    _cfg="$CFG_STUB" NEXUS_ROOT="$WORK" \
    bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "$BOT_MENTIONS_ENABLED"' \
    _ "$_test_dir/_config.sh")
assert_eq "BOT_MENTIONS_ENABLED defaults to true (key absent, no env override)" \
    "$default_val" "true"

# And an explicit env opt-OUT still wins over the new default.
optout_val=$(env MONITOR_BOT_MENTIONS_ENABLED=false \
    _cfg="$CFG_STUB" NEXUS_ROOT="$WORK" \
    bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "$BOT_MENTIONS_ENABLED"' \
    _ "$_test_dir/_config.sh")
assert_eq "explicit opt-out (env=false) overrides the default-ON" \
    "$optout_val" "false"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
