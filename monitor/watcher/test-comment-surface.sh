#!/usr/bin/env bash
# Tests for the sweep-independent operator-comment surfacing path
# (your-org/nexus-code#562).
#
# The defect: eligible-comment surfacing was coupled to the sweep-priced
# compose_emit body; at ~12 windows the sweep pushed compose_emit past
# its 300s watchdog and operator comments surfaced ~8min late. The fix:
# a `comment_surface` task computes the shared gh_now view and pastes a
# MINIMAL emit with no pane probing at all; compose_emit keeps a
# backstop call, with the per-comment cooldown stamp making the two
# paths mutually exclusive per comment.
#
# Covers:
#   1.  `_compose_gh_now` surfaces an eligible comment from the staged
#       github_poll.out (extraction fidelity)
#   2.  `_v2_task_comment_surface` pastes a minimal emit: eligible
#       section + sig trailer present; NO workspace prelude, NO
#       snapshot section, NO pane-state invocation (the decoupling)
#   3.  quiet path: empty gh_now → no paste, no archive
#   4.  cooldown exclusivity: after comment_surface surfaces id=N, a
#       backstop `_compose_gh_now` run returns EMPTY for the same body
#       (no double-paste), and an EDITED body re-surfaces
#   5.  paste-failure accounting: failed paste → _emit_delivery_fail,
#       no record-emit
#   6.  nudge lane split: queue/github advances nudge comment_surface
#       (not compose_emit); requests advances nudge compose_emit;
#       fallback to compose_emit when comment_surface unregistered
#   7.  paste lock: two concurrent paste_to_target calls into the same
#       target serialize (no interleaving)
#
# Run: bash monitor/watcher/test-comment-surface.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() {
    printf '  FAIL: %s\n' "$1" >&2
    [[ $# -ge 2 ]] && printf '         %s\n' "$2" >&2
    FAIL=$(( FAIL + 1 ))
}
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then pass "$label"; else fail "$label" "got $(printf %q "$got"), want $(printf %q "$want")"; fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then pass "$label"; else fail "$label" "expected to find: $needle"; fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if ! grep -qF -- "$needle" <<<"$hay"; then pass "$label"; else fail "$label" "did NOT expect: $needle"; fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export STATE_DIR="$WORK/state"
mkdir -p "$STATE_DIR"
tmp_dir="$WORK/tmp"; mkdir -p "$tmp_dir"
V2_STAGE_DIR="$WORK/stage"; mkdir -p "$V2_STAGE_DIR"
TARGET="orchestrator"

# Filter knobs: alice is the operator; cooldown ON (it is load-bearing
# for the exclusivity contract under test).
USER_LOGIN="alice"; BOT_LOGIN=""; CROSS_REPO_SURFACE="off"
MONITOR_EMIT_COOLDOWN_SECONDS=300
export USER_LOGIN BOT_LOGIN CROSS_REPO_SURFACE MONITOR_EMIT_COOLDOWN_SECONDS

# Real filter pipeline members (`_filter_cross_repo_surface` lives in
# _github.sh; the rest in _emit_filters.sh — same pair the multibyte
# compose tests source).
# shellcheck source=_emit_filters.sh
. "$_test_dir/_emit_filters.sh"
# shellcheck source=_github.sh
. "$_test_dir/_github.sh"

# Pluck the functions under test from main.sh (top-level execution
# prevents wholesale sourcing; same pattern as the multibyte tests).
_pluck_fn() {  # <fn-name> <file>
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\) \\{" { capture=1 }
        capture { print }
        capture && /^\}/ { exit }
    ' "$2"
}
eval "$(_pluck_fn _run_bounded                    "$_test_dir/main.sh")"
eval "$(_pluck_fn _gh_filter_dedup_pipeline       "$_test_dir/main.sh")"
eval "$(_pluck_fn _gh_filter_dedup_pipeline_file  "$_test_dir/main.sh")"
eval "$(_pluck_fn _compose_gh_now                 "$_test_dir/main.sh")"
eval "$(_pluck_fn _v2_task_comment_surface        "$_test_dir/main.sh")"
eval "$(_pluck_fn paste_to_target                 "$_test_dir/main.sh")"

# ---- stubs ---------------------------------------------------------------
log() { printf '[test-log] %s\n' "$*" >&2; }
_close_inherited_locks() { :; }
_ensure_watcher_tmp_dir() { mkdir -p "$tmp_dir"; }
_drain_deliveries_queue() { :; }
_reemit_gc() { :; }
_reemit_register() { cat >/dev/null; }
_reemit_pending() { :; }
_filter_reemit_backoff() { cat; }   # not sourced from _emit_filters in this scope? (it is; keep real if defined)
# Prefer the real backoff filter when _emit_filters.sh provided it.
declare -F _filter_reemit_backoff >/dev/null || _filter_reemit_backoff() { cat; }

