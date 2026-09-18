#!/usr/bin/env bash
# Unit tests for two discriminating full-state emit-noise fixes
# (watcher-emit-noise):
#
#   Class 1 — STALE full-state snapshot re-stat. The periodic
#     `--- workspace snapshot ---` is served from the async-staged
#     full_state_snap.out (600s cadence), so a window killed between async
#     renders lingers as a live row (the 2026-07-21 00:37 emit listed two
#     kill-window'd windows as live while its own fresh prelude counted
#     them gone). `_full_state_restat_live_windows` drops rows for windows
#     absent from the current tmux set; non-row lines pass through; an
#     empty live set passes through unchanged.
#
#   Class 2 — change-emit shadow collapse. FULL_STATE_STAMP (the
#     full-state DUE clock) is reset from ANY successful paste, so a
#     change/resurface poll defers the next periodic full-state by
#     full_state_emit_interval instead of letting it fire moments later
#     (the 2026-07-21 00:36 poll → 00:38 poll-full-state double-wake). The
#     genuine timeout HEARTBEAT is governed by the canonical-cache mtime +
#     effective floor, NOT the stamp, so a static workspace's liveness
#     heartbeat is unaffected — proven here by reproducing both predicates.
#
# Run: bash monitor/watcher/test-full-state-emit-noise.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    if [[ -n "$needle" ]] && grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — missing %q\n' "$label" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  FAIL: %s — unexpectedly found %q\n' "$label" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/.state"; mkdir -p "$STATE_DIR"; export STATE_DIR

# tmux stub so the helper's auto-query branch is deterministic (used only
# by the empty-arg path; the tests below pass the live set explicitly, as
# main.sh does).
STUB_DIR="$WORK/bin"; mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    list-windows) printf '%s\n' ${MOCK_TMUX_WINDOWS:-} ;;
    *)            : ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/tmux"
PATH="$STUB_DIR:$PATH"

# shellcheck source=_idle_probe.sh
source "$_test_dir/_idle_probe.sh"

# ======================================================================
# Class 1 — _full_state_restat_live_windows
# ======================================================================
echo '=== Class 1: stale-snapshot re-stat drops dead-window rows ==='

# Reproduce the 2026-07-21 00:38 stale snapshot: two windows
# (pubfork-skills, pubfork-skills-skeptic) were kill-window'd ~00:34 but
# the staged snapshot still lists them. The live set is the corrected
# 5-window set from the 00:51 self-correcting emit.
SNAP="  - palantir-genetrends idle 296311s (state=empty)
  - prox-obsp idle 211768s (state=empty)
  - xiulan-simplify idle 32900s (state=empty)
  - pubfork-skills idle 320s (state=empty)
  - chat idle 14761s (state=empty)
  - pubfork-skills-skeptic parked-awaiting-skeptic (state=empty; skeptic reviewing — exempt from idle/close)
  - palantir-genetrends-skeptic idle 298010s (state=empty)
(full snapshot; transitions only between snapshots)"
LIVE="palantir-genetrends
prox-obsp
xiulan-simplify
chat
palantir-genetrends-skeptic"

out=$(printf '%s' "$SNAP" | _full_state_restat_live_windows "$LIVE")
assert_not_contains "killed pubfork-skills row dropped"          "$out" 'pubfork-skills idle'
assert_not_contains "killed pubfork-skills-skeptic row dropped"  "$out" 'pubfork-skills-skeptic'
assert_contains     "live palantir-genetrends row kept"          "$out" '  - palantir-genetrends idle'
assert_contains     "live chat row kept"                         "$out" '  - chat idle'
assert_contains     "live palantir-genetrends-skeptic row kept"  "$out" '  - palantir-genetrends-skeptic idle'
assert_contains     "footer (non-row line) passes through"       "$out" '(full snapshot; transitions only between snapshots)'
# Exactly the 5 live rows survive (+ footer).
kept_rows=$(printf '%s\n' "$out" | grep -c '^  - ')
assert_eq "exactly 5 window rows survive" "$kept_rows" 5

