#!/usr/bin/env bash
# Integration scenario: same-name worker recycle → stale wrap-up ignored.
#
# Pass B scenario 4/4 for your-org/nexus-code#78. PRs #45/#46/#55/#63/#68
# each tried to fix narrow facets of the "worker dies, same name returns,
# watcher resurrects the prior life's classification" regression class.
# PR #73 D2 landed the structural fix: spawn-worker.sh seeds an
# authoritative `spawn` action-log event whose ts becomes the lifecycle
# birth, and `_idle_probe.sh::_idle_window_wrap_up_report` scopes wrap-up
# matching to entries with `ts >= spawn_epoch`. This scenario lifts that
# from helper-level unit coverage to "the matcher actually rejects a
# stale wrap-up when a real tmux window with the same name has been
# kill-and-respawned".
#
# Flow exercised:
#
#   1. First life of `recycle-worker`:
#        - seed lifecycle anchors (mirror of spawn-worker.sh's
#          _seed_lifecycle_anchors: `spawn` action-log row +
#          engagement-log row stamped at NOW),
#        - spawn the stub claude via the harness's tmux,
#        - emit a `wrap-up` action-log event for the window.
#        - assert: `_idle_window_wrap_up_report` returns the basename
#          (matcher CAN see the wrap-up in this lifecycle).
#   2. Kill the window; assert `state=absent`.
#   3. Second life of `recycle-worker` (same window name):
#        - sleep > 1s so the new spawn ts > the stale wrap-up ts (the
#          action log records `date -Is` at 1-second resolution),
#        - seed fresh lifecycle anchors,
#        - spawn a new stub claude.
#        - assert (a): engagement-log row for the window now has ts
#          NEWER than the stale wrap-up's ts.
#        - assert (b): `_idle_window_wrap_up_report` returns 1
#          (lifecycle scope filter drops the prior life's wrap-up).
#        - assert (c): with the spawn-grace gate disabled and the
#          engagement-log row backdated past the idle threshold,
#          `list_really_idle_workers` classifies the window as
#          `no-wrap-up`, NOT `wrapped` — the production composition
#          that the matcher feeds.
#   4. Spawn-grace gate:
#        - re-stamp the lifecycle anchors at NOW (fresh spawn), backdate
#          engagement so age >= threshold,
#        - with MONITOR_IDLE_POOL_SPAWN_GRACE_SECONDS=120 (default),
#          `list_really_idle_workers` MUST NOT emit a row for the worker
#          even though pane-state looks idle and engagement-age has
#          crossed the threshold. The grace gate is the second half of
#          the #73 D2 lifecycle-anchor pair.
#
# This scenario directly exercises the helpers under test:
#   - _idle_window_spawn_ts            (lifecycle birth lookup)
#   - _idle_window_wrap_up_report      (lifecycle-scoped matcher)
#   - list_really_idle_workers         (spawn-grace gate composition)
#   - spawn-worker.sh::_seed_lifecycle_anchors  (write shape)
#
# The matcher is NOT mocked. We replicate the production write shape
# (action-log + engagement-log) and call the real `_idle_probe.sh`
# helpers directly. spawn-worker.sh itself is heavy to drive from a
# scenario (requires NEXUS_ROOT, floor file, prompt file, hook
# scaffolding), so its lifecycle-seed routine — twelve lines of atomic
# file writes — is replicated inline by `seed_lifecycle_anchors` below.
# Keep that helper in lockstep with spawn-worker.sh::_seed_lifecycle_anchors.
#
# Run: RUN_INTEGRATION=1 bash monitor/watcher/test-integration/test-same-name-recycle.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_harness.sh
. "$_self_dir/_harness.sh"
# shellcheck source=../_test_helpers.sh
. "$_self_dir/../_test_helpers.sh"

harness_skip_if_disabled

# jq is a hard prerequisite — the matcher's primary path uses it, and
# the test's action-log writes go through `ng log-action` which also
# uses jq for safe escaping. Without jq the test would silently fall
# into the sed-fallback path that we don't intend to exercise here.
if ! command -v jq >/dev/null 2>&1; then
    echo "skipped: $(basename "${0}") (jq not on PATH)"
    exit 0
fi

harness_setup

