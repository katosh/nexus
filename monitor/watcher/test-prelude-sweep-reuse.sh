#!/usr/bin/env bash
# test-prelude-sweep-reuse.sh — the compose-time workspace prelude must reuse
# the recorder's newest complete sweep instead of re-forking pane-state.sh for
# every recording older than the pane-cache TTL (your-org/nexus-code#1698).
#
# THE MEASURED DEFECT. On 2026-09-30 (load 65–105, 18 worker windows) one
# pane-state.sh fork cost 9–40 s WALL for 0.9–5 s CPU, and the recorder sweep
# (`idle_section`) took up to 182 s. The recorder writes windows in order, so
# at any moment about half of its recordings were past the 90 s TTL, and
# `render_idle_prelude` re-forked every one of them serially — against a
# budget of 20 s + 2 s × windows. 32 `compose_report: prelude render TIMED OUT`
# that day, 39 the day before.
#
# WHAT IS PINNED.
#   R1  the render COMPLETES inside the production-default budget on a board
#       whose recordings are stale-by-TTL but belong to a complete sweep, with
#       per-window work stubbed at a cost that makes a serial re-probe blow
#       the budget. Red on base 5dc308cf (timeout, 6 forks), green here.
#   C1–C8  correctness of the reuse: it is served ONLY under the sweep
#       conditions, and a window whose state CHANGED (heartbeat moved to the
#       other activity class after the recording) is RE-PROBED and re-rendered.
#   M1  the recorder marks a sweep complete only after it returns.
#   K1  per-window config knobs are resolved once per sweep, not once per
#       window (the second-largest term in the measured render).
#
# Fork counts, not stopwatches, for C/K; R1 is the one wall-clock arm and its
# margin is wide (stub cost × windows = 48 s against a 32 s budget; the head
# arm forks nothing).
#
# Run: bash monitor/watcher/test-prelude-sweep-reuse.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export NEXUS_ROOT="$WORK/nexus"
export STATE_DIR="$WORK/state"
export NEXUS_STATE_DIR="$STATE_DIR"
mkdir -p "$NEXUS_ROOT/monitor" "$NEXUS_ROOT/config" "$STATE_DIR/heartbeat" "$STATE_DIR/pane-cache"
STUB_BIN="$WORK/bin"; mkdir -p "$STUB_BIN"
FORKS="$WORK/forks"; : > "$FORKS"
SCEN="$WORK/scen"; mkdir -p "$SCEN"
CFG_CALLS="$WORK/cfg-calls"; : > "$CFG_CALLS"
export FORKS SCEN CFG_CALLS

# pane-state.sh stub: one line appended to $FORKS per fork, optional per-fork
# cost ($STUB_SLEEP), and the line a FRESH probe would return, taken from
# $SCEN/<idx> (default: busy).
cat > "$NEXUS_ROOT/monitor/pane-state.sh" <<'STUB'
#!/usr/bin/env bash
idx="${@: -1}"
printf '%s\n' "$idx" >> "$FORKS"
[[ -n "${STUB_SLEEP:-}" ]] && sleep "$STUB_SLEEP"
if [[ -f "$SCEN/$idx" ]]; then cat "$SCEN/$idx"; else printf 'state=busy active=1 window=%s name=w%s\n' "$idx" "$idx"; fi
STUB
chmod +x "$NEXUS_ROOT/monitor/pane-state.sh"

# config/load.sh stub: records the key, prints the default.
cat > "$NEXUS_ROOT/config/load.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$CFG_CALLS"
printf '%s\n' "${2:-}"
STUB
chmod +x "$NEXUS_ROOT/config/load.sh"

# tmux stub: MOCK_TMUX_WINDOWS rows are `name|activity|index`.
cat > "$STUB_BIN/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    list-windows)
        if [[ "${2:-}" == -F && "${3:-}" == '#{window_name}' ]]; then
            printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" | cut -d'|' -f1
        else
            printf '%s\n' "${MOCK_TMUX_WINDOWS:-}"
        fi ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/tmux"
export PATH="$STUB_BIN:$PATH"

