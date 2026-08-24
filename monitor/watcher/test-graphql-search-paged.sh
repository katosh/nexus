#!/usr/bin/env bash
# Unit tests for the paginated GraphQL search walk
# (`_snapshot_search_paged` + `_snapshot_issue_comments` in
# monitor/watcher/_github.sh — your-org/nexus-code#595).
#
# Run: bash monitor/watcher/test-graphql-search-paged.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THE CENTRAL CASE IS "PARTIAL SUCCESS". The production failure was
# NOT a refusal. GitHub answered HTTP 200 with a populated `data` AND a
# top-level `errors` array, having nulled `author` on all 1,247 comments
# and `body`/`reactions` on 439 of them to stay inside its budget. So a
# page can be simultaneously rc=0 and unusable, and any check that reads
# the exit status instead of the payload will consume nulls. Consuming
# them is not a cosmetic bug: `reactions` is exactly the field the
# EYES/ROCKET filter reads to decide a comment was already acked, so a
# nulled page makes the entire acked backlog look eligible and re-emit.
# `partial_page_is_discarded` below is the assertion that matters most
# in this file.
#
# `gh` is shadowed with a bash function that serves a scripted sequence
# of canned pages; `timeout` is shadowed to strip its flags so the single
# production code path (`_snapshot_graphql`, which wraps gh in `timeout`)
# stays under test rather than being bypassed.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR"
REPO="your-org/your-nexus"
USER_LOGIN="operator"

source "$_test_dir/_github.sh"

# `timeout` cannot exec a bash function; strip its flags and run the
# rest, keeping _snapshot_graphql itself on the tested path.
timeout() {
    while [[ "${1:-}" == -* ]]; do
        [[ "$1" == "-k" ]] && shift
        shift
    done
    shift  # the duration
    "$@"
}

# Scripted gh. $WORK/pages/<n>.json is served on the n-th call;
# $WORK/rc/<n> (if present) overrides the exit status.
#
# The call counter lives in a FILE, not a variable: `_snapshot_graphql`
# invokes gh inside `$(...)`, so a shell-variable counter increments in
# a subshell and is lost. With a variable counter every call re-serves
# page 1 — whose `hasNextPage` is true — and the walk spins to the page
# cap while the assertions still look plausible.
CALL_LOG="$WORK/calls.txt"
CALL_N="$WORK/calls.n"
gh() {
    local n=1
    [[ -f "$CALL_N" ]] && n=$(( $(cat "$CALL_N") + 1 ))
    printf '%s' "$n" > "$CALL_N"
    printf '%s\n' "$*" >> "$CALL_LOG"
    local body="$WORK/pages/${n}.json"
    local rcf="$WORK/rc/${n}"
    [[ -f "$body" ]] && cat "$body"
    if [[ -f "$rcf" ]]; then return "$(cat "$rcf")"; fi
    return 0
}

# Build a page: <n> <hasNext> <endCursor> <issue-numbers...>
mkpage() {
    local n="$1" hasnext="$2" cursor="$3"; shift 3
    mkdir -p "$WORK/pages"
    local nodes="" num
    for num in "$@"; do
        [[ -n "$nodes" ]] && nodes+=","
        nodes+=$(printf '{"number":%s,"comments":{"nodes":[{"databaseId":%s00,"author":{"login":"operator"},"body":"hello %s","reactions":{"nodes":[]}}]}}' "$num" "$num" "$num")
    done
    printf '{"data":{"search":{"pageInfo":{"hasNextPage":%s,"endCursor":"%s"},"nodes":[%s]}}}' \
        "$hasnext" "$cursor" "$nodes" > "$WORK/pages/$n.json"
}

reset_h() {
    rm -rf "$WORK/pages" "$WORK/rc" "$CALL_LOG" "$CALL_N" "$STATE_DIR"
    mkdir -p "$WORK/pages" "$WORK/rc" "$STATE_DIR"

}

QUERY='query($q: String!, $first: Int!, $after: String) { search(query:$q, first:$first, after:$after) { pageInfo { hasNextPage endCursor } nodes { number } } }'
alerts() { cat "$STATE_DIR/watcher-alerts.log" 2>/dev/null; }

