#!/usr/bin/env bash
# Phase-1 event/action pre-filter for snapshot_deliveries (emit-gap
# latency fix). The /app/hook/deliveries log is GLOBAL across every
# installed repo; ~46% of recent deliveries in production are events
# that can never surface (push, security_advisory, create, edited, …).
# Before the fix, phase 2 spent a bounded curl PAYLOAD FETCH on each of
# them only for `_process_delivery` to drop them — wasting the per-cycle
# fetch cap and starving fresh @bot-mentions / asset comments behind a
# multi-day backlog. The fix skips non-surfacing deliveries during phase
# 1 collection using the `event`/`action` already in the LISTING (no
# extra request).
#
# This test asserts the latency-relevant behaviour the existing
# test-snapshot-deliveries.sh does NOT: that non-surfacing deliveries
# are NEVER FETCHED (their detail endpoint is not hit), while the cursor
# still advances past them.
#
# Run: bash monitor/watcher/test-deliveries-event-prefilter.sh
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0; FAIL=0
assert_contains()     { if grep -qF -- "$3" <<<"$2"; then printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL: %s\n         expected: %s\n         in:\n%s\n' "$1" "$3" "$2" >&2; FAIL=$((FAIL+1)); fi; }
assert_not_contains() { if ! grep -qF -- "$3" <<<"$2"; then printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL: %s\n         did NOT expect: %s\n         in:\n%s\n' "$1" "$3" "$2" >&2; FAIL=$((FAIL+1)); fi; }
assert_eq()           { if [[ "$2" == "$3" ]]; then printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL: %s — got %q want %q\n' "$1" "$2" "$3" >&2; FAIL=$((FAIL+1)); fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR"
REPO="your-org/your-nexus"
USER_LOGIN="operator"
MINT_JWT_BIN="$WORK/mint-jwt-stub.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" fake.jwt.value\n' > "$MINT_JWT_BIN"
chmod +x "$MINT_JWT_BIN"
# Record of every delivery-detail id actually fetched.
FETCH_LOG="$WORK/fetched.ids"
: > "$FETCH_LOG"
export STATE_DIR REPO USER_LOGIN MINT_JWT_BIN FETCH_LOG

. "$_test_dir/_github.sh"
. "$_test_dir/_deliveries.sh"

mkdir -p "$WORK/fixtures"
LIST_BODY="$WORK/fixtures/list.json"
LIST_HDR="$WORK/fixtures/list.hdr"
printf 'HTTP/2 200 \n\n' > "$LIST_HDR"

# Newest-first listing: two surfacing comments bracketing a run of
# non-surfacing noise (push / security_advisory / create / edited).
cat > "$LIST_BODY" <<'JSON'
[
  {"id": 5001, "guid": "guid-5001", "event": "issue_comment",     "action": "created"},
  {"id": 5002, "guid": "guid-5002", "event": "push",              "action": null},
  {"id": 5003, "guid": "guid-5003", "event": "security_advisory", "action": "published"},
  {"id": 5004, "guid": "guid-5004", "event": "create",            "action": null},
  {"id": 5005, "guid": "guid-5005", "event": "issue_comment",     "action": "edited"},
  {"id": 5006, "guid": "guid-5006", "event": "issues",            "action": "opened"}
]
JSON

mk_detail() {
    cat > "$WORK/fixtures/${1}.json" <<JSON
{ "id": ${1}, "event": "${2}", "action": "${3}",
  "request": { "headers": {"X-GitHub-Event": "${2}"}, "payload": ${4} } }
JSON
}
# EVERY delivery gets a valid detail fixture — so if the pre-fix code
# fetched the noise deliveries, the fetch would succeed (200) and be
# recorded. The fix must skip them BEFORE the fetch, not rely on a 404.
mk_detail 5001 issue_comment created '{ "action":"created","repository":{"full_name":"your-org/your-nexus"},"issue":{"number":11,"pull_request":null},"comment":{"id":81001,"user":{"login":"operator"},"body":"fresh comment"} }'
mk_detail 5002 push                ''      '{ "action":null,"repository":{"full_name":"your-org/your-nexus"} }'
mk_detail 5003 security_advisory   published '{ "action":"published" }'
mk_detail 5004 create              ''      '{ "action":null,"repository":{"full_name":"your-org/your-nexus"} }'
mk_detail 5005 issue_comment       edited  '{ "action":"edited","repository":{"full_name":"your-org/your-nexus"},"issue":{"number":22,"pull_request":null},"comment":{"id":81005,"user":{"login":"operator"},"body":"edit"} }'
mk_detail 5006 issues              opened  '{ "action":"opened","repository":{"full_name":"your-org/your-nexus"},"issue":{"number":17,"user":{"login":"operator"},"body":"fresh issue"} }'

# Mock curl: records detail fetches to $FETCH_LOG, serves fixtures.
curl() {
    local hdr_target="" body_target="" url="" status_w=0 prev=""
    for arg in "$@"; do
        case "$prev" in
            -D) hdr_target="$arg"; prev=""; continue ;;
            -o) body_target="$arg"; prev=""; continue ;;
            -w) status_w=1; prev=""; continue ;;
            -H) prev=""; continue ;;
        esac
        case "$arg" in
            -D|-o|-H|-w) prev="$arg" ;;
            http*) url="$arg" ;;
        esac
    done
    local code=200 src_hdr="$WORK/fixtures/.hdr" src_body=""
    printf 'HTTP/2 200 \n\n' > "$src_hdr"
    case "$url" in
        *'/app/hook/deliveries?per_page='*) src_hdr="$LIST_HDR"; src_body="$LIST_BODY" ;;
        *'/app/hook/deliveries/'*)
            local id="${url##*/}"; id="${id%%\?*}"
            printf '%s\n' "$id" >> "$FETCH_LOG"   # <-- record the fetch
            src_body="$WORK/fixtures/${id}.json"
            [[ -f "$src_body" ]] || { code=404; src_body="$WORK/fixtures/.empty"; printf '{}' > "$src_body"; }
            printf 'HTTP/2 %s \n\n' "$code" > "$src_hdr" ;;
        *) code=404; src_body="$WORK/fixtures/.empty"; : > "$src_body" ;;
    esac
    [[ -n "$hdr_target" ]] && cp "$src_hdr" "$hdr_target"
    [[ -n "$body_target" ]] && cp "$src_body" "$body_target"
    (( status_w == 1 )) && printf '%s' "$code"
    return 0
}
export -f curl