export MONITOR_PANE_CACHE_TTL_SECONDS=90
export MONITOR_PRELUDE_DRY_RUN=1
unset MONITOR_PANE_CACHE_MODE MONITOR_PANE_CACHE_DIR MONITOR_PANE_CACHE_SWEEP_REUSE 2>/dev/null || true

# shellcheck source=_pane_cache.sh
source "$_test_dir/_pane_cache.sh"
# shellcheck source=_idle_probe.sh
source "$_test_dir/_idle_probe.sh" 2>/dev/null

forks() { wc -l < "$FORKS" | tr -d ' '; }
NOW=$(date +%s)

# plant_board <n>: n windows w1..wn at index 1..n, each with a BUSY recording
# aged 150 s (past the 90 s TTL), a busy heartbeat OLDER than the recording, and
# a complete sweep that started 200 s ago and ended 20 s ago.
plant_board() {
    local n="$1" i rows=""
    rm -rf "$STATE_DIR/pane-cache" "$STATE_DIR/heartbeat" "$SCEN"
    mkdir -p "$STATE_DIR/pane-cache" "$STATE_DIR/heartbeat" "$SCEN"
    NOW=$(date +%s)
    for (( i=1; i<=n; i++ )); do
        rows+="w${i}|$(( NOW - 1000 ))|${i}"$'\n'
        printf 'state=busy active=1 window=%s name=w%s\n' "$i" "$i" > "$STATE_DIR/pane-cache/$i.line"
        touch -d "@$(( NOW - 150 ))" "$STATE_DIR/pane-cache/$i.line"
        printf '{"state":"busy","last_activity":%s,"window":"w%s"}\n' "$(( NOW - 300 ))" "$i" > "$STATE_DIR/heartbeat/w$i.json"
        touch -d "@$(( NOW - 300 ))" "$STATE_DIR/heartbeat/w$i.json"
    done
    export MOCK_TMUX_WINDOWS="${rows%$'\n'}"
    printf '%s\t%s\n' "$(( NOW - 200 ))" "$(( NOW - 20 ))" > "$STATE_DIR/pane-cache/.sweep"
    : > "$FORKS"
}

# ===========================================================================
echo "=== R1. the render completes within the production-default budget ==="
# Six windows; a fresh probe costs 8 s (chosen: inside the 9–40 s measured
# wall range, small enough to keep the red arm short). Serial re-probe = 48 s.
# Budget = 20 s + 6 × 2 s = 32 s — `_render_budget_seconds` at its defaults.
N=6; BUDGET=$(( 20 + N * 2 ))
plant_board "$N"
_r1_out="$WORK/r1.out"
STUB_SLEEP=8 timeout "$BUDGET" bash -c '
    source "$1/_pane_cache.sh"; source "$1/_idle_probe.sh" 2>/dev/null
    render_idle_prelude' _ "$_test_dir" > "$_r1_out" 2>/dev/null
_r1_rc=$?
assert_eq "render_idle_prelude finished inside ${BUDGET}s (rc 0, not 124)" "$_r1_rc" "0"
assert_eq "…re-probing NO window whose recording belongs to the complete sweep" "$(forks)" "0"
assert_contains "…and the counts are the recordings' (6 busy)" "$(cat "$_r1_out")" "6 busy | 0 idle"

# ===========================================================================
echo "=== C. reuse is served ONLY under the sweep conditions ==="
plant_board 1
export MONITOR_PANE_CACHE_SWEEP_REUSE=1
line=$(_idle_pane_state_line 1 w1)
assert_eq "C1 stale-by-TTL recording from the complete sweep is served" "$line" "state=busy active=1 window=1 name=w1"
assert_eq "C1 …without a fork" "$(forks)" "0"