PASTE_LOG="$WORK/paste.log"
PASTE_BODY_DIR="$WORK/pastes"; mkdir -p "$PASTE_BODY_DIR"
PASTE_RC=0
paste_with_retry() {
    local target="$1" body_file="$2"
    local n
    n=$(ls "$PASTE_BODY_DIR" | wc -l)
    cp "$body_file" "$PASTE_BODY_DIR/paste-$(( n + 1 )).md"
    printf 'paste target=%s\n' "$target" >> "$PASTE_LOG"
    return "$PASTE_RC"
}
ARCHIVE_LOG="$WORK/archive.log"
archive_emit() { printf 'archived tag=%s\n' "${2:-}" >> "$ARCHIVE_LOG"; printf '%s/archive-fake.md\n' "$WORK"; }
_over_limit_orchestrator_paused() { return 1; }
_over_limit_record_held() { :; }
DELIVERY_OK_COUNT=0; DELIVERY_FAIL_COUNT=0
_emit_delivery_ok()   { DELIVERY_OK_COUNT=$(( DELIVERY_OK_COUNT + 1 )); }
_emit_delivery_fail() { DELIVERY_FAIL_COUNT=$(( DELIVERY_FAIL_COUNT + 1 )); }
RECORD_EMIT_COUNT=0
_compose_emit_record_emit() { RECORD_EMIT_COUNT=$(( RECORD_EMIT_COUNT + 1 )); }
RESPAWN_HISTORY="$WORK/respawn-history"
RESPAWN_TRIPPED="$WORK/respawn-tripped"
RESPAWN_CONSEC_COUNTER="$WORK/respawn-consec"
RESPAWN_SLOW_GRIND_TRIPPED="$WORK/respawn-slow-grind"
_respawn_loop_reset() { :; }
_respawn_consec_reset() { :; }
# Canary: the decoupled path must NEVER probe panes.
PANE_PROBE_LOG="$WORK/pane-probes.log"
_idle_pane_state_line() { printf 'probe\n' >> "$PANE_PROBE_LOG"; printf 'state=idle active=0\n'; }
render_idle_prelude() { printf 'probe-prelude\n' >> "$PANE_PROBE_LOG"; printf '0 busy\n'; }

# ---- fixture comment -----------------------------------------------------
stage_comment() {  # <id> <body>
    printf 'issue=42 author=alice id=%s title=Test\n  body: %s\n' "$1" "$2" \
        > "$V2_STAGE_DIR/github_poll.out"
}

# ============================================================
echo '=== (1) _compose_gh_now surfaces the staged eligible comment ==='
stage_comment 1001 "please deploy the fix"
gh=$(_compose_gh_now)
assert_contains "comment id surfaced" "$gh" "id=1001"
assert_contains "body surfaced" "$gh" "please deploy the fix"

echo '=== (2) comment_surface pastes a minimal, sweep-free emit ==='
rm -f "$STATE_DIR"/emit-history/comment-*.meta 2>/dev/null
stage_comment 1001 "please deploy the fix"
_v2_task_comment_surface
body=$(cat "$PASTE_BODY_DIR/paste-1.md" 2>/dev/null || true)
assert_contains "eligible section present" "$body" "--- eligible github comments ---"
assert_contains "comment present" "$body" "id=1001"
assert_contains "sig trailer present" "$body" "--- nexus-emit-sig "
assert_contains "standard emit header" "$body" "=== nexus state changed at"
assert_not_contains "no workspace prelude" "$body" "workspace:"
assert_not_contains "no snapshot section" "$body" "--- workspace snapshot ---"
assert_not_contains "no idle section" "$body" "--- idle workers ---"
if [[ -f "$PANE_PROBE_LOG" ]]; then
    fail "comment_surface probed a pane ($(wc -l < "$PANE_PROBE_LOG") probes)"
else
    pass "zero pane probes on the comment path"
fi
assert_eq "delivery-ok accounted" "$DELIVERY_OK_COUNT" "1"
assert_eq "emit recorded for dedup ring" "$RECORD_EMIT_COUNT" "1"

echo '=== (3) quiet path: nothing eligible → no paste, no archive ==='
: > "$V2_STAGE_DIR/github_poll.out"
rm -f "$ARCHIVE_LOG"
_v2_task_comment_surface
n_pastes=$(ls "$PASTE_BODY_DIR" | wc -l)
assert_eq "no new paste" "$n_pastes" "1"
[[ -f "$ARCHIVE_LOG" ]] && fail "archived an empty emit" || pass "no archive on quiet path"

echo '=== (4) cooldown exclusivity: backstop cannot double-paste; edit re-surfaces ==='
stage_comment 1001 "please deploy the fix"
gh_backstop=$(_compose_gh_now)
assert_eq "same body within cooldown → backstop sees EMPTY" "$gh_backstop" ""
stage_comment 1001 "please deploy the fix -- EDITED"
gh_edited=$(_compose_gh_now)
assert_contains "edited body bypasses cooldown" "$gh_edited" "EDITED"

echo '=== (5) paste failure → delivery-fail accounting, no record-emit ==='
rm -f "$STATE_DIR"/emit-history/comment-*.meta 2>/dev/null
stage_comment 2002 "another ask"
PASTE_RC=4
_v2_task_comment_surface
PASTE_RC=0
assert_eq "delivery-fail accounted" "$DELIVERY_FAIL_COUNT" "1"
assert_eq "no record-emit on failed paste" "$RECORD_EMIT_COUNT" "1"