echo "== the walk follows cursors to exhaustion =="

reset_h
mkpage 1 true  c1 1 2
mkpage 2 true  c2 3 4
mkpage 3 false ""  5
out="$WORK/out.jsonl"
_snapshot_search_paged issue_comments "$QUERY" "repo:x is:issue" "$out"
assert_rc "walk succeeds" "$?" "0"
assert_eq "three pages fetched" "$_SEARCH_PAGES_TOTAL" "3"
assert_eq "  all three usable" "$_SEARCH_PAGES_OK" "3"
assert_eq "  none failed" "$_SEARCH_PAGES_FAILED" "0"
assert_eq "one JSON document per page" "$(wc -l < "$out")" "3"
assert_eq "every issue present exactly once" \
    "$(jq -r '.data.search.nodes[].number' "$out" | sort -n | tr '\n' ' ')" "1 2 3 4 5 "

echo "== cursor handling =="

assert_not_contains "first call sends NO after= (omitted var is null)" \
    "$(sed -n 1p "$CALL_LOG")" "after="
assert_contains "second call sends the first page's endCursor" \
    "$(sed -n 2p "$CALL_LOG")" "after=c1"
assert_contains "third call sends the second page's endCursor" \
    "$(sed -n 3p "$CALL_LOG")" "after=c2"
assert_contains "page size is passed as an Int (-F)" \
    "$(sed -n 1p "$CALL_LOG")" "-F first="

echo "== partial_page_is_discarded (THE case #595 is about) =="

reset_h
mkpage 1 true c1 1 2
# Page 2: HTTP 200, data present, but field errors nulled things out —
# byte-for-byte the shape the live query returned 2,933 times.
cat > "$WORK/pages/2.json" <<'JSON'
{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":""},
 "nodes":[{"number":9,"comments":{"nodes":[{"databaseId":900,"author":null,"body":null,"reactions":null}]}}]}},
 "errors":[{"type":"RESOURCE_LIMITS_EXCEEDED","path":["search","nodes",0,"comments","nodes",0,"body"],
            "message":"Resource limits for this query exceeded."}]}
JSON
printf '0\n' > "$WORK/rc/2"   # gh exits ZERO — only the payload betrays it
out="$WORK/out2.jsonl"
_snapshot_search_paged issue_comments "$QUERY" "repo:x is:issue" "$out"
assert_eq "the good page is kept" "$_SEARCH_PAGES_OK" "1"
assert_eq "the partial page is counted FAILED despite rc=0" "$_SEARCH_PAGES_FAILED" "1"
assert_eq "  and is not written out" "$(wc -l < "$out")" "1"
assert_not_contains "  no nulled record reached the consumer" "$(cat "$out")" '"author":null'
assert_contains "  the truncation is logged, not silent" "$(alerts)" \
    "graphql_partial_walk reason=partial_resolution"
assert_contains "  the log names the remedy" "$(alerts)" "MONITOR_GRAPHQL_SEARCH_PAGE_SIZE"

echo "== an empty/non-envelope body with rc=0 is NOT a healthy page =="

# "gh exited 0 and there were no errors" is still not "this is a search
# result". Without this check an empty 200 counts as a good page, clears
# the degradation counter and reads as a recovered surface.
reset_h
mkpage 1 true c1 1 2
: > "$WORK/pages/2.json"                 # rc=0, empty body
out="$WORK/oute.jsonl"
_snapshot_search_paged issue_comments "$QUERY" "repo:x is:issue" "$out"
assert_eq "empty body counted FAILED, not OK" "$_SEARCH_PAGES_FAILED" "1"
assert_eq "  only the real page kept" "$_SEARCH_PAGES_OK" "1"
assert_contains "  and it is logged" "$(alerts)" "graphql_partial_walk reason=malformed_page"