# Rename the harness session to "0" so `pane-state.sh <bare-index>`
# resolves to our pane (pane-state.sh defaults a bare numeric target to
# session "0" — that matches the operator's typical session ID in
# production but NOT the harness's generated name). Slow-grind / spawn-
# busy-idle-absent only assert through wrappers that pass a full
# `session:index` target, so they don't run into this; our scenario
# exercises `list_really_idle_workers` which goes through
# `_idle_pane_state_line` with a bare index. The rename is the cheapest
# alignment.
harness_tmux rename-session -t "$HARNESS_SESSION" "0"
HARNESS_SESSION="0"
export HARNESS_SESSION

# Production helpers read STATE_DIR from env. The harness puts
# `$HARNESS_STATE_DIR` under the fake nexus tree; export both
# variables so any helper invocation routes there.
export STATE_DIR="$HARNESS_STATE_DIR"
export NEXUS_ROOT="$HARNESS_DIR"
# Spawn grace defaults to 120s. Override per-phase below.
export MONITOR_IDLE_POOL_SPAWN_GRACE_SECONDS=0
# Idle threshold default is 60s. Lower so phase-3 / phase-4 don't have
# to wait minute-scale. The disappearance-prune cycle has no time
# dependency, so this is the only knob that matters here.
export MONITOR_IDLE_THRESHOLD_SECONDS=10

# Mirror the watcher tree into the fake nexus root so `ng` and
# `pane-state.sh` (resolved by `_idle_probe.sh` via NEXUS_ROOT) line up
# with what production reads.
mkdir -p "$HARNESS_DIR/monitor/watcher" \
         "$HARNESS_DIR/config"
cp "$HARNESS_REPO_ROOT/monitor/ng"          "$HARNESS_DIR/monitor/ng"
cp "$HARNESS_REPO_ROOT/monitor/pane-state.sh" "$HARNESS_DIR/monitor/pane-state.sh"
chmod +x "$HARNESS_DIR/monitor/ng" "$HARNESS_DIR/monitor/pane-state.sh"
# `ng log-action` only touches the action log; it doesn't shell out to
# `config/load.sh`. A no-op stub keeps the resolver chain inert without
# accidentally redirecting STATE_DIR elsewhere.
cat > "$HARNESS_DIR/config/load.sh" <<'CFG'
#!/usr/bin/env bash
exit 2
CFG
chmod +x "$HARNESS_DIR/config/load.sh"

# Source the real `_idle_probe.sh`. The matcher and the
# `list_really_idle_workers` gate run from this in-process source —
# no subprocess hop, so PASS/FAIL counters stay reliable.
# shellcheck source=../_idle_probe.sh
. "$HARNESS_REPO_ROOT/monitor/watcher/_idle_probe.sh"

NG="$HARNESS_DIR/monitor/ng"
WORKER_NAME=recycle-worker
ACTION_LOG="$STATE_DIR/action-log.jsonl"
ENGAGEMENT_LOG="$STATE_DIR/engagement-log.tsv"
STALE_REPORT_BASENAME="your-nexus_$(date -u +%Y-%m-%d)_120000_${WORKER_NAME}-test.md"

echo "=== harness ==="
echo "  HARNESS_DIR=$HARNESS_DIR"
echo "  HARNESS_SESSION=$HARNESS_SESSION"
echo "  STATE_DIR=$STATE_DIR"
echo "  WORKER_NAME=$WORKER_NAME"

# ---------------------------------------------------------------------------
# Replicates spawn-worker.sh::_seed_lifecycle_anchors — the production
# write shape the matcher relies on. Keep in lockstep with the
# production routine when its on-disk format evolves.
# ---------------------------------------------------------------------------
seed_lifecycle_anchors() {
    local window="$1"
    local now
    now=$(date +%s)
    mkdir -p "$STATE_DIR"
    "$NG" log-action monitor \
        --event spawn \
        --extra "window=$window" \
        --extra "workdir=$HARNESS_DIR" \
        >/dev/null
    local tmp
    tmp=$(mktemp "${ENGAGEMENT_LOG}.XXXXXX")
    if [[ -f "$ENGAGEMENT_LOG" ]]; then
        awk -F'\t' -v w="$window" '$1 != w' "$ENGAGEMENT_LOG" > "$tmp"
    fi
    printf '%s\t%s\n' "$window" "$now" >> "$tmp"
    mv "$tmp" "$ENGAGEMENT_LOG"
}

