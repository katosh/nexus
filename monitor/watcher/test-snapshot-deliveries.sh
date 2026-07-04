#!/usr/bin/env bash
# Mock-curl unit tests for monitor/watcher/_deliveries.sh.
#
# Run: bash monitor/watcher/test-snapshot-deliveries.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: shadow `curl` with a bash function that branches on the URL
# arg and emits canned headers + payload bodies. The unit-under-test
# uses the standard curl invocation shape (`-D <header_file> -o
# <body_file> -w '%{http_code}'`), so the mock writes both files and
# echoes the status code.

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
MINT_JWT_BIN="$WORK/mint-jwt-stub.sh"
cat > "$MINT_JWT_BIN" <<'STUB'
#!/usr/bin/env bash
# Stub: emits a fake JWT regardless of args.
printf '%s\n' 'fake.jwt.value'
STUB
chmod +x "$MINT_JWT_BIN"

export STATE_DIR REPO USER_LOGIN MINT_JWT_BIN

# Source the unit under test. `_github.sh` is sourced for the
# `_filter_to_user_author` chokepoint — issue #86 moved the user-
# author rule there, so the production pipeline runs
# `snapshot_deliveries | _filter_to_user_author`.
. "$_test_dir/_github.sh"
. "$_test_dir/_deliveries.sh"

# Fixtures live as files under $WORK/fixtures so the curl mock can
# branch on URL.

mkdir -p "$WORK/fixtures"

# Listing endpoint: array of delivery summaries (newest-first).
LIST_BODY="$WORK/fixtures/list.json"
LIST_HDR="$WORK/fixtures/list.hdr"
cat > "$LIST_BODY" <<'JSON'
[
  {"id": 1001, "guid": "guid-1001", "event": "issue_comment",       "action": "created"},
  {"id": 1002, "guid": "guid-1002", "event": "pull_request_review_comment", "action": "created"},
  {"id": 1003, "guid": "guid-1003", "event": "issues",              "action": "opened"},
  {"id": 1004, "guid": "guid-1004", "event": "issue_comment",       "action": "created"},
  {"id": 1005, "guid": "guid-1005", "event": "issue_comment",       "action": "edited"},
  {"id": 1006, "guid": "guid-1006", "event": "push",                "action": null}
]
JSON
printf 'HTTP/2 200 \n\n' > "$LIST_HDR"

# Per-delivery payload fixtures. The deliveries detail endpoint returns
# { id, guid, ..., event, action, request: { headers, payload } }.
mk_detail() {
    local id="$1" event="$2" action="$3" payload="$4"
    cat > "$WORK/fixtures/${id}.json" <<JSON
{
  "id": ${id},
  "event": "${event}",
  "action": "${action}",
  "request": {
    "headers": {"X-GitHub-Event": "${event}"},
    "payload": ${payload}
  }
}
JSON
}

# 1001: in-repo issue comment, author=operator -> existing issue= shape.
mk_detail 1001 issue_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/your-nexus"},
  "issue": {"number": 11, "pull_request": null},
  "comment": {"id": 91001, "user": {"login": "operator"}, "body": "fresh issue comment"}
}'

# 1002: in-repo PR review-thread comment from operator -> pr_review= shape.
mk_detail 1002 pull_request_review_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/your-nexus"},
  "pull_request": {"number": 42},
  "comment": {"id": 92002, "path": "monitor/watcher/_deliveries.sh", "user": {"login": "operator"}, "body": "review comment"}
}'

# 1003: in-repo issues:opened by operator -> issue_new= shape.
mk_detail 1003 issues opened '{
  "action": "opened",
  "repository": {"full_name": "your-org/your-nexus"},
  "issue": {"number": 17, "user": {"login": "operator"}, "body": "fresh issue body"}
}'

# 1004: cross-repo issue_comment from someone-else, body @-mentions bot.
mk_detail 1004 issue_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/some-other-repo"},
  "issue": {"number": 88, "pull_request": null},
  "comment": {"id": 94004, "user": {"login": "operator"}, "body": "Hey @your-org-bot, can you look at this?"}
}'

# 1005: in-repo issue_comment but action=edited -> emit_ok=false.
mk_detail 1005 issue_comment edited '{
  "action": "edited",
  "repository": {"full_name": "your-org/your-nexus"},
  "issue": {"number": 22, "pull_request": null},
  "comment": {"id": 95005, "user": {"login": "operator"}, "body": "edit"}
}'

