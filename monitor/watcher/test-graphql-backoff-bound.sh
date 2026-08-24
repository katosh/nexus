#!/usr/bin/env bash
# Unit tests for the bounded, self-reconciling GraphQL backoff gate and
# the ingest-degradation escalation
# (`_graphql_backoff_active`, `_graphql_note_failure`/`_graphql_note_success`
# in monitor/watcher/_github.sh — your-org/nexus-code#594 and #595).
#
# Run: bash monitor/watcher/test-graphql-backoff-bound.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHAT IS ACTUALLY UNDER TEST. Not "does the gate return the right exit
# code" — the pre-#594 gate returned the right exit code for a stored
# instant it had no business trusting, and that is precisely how it
# severed the operator channel. The property is: **no computed instant,
# on its own, may keep operator communication withheld.** So every case
# below asserts on the REASON the gate reports (the reconcile line's
# `reason=` slug, the announcement's text), not on rc alone. An
# rc-only assertion cannot distinguish "opened because the ceiling
# forced it" from "opened because the epoch happened to elapse", and
# those are the two behaviours the whole change is about.
#
# `date` is shadowed so the clock can be advanced without sleeping.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR"
REPO="your-org/your-nexus"
USER_LOGIN="operator"

source "$_test_dir/_github.sh"

# Test clock. `date +%s` returns $NOW; everything else defers to the
# real date so ISO stamps in log lines stay well-formed.
NOW=1785000000
date() {
    if [[ "${1:-}" == "+%s" ]]; then printf '%s' "$NOW"; return 0; fi
    command date "$@"
}

