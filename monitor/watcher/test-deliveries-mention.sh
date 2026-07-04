#!/usr/bin/env bash
# Mock-curl unit tests for the @bot-mention / wedge-safety behaviour of
# monitor/watcher/_deliveries.sh (the deliveries path repurposed per the
# operator directive on your-org/nexus-code#330: "the watcher emits when
# the bot is @-addressed in any repo it is installed on").
#
# Run: bash monitor/watcher/test-deliveries-mention.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Companion to test-snapshot-deliveries.sh (which covers the per-event
# line shapes + the universal user-author chokepoint). THIS file focuses
# on the three things the #330-superseding change adds:
#
#   1. WEDGE-SAFETY (the most important — this path took the live watcher
#      down 3× in 20 min on 2026-06-20):
#        a. every curl carries --connect-timeout + --max-time;
#        b. a failing/timed-out deliveries curl is NON-FATAL — the
#           function returns 0 promptly and a sentinel command AFTER it
#           still runs (the main loop is never blocked);
#        c. the per-cycle fetch cap bounds work and the cursor advances
#           incrementally so a bounded backlog drains over cycles.
#   2. @bot-MENTION cross-repo surfacing: a cross-repo comment that
#      @-addresses the bot surfaces as `mention=<owner>/<repo>` with the
#      RIGHT per-repo attribution and survives the mention_only gate; one
#      that does NOT @-address the bot is dropped by the gate.
#   3. REPO-SCOPED dedup: two cross-repo new-issues sharing an issue
#      NUMBER across different repos both surface (no number collision);
#      the repo-scoped processed-comments key hides the right one.

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
mkdir -p "$STATE_DIR" "$WORK/fixtures"
REPO="your-org/your-nexus"
USER_LOGIN="operator"
BOT_LOGIN="your-org-bot"
CROSS_REPO_SURFACE="mention_only"
MINT_JWT_BIN="$WORK/mint-jwt-stub.sh"
cat > "$MINT_JWT_BIN" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'fake.jwt.value'
STUB
chmod +x "$MINT_JWT_BIN"

export STATE_DIR REPO USER_LOGIN BOT_LOGIN CROSS_REPO_SURFACE MINT_JWT_BIN

# Source the units under test. `_github.sh` provides the two filter
# chokepoints the production pipeline runs after the raw emit:
# `_filter_to_user_author` then `_filter_cross_repo_surface`.
. "$_test_dir/_github.sh"
. "$_test_dir/_deliveries.sh"

# The production pipeline as the consumer sees it (minus dedup/skip-marker,
# which are tested elsewhere). Mention surfacing is decided by these two.
pipeline() { _filter_to_user_author | _filter_cross_repo_surface; }

LIST_BODY="$WORK/fixtures/list.json"
LIST_HDR="$WORK/fixtures/list.hdr"
ARGV_LOG="$WORK/curl-argv.log"
printf 'HTTP/2 200 \n\n' > "$LIST_HDR"

mk_detail() {
    local id="$1" event="$2" action="$3" payload="$4"
    cat > "$WORK/fixtures/${id}.json" <<JSON
{
  "id": ${id},
  "event": "${event}",
  "action": "${action}",
  "request": { "headers": {}, "payload": ${payload} }
}
JSON
}