emit_wrap_up_event() {
    local window="$1" report="$2"
    "$NG" log-action monitor \
        --event wrap-up \
        --extra "window=$window" \
        --extra "report=$report" \
        --extra "issue=999" \
        >/dev/null
}

engagement_epoch_for() {
    local window="$1"
    awk -F'\t' -v w="$window" '$1 == w { print $2; exit }' "$ENGAGEMENT_LOG"
}

# Pull the most recent wrap-up event ts for the window from the
# action log (raw ISO; matches what _idle_iso_to_epoch consumes).
latest_wrap_up_iso_for() {
    local window="$1"
    grep '"event":"wrap-up"' "$ACTION_LOG" 2>/dev/null \
        | tac \
        | jq -r --arg w "$window" 'select(.window == $w) | .ts' \
        | head -1
}

# ===========================================================================
# Phase 1: first life — seed anchors, spawn stub, emit wrap-up.
# ===========================================================================
echo
echo "=== phase 1: first life — spawn, wrap-up baseline ==="

seed_lifecycle_anchors "$WORKER_NAME"
SPAWN1_ISO=$(_idle_window_spawn_ts "$WORKER_NAME")
echo "  first-life spawn ts: $SPAWN1_ISO"
assert_eq "first-life spawn event recorded" \
    "$([[ -n "$SPAWN1_ISO" ]] && echo present || echo missing)" \
    "present"

win1=$(harness_spawn_worker "$WORKER_NAME" \
    "STUB_CLAUDE_BUSY_SECONDS=0" \
    "STUB_CLAUDE_HOLD_SECONDS=60")
[[ "$win1" =~ ^[0-9]+$ ]] || {
    echo "  FAIL: phase-1 spawn returned non-numeric window index: $win1" >&2
    th_summary_and_exit
}
echo "  first-life tmux window=$win1"

# pane-state.sh takes <window-index> or <session>:<window-index> — NOT
# a window-name target. Scenarios pass the integer index recorded by
# `harness_spawn_worker`. Mirrors the predicate shape in
# test-spawn-busy-idle-absent.sh.
pane_state_is() {
    local idx="$1" expected="$2" out
    out=$(PATH="$HARNESS_BIN:$PATH" \
        "$HARNESS_REPO_ROOT/monitor/pane-state.sh" \
        "${HARNESS_SESSION}:${idx}" 2>/dev/null) || return 1
    grep -q "state=${expected}" <<<"$out"
}

# `ng log-action` stamps `date -Is` at one-second resolution. Sleep
# 1.2s so the wrap-up ts is unambiguously ≥ spawn ts (the matcher
# allows equality; we want a clean ordering for human-eyeball
# debugging on the log).
sleep 1.2
emit_wrap_up_event "$WORKER_NAME" "$STALE_REPORT_BASENAME"

# Matcher CAN see the wrap-up while still in the first life: the
# event's ts >= spawn_ts (same lifecycle).
match_basename=$(_idle_window_wrap_up_report "$WORKER_NAME" "$ACTION_LOG" || true)
assert_eq "phase-1 matcher returns the wrap-up basename" \
    "$match_basename" "$STALE_REPORT_BASENAME"

# ===========================================================================
# Phase 2: kill the window. Pane-state must flip to absent — that's
# the regression PR #55 was supposed to keep stable. Validates the
# precondition the recycle relies on (window genuinely went away).
# ===========================================================================
echo
echo "=== phase 2: kill first-life window ==="
harness_tmux kill-window -t "${HARNESS_SESSION}:${win1}"

wait_for "pane-state reports absent after first-life kill" 3 -- pane_state_is "$win1" absent

# ===========================================================================
# Phase 3: second life — fresh spawn anchor, re-spawn the stub, assert
# the matcher drops the stale wrap-up.
# ===========================================================================
echo
echo "=== phase 3: second life — same name; lifecycle scope filters stale wrap-up ==="