# Mock curl. Branches on the last positional URL arg and writes the
# header file (+ optional body file) with canned content; echoes the
# status code on stdout (the unit-under-test reads it via -w).
curl() {
    local hdr_target="" body_target="" url="" status_w=0
    # Walk argv to extract -D, -o, -w '%{http_code}' and the URL.
    local prev=""
    for arg in "$@"; do
        case "$prev" in
            -D) hdr_target="$arg"; prev=""; continue ;;
            -o) body_target="$arg"; prev=""; continue ;;
            -w) status_w=1; prev=""; continue ;;
            -H) prev=""; continue ;;
        esac
        case "$arg" in
            -D|-o|-H|-w) prev="$arg" ;;
            -sS) ;;
            -*)  ;;
            http*) url="$arg" ;;
        esac
    done

    # Choose the response.
    local code=200 src_hdr="" src_body=""
    case "$url" in
        *'/app/hook/deliveries?per_page='*)
            src_hdr="$LIST_HDR"; src_body="$LIST_BODY" ;;
        *'/app/hook/deliveries/'*)
            local id="${url##*/}"
            id="${id%%\?*}"
            src_body="$WORK/fixtures/${id}.json"
            if [[ ! -f "$src_body" ]]; then
                code=404
                src_body="$WORK/fixtures/.empty"
                printf '{"message":"Not Found"}' > "$src_body"
            fi
            src_hdr="$WORK/fixtures/.detail-hdr"
            printf 'HTTP/2 %s \n\n' "$code" > "$src_hdr"
            ;;
        *)
            code=404
            src_body="$WORK/fixtures/.empty"
            : > "$src_body"
            src_hdr="$WORK/fixtures/.detail-hdr"
            printf 'HTTP/2 %s \n\n' "$code" > "$src_hdr"
            ;;
    esac

    [[ -n "$hdr_target" ]] && cp "$src_hdr"  "$hdr_target"
    [[ -n "$body_target" ]] && cp "$src_body" "$body_target"
    (( status_w == 1 )) && printf '%s' "$code"
    return 0
}
export -f curl

# ---- snapshot_deliveries: emits expected lines, advances cursor ----

echo '=== snapshot_deliveries: line shapes from each event type ==='
out=$(snapshot_deliveries 2>/dev/null | _filter_to_user_author)
assert_contains "issue_comment -> issue= shape" "$out" "issue=11 id=91001 author=operator"
assert_contains "pr_review_comment -> pr_review= shape" "$out" "pr_review=42 id=92002 author=operator path=monitor/watcher/_deliveries.sh"
assert_contains "issues opened -> issue_new= shape" "$out" "issue_new=17 id=17 author=operator"
assert_contains "cross-repo user-authored event -> mention= shape with repo=" "$out" "mention=your-org/some-other-repo"
assert_contains "cross-repo mention has kind= field" "$out" "kind=issue n=88"
assert_not_contains "edited action filtered" "$out" "id=95005"
assert_not_contains "push event filtered" "$out" "guid-1006"

echo '=== cursor advances to newest GUID (guid-1001) ==='
got_cursor=$(cat "$STATE_DIR/last-delivery-cursor.txt" 2>/dev/null)
assert_eq "cursor" "$got_cursor" "guid-1001"

# ---- second run with cursor: nothing new ----

echo '=== second run with cursor at newest -> no output ==='
out=$(snapshot_deliveries 2>/dev/null | _filter_to_user_author)
assert_eq "empty output on second run" "$out" ""

# ---- 404 handling: empty deliveries log ----

echo '=== 404 on listing endpoint -> empty output, no error ==='
rm -f "$STATE_DIR/last-delivery-cursor.txt"
printf 'HTTP/2 404 \n\n' > "$LIST_HDR"
printf '{"message":"Not Found"}' > "$LIST_BODY"
# Also patch the curl mock by mutating the fixture file directly —
# the mock reads $LIST_BODY each call so this takes effect immediately.
out=$(snapshot_deliveries 2>/dev/null | _filter_to_user_author)
assert_eq "empty output on 404" "$out" ""
assert_eq "no cursor written on 404" "$(cat "$STATE_DIR/last-delivery-cursor.txt" 2>/dev/null)" ""
# Restore for subsequent tests.
printf 'HTTP/2 200 \n\n' > "$LIST_HDR"
cat > "$LIST_BODY" <<'JSON'
[
  {"id": 1001, "guid": "guid-1001", "event": "issue_comment", "action": "created"}
]
JSON