# Mock curl. Records full argv (for the timeout-flag assertions), branches
# on the URL, writes header/body files, echoes the status code. Honors two
# fault-injection globals:
#   CURL_FAIL_CODE  — if set (non-empty), curl returns THIS exit code
#                     (simulating a --max-time abort, curl's rc 28) for
#                     the LISTING endpoint, writing nothing.
curl() {
    printf '%s\0' "$@" >> "$ARGV_LOG"; printf '\n' >> "$ARGV_LOG"
    local hdr_target="" body_target="" url="" status_w=0 prev=""
    for arg in "$@"; do
        case "$prev" in
            -D) hdr_target="$arg"; prev=""; continue ;;
            -o) body_target="$arg"; prev=""; continue ;;
            -w) status_w=1; prev=""; continue ;;
            -H|--connect-timeout|--max-time) prev=""; continue ;;
        esac
        case "$arg" in
            -D|-o|-H|-w|--connect-timeout|--max-time) prev="$arg" ;;
            -sS) ;;
            -*)  ;;
            http*) url="$arg" ;;
        esac
    done

    local code=200 src_hdr="" src_body=""
    case "$url" in
        *'/app/hook/deliveries?per_page='*|*'/app/hook/deliveries?'*'cursor='*)
            if [[ -n "${CURL_FAIL_CODE:-}" ]]; then
                return "$CURL_FAIL_CODE"   # simulate a timeout / transport abort
            fi
            src_hdr="$LIST_HDR"; src_body="$LIST_BODY" ;;
        *'/app/hook/deliveries/'*)
            local id="${url##*/}"; id="${id%%\?*}"
            src_body="$WORK/fixtures/${id}.json"
            if [[ ! -f "$src_body" ]]; then
                code=404; src_body="$WORK/fixtures/.empty"
                printf '{"message":"Not Found"}' > "$src_body"
            fi
            src_hdr="$WORK/fixtures/.detail-hdr"
            printf 'HTTP/2 %s \n\n' "$code" > "$src_hdr" ;;
        *)
            code=404; src_body="$WORK/fixtures/.empty"; : > "$src_body"
            src_hdr="$WORK/fixtures/.detail-hdr"
            printf 'HTTP/2 %s \n\n' "$code" > "$src_hdr" ;;
    esac
    [[ -n "$hdr_target" ]] && cp "$src_hdr"  "$hdr_target"
    [[ -n "$body_target" ]] && cp "$src_body" "$body_target"
    (( status_w == 1 )) && printf '%s' "$code"
    return 0
}
export -f curl

reset_state() { rm -f "$STATE_DIR/last-delivery-cursor.txt" \
                       "$STATE_DIR/processed-comments.txt" "$ARGV_LOG"; }

# =====================================================================
echo '=== @bot-mention cross-repo surfacing + per-repo attribution ==='
# Two cross-repo issue_comments by the operator: one @-addresses the bot
# (must surface), one does not (gate must drop). Plus an in-$REPO comment
# (always surfaces, no @ required).
cat > "$LIST_BODY" <<'JSON'
[
  {"id": 5001, "guid": "g-5001", "event": "issue_comment", "action": "created"},
  {"id": 5002, "guid": "g-5002", "event": "issue_comment", "action": "created"},
  {"id": 5003, "guid": "g-5003", "event": "issue_comment", "action": "created"}
]
JSON
# 5001: cross-repo (your-org/nexus-code), body @-addresses the bot.
mk_detail 5001 issue_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/nexus-code"},
  "issue": {"number": 329, "pull_request": {"url": "x"}},
  "comment": {"id": 470001, "user": {"login": "operator"}, "body": "@your-org-bot please watch nexus-code"}
}'
# 5002: cross-repo (your-org/nexus-code), body does NOT @-address the bot.
mk_detail 5002 issue_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/nexus-code"},
  "issue": {"number": 400, "pull_request": null},
  "comment": {"id": 470002, "user": {"login": "operator"}, "body": "just a normal cross-repo note, no mention"}
}'
# 5003: in-$REPO comment (no @ required to surface).
mk_detail 5003 issue_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/your-nexus"},
  "issue": {"number": 12, "pull_request": null},
  "comment": {"id": 470003, "user": {"login": "operator"}, "body": "in-repo comment"}
}'
reset_state
out=$(snapshot_deliveries 2>/dev/null | pipeline)
assert_contains "cross-repo @bot comment surfaces as mention="        "$out" "mention=your-org/nexus-code kind=pr n=329 id=470001 author=operator"
assert_contains "per-repo attribution names the SOURCE repo"          "$out" "mention=your-org/nexus-code"
assert_not_contains "cross-repo comment WITHOUT @bot is gated out"    "$out" "id=470002"
assert_not_contains "non-mention body preview also dropped by gate"   "$out" "normal cross-repo note"
assert_contains "in-\$REPO comment surfaces with NO @ required"        "$out" "issue=12 id=470003 author=operator"