# Sleep ≥ 1s so the new spawn ts is strictly greater than the stale
# wrap-up ts (action log resolution is one second). The matcher's
# scope check is `entry_epoch < spawn_epoch`, so equality would let
# the stale wrap-up through. The production case clears this trivially
# (wrap-up and re-spawn are operator-driven minutes apart); for the
# test we pin the ordering explicitly.
echo "  pause 2s so second-life spawn ts > first-life wrap-up ts"
sleep 2
seed_lifecycle_anchors "$WORKER_NAME"
SPAWN2_ISO=$(_idle_window_spawn_ts "$WORKER_NAME")
echo "  second-life spawn ts: $SPAWN2_ISO"

WRAP1_ISO=$(latest_wrap_up_iso_for "$WORKER_NAME")
WRAP1_EPOCH=$(_idle_iso_to_epoch "$WRAP1_ISO")
SPAWN2_EPOCH=$(_idle_iso_to_epoch "$SPAWN2_ISO")
echo "  stale wrap-up epoch:  $WRAP1_EPOCH"
echo "  fresh spawn  epoch:   $SPAWN2_EPOCH"

# (a) engagement-log row carries a newer ts than the prior wrap-up.
ENG_EPOCH=$(engagement_epoch_for "$WORKER_NAME")
echo "  engagement-log epoch: $ENG_EPOCH"
if [[ "$ENG_EPOCH" =~ ^[0-9]+$ ]] \
   && [[ "$WRAP1_EPOCH" =~ ^[0-9]+$ ]] \
   && (( ENG_EPOCH > WRAP1_EPOCH )); then
    printf '  PASS: engagement-log row is newer than stale wrap-up (delta=%ds)\n' \
        "$(( ENG_EPOCH - WRAP1_EPOCH ))"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: engagement-log row (%s) is not newer than stale wrap-up (%s)\n' \
        "$ENG_EPOCH" "$WRAP1_EPOCH" >&2
    FAIL=$(( FAIL + 1 ))
fi

# Re-spawn the tmux window with the same name so list_really_idle_workers
# enumerates it. Stub busy-then-idle: short busy phase, long hold.
win2=$(harness_spawn_worker "$WORKER_NAME" \
    "STUB_CLAUDE_BUSY_SECONDS=0" \
    "STUB_CLAUDE_HOLD_SECONDS=60")
[[ "$win2" =~ ^[0-9]+$ ]] || {
    echo "  FAIL: phase-3 re-spawn returned non-numeric window index: $win2" >&2
    th_summary_and_exit
}
echo "  second-life tmux window=$win2"

# (b) lifecycle-scoped matcher drops the stale wrap-up. Note: the
# action log STILL contains the wrap-up entry — the matcher's job is
# to ignore it based on ts vs spawn ts.
match2=$(_idle_window_wrap_up_report "$WORKER_NAME" "$ACTION_LOG" 2>/dev/null || true)
assert_empty "phase-3 matcher drops stale wrap-up after recycle" "$match2"

# Sanity: the wrap-up event is still in the log — the matcher chose
# to skip it, not magically deleted it.
wrap_event_count=$(grep -c '"event":"wrap-up"' "$ACTION_LOG" 2>/dev/null || echo 0)
assert_eq "wrap-up event still on disk (matcher skipped, did not erase)" \
    "$wrap_event_count" "1"

# (c) full classifier composition: with the spawn-grace gate already
# disabled (set above) and engagement-log backdated past the threshold,
# `list_really_idle_workers` MUST classify the window as `no-wrap-up`,
# NOT `wrapped`. This is the production line the operator actually
# sees through render_idle_section.
#
# Confirm the stub is rendering its idle frame before we drive the
# probe through it. The stub starts idle (BUSY=0) so this should
# resolve on the first poll; the wait is defensive against the
# new-window/render race tmux exhibits in the first ~250 ms after a
# `new-window` (capture-pane briefly returns nothing — pane-state
# emits `state=absent` then because the renderer signal is empty).
wait_for "stub claude rendering idle frame (second life)" 6 -- pane_state_is "$win2" idle
backdate=$(( $(date +%s) - MONITOR_IDLE_THRESHOLD_SECONDS - 5 ))
tmp=$(mktemp "${ENGAGEMENT_LOG}.XXXXXX")
awk -F'\t' -v w="$WORKER_NAME" -v ts="$backdate" '
    $1 == w { next }
    { print }
    END { printf "%s\t%s\n", w, ts }
