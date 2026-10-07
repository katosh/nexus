#!/usr/bin/env bash
# test-prelude-render-deadline.sh — the compose-time workspace prelude is
# BOUNDED by its own budget, and degrades inside it with an honest label
# instead of being killed (your-org/nexus-code#1698, reopened).
#
# THE MEASURED DEFECT. #1702 let the prelude reuse the recorder's last sweep,
# which cut how many pane-state.sh forks it made but not what each one costs.
# That cost scales with load: measured read-only on the live board, 1.6–7 s
# per fork at load 25 and 17–40 s at load 90–105, ~83% of a cold render. A
# serial set of such forks has no time bound, and with #1702 deployed the
# render was still killed (`exceeded 38s … rc 124`, 2026-09-30 23:18:53) and
# the emit fell back to a STALE line 709 s old.
#
# WHAT IS PINNED.
#   B   a synthetic board of N = 10, 20, 30 windows whose every recording is
#       unusable and whose every probe costs 5 s (serial: 2.5× the budget) —
#       the render RETURNS inside the production-default budget (20 s + 2 s ×
#       N), counts what it could not probe as `unprobed`, and its counts add
#       up to N. Red on dev 3d022b09 / ec925978 (killed at the budget, rc 124).
#   N   negative / kill-safety: a window whose probe was DEFERRED, TIMED OUT
#       or FAILED is never counted idle, even when a probe would have said
#       idle; a deferred line carries no `state=`; and the authoritative
#       (non-read-only) path never defers, whatever the environment says.
#   P   positive controls: the same idle window IS counted idle when the
#       budget allows its probe; with no budget the line is byte-identical to
#       the pre-#1698 format (no `unprobed` axis).
#
# Wall-clock arms (B) assert against the budget, with the margin stated; the
# rest count forks and read lines.
#
# Run: bash monitor/watcher/test-prelude-render-deadline.sh
# Expected: ALL TESTS PASSED, exit 0. ~2.5 min (B dominates).

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export NEXUS_ROOT="$WORK/nexus"
export STATE_DIR="$WORK/state"
export NEXUS_STATE_DIR="$STATE_DIR"
mkdir -p "$NEXUS_ROOT/monitor" "$NEXUS_ROOT/config" "$STATE_DIR"
STUB_BIN="$WORK/bin"; mkdir -p "$STUB_BIN"
FORKS="$WORK/forks"; : > "$FORKS"
SCEN="$WORK/scen"; mkdir -p "$SCEN"
export FORKS SCEN

# pane-state.sh stub: one line per fork in $FORKS; per-fork cost $STUB_SLEEP
# (or $SCEN/<idx>.sleep); output $SCEN/<idx> (default busy); exit
# $SCEN/<idx>.rc (default 0).
cat > "$NEXUS_ROOT/monitor/pane-state.sh" <<'STUB'
#!/usr/bin/env bash
idx="${@: -1}"
printf '%s\n' "$idx" >> "$FORKS"
s="${STUB_SLEEP:-}"; [[ -f "$SCEN/$idx.sleep" ]] && s=$(cat "$SCEN/$idx.sleep")
[[ -n "$s" ]] && sleep "$s"
if [[ -f "$SCEN/$idx" ]]; then cat "$SCEN/$idx"; else printf 'state=busy active=1 window=%s name=w%s\n' "$idx" "$idx"; fi
[[ -f "$SCEN/$idx.rc" ]] && exit "$(cat "$SCEN/$idx.rc")"
exit 0
STUB
chmod +x "$NEXUS_ROOT/monitor/pane-state.sh"

cat > "$NEXUS_ROOT/config/load.sh" <<'STUB'
#!/usr/bin/env bash
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
unset MONITOR_PANE_CACHE_MODE MONITOR_PANE_CACHE_DIR MONITOR_PANE_CACHE_SWEEP_REUSE \
      MONITOR_RENDER_BUDGET_SECONDS MONITOR_RENDER_PROBE_DEADLINE MONITOR_RENDER_LOOP_DEADLINE \
      MONITOR_RENDER_DEFERRED_FILE MONITOR_IDLE_PROBE_READONLY 2>/dev/null || true