# C2: the CHANGE signal. The worker's Stop hook fired after the recording
# (heartbeat now idle_prompt, newer than the entry) — the window's state
# changed, so it must be re-probed and re-rendered with the fresh state.
printf 'state=idle active=0 window=1 name=w1\n' > "$SCEN/1"
printf '{"state":"idle_prompt","last_activity":%s,"window":"w1"}\n' "$NOW" > "$STATE_DIR/heartbeat/w1.json"
touch -d "@$(( NOW - 5 ))" "$STATE_DIR/heartbeat/w1.json"
line=$(_idle_pane_state_line 1 w1)
assert_eq "C2 a window whose heartbeat changed class is RE-PROBED" "$(forks)" "1"
assert_eq "C2 …and the fresh state is what is rendered" "$line" "state=idle active=0 window=1 name=w1"
line=$(_idle_pane_state_line 1 w1)
assert_eq "C2 …the re-probe repaired the cache: the next read is served" "$(forks)" "1"
assert_eq "C2 …with the new recording" "$line" "state=idle active=0 window=1 name=w1"

# C3: busy→busy hook traffic (PostToolUse) must NOT invalidate.
plant_board 1
printf '{"state":"busy","last_activity":%s,"window":"w1"}\n' "$NOW" > "$STATE_DIR/heartbeat/w1.json"
_idle_pane_state_line 1 w1 >/dev/null
assert_eq "C3 a newer heartbeat in the SAME class does not force a fork" "$(forks)" "0"

# C4: no heartbeat → the change is unobservable → fail closed (fork).
plant_board 1
rm -f "$STATE_DIR/heartbeat/w1.json"
_idle_pane_state_line 1 w1 >/dev/null
assert_eq "C4 no readable heartbeat → reuse refused (fork)" "$(forks)" "1"

# C5: recorder no longer cycling: last sweep ended 400 s ago after a 180 s run.
plant_board 1
printf '%s\t%s\n' "$(( NOW - 580 ))" "$(( NOW - 400 ))" > "$STATE_DIR/pane-cache/.sweep"
touch -d "@$(( NOW - 150 ))" "$STATE_DIR/pane-cache/1.line"
_idle_pane_state_line 1 w1 >/dev/null
assert_eq "C5 a stalled recorder's sweep does not qualify (fork)" "$(forks)" "1"

# C6: recording OLDER than the complete sweep's start — not from that sweep.
plant_board 1
touch -d "@$(( NOW - 250 ))" "$STATE_DIR/pane-cache/1.line"
_idle_pane_state_line 1 w1 >/dev/null
assert_eq "C6 a recording predating the last complete sweep is refused (fork)" "$(forks)" "1"

# C7: the hard age cap (300 s, chosen) holds even inside a long sweep.
plant_board 1
printf '%s\t%s\n' "$(( NOW - 1000 ))" "$(( NOW - 10 ))" > "$STATE_DIR/pane-cache/.sweep"
touch -d "@$(( NOW - 400 ))" "$STATE_DIR/pane-cache/1.line"
_idle_pane_state_line 1 w1 >/dev/null
assert_eq "C7 a recording past MONITOR_PANE_CACHE_SWEEP_MAX_AGE_SECONDS is refused" "$(forks)" "1"

# C8: consumers that did NOT opt in keep the plain TTL rule.
plant_board 1
unset MONITOR_PANE_CACHE_SWEEP_REUSE
_idle_pane_state_line 1 w1 >/dev/null
assert_eq "C8 without the opt-in a stale-by-TTL recording still forks" "$(forks)" "1"
# …and no .sweep at all means no extension even WITH the opt-in.
plant_board 1
rm -f "$STATE_DIR/pane-cache/.sweep"
MONITOR_PANE_CACHE_SWEEP_REUSE=1 _idle_pane_state_line 1 w1 >/dev/null
assert_eq "C8 with the opt-in but NO completed sweep on record → fork" "$(forks)" "1"

# ===========================================================================
echo "=== C9. END TO END: a changed window is re-rendered in the prelude counts ==="
# Three windows served from the sweep; w2 finished its turn after the sweep
# recorded it (heartbeat idle_prompt, newer). Only w2 is re-probed, and the
# prelude counts it as not-busy.
plant_board 3
printf 'state=idle active=0 window=2 name=w2\n' > "$SCEN/2"
printf '{"state":"idle_prompt","last_activity":%s,"window":"w2"}\n' "$NOW" > "$STATE_DIR/heartbeat/w2.json"
touch -d "@$(( NOW - 5 ))" "$STATE_DIR/heartbeat/w2.json"
# Threshold 0: the first-sight engagement baseline stamps `now`, so any
# positive idle threshold would hold a brand-new fixture window out of the
# idle pool regardless of its pane state.
out=$(MONITOR_IDLE_THRESHOLD_SECONDS=0 render_idle_prelude 2>/dev/null)
assert_eq "C9 exactly the changed window was re-probed" "$(sort -u "$FORKS" | tr '\n' ' ')" "2 "
assert_contains "C9 …and the counts moved: 2 busy, not 3" "$out" "2 busy |"

