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
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    if [[ -n "$needle" ]] && grep -qF -- "$needle" <<<"$hay"; then pass "$label"; else fail "$label" "expected to find: $needle"; fi
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

echo '=== (5b) your-org/nexus-code#966: a staged watcher_alert must not re-emit every fire ==='
# THE DEFECT. `_compose_gh_now` `cat`s `<stage>/github_poll.out` (main.sh
# ~L3995) WITHOUT consuming it, and `github_poll` rewrites that file only
# every 600 s. Every `comment_surface` fire in between therefore re-reads
# the SAME bytes. For a comment that is harmless — the pipeline damps it. An
# alert is forwarded by every hop instead, because each dispatches on the
# recognised emit-header shapes `^(issue|pr|pr_review|issue_new|mention|
# cross_repo)=` and takes its DEFAULT ARM on anything else. (Not "all eight
# key on `id=<N>`" — only the five damping hops do; the author, skip-marker
# and cross-repo hops key on other things and would forward an alert
# carrying an id anyway.) So it passes all eight, and
# `_v2_task_comment_surface` pastes unconditionally
# (its dedup gate is bypassed by design for comment-bearing bodies). During
# the 2026-08-17 GraphQL 503 that produced 20+ byte-identical pastes with a
# FROZEN `held_s=2403` — frozen because the generator's announce-once
# contract worked perfectly; only the replay was unbounded.
#
# The property under test is therefore NOT "the generator announces once"
# (test-graphql-backoff-bound.sh already owns that, and it passed throughout
# the incident). It is: **a staged alert survives an arbitrary number of
# re-reads as ONE emit, while a genuine state change still gets through.**
alert_hist="$STATE_DIR/alert-history"
stage_alert() { printf '%s\n' "$1" > "$V2_STAGE_DIR/github_poll.out"; }
# The literal block from the incident (monitor/.state/watcher-alerts.log,
# 2026-08-17T10:45:41-07:00), truncated body — the header carries the
# state-bearing tokens and is what the key + hash are computed over.
DEGRADED_2403=$'watcher_alert=ingest-degraded surface=issue_comments kind=total held_s=2403 failures=5\n  body: The issue_comments fetch has failed on EVERY attempt for 40 min (5 consecutive failures).'
DEGRADED_6003=$'watcher_alert=ingest-degraded surface=issue_comments kind=total held_s=6003 failures=11\n  body: The issue_comments fetch has failed on EVERY attempt for 100 min (11 consecutive failures).'

# Count HEADER OCCURRENCES, not matching lines: `grep -c` counts lines and
# would read 1 for a body that happened to quote the token twice.
count_alerts() { grep -o "$2" <<<"$1" | wc -l | tr -d ' '; }

# --- the storm itself: N re-reads of ONE staged generation -> ONE emit ---
rm -rf "$alert_hist" "$STATE_DIR"/emit-history; mkdir -p "$STATE_DIR/emit-history"
stage_alert "$DEGRADED_2403"
storm=""
for _i in 1 2 3 4 5 6; do storm+=$(_compose_gh_now)$'\n'; done
n=$(count_alerts "$storm" 'watcher_alert=ingest-degraded')
assert_eq "6 fires against one staged alert emit it exactly ONCE" "$n" "1"

# --- but a real state change must still reach the operator ---
stage_alert "$DEGRADED_6003"
escalated=$(_compose_gh_now)
assert_contains "a WORSENED alert (held_s advanced) bypasses the damper" \
    "$escalated" "held_s=6003"
again=$(_compose_gh_now)
assert_not_contains "  and then damps at its own new value" "$again" "held_s=6003"

# --- recovery is a DIFFERENT kind: it must not inherit the hold ---
# An `ingest-recovered` swallowed by a degraded-alert cooldown is strictly
# worse than the storm: the operator is left unable to tell "recovered"
# from "watcher died", which is exactly what `#966` item 3 asks for.
stage_alert $'watcher_alert=ingest-recovered surface=issue_comments\n  body: The issue_comments fetch is succeeding again after 100 min degraded.'
recovered=$(_compose_gh_now)
assert_contains "recovery surfaces immediately despite the degraded hold" \
    "$recovered" "watcher_alert=ingest-recovered"

# --- the SIBLING kinds `#966` flagged as unmeasured storm identically ---
# `graphql-backoff` (_github.sh ~L339) and `rate-limit` (~L413) print from
# the same stdout into the same staging file, so they are the same defect,
# not two similar ones. Assert the fix is keyed on the CLASS.
for kind_block in \
    'watcher_alert=graphql-backoff surface=issue_comments held_s=900 ceiling_s=3600' \
    'watcher_alert=rate-limit surface=pr_comments reset=1786990000'
