#!/usr/bin/env bash
# Tests for the interrupted-mid-turn classification in
# monitor/watcher/_idle_probe.sh (the stall-detection work).
#
# A fresh `turn-failure/<window>.json` marker (written by the
# StopFailure hook) reclassifies an otherwise idle/empty worker as
# `interrupted`, carrying `<category>:<recovery>` so the orchestrator
# picks paste-vs-respawn correctly. This proves the marker → class
# wiring AND the negative cases (busy resumed, exited, no-marker,
# stale-marker) that keep it from over-firing.
#
# Harness mirrors test-idle-probe.sh: shadow tmux + pane-state.sh on
# PATH, seed engagement-log so the age gate passes, drop a marker.
#
# Run: bash monitor/watcher/test-idle-probe-interrupted.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROBE="$_test_dir/_idle_probe.sh"

PASS=0; FAIL=0
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n         want: %s\n         in:\n%s\n' "$label" "$needle" "$hay" >&2
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

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/.state"; mkdir -p "$STATE_DIR"; export STATE_DIR
STUB_DIR="$WORK/bin"; mkdir -p "$STUB_DIR"
mkdir -p "$WORK/monitor"
NEXUS_ROOT="$WORK"; export NEXUS_ROOT

cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    list-windows) printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" ;;
    *) : ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

cat > "$STUB_DIR/pane-state.sh" <<'STUB'
#!/usr/bin/env bash
win="${1:-}"
while [[ "$win" == --* ]]; do shift 2 2>/dev/null || break; win="${1:-}"; done
key="MOCK_PANE_STATE_${win//[^a-zA-Z0-9_]/_}"
printf 'state=%s\n' "${!key:-busy}"
exit 0
STUB
chmod +x "$STUB_DIR/pane-state.sh"
cp "$STUB_DIR/pane-state.sh" "$WORK/monitor/pane-state.sh"

NOW=$(date +%s)
OLD_TS=$(( NOW - 120 ))   # above the 60s idle threshold

seed_engagement() {
    local elog="$STATE_DIR/engagement-log.tsv"; : > "$elog"
    printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" \
        | awk -F'|' 'NF>=2 && $1 != "" { printf "%s\t%s\n", $1, $2 }' >> "$elog"
}

# Drop a turn-failure marker exactly as turn-failure-emit.sh writes it.
drop_marker() {
    local window="$1" category="$2" recovery="$3" ts="${4:-$NOW}"
    mkdir -p "$STATE_DIR/turn-failure"
    jq -nc --argjson ts "$ts" --arg cat "$category" --arg rec "$recovery" \
        '{ts:$ts, error:"server_error", category:$cat, recovery:$rec, window:"w"}' \
        > "$STATE_DIR/turn-failure/$window.json"
}

run_probe_capture() {
    local _out_var="$1" _rc_var="$2"; shift 2
    local _tmp; _tmp=$(mktemp)
    PATH="$STUB_DIR:$PATH" bash -c "
        set -uo pipefail
        STATE_DIR='$STATE_DIR'; NEXUS_ROOT='$NEXUS_ROOT'
        source '$PROBE'
        $*" >"$_tmp" 2>/dev/null
    local _rc=$?
    printf -v "$_out_var" '%s' "$(<"$_tmp")"; printf -v "$_rc_var" '%s' "$_rc"
    rm -f "$_tmp"
}

echo "=== idle + fresh transient marker → interrupted:transient:paste ==="
export MOCK_TMUX_WINDOWS="wcrash|$OLD_TS"
export MOCK_PANE_STATE_wcrash=idle
seed_engagement
drop_marker wcrash transient paste
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "row class is interrupted" "$out" $'wcrash\tinterrupted'
assert_contains "detail carries transient:paste" "$out" "transient:paste"
assert_not_contains "NOT misclassified as no-wrap-up" "$out" "no-wrap-up"

echo "=== empty pane + fresh marker → interrupted (the real incident shape) ==="
export MOCK_TMUX_WINDOWS="wempty|$OLD_TS"
export MOCK_PANE_STATE_wempty=empty
seed_engagement
drop_marker wempty transient paste
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "empty+marker surfaces interrupted" "$out" $'wempty\tinterrupted'

echo "=== empty pane + NO marker → skipped (unchanged behaviour) ==="
unset MOCK_PANE_STATE_wcrash
export MOCK_TMUX_WINDOWS="wbare|$OLD_TS"
export MOCK_PANE_STATE_wbare=empty
seed_engagement
rm -rf "$STATE_DIR/turn-failure"
run_probe_capture out rc 'list_really_idle_workers'
assert_not_contains "bare empty pane not surfaced" "$out" "wbare"

echo "=== idle + NO marker → normal no-wrap-up (no regression) ==="
export MOCK_TMUX_WINDOWS="wnorm|$OLD_TS"
export MOCK_PANE_STATE_wnorm=idle
seed_engagement
rm -rf "$STATE_DIR/turn-failure"
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "no marker → no-wrap-up" "$out" $'wnorm\tno-wrap-up'
assert_not_contains "no marker → not interrupted" "$out" "interrupted"

echo "=== resumed worker (busy) + marker present → NOT surfaced (paste already worked) ==="
export MOCK_TMUX_WINDOWS="wbusy|$OLD_TS"
export MOCK_PANE_STATE_wbusy=busy
seed_engagement
drop_marker wbusy transient paste
run_probe_capture out rc 'list_really_idle_workers'
assert_not_contains "busy pane never surfaces despite marker" "$out" "wbusy"

echo "=== exited process (absent) + marker present → pane-absent wins (respawn, not paste) ==="
export MOCK_TMUX_WINDOWS="wdead|$OLD_TS"
export MOCK_PANE_STATE_wdead=absent
seed_engagement
drop_marker wdead transient paste
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "absent overrides marker" "$out" $'wdead\tpane-absent'
assert_not_contains "absent is NOT interrupted" "$out" "interrupted"

echo "=== stale marker (older than staleness) → falls back to no-wrap-up ==="
export MOCK_TMUX_WINDOWS="wstale|$OLD_TS"
export MOCK_PANE_STATE_wstale=idle
seed_engagement
drop_marker wstale transient paste $(( NOW - 4000 ))   # > 1800s default
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "stale marker → no-wrap-up" "$out" $'wstale\tno-wrap-up'
assert_not_contains "stale marker → not interrupted" "$out" "interrupted"

echo "=== respawn-recovery marker → render guidance says RESPAWN ==="
export MOCK_TMUX_WINDOWS="wmodel|$OLD_TS"
export MOCK_PANE_STATE_wmodel=idle
seed_engagement
rm -rf "$STATE_DIR/turn-failure"
drop_marker wmodel config respawn
rm -f "$STATE_DIR/idle-state.tsv"
run_probe_capture out rc 'render_idle_section'
assert_contains "render: interrupted respawn guidance" "$out" "RESPAWN"
assert_contains "render: names the window" "$out" "wmodel"

echo "=== prelude count includes interrupted axis ==="
export MOCK_TMUX_WINDOWS="wp|$OLD_TS"
export MOCK_PANE_STATE_wp=idle
seed_engagement
rm -rf "$STATE_DIR/turn-failure"; drop_marker wp transient paste
run_probe_capture out rc 'render_idle_prelude'
assert_contains "prelude shows interrupted axis" "$out" "interrupted"
assert_contains "prelude counts 1 interrupted" "$out" "1 interrupted"

echo
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED ($PASS)"; exit 0
else
    echo "FAILED: $FAIL (passed $PASS)" >&2; exit 1
fi