alerts() { cat "$STATE_DIR/watcher-alerts.log" 2>/dev/null; }
reset_state() { rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"; }

echo "== the ordinary path still works =="

reset_state
_graphql_backoff_active issue_comments
assert_rc "no backoff file -> gate open" "$?" "1"

printf '%s\n%s\n' "$(( NOW + 600 ))" "$NOW" > "$STATE_DIR/graphql-backoff-issue_comments"
_graphql_backoff_active issue_comments
assert_rc "fresh backoff inside its window -> gate closed" "$?" "0"

NOW=$(( NOW + 700 ))
_graphql_backoff_active issue_comments
assert_rc "window elapsed -> gate open" "$?" "1"
assert_no_file "  state cleaned up" "$STATE_DIR/graphql-backoff-issue_comments"

echo "== BOUND: the ceiling overrides the stored prediction =="

reset_state
NOW=1785000000
# The exact #594 shape: an epoch far in the future. Pre-fix this
# suppressed the surface until that instant arrived — potentially never.
printf '%s\n%s\n' "$(( NOW + 86400 * 365 ))" "$NOW" > "$STATE_DIR/graphql-backoff-issue_comments"
MONITOR_GRAPHQL_BACKOFF_MAX_SECONDS=900

_graphql_backoff_active issue_comments
assert_rc "inside the ceiling, an absurd epoch still suppresses" "$?" "0"

NOW=$(( NOW + 901 ))
_graphql_backoff_active issue_comments
assert_rc "past the ceiling -> gate OPENS despite a year-away epoch" "$?" "1"
assert_no_file "  state cleared" "$STATE_DIR/graphql-backoff-issue_comments"
# NEGATIVE CONTROL, on the reason. rc=1 alone would also be produced by
# the plain expiry branch; only the reason distinguishes "the ceiling
# refused to honour this" from "the window simply elapsed".
assert_contains "  reconciled FOR THE CEILING REASON" "$(alerts)" \
    "graphql_backoff_reconciled reason=ceiling"
assert_contains "  and names the offending stamps" "$(alerts)" "armed=1785000000"

echo "== BOUND is measured from the OBSERVATION, not the prediction =="

reset_state
NOW=1785000000
# Armed long ago, prediction still in the future. The observation is
# stale; the gate must not honour it.
printf '%s\n%s\n' "$(( NOW + 600 ))" "$(( NOW - 5000 ))" > "$STATE_DIR/graphql-backoff-pr_comments"
MONITOR_GRAPHQL_BACKOFF_MAX_SECONDS=900
_graphql_backoff_active pr_comments
assert_rc "old observation + future prediction -> gate OPEN" "$?" "1"
assert_contains "  and says the ceiling did it" "$(alerts)" \
    "graphql_backoff_reconciled reason=ceiling"

echo "== RECONCILE: malformed and clock-skewed state repair, never wait =="

reset_state
printf 'not-an-epoch\n' > "$STATE_DIR/graphql-backoff-new_issues"
_graphql_backoff_active new_issues
assert_rc "unparseable reset -> gate open" "$?" "1"
assert_contains "  reason=malformed_reset" "$(alerts)" \
    "graphql_backoff_reconciled reason=malformed_reset"

reset_state
NOW=1785000000
# Clock jumped backwards: armed is "in the future". A naive `now-armed`
# yields a negative age that would sit under any ceiling forever.
printf '%s\n%s\n' "$(( NOW + 600 ))" "$(( NOW + 100000 ))" > "$STATE_DIR/graphql-backoff-issue_comments"
_graphql_backoff_active issue_comments
assert_rc "armed in the future (clock skew) -> gate open" "$?" "1"
assert_contains "  reason=ceiling" "$(alerts)" "reason=ceiling"

echo "== legacy single-line file (rolled forward) =="

reset_state
NOW=1785000000
printf '%s\n' "$(( NOW + 600 ))" > "$STATE_DIR/graphql-backoff-issue_comments"
# A legacy file carries no observation line, so the gate recovers one
# from the mtime. Pin the mtime to the TEST clock — leaving it at real
# wall-clock makes `now - armed` hugely negative under a fake past
# clock, which correctly trips the skew guard but tests the wrong branch.
touch -d "@$NOW" "$STATE_DIR/graphql-backoff-issue_comments"
_graphql_backoff_active issue_comments
assert_rc "legacy file inside window -> suppresses (mtime is the observation)" "$?" "0"

NOW=$(( NOW + 901 ))
MONITOR_GRAPHQL_BACKOFF_MAX_SECONDS=900
_graphql_backoff_active issue_comments
assert_rc "legacy file past the ceiling -> gate open" "$?" "1"
assert_contains "  ceiling applies to legacy files too" "$(alerts)" "reason=ceiling"

echo "== arm-side clamp: an absurd API reset never reaches disk =="

reset_state
NOW=1785000000
MONITOR_GRAPHQL_BACKOFF_MAX_SECONDS=900
err="$WORK/err.json"
cat > "$err" <<JSON
{"errors":[{"type":"RATE_LIMIT","extensions":{"reset_at_epoch":$(( NOW + 86400 * 365 ))}}]}
JSON
out=$(_watcher_handle_graphql_failure "$err" issue_comments)
stored=$(head -n1 "$STATE_DIR/graphql-backoff-issue_comments")
armed=$(sed -n 2p "$STATE_DIR/graphql-backoff-issue_comments")
assert_eq "stored reset clamped to now+ceiling" "$stored" "$(( NOW + 900 ))"
assert_eq "observation epoch recorded on line 2" "$armed" "$NOW"
assert_contains "  clamp is logged, not silent" "$(alerts)" "graphql_backoff_clamped"
assert_contains "  rate-limit sentinel still emitted" "$out" "watcher_alert=rate-limit"

# A reset already in the past must not park the gate on a negative window.
reset_state
cat > "$err" <<JSON
{"errors":[{"type":"RATE_LIMIT","extensions":{"reset_at_epoch":$(( NOW - 99999 ))}}]}
JSON
_watcher_handle_graphql_failure "$err" issue_comments >/dev/null
assert_eq "past reset collapses to now" \
    "$(head -n1 "$STATE_DIR/graphql-backoff-issue_comments")" "$NOW"

echo "== ANNOUNCE: a live suppression reports itself out-of-band =="

reset_state
NOW=1785000000
MONITOR_GRAPHQL_BACKOFF_MAX_SECONDS=3600
MONITOR_GRAPHQL_BACKOFF_ANNOUNCE_SECONDS=300
printf '%s\n%s\n' "$(( NOW + 3000 ))" "$NOW" > "$STATE_DIR/graphql-backoff-issue_comments"

out=$(_graphql_backoff_active issue_comments)
assert_empty "below the announce delay -> quiet" "$out"

NOW=$(( NOW + 301 ))
out=$(_graphql_backoff_active issue_comments)
assert_contains "past the delay -> sentinel on STDOUT (rides the emit)" \
    "$out" "watcher_alert=graphql-backoff surface=issue_comments"
assert_contains "  states the operator-visible consequence" "$out" \
    "are NOT reaching this emit"
assert_contains "  and logs it too" "$(alerts)" "graphql_backoff_suppressing"

NOW=$(( NOW + 60 ))
out=$(_graphql_backoff_active issue_comments)
assert_empty "announced once per hold, not per poll" "$out"

echo "== #595 ingest-degradation escalation =="

reset_state
NOW=1785000000
MONITOR_GRAPHQL_DEGRADED_ESCALATE_SECONDS=1800
MONITOR_GRAPHQL_DEGRADED_REMIND_SECONDS=3600

out=$(_graphql_note_failure issue_comments)
assert_empty "first failure is quiet (transients must not alert-storm)" "$out"
NOW=$(( NOW + 600 )); out=$(_graphql_note_failure issue_comments)
assert_empty "10 min of failures still quiet" "$out"

NOW=$(( NOW + 1300 )); out=$(_graphql_note_failure issue_comments)
assert_contains "past the escalate window -> out-of-band sentinel" \
    "$out" "watcher_alert=ingest-degraded surface=issue_comments"
assert_contains "  names it as the operator channel's ingest" "$out" \
    "ingest side of the operator channel"
assert_contains "  is honest that comments are NOT lost" "$out" "not lost"
assert_contains "  logged as escalated" "$(alerts)" "graphql_degraded_escalated"

NOW=$(( NOW + 600 )); out=$(_graphql_note_failure issue_comments)
assert_empty "re-nag is throttled to the slower cadence" "$out"
NOW=$(( NOW + 3100 )); out=$(_graphql_note_failure issue_comments)
assert_contains "past the remind cadence -> renags" "$out" "watcher_alert=ingest-degraded"

out=$(_graphql_note_success issue_comments)
assert_contains "recovery retracts the alert" "$out" "watcher_alert=ingest-recovered"
assert_no_file "  degraded state cleared" "$STATE_DIR/graphql-degraded-issue_comments"

# NEGATIVE CONTROL for the retraction: a surface that never escalated
# must NOT emit a recovery — otherwise every ordinary transient blip
# would produce an unexplained "recovered" line and train the reader to
# ignore the pair.
reset_state
_graphql_note_failure pr_comments >/dev/null
out=$(_graphql_note_success pr_comments)
assert_empty "recovery WITHOUT a prior escalation stays silent" "$out"

echo "== a clean run touches nothing =="

reset_state
out=$(_graphql_note_success new_issues)
assert_empty "success with no prior failure -> silent" "$out"
assert_eq "  no alerts written" "$(alerts | wc -l)" "0"

th_summary_and_exit