' "$ENGAGEMENT_LOG" > "$tmp"
mv "$tmp" "$ENGAGEMENT_LOG"

idle_set=$(list_really_idle_workers 2>/dev/null)
echo "  idle set:"
printf '%s\n' "$idle_set" | sed 's/^/    /'
recycle_row=$(printf '%s\n' "$idle_set" \
    | awk -F'\t' -v w="$WORKER_NAME" '$1 == w { print; exit }')
recycle_class=$(printf '%s' "$recycle_row" | awk -F'\t' '{print $2}')
assert_eq "phase-3 classifier emits no-wrap-up (NOT wrapped)" \
    "$recycle_class" "no-wrap-up"

# ===========================================================================
# Phase 4: spawn-grace gate. With the production default
# MONITOR_IDLE_POOL_SPAWN_GRACE_SECONDS=120 active and a fresh spawn
# event, the classifier must NOT emit the worker even when engagement
# is backdated past the idle threshold.
# ===========================================================================
echo
echo "=== phase 4: spawn-grace gate suppresses brand-new windows ==="

# Re-stamp the spawn so it's fresh again. Engagement stays backdated
# (the row from phase 3 still has the backdated ts because
# seed_lifecycle_anchors atomically rewrites the engagement-log row at
# NOW — so re-stamp ALSO re-engages now-engagement; we then re-backdate.)
seed_lifecycle_anchors "$WORKER_NAME"
backdate=$(( $(date +%s) - MONITOR_IDLE_THRESHOLD_SECONDS - 5 ))
tmp=$(mktemp "${ENGAGEMENT_LOG}.XXXXXX")
awk -F'\t' -v w="$WORKER_NAME" -v ts="$backdate" '
    $1 == w { next }
    { print }
    END { printf "%s\t%s\n", w, ts }
' "$ENGAGEMENT_LOG" > "$tmp"
mv "$tmp" "$ENGAGEMENT_LOG"

# Re-enable production-default spawn grace for this phase.
export MONITOR_IDLE_POOL_SPAWN_GRACE_SECONDS=120

idle_set_with_grace=$(list_really_idle_workers 2>/dev/null)
echo "  idle set (grace=120):"
printf '%s\n' "$idle_set_with_grace" | sed 's/^/    /'
grace_row=$(printf '%s\n' "$idle_set_with_grace" \
    | awk -F'\t' -v w="$WORKER_NAME" '$1 == w { print; exit }')
assert_empty "phase-4 spawn-grace suppresses idle classification" "$grace_row"

# Disable grace again and confirm the row DOES surface — proves the
# grace is the sole reason for suppression in phase 4, not some other
# precondition we've accidentally broken.
export MONITOR_IDLE_POOL_SPAWN_GRACE_SECONDS=0
idle_set_without_grace=$(list_really_idle_workers 2>/dev/null)
grace_row_off=$(printf '%s\n' "$idle_set_without_grace" \
    | awk -F'\t' -v w="$WORKER_NAME" '$1 == w { print; exit }')
grace_class_off=$(printf '%s' "$grace_row_off" | awk -F'\t' '{print $2}')
assert_eq "phase-4 control: with grace disabled, classifier surfaces no-wrap-up" \
    "$grace_class_off" "no-wrap-up"

# ===========================================================================
# Diagnostic dump (failure path only).
# ===========================================================================
if (( FAIL > 0 )); then
    echo
    echo "=== diagnostic dump (failure path) ==="
    echo "--- action-log ---"
    cat "$ACTION_LOG" 2>/dev/null || echo "(missing)"
    echo "--- engagement-log ---"
    cat "$ENGAGEMENT_LOG" 2>/dev/null || echo "(missing)"
    echo "--- list-windows ---"
    harness_tmux list-windows -t "$HARNESS_SESSION" \
        -F '#{window_index}: #{window_name} active=#{window_active}' || true
    echo "--- pane-state (current second-life window idx=${win2:-?}) ---"
    [[ -n "${win2:-}" ]] && harness_pane_state "$win2" || true
fi

th_summary_and_exit