echo '=== Class 1: empty live set passes through unchanged (tmux transient) ==='
export MOCK_TMUX_WINDOWS=""     # helper auto-queries → empty → pass-through
out=$(printf '%s' "$SNAP" | _full_state_restat_live_windows "")
passthru_rows=$(printf '%s\n' "$out" | grep -c '^  - ')
assert_eq "all 7 rows survive on empty live set" "$passthru_rows" 7
unset MOCK_TMUX_WINDOWS

echo '=== Class 1: all-live snapshot is unchanged ==='
LIVE_ALL="palantir-genetrends
prox-obsp
xiulan-simplify
pubfork-skills
chat
pubfork-skills-skeptic
palantir-genetrends-skeptic"
out=$(printf '%s' "$SNAP" | _full_state_restat_live_windows "$LIVE_ALL")
all_rows=$(printf '%s\n' "$out" | grep -c '^  - ')
assert_eq "all 7 rows survive when all live" "$all_rows" 7

# ======================================================================
# Class 2 — change-emit collapses the periodic full-state shadow
# ======================================================================
# Reproduce main.sh's two independent full-state predicates:
#   DUE clock:   now - FULL_STATE_STAMP >= full_state_emit_interval
#   HEARTBEAT:   now - CANONICAL_CACHE_mtime >= effective_floor  (only
#                consulted when DUE and canonical unchanged)
# Class 2 resets FULL_STATE_STAMP on EVERY paste; the heartbeat predicate
# reads the canonical-cache mtime, which a change poll never touches.
echo '=== Class 2: change-emit resets the DUE clock, collapsing the shadow ==='
EMIT_INTERVAL=600
# t=0 last full-state emit → stamp=0. A change poll pastes at t=590.
last_full_ts=0
change_emit_ts=590

due_at() {   # due_at <now> <stamp>  → 1 (due) / 0 (not due)
    local now="$1" stamp="$2"
    (( now - stamp >= EMIT_INTERVAL )) && echo 1 || echo 0
}
# Pre-fix: the change poll does NOT move the stamp, so at t=600 the
# periodic full-state is DUE — firing 10s after the change poll (shadow).
assert_eq "pre-fix: full-state DUE 10s after change poll (shadow)" \
    "$(due_at 600 "$last_full_ts")" 1
# With the fix: the change poll reset the stamp to 590, so at t=600 the
# full-state is NOT due — the shadow is collapsed.
assert_eq "fix: full-state NOT due right after change poll" \
    "$(due_at 600 "$change_emit_ts")" 0
# The periodic full-state still fires — deferred by one emit interval from
# the change poll (t=590+600=1190), never suppressed forever.
assert_eq "fix: full-state due one interval after the change poll" \
    "$(due_at 1190 "$change_emit_ts")" 1

echo '=== Class 2: liveness HEARTBEAT is governed by canonical mtime, not the stamp ==='
source "$_test_dir/_emit_dedup.sh"
export MONITOR_FULL_STATE_SAFETY_FLOOR_SECONDS=900
export MONITOR_FULL_STATE_IDLE_BACKOFF_ENABLED=true
export MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS=7200
heartbeat_fires() {   # <age_since_canonical> <idle_streak> → emit|suppress
    local age="$1" idle="$2" floor
    floor=$(_full_state_effective_floor "$idle")
    (( age >= floor )) && echo emit || echo suppress
}
# A static workspace: the canonical hasn't changed and its cache is older
# than the base floor → the heartbeat EMITS regardless of how recently a
# change poll reset the DUE stamp. This is the invariant Class 2 must not
# break: the timeout heartbeat still pokes a quiet-but-healthy orchestrator.
assert_eq "static workspace past base floor → heartbeat emits" \
    "$(heartbeat_fires 950 100)" emit
# Fresh canonical (recently emitted heartbeat) → suppressed, as before.
assert_eq "canonical fresh → heartbeat suppressed" \
    "$(heartbeat_fires 300 100)" suppress