do
    kind="${kind_block#watcher_alert=}"; kind="${kind%% *}"
    stage_alert "$kind_block"$'\n  body: sibling alert body'
    sib=""
    for _i in 1 2 3 4; do sib+=$(_compose_gh_now)$'\n'; done
    assert_eq "sibling '$kind' damped too (4 fires -> 1 emit)" \
        "$(count_alerts "$sib" "watcher_alert=$kind")" "1"
done

# --- co-tenancy: damping alerts must not cost us the operator channel ---
# The alert and a fresh operator comment share one staged file. The comment
# must surface; the alert must surface once; neither may suppress the other.
rm -rf "$alert_hist" "$STATE_DIR"/emit-history; mkdir -p "$STATE_DIR/emit-history"
printf '%s\n%s\n' \
    "$DEGRADED_2403" \
    "$(printf 'issue=42 author=alice id=5150 title=Urgent\n  body: are you seeing my comments?')" \
    > "$V2_STAGE_DIR/github_poll.out"
both=""
for _i in 1 2 3; do both+=$(_compose_gh_now)$'\n'; done
assert_eq "operator comment still surfaces exactly once" \
    "$(count_alerts "$both" 'id=5150')" "1"
assert_eq "  alongside exactly one alert" \
    "$(count_alerts "$both" 'watcher_alert=ingest-degraded')" "1"

# --- NEGATIVE CONTROL: the knob at 0 reproduces `#966` verbatim ---
# Without this, a passing suite cannot distinguish "the damper works" from
# "something upstream happened to eat the block". Turning the damper OFF
# must restore the storm; if it does not, the assertions above are not
# witnessing the mechanism they name.
rm -rf "$alert_hist" "$STATE_DIR"/emit-history; mkdir -p "$STATE_DIR/emit-history"
MONITOR_ALERT_EMIT_COOLDOWN_SECONDS=0
stage_alert "$DEGRADED_2403"
unstormed=""
for _i in 1 2 3 4 5 6; do unstormed+=$(_compose_gh_now)$'\n'; done
assert_eq "damper disabled -> the #966 storm returns (6 fires, 6 emits)" \
    "$(count_alerts "$unstormed" 'watcher_alert=ingest-degraded')" "6"
unset MONITOR_ALERT_EMIT_COOLDOWN_SECONDS

# --- and once more against the REAL generator, not a hand-written block ---
# Everything above stages a block this file typed. That is a fixture agreeing
# with itself: if the damper's kind/surface parse and the generator's actual
# output format ever diverge, every assertion above still passes and the storm
# comes back in production. So drive `_graphql_note_failure` (the real
# `_github.sh` function, already sourced) to EMIT the block, stage exactly what
# it produced, and re-run the replay.
rm -rf "$alert_hist" "$STATE_DIR"/emit-history; mkdir -p "$STATE_DIR/emit-history"
_ensure_service_log() { :; }   # the real one wants a service registry
MONITOR_GRAPHQL_DEGRADED_ESCALATE_SECONDS=1800
MONITOR_GRAPHQL_DEGRADED_REMIND_SECONDS=3600
rm -f "$STATE_DIR/graphql-degraded-issue_comments"
# Two failures far enough apart to cross the escalate window.
real_gen=$(_graphql_note_failure issue_comments total)
printf 'first=%s\ncount=2\nannounced=0\n' "$(( $(date +%s) - 2000 ))" \
    > "$STATE_DIR/graphql-degraded-issue_comments"
real_gen=$(_graphql_note_failure issue_comments total)
if [[ -n "$real_gen" ]] && grep -q '^watcher_alert=' <<<"$real_gen"; then
    pass "generator produced a real alert block to test against"
    printf '%s\n' "$real_gen" > "$V2_STAGE_DIR/github_poll.out"
    real_storm=""
    for _i in 1 2 3 4 5; do real_storm+=$(_compose_gh_now)$'\n'; done
    assert_eq "GENERATED alert damped identically (5 fires -> 1 emit)" \
        "$(count_alerts "$real_storm" 'watcher_alert=ingest-degraded')" "1"
    # The damper keys on `surface=`; prove the generator actually emits that
    # token, or the key silently degrades to the kind and every surface
    # shares one stamp.
    assert_contains "  generator emits the surface= token the damper keys on" \
        "$real_gen" "surface=issue_comments"
else
    fail "could not drive the real generator (got: ${real_gen:0:80})"
fi
unset -f _ensure_service_log

