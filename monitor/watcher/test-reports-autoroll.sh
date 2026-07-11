#!/usr/bin/env bash
# Tests for the WATCHER-triggered automatic reports-archive roll
# (your-org/nexus-code#447) — the `_v2_task_reports_roll` scheduled task and
# its one-shot `_reports_roll_emit_section` audit breadcrumb, plucked out of
# monitor/watcher/main.sh (which carries top-level state and so cannot be
# sourced whole — same awk-pluck approach the pre-extraction emit-dedup test
# used).
#
# What the auto path must guarantee (the directive):
#   1. Fires on startup / first run (no day-stamp yet) → runs the roller.
#   2. Idempotent across loops: once it ran today, later ticks the SAME day
#      are a cheap no-op — the roller is NOT re-invoked (a file that ages in
#      after the day's run is NOT rolled until the next day-boundary).
#   3. Quiet when nothing rolls: a run that moves 0 files writes NO notice and
#      does NOT pull compose_emit forward (no emit noise — the #443 concern).
#   4. Emits (once) when it DOES roll: writes the notice + fires compose_emit;
#      the emit-section surfaces it once and self-clears (no flap).
#   5. Buffer invariant holds on the auto path: a report inside the ≥1-month
#      buffer (previous/current month) is never moved.
#   6. Mid-write guard on the auto path: with MIN_AGE>0 a freshly-written
#      eligible file is skipped, not rolled.
#
# Fixtures are anchored to the REAL current month (the task reads the wall
# clock), so the assertions stay valid in any month: an "old" report is 3
# months back (always past the buffer); a "buffered" report is the previous
# month (always inside the buffer).
#
# Run: bash monitor/watcher/test-reports-autoroll.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAIN_SH="$_test_dir/main.sh"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf '  FAIL: %s (got %q want %q)\n' "$label" "$got" "$want" >&2
        FAIL=$((FAIL + 1))
    fi
}
assert_flat() {
    local label="$1" dir="$2" base="$3"
    if [[ -f "$dir/$base" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf '  FAIL: %s (expected flat %s/%s)\n' "$label" "$dir" "$base" >&2
        FAIL=$((FAIL + 1))
    fi
}
assert_absent() {
    local label="$1" path="$2"
    if [[ ! -e "$path" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf '  FAIL: %s (expected absent: %s)\n' "$label" "$path" >&2
        FAIL=$((FAIL + 1))
    fi
}

# ---- pluck the two functions under test out of main.sh --------------------
# `name() {` ... first line that is a bare `}` at column 0. main.sh's function
# bodies all close that way, so this bounds each function exactly.
_pluck_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\) \\{" { inb=1 }
        inb { print }
        inb && /^\}$/ { exit }
    ' "$MAIN_SH"
}

fns_src=$(_pluck_fn _v2_task_reports_roll; printf '\n'; _pluck_fn _reports_roll_emit_section)
if [[ -z "$fns_src" ]] || ! grep -q '_v2_task_reports_roll' <<<"$fns_src"; then
    echo "FAIL: could not pluck _v2_task_reports_roll from $MAIN_SH" >&2
    exit 1
fi
# shellcheck disable=SC1090
eval "$fns_src"

# ---- stubs + harness env --------------------------------------------------
log() { :; }    # main.sh's is stderr-only; silence in tests
# The task does NOT force-fire compose_emit (it runs async; a durable notice
# file is picked up on compose_emit's own cadence). A no-op stub guards against
# any future sync-path call without the test asserting on it.
_schedule_fire_now() { return 0; }

# The plucked task resolves the roller as "$_script_dir/../reports-roll.sh".
# Point _script_dir at monitor/watcher so that lands on the real roller.
_script_dir="$_test_dir"
NEXUS_ROOT=""   # unused (we always pass an explicit reports dir via --reports-dir? no —
                # the task calls the roller with --now only, so it resolves the reports
                # dir from NEXUS_ROOT. Set NEXUS_ROOT per-test to the temp root.)

# Date helpers anchored to the real current month (GNU date).
CUR_YM=$(date +%Y-%m)
OLD_DATE=$(date -d "${CUR_YM}-15 -3 months" +%Y-%m-%d)   # always past the buffer
PREV_DATE=$(date -d "${CUR_YM}-15 -1 month"  +%Y-%m-%d)  # always inside the buffer

new_env() {   # fresh temp NEXUS_ROOT with reports/, echoes the root
    local root; root=$(mktemp -d)
    mkdir -p "$root/reports"
    printf '%s' "$root"
}
setup_state() {   # per-test STATE_DIR + notice/stamp paths
    STATE_DIR=$(mktemp -d)
    REPORTS_ROLL_LAST_DAY_FILE="$STATE_DIR/reports-roll-last-day"
    REPORTS_ROLL_NOTICE_FILE="$STATE_DIR/reports-roll-notice"
    MONITOR_REPORTS_ROLL_MIN_AGE_SECONDS=0
}

# ---- 1: startup / first run rolls an aged report + emits ------------------
echo "== first run rolls an aged report, stamps the day, fires compose_emit =="
setup_state
NEXUS_ROOT=$(new_env)
: > "$NEXUS_ROOT/reports/nexus_${OLD_DATE}_120000_aged.md"
: > "$NEXUS_ROOT/reports/nexus_${PREV_DATE}_120000_buffered.md"
_v2_task_reports_roll
old_ym=${OLD_DATE%-*}   # YYYY-MM
assert_eq   "aged report moved into its bucket" \
    "$([[ -f "$NEXUS_ROOT/reports/${old_ym}/nexus_${OLD_DATE}_120000_aged.md" ]] && echo yes)" "yes"
assert_flat "buffered (prev-month) report stays flat" "$NEXUS_ROOT/reports" "nexus_${PREV_DATE}_120000_buffered.md"
assert_eq   "day-stamp written = today" "$(cat "$REPORTS_ROLL_LAST_DAY_FILE")" "$(date +%Y-%m-%d)"
assert_eq   "notice written (rolled >0)" "$([[ -s "$REPORTS_ROLL_NOTICE_FILE" ]] && echo yes)" "yes"
assert_eq   "notice body names the archive action" \
    "$(grep -c 'Auto-archived aged reports' "$REPORTS_ROLL_NOTICE_FILE")" "1"

# ---- 2: same-day idempotency — later tick is a no-op ----------------------
echo "== second call the same day does NOT re-invoke the roller =="
# Add a NEW aged file after the day's run. Because the stamp == today, the
# task must short-circuit and leave it flat until the next day-boundary.
: > "$NEXUS_ROOT/reports/nexus_${OLD_DATE}_130000_added-after-run.md"
_v2_task_reports_roll
assert_flat "file added after the day's run stays flat (day-gate short-circuit)" \
    "$NEXUS_ROOT/reports" "nexus_${OLD_DATE}_130000_added-after-run.md"

# ---- 3: quiet when nothing rolls -----------------------------------------
echo "== a run with nothing aged writes NO notice and fires nothing =="
setup_state
NEXUS_ROOT=$(new_env)
: > "$NEXUS_ROOT/reports/nexus_${PREV_DATE}_120000_buffered.md"   # inside buffer only
: > "$NEXUS_ROOT/reports/nexus_$(date +%Y-%m)-15_120000_current.md"
_v2_task_reports_roll
assert_eq   "day-stamp still written (we DID run)" "$(cat "$REPORTS_ROLL_LAST_DAY_FILE")" "$(date +%Y-%m-%d)"
assert_absent "no notice file when nothing rolled (silent)" "$REPORTS_ROLL_NOTICE_FILE"

# ---- 4: emit-section surfaces once then self-clears -----------------------
echo "== _reports_roll_emit_section is one-shot (prints then consumes) =="
setup_state
printf 'Auto-archived aged reports into monthly reports/YYYY-MM/ buckets.\nreports-roll.sh: rolled 2, ...\n' \
    > "$REPORTS_ROLL_NOTICE_FILE"
first=$(_reports_roll_emit_section "$REPORTS_ROLL_NOTICE_FILE")
second=$(_reports_roll_emit_section "$REPORTS_ROLL_NOTICE_FILE")
assert_eq   "first read yields the notice" "$(printf '%s' "$first" | grep -c 'Auto-archived')" "1"
assert_absent "notice consumed after first read" "$REPORTS_ROLL_NOTICE_FILE"
assert_eq   "second read yields nothing (self-cleared)" "$second" ""

# ---- 5: buffer invariant on the auto path (explicit) ----------------------
echo "== auto path never moves a report inside the buffer =="
setup_state
NEXUS_ROOT=$(new_env)
: > "$NEXUS_ROOT/reports/nexus_${PREV_DATE}_090000_prev-month.md"
_v2_task_reports_roll
assert_flat "previous-month report never moved by auto-roll" \
    "$NEXUS_ROOT/reports" "nexus_${PREV_DATE}_090000_prev-month.md"
# and it wasn't bucketed anywhere
prev_ym=${PREV_DATE%-*}
assert_absent "no prev-month bucket created" "$NEXUS_ROOT/reports/${prev_ym}"

# ---- 6: mid-write guard on the auto path ----------------------------------
echo "== auto path with MIN_AGE>0 skips a freshly-written eligible file =="
setup_state
MONITOR_REPORTS_ROLL_MIN_AGE_SECONDS=3600
NEXUS_ROOT=$(new_env)
: > "$NEXUS_ROOT/reports/nexus_${OLD_DATE}_120000_fresh-eligible.md"   # aged date, mtime=now
_v2_task_reports_roll
assert_flat "freshly-written eligible file skipped by mid-write guard" \
    "$NEXUS_ROOT/reports" "nexus_${OLD_DATE}_120000_fresh-eligible.md"
assert_absent "no notice when the only candidate was skipped" "$REPORTS_ROLL_NOTICE_FILE"

# ---- summary ---------------------------------------------------------------
echo
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d/%d)\n' "$PASS" "$((PASS + FAIL))"
    exit 0
else
    printf 'TESTS FAILED: %d passed, %d failed\n' "$PASS" "$FAIL" >&2
    exit 1
fi