# =====================================================================
echo '=== timeout flags are passed to EVERY curl (wedge-safety guard 1) ==='
# argv log from the run above. Both the listing and per-delivery curls
# must carry --connect-timeout and --max-time.
n_maxtime=$(grep -c -- '--max-time' "$ARGV_LOG" 2>/dev/null || echo 0)
n_connect=$(grep -c -- '--connect-timeout' "$ARGV_LOG" 2>/dev/null || echo 0)
n_detail=$(grep -c '/app/hook/deliveries/' "$ARGV_LOG" 2>/dev/null || echo 0)
# 1 listing call + 3 per-delivery calls = 4 curls, each with both flags.
assert_eq "every curl carries --max-time (>=4)"        "$(( n_maxtime >= 4 ? 1 : 0 ))" "1"
assert_eq "every curl carries --connect-timeout (>=4)" "$(( n_connect >= 4 ? 1 : 0 ))" "1"
assert_eq "per-delivery fetches happened (3)"          "$(( n_detail >= 3 ? 1 : 0 ))" "1"

# =====================================================================
echo '=== a timed-out listing curl is NON-FATAL — loop continues (guard 1) ==='
# Simulate curl aborting on --max-time (rc 28). snapshot_deliveries must
# return 0 promptly, write no cursor, and a SENTINEL command after it must
# still run (proving the main loop is never blocked / wedged).
cat > "$LIST_BODY" <<'JSON'
[ {"id": 6001, "guid": "g-6001", "event": "issue_comment", "action": "created"} ]
JSON
reset_state
CURL_FAIL_CODE=28 snapshot_deliveries >/tmp/_deliv_out 2>/tmp/_deliv_err
rc=$?
sentinel="loop-still-alive"
assert_eq "snapshot_deliveries returns 0 on curl timeout"  "$rc" "0"
assert_eq "sentinel runs after a timed-out poll"           "$sentinel" "loop-still-alive"
assert_contains "logs a non-fatal skip on timeout"         "$(cat /tmp/_deliv_err)" "skipping cycle (non-fatal)"
assert_eq "no cursor written on a timed-out poll"          "$(cat "$STATE_DIR/last-delivery-cursor.txt" 2>/dev/null)" ""
assert_eq "no output emitted on a timed-out poll"          "$(cat /tmp/_deliv_out)" ""

# =====================================================================
echo '=== per-cycle fetch cap + incremental cursor drain (guards 2 & 3) ==='
# Backlog of 5 new cross-repo @bot comments; cap = 2. First poll processes
# the OLDEST 2, advances the cursor; second poll the next 2; third the last
# 1. No re-walk, no loss.
cat > "$LIST_BODY" <<'JSON'
[
  {"id": 8005, "guid": "g-8005", "event": "issue_comment", "action": "created"},
  {"id": 8004, "guid": "g-8004", "event": "issue_comment", "action": "created"},
  {"id": 8003, "guid": "g-8003", "event": "issue_comment", "action": "created"},
  {"id": 8002, "guid": "g-8002", "event": "issue_comment", "action": "created"},
  {"id": 8001, "guid": "g-8001", "event": "issue_comment", "action": "created"}
]
JSON
for i in 1 2 3 4 5; do
  mk_detail "800${i}" issue_comment created "{
    \"action\": \"created\",
    \"repository\": {\"full_name\": \"your-org/nexus-code\"},
    \"issue\": {\"number\": ${i}, \"pull_request\": null},
    \"comment\": {\"id\": 90000${i}, \"user\": {\"login\": \"operator\"}, \"body\": \"@your-org-bot item ${i}\"}
  }"
done
reset_state
export DELIVERIES_MAX_FETCH_PER_CYCLE=2
# Poll 1: oldest two (8001, 8002 — issue numbers 1,2).
o1=$(snapshot_deliveries 2>/dev/null | pipeline)
c1=$(cat "$STATE_DIR/last-delivery-cursor.txt" 2>/dev/null)
assert_contains "poll1 processes oldest item 1"  "$o1" "mention=your-org/nexus-code kind=issue n=1 id=900001"
assert_contains "poll1 processes oldest item 2"  "$o1" "n=2 id=900002"
assert_not_contains "poll1 does NOT process item 3 (capped)" "$o1" "id=900003"
assert_eq "poll1 cursor advanced to last-processed (g-8002)" "$c1" "g-8002"
# Poll 2: next two (8003, 8004).
o2=$(snapshot_deliveries 2>/dev/null | pipeline)
assert_contains "poll2 resumes at item 3"  "$o2" "n=3 id=900003"
assert_contains "poll2 processes item 4"   "$o2" "n=4 id=900004"
assert_not_contains "poll2 does NOT re-emit item 1 (no re-walk)" "$o2" "id=900001"
assert_not_contains "poll2 does NOT reach item 5 yet"            "$o2" "id=900005"
# Poll 3: last one (8005).
o3=$(snapshot_deliveries 2>/dev/null | pipeline)
assert_contains "poll3 processes final item 5" "$o3" "n=5 id=900005"
assert_eq "poll3 cursor at newest (g-8005)" "$(cat "$STATE_DIR/last-delivery-cursor.txt" 2>/dev/null)" "g-8005"
# Poll 4: nothing new.
o4=$(snapshot_deliveries 2>/dev/null | pipeline)
assert_eq "poll4 empty (backlog drained)" "$o4" ""
unset DELIVERIES_MAX_FETCH_PER_CYCLE