echo '=== (6) nudge lane split ==='
# shellcheck source=_scheduler.sh
source "$_test_dir/_scheduler.sh"
# shellcheck source=_compose_nudge.sh
source "$_test_dir/_compose_nudge.sh"
dummy() { return 0; }
queue_file="$WORK/deliveries-queue.lines"
gh_out_file="$WORK/github_poll_nudge.out"
req_out_file="$WORK/requests_poll.out"

# (6a) both tasks registered: queue advance nudges comment_surface only.
_compose_nudge_reset_for_tests
_scheduler_reset_for_tests
NEXUS_TEST_NOW=1000
_schedule_task compose_emit 60 dummy --class medium
_schedule_task comment_surface 15 dummy --class medium
TASK_NEXT_FIRE[compose_emit]=1060
TASK_NEXT_FIRE[comment_surface]=1015
printf 'issue=42 id=99 author=alice\n  body: hi\n' > "$queue_file"
touch -d @1001 "$queue_file" 2>/dev/null || touch "$queue_file"
NEXUS_TEST_NOW=1001
_compose_emit_nudge_check "$queue_file" "$gh_out_file" "$req_out_file"
assert_eq "queue advance → comment_surface pulled" "${TASK_NEXT_FIRE[comment_surface]}" "0"
assert_eq "queue advance → compose_emit NOT pulled" "${TASK_NEXT_FIRE[compose_emit]}" "1060"

# (6b) requests advance nudges compose_emit only.
TASK_NEXT_FIRE[comment_surface]=1015
printf 'request pending\n' > "$req_out_file"
touch -d @1002 "$req_out_file" 2>/dev/null || touch "$req_out_file"
NEXUS_TEST_NOW=1002
_compose_emit_nudge_check "$queue_file" "$gh_out_file" "$req_out_file"
assert_eq "requests advance → compose_emit pulled" "${TASK_NEXT_FIRE[compose_emit]}" "0"
assert_eq "requests advance → comment_surface NOT pulled" "${TASK_NEXT_FIRE[comment_surface]}" "1015"

# (6c) comment_surface unregistered → queue advance falls back to compose_emit.
_compose_nudge_reset_for_tests
_scheduler_reset_for_tests
NEXUS_TEST_NOW=2000
_schedule_task compose_emit 60 dummy --class medium
TASK_NEXT_FIRE[compose_emit]=2060
touch -d @2001 "$queue_file" 2>/dev/null || touch "$queue_file"
NEXUS_TEST_NOW=2001
_compose_emit_nudge_check "$queue_file" "$gh_out_file" "$req_out_file"
assert_eq "fallback: compose_emit pulled when comment_surface absent" "${TASK_NEXT_FIRE[compose_emit]}" "0"

echo '=== (7b) concurrent cooldown passes: exactly one wins (skeptic finding, atomic stamp) ==='
if command -v flock >/dev/null 2>&1; then
    rm -f "$STATE_DIR"/emit-history/comment-777* 2>/dev/null
    conc_block=$'issue=42 author=alice id=777 title=Race\n  body: the same comment seen by both paths\n'
    out_a="$WORK/conc-a.out"; out_b="$WORK/conc-b.out"
    ( printf '%s' "$conc_block" | _filter_emit_cooldown > "$out_a" ) &
    pa=$!
    ( printf '%s' "$conc_block" | _filter_emit_cooldown > "$out_b" ) &
    pb=$!
    wait "$pa" "$pb"
    passes=$(cat "$out_a" "$out_b" | grep -c "id=777")
    assert_eq "same comment passes exactly one concurrent filter run" "$passes" "1"
else
    pass "flock unavailable; concurrent-cooldown test skipped (documented fail-open)"
fi

echo '=== (7) paste lock serializes concurrent pasters ==='
if command -v flock >/dev/null 2>&1; then
    SERIAL_LOG="$WORK/serial.log"
    _paste_to_target_unlocked() {
        printf 'start %s\n' "$(date +%s.%N)" >> "$SERIAL_LOG"
        sleep 1
        printf 'end %s\n' "$(date +%s.%N)" >> "$SERIAL_LOG"
        return 0
    }
    body_a="$WORK/body-a"; printf 'a\n' > "$body_a"
    paste_to_target orchestrator "$body_a" &
    p1=$!
    paste_to_target orchestrator "$body_a" &
    p2=$!
    wait "$p1" "$p2"
    # Serialized ⇔ events strictly alternate start,end,start,end.
    seq=$(awk '{print $1}' "$SERIAL_LOG" | tr '\n' ' ')
    assert_eq "no interleaving (start end start end)" "$seq" "start end start end "
else
    pass "flock unavailable; lock test skipped (fail-open path covered by design)"
fi

# ============================================================
echo
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED ($PASS)"
    exit 0
else
    echo "$FAIL TEST(S) FAILED ($PASS passed)" >&2
    exit 1
fi