# ---- issue #86: three-author fixture, only USER_LOGIN surfaces ----
#
# Drops any delivery whose author isn't $USER_LOGIN via the chokepoint.
# Same fixture-author trio used across every path's test
# (huangy57-nexus-bot[bot], your-org-bot[bot], operator) so any
# regression in the universal-filter rule fails identically everywhere.

echo '=== universal user-author filter: bot-authored deliveries drop, user surfaces ==='
cat > "$LIST_BODY" <<'JSON'
[
  {"id": 7001, "guid": "guid-7001", "event": "issue_comment", "action": "created"},
  {"id": 7002, "guid": "guid-7002", "event": "issue_comment", "action": "created"},
  {"id": 7003, "guid": "guid-7003", "event": "issue_comment", "action": "created"},
  {"id": 7010, "guid": "guid-7010", "event": "issues",        "action": "opened"},
  {"id": 7011, "guid": "guid-7011", "event": "issues",        "action": "opened"},
  {"id": 7012, "guid": "guid-7012", "event": "issues",        "action": "opened"},
  {"id": 7020, "guid": "guid-7020", "event": "pull_request_review_comment", "action": "created"},
  {"id": 7021, "guid": "guid-7021", "event": "pull_request_review_comment", "action": "created"},
  {"id": 7022, "guid": "guid-7022", "event": "pull_request_review_comment", "action": "created"},
  {"id": 7030, "guid": "guid-7030", "event": "pull_request", "action": "opened"},
  {"id": 7031, "guid": "guid-7031", "event": "pull_request", "action": "opened"},
  {"id": 7032, "guid": "guid-7032", "event": "pull_request", "action": "opened"}
]
JSON

# Issue-comment trio. Same repo, same issue number — author varies.
mk_detail 7001 issue_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/your-nexus"},
  "issue": {"number": 100, "pull_request": null},
  "comment": {"id": 97001, "user": {"login": "huangy57-nexus-bot[bot]"}, "body": "sibling bot comment"}
}'
mk_detail 7002 issue_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/your-nexus"},
  "issue": {"number": 100, "pull_request": null},
  "comment": {"id": 97002, "user": {"login": "your-org-bot[bot]"}, "body": "self-bot comment"}
}'
mk_detail 7003 issue_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/your-nexus"},
  "issue": {"number": 100, "pull_request": null},
  "comment": {"id": 97003, "user": {"login": "operator"}, "body": "operator comment"}
}'

# issues:opened trio.
mk_detail 7010 issues opened '{
  "action": "opened",
  "repository": {"full_name": "your-org/your-nexus"},
  "issue": {"number": 200, "user": {"login": "huangy57-nexus-bot[bot]"}, "body": "sibling bot opened issue"}
}'
mk_detail 7011 issues opened '{
  "action": "opened",
  "repository": {"full_name": "your-org/your-nexus"},
  "issue": {"number": 201, "user": {"login": "your-org-bot[bot]"}, "body": "self-bot opened issue"}
}'
mk_detail 7012 issues opened '{
  "action": "opened",
  "repository": {"full_name": "your-org/your-nexus"},
  "issue": {"number": 202, "user": {"login": "operator"}, "body": "operator opened issue"}
}'

# PR review-comment trio.
mk_detail 7020 pull_request_review_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/your-nexus"},
  "pull_request": {"number": 300},
  "comment": {"id": 97020, "path": "monitor/watcher/_github.sh", "user": {"login": "huangy57-nexus-bot[bot]"}, "body": "review by sibling bot"}
}'
mk_detail 7021 pull_request_review_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/your-nexus"},
  "pull_request": {"number": 300},
  "comment": {"id": 97021, "path": "monitor/watcher/_github.sh", "user": {"login": "your-org-bot[bot]"}, "body": "review by self bot"}
}'
mk_detail 7022 pull_request_review_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/your-nexus"},
  "pull_request": {"number": 300},
  "comment": {"id": 97022, "path": "monitor/watcher/_github.sh", "user": {"login": "operator"}, "body": "review by operator"}
}'