# ======================================================================
# Class 3 — your-org/nexus-code#1397: an EMPTY pane-state read is an
# INSTRUMENT failure, not a classifier `unknown`, and the snapshot says which
# ======================================================================
# Four consecutive snapshots rendered one pane `state=unknown` while a direct
# pane-state.sh read said `working-background`, no stderr either side —
# because `_idle_pane_state_line` ran pane-state.sh with `2>/dev/null … || true`
# and the renderer collapsed an empty read into `unknown`. Driven through the
# REAL `render_full_state_snapshot` with a scripted pane-state.sh at
# $NEXUS_ROOT/monitor/pane-state.sh.
echo '=== Class 3: probe FAILED vs classifier unknown are rendered apart ==='
export NEXUS_ROOT="$WORK"
mkdir -p "$WORK/monitor"
cat > "$WORK/monitor/pane-state.sh" <<'PS'
#!/usr/bin/env bash
case "${MOCK_PS_MODE:-idle}" in
    fail)    echo "boom: capture-pane timed out under load" >&2; exit 2 ;;
    empty)   exit 0 ;;
    forge)   echo "state=busy active=1" >&2; exit 2 ;;
    unknown) echo "state=unknown active=0 window=3 name=wtmuxsk" ;;
    *)       echo "state=idle active=0 window=3 name=wtmuxsk" ;;
esac
PS
chmod +x "$WORK/monitor/pane-state.sh"
export MOCK_TMUX_WINDOWS="wtmuxsk|$(( $(date +%s) - 300 ))|3"
snap() { MOCK_PS_MODE="$1" render_full_state_snapshot 2>/dev/null; }

# The primitive: no line from the probe -> a DIAGNOSTIC line with NO state= key.
line=$(MOCK_PS_MODE=fail _idle_pane_state_line 3 wtmuxsk)
assert_contains     "probe rc!=0 + no stdout -> diagnostic line probe=failed" "$line" "probe=failed"
assert_contains     "…carries the rc"                                         "$line" "probe_rc=2"
assert_contains     "…carries the first stderr line"                          "$line" "boom: capture-pane timed out"
assert_not_contains "…and carries NO state= key (consumers still read empty)" "$line" "state="
assert_eq "_idle_pane_state_get still says unknown on a failed probe" "$(MOCK_PS_MODE=fail _idle_pane_state_get 3)" unknown
line=$(MOCK_PS_MODE=empty _idle_pane_state_line 3 wtmuxsk)
assert_contains "probe rc=0 + no stdout -> probe=failed probe_rc=0" "$line" "probe=failed probe_rc=0"
assert_contains "…with stderr: none"                                 "$line" "probe_stderr=none"
# NEGATIVE CONTROL: stderr text cannot FORGE a state through the diagnostic.
line=$(MOCK_PS_MODE=forge _idle_pane_state_line 3 wtmuxsk)
assert_not_contains "stderr saying state=busy cannot forge a state= field" "$line" "state="
assert_eq "…and the parsed state is still unknown" "$(MOCK_PS_MODE=forge _idle_pane_state_get 3)" unknown

# The snapshot: three different facts, three different labels.
out=$(snap fail)
assert_contains     "snapshot/fail: row says READ FAILED with the rc"       "$out" "state=unknown; pane-state.sh READ FAILED (rc=2"
assert_contains     "snapshot/fail: row carries the stderr excerpt"         "$out" "boom: capture-pane timed out"
assert_contains     "snapshot/fail: row says INSTRUMENT failure"            "$out" "INSTRUMENT failure, not a pane classification"
assert_not_contains "snapshot/fail: row does NOT claim a classifier verdict" "$out" "classifier verdict"
out=$(snap unknown)
assert_contains     "snapshot/unknown: row says classifier verdict"         "$out" "state=unknown; classifier verdict"
assert_not_contains "snapshot/unknown: row does NOT say READ FAILED"        "$out" "READ FAILED"
out=$(snap idle)
assert_contains     "snapshot/idle (control): plain state=idle"             "$out" "(state=idle)"
assert_not_contains "snapshot/idle (control): no unknown annotation"        "$out" "unknown;"
# The dead-window re-stat (Class 1) still keys on the window NAME, so an
# annotated row is dropped/kept exactly like a plain one.
kept=$(snap fail | _full_state_restat_live_windows "wtmuxsk" | grep -c '^  - wtmuxsk ')
assert_eq "annotated row survives the live re-stat" "$kept" 1
unset NEXUS_ROOT MOCK_TMUX_WINDOWS

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then echo "ALL TESTS PASSED"; exit 0; else echo "TESTS FAILED"; exit 1; fi
