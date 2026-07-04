#!/usr/bin/env bash
# Regression tests for the eligibility-staleness bug (live reproduction
# on your-org/your-nexus#128 comment 4560117367, 2026-05-27).
#
# Symptom — operator confirmed PR #188's null-safe filter + suppress-emit
# channel did NOT prevent the bug. A comment with bot-EYES (well-formed,
# non-null .user.login) and an entry in processed-comments.txt resurfaced
# every nudge cycle.
#
# Root cause — the v2 scheduler stages the eligibility-filtered output
# of `_snapshot_issue_comments` in `github_poll.out` once per 600s tick.
# Between ticks, `_v2_task_compose_emit` re-reads that staged file and
# pipes it through `_gh_filter_dedup_pipeline`. That pipeline only
# applied: author chokepoint, cross-repo gate, in-stream dedup,
# operator suppression. It did NOT re-apply the processed-comments
# dedup. When the bot reacts EYES on a fresh comment (writes to
# processed-comments.txt at the same instant), the staged file remains
# the pre-reaction snapshot for up to 600s, and every compose_emit
# during that window emits the comment as eligible.
#
# These tests assert two new behaviours expected to land in the same
# PR:
#
#   (1) `_filter_processed_comments` — last-hop awk filter that drops
#       any emit block whose `id=<N>` matches a `comment:<N>` line in
#       `$STATE_DIR/processed-comments.txt`. Wired into
#       `_gh_filter_dedup_pipeline` so the live state of the processed
#       cache is consulted every compose_emit, eliminating the 600s
#       staleness window.
#
#   (2) `_filter_emit_cooldown` — third-tier rate limiter. After an
#       emit of `id=<N>`, subsequent emits within
#       `MONITOR_EMIT_COOLDOWN_SECONDS` are dropped unless the body
#       content-hash changes (operator edited the comment).
#
# Both filters layer on top of, not replace, the existing reaction
# filter inside `_snapshot_issue_comments` and the suppress-emit
# channel from PR #188.
#
# Run: bash monitor/watcher/test-eligibility-staleness.sh

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
FIXTURE_DIR="$_test_dir/fixtures"

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
assert_equal() {
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
CROSS_REPO_SURFACE="off"
export STATE_DIR REPO USER_LOGIN BOT_LOGIN CROSS_REPO_SURFACE

# The filter members live in _emit_filters.sh (issue 180 S2 seam) —
# functions-only, sourceable directly. Only the pipeline wrapper
# `_gh_filter_dedup_pipeline` remains in main.sh (heavy top-level
# state we can't source), so it keeps the awk-extract + eval trick
# `test-emit-suppression.sh` also uses.
. "$_test_dir/_github.sh"
. "$_test_dir/_emit_filters.sh"
for fn in _gh_filter_dedup_pipeline; do
    fn_def=$(awk -v fn="$fn" '
        $0 ~ "^" fn "\\(\\) \\{$" { capture=1 }
        capture { print; if ($0 == "}") capture=0 }
    ' "$_test_dir/main.sh")
    if [[ -z "$fn_def" ]]; then
        echo "test setup: could not extract $fn() from main.sh" >&2
        exit 1
    fi
    eval "$fn_def"
done

# ---- Captured-fixture verification ------------------------------------
# `regression-staleness-issue128.json` was captured byte-for-byte from
# the real GraphQL response at the time the bug was reproducing on the
# operator's watcher (2026-05-27 ~18:55 PDT). Every quirk of the
# response — `.user.login = "your-org-bot[bot]"` exact string,
# the trailing `[bot]` suffix, the ASCII-only body — is preserved.

echo '=== captured fixture: eyes-only comment is excluded by _snapshot_issue_comments ==='

ISSUE_FIXTURE=$(cat "$FIXTURE_DIR/regression-staleness-issue128.json")
PR_FIXTURE='{"data":{"search":{"nodes":[]}}}'
NEW_ISSUES_FIXTURE='{"data":{"search":{"nodes":[]}}}'

MINT_STUB="$WORK/mint-token.sh"
printf '#!/usr/bin/env bash\nprintf %%s test-token\n' > "$MINT_STUB"
chmod +x "$MINT_STUB"
MINT_TOKEN_BIN="$MINT_STUB"
export MINT_TOKEN_BIN

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

# Belt: snapshot_github runs the eligibility filter and MUST exclude
# the EYES'd comment in the fixture. Suspenders: the next assertion
# also confirms processed-comments dedup catches it.
out=$(snapshot_github)
assert_not_contains "fixture EYES-only id=4560117367 excluded" "$out" "id=4560117367"

# ---- Root-cause regression: stale staged input + live processed cache -
# Simulates the watcher's actual failure mode. `staged_input` is the
# byte-for-byte content `github_poll.out` carried at the time the
# operator added bot-EYES + processed-comments entry. It LOOKS
# eligible — the EYES filter ran 600s ago, before EYES was added.
# Now compose_emit fires; the pipeline must consult the live
# processed-comments cache and drop the block.

echo '=== stale-staged input is dropped by processed-comments re-check ==='

staged_input=$'issue=128 id=4560117367 author=operator\n  body: @your-org-bot please act on operator\'s instructions.\nissue=128 id=4560015629 author=operator\n  body: fresh request that should still surface\n'

# Live processed-comments cache: bot added EYES + appended after the
# github_poll snapshot was written.
printf 'comment:4560117367\n' > "$STATE_DIR/processed-comments.txt"
out=$(printf '%s' "$staged_input" | _filter_processed_comments)
assert_not_contains "live-processed: id=4560117367 dropped" "$out" "id=4560117367"
assert_contains     "live-processed: id=4560015629 surfaces" "$out" "id=4560015629"

echo '=== _gh_filter_dedup_pipeline now drops processed-cache entry ==='
# Reset cooldown stamps so the cooldown filter doesn't shadow this case.
rm -rf "$STATE_DIR/emit-history"
# emit-suppression file absent so suppress filter is passthrough.
rm -f "$STATE_DIR/emit-suppression.lines"
out=$(printf '%s' "$staged_input" | _gh_filter_dedup_pipeline)
assert_not_contains "pipeline: stale eligible id=4560117367 dropped" "$out" "id=4560117367"
assert_contains     "pipeline: fresh id=4560015629 surfaces"          "$out" "id=4560015629"

# ---- _filter_processed_comments unit assertions ----------------------

echo '=== _filter_processed_comments unit: absent file is passthrough ==='
rm -f "$STATE_DIR/processed-comments.txt"
input=$'issue=1 id=100 author=alice\n  body: hello\n'
out=$(printf '%s' "$input" | _filter_processed_comments)
assert_contains "absent processed cache passes block" "$out" "id=100"

echo '=== _filter_processed_comments unit: issue:<N> drops issue_new ==='
printf 'issue:55\n' > "$STATE_DIR/processed-comments.txt"
input=$'issue_new=55 author=alice\n  body: new issue\nissue_new=66 author=alice\n  body: another issue\n'
out=$(printf '%s' "$input" | _filter_processed_comments)
assert_not_contains "processed-issue: issue_new=55 dropped" "$out" "issue_new=55"
assert_contains     "processed-issue: issue_new=66 surfaces" "$out" "issue_new=66"

echo '=== _filter_processed_comments unit: id substring safety ==='
printf 'comment:100\n' > "$STATE_DIR/processed-comments.txt"
# `id=1001` must NOT match the `comment:100` entry — same token-boundary
# discipline `_filter_suppression` uses.
input=$'issue=1 id=1001 author=alice\n  body: should pass\nissue=2 id=100 author=alice\n  body: should drop\n'
out=$(printf '%s' "$input" | _filter_processed_comments)
assert_contains     "id=1001 (substring of 100) passes" "$out" "id=1001"
assert_not_contains "id=100 dropped"                     "$out" "id=100 author"

echo '=== _filter_processed_comments unit: blank + # comments tolerated ==='
printf '\n  comment:100  \n# explanation line\n\ncomment:200\nrubbish\n' > "$STATE_DIR/processed-comments.txt"
input3=$'issue=1 id=100 author=alice\n  body: drop1\nissue=2 id=200 author=alice\n  body: drop2\nissue=3 id=300 author=alice\n  body: pass\n'
out=$(printf '%s' "$input3" | _filter_processed_comments)
assert_not_contains "id=100 dropped (whitespace tolerated)" "$out" "id=100 author"
assert_not_contains "id=200 dropped"                        "$out" "id=200 author"
assert_contains     "id=300 passes (no entry)"              "$out" "id=300"

# ---- _filter_emit_cooldown unit assertions ---------------------------

echo '=== _filter_emit_cooldown: first emit passes + stamps history ==='
HIST_DIR="$STATE_DIR/emit-history"
rm -rf "$HIST_DIR"
MONITOR_EMIT_COOLDOWN_SECONDS=300
export MONITOR_EMIT_COOLDOWN_SECONDS
input=$'issue=10 id=1234 author=alice\n  body: first emit\n'
out=$(printf '%s' "$input" | _filter_emit_cooldown)
assert_contains "first emit surfaces" "$out" "id=1234"
[[ -f "$HIST_DIR/comment-1234.meta" ]] && {
    printf '  PASS: history file written for id=1234\n'; PASS=$(( PASS + 1 ))
} || {
    printf '  FAIL: history file MISSING for id=1234\n' >&2
    FAIL=$(( FAIL + 1 ))
}

echo '=== _filter_emit_cooldown: repeat within window dropped ==='
out=$(printf '%s' "$input" | _filter_emit_cooldown)
assert_not_contains "repeat within cooldown dropped" "$out" "id=1234"

echo '=== _filter_emit_cooldown: body change bypasses cooldown ==='
input_changed=$'issue=10 id=1234 author=alice\n  body: operator edited the request\n'
out=$(printf '%s' "$input_changed" | _filter_emit_cooldown)
assert_contains "edited body bypasses cooldown" "$out" "id=1234"

echo '=== _filter_emit_cooldown: expired stamp re-emits ==='
rm -rf "$HIST_DIR"
mkdir -p "$HIST_DIR"
# Stamp 1 hour ago with the original body sha — cooldown 300s, must expire.
old_ts=$(( $(date +%s) - 3600 ))
old_body=$'  body: first emit'
# Recompute sha exactly the same way the filter does (whole body line).
old_sha=$(printf '%s' "$old_body" | sha256sum | awk '{print $1}')
printf 'ts=%s\nbody_sha=%s\n' "$old_ts" "$old_sha" > "$HIST_DIR/comment-1234.meta"
out=$(printf '%s' "$input" | _filter_emit_cooldown)
assert_contains "expired stamp re-emits" "$out" "id=1234"

echo '=== _filter_emit_cooldown: cooldown=0 disables filter ==='
rm -rf "$HIST_DIR"
MONITOR_EMIT_COOLDOWN_SECONDS=0
out1=$(printf '%s' "$input" | _filter_emit_cooldown)
out2=$(printf '%s' "$input" | _filter_emit_cooldown)
assert_contains "cooldown=0: first emit surfaces"  "$out1" "id=1234"
assert_contains "cooldown=0: second emit surfaces" "$out2" "id=1234"
MONITOR_EMIT_COOLDOWN_SECONDS=300

echo '=== _filter_emit_cooldown: integration via _gh_filter_dedup_pipeline ==='
rm -rf "$HIST_DIR"
rm -f "$STATE_DIR/emit-suppression.lines"
rm -f "$STATE_DIR/processed-comments.txt"
USER_LOGIN="alice"
export USER_LOGIN
fresh_input=$'issue=20 id=9876 author=alice\n  body: brand-new request\n'
out=$(printf '%s' "$fresh_input" | _gh_filter_dedup_pipeline)
assert_contains "pipeline first emit surfaces" "$out" "id=9876"
out=$(printf '%s' "$fresh_input" | _gh_filter_dedup_pipeline)
assert_not_contains "pipeline second emit dropped by cooldown" "$out" "id=9876"
USER_LOGIN="operator"
export USER_LOGIN

# ---- Composition order: processed-cache + suppress + cooldown stack ---

echo '=== full pipeline composes all three drop layers ==='
rm -rf "$HIST_DIR"
printf 'comment:1\n' > "$STATE_DIR/processed-comments.txt"
printf 'comment:2\n' > "$STATE_DIR/emit-suppression.lines"
USER_LOGIN="alice"
export USER_LOGIN
input=$'issue=1 id=1 author=alice\n  body: drop by processed\nissue=2 id=2 author=alice\n  body: drop by suppress\nissue=3 id=3 author=alice\n  body: should surface\n'
out=$(printf '%s' "$input" | _gh_filter_dedup_pipeline)
assert_not_contains "processed: id=1 dropped" "$out" "id=1 author"
assert_not_contains "suppress: id=2 dropped"  "$out" "id=2 author"
assert_contains     "id=3 surfaces"           "$out" "id=3 author"
USER_LOGIN="operator"
export USER_LOGIN

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