# pull_request:opened trio.
mk_detail 7030 pull_request opened '{
  "action": "opened",
  "repository": {"full_name": "your-org/your-nexus"},
  "pull_request": {"number": 400, "id": 990030, "user": {"login": "huangy57-nexus-bot[bot]"}, "body": "sibling bot PR"}
}'
mk_detail 7031 pull_request opened '{
  "action": "opened",
  "repository": {"full_name": "your-org/your-nexus"},
  "pull_request": {"number": 401, "id": 990031, "user": {"login": "your-org-bot[bot]"}, "body": "self bot PR"}
}'
mk_detail 7032 pull_request opened '{
  "action": "opened",
  "repository": {"full_name": "your-org/your-nexus"},
  "pull_request": {"number": 402, "id": 990032, "user": {"login": "operator"}, "body": "operator PR"}
}'

rm -f "$STATE_DIR/last-delivery-cursor.txt" "$STATE_DIR/processed-comments.txt"
out=$(snapshot_deliveries 2>/dev/null | _filter_to_user_author)

# Per event type: the bot-authored pair drops, operator surfaces.
assert_not_contains "huangy57 bot issue_comment dropped" "$out" "id=97001"
assert_not_contains "your-org bot issue_comment dropped" "$out" "id=97002"
assert_contains    "operator issue_comment surfaces"       "$out" "issue=100 id=97003 author=operator"

assert_not_contains "huangy57 bot issues:opened dropped" "$out" "issue_new=200"
assert_not_contains "your-org bot issues:opened dropped" "$out" "issue_new=201"
assert_contains    "operator issues:opened surfaces"       "$out" "issue_new=202 id=202 author=operator"

assert_not_contains "huangy57 bot pr_review_comment dropped" "$out" "id=97020"
assert_not_contains "your-org bot pr_review_comment dropped" "$out" "id=97021"
assert_contains    "operator pr_review_comment surfaces"       "$out" "pr_review=300 id=97022 author=operator"

assert_not_contains "huangy57 bot pull_request dropped" "$out" "id=990030"
assert_not_contains "your-org bot pull_request dropped" "$out" "id=990031"
assert_contains    "operator pull_request surfaces"       "$out" "pr=402 id=990032 author=operator"

# Body previews of bot-authored events must not leak either (the
# chokepoint drops the `  body: ...` continuation alongside its
# header).
assert_not_contains "sibling-bot body preview dropped"    "$out" "sibling bot comment"
assert_not_contains "self-bot body preview dropped"       "$out" "self-bot comment"
assert_not_contains "sibling-bot issue body dropped"      "$out" "sibling bot opened issue"
assert_not_contains "self-bot issue body dropped"         "$out" "self-bot opened issue"
assert_contains    "operator comment body inlined"        "$out" "operator comment"

# Restore the default fixture set for any subsequent tests.
cat > "$LIST_BODY" <<'JSON'
[
  {"id": 1001, "guid": "guid-1001", "event": "issue_comment", "action": "created"}
]
JSON
mk_detail 1001 issue_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/your-nexus"},
  "issue": {"number": 11, "pull_request": null},
  "comment": {"id": 91001, "user": {"login": "operator"}, "body": "fresh issue comment"}
}'

# ---- processed-comments dedup ----

echo '=== processed-comments dedup hides emitted lines ==='
cat > "$LIST_BODY" <<'JSON'
[
  {"id": 1001, "guid": "guid-1001b", "event": "issue_comment", "action": "created"},
  {"id": 1003, "guid": "guid-1003b", "event": "issues",        "action": "opened"}
]
JSON
rm -f "$STATE_DIR/last-delivery-cursor.txt"
printf 'comment:91001\nissue:17\n' > "$STATE_DIR/processed-comments.txt"
out=$(snapshot_deliveries 2>/dev/null)
assert_not_contains "comment:91001 hidden by processed-comments" "$out" "id=91001"
assert_not_contains "issue:17 hidden by processed-comments" "$out" "issue_new=17"
rm -f "$STATE_DIR/processed-comments.txt"