echo '=== _delivery_event_eligible unit truth table ==='
_delivery_event_eligible issue_comment created               && r=ok || r=no; assert_eq "issue_comment/created eligible"   "$r" "ok"
_delivery_event_eligible issue_comment edited                && r=ok || r=no; assert_eq "issue_comment/edited NOT"        "$r" "no"
_delivery_event_eligible pull_request_review submitted       && r=ok || r=no; assert_eq "pr_review/submitted eligible"     "$r" "ok"
_delivery_event_eligible pull_request_review edited          && r=ok || r=no; assert_eq "pr_review/edited NOT"            "$r" "no"
_delivery_event_eligible issues opened                       && r=ok || r=no; assert_eq "issues/opened eligible"          "$r" "ok"
_delivery_event_eligible pull_request opened                 && r=ok || r=no; assert_eq "pull_request/opened eligible"    "$r" "ok"
_delivery_event_eligible push ''                             && r=ok || r=no; assert_eq "push NOT"                       "$r" "no"
_delivery_event_eligible security_advisory published         && r=ok || r=no; assert_eq "security_advisory NOT"          "$r" "no"
_delivery_event_eligible create ''                           && r=ok || r=no; assert_eq "create NOT"                     "$r" "no"

echo '=== noise deliveries are never FETCHED (fetch budget preserved) ==='
rm -f "$STATE_DIR/last-delivery-cursor.txt"; : > "$FETCH_LOG"
out=$(snapshot_deliveries 2>/dev/null | _filter_to_user_author)
fetched=$(sort "$FETCH_LOG")
assert_contains     "surfacing issue_comment fetched" "$fetched" "5001"
assert_contains     "surfacing issues:opened fetched" "$fetched" "5006"
assert_not_contains "push NOT fetched"                "$fetched" "5002"
assert_not_contains "security_advisory NOT fetched"   "$fetched" "5003"
assert_not_contains "create NOT fetched"              "$fetched" "5004"
assert_not_contains "edited issue_comment NOT fetched" "$fetched" "5005"

echo '=== surfacing comments still emit, cursor advances past the noise ==='
assert_contains "issue_comment 5001 surfaces" "$out" "issue=11 id=81001 author=operator"
assert_contains "issues 5006 surfaces"        "$out" "issue_new=17 id=17 author=operator"
assert_eq "cursor advanced to newest overall (guid-5001)" "$(cat "$STATE_DIR/last-delivery-cursor.txt" 2>/dev/null)" "guid-5001"

echo
if (( FAIL == 0 )); then echo "=== summary: $PASS passed, 0 failed ==="; echo "ALL TESTS PASSED"; exit 0
else echo "=== summary: $PASS passed, $FAIL failed ===" >&2; exit 1; fi