reset_h
mkpage 1 true c1 1 2
printf '{"data":{"viewer":{"login":"x"}}}' > "$WORK/pages/2.json"   # valid JSON, wrong shape
_snapshot_search_paged issue_comments "$QUERY" "repo:x is:issue" "$out"
assert_eq "non-envelope body counted FAILED" "$_SEARCH_PAGES_FAILED" "1"

echo "== a partial page is SKIPPED, not fatal to the tail (skeptic req-001) =="

# The original code `break`-ed here, so a bad page 2 withheld pages 2..N.
# The tail must survive: only the bad page's issues are lost.
reset_h
mkpage 1 true c1 1 2
cat > "$WORK/pages/2.json" <<'JSON'
{"data":{"search":{"pageInfo":{"hasNextPage":true,"endCursor":"c2"},
 "nodes":[{"number":9,"comments":{"nodes":[{"databaseId":900,"author":null,"body":null,"reactions":null}]}}]}},
 "errors":[{"type":"RESOURCE_LIMITS_EXCEEDED","message":"Resource limits for this query exceeded."}]}
JSON
mkpage 3 false "" 5 6
out="$WORK/outskip.jsonl"
_snapshot_search_paged issue_comments "$QUERY" "repo:x is:issue" "$out"
assert_eq "walk continued past the partial page" "$_SEARCH_PAGES_TOTAL" "3"
assert_eq "  both good pages kept" "$_SEARCH_PAGES_OK" "2"
assert_eq "  the partial page counted failed" "$_SEARCH_PAGES_FAILED" "1"
assert_eq "  NOT flagged truncated (the tail was reached)" "$_SEARCH_PAGES_TRUNCATED" "0"
assert_eq "page-3 issues survive a partial page 2" \
    "$(jq -r '.data.search.nodes[].number' "$out" | sort -n | tr '\n' ' ')" "1 2 5 6 "
assert_not_contains "  nulled records still never reach the consumer" "$(cat "$out")" '"author":null'
assert_contains "  log says the walk CONTINUES" "$(alerts)" "walk CONTINUES"

# When the partial page yields NO usable cursor we genuinely cannot go on —
# that is a truncated walk and must be flagged as such.
reset_h
mkpage 1 true c1 1 2
cat > "$WORK/pages/2.json" <<'JSON'
{"data":{"search":{"pageInfo":{"hasNextPage":true,"endCursor":null},
 "nodes":[{"number":9,"comments":{"nodes":[{"databaseId":900,"author":null,"body":null,"reactions":null}]}}]}},
 "errors":[{"type":"RESOURCE_LIMITS_EXCEEDED","message":"Resource limits for this query exceeded."}]}
JSON
out="$WORK/outtrunc.jsonl"
_snapshot_search_paged issue_comments "$QUERY" "repo:x is:issue" "$out"
assert_eq "no usable cursor -> walk truncated" "$_SEARCH_PAGES_TRUNCATED" "1"
assert_contains "  and says the tail is withheld" "$(alerts)" "every later page withheld"

echo "== a TRUNCATED walk is degradation, not success (skeptic req-001) =="

# The defect: some pages land, so _SEARCH_PAGES_OK>0, so the caller used to
# call _graphql_note_success — clearing the degradation counter and leaving a
# throttled WARN as the ONLY trace of a withheld tail. That is the log-only
# invisibility #595 exists to kill.
reset_h
mkpage 1 true c1 1 2
printf '1\n' > "$WORK/rc/2"                     # page 2 dies -> truncated walk
MONITOR_GRAPHQL_DEGRADED_ESCALATE_SECONDS=0     # escalate immediately
emit=$(_snapshot_issue_comments "")
assert_contains "partial delivery escalates out-of-band" "$emit" \
    "watcher_alert=ingest-degraded surface=issue_comments kind=truncated"
assert_contains "  names the withheld tail, not a slow fetch" "$emit" "unknown tail"
assert_contains "  and names the actionable knob" "$emit" "search_page_size"
assert_contains "  page-1 issues still surfaced" "$emit" "issue=1 "
assert_file_exists "  degradation state RETAINED (not cleared by partial success)" \
    "$STATE_DIR/graphql-degraded-issue_comments"

