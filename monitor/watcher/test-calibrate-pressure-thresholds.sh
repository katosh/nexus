#!/usr/bin/env bash
# Unit tests for monitor/calibrate-pressure-thresholds.sh
# (your-org/nexus-code#79; #94 segment-count regression coverage).
#
# Run: bash monitor/watcher/test-calibrate-pressure-thresholds.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: build synthetic prelude diffs under a temp dir, run the
# script with --diffs-dir pointing at it, assert on stdout and exit
# code. Fixture prelude lines come from sourcing `_idle_probe.sh` and
# running the real `render_idle_prelude` function with stubbed helpers
# — so the parser is exercised against whatever format the watcher
# currently emits. Hand-coded preludes are intentionally avoided: the
# silent-drop bug in issue #94 went unnoticed because the test fixture
# was a 5-segment string while production emitted 7 segments. Sourcing
# the live emitter prevents recurrence.
#
# Covers:
#   - empty-archive path (exit 0, "samples: 0" + deferred-analysis note)
#   - parses prelude lines, drops non-prelude diffs
#   - percentile math (R-7 linear interpolation) on a known fixture
#   - drift verdict (REVISE vs OK) per --drift-delta
#   - --since / --until lexicographic filename filter
#   - --raw emits TSV with header (includes the new axes)
#   - missing diffs dir → exit 3
#   - bad --since / --drift-delta → exit 2
#   - 7-segment prelude (issue #94 regression) round-trips through
#     the real `render_idle_prelude` and parses without drops
#   - over-limit + awaiting-input axes appear in distribution rows
#   - --fail-on-zero-rows exits 4 on empty archive

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$(cd "$_test_dir/.." && pwd)/calibrate-pressure-thresholds.sh"
PROBE="$_test_dir/_idle_probe.sh"

if [[ ! -x "$SCRIPT" ]]; then
    printf 'FAIL: calibration script not executable at %s\n' "$SCRIPT" >&2
    exit 1
fi
if [[ ! -f "$PROBE" ]]; then
    printf 'FAIL: probe source not found at %s\n' "$PROBE" >&2
    exit 1
fi

