#!/usr/bin/env bash
# Unit tests for the skeptic-exemption FIDELITY fix (emit/exemption
# fidelity, Defect B): the parked-awaiting-skeptic exemption must require an
# ACTUAL live skeptic, not merely a fresh skeptic-pending marker (which the
# worker's own await loop keeps fresh forever). A fresh marker with no live
# skeptic past the grace window is ORPHANED — it stops conferring the
# exemption and surfaces as an actionable class.
#
# Strategy: shadow `tmux` on PATH so `_idle_skeptic_live_window` sees a
# scriptable window set; seed a fake action-log.jsonl and skeptic-pending
# markers under a per-test STATE_DIR; source _idle_probe.sh and call the
# predicates directly.
#
# Run: bash monitor/watcher/test-skeptic-fidelity.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROBE="$_test_dir/_idle_probe.sh"

PASS=0
FAIL=0
ok()   { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad()  { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
assert_parked()   { if _idle_skeptic_parked   "$1" "$NOW" "$LIVE"; then ok "$2"; else bad "$2 (expected parked/exempt)"; fi; }
assert_unparked() { if _idle_skeptic_parked   "$1" "$NOW" "$LIVE"; then bad "$2 (expected NOT parked)"; else ok "$2"; fi; }
assert_orphan()   { if _idle_skeptic_orphaned "$1" "$NOW" "$LIVE"; then ok "$2"; else bad "$2 (expected orphaned)"; fi; }
assert_notorphan(){ if _idle_skeptic_orphaned "$1" "$NOW" "$LIVE"; then bad "$2 (expected NOT orphaned)"; else ok "$2"; fi; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STATE_DIR="$WORK/.state"
mkdir -p "$STATE_DIR/skeptic/pending"
export STATE_DIR
# No config/load.sh reachable → helpers fall back to defaults (hang 600,
# orphan grace 600). Keep NEXUS_ROOT unset so the config probe is skipped.
unset NEXUS_ROOT MONITOR_SKEPTIC_AWAIT_HANG_SECONDS MONITOR_SKEPTIC_ORPHAN_GRACE_SECONDS 2>/dev/null || true

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
# Stub tmux: list-windows emits $MOCK_TMUX_WINDOWS (newline-separated names).
cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    list-windows) printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" ;;
    *) : ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/tmux"
export PATH="$STUB_DIR:$PATH"

# shellcheck source=_idle_probe.sh
source "$PROBE"

ACTION_LOG="$STATE_DIR/action-log.jsonl"
NOW=$(date +%s)
LIVE=""   # set per-scenario from MOCK_TMUX_WINDOWS

# Helpers to build fixtures.
iso() { date -d "@$1" -Is 2>/dev/null || date -Is; }        # epoch -> ISO
mk_marker() { : > "$STATE_DIR/skeptic/pending/${1//[^a-zA-Z0-9_-]/_}"; touch -d "@$2" "$STATE_DIR/skeptic/pending/${1//[^a-zA-Z0-9_-]/_}"; }
log_request() { printf '{"ts":"%s","agent":"monitor","event":"skeptic-request","target-window":"%s","depth":"1"}\n' "$(iso "$2")" "$1" >> "$ACTION_LOG"; }
log_spawn()   { printf '{"ts":"%s","agent":"monitor","event":"skeptic-spawn","window":"%s","target-window":"%s","orig-window":"%s","depth":"1"}\n' "$(iso "$3")" "$2" "$1" "$1" >> "$ACTION_LOG"; }

# ---- Scenario 1: fresh marker + LIVE skeptic window → parked (exempt) ----
echo "=== 1. fresh marker + live skeptic → exempt ==="
mk_marker worker-a "$NOW"                        # marker fresh (worker parked)
log_request worker-a "$(( NOW - 30 ))"           # skeptic required 30s ago
log_spawn   worker-a worker-a-skeptic "$(( NOW - 20 ))"  # a real skeptic spawned
LIVE=$'worker-a\nworker-a-skeptic\norchestrator' # skeptic window is ALIVE
export MOCK_TMUX_WINDOWS="$LIVE"
assert_parked    worker-a "live skeptic window present → parked/exempt"
assert_notorphan worker-a "live skeptic → not orphaned"

# ---- Scenario 2: fresh marker, no skeptic, WITHIN grace → exempt --------
echo "=== 2. fresh marker, no skeptic yet, within grace → exempt ==="
mk_marker worker-b "$NOW"
log_request worker-b "$(( NOW - 60 ))"           # required only 60s ago (< 600 grace)
LIVE=$'worker-b\norchestrator'                   # NO skeptic window
export MOCK_TMUX_WINDOWS="$LIVE"
assert_parked    worker-b "no skeptic but within grace → still exempt"
assert_notorphan worker-b "within grace → not yet orphaned"

# ---- Scenario 3: fresh marker, no skeptic, PAST grace → ORPHANED --------
# THE bug: the worker's await keeps the marker fresh forever, but no skeptic
# was ever spawned. Past the grace window the exemption must lapse.
echo "=== 3. fresh marker, no skeptic, past grace → orphaned (NOT exempt) ==="
mk_marker worker-c "$NOW"                         # marker STILL fresh (await re-touches)
log_request worker-c "$(( NOW - 1200 ))"          # required 20 min ago, never spawned
LIVE=$'worker-c\norchestrator'                    # NO skeptic window
export MOCK_TMUX_WINDOWS="$LIVE"
assert_unparked worker-c "fresh marker, no skeptic, past grace → NOT exempt"
assert_orphan   worker-c "fresh marker, no skeptic, past grace → orphaned"

# ---- Scenario 4: skeptic was spawned but its window DIED → not exempt ---
echo "=== 4. skeptic spawned then died, past grace → orphaned ==="
mk_marker worker-d "$NOW"
log_request worker-d "$(( NOW - 1300 ))"
log_spawn   worker-d worker-d-skeptic "$(( NOW - 1200 ))"  # spawned...
LIVE=$'worker-d\norchestrator'                    # ...but skeptic window is GONE
export MOCK_TMUX_WINDOWS="$LIVE"
assert_unparked worker-d "spawn recorded but skeptic window dead → NOT exempt"
assert_orphan   worker-d "dead skeptic past grace → orphaned"

# ---- Scenario 5: STALE marker (await died) → neither parked nor orphaned -
# A marker older than the hang window is the genuine-hang path — it must
# fall through to normal idle classification, NOT the orphan class.
echo "=== 5. stale marker → genuine-hang path (not parked, not orphaned) ==="
mk_marker worker-e "$(( NOW - 900 ))"             # marker mtime 15 min old (> 600 hang)
log_request worker-e "$(( NOW - 2000 ))"
LIVE=$'worker-e\norchestrator'
export MOCK_TMUX_WINDOWS="$LIVE"
assert_unparked  worker-e "stale marker → NOT parked"
assert_notorphan worker-e "stale marker → NOT orphaned (genuine-hang path)"

# ---- Scenario 6: template-named skeptic window covers action-log gap ----
echo "=== 6. no spawn event, but <win>-skeptic window alive → exempt ==="
mk_marker worker-f "$NOW"
log_request worker-f "$(( NOW - 1200 ))"          # past grace...
LIVE=$'worker-f\nworker-f-skeptic\norchestrator'  # ...but template skeptic is ALIVE
export MOCK_TMUX_WINDOWS="$LIVE"
assert_parked    worker-f "template-named live skeptic → exempt despite no spawn log"
assert_notorphan worker-f "template-named live skeptic → not orphaned"

# ---- Scenario 7: no marker at all → not parked, not orphaned ------------
echo "=== 7. no marker → not parked, not orphaned ==="
LIVE=$'worker-g\norchestrator'
export MOCK_TMUX_WINDOWS="$LIVE"
assert_unparked  worker-g "no marker → not parked"
assert_notorphan worker-g "no marker → not orphaned"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then echo "ALL TESTS PASSED"; exit 0; else echo "TESTS FAILED"; exit 1; fi