# shellcheck source=_pane_cache.sh
source "$_test_dir/_pane_cache.sh"
# shellcheck source=_idle_probe.sh
source "$_test_dir/_idle_probe.sh" 2>/dev/null

forks() { wc -l < "$FORKS" | tr -d ' '; }
# field <line> <label> — the count of the axis named EXACTLY <label>.
field() { printf '%s\n' "$1" | awk -v l="$2" -F' [|] ' '{ for (i=1;i<=NF;i++) { split($i,a," "); if (a[2]==l) print a[1] } }'; }

# plant_board <n>: n windows w1..wn at index 1..n, NO pane-cache recordings
# (every window must be forked — the recorder-is-dead worst case), each window
# engaged long ago so an idle probe WOULD classify it idle.
plant_board() {
    local n="$1" i rows="" now
    rm -rf "$STATE_DIR" "$SCEN"; mkdir -p "$STATE_DIR/pane-cache" "$STATE_DIR/heartbeat" "$SCEN"
    now=$(date +%s)
    : > "$STATE_DIR/engagement-log.tsv"
    for (( i=1; i<=n; i++ )); do
        rows+="w${i}|$(( now - 5000 ))|${i}"$'\n'
        printf 'w%s\t%s\n' "$i" "$(( now - 5000 ))" >> "$STATE_DIR/engagement-log.tsv"
    done
    export MOCK_TMUX_WINDOWS="${rows%$'\n'}"
    : > "$FORKS"
}