# NEGATIVE CONTROL: a COMPLETE walk must still clear the counter and stay
# quiet, or the above would just be "always alarm".
reset_h
mkpage 1 true c1 1 2
mkpage 2 false "" 3
emit=$(_snapshot_issue_comments "")
assert_not_contains "a complete walk does NOT escalate" "$emit" "ingest-degraded"
assert_no_file "  degradation state cleared" "$STATE_DIR/graphql-degraded-issue_comments"
unset MONITOR_GRAPHQL_DEGRADED_ESCALATE_SECONDS

echo "== per-page isolation: one bad page does not lose the good ones =="

reset_h
mkpage 1 true c1 1 2
mkpage 3 false "" 5
printf '1\n' > "$WORK/rc/2"    # page 2 transport failure
out="$WORK/out3.jsonl"
_snapshot_search_paged issue_comments "$QUERY" "repo:x is:issue" "$out"
assert_rc "walk still reports success (page 1 delivered)" "$?" "0"
assert_eq "page 1 survives a later page's failure" "$_SEARCH_PAGES_OK" "1"
assert_contains "issue 1 still surfaced" "$(jq -r '.data.search.nodes[].number' "$out" | tr '\n' ' ')" "1"

echo "== total failure is distinguishable from partial =="

reset_h
printf '1\n' > "$WORK/rc/1"
out="$WORK/out4.jsonl"
_snapshot_search_paged issue_comments "$QUERY" "repo:x is:issue" "$out"
assert_rc "every page failed -> rc 1" "$?" "1"
assert_eq "  zero usable pages" "$_SEARCH_PAGES_OK" "0"
assert_eq "  output file empty" "$(wc -c < "$out")" "0"

echo "== bounds: page cap and wall-clock budget are announced, not silent =="

reset_h
# An endless walk: every page claims another follows.
for i in $(seq 1 12); do mkpage "$i" true "c$i" "$i"; done
MONITOR_GRAPHQL_SEARCH_MAX_PAGES=4
out="$WORK/out5.jsonl"
_snapshot_search_paged issue_comments "$QUERY" "repo:x is:issue" "$out"
assert_eq "walk stops at the page cap" "$_SEARCH_PAGES_TOTAL" "4"
# NEGATIVE CONTROL on truncation. A capped walk that stays quiet reads
# downstream as "covered everything" — the exact silent-truncation
# failure mode. Assert the WARN, and assert it names the cap.
assert_contains "capped walk announces the coverage gap" "$(alerts)" \
    "graphql_partial_walk reason=page_cap"
assert_contains "  and states what was skipped" "$(alerts)" "were NOT fetched"
unset MONITOR_GRAPHQL_SEARCH_MAX_PAGES

echo "== config validation rejects nonsense rather than trusting it =="

reset_h
mkpage 1 false "" 1
MONITOR_GRAPHQL_SEARCH_PAGE_SIZE="; rm -rf /"
out="$WORK/out6.jsonl"
_snapshot_search_paged issue_comments "$QUERY" "repo:x is:issue" "$out" >/dev/null
assert_contains "non-numeric page size falls back to the default" \
    "$(sed -n 1p "$CALL_LOG")" "-F first=10"
MONITOR_GRAPHQL_SEARCH_PAGE_SIZE=500
reset_h; mkpage 1 false "" 1
_snapshot_search_paged issue_comments "$QUERY" "repo:x is:issue" "$out" >/dev/null
assert_contains "out-of-range page size falls back too" \
    "$(sed -n 1p "$CALL_LOG")" "-F first=10"
unset MONITOR_GRAPHQL_SEARCH_PAGE_SIZE

echo "== end-to-end _snapshot_issue_comments over multiple pages =="

reset_h
mkpage 1 true  c1 11 12
mkpage 2 false ""  13
emit=$(_snapshot_issue_comments "")
assert_contains "issue on page 1 emitted" "$emit" "issue=11 id=1100 author=operator"
assert_contains "issue on page 2 emitted" "$emit" "issue=13 id=1300 author=operator"
assert_eq "one emit block per comment across all pages" \
    "$(grep -c '^issue=' <<<"$emit")" "3"