# ===========================================================================
echo "=== M1. the recorder marks a sweep complete only after it returns ==="
_pluck_fn() {
    awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{" { c=1 } c { print } c && /^\}/ { exit }' "$2"
}
eval "$(_pluck_fn _v2_task_idle_section "$_test_dir/main.sh")"
rm -f "$STATE_DIR/pane-cache/.sweep"
render_idle_section() { [[ -e "$STATE_DIR/pane-cache/.sweep" ]] && echo present > "$WORK/m1.during" || echo absent > "$WORK/m1.during"; }
_m1_before=$(date +%s)
_v2_task_idle_section
IFS=$'\t' read -r _m1_s _m1_e < "$STATE_DIR/pane-cache/.sweep" 2>/dev/null || true
assert_eq "M1 no completion mark exists WHILE the sweep runs" "$(cat "$WORK/m1.during" 2>/dev/null)" "absent"
if [[ "${_m1_s:-}" =~ ^[0-9]+$ && "${_m1_e:-}" =~ ^[0-9]+$ ]] && (( _m1_s >= _m1_before - 1 && _m1_e >= _m1_s )); then
    printf '  PASS: M1 the mark records <start>\\t<end> of the sweep that returned\n'; _th_pass
else
    printf '  FAIL: M1 .sweep after a sweep: start=%s end=%s (want numeric, start ≥ %s, end ≥ start)\n' "${_m1_s:-}" "${_m1_e:-}" "$_m1_before" >&2; _th_fail
fi
unset -f render_idle_section

# ===========================================================================
echo "=== K1. per-window config knobs are resolved once per sweep ==="
plant_board 4
for i in 1 2 3 4; do
    printf 'state=working-background active=0 window=%s name=w%s bg_cpu=10 bg_shells=1 bg_reliable=1\n' "$i" "$i" > "$STATE_DIR/pane-cache/$i.line"
done
: > "$CFG_CALLS"
MONITOR_PANE_CACHE_MODE=read MONITOR_PANE_CACHE_SWEEP_REUSE=1 MONITOR_IDLE_PROBE_READONLY=1 \
    list_really_idle_workers >/dev/null 2>&1
_k_orphan=$(command grep -cxF monitor.background_orphan_grace_seconds "$CFG_CALLS")
_k_ceiling=$(command grep -cxF monitor.background_children_grace_ceiling_seconds "$CFG_CALLS")
# Reachability first: a zero here would mean the branch was never entered and
# the bound below is vacuous.
if (( _k_orphan >= 1 && _k_ceiling >= 1 )); then
    printf '  PASS: K1 the working-background branch was reached (orphan=%s ceiling=%s)\n' "$_k_orphan" "$_k_ceiling"; _th_pass
else
    printf '  FAIL: K1 the knob resolvers were never reached (orphan=%s ceiling=%s) — fixture is not exercising the branch\n' "$_k_orphan" "$_k_ceiling" >&2; _th_fail
fi
assert_eq "K1 orphan-grace resolved ONCE for 4 windows (was once per window)" "$_k_orphan" "1"
assert_eq "K1 children-ceiling resolved ONCE for 4 windows" "$_k_ceiling" "1"
# …and the memo does not leak out of the sweep: a config edit is picked up by
# the NEXT call.
assert_eq "K1 the memo is scoped to the call (no global left behind)" "${MONITOR_BACKGROUND_ORPHAN_GRACE_SECONDS:-unset}" "unset"

# ---- assertion-count guard -------------------------------------------------
_EXPECTED_ASSERTIONS=24
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$_EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