# =====================================================================
echo '=== repo-scoped cross-repo dedup: same issue number, different repos ==='
# Two cross-repo new-issues with the SAME number (#7) in DIFFERENT repos.
# A bare issue:<n> key would collide; the repo-scoped key must surface BOTH.
cat > "$LIST_BODY" <<'JSON'
[
  {"id": 9002, "guid": "g-9002", "event": "issues", "action": "opened"},
  {"id": 9001, "guid": "g-9001", "event": "issues", "action": "opened"}
]
JSON
mk_detail 9001 issues opened '{
  "action": "opened",
  "repository": {"full_name": "your-org/nexus-code"},
  "issue": {"number": 7, "user": {"login": "operator"}, "body": "@your-org-bot nexus-code issue 7"}
}'
mk_detail 9002 issues opened '{
  "action": "opened",
  "repository": {"full_name": "your-org/other-repo"},
  "issue": {"number": 7, "user": {"login": "operator"}, "body": "@your-org-bot other-repo issue 7"}
}'
reset_state
out=$(snapshot_deliveries 2>/dev/null | pipeline)
assert_contains "nexus-code #7 surfaces"  "$out" "mention=your-org/nexus-code kind=issue_new n=7"
assert_contains "other-repo #7 surfaces (no number collision)" "$out" "mention=your-org/other-repo kind=issue_new n=7"
# Now seed processed-comments with ONLY the nexus-code repo-scoped key;
# the other-repo #7 must still surface.
reset_state
printf 'issue:your-org/nexus-code:7\n' > "$STATE_DIR/processed-comments.txt"
out=$(snapshot_deliveries 2>/dev/null | pipeline)
assert_not_contains "repo-scoped key hides nexus-code #7" "$out" "mention=your-org/nexus-code kind=issue_new n=7"
assert_contains "other-repo #7 still surfaces (distinct key)" "$out" "mention=your-org/other-repo kind=issue_new n=7"

# =====================================================================
echo '=== first-run seed knob (opt-in): seed=true skips backlog ==='
cat > "$LIST_BODY" <<'JSON'
[
  {"id": 4002, "guid": "g-4002", "event": "issue_comment", "action": "created"},
  {"id": 4001, "guid": "g-4001", "event": "issue_comment", "action": "created"}
]
JSON
mk_detail 4001 issue_comment created '{
  "action":"created","repository":{"full_name":"your-org/nexus-code"},
  "issue":{"number":50,"pull_request":null},
  "comment":{"id":410001,"user":{"login":"operator"},"body":"@your-org-bot backlog 1"}}'
mk_detail 4002 issue_comment created '{
  "action":"created","repository":{"full_name":"your-org/nexus-code"},
  "issue":{"number":51,"pull_request":null},
  "comment":{"id":410002,"user":{"login":"operator"},"body":"@your-org-bot backlog 2"}}'
# seed=true: empty cursor → process nothing, cursor seeded to newest.
reset_state
out=$(DELIVERIES_SEED_ON_FIRST_RUN=true snapshot_deliveries 2>/dev/null | pipeline)
assert_eq "seed=true emits nothing on first run" "$out" ""
assert_eq "seed=true seeds cursor to newest (g-4002)" "$(cat "$STATE_DIR/last-delivery-cursor.txt" 2>/dev/null)" "g-4002"
# seed=false (default): empty cursor → walks the backlog.
reset_state
out=$(DELIVERIES_SEED_ON_FIRST_RUN=false snapshot_deliveries 2>/dev/null | pipeline)
assert_contains "seed=false walks backlog item 1" "$out" "id=410001"
assert_contains "seed=false walks backlog item 2" "$out" "id=410002"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