# The dedup file must still be honoured across the page stream.
reset_h
mkpage 1 true  c1 11 12
mkpage 2 false ""  13
emit=$(_snapshot_issue_comments "comment:1200")
assert_not_contains "processed comment stays suppressed under pagination" "$emit" "id=1200"
assert_contains "  its page-mates still surface" "$emit" "id=1100"

# EYES/ROCKET eligibility must survive pagination too.
reset_h
mkdir -p "$WORK/pages"
printf '{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":""},"nodes":[{"number":20,"comments":{"nodes":[{"databaseId":2000,"author":{"login":"operator"},"body":"acked","reactions":{"nodes":[{"content":"ROCKET","user":{"login":"bot"}}]}},{"databaseId":2001,"author":{"login":"operator"},"body":"fresh","reactions":{"nodes":[]}}]}}]}}}' > "$WORK/pages/1.json"
emit=$(_snapshot_issue_comments "")
assert_not_contains "ROCKET-ed comment filtered" "$emit" "id=2000"
assert_contains "  un-acked comment surfaces" "$emit" "id=2001"

echo "== total-failure path escalates instead of failing silently =="

reset_h
printf '1\n' > "$WORK/rc/1"
MONITOR_GRAPHQL_DEGRADED_ESCALATE_SECONDS=0
emit=$(_snapshot_issue_comments "")
assert_contains "a wholly failed fetch escalates out-of-band" "$emit" \
    "watcher_alert=ingest-degraded surface=issue_comments"
unset MONITOR_GRAPHQL_DEGRADED_ESCALATE_SECONDS

echo "== the live query shape carries the stability sort =="

assert_contains "issue_comments queries sort:created-asc" \
    "$(declare -f _snapshot_issue_comments)" "sort:created-asc"
assert_contains "issue_comments paginates via \$after" \
    "$(declare -f _snapshot_issue_comments)" 'after: $after'
assert_contains "issue_comments still requests last:50 comments (no window narrowing)" \
    "$(declare -f _snapshot_issue_comments)" "comments(last: 50)"

echo "== a discarded FINAL page is 'partial', not 'truncated' =="

# Blast radius must be reported accurately: if the bad page is the last
# one, its own issues are withheld but there is no tail behind it.
reset_h
mkpage 1 true c1 1 2
cat > "$WORK/pages/2.json" <<'JSON'
{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":""},
 "nodes":[{"number":9,"comments":{"nodes":[{"databaseId":900,"author":null,"body":null,"reactions":null}]}}]}},
 "errors":[{"type":"RESOURCE_LIMITS_EXCEEDED","message":"Resource limits for this query exceeded."}]}
JSON
out="$WORK/outlast.jsonl"
_snapshot_search_paged issue_comments "$QUERY" "repo:x is:issue" "$out"
assert_eq "final bad page is NOT flagged truncated" "$_SEARCH_PAGES_TRUNCATED" "0"
assert_eq "  but is still counted failed" "$_SEARCH_PAGES_FAILED" "1"
assert_contains "  log says no tail was withheld" "$(alerts)" "no tail withheld"

reset_h
mkpage 1 true c1 1 2
cat > "$WORK/pages/2.json" <<'JSON'
{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":""},
 "nodes":[{"number":9,"comments":{"nodes":[{"databaseId":900,"author":null,"body":null,"reactions":null}]}}]}},
 "errors":[{"type":"RESOURCE_LIMITS_EXCEEDED","message":"Resource limits for this query exceeded."}]}
JSON
MONITOR_GRAPHQL_DEGRADED_ESCALATE_SECONDS=0
emit=$(_snapshot_issue_comments "")
assert_contains "a discarded page still escalates (kind=partial)" "$emit"     "watcher_alert=ingest-degraded surface=issue_comments kind=partial"
assert_not_contains "  and does NOT claim a withheld tail" "$emit" "unknown tail"
unset MONITOR_GRAPHQL_DEGRADED_ESCALATE_SECONDS

th_summary_and_exit