# render_in_budget <budget>: the production pairing — `timeout <budget>` stands
# in for `_run_bounded`, and the render is told the same budget. Sets R_RC,
# R_OUT, R_SECS.
render_in_budget() {
    local b="$1" t0 t1
    t0=$(date +%s)
    R_OUT=$(MONITOR_RENDER_BUDGET_SECONDS="$b" timeout "$b" bash -c '
        source "$1/_pane_cache.sh"; source "$1/_idle_probe.sh" 2>/dev/null
        render_idle_prelude' _ "$_test_dir" 2>/dev/null)
    R_RC=$?
    t1=$(date +%s); R_SECS=$(( t1 - t0 ))
}

# ===========================================================================
for N in 10 20 30; do
    BUDGET=$(( 20 + N * 2 ))   # _render_budget_seconds at its defaults
    echo "=== B${N}. ${N} windows × 5 s probes (serial $(( N * 5 )) s) inside a ${BUDGET} s budget ==="
    plant_board "$N"
    STUB_SLEEP=5 render_in_budget "$BUDGET"
    export -n STUB_SLEEP 2>/dev/null; unset STUB_SLEEP
    assert_eq "B${N} the render RETURNED inside its budget (rc 0, not 124)" "$R_RC" "0"
    if (( R_SECS < BUDGET )); then
        printf '  PASS: B%s elapsed %ss < budget %ss\n' "$N" "$R_SECS" "$BUDGET"; _th_pass
    else
        printf '  FAIL: B%s elapsed %ss >= budget %ss\n' "$N" "$R_SECS" "$BUDGET" >&2; _th_fail
    fi
    _u=$(field "$R_OUT" unprobed); _b=$(field "$R_OUT" busy); _i=$(field "$R_OUT" idle)
    if [[ "$_u" =~ ^[0-9]+$ ]] && (( _u > 0 )); then
        printf '  PASS: B%s the windows it could not afford are labelled unprobed (%s)\n' "$N" "$_u"; _th_pass
    else
        printf '  FAIL: B%s no unprobed count on a board it cannot fully probe: [%s]\n' "$N" "$R_OUT" >&2; _th_fail
    fi
    assert_eq "B${N} busy + idle + unprobed accounts for every window" "$(( ${_b:-0} + ${_i:-0} + ${_u:-0} ))" "$N"
done

# ===========================================================================
echo "=== N. kill-safety: an un-probed window is NEVER counted idle ==="
export STUB_IDLE='state=idle active=0 window=1 name=w1'

echo "--- P1 positive control: with room for its probe, the idle window IS idle"
plant_board 1; printf '%s\n' "$STUB_IDLE" > "$SCEN/1"
render_in_budget 30
assert_contains "P1 idle window counted idle when probed" "$R_OUT" "0 busy | 1 idle"
assert_not_contains "P1 …and nothing is unprobed" "$R_OUT" "unprobed"

echo "--- N1 the probe would say idle but no time is left: deferred, not idle"
plant_board 1; printf '%s\n' "$STUB_IDLE" > "$SCEN/1"
# Budget 5: loop deadline = start+1, probe deadline = start-4 → no slice.
render_in_budget 5
assert_contains "N1 counted unprobed" "$R_OUT" "| 1 unprobed"
assert_contains "N1 …and NOT idle (and not busy)" "$R_OUT" "0 busy | 0 idle"
assert_eq "N1 …without forking a probe it had no time for" "$(forks)" "0"

echo "--- N2 the probe would say idle but is killed by its time slice: not idle"
plant_board 1; printf '%s\n' "$STUB_IDLE" > "$SCEN/1"; echo 60 > "$SCEN/1.sleep"
MONITOR_RENDER_PROBE_RESERVE_SECONDS=5 render_in_budget 20   # slice = 20-4-5 = 11 s
assert_eq "N2 the render still returned (rc 0)" "$R_RC" "0"
assert_contains "N2 counted unprobed" "$R_OUT" "| 1 unprobed"
assert_contains "N2 …and NOT idle" "$R_OUT" "0 busy | 0 idle"

echo "--- N3 a probe that FAILED (no line, rc 3) is not idle"
plant_board 1; : > "$SCEN/1"; echo 3 > "$SCEN/1.rc"
render_in_budget 30
assert_contains "N3 a failed probe is not counted idle" "$R_OUT" "| 0 idle |"
_set=$(MONITOR_IDLE_PROBE_READONLY=1 list_really_idle_workers 2>/dev/null)
assert_not_contains "N3 …and list_really_idle_workers emits no row for it" "$_set" "w1"

echo "--- N4 the deferred line carries no state= key"
_past=$(( $(date +%s) - 100 )); _sink="$WORK/sink"; : > "$_sink"
_line=$(MONITOR_IDLE_PROBE_READONLY=1 MONITOR_RENDER_PROBE_DEADLINE="$_past" \
        MONITOR_RENDER_DEFERRED_FILE="$_sink" _idle_pane_state_line 1 w1)
assert_contains "N4 an expired probe slice yields probe=deferred" "$_line" "probe=deferred"
assert_not_contains "N4 …with NO state= token any consumer could parse" "$_line" "state="

echo "--- N5 the authoritative (non-read-only) path NEVER defers"
plant_board 1; printf '%s\n' "$STUB_IDLE" > "$SCEN/1"
_line=$(MONITOR_RENDER_PROBE_DEADLINE="$_past" MONITOR_RENDER_LOOP_DEADLINE="$_past" \
        MONITOR_RENDER_DEFERRED_FILE="$_sink" _idle_pane_state_line 1 w1)
assert_eq "N5 without READONLY an expired deadline is ignored: the probe runs" "$_line" "$STUB_IDLE"
assert_eq "N5 …and it forked" "$(forks)" "1"

echo "--- P2 no budget: the line has no unprobed axis (pre-#1698 format)"
plant_board 2
_out=$(render_idle_prelude 2>/dev/null)
assert_eq "P2 unbudgeted line is the eleven-axis format" "$_out" \
    "2 busy | 0 idle | 0 retained | 0 idle-too-long | 0 pane-absent | 0 over-limit | 0 orphan-async | 0 interrupted | 0 parked-skeptic | 0 idle-children | 0 awaiting-input"

# ---- assertion-count guard -------------------------------------------------
# No conditional cases: the count is exact. Bump it deliberately; a DROP means
# a case stopped running.
_EXPECTED_ASSERTIONS=27
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$_EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