echo '=== (5c) #966 + follow-up: ONE delivery per generator EDGE across a whole outage ==='
# THE COMPOSITION THIS WHOLE CHANGE TURNS ON. `#966` has two halves and a fix
# for one can deepen the other: a damper tight enough to collapse the storm
# would, if it keyed on anything coarser than content, also swallow the
# still-degraded restatements and leave the operator with one alert at minute
# zero and silence through a multi-hour outage. Silence is NOT neutral, because
# a real recovery DOES emit `ingest-recovered` — so quiet reads as resolved.
#
# Section (5b) proves replays collapse. This proves restatements survive. The
# property is the conjunction, and it is the one an operator actually
# experiences: across a simulated outage the emit stream must carry EXACTLY ONE
# delivery per generator EDGE — escalate, restate, recover — no matter how many
# times the pipeline re-reads the staging file in between.
rm -rf "$alert_hist" "$STATE_DIR/emit-history" "$STATE_DIR/graphql-degraded-issue_comments"
mkdir -p "$STATE_DIR/emit-history"
_ensure_service_log() { :; }
SIM_NOW=1785000000
# Shim the clock for BOTH sides at once: the generator's `held_s` and the
# damper's cooldown must advance on the same simulated timeline, or the test
# would prove the two agree only about real time.
date() {
    if [[ "${1:-}" == "+%s" ]]; then printf '%s' "$SIM_NOW"; return 0; fi
    command date "$@"
}
MONITOR_GRAPHQL_DEGRADED_ESCALATE_SECONDS=1800
unset MONITOR_GRAPHQL_DEGRADED_REMIND_SECONDS   # exercise the SHIPPED default
unset MONITOR_ALERT_EMIT_COOLDOWN_SECONDS       # ditto

# Read the staged file the way `comment_surface` does — repeatedly, without
# consuming it. Echoes how many alert blocks were actually DELIVERED.
deliver() {  # <n_fires>
    local n="$1" i acc=""
    for (( i = 0; i < n; i++ )); do acc+=$(_compose_gh_now)$'\n'; done
    count_alerts "$acc" 'watcher_alert='
}

# Edge 1 — escalation. Seed a `first` already past the escalate window.
printf 'first=%s\ncount=3\nannounced=0\n' "$(( SIM_NOW - 2000 ))" \
    > "$STATE_DIR/graphql-degraded-issue_comments"
edge1=$(_graphql_note_failure issue_comments total)
printf '%s\n' "$edge1" > "$V2_STAGE_DIR/github_poll.out"
assert_eq "edge 1 (escalate): 4 fires deliver it ONCE" "$(deliver 4)" "1"

# Edge 2 — restatement, two polls later, while the condition still holds.
SIM_NOW=$(( SIM_NOW + 1200 ))
edge2=$(_graphql_note_failure issue_comments total)
if [[ -n "$edge2" ]]; then
    pass "edge 2 (restate): the generator re-nagged while still degraded"
    printf '%s\n' "$edge2" > "$V2_STAGE_DIR/github_poll.out"
    assert_eq "edge 2 (restate): 4 more fires deliver it ONCE" "$(deliver 4)" "1"
    # The damper keys on (kind, content). Identical kind — so the ONLY reason
    # this restatement gets through is that `held_s` moved. Assert the thing
    # the pass depends on, or a future frozen-held_s regression turns this
    # section green while silencing the heartbeat.
    # `[[ =~ ]]` rather than `grep … | head -1`: this file runs under
    # `set -uo pipefail`, and `head` closes the pipe early, so the writer takes
    # EPIPE and the pipeline rc goes non-zero. Harmless where the status is
    # discarded, but `test-early-exit-reader-manifest.sh` tracks every such
    # site as a population precisely because the next edit might consume it
    # (`#622`). Not adding to that population is cheaper than justifying an
    # addition to it — and BASH_REMATCH is what `_alert_cooldown_flush` uses.
    h1=""; h2=""
    [[ "$edge1" =~ held_s=([0-9]+) ]] && h1="${BASH_REMATCH[1]}"
    [[ "$edge2" =~ held_s=([0-9]+) ]] && h2="${BASH_REMATCH[1]}"
    assert_eq "  restatement carries a LIVE held_s (${h1:-?} -> ${h2:-?})" \
        "$(( ${h2:-0} > ${h1:-0} ? 1 : 0 ))" "1"
else
    fail "edge 2: generator stayed silent while still degraded (the #966 silent half)"
fi

# Edge 3 — recovery. Different KIND, so it must not wait out any hold.
SIM_NOW=$(( SIM_NOW + 600 ))
edge3=$(_graphql_note_success issue_comments)
printf '%s\n' "$edge3" > "$V2_STAGE_DIR/github_poll.out"
assert_eq "edge 3 (recover): 3 fires deliver it ONCE" "$(deliver 3)" "1"
assert_contains "  and it is the recovery, not a stale degraded repeat" \
    "$edge3" "watcher_alert=ingest-recovered"

unset -f date _ensure_service_log

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