WORK=$(mktemp -d -t nexus-calibrate-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---- prelude generator ---------------------------------------------------
#
# Spawn a subshell that sources the live _idle_probe.sh, overrides the
# helpers render_idle_prelude depends on, then calls the real function.
# The result is the actual format the watcher would emit for the
# requested per-axis counts. Args: busy idle retained idle-too-long
# pane-absent over-limit awaiting-input.
#
# Mocks:
#   _idle_list_worker_windows  — emits `busy+idle+retained+idle-too-long+
#       pane-absent+over-limit` worker rows (the prelude derives
#       n_busy = total_workers - n_idle_total, so the total must include
#       every classified bucket plus the desired busy count)
#   list_really_idle_workers   — emits one row per non-busy bucket with
#       the correct wrap-up class so render_idle_prelude's per-class
#       counters tally exactly
#   _notifications_*           — stub out the awaiting-input pipeline
#       and return the requested count
gen_prelude_line() {
    # Positional args (post-#183 8-axis prelude): busy idle retained
    # idle-too-long pane-absent over-limit orphan-async awaiting-input.
    # The orphan-async slot defaults to 0 so legacy 7-arg callers
    # exercise the same 8-segment prelude with `0 orphan-async`.
    local _busy="$1" _idle="$2" _ret="$3" _itl="$4" _abs="$5" _ovr="$6"
    local _oa _awa
    if (( $# >= 8 )); then
        _oa="$7"; _awa="$8"
    else
        _oa=0; _awa="$7"
    fi
    local _st
    _st=$(mktemp -d -t nexus-prelude-XXXXXX)
    bash -c '
        set -uo pipefail
        STATE_DIR='"$_st"'
        export STATE_DIR
        # Source the live probe to pull in render_idle_prelude.
        source '"$PROBE"' >/dev/null 2>&1
        _idle_list_worker_windows() {
            local n=$(( '"$_busy"' + '"$_idle"' + '"$_ret"' \
                        + '"$_itl"' + '"$_abs"' + '"$_ovr"' \
                        + '"$_oa"' ))
            local i
            for (( i = 0; i < n; i++ )); do printf "w%d\t0\t0\n" "$i"; done
        }
        list_really_idle_workers() {
            local i=0 j
            for (( j = 0; j < '"$_idle"'; j++, i++ )); do printf "w%d\tno-wrap-up\t0\t\n"   "$i"; done
            for (( j = 0; j < '"$_ret"';  j++, i++ )); do printf "w%d\tretained\t0\t\n"     "$i"; done
            for (( j = 0; j < '"$_itl"';  j++, i++ )); do printf "w%d\tidle-too-long\t0\t\n" "$i"; done
            for (( j = 0; j < '"$_abs"';  j++, i++ )); do printf "w%d\tpane-absent\t0\t\n"   "$i"; done
            for (( j = 0; j < '"$_ovr"';  j++, i++ )); do printf "w%d\tover-limit\t0\t\n"    "$i"; done
            for (( j = 0; j < '"$_oa"';   j++, i++ )); do printf "w%d\tidle-orphan-async\t0\t\n" "$i"; done
        }
        _notifications_rotate_if_oversized() { :; }
        _notifications_stamp_path() { printf "%s/last-prelude.ts" "$STATE_DIR"; }
        _notifications_count_distinct_since() { printf "%s" '"$_awa"'; }
        render_idle_prelude
    '
    local rc=$?
    rm -rf "$_st"
    return "$rc"
}

# Write a synthetic prelude diff at $1 with the seven axis values
# given as $2..$8. The prelude body comes from gen_prelude_line so it
# tracks whatever shape _idle_probe.sh currently emits.
write_prelude() {
    local path="$1"; shift
    local line
    line=$(gen_prelude_line "$@")
    {
        echo '=== nexus state changed at synthetic ==='
        printf 'workspace: %s\n' "$line"
        echo '--- rest of body irrelevant ---'
    } > "$path"
}

# Sanity: gen_prelude_line must produce a non-empty string and contain
# all seven labelled axes. If this fails every downstream test that
# depends on a real prelude line silently writes empty diffs and the
# assertions get murky — fail fast here instead.
echo '=== prelude generator self-check ==='
sample=$(gen_prelude_line 2 1 1 1 1 1 1)
assert_contains 'self-check: prelude has busy'           "$sample" 'busy'
assert_contains 'self-check: prelude has idle '          "$sample" 'idle '
assert_contains 'self-check: prelude has retained'       "$sample" 'retained'
assert_contains 'self-check: prelude has idle-too-long'  "$sample" 'idle-too-long'
assert_contains 'self-check: prelude has pane-absent'    "$sample" 'pane-absent'
assert_contains 'self-check: prelude has over-limit'     "$sample" 'over-limit'
assert_contains 'self-check: prelude has awaiting-input' "$sample" 'awaiting-input'
# Issue #94 root: the prelude is `|`-separated segments. Issue #183
# widened it to 8 (added `N orphan-async`); the stall-detection work
# widened it to 9 (added `N interrupted`); the worker-lifecycle fix
# widened it to 10 (added `N parked-skeptic`, excluding parked-awaiting-
# skeptic workers from the busy residue). Anything fewer means a future
# axis was dropped or the generator misfired; either way the test below
# would silently degrade.
seg_count=$(awk -F'|' '{print NF}' <<<"$sample")
assert_eq 'self-check: prelude has 10 segments' "$seg_count" '10'
assert_contains 'self-check: prelude has orphan-async'   "$sample" 'orphan-async'
assert_contains 'self-check: prelude has interrupted'    "$sample" 'interrupted'
assert_contains 'self-check: prelude has parked-skeptic' "$sample" 'parked-skeptic'

# ---- Test 1: empty archive ----
echo
echo '=== empty archive ==='
EMPTY="$WORK/empty"
mkdir -p "$EMPTY"
out=$("$SCRIPT" --diffs-dir "$EMPTY" 2>&1)
rc=$?
assert_eq      'empty: exit 0' "$rc" 0
assert_contains 'empty: samples: 0' "$out" 'samples: 0'
assert_contains 'empty: deferred-analysis note' "$out" 'meaningful after'

# ---- Test 2: non-prelude diffs are skipped ----
echo
echo '=== non-prelude diffs skipped ==='
MIXED="$WORK/mixed"
mkdir -p "$MIXED"
# Five files, three with a prelude, two without.
write_prelude "$MIXED/2026-05-15_01-00-00_aaa.md" 1 0 0 0 0 0 0
write_prelude "$MIXED/2026-05-15_02-00-00_bbb.md" 2 0 0 0 0 0 0
cat >"$MIXED/2026-05-15_03-00-00_ccc.md" <<'EOF'
=== nexus state changed ===
no prelude here
EOF
write_prelude "$MIXED/2026-05-15_04-00-00_ddd.md" 3 0 0 0 0 0 0
cat >"$MIXED/2026-05-15_05-00-00_eee.md" <<'EOF'
=== nexus state changed ===
also no prelude
EOF
out=$("$SCRIPT" --diffs-dir "$MIXED" 2>&1)
rc=$?
assert_eq       'mixed: exit 0' "$rc" 0
assert_contains 'mixed: samples=3' "$out" 'samples: 3'

# ---- Test 3: percentile math on known fixture ----
echo
echo '=== percentile math ==='
KNOWN="$WORK/known"
mkdir -p "$KNOWN"
# busy = 1..20 → expected p50=11, p75=15, p90=18 (R-7 linear interp,
# rounded to nearest). The script's own validated arithmetic.
for i in $(seq 1 20); do
    fname=$(printf '2026-05-15_%02d-00-00_a.md' "$i")
    write_prelude "$KNOWN/$fname" "$i" 0 0 0 0 0 0
done
out=$("$SCRIPT" --diffs-dir "$KNOWN" 2>&1)
rc=$?
assert_eq 'known: exit 0' "$rc" 0
# Pull the "busy" row from the distribution table. Format:
#   "  busy             min p10 p25 p50 p75 p90 p95 max  mean"
busy_row=$(awk '/^  busy / {print; exit}' <<<"$out")
read -r _ p_min p_p10 p_p25 p_p50 p_p75 p_p90 p_p95 p_max p_mean <<<"$busy_row"
assert_eq 'known: busy min'  "$p_min"  '1'
assert_eq 'known: busy p50'  "$p_p50"  '11'
assert_eq 'known: busy p75'  "$p_p75"  '15'
assert_eq 'known: busy p90'  "$p_p90"  '18'
assert_eq 'known: busy max'  "$p_max"  '20'
assert_eq 'known: busy mean' "$p_mean" '11'

# Drift verdict: busy_high skill=7 observed_p90=18 → REVISE
assert_contains 'known: busy high → REVISE' "$out" 'busy high floor'
revise_line=$(awk '/busy high floor/ {print}' <<<"$out")
assert_contains 'known: REVISE flagged' "$revise_line" 'REVISE'

# ---- Test 4: low-drift verdict says OK ----
echo
echo '=== low-drift OK verdict ==='
OK_DIR="$WORK/okdrift"
mkdir -p "$OK_DIR"
# Each axis is tuned so all four tier-boundaries land within delta=1
# of the skill threshold (skill busy=3/7, retained=5/10).
#   busy     sorted: 1 1 1 2 2 2 2 3 3 3 3 3 3 4 4 5 5 6 7 8
#                    p75=4, p90=6 → both OK (diff ≤ 1)
#   retained sorted: 1 1 2 2 3 3 3 3 4 4 4 4 5 5 6 7 8 9 10 11
#                    p75=6, p90=9 → both OK (diff ≤ 1)
busy_vals=(1 1 1 2 2 2 2 3 3 3 3 3 3 4 4 5 5 6 7 8)
ret_vals=(1 1 2 2 3 3 3 3 4 4 4 4 5 5 6 7 8 9 10 11)
for i in "${!busy_vals[@]}"; do
    idx=$(( i + 1 ))
    fname=$(printf '2026-05-15_%02d-00-00_a.md' "$idx")
    write_prelude "$OK_DIR/$fname" "${busy_vals[$i]}" 0 "${ret_vals[$i]}" 0 0 0 0
done
out=$("$SCRIPT" --diffs-dir "$OK_DIR" --drift-delta 2 2>&1)
rc=$?
assert_eq 'ok: exit 0' "$rc" 0
busy_low=$(awk '/busy moderate floor/ {print; exit}' <<<"$out")
busy_high=$(awk '/busy high floor/ {print; exit}' <<<"$out")
assert_contains 'ok: busy moderate → OK' "$busy_low" 'OK'
assert_contains 'ok: busy high → OK'     "$busy_high" 'OK'
assert_contains 'ok: final no-revision blurb' "$out" 'No skill revision indicated'

# ---- Test 5: --since / --until filter ----
echo
echo '=== --since / --until filter ==='
SPAN="$WORK/span"
mkdir -p "$SPAN"
for i in 1 2 3; do
    write_prelude "$SPAN/2026-05-10_0${i}-00-00_old.md" $((i * 10)) 0 0 0 0 0 0
done
for i in 1 2 3; do
    write_prelude "$SPAN/2026-05-20_0${i}-00-00_new.md" $((i * 100)) 0 0 0 0 0 0
done
out_since=$("$SCRIPT" --diffs-dir "$SPAN" --since 2026-05-20 2>&1)
assert_contains 'since: samples=3'   "$out_since" 'samples: 3'
# The new-file busy values are 100, 200, 300 → min = 100.
busy_row=$(awk '/^  busy / {print; exit}' <<<"$out_since")
read -r _ p_min _ <<<"$busy_row"
assert_eq      'since: only new rows kept' "$p_min" '100'

out_until=$("$SCRIPT" --diffs-dir "$SPAN" --until 2026-05-10 2>&1)
assert_contains 'until: samples=3' "$out_until" 'samples: 3'
busy_row=$(awk '/^  busy / {print; exit}' <<<"$out_until")
read -r _ p_min _ _ _ _ _ _ p_max _ <<<"$busy_row"
assert_eq 'until: only old rows kept (min)' "$p_min" '10'
assert_eq 'until: only old rows kept (max)' "$p_max" '30'

# ---- Test 6: --raw TSV ----
echo
echo '=== --raw TSV ==='
out_raw=$("$SCRIPT" --diffs-dir "$KNOWN" --raw 2>&1)
rc=$?
assert_eq      'raw: exit 0' "$rc" 0
header=$(printf '%s\n' "$out_raw" | head -1)
assert_eq      'raw: header (post-#94 7-axis)' "$header" \
    $'busy\tidle\tretained\tidle-too-long\tpane-absent\tover-limit\tawaiting-input\tfile'
data_rows=$(printf '%s\n' "$out_raw" | tail -n +2 | wc -l)
data_rows=${data_rows// /}
assert_eq      'raw: 20 data rows' "$data_rows" '20'

# ---- Test 7: missing diffs dir ----
echo
echo '=== missing diffs dir ==='
"$SCRIPT" --diffs-dir "$WORK/does-not-exist" >/dev/null 2>"$WORK/err"
rc=$?
assert_eq      'missing: exit 3' "$rc" 3
err=$(cat "$WORK/err")
assert_contains 'missing: stderr explains' "$err" 'does not exist'

# ---- Test 8: bad usage ----
echo
echo '=== bad usage ==='
"$SCRIPT" --diffs-dir "$EMPTY" --since not-a-date >/dev/null 2>"$WORK/err"
rc=$?
# --diffs-dir pin: without it the script's default DIFFS_DIR resolver
# falls back to `<script-dir>/.state/diffs`, which happens to exist on
# an operator dev box (real watcher data) but not in a fresh CI
# checkout. Missing dir → exit 3, preempting the --since YYYY-MM-DD
# validation we actually want to assert (exit 2).
assert_eq 'bad --since: exit 2' "$rc" 2

"$SCRIPT" --drift-delta -1 --diffs-dir "$EMPTY" >/dev/null 2>"$WORK/err"
rc=$?
assert_eq 'bad --drift-delta: exit 2' "$rc" 2

# ---- Test 9: issue #94 regression — 7-axis prelude parses ----
#
# The original bug: `(( ${#parts[@]} == 5 ))` silently dropped every
# row whose prelude had grown to 6 segments (#76 awaiting-input) or
# 7 segments (#90 over-limit). Sourcing the real `render_idle_prelude`
# above means the fixture lines are whatever shape the watcher emits
# today; this test asserts at least one row parses, the totals match
# the per-axis values requested, and both new axes are first-class in
# the distribution table.
echo
echo '=== issue #94: 7-axis prelude parses, new axes surface ==='
SEVEN="$WORK/seven"
mkdir -p "$SEVEN"
# busy idle retained idle-too-long pane-absent over-limit awaiting-input
write_prelude "$SEVEN/2026-05-20_01-00-00_a.md" 4 2 1 0 0 3 5
write_prelude "$SEVEN/2026-05-20_02-00-00_a.md" 6 1 0 1 0 2 7
write_prelude "$SEVEN/2026-05-20_03-00-00_a.md" 5 3 1 0 1 1 4
out=$("$SCRIPT" --diffs-dir "$SEVEN" 2>&1)
rc=$?
assert_eq        'seven: exit 0'                              "$rc"  0
assert_contains  'seven: samples=3 (issue #94 regression)'    "$out" 'samples: 3'
assert_contains  'seven: over-limit row present in dist'      "$out" 'over-limit'
assert_contains  'seven: awaiting-input row present in dist'  "$out" 'awaiting-input'
# --raw should expose all 7 numeric columns + filename.
raw_out=$("$SCRIPT" --diffs-dir "$SEVEN" --raw 2>&1)
row=$(printf '%s\n' "$raw_out" | grep '_01-00-00_a.md$' | head -1)
read -r r_busy r_idle r_ret r_itl r_abs r_ovr r_awa _file <<<"$(printf '%s' "$row" | tr '\t' ' ')"
assert_eq 'seven: row1 busy'           "$r_busy" '4'
assert_eq 'seven: row1 idle'           "$r_idle" '2'
assert_eq 'seven: row1 retained'       "$r_ret"  '1'
assert_eq 'seven: row1 idle-too-long'  "$r_itl"  '0'
assert_eq 'seven: row1 pane-absent'    "$r_abs"  '0'
assert_eq 'seven: row1 over-limit'     "$r_ovr"  '3'
assert_eq 'seven: row1 awaiting-input' "$r_awa"  '5'
# Distribution row for over-limit must have non-zero max.
overlimit_row=$(awk '/^  over-limit / {print; exit}' <<<"$out")
read -r _ ol_min _ _ _ _ _ _ ol_max _ <<<"$overlimit_row"
assert_eq 'seven: over-limit max=3' "$ol_max" '3'
awaiting_row=$(awk '/^  awaiting-input / {print; exit}' <<<"$out")
read -r _ aw_min _ _ _ _ _ _ aw_max _ <<<"$awaiting_row"
assert_eq 'seven: awaiting-input max=7' "$aw_max" '7'

# ---- Test 10: --fail-on-zero-rows ----
echo
echo '=== --fail-on-zero-rows ==='
# Empty archive: default exits 0, flag exits 4.
"$SCRIPT" --diffs-dir "$EMPTY" >/dev/null 2>&1
rc=$?
assert_eq 'fail-on-zero: default exit 0' "$rc" 0
"$SCRIPT" --diffs-dir "$EMPTY" --fail-on-zero-rows >/dev/null 2>"$WORK/err"
rc=$?
assert_eq      'fail-on-zero: flag → exit 4' "$rc" 4
err=$(cat "$WORK/err")
assert_contains 'fail-on-zero: stderr explains' "$err" 'zero rows parsed'

# Archive with only malformed preludes also exits 4.
GARBAGE="$WORK/garbage"
mkdir -p "$GARBAGE"
cat >"$GARBAGE/2026-05-20_01-00-00_a.md" <<'EOF'
=== nexus state changed ===
workspace: not a parseable prelude
EOF
"$SCRIPT" --diffs-dir "$GARBAGE" --fail-on-zero-rows >/dev/null 2>"$WORK/err"
rc=$?
assert_eq 'fail-on-zero: garbage → exit 4' "$rc" 4

# Healthy archive: flag is a no-op.
"$SCRIPT" --diffs-dir "$SEVEN" --fail-on-zero-rows >/dev/null 2>&1
rc=$?
assert_eq 'fail-on-zero: healthy → exit 0' "$rc" 0

# --raw under --fail-on-zero-rows also exits 4 on empty.
"$SCRIPT" --diffs-dir "$EMPTY" --raw --fail-on-zero-rows >/dev/null 2>&1
rc=$?
assert_eq 'fail-on-zero: --raw empty → exit 4' "$rc" 4

th_summary_and_exit