# ---- jq integer-precision regression ----
#
# GitHub returns delivery `id` as a 64-bit integer (currently ~3.8e18,
# above 2^53 = 9007199254740992). jq 1.5 parses numbers as IEEE 754
# doubles, silently truncating the low ~3 digits. Before the fix,
# `_deliveries.sh` extracted ids via `jq -r '.[].id'`, which corrupted
# the URL parameter for the per-delivery fetch and caused a 404 — so
# `_process_delivery` bailed without emitting and the comment never
# surfaced. The fix extracts ids via grep on the raw JSON text.
#
# Reproduction case from production: cid=4362002465 on your-nexus#66,
# delivery id=3817528646927646720 (jq-truncated to 3817528646927646700).
#
echo '=== jq integer-precision: 19-digit delivery id round-trips intact ==='
cat > "$LIST_BODY" <<'JSON'
[
  {"id": 3817528646927646720, "guid": "ed478770-45ae-11f1-8a10-b178c82025a7", "event": "issue_comment", "action": "created"}
]
JSON
mk_detail 3817528646927646720 issue_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/your-nexus"},
  "issue": {"number": 66, "pull_request": null},
  "comment": {"id": 4362002465, "user": {"login": "operator"}, "body": "manifold body"}
}'
rm -f "$STATE_DIR/last-delivery-cursor.txt" "$STATE_DIR/processed-comments.txt"
out=$(snapshot_deliveries 2>/dev/null | _filter_to_user_author)
assert_contains "19-digit id resolves: comment line emitted" "$out" "issue=66 id=4362002465 author=operator"
assert_eq "cursor advances to the 19-digit guid" \
    "$(cat "$STATE_DIR/last-delivery-cursor.txt" 2>/dev/null)" \
    "ed478770-45ae-11f1-8a10-b178c82025a7"

# ---- config default: deliveries concern defaults to true ----
#
# Latency fix (asset-repo operator comments surfaced only at the ~600 s
# `github_poll` cadence; perceived as "not emitted"). The deliveries path
# ALREADY emits in-$REPO `issue_comment` events as `issue=` lines within the
# 15 s `deliveries_poll` cycle (proven by the `issue_comment -> issue= shape`
# assertion above) — it was gated off SOLELY by this config default. The
# 2026-06-20 wedge that justified default-OFF (un-timed-out curls +
# non-incremental cursor) is fixed by guards 1–3 in `_deliveries.sh` (proven
# by the wedge-safety tests), and the App webhook is live (HTTP 200,
# `issue_comment created` deliveries for the asset repo), so the defensive
# default is now stale. The two split flags (asset / bot_mention) both
# default ON. (Full config-resolution matrix: test-deliveries-split.sh.)
#
# Assert the effective default `_config.sh` resolves when the keys are ABSENT
# from nexus.yml AND no env override. Run in a clean `bash` so sourcing
# `_config.sh` (which sets ~50 globals) can't clobber this harness's state.
# The `_cfg` stub mimics an absent key by echoing the caller-supplied default
# ($2), exactly as `config/load.sh` does on a miss.
echo '=== config default: deliveries asset/bot_mention default to true ==='
CFG_STUB="$WORK/cfg-default-stub.sh"
cat > "$CFG_STUB" <<'STUB'
#!/usr/bin/env bash
# $1 = config key, $2 = default. Absent-key behaviour: echo the default.
printf '%s' "${2:-}"
STUB
chmod +x "$CFG_STUB"
asset_default=$(env -u MONITOR_DELIVERIES_ASSET_ENABLED \
    _cfg="$CFG_STUB" NEXUS_ROOT="$WORK" \
    bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "$DELIVERIES_ASSET_ENABLED"' \
    _ "$_test_dir/_config.sh")
assert_eq "DELIVERIES_ASSET_ENABLED defaults to true (key absent, no env override)" \
    "$asset_default" "true"
botmention_default=$(env -u MONITOR_DELIVERIES_BOT_MENTION_ENABLED \
    _cfg="$CFG_STUB" NEXUS_ROOT="$WORK" \
    bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "$DELIVERIES_BOT_MENTION_ENABLED"' \
    _ "$_test_dir/_config.sh")
assert_eq "DELIVERIES_BOT_MENTION_ENABLED defaults to true (key absent, no env override)" \
    "$botmention_default" "true"

# And an explicit env opt-OUT still wins over the default.
optout_val=$(env MONITOR_DELIVERIES_ASSET_ENABLED=false \
    _cfg="$CFG_STUB" NEXUS_ROOT="$WORK" \
    bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "$DELIVERIES_ASSET_ENABLED"' \
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
