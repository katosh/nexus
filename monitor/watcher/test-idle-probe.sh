#!/usr/bin/env bash
# Unit tests for monitor/watcher/_idle_probe.sh.
#
# Run: bash monitor/watcher/test-idle-probe.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: shadow `tmux` and `pane-state.sh` on PATH so we can
# script per-window window_activity epochs and pane-states without
# touching the real tmux server, and seed a fake action-log.jsonl
# under a per-test STATE_DIR. Source _idle_probe.sh and call its
# public functions directly.
#
# Tests cover:
#   - list_really_idle_workers honours the 60s threshold (default)
#     and MONITOR_IDLE_THRESHOLD_SECONDS override.
#   - Pane-state ∈ {idle, autosuggest-only} -> "really idle";
#     pane-state ∈ {absent, empty, blocked} -> `pane-absent` class
#     (inviolable, ignores window-retain).
#   - watcher / claude / orchestrator / monitor windows always
#     excluded regardless of activity age.
#   - Wrap-up classification: project-slot match, slug-slot match,
#     no match falls through to "no-wrap-up".
#   - list_idle_transitions dedupes against the prior state file:
#     same (window, class) silenced, new class on same window
#     surfaced.
#   - render_idle_section formats correctly and is empty on no
#     transitions.
#   - engagement-log: stamped when pane-state observes
#     busy / user-typing; retain consumed by engagement-log epoch
#     post retain.ts (NOT by tmux #{window_activity} alone);
#     missing engagement-log row means "no engagement ever" so
#     retain holds.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROBE="$_test_dir/_idle_probe.sh"

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
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         expected to find: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
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
assert_empty() {
    local label="$1" got="$2"
    if [[ -z "$got" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — expected empty, got: %q\n' "$label" "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STATE_DIR="$WORK/.state"
mkdir -p "$STATE_DIR"
export STATE_DIR

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"

# Stubbed tmux. Reads MOCK_TMUX_WINDOWS as newline-separated
# `<name>|<activity-epoch>` entries and emits them for
# `tmux list-windows -F '#{window_name}|#{window_activity}'`.
# Other tmux subcommands return empty / exit 0.
cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    list-windows)
        printf '%s\n' "${MOCK_TMUX_WINDOWS:-}"
        ;;
    display)
        # Not used in these tests; the probe consults list-windows
        # for activity. Return empty for safety.
        printf ''
        ;;
    *)
        :  # no-op
        ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

# Stubbed pane-state.sh. MOCK_PANE_STATE_<window-name> sets the
# state for that window; default `busy`. The probe only looks
# at the `state=...` key; emit just that.
cat > "$STUB_DIR/pane-state.sh" <<'STUB'
#!/usr/bin/env bash
# Sanitize the window name to a valid env-var suffix.
win="${1:-}"
# Strip any leading flags pane-state.sh accepts (--heartbeat-staleness
# <n>, etc.) so the stub matches the real script's calling convention.
while [[ "$win" == --* ]]; do
    shift 2 2>/dev/null || break
    win="${1:-}"
done
key="MOCK_PANE_STATE_${win//[^a-zA-Z0-9_]/_}"
reset_key="MOCK_PANE_RESET_AT_${win//[^a-zA-Z0-9_]/_}"
orphan_key="MOCK_ORPHAN_KINDS_${win//[^a-zA-Z0-9_]/_}"
hash_key="MOCK_CONTENT_HASH_${win//[^a-zA-Z0-9_]/_}"
state="${!key:-busy}"
reset_at="${!reset_key:-}"
orphan_kinds="${!orphan_key:-}"
content_hash="${!hash_key:-}"
extras=""
[[ -n "$reset_at" ]]      && extras+=" reset_at=$reset_at"
[[ -n "$orphan_kinds" ]]  && extras+=" orphan_kinds=$orphan_kinds"
[[ -n "$content_hash" ]]  && extras+=" content_hash=$content_hash"
printf 'state=%s%s\n' "$state" "$extras"
exit 0
STUB
chmod +x "$STUB_DIR/pane-state.sh"

# Place the stubbed pane-state.sh where _idle_pane_state_says_idle
# looks for it (NEXUS_ROOT/monitor/pane-state.sh or relative).
mkdir -p "$WORK/monitor"
cp "$STUB_DIR/pane-state.sh" "$WORK/monitor/pane-state.sh"
chmod +x "$WORK/monitor/pane-state.sh"
NEXUS_ROOT="$WORK"
export NEXUS_ROOT

# Source the probe under test. Use a fresh subshell per test so
# state leakage from earlier tests doesn't bleed.
run_probe() {
    PATH="$STUB_DIR:$PATH" bash -c "
        STATE_DIR='$STATE_DIR'
        NEXUS_ROOT='$NEXUS_ROOT'
        export STATE_DIR NEXUS_ROOT
        $* >/dev/null 2>&1
        echo \"\$_unused\"
    " 2>/dev/null
}

# A helper that runs a probe function with the current MOCK_* env
# already exported, captures stdout, returns rc.
run_probe_capture() {
    local _out_var="$1" _rc_var="$2"; shift 2
    local _stdout _rc _tmp
    _tmp=$(mktemp)
    PATH="$STUB_DIR:$PATH" bash -c "
        set -uo pipefail
        STATE_DIR='$STATE_DIR'
        NEXUS_ROOT='$NEXUS_ROOT'
        source '$PROBE'
        $*
    " >"$_tmp" 2>/dev/null
    _rc=$?
    _stdout=$(<"$_tmp"); rm -f "$_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_rc_var" '%s' "$_rc"
}

NOW=$(date +%s)
# Old timestamp = 2 minutes ago (above default 60s threshold).
OLD_TS=$(( NOW - 120 ))
# Young timestamp = 5 seconds ago (below threshold).
YOUNG_TS=$(( NOW - 5 ))

# Seed engagement-log rows from the current MOCK_TMUX_WINDOWS,
# stamping each window at its tmux window_activity epoch. Emulates
# the production state where the watcher has already observed
# each window at least once and the first-sight backfill (issue
# #44) has populated the engagement-log. Tests that expect a
# worker to surface as "really idle" via the engagement-anchored
# age gate must call this AFTER setting MOCK_TMUX_WINDOWS —
# otherwise the probe's first-observation backfill stamps every
# window at NOW, so age=0 < threshold and the window is filtered.
seed_engagement_log_matching_activity() {
    local elog="$STATE_DIR/engagement-log.tsv"
    : > "$elog"
    [[ -n "${MOCK_TMUX_WINDOWS:-}" ]] || return 0
    printf '%s\n' "$MOCK_TMUX_WINDOWS" \
        | awk -F'|' 'NF>=2 && $1 != "" { printf "%s\t%s\n", $1, $2 }' \
        >> "$elog"
}

# Write the per-window user-prompt stamp exactly as
# monitor/worker-heartbeat.sh does from the UserPromptSubmit hook
# (`<epoch>\t<session-id>`). THE operator-engagement trigger. Since the
# your-org/your-nexus#205 follow-up the trigger alone no longer marks
# a window — observed pane-content CHANGE within the decay TTL must
# corroborate it; tests simulate that with stamp_pane_change (or by
# advancing MOCK_CONTENT_HASH_<w> across probe cycles).
stamp_user_prompt() {
    local window="$1" epoch="${2:-$(date +%s)}"
    mkdir -p "$STATE_DIR/user-prompt"
    printf '%s\t%s\n' "$epoch" "test-session" > "$STATE_DIR/user-prompt/$window"
}

# Write the per-window pane-change stamp exactly as the probe's
# _openg_change_stamp does (`<last_hash>\t<last_change_epoch>`). The
# change-corroboration substrate (your-org/your-nexus#205 follow-up):
# `last_change_epoch` is the last cycle the transcript hash differed.
# A recent epoch corroborates a submit and keeps a mark valid; an old
# one lets the mark self-expire.
stamp_pane_change() {
    local window="$1" epoch="${2:-$(date +%s)}" hash="${3:-h$RANDOM}"
    mkdir -p "$STATE_DIR/pane-change"
    printf '%s\t%s\n' "$hash" "$epoch" > "$STATE_DIR/pane-change/$window"
}

# ---- Test 1: idle workers detected, busy ones skipped -------------------

echo '=== threshold + pane-state filter ==='
rm -f "$STATE_DIR/idle-state.tsv"
export MOCK_TMUX_WINDOWS="$(printf 'foo|%s\nbar|%s\nbaz|%s' "$OLD_TS" "$YOUNG_TS" "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_foo=idle
export MOCK_PANE_STATE_bar=idle
export MOCK_PANE_STATE_baz=busy
run_probe_capture out rc 'list_really_idle_workers'
assert_eq        "exit 0"                              "$rc"  "0"
assert_contains  "old + idle window included"          "$out" "foo"
assert_not_contains "young (below threshold) skipped"  "$out" "bar"
assert_not_contains "busy window skipped"              "$out" "baz"

# ---- Test 2: pane-state values that count as idle vs pane-absent vs skip --
#
# `idle` and `autosuggest-only` flow through wrap-up classification.
# `absent` and `blocked` fall into the inviolable `pane-absent` class
# (the inner Claude process is gone or the pane is sitting on a
# stalled overlay). Post-#72 rethink: `empty` no longer maps to
# `pane-absent` — pane-state.sh now distinguishes "renderer transient
# but claude alive" (state=empty) from "no claude in pane" (state=absent),
# so `empty` is a skip-and-retry-next-cycle signal at the probe layer.
# `user-typing` and `busy` are real engagement and never surface as idle.

echo '=== idle/autosuggest-only → idle classes; absent/blocked → pane-absent; empty → skip ==='
rm -f "$STATE_DIR/idle-state.tsv"
export MOCK_TMUX_WINDOWS="$(printf 'w1|%s\nw2|%s\nw3|%s\nw4|%s\nw5|%s' \
    "$OLD_TS" "$OLD_TS" "$OLD_TS" "$OLD_TS" "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_w1=idle
export MOCK_PANE_STATE_w2=autosuggest-only
export MOCK_PANE_STATE_w3=empty
export MOCK_PANE_STATE_w4=user-typing
export MOCK_PANE_STATE_w5=absent
run_probe_capture out rc 'list_really_idle_workers'
assert_contains  "idle → no-wrap-up"                   "$out" $'w1\tno-wrap-up'
assert_contains  "autosuggest-only → no-wrap-up"       "$out" $'w2\tno-wrap-up'
assert_not_contains "empty → skipped (no row)"         "$out" $'w3\t'
assert_not_contains "user-typing excluded"             "$out" $'w4\t'
assert_contains  "absent → pane-absent"                "$out" $'w5\tpane-absent'

# ---- Test 3: reserved windows excluded ---------------------------------

echo '=== watcher / claude / orchestrator / monitor never surfaced ==='
rm -f "$STATE_DIR/idle-state.tsv"
export MOCK_TMUX_WINDOWS="$(printf 'watcher|%s\nclaude|%s\norchestrator|%s\nmonitor|%s\nrealworker|%s' \
    "$OLD_TS" "$OLD_TS" "$OLD_TS" "$OLD_TS" "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_watcher=idle
export MOCK_PANE_STATE_claude=idle
export MOCK_PANE_STATE_orchestrator=idle
export MOCK_PANE_STATE_monitor=idle
export MOCK_PANE_STATE_realworker=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_not_contains "watcher excluded"                 "$out" "watcher"
assert_not_contains "claude excluded"                  "$out" "claude"
assert_not_contains "orchestrator excluded"            "$out" "orchestrator"
assert_not_contains "monitor excluded"                 "$out" "monitor"
assert_contains  "real worker included"                "$out" "realworker"

# ---- Test 3a1: transient sandbox-notify `•bell` windows dropped --------
#
# A bell from a hook subprocess (no controlling tty) makes sandbox-notify
# fall to its `tmux new-window -d -n '•bell'` path, spawning a transient
# window that — until this filter — leaked into the workspace-snapshot
# sweep with state=unknown/pane-absent. `_idle_list_worker_windows` now
# drops any `^•` row (matching snapshot_local + list_bell_windows), so the
# snapshot never surfaces a phantom bell window. (Start-anchoring — a
# mid-string `•` survives — is covered for the identical `^•` regex in
# test-snapshot-tmux-filter.sh Test 3.)
echo '=== •-prefixed sandbox-notify windows dropped from the sweep ==='
rm -f "$STATE_DIR/idle-state.tsv"
export MOCK_TMUX_WINDOWS="$(printf '•bell|%s\nrealworker|%s' \
    "$OLD_TS" "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_realworker=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_eq           "exit 0 (•bell present)"           "$rc"  "0"
assert_not_contains "•bell phantom row dropped"        "$out" "•bell"
assert_contains     "real worker still swept"          "$out" "realworker"

# ---- Test 3a2: cockpit `services` window exempted ----------------------
#
# your-org/your-nexus#204: the cockpit window (svc.sh dashboard, named
# `services` by entry.sh / svc.sh) runs a bash loop, NOT claude, so the
# pane-state probe finds no inner Claude process and would (wrongly)
# classify it `pane-absent` — "relaunch or close" against healthy infra.
# It must be exempt from the worker sweep alongside the orchestrator.
# `absent` pane-state is the strongest proof: it is the inviolable
# pane-absent class if the cockpit were treated as a worker. Second
# sub-case: a non-default cockpit name via SERVICES_WINDOW is honoured.
echo '=== cockpit services window exempted from the worker sweep ==='
rm -f "$STATE_DIR/idle-state.tsv"
export MOCK_TMUX_WINDOWS="$(printf 'services|%s\nrealworker|%s' "$OLD_TS" "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_services=absent
export MOCK_PANE_STATE_realworker=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_eq           "exit 0 (cockpit present)"         "$rc"  "0"
assert_not_contains "cockpit services exempted"        "$out" $'services\t'
assert_contains     "real worker still swept"          "$out" "realworker"
unset MOCK_PANE_STATE_services

echo '=== SERVICES_WINDOW override renames the exempt cockpit ==='
rm -f "$STATE_DIR/idle-state.tsv"
export MOCK_TMUX_WINDOWS="$(printf 'cockpit|%s\nservices|%s' "$OLD_TS" "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_cockpit=absent
export MOCK_PANE_STATE_services=absent
# run_probe_capture re-execs the probe in a fresh `bash -c`, so only an
# EXPORTED override propagates (matches how MOCK_* reach the subshell).
export SERVICES_WINDOW=cockpit
run_probe_capture out rc 'list_really_idle_workers'
assert_not_contains "renamed cockpit exempted"         "$out" $'cockpit\t'
assert_contains     "default name now swept"           "$out" $'services\tpane-absent'
unset SERVICES_WINDOW MOCK_PANE_STATE_cockpit MOCK_PANE_STATE_services

# ---- Test 3b: registry-declared service windows exempted ---------------
#
# Gap 2 (service-recovery-hardening, 2026-06-08): _idle_list_worker_windows
# must ALSO exempt windows whose name appears in monitor/services.registry
# (field 1). A healthy nginx/serve window (e.g. `demo-serve` on :8731)
# is infrastructure, not a dead worker, and must never trip the
# pane-absent "relaunch or close" alarm. Three sub-cases: registry name
# exempted; registry absent → unchanged (prior hardcoded set only); a
# malformed line is skipped and the sweep survives.

echo '=== registry service windows exempted from the worker sweep ==='
REG="$WORK/monitor/services.registry"
rm -f "$STATE_DIR/idle-state.tsv"
# A valid 4-field TAB record, plus a comment and a blank line to prove
# they're tolerated (mirrors bootstrap-recover.sh's parser).
{
    printf '# infra services\n'
    printf '\n'
    printf 'demo-serve\t%s\t./serve.sh\tcurl -fsS localhost:8731\n' "$WORK"
} > "$REG"
export MOCK_TMUX_WINDOWS="$(printf 'demo-serve|%s\nrealworker|%s' "$OLD_TS" "$OLD_TS")"
seed_engagement_log_matching_activity
# `absent` would be the inviolable pane-absent class if the service
# were (wrongly) treated as a worker — the strongest proof it's exempt.
export MOCK_PANE_STATE_demo_serve=absent
export MOCK_PANE_STATE_realworker=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_eq           "exit 0 (registry present)"        "$rc"  "0"
assert_not_contains "registry service exempted"        "$out" "demo-serve"
assert_contains     "real worker still swept"          "$out" "realworker"

echo '=== registry ABSENT → degrade to hardcoded exempt set ==='
rm -f "$REG" "$STATE_DIR/idle-state.tsv"
run_probe_capture out rc 'list_really_idle_workers'
assert_eq           "exit 0 (no registry)"             "$rc"  "0"
assert_contains     "no registry → service swept"      "$out" $'demo-serve\tpane-absent'
assert_contains     "real worker still swept (no reg)" "$out" "realworker"

echo '=== malformed registry line skipped, sweep survives ==='
rm -f "$STATE_DIR/idle-state.tsv"
{
    printf 'demo-serve\t%s\t./serve.sh\tcurl -fsS localhost:8731\n' "$WORK"
    printf 'broken-two-field\tonly-two-fields\n'
} > "$REG"
export MOCK_TMUX_WINDOWS="$(printf 'demo-serve|%s\nbroken-two-field|%s\nrealworker|%s' \
    "$OLD_TS" "$OLD_TS" "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_demo_serve=idle
export MOCK_PANE_STATE_broken_two_field=idle
export MOCK_PANE_STATE_realworker=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_eq           "exit 0 (malformed line)"          "$rc"  "0"
assert_not_contains "valid service still exempted"     "$out" $'demo-serve\t'
assert_contains     "malformed entry NOT exempted"     "$out" "broken-two-field"
assert_contains     "sweep survived → realworker"      "$out" "realworker"
rm -f "$REG"
unset MOCK_PANE_STATE_demo_serve MOCK_PANE_STATE_broken_two_field

# ---- Test 4: threshold override via env -------------------------------

echo '=== MONITOR_IDLE_THRESHOLD_SECONDS=10 honoured ==='
rm -f "$STATE_DIR/idle-state.tsv"
# 20s old, below default 60s, but above the env override of 10s.
# Fresh anchor: the looser-threshold (120s) assertion below asserts
# `tighten` is NOT surfaced because age (20s) < 120s; pinned to the
# top-of-test NOW it could age past 120s under a long parallel run
# (same wall-clock-coupling class as the justfinished/booting flakes,
# your-org/your-nexus#180 R3).
_seed_now=$(date +%s)
TS_15=$(( _seed_now - 20 ))
export MOCK_TMUX_WINDOWS="$(printf 'tighten|%s' "$TS_15")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_tighten=idle
run_probe_capture out rc 'MONITOR_IDLE_THRESHOLD_SECONDS=10 list_really_idle_workers'
assert_contains  "honours tighter threshold"           "$out" "tighten"
run_probe_capture out rc 'MONITOR_IDLE_THRESHOLD_SECONDS=120 list_really_idle_workers'
assert_not_contains "honours looser threshold"         "$out" "tighten"

# ---- Test 5: wrap-up classification ------------------------------------

echo '=== wrap-up classification: project-slot vs slug-slot ==='
rm -f "$STATE_DIR/idle-state.tsv"
# Seed action-log with wrap-up events covering both matching modes.
LOG="$STATE_DIR/action-log.jsonl"
cat > "$LOG" <<'EOF'
{"ts":"2026-05-10T16:00:00-07:00","agent":"monitor","event":"wrap-up","issue":"42","report":"proj-window_2026-05-10_120000_foo.md","upload":"ok","comment":"ok","rocket":"ok"}
{"ts":"2026-05-10T16:01:00-07:00","agent":"monitor","event":"wrap-up","issue":"99","report":"nexus_2026-05-10_130000_slug-window-task.md","upload":"ok","comment":"ok","rocket":"ok"}
{"ts":"2026-05-10T16:02:00-07:00","agent":"monitor","event":"some-other","issue":"77","report":"bystander_2026-05-10_140000_other.md"}
EOF
export MOCK_TMUX_WINDOWS="$(printf 'proj-window|%s\nslug-window|%s\nnomatch|%s' "$OLD_TS" "$OLD_TS" "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_proj_window=idle    # underscores per sanitization
export MOCK_PANE_STATE_slug_window=idle
export MOCK_PANE_STATE_nomatch=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_contains  "project-slot match → wrapped"        "$out" $'proj-window\twrapped'
assert_contains  "slug-slot match → wrapped"           "$out" $'slug-window\twrapped'
assert_contains  "no match → no-wrap-up"               "$out" $'nomatch\tno-wrap-up'

# ---- Test 5b: window-field match wins over basename heuristic ----------
#
# Issue #109: `ng wrap-up` now records the source tmux window in the
# action-log entry. The classifier should prefer that authoritative
# field and only fall back to the basename heuristic on legacy
# entries that lack it.

echo '=== wrap-up classification: window field (post-#109) is authoritative ==='
rm -f "$STATE_DIR/idle-state.tsv"
LOG="$STATE_DIR/action-log.jsonl"
# Three windows. authoritative-win has a wrap-up entry with the
# window field set to "authoritative-win" and a report basename
# whose project-slot is a DIFFERENT window — the basename heuristic
# would miss it; the window field must drive the match.
# legacy-win has a wrap-up entry with NO window field and a
# basename project-slot match — must still pair via fallback.
# stray-win has a wrap-up entry whose window field names some
# OTHER window — must NOT match stray-win even though the basename
# would (different-window basename match suppressed).
cat > "$LOG" <<'EOF'
{"event":"wrap-up","issue":"1","window":"authoritative-win","report":"nexus_2026-05-10_120000_unrelated-slug.md","upload":"ok","comment":"ok","rocket":"ok"}
{"event":"wrap-up","issue":"2","report":"legacy-win_2026-05-10_120100_old.md","upload":"ok","comment":"ok","rocket":"ok"}
{"event":"wrap-up","issue":"3","window":"some-other-window","report":"stray-win_2026-05-10_120200_thing.md","upload":"ok","comment":"ok","rocket":"ok"}
EOF
export MOCK_TMUX_WINDOWS="$(printf 'authoritative-win|%s\nlegacy-win|%s\nstray-win|%s' \
    "$OLD_TS" "$OLD_TS" "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_authoritative_win=idle
export MOCK_PANE_STATE_legacy_win=idle
export MOCK_PANE_STATE_stray_win=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_contains  "window-field match wins (authoritative-win wrapped)" "$out" \
                 $'authoritative-win\twrapped'
assert_contains  "legacy entry (no window field) still falls back to basename" "$out" \
                 $'legacy-win\twrapped'
assert_contains  "different-window field suppresses basename match" "$out" \
                 $'stray-win\tno-wrap-up'

# ---- Test 6: list_idle_transitions dedupes -----------------------------

echo '=== transitions: first cycle emits all, second cycle silenced ==='
rm -f "$STATE_DIR/idle-state.tsv"
export MOCK_TMUX_WINDOWS="$(printf 'aw|%s\nbw|%s' "$OLD_TS" "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_aw=idle
export MOCK_PANE_STATE_bw=idle
run_probe_capture first_out rc 'list_idle_transitions'
assert_contains "first cycle: aw surfaces"             "$first_out" "aw"
assert_contains "first cycle: bw surfaces"             "$first_out" "bw"
# Same MOCK_TMUX_WINDOWS + same classification on next call → empty
# (state file is now seeded).
run_probe_capture second_out rc 'list_idle_transitions'
assert_empty    "second cycle: nothing surfaces"        "$second_out"

# ---- Test 7: transition when wrap-up event lands ----------------------

echo '=== wrap-up arrives mid-idle → transition re-emits ==='
rm -f "$STATE_DIR/idle-state.tsv"
LOG="$STATE_DIR/action-log.jsonl"
: > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'fluxw|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_fluxw=idle
# First cycle: no wrap-up event, classified as no-wrap-up.
run_probe_capture out1 rc 'list_idle_transitions'
assert_contains  "first cycle: fluxw no-wrap-up"       "$out1" $'fluxw\tno-wrap-up'
# Now write a wrap-up event matching fluxw.
echo '{"event":"wrap-up","issue":"5","report":"fluxw_2026-05-10_150000_finished.md","upload":"ok","comment":"ok","rocket":"ok"}' >> "$LOG"
# Second cycle: classification flips to wrapped → re-emit.
run_probe_capture out2 rc 'list_idle_transitions'
assert_contains  "second cycle: fluxw wrapped"         "$out2" $'fluxw\twrapped'

# ---- Test 8: render_idle_section formatting ---------------------------

echo '=== render_idle_section formats both kinds ==='
rm -f "$STATE_DIR/idle-state.tsv"
LOG="$STATE_DIR/action-log.jsonl"
cat > "$LOG" <<'EOF'
{"event":"wrap-up","issue":"42","report":"alpha_2026-05-10_120000_done.md","upload":"ok","comment":"ok","rocket":"ok"}
EOF
export MOCK_TMUX_WINDOWS="$(printf 'alpha|%s\nbeta|%s' "$OLD_TS" "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_alpha=idle
export MOCK_PANE_STATE_beta=idle
run_probe_capture out rc 'render_idle_section'
assert_contains  "renders 'wrapped up'"                "$out" \
                 "- alpha wrapped up"
assert_contains  "renders 'WITHOUT wrap-up'"           "$out" \
                 "- beta idle"
assert_contains  "WITHOUT wrap-up wording"             "$out" \
                 "WITHOUT wrap-up"

# ---- Test 9: idle-too-long override ------------------------------------

echo '=== idle ≥ MONITOR_IDLE_CLOSE_HOURS → idle-too-long (overrides class) ==='
rm -f "$STATE_DIR/idle-state.tsv"
LOG="$STATE_DIR/action-log.jsonl"
: > "$LOG"
# 25h-old timestamp.
TS_25H=$(( NOW - 90100 ))
export MOCK_TMUX_WINDOWS="$(printf 'staleworker|%s' "$TS_25H")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_staleworker=idle
# Default close threshold is 24h.
run_probe_capture out rc 'MONITOR_IDLE_CLOSE_HOURS=24 list_really_idle_workers'
assert_contains  "row classified as idle-too-long" "$out" \
                 $'staleworker\tidle-too-long'
# A wrap-up event present doesn't matter — idle-too-long still wins.
echo '{"event":"wrap-up","issue":"1","report":"staleworker_2026-05-09_001122_done.md","upload":"ok","comment":"ok","rocket":"ok"}' >> "$LOG"
run_probe_capture out rc 'MONITOR_IDLE_CLOSE_HOURS=24 list_really_idle_workers'
assert_contains  "wrap-up present → still idle-too-long" "$out" \
                 $'staleworker\tidle-too-long'
# Loosening the threshold (50h) flips the classification back to
# wrapped — proves the override is threshold-gated, not unconditional.
run_probe_capture out rc 'MONITOR_IDLE_CLOSE_HOURS=50 list_really_idle_workers'
assert_contains  "looser threshold → wrapped"        "$out" \
                 $'staleworker\twrapped'
assert_not_contains "looser threshold suppresses too-long" "$out" \
                    "idle-too-long"

# ---- Test 10: wrapped-but-stub via report-check ------------------------

echo '=== wrap-up event + report fails report-check → wrapped-but-stub ==='
rm -f "$STATE_DIR/idle-state.tsv"
LOG="$STATE_DIR/action-log.jsonl"

# Build a tiny fake nexus tree so the probe finds reports/ and ng.
FAKE_NEXUS_8="$WORK/fake-nexus-8"
mkdir -p "$FAKE_NEXUS_8/monitor" "$FAKE_NEXUS_8/reports"
# Stub `ng` that responds to `report-check` based on the report's
# basename. A report whose basename contains "good" passes; one
# whose basename contains "stub" fails with a structured stderr
# matching what real ng emits. Anything else exits 2 (file
# missing).
cat > "$FAKE_NEXUS_8/monitor/ng" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "report-check" ]] || exit 0
path="${2:-}"
[[ -f "$path" ]] || { echo "ng report-check: file missing: $path" >&2; exit 2; }
base=$(basename "$path")
case "$base" in
    *good*)
        printf 'report-check: %s OK\n' "$base"; exit 0 ;;
    *stub*)
        {
            printf 'ng report-check: %s — incomplete:\n' "$base"
            printf '  - section: ## How to Resume\n'
            printf '  - body too short: 142 < 500 chars\n'
        } >&2
        exit 1 ;;
    *)  exit 0 ;;
esac
STUB
chmod +x "$FAKE_NEXUS_8/monitor/ng"
# Seed reports.
echo "complete content" > "$FAKE_NEXUS_8/reports/good-worker_2026-05-10_120000_done.md"
echo "stub content"     > "$FAKE_NEXUS_8/reports/stub-worker_2026-05-10_120000_partial.md"
# Action log with wrap-up events for both.
cat > "$LOG" <<'EOF'
{"event":"wrap-up","issue":"42","report":"good-worker_2026-05-10_120000_done.md","upload":"ok","comment":"ok","rocket":"ok"}
{"event":"wrap-up","issue":"43","report":"stub-worker_2026-05-10_120000_partial.md","upload":"ok","comment":"ok","rocket":"ok"}
EOF
# Make pane-state.sh also visible from the fake nexus root so the
# probe's `$NEXUS_ROOT/monitor/pane-state.sh` lookup succeeds.
cp "$STUB_DIR/pane-state.sh" "$FAKE_NEXUS_8/monitor/pane-state.sh"
export MOCK_TMUX_WINDOWS="$(printf 'good-worker|%s\nstub-worker|%s' "$OLD_TS" "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_good_worker=idle
export MOCK_PANE_STATE_stub_worker=idle
run_probe_capture out rc \
    "NEXUS_ROOT='$FAKE_NEXUS_8' list_really_idle_workers"
assert_contains  "complete report → wrapped"            "$out" \
                 $'good-worker\twrapped'
assert_contains  "stub report → wrapped-but-stub"       "$out" \
                 $'stub-worker\twrapped-but-stub'
assert_contains  "stub detail carries failed-field"     "$out" \
                 "How to Resume"

# ---- Test 11: render_idle_section formats all four classes -------------

echo '=== render_idle_section formats wrapped-but-stub + idle-too-long ==='
rm -f "$STATE_DIR/idle-state.tsv"
# Inject a hand-crafted current set bypassing list_really_idle_workers,
# by overriding the function in the sourced probe.
out=$(PATH="$STUB_DIR:$PATH" bash -c "
    set -uo pipefail
    STATE_DIR='$STATE_DIR'
    NEXUS_ROOT='$NEXUS_ROOT'
    source '$PROBE'
    list_really_idle_workers() {
        printf 'alpha\twrapped\t75\t\n'
        printf 'bravo\twrapped-but-stub\t90\tsection: ## How to Resume\n'
        printf 'cha-rlie\tno-wrap-up\t150\t\n'
        printf 'delta\tidle-too-long\t90000\t\n'
    }
    render_idle_section
" 2>/dev/null)
assert_contains  "alpha row renders 'wrapped up'"       "$out" \
                 "- alpha wrapped up"
assert_contains  "bravo row renders wrapped-but-stub"   "$out" \
                 "- bravo wrapped-but-stub"
assert_contains  "bravo row carries the missing section detail" "$out" \
                 "How to Resume"
assert_contains  "cha-rlie row renders WITHOUT wrap-up" "$out" \
                 "WITHOUT wrap-up"
assert_contains  "delta row renders idle-too-long"      "$out" \
                 "- delta idle-too-long"
assert_contains  "delta row formats age in h+m"         "$out" \
                 "25h"

# ---- Test 12: window-retain suppresses `wrapped` ----------------------
#
# A worker with a wrap-up event AND a recent window-retain event for
# the same window name should classify as `retained` (collated into
# the footer) rather than `wrapped` (per-row emit).

echo '=== idle-orphan-async surfaced with offending job ids (issue #183) ==='
# pane-state.sh emits state=idle-orphan-async + orphan_kinds=<csv>
# for a worker whose heartbeat declared external_waits but no
# resume mechanism. The probe should:
#   - never suppress idle-orphan-async via window-retain;
#   - carry the orphan_kinds csv through as the detail column;
#   - stamp engagement-log when state is working-background/
#     working-self-paced so retained-workers aren't garbage-
#     collected mid-monitor.

rm -f "$STATE_DIR/idle-state.tsv"
LOG="$STATE_DIR/action-log.jsonl"
: > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'orphw|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_orphw=idle-orphan-async
export MOCK_ORPHAN_KINDS_orphw="slurm:52527284_4,ci:abc/runs/9"
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "orphan-async → row emitted" "$out" \
    $'orphw\tidle-orphan-async'
assert_contains "orphan-async row carries orphan_kinds csv as detail" "$out" \
    "slurm:52527284_4,ci:abc/runs/9"

# window-retain MUST NOT suppress idle-orphan-async.
rm -f "$STATE_DIR/idle-state.tsv"
RETAIN_TS=$(date -Is -d "@$(( OLD_TS + 10 ))")
cat > "$LOG" <<EOF
{"ts":"$RETAIN_TS","agent":"monitor","event":"window-retain","window":"orphw","reason":"loaded-context"}
EOF
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "retain does NOT suppress idle-orphan-async" "$out" \
    $'orphw\tidle-orphan-async'
assert_not_contains "no retained row when class is orphan-async" "$out" \
    $'orphw\tretained'

# working-background and working-self-paced never reach the idle pool.
rm -f "$STATE_DIR/idle-state.tsv"
: > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'wbgw|%s\nwspw|%s' "$OLD_TS" "$OLD_TS")"
seed_engagement_log_matching_activity
unset MOCK_ORPHAN_KINDS_orphw
export MOCK_PANE_STATE_wbgw=working-background
export MOCK_PANE_STATE_wspw=working-self-paced
run_probe_capture out rc 'list_really_idle_workers'
assert_not_contains "working-background suppressed from idle pool" "$out" \
    "wbgw"
assert_not_contains "working-self-paced suppressed from idle pool" "$out" \
    "wspw"

echo '=== render_idle_section renders the orphan-async advisory ==='
rm -f "$STATE_DIR/idle-state.tsv"
out=$(PATH="$STUB_DIR:$PATH" bash -c "
    set -uo pipefail
    STATE_DIR='$STATE_DIR'
    NEXUS_ROOT='$NEXUS_ROOT'
    source '$PROBE'
    list_really_idle_workers() {
        printf 'orphw\tidle-orphan-async\t120\tslurm:52527284_4\n'
    }
    render_idle_section
" 2>/dev/null)
assert_contains  "orphan-async advisory line"           "$out" \
                 "orphw idle-orphan-async"
assert_contains  "advisory quotes the offending job"    "$out" \
                 "slurm:52527284_4"
assert_contains  "advisory points at the contract"      "$out" \
                 "worker-defaults"

echo '=== prelude carries orphan-async axis ==='
rm -f "$STATE_DIR/idle-state.tsv"
: > "$LOG"
# Two workers: one busy, one orphan-async. The render_idle_prelude
# tally should reflect both.
export MOCK_TMUX_WINDOWS="$(printf 'workingw|%s\norphw|%s' "$OLD_TS" "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_workingw=busy
export MOCK_PANE_STATE_orphw=idle-orphan-async
export MOCK_ORPHAN_KINDS_orphw="slurm:1"
run_probe_capture out rc 'render_idle_prelude'
assert_contains "prelude includes orphan-async axis" "$out" "orphan-async"
assert_contains "prelude tallies one orphan-async"   "$out" "1 orphan-async"

echo '=== Bug 3: prelude separates parked-awaiting-skeptic from busy ==='
rm -f "$STATE_DIR/idle-state.tsv"
: > "$LOG"
# Two idle-aged workers: one genuinely busy, one parked on a LIVE
# skeptic-pending marker. The parked worker is exempt from idle/close
# (class parked-awaiting-skeptic) — NOT idle, but NOT busy either. Before
# the fix it fell into the `total - idle_total` residue and inflated
# "busy"; now it has its own `parked-skeptic` axis and is excluded from
# busy. This is the "all 11 busy" misreport the operator saw after merging.
export MOCK_TMUX_WINDOWS="$(printf 'busyw|%s\nparkw|%s' "$OLD_TS" "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_busyw=busy
export MOCK_PANE_STATE_parkw=idle
mkdir -p "$STATE_DIR/skeptic/pending"
echo 1 > "$STATE_DIR/skeptic/pending/parkw"   # fresh marker → live park
run_probe_capture out rc 'render_idle_prelude'
assert_contains "prelude includes parked-skeptic axis" "$out" "parked-skeptic"
assert_contains "prelude tallies one parked-skeptic"   "$out" "1 parked-skeptic"
assert_contains "parked worker excluded from busy (only the busy one)" "$out" "1 busy"
# Mutation guard: clearing the marker re-classifies the worker as a normal
# idle/no-wrap-up worker — parked-skeptic drops to 0 (proves the axis is
# driven by the live marker, not a constant).
rm -f "$STATE_DIR/skeptic/pending/parkw"
rm -f "$STATE_DIR/idle-state.tsv"
run_probe_capture out rc 'render_idle_prelude'
assert_contains "marker cleared -> 0 parked-skeptic" "$out" "0 parked-skeptic"
unset MOCK_PANE_STATE_busyw MOCK_PANE_STATE_parkw

echo '=== window-retain suppresses wrapped class ==='
rm -f "$STATE_DIR/idle-state.tsv"
LOG="$STATE_DIR/action-log.jsonl"
# Retain ts must be AFTER the window's activity epoch so the retain
# is not considered consumed by post-retain activity.
RETAIN_TS=$(date -Is -d "@$(( OLD_TS + 10 ))")
cat > "$LOG" <<EOF
{"ts":"$(date -Is -d "@$OLD_TS")","agent":"monitor","event":"wrap-up","issue":"42","report":"echoworker_2026-05-10_120000_done.md","upload":"ok","comment":"ok","rocket":"ok"}
{"ts":"$RETAIN_TS","agent":"monitor","event":"window-retain","window":"echoworker","reason":"loaded-context-dm-kernel-figures"}
EOF
export MOCK_TMUX_WINDOWS="$(printf 'echoworker|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_echoworker=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_contains  "wrapped + retain → retained"        "$out" \
                 $'echoworker\tretained'
assert_not_contains "no wrapped row when retained"     "$out" \
                    $'echoworker\twrapped'
assert_contains  "retained row carries the reason"    "$out" \
                 "loaded-context-dm-kernel-figures"

# ---- Test 13: window-retain suppresses `no-wrap-up` -------------------

echo '=== window-retain suppresses no-wrap-up class ==='
rm -f "$STATE_DIR/idle-state.tsv"
LOG="$STATE_DIR/action-log.jsonl"
RETAIN_TS=$(date -Is -d "@$(( OLD_TS + 10 ))")
cat > "$LOG" <<EOF
{"ts":"$RETAIN_TS","agent":"monitor","event":"window-retain","window":"repltime-histones","reason":"open-ended-issue-81-prs-await-review"}
EOF
export MOCK_TMUX_WINDOWS="$(printf 'repltime-histones|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_repltime_histones=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_contains  "no-wrap-up + retain → retained"      "$out" \
                 $'repltime-histones\tretained'
assert_not_contains "no no-wrap-up row when retained"  "$out" \
                    $'repltime-histones\tno-wrap-up'

# ---- Test 14: retain does NOT suppress `wrapped-but-stub` -------------

echo '=== window-retain does NOT suppress wrapped-but-stub ==='
rm -f "$STATE_DIR/idle-state.tsv"
LOG="$STATE_DIR/action-log.jsonl"
# Reuse FAKE_NEXUS_8's stub `ng` from Test 10 (stub report fails check).
FAKE_NEXUS_14="$WORK/fake-nexus-14"
mkdir -p "$FAKE_NEXUS_14/monitor" "$FAKE_NEXUS_14/reports"
cp "$FAKE_NEXUS_8/monitor/ng" "$FAKE_NEXUS_14/monitor/ng"
cp "$STUB_DIR/pane-state.sh" "$FAKE_NEXUS_14/monitor/pane-state.sh"
echo "stub content" > "$FAKE_NEXUS_14/reports/stubworker_2026-05-10_120000_partial.md"
RETAIN_TS=$(date -Is -d "@$(( OLD_TS + 10 ))")
cat > "$FAKE_NEXUS_14/.state-action-log.jsonl" <<EOF
{"ts":"$(date -Is -d "@$OLD_TS")","agent":"monitor","event":"wrap-up","issue":"77","report":"stubworker_2026-05-10_120000_partial.md","upload":"ok","comment":"ok","rocket":"ok"}
{"ts":"$RETAIN_TS","agent":"monitor","event":"window-retain","window":"stubworker","reason":"do-not-suppress-me"}
EOF
# Point STATE_DIR at the fake-nexus's action-log location for this test.
STUB_STATE_14="$WORK/state-14"
mkdir -p "$STUB_STATE_14"
cp "$FAKE_NEXUS_14/.state-action-log.jsonl" "$STUB_STATE_14/action-log.jsonl"
# Seed engagement-log in the test-specific STATE_DIR override.
# (seed_engagement_log_matching_activity targets the outer
# $STATE_DIR; here the probe runs against $STUB_STATE_14.)
printf 'stubworker\t%s\n' "$OLD_TS" > "$STUB_STATE_14/engagement-log.tsv"
export MOCK_TMUX_WINDOWS="$(printf 'stubworker|%s' "$OLD_TS")"
export MOCK_PANE_STATE_stubworker=idle
run_probe_capture out rc \
    "STATE_DIR='$STUB_STATE_14' NEXUS_ROOT='$FAKE_NEXUS_14' list_really_idle_workers"
assert_contains  "wrapped-but-stub survives retain"    "$out" \
                 $'stubworker\twrapped-but-stub'
assert_not_contains "retained does not appear"         "$out" \
                    $'stubworker\tretained'

# ---- Test 15: retain does NOT suppress `idle-too-long` ----------------

echo '=== window-retain does NOT suppress idle-too-long ==='
rm -f "$STATE_DIR/idle-state.tsv"
LOG="$STATE_DIR/action-log.jsonl"
TS_25H=$(( NOW - 90100 ))
RETAIN_TS=$(date -Is -d "@$(( TS_25H + 10 ))")
cat > "$LOG" <<EOF
{"ts":"$RETAIN_TS","agent":"monitor","event":"window-retain","window":"staleworker","reason":"trying-to-mute-me"}
EOF
export MOCK_TMUX_WINDOWS="$(printf 'staleworker|%s' "$TS_25H")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_staleworker=idle
run_probe_capture out rc 'MONITOR_IDLE_CLOSE_HOURS=24 list_really_idle_workers'
assert_contains  "idle-too-long survives retain"        "$out" \
                 $'staleworker\tidle-too-long'
assert_not_contains "retained does not appear"          "$out" \
                    $'staleworker\tretained'

# ---- Test 16: retain consumed by engagement-log epoch > retain.ts -----
#
# Spec change (issue #111): the retain-consume gate compares the
# *engagement-log* epoch against retain.ts, NOT tmux's
# #{window_activity}. Engagement = pane-state observed as
# `busy` or `user-typing`. Autosuggest re-renders / cursor blinks /
# status-bar ticks bump #{window_activity} without engagement, so
# the old gate was too loose. Test the new gate: pre-stamp the
# engagement-log with an epoch between retain.ts and now → retain
# consumed → no-wrap-up surfaces.

echo '=== retain consumed when engagement-log epoch post-dates retain.ts ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv"
LOG="$STATE_DIR/action-log.jsonl"
TS_ACTIVITY=$(( NOW - 120 ))      # 2 min ago
TS_ENGAGEMENT=$(( NOW - 60 ))     # 1 min ago — between retain.ts and now
TS_RETAIN=$(( NOW - 300 ))        # 5 min ago
RETAIN_TS_ISO=$(date -Is -d "@$TS_RETAIN")
cat > "$LOG" <<EOF
{"ts":"$RETAIN_TS_ISO","agent":"monitor","event":"window-retain","window":"consumed","reason":"i-am-stale"}
EOF
# Pre-populate engagement-log with a stamp post retain.ts.
printf '%s\t%s\n' consumed "$TS_ENGAGEMENT" > "$STATE_DIR/engagement-log.tsv"
export MOCK_TMUX_WINDOWS="$(printf 'consumed|%s' "$TS_ACTIVITY")"
export MOCK_PANE_STATE_consumed=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_contains  "engagement post-retain → no-wrap-up surfaces" "$out" \
                 $'consumed\tno-wrap-up'
assert_not_contains "stale retain does NOT suppress"             "$out" \
                    $'consumed\tretained'

# ---- Test 17: TTL boundary --------------------------------------------
#
# A retain older than MONITOR_RETAIN_TTL_SECONDS is ignored even if
# no activity has happened since.

echo '=== retain past TTL is ignored ==='
rm -f "$STATE_DIR/idle-state.tsv"
LOG="$STATE_DIR/action-log.jsonl"
# Activity 30 hours ago (well past 60s threshold but well under the
# 24h close threshold of test 9 ... we set close threshold to 99h to
# isolate the TTL behaviour from idle-too-long).
TS_OLD=$(( NOW - 30 * 3600 ))
# Retain BEFORE that activity → activity_epoch > retain.ts → retain
# is already consumed by that path. To isolate the TTL test, put
# retain AFTER activity but past TTL: retain at 5h ago > activity
# at 30h ago, and TTL=3600 (1h) means retain is too old.
TS_RETAIN=$(( NOW - 5 * 3600 ))
RETAIN_TS_ISO=$(date -Is -d "@$TS_RETAIN")
cat > "$LOG" <<EOF
{"ts":"$RETAIN_TS_ISO","agent":"monitor","event":"window-retain","window":"ttlworker","reason":"too-old-to-matter"}
EOF
export MOCK_TMUX_WINDOWS="$(printf 'ttlworker|%s' "$TS_OLD")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_ttlworker=idle
# TTL=3600 → 1h ago is the boundary; retain at 5h is well past it.
# CLOSE_HOURS=99 keeps us out of the idle-too-long override.
run_probe_capture out rc \
    'MONITOR_RETAIN_TTL_SECONDS=3600 MONITOR_IDLE_CLOSE_HOURS=99 list_really_idle_workers'
assert_contains  "past-TTL retain ignored, no-wrap-up surfaces" "$out" \
                 $'ttlworker\tno-wrap-up'
assert_not_contains "past-TTL retain does NOT suppress"          "$out" \
                    $'ttlworker\tretained'
# And the inverse: TTL=86400 (default) → the same 5h-old retain WOULD
# suppress (when activity post-dates retain.ts so the retain isn't
# already consumed). Move retain to 5h ago and activity to 6h ago.
TS_OLD=$(( NOW - 6 * 3600 ))
export MOCK_TMUX_WINDOWS="$(printf 'ttlworker|%s' "$TS_OLD")"
seed_engagement_log_matching_activity
run_probe_capture out rc \
    'MONITOR_RETAIN_TTL_SECONDS=86400 MONITOR_IDLE_CLOSE_HOURS=99 list_really_idle_workers'
assert_contains  "within-TTL retain suppresses"                  "$out" \
                 $'ttlworker\tretained'

# ---- Test 18: render_idle_section produces the footer ----------------

echo '=== render_idle_section renders the retained footer ==='
rm -f "$STATE_DIR/idle-state.tsv"
# Inject three retained rows + one wrapped row directly (bypass
# list_really_idle_workers to isolate footer rendering).
out=$(PATH="$STUB_DIR:$PATH" bash -c "
    set -uo pipefail
    STATE_DIR='$STATE_DIR'
    NEXUS_ROOT='$NEXUS_ROOT'
    source '$PROBE'
    list_really_idle_workers() {
        printf 'foo-window\twrapped\t60\t\n'
        printf 'echo-density\tretained\t3600\tloaded-context-dm-kernel-figures\n'
        printf 'repltime-histones\tretained\t7200\topen-ended-issue-81-prs-await-review\n'
        printf 'nexus-self-fix-wrap-up\tretained\t900\tpost-merge-loaded-context\n'
    }
    render_idle_section
" 2>/dev/null)
assert_contains  "wrapped row renders normally"          "$out" \
                 "- foo-window wrapped up"
assert_contains  "footer prefix shows count"             "$out" \
                 "(3 retained windows suppressed:"
assert_contains  "footer lists echo-density"             "$out" \
                 "echo-density (loaded-context-dm-kernel-figures)"
assert_contains  "footer lists repltime-histones"        "$out" \
                 "repltime-histones (open-ended-issue-81-prs-await-review)"
assert_contains  "footer lists nexus-self-fix-wrap-up"   "$out" \
                 "nexus-self-fix-wrap-up (post-merge-loaded-context)"
# Sanity: no per-window "retained" row in the body.
assert_not_contains "no per-row retained line"            "$out" \
                    "  - echo-density"

# ---- Test 19: footer truncates long reasons ---------------------------

echo '=== render_idle_section truncates reasons over 40 chars ==='
rm -f "$STATE_DIR/idle-state.tsv"
LONG_REASON="this-is-a-very-long-reason-that-exceeds-forty-chars-easily"
out=$(PATH="$STUB_DIR:$PATH" bash -c "
    set -uo pipefail
    STATE_DIR='$STATE_DIR'
    NEXUS_ROOT='$NEXUS_ROOT'
    source '$PROBE'
    list_really_idle_workers() {
        printf 'bigreason\tretained\t60\t$LONG_REASON\n'
    }
    render_idle_section
" 2>/dev/null)
assert_contains  "footer truncates long reason with ellipsis" "$out" "…"
assert_not_contains "untruncated reason absent"               "$out" \
                    "$LONG_REASON"

# ---- Test 20: suppressed-set dedupe (footer re-emit only on change) --

echo '=== suppressed-set dedupe: same set → no footer; change → footer ==='
rm -f "$STATE_DIR/idle-state.tsv"
LOG="$STATE_DIR/action-log.jsonl"
RETAIN_TS_A=$(date -Is -d "@$(( OLD_TS + 10 ))")
cat > "$LOG" <<EOF
{"ts":"$RETAIN_TS_A","agent":"monitor","event":"window-retain","window":"alpharetain","reason":"alpha-reason"}
{"ts":"$RETAIN_TS_A","agent":"monitor","event":"window-retain","window":"betaretain","reason":"beta-reason"}
EOF
export MOCK_TMUX_WINDOWS="$(printf 'alpharetain|%s\nbetaretain|%s' "$OLD_TS" "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_alpharetain=idle
export MOCK_PANE_STATE_betaretain=idle
# Cycle 1: both windows go from "not tracked" to retained → footer emits.
run_probe_capture out1 rc 'render_idle_section'
assert_contains  "cycle 1: footer with both retained rows" "$out1" \
                 "2 retained windows suppressed"
assert_contains  "cycle 1: alpharetain listed"             "$out1" "alpharetain"
assert_contains  "cycle 1: betaretain listed"              "$out1" "betaretain"
# Cycle 2: identical state → no footer (dedupe).
run_probe_capture out2 rc 'render_idle_section'
assert_empty    "cycle 2: identical set silenced"           "$out2"
# Cycle 3: drop betaretain by removing the tmux window → set
# changed → footer re-emits showing only alpharetain.
export MOCK_TMUX_WINDOWS="$(printf 'alpharetain|%s' "$OLD_TS")"
run_probe_capture out3 rc 'render_idle_section'
assert_contains  "cycle 3: footer re-emits on removal"     "$out3" \
                 "1 retained windows suppressed"
assert_contains  "cycle 3: alpharetain still listed"       "$out3" "alpharetain"
assert_not_contains "cycle 3: betaretain dropped"          "$out3" "betaretain"

# ---- Test 21: retain survives cursor/render activity ------------------
#
# Reproduces the echo-density bug from issue #111 directly. The
# tmux #{window_activity} epoch advances post retain.ts (autosuggest
# blink, cursor move, status-bar tick) but pane-state stays idle.
# Pre-fix, `(( activity_epoch <= retain_ts_epoch ))` consumed the
# retain. Post-fix, only engagement (busy / user-typing) consumes —
# so the retain must hold.

echo '=== retain survives tmux activity bump without engagement ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv"
LOG="$STATE_DIR/action-log.jsonl"
# Retain 30 min ago; tmux activity 5 min ago (post-retain).
# Under the old gate, the retain would be consumed.
TS_ACTIVITY=$(( NOW - 300 ))
TS_RETAIN=$(( NOW - 1800 ))
RETAIN_TS_ISO=$(date -Is -d "@$TS_RETAIN")
cat > "$LOG" <<EOF
{"ts":"$RETAIN_TS_ISO","agent":"monitor","event":"window-retain","window":"renderbump","reason":"context-loaded"}
EOF
# Engagement long ago (before retain.ts) → retain holds. Post-#44
# backfill stamps every observed window at first sight, so we can't
# rely on the "missing row" sentinel; explicitly model "engaged
# pre-retain" by seeding an engagement-log epoch < retain.ts.
printf 'renderbump\t%s\n' "$(( TS_RETAIN - 60 ))" > "$STATE_DIR/engagement-log.tsv"
export MOCK_TMUX_WINDOWS="$(printf 'renderbump|%s' "$TS_ACTIVITY")"
export MOCK_PANE_STATE_renderbump=autosuggest-only
run_probe_capture out rc 'list_really_idle_workers'
assert_contains  "activity bump without engagement → retained"    "$out" \
                 $'renderbump\tretained'
assert_not_contains "no no-wrap-up row when retain still holds"    "$out" \
                    $'renderbump\tno-wrap-up'
assert_contains  "retained row carries the reason"                "$out" \
                 "context-loaded"

# ---- Test 22: retain consumed by busy stamp ---------------------------
#
# Pre-populate engagement-log with a `busy` epoch between
# retain.ts and now → retain is consumed → base class surfaces.

echo '=== retain consumed by engagement-log busy stamp ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv"
LOG="$STATE_DIR/action-log.jsonl"
TS_RETAIN=$(( NOW - 1800 ))       # 30 min ago
TS_BUSY=$(( NOW - 900 ))          # 15 min ago — between retain.ts and now
RETAIN_TS_ISO=$(date -Is -d "@$TS_RETAIN")
cat > "$LOG" <<EOF
{"ts":"$RETAIN_TS_ISO","agent":"monitor","event":"window-retain","window":"busyworker","reason":"do-not-suppress"}
EOF
printf '%s\t%s\n' busyworker "$TS_BUSY" > "$STATE_DIR/engagement-log.tsv"
# Activity 5 min ago — pane currently idle (engagement finished).
export MOCK_TMUX_WINDOWS="$(printf 'busyworker|%s' "$(( NOW - 300 ))")"
export MOCK_PANE_STATE_busyworker=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_contains  "busy-stamp post-retain → no-wrap-up"            "$out" \
                 $'busyworker\tno-wrap-up'
assert_not_contains "retain consumed; no retained row"            "$out" \
                    $'busyworker\tretained'

# ---- Test 23: retain consumed by user-typing stamp --------------------
#
# Same as Test 22 but the engagement marker stamp came from a
# `user-typing` observation. Engagement-log doesn't record which
# state, just the epoch — both paths land here.

echo '=== retain consumed by engagement-log user-typing stamp ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv"
LOG="$STATE_DIR/action-log.jsonl"
TS_RETAIN=$(( NOW - 1800 ))
TS_TYPING=$(( NOW - 600 ))        # 10 min ago, post-retain
RETAIN_TS_ISO=$(date -Is -d "@$TS_RETAIN")
cat > "$LOG" <<EOF
{"ts":"$RETAIN_TS_ISO","agent":"monitor","event":"window-retain","window":"typer","reason":"do-not-suppress"}
EOF
printf '%s\t%s\n' typer "$TS_TYPING" > "$STATE_DIR/engagement-log.tsv"
export MOCK_TMUX_WINDOWS="$(printf 'typer|%s' "$(( NOW - 120 ))")"
export MOCK_PANE_STATE_typer=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_contains  "user-typing stamp post-retain → no-wrap-up"     "$out" \
                 $'typer\tno-wrap-up'
assert_not_contains "retain consumed; no retained row"            "$out" \
                    $'typer\tretained'

# ---- Test 24: engagement-log persists across cycles -------------------
#
# Post-#44 (backfill on first observation): EVERY observed window
# gets a row at first sight, regardless of pane-state. Subsequent
# busy / user-typing observations update the row with the current
# epoch (engagement is a high-water mark; backfill is the floor).
# At-most-one row per window.

echo '=== engagement-log: probe stamps every observed window (busy or idle) ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv"
LOG="$STATE_DIR/action-log.jsonl"
: > "$LOG"
ELOG="$STATE_DIR/engagement-log.tsv"
# Cycle 1: cyc1 is busy, cyc2 is idle. After: BOTH have rows
# (cyc1 via busy stamp = NOW; cyc2 via backfill = NOW).
export MOCK_TMUX_WINDOWS="$(printf 'cyc1|%s\ncyc2|%s' "$YOUNG_TS" "$YOUNG_TS")"
export MOCK_PANE_STATE_cyc1=busy
export MOCK_PANE_STATE_cyc2=idle
run_probe_capture _ rc 'list_really_idle_workers'
assert_eq        "engagement-log exists after cycle 1"            \
                 "$( [[ -f "$ELOG" ]] && echo yes || echo no )"   "yes"
assert_eq        "cyc1 row count == 1 (busy stamped)"             \
                 "$(awk -F'\t' '$1=="cyc1"' "$ELOG" | wc -l)"     "1"
assert_eq        "cyc2 row count == 1 (backfilled on first sight)" \
                 "$(awk -F'\t' '$1=="cyc2"' "$ELOG" | wc -l)"     "1"
# Cycle 2: cyc1 now idle, cyc2 now user-typing. Both rows persist
# (engagement is a high-water mark, never decremented); cyc1 row
# stays at its busy timestamp, cyc2 row advances to user-typing
# stamp.
export MOCK_PANE_STATE_cyc1=idle
export MOCK_PANE_STATE_cyc2=user-typing
run_probe_capture _ rc 'list_really_idle_workers'
assert_eq        "cyc1 row still present after cycle 2"           \
                 "$(awk -F'\t' '$1=="cyc1"' "$ELOG" | wc -l)"     "1"
assert_eq        "cyc2 row count == 1 (user-typing stamped)"      \
                 "$(awk -F'\t' '$1=="cyc2"' "$ELOG" | wc -l)"     "1"
# Cycle 3: cyc2 busy again — its row updates with the newer epoch.
TS_BEFORE_C3=$(awk -F'\t' '$1=="cyc2" {print $2}' "$ELOG")
sleep 1   # ensure NOW advances at least 1 second
export MOCK_PANE_STATE_cyc2=busy
run_probe_capture _ rc 'list_really_idle_workers'
TS_AFTER_C3=$(awk -F'\t' '$1=="cyc2" {print $2}' "$ELOG")
assert_eq        "cyc2 still at-most-one row after cycle 3"       \
                 "$(awk -F'\t' '$1=="cyc2"' "$ELOG" | wc -l)"     "1"
if (( TS_AFTER_C3 > TS_BEFORE_C3 )); then
    printf '  PASS: cyc2 row epoch advanced (%s → %s)\n' \
        "$TS_BEFORE_C3" "$TS_AFTER_C3"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: cyc2 row epoch did not advance (%s → %s)\n' \
        "$TS_BEFORE_C3" "$TS_AFTER_C3" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 25: helper-level sentinel for missing engagement-log rows ---
#
# Post-#44 (backfill on first observation), `list_really_idle_workers`
# no longer reaches the "missing row" code path — every observed
# window gets a row at first sight. The sentinel semantic in
# `_engagement_log_lookup` (missing row → empty stdout, exit 0)
# still exists at the helper level, and the retain-consume gate
# still coerces empty → 0 so retain holds when a row really is
# missing. Verify the helper-level contract directly.

echo '=== _engagement_log_lookup: missing row → empty stdout, exit 0 ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv"
# Empty file (zero rows) — distinct from "no file".
: > "$STATE_DIR/engagement-log.tsv"
run_probe_capture out rc \
    'echo "got=[$(_engagement_log_lookup neverseen)] rc=$?"'
assert_contains  "empty engagement-log: lookup prints nothing"    "$out" \
                 "got=[]"
assert_contains  "empty engagement-log: lookup exits 0"           "$out" \
                 "rc=0"
# Now delete the file entirely.
rm -f "$STATE_DIR/engagement-log.tsv"
run_probe_capture out rc \
    'echo "got=[$(_engagement_log_lookup neverseen)] rc=$?"'
assert_contains  "absent engagement-log: lookup prints nothing"   "$out" \
                 "got=[]"
assert_contains  "absent engagement-log: lookup exits 0"          "$out" \
                 "rc=0"

# ---- Test 26: state=absent → pane-absent ------------------------------
#
# Inner Claude process has died; pane fell back to shell prompt
# (no `❯<NBSP>` input row). pane-state.sh returns state=absent.
# Classifier must emit pane-absent regardless of wrap-up presence.

echo '=== state=absent → pane-absent ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv"
LOG="$STATE_DIR/action-log.jsonl"
: > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'crashed|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_crashed=absent
run_probe_capture out rc 'list_really_idle_workers'
assert_contains  "absent pane-state → pane-absent"                "$out" \
                 $'crashed\tpane-absent'
assert_contains  "pane-absent carries advisory detail"            "$out" \
                 "claude process gone or unresponsive"
# Even with a wrap-up event present, pane-absent still wins.
echo '{"event":"wrap-up","issue":"77","window":"crashed","report":"crashed_2026-05-11_120000_done.md","upload":"ok","comment":"ok","rocket":"ok"}' >> "$LOG"
run_probe_capture out rc 'list_really_idle_workers'
assert_contains  "wrap-up present, still pane-absent"             "$out" \
                 $'crashed\tpane-absent'
assert_not_contains "pane-absent shadows wrapped"                  "$out" \
                    $'crashed\twrapped'

# ---- Test 27: state=blocked → pane-absent -----------------------------
#
# Pane sitting on an unhandled overlay (permission prompt the
# unstick library couldn't dismiss, or a rate-limit modal).
# pane-state.sh returns state=blocked. Classifier emits pane-absent.

echo '=== state=blocked → pane-absent ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv"
LOG="$STATE_DIR/action-log.jsonl"
: > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'stalled|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_stalled=blocked
run_probe_capture out rc 'list_really_idle_workers'
assert_contains  "blocked pane-state → pane-absent"               "$out" \
                 $'stalled\tpane-absent'

# ---- Test 28: state=empty → skip (no row) -----------------------------
#
# Pane-state.sh now distinguishes "renderer transient but claude alive"
# (state=empty) from "no claude in pane" (state=absent). The probe
# treats `empty` as a skip-and-retry-next-cycle signal — the pane is
# alive but the renderer hasn't landed on a stable rule yet (mid-paste,
# status-bar swap, etc.). NO row is emitted; on a subsequent cycle when
# the renderer settles, the worker re-enters classification with its
# real state (idle / busy / etc.). This closes the regression where
# `empty` false-positives produced `pane-absent` emits on actively
# busy workers (issue #72 regression 2).

echo '=== state=empty → skipped (no row) ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv"
LOG="$STATE_DIR/action-log.jsonl"
: > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'ambiguous|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_ambiguous=empty
run_probe_capture out rc 'list_really_idle_workers'
assert_not_contains "empty pane-state → skipped"                  "$out" \
                    "ambiguous"

# ---- Test 29: pane-absent ignores window-retain -----------------------
#
# Inviolable like idle-too-long. A crash signal must surface even
# if the orchestrator earlier logged a retain — the retain reason
# (loaded context, open-ended scope, etc.) is moot when the
# Claude process is no longer running.

echo '=== pane-absent ignores window-retain (inviolable) ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv"
LOG="$STATE_DIR/action-log.jsonl"
RETAIN_TS=$(date -Is -d "@$(( OLD_TS + 10 ))")
cat > "$LOG" <<EOF
{"ts":"$RETAIN_TS","agent":"monitor","event":"window-retain","window":"deadbutsaved","reason":"trying-to-mute-the-crash"}
EOF
export MOCK_TMUX_WINDOWS="$(printf 'deadbutsaved|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_deadbutsaved=absent
run_probe_capture out rc 'list_really_idle_workers'
assert_contains  "pane-absent survives retain"                    "$out" \
                 $'deadbutsaved\tpane-absent'
assert_not_contains "retained does not appear"                     "$out" \
                    $'deadbutsaved\tretained'

# ---- Test 30: pane-absent dedupes across cycles -----------------------
#
# The state is hooked into idle-state.tsv on (window, class) like
# the other classes — first transition emits, identical-state
# second cycle is silenced.

echo '=== pane-absent dedupes (transition emit, stable silenced) ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv"
LOG="$STATE_DIR/action-log.jsonl"
: > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'flapping|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_flapping=absent
run_probe_capture first rc 'list_idle_transitions'
assert_contains  "cycle 1: pane-absent surfaces"                  "$first" \
                 $'flapping\tpane-absent'
# Cycle 2 with identical state → no emit.
run_probe_capture second rc 'list_idle_transitions'
assert_empty    "cycle 2: identical pane-absent silenced"          "$second"

# ---- Test 31: render_idle_section formats pane-absent ----------------

echo '=== render_idle_section formats pane-absent rows ==='
rm -f "$STATE_DIR/idle-state.tsv"
out=$(PATH="$STUB_DIR:$PATH" bash -c "
    set -uo pipefail
    STATE_DIR='$STATE_DIR'
    NEXUS_ROOT='$NEXUS_ROOT'
    source '$PROBE'
    list_really_idle_workers() {
        printf 'docs-merge-and-polish\tpane-absent\t900\tclaude process gone or unresponsive; relaunch or close\n'
    }
    render_idle_section
" 2>/dev/null)
assert_contains  "pane-absent row renders advisory"               "$out" \
                 "- docs-merge-and-polish pane-absent"
assert_contains  "pane-absent row includes relaunch hint"         "$out" \
                 "relaunch or close"

# ---- Tests 31b: over-limit classification + rendering (issue #87) -------

echo '=== over-limit: pane-state=over-limit short-circuits to over-limit class ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv"
# Use YOUNG_TS to also prove the over-limit short-circuit bypasses the
# 60s age gate — a worker just suspended must surface immediately.
export MOCK_TMUX_WINDOWS="$(printf 'suspended|%s' "$YOUNG_TS")"
export MOCK_PANE_STATE_suspended=over-limit
export MOCK_PANE_RESET_AT_suspended='3am_America/Los_Angeles'
run_probe_capture out rc 'list_really_idle_workers'
assert_eq        "exit 0"                                "$rc"  "0"
assert_contains  "over-limit class emitted"              "$out" \
                 $'suspended\tover-limit'
assert_contains  "detail carries reset_at"               "$out" \
                 "3am_America/Los_Angeles"

echo '=== over-limit: window-retain does NOT suppress over-limit (inviolable) ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv"
LOG="$STATE_DIR/action-log.jsonl"
RETAIN_TS=$(date -d "@$NOW" -Is 2>/dev/null || date -Iseconds)
printf '{"event":"window-retain","window":"suspended","ts":"%s","reason":"keep-loaded-context"}\n' \
    "$RETAIN_TS" > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'suspended|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_suspended=over-limit
export MOCK_PANE_RESET_AT_suspended='3am_America/Los_Angeles'
run_probe_capture out rc 'list_really_idle_workers'
assert_contains  "over-limit ignores retain"             "$out" \
                 $'suspended\tover-limit'
assert_not_contains "no retained downgrade"              "$out" \
                 $'suspended\tretained'

echo '=== render_idle_section formats over-limit rows with reset_at ==='
out=$(PATH="$STUB_DIR:$PATH" bash -c "
    set -uo pipefail
    STATE_DIR='$STATE_DIR'
    NEXUS_ROOT='$NEXUS_ROOT'
    source '$PROBE'
    list_really_idle_workers() {
        printf 'notion-content-full\tover-limit\t180\t3am_America/Los_Angeles\n'
    }
    render_idle_section
" 2>/dev/null)
assert_contains  "over-limit row carries OVER-LIMIT prefix"       "$out" \
                 "- notion-content-full OVER-LIMIT"
assert_contains  "over-limit row carries reset_at"                "$out" \
                 "resets 3am_America/Los_Angeles"
assert_contains  "over-limit row carries schedule-resume hint"    "$out" \
                 "schedule resume"

echo '=== render_idle_prelude includes over-limit count ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/last-prelude.ts"
export MOCK_TMUX_WINDOWS="$(printf 'overworker|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_overworker=over-limit
export MOCK_PANE_RESET_AT_overworker='3am'
run_probe_capture out rc 'render_idle_prelude'
assert_contains  "prelude advertises over-limit axis"             "$out" \
                 "over-limit"
assert_contains  "prelude counts the over-limit worker"           "$out" \
                 "1 over-limit"
# Reset env vars to avoid leaking into subsequent tests.
unset MOCK_PANE_RESET_AT_suspended MOCK_PANE_RESET_AT_overworker

# ---- Test 32: idle age anchored to engagement-log, not window_activity ----
#
# Spec change (idle-pool entry gate): when an engagement-log row
# exists, age is `now - engagement_epoch`. The fixture pins
# window_activity to T-30s (well below the 60s threshold) and
# engagement to T-300s (well above). Pre-fix the worker is
# filtered out (age=30s); post-fix the worker enters the pool
# (age=300s) and gets classified.

echo '=== idle age anchored to engagement-log, not window_activity ==='
rm -f "$STATE_DIR/idle-state.tsv"
LOG="$STATE_DIR/action-log.jsonl"
: > "$LOG"
TS_ACTIVITY=$(( NOW - 30 ))    # 30s ago — below default 60s threshold
TS_ENGAGEMENT=$(( NOW - 300 )) # 5 min ago — engagement floor
printf '%s\t%s\n' anchored "$TS_ENGAGEMENT" > "$STATE_DIR/engagement-log.tsv"
export MOCK_TMUX_WINDOWS="$(printf 'anchored|%s' "$TS_ACTIVITY")"
export MOCK_PANE_STATE_anchored=autosuggest-only
run_probe_capture out rc 'list_really_idle_workers'
assert_contains  "engagement-anchored age passes threshold"       "$out" \
                 $'anchored\tno-wrap-up'
# Age column should reflect engagement-floor (≈300s), not 30s.
age_col=$(awk -F'\t' '$1=="anchored" {print $3}' <<<"$out")
if (( age_col >= 290 )); then
    printf '  PASS: age column reflects engagement floor (%s ≥ 290)\n' "$age_col"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: age column not engagement-anchored: %s (want ≥ 290)\n' \
        "$age_col" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 33: fresh worker — backfill stamps at observation time -------
#
# Post-#44: a worker the watcher has never observed before gets an
# engagement-log row backfilled at first sight (epoch = NOW). The
# 60s post-observation grace is the documented trade-off: the
# worker spends 60s in the "not yet really idle" classification
# even if its tmux window_activity is older. After 60s of
# continuous observation, age = NOW - backfill_epoch crosses the
# threshold and the worker enters the pool consistently — without
# the autosuggest-bump flap that the old window_activity fallback
# re-introduced (issue #44).

echo '=== fresh worker: backfill on first observation; 60s post-observation grace ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv"
LOG="$STATE_DIR/action-log.jsonl"
: > "$LOG"
# Capture a fresh NOW; preceding tests can drift the file-level NOW
# by a few seconds, which is fine for activity comparisons but
# breaks tight equality on the backfill-epoch assertion.
NOW_T33=$(date +%s)
# Window_activity 30s ago, no engagement-log row.
TS_ACTIVITY=$(( NOW_T33 - 30 ))
export MOCK_TMUX_WINDOWS="$(printf 'fresh|%s' "$TS_ACTIVITY")"
export MOCK_PANE_STATE_fresh=autosuggest-only
run_probe_capture out rc 'list_really_idle_workers'
# Backfill stamps NOW → age = 0 → filtered out (60s grace).
assert_not_contains "fresh worker filtered out during 60s grace" "$out" "fresh"
# Stricter: verify the backfill side-effect — engagement-log now
# carries a row for the window with epoch ≈ NOW.
assert_eq        "engagement-log row created by backfill"          \
                 "$(awk -F'\t' '$1=="fresh"' "$STATE_DIR/engagement-log.tsv" | wc -l)" "1"
STAMPED=$(awk -F'\t' '$1=="fresh" {print $2}' "$STATE_DIR/engagement-log.tsv")
NOW_AFTER=$(date +%s)
if (( STAMPED >= NOW_T33 - 5 && STAMPED <= NOW_AFTER + 5 )); then
    printf '  PASS: backfill epoch ≈ NOW (%s within probe-run window [%s, %s])\n' \
        "$STAMPED" "$NOW_T33" "$NOW_AFTER"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: backfill epoch outside probe-run window (%s vs [%s, %s])\n' \
        "$STAMPED" "$NOW_T33" "$NOW_AFTER" >&2
    FAIL=$(( FAIL + 1 ))
fi
# Sanity: pre-seed engagement-log with an older epoch (simulating
# "a few minutes have passed since the first observation"). Worker
# now enters the pool because age = NOW - engagement ≥ threshold.
# This proves the engagement-anchored gate is wired AND that the
# post-backfill engagement-log epoch (not window_activity) is the
# anchor.
TS_OLD_ENGAGEMENT=$(( NOW - 120 ))
printf 'fresh\t%s\n' "$TS_OLD_ENGAGEMENT" > "$STATE_DIR/engagement-log.tsv"
rm -f "$STATE_DIR/idle-state.tsv"
run_probe_capture out rc 'list_really_idle_workers'
assert_contains  "older engagement epoch → fresh worker enters pool" "$out" \
                 $'fresh\tno-wrap-up'

# ---- Test 34: recent engagement excludes worker from idle pool ---------
#
# An engagement-log row whose epoch is within the last threshold
# seconds means the current idle stretch is too young to count.
# The worker stays out of the pool even though window_activity is
# old. This is the inverse of Test 32 and proves the new gate
# strictly tracks engagement-derived age.

echo '=== recent engagement (<threshold) excludes worker ==='
rm -f "$STATE_DIR/idle-state.tsv"
LOG="$STATE_DIR/action-log.jsonl"
: > "$LOG"
# Re-anchor to a FRESH now (not the top-of-test NOW) so the
# engagement epoch's age is measured from ~here, not from the start of
# a possibly-100s+ run. The probe ages workers by live wall-clock; a
# fixture stamped at the top-of-test NOW aged past the 60s threshold
# whenever the suite ran long under parallel load, surfacing
# `justfinished` and failing this assertion (your-org/your-nexus#180,
# R3 idle-probe flake). Fresh anchor keeps the seed→assert gap sub-second.
_seed_now=$(date +%s)
TS_ACTIVITY=$(( _seed_now - 120 ))   # 2 min ago — old, would pass default gate
TS_ENGAGEMENT=$(( _seed_now - 15 ))  # 15s ago — well below the 60s threshold
printf '%s\t%s\n' justfinished "$TS_ENGAGEMENT" > "$STATE_DIR/engagement-log.tsv"
export MOCK_TMUX_WINDOWS="$(printf 'justfinished|%s' "$TS_ACTIVITY")"
export MOCK_PANE_STATE_justfinished=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_not_contains "recently-engaged worker filtered out"        "$out" \
                    "justfinished"

# ---- Test 35: footer stable under window_activity bumps ---------------
#
# Regression for the bug this PR fixes. A retained worker whose
# pane sits in `autosuggest-only` for hours nonetheless has its
# tmux `#{window_activity}` bumped continuously by spinner glyph
# swaps, cursor renders, and status-bar ticks. Under the old
# entry gate the worker dropped out of the pool whenever
# `now - activity < 60s` and re-entered when activity drifted
# back past 60s, causing the suppressed-set footer to thrash
# every minute or two. Under the engagement-anchored gate the
# worker's idle age stays large across cycles regardless of
# window_activity bumps, so its classification is stable and
# `list_idle_transitions` emits nothing on the second cycle.

echo '=== footer stable across cycles despite window_activity bumps ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv"
LOG="$STATE_DIR/action-log.jsonl"
# Seed a retain so the worker classifies as `retained` (the actual
# footer-bearing class).
TS_RETAIN=$(( NOW - 1800 ))           # 30 min ago
TS_ENGAGEMENT=$(( NOW - 2400 ))       # 40 min ago — before retain.ts so
                                      # retain has not been consumed.
RETAIN_TS_ISO=$(date -Is -d "@$TS_RETAIN")
cat > "$LOG" <<EOF
{"ts":"$RETAIN_TS_ISO","agent":"monitor","event":"window-retain","window":"renderchurn","reason":"context-loaded"}
EOF
printf '%s\t%s\n' renderchurn "$TS_ENGAGEMENT" > "$STATE_DIR/engagement-log.tsv"
# Cycle 1: window_activity well past the 60s entry gate even
# under the old logic. Worker enters the pool, classifies as
# retained.
TS_ACTIVITY_C1=$(( NOW - 180 ))
export MOCK_TMUX_WINDOWS="$(printf 'renderchurn|%s' "$TS_ACTIVITY_C1")"
export MOCK_PANE_STATE_renderchurn=autosuggest-only
run_probe_capture out_c1 rc 'list_idle_transitions'
assert_contains  "cycle 1: renderchurn enters as retained"        "$out_c1" \
                 $'renderchurn\tretained'
# Cycle 2: simulate an autosuggest render that bumped
# window_activity to T-20s — well below the 60s entry gate. Pre-
# fix the worker would drop out of the pool here, causing the
# footer to re-emit "0 retained windows suppressed". Post-fix the
# engagement floor (T-1700s) keeps the age at ~1700s, so the
# classification is identical to cycle 1 and the transitions diff
# is empty.
TS_ACTIVITY_C2=$(( NOW - 20 ))
export MOCK_TMUX_WINDOWS="$(printf 'renderchurn|%s' "$TS_ACTIVITY_C2")"
run_probe_capture out_c2 rc 'list_idle_transitions'
assert_empty    "cycle 2: render bump produces no transition"     "$out_c2"

# ---- Test 36: pre-existing-idle worker — no flap across cycles --------
#
# Direct regression for issue #44. A worker that has been
# continuously idle since before this watcher's process lifetime
# (no engagement-log row when the probe first sees it) used to
# hit the `now - window_activity` fallback, which oscillated
# above/below the threshold every time an autosuggest re-render
# bumped tmux's #{window_activity}. Post-#44 the backfill stamps
# at first observation and the worker's classification stays put.

echo '=== pre-existing-idle worker: no flap under autosuggest bumps ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv"
LOG="$STATE_DIR/action-log.jsonl"
# Seed a window-retain so the worker classifies as `retained`
# (the actual footer-bearing class that flapped in production).
TS_RETAIN=$(( NOW - 1800 ))           # 30 min ago
RETAIN_TS_ISO=$(date -Is -d "@$TS_RETAIN")
cat > "$LOG" <<EOF
{"ts":"$RETAIN_TS_ISO","agent":"monitor","event":"window-retain","window":"preexisting","reason":"context-loaded"}
EOF
# Cycle 1: window_activity bumped 10s ago (post-retain) by an
# autosuggest re-render. NO engagement-log row — first probe sees
# this worker for the first time. Pre-#44, age = NOW - activity =
# 10s < 60s → filtered out → footer drops the worker → flap.
# Post-#44, backfill stamps NOW → age = 0 → also filtered, BUT
# the engagement-log now has a row so subsequent cycles are stable.
TS_ACTIVITY_C1=$(( NOW - 10 ))
export MOCK_TMUX_WINDOWS="$(printf 'preexisting|%s' "$TS_ACTIVITY_C1")"
export MOCK_PANE_STATE_preexisting=autosuggest-only
run_probe_capture out_c1 rc 'list_idle_transitions'
# Whatever cycle 1 emits, cycle 2 with another activity bump
# (simulating a second autosuggest re-render) must produce the
# same set — no new transitions.
TS_ACTIVITY_C2=$(( NOW - 5 ))
export MOCK_TMUX_WINDOWS="$(printf 'preexisting|%s' "$TS_ACTIVITY_C2")"
run_probe_capture out_c2 rc 'list_idle_transitions'
assert_empty    "cycle 2: identical state → no flap into-or-out-of" "$out_c2"
# And cycle 3 with yet another bump, to be thorough.
TS_ACTIVITY_C3=$(( NOW - 2 ))
export MOCK_TMUX_WINDOWS="$(printf 'preexisting|%s' "$TS_ACTIVITY_C3")"
run_probe_capture out_c3 rc 'list_idle_transitions'
assert_empty    "cycle 3: still no flap"                            "$out_c3"

# ---- Test 37: backfill on first observation creates engagement-log row -
#
# Direct unit test of the backfill semantic: probe a window the
# watcher has never seen, verify the engagement-log gains a row
# stamped with the current epoch.

echo '=== backfill: first observation creates engagement-log row ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv"
LOG="$STATE_DIR/action-log.jsonl"
: > "$LOG"
# No pre-existing engagement-log; window observed for the first time.
NOW_T37=$(date +%s)
export MOCK_TMUX_WINDOWS="$(printf 'firstsight|%s' "$(( NOW_T37 - 30 ))")"
export MOCK_PANE_STATE_firstsight=idle
run_probe_capture _ rc 'list_really_idle_workers'
assert_eq        "engagement-log file created"                    \
                 "$( [[ -f "$STATE_DIR/engagement-log.tsv" ]] && echo yes || echo no )" "yes"
assert_eq        "firstsight row count == 1 (backfilled)"         \
                 "$(awk -F'\t' '$1=="firstsight"' "$STATE_DIR/engagement-log.tsv" | wc -l)" "1"
STAMPED_T37=$(awk -F'\t' '$1=="firstsight" {print $2}' "$STATE_DIR/engagement-log.tsv")
NOW_AFTER_T37=$(date +%s)
if (( STAMPED_T37 >= NOW_T37 - 5 && STAMPED_T37 <= NOW_AFTER_T37 + 5 )); then
    printf '  PASS: backfill epoch within probe-run window (%s in [%s, %s])\n' \
        "$STAMPED_T37" "$NOW_T37" "$NOW_AFTER_T37"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: backfill epoch outside probe-run window (%s vs [%s, %s])\n' \
        "$STAMPED_T37" "$NOW_T37" "$NOW_AFTER_T37" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 38: backfill idempotency — existing row preserved -----------
#
# Backfill must only stamp when no row exists. If a window already
# has an engagement-log row (from a prior cycle, or from a watcher
# that ran earlier this session), the row's epoch is preserved —
# busy / user-typing observations refresh it, but plain idle
# observations through backfill must NOT overwrite.

echo '=== backfill: existing engagement-log row preserved on idle observation ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv"
LOG="$STATE_DIR/action-log.jsonl"
: > "$LOG"
# Pre-seed with an epoch from 5 minutes ago.
NOW_T38=$(date +%s)
PRE_EPOCH=$(( NOW_T38 - 300 ))
printf 'preserved\t%s\n' "$PRE_EPOCH" > "$STATE_DIR/engagement-log.tsv"
export MOCK_TMUX_WINDOWS="$(printf 'preserved|%s' "$(( NOW_T38 - 10 ))")"
export MOCK_PANE_STATE_preserved=idle
run_probe_capture _ rc 'list_really_idle_workers'
POST_EPOCH=$(awk -F'\t' '$1=="preserved" {print $2}' "$STATE_DIR/engagement-log.tsv")
assert_eq        "preserved row count == 1 after probe"           \
                 "$(awk -F'\t' '$1=="preserved"' "$STATE_DIR/engagement-log.tsv" | wc -l)" "1"
assert_eq        "preserved epoch unchanged by backfill (idempotency)" \
                 "$POST_EPOCH" "$PRE_EPOCH"
# Sanity: a busy observation SHOULD update the row (engagement
# refresh is distinct from backfill). Switch the pane to busy and
# re-run; epoch must advance.
sleep 1   # ensure NOW advances
export MOCK_PANE_STATE_preserved=busy
run_probe_capture _ rc 'list_really_idle_workers'
POST_BUSY_EPOCH=$(awk -F'\t' '$1=="preserved" {print $2}' "$STATE_DIR/engagement-log.tsv")
if (( POST_BUSY_EPOCH > PRE_EPOCH )); then
    printf '  PASS: busy observation refreshes epoch (%s → %s)\n' \
        "$PRE_EPOCH" "$POST_BUSY_EPOCH"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: busy observation did not refresh epoch (%s → %s)\n' \
        "$PRE_EPOCH" "$POST_BUSY_EPOCH" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 39: stale-after-resume — disappearance drop unblocks resume --
#
# Direct regression for issue #61. Engagement-log has a stale row
# for window X (epoch 1h ago, before any prior wrap-up). Across
# three cycles we simulate: present → absent → present (same name,
# resumed). Cycle 2's disappearance prune must remove the row;
# cycle 3 must take PR #46's backfill path (no row → stamp NOW)
# instead of inheriting the 1h-old epoch and tripping the
# "wrapped up (idle 1h00m)" classifier on a freshly-resumed worker.

echo '=== stale-after-resume: disappearance prune unblocks resumption ==='
rm -f "$STATE_DIR/idle-state.tsv" \
      "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt" \
      "$STATE_DIR/operator-engaged.tsv" "$STATE_DIR/machine-input.tsv"
rm -rf "$STATE_DIR/user-prompt"
LOG="$STATE_DIR/action-log.jsonl"
: > "$LOG"
NOW_T39=$(date +%s)
STALE_EPOCH=$(( NOW_T39 - 3600 ))   # 1h ago — well past the 60s gate
# Cycle 1: window present, engagement-log carries the stale row, and
# a user-prompt stamp from the prior life exists (machine-attributed
# via a matching machine-input row so it can't mark the window —
# this block tests the PRUNE, not the seed).
printf 'resumed\t%s\n' "$STALE_EPOCH" > "$STATE_DIR/engagement-log.tsv"
stamp_user_prompt resumed "$STALE_EPOCH"
stamp_pane_change resumed "$STALE_EPOCH"
printf 'resumed\t%s\ttest-paste\n' "$STALE_EPOCH" > "$STATE_DIR/machine-input.tsv"
export MOCK_TMUX_WINDOWS="$(printf 'resumed|%s' "$(( NOW_T39 - 60 ))")"
export MOCK_PANE_STATE_resumed=idle
run_probe_capture out_c1 rc 'list_really_idle_workers'
assert_contains  "cycle 1: stale row classifies as no-wrap-up (1h idle)" \
                 "$out_c1" $'resumed\tno-wrap-up'
# Cycle 2: window disappears from tmux.
export MOCK_TMUX_WINDOWS=""
run_probe_capture out_c2 rc 'list_really_idle_workers'
assert_empty    "cycle 2: no rows surface (window absent)"               "$out_c2"
# Engagement-log row for `resumed` must be gone.
assert_eq        "cycle 2: engagement-log row dropped" \
                 "$(awk -F'\t' '$1=="resumed"' "$STATE_DIR/engagement-log.tsv" | wc -l)" \
                 "0"
# The user-prompt stamp must be pruned with the window too — a
# reused window-name starts from "no submit yet", not the prior
# life's stamp.
if [[ ! -f "$STATE_DIR/user-prompt/resumed" ]]; then
    printf '  PASS: cycle 2: user-prompt stamp pruned with the window\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: cycle 2: user-prompt stamp not pruned\n' >&2
    FAIL=$(( FAIL + 1 ))
fi
# Same for the pane-change stamp (your-org/your-nexus#205 follow-up) —
# a reused window-name must not inherit the prior life's change clock.
if [[ ! -f "$STATE_DIR/pane-change/resumed" ]]; then
    printf '  PASS: cycle 2: pane-change stamp pruned with the window\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: cycle 2: pane-change stamp not pruned\n' >&2
    FAIL=$(( FAIL + 1 ))
fi
# Cycle 3: window reappears under the same name (resumed).
NOW_T39_C3=$(date +%s)
export MOCK_TMUX_WINDOWS="$(printf 'resumed|%s' "$(( NOW_T39_C3 - 5 ))")"
export MOCK_PANE_STATE_resumed=idle
run_probe_capture out_c3 rc 'list_really_idle_workers'
# Backfill stamped at NOW → age ≈ 0 → filtered by the 60s grace.
# Crucially NOT classified as `no-wrap-up` at the 1h age it would
# have inherited from the stale row.
assert_not_contains "cycle 3: resumed worker NOT classified (60s grace)" \
                    "$out_c3" "resumed"
RESUMED_EPOCH=$(awk -F'\t' '$1=="resumed" {print $2}' "$STATE_DIR/engagement-log.tsv")
NOW_T39_AFTER=$(date +%s)
if [[ -n "$RESUMED_EPOCH" ]] \
   && (( RESUMED_EPOCH >= NOW_T39_C3 - 5 )) \
   && (( RESUMED_EPOCH <= NOW_T39_AFTER + 5 )); then
    printf '  PASS: cycle 3 backfill epoch ≈ NOW (%s in [%s, %s])\n' \
        "$RESUMED_EPOCH" "$NOW_T39_C3" "$NOW_T39_AFTER"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: cycle 3 backfill epoch not at NOW (%s vs [%s, %s])\n' \
        "$RESUMED_EPOCH" "$NOW_T39_C3" "$NOW_T39_AFTER" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 40: sustained presence — row never dropped -------------------
#
# A window that stays present across multiple cycles must not have
# its engagement-log row dropped. Disappearance pruning is gated
# on `previous − current`, so a window in both sets is preserved.
# This also guards the idempotency contract from PRs #33 / #46.

echo '=== sustained presence: engagement-log row preserved across cycles ==='
rm -f "$STATE_DIR/idle-state.tsv" \
      "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt"
LOG="$STATE_DIR/action-log.jsonl"
: > "$LOG"
NOW_T40=$(date +%s)
STAB_EPOCH=$(( NOW_T40 - 300 ))   # 5 min ago — past threshold
printf 'stable\t%s\n' "$STAB_EPOCH" > "$STATE_DIR/engagement-log.tsv"
export MOCK_TMUX_WINDOWS="$(printf 'stable|%s' "$(( NOW_T40 - 30 ))")"
export MOCK_PANE_STATE_stable=idle
# Run four cycles back-to-back with identical state.
for _cycle in 1 2 3 4; do
    run_probe_capture _out_unused rc 'list_really_idle_workers'
done
assert_eq        "stable row count == 1 after 4 cycles" \
                 "$(awk -F'\t' '$1=="stable"' "$STATE_DIR/engagement-log.tsv" | wc -l)" \
                 "1"
KEPT_EPOCH=$(awk -F'\t' '$1=="stable" {print $2}' "$STATE_DIR/engagement-log.tsv")
assert_eq        "stable epoch preserved (no drop, no refresh on idle)" \
                 "$KEPT_EPOCH" "$STAB_EPOCH"

# ---- Test 41: cold-start with stale on-disk row — prune in two cycles --
#
# Fresh watcher process: engagement-log has a row for a window that
# is NOT in tmux, and no previous-windows file exists yet. Cycle 1
# can't compute a disappearance (previous = ∅) so the row lingers.
# Cycle 1 persists `current ∪ engagement-log-keys`, so the stale
# window's name lands in the previous-windows file. Cycle 2 sees
# previous = {stale}, current = ∅ → disappeared = {stale} → drop.

echo '=== cold-start with stale on-disk row: cycle 1 lingers, cycle 2 prunes ==='
rm -f "$STATE_DIR/idle-state.tsv" \
      "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt"
LOG="$STATE_DIR/action-log.jsonl"
: > "$LOG"
NOW_T41=$(date +%s)
STALE_EPOCH_T41=$(( NOW_T41 - 7200 ))   # 2h old
printf 'orphan\t%s\n' "$STALE_EPOCH_T41" > "$STATE_DIR/engagement-log.tsv"
# Tmux state shows orphan is NOT present.
export MOCK_TMUX_WINDOWS=""
# Cycle 1: previous-windows file absent → no disappearance pruning
# yet. Row lingers.
run_probe_capture _ rc 'list_really_idle_workers'
assert_eq        "cycle 1: orphan row still present (lingers)" \
                 "$(awk -F'\t' '$1=="orphan"' "$STATE_DIR/engagement-log.tsv" | wc -l)" \
                 "1"
# Previous-windows file should now record orphan (from the
# engagement-log ∪ current union persist).
assert_eq        "cycle 1: previous-windows captures orphan via engagement-log union" \
                 "$(awk -v w=orphan '$0==w {n++} END {print n+0}' \
                       "$STATE_DIR/idle-probe-previous-windows.txt" 2>/dev/null)" \
                 "1"
# Cycle 2: previous = {orphan}, current = ∅ → drop.
run_probe_capture _ rc 'list_really_idle_workers'
assert_eq        "cycle 2: orphan row pruned" \
                 "$(awk -F'\t' '$1=="orphan"' "$STATE_DIR/engagement-log.tsv" 2>/dev/null | wc -l)" \
                 "0"
# Previous-windows file should now be empty (no current, no
# engagement-log keys).
assert_eq        "cycle 2: previous-windows cleared (orphan dropped)" \
                 "$(awk -v w=orphan '$0==w {n++} END {print n+0}' \
                       "$STATE_DIR/idle-probe-previous-windows.txt" 2>/dev/null)" \
                 "0"

# ---- Test 42: lifecycle-scoped wrap-up matching (issue #72) ----------
#
# Action-log has a stale wrap-up from a prior life of the window, then
# a spawn event marking the start of the current life. The classifier
# must NOT treat the prior wrap-up as authoritative — the window's
# current lifecycle has no wrap-up yet, so the row should classify as
# no-wrap-up.
#
# Closes regression 3 from issue #72.

echo '=== lifecycle scope: wrap-up before spawn is ignored ==='
rm -f "$STATE_DIR/idle-state.tsv" \
      "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt"
LOG="$STATE_DIR/action-log.jsonl"
SPAWN_TS=$(date -Is -d "@$(( NOW - 600 ))")   # 10 min ago
OLD_WRAP_TS=$(date -Is -d "@$(( NOW - 7200 ))")   # 2 h ago
cat > "$LOG" <<EOF
{"ts":"$OLD_WRAP_TS","agent":"monitor","event":"wrap-up","window":"recycled","report":"recycled_2026-05-10_120000_old.md","upload":"ok","comment":"ok","rocket":"ok"}
{"ts":"$SPAWN_TS","agent":"monitor","event":"spawn","window":"recycled","workdir":"/tmp/recycled"}
EOF
export MOCK_TMUX_WINDOWS="$(printf 'recycled|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_recycled=idle
# Disable spawn grace for this test — we want to assert wrap-up
# scoping, not grace skipping.
run_probe_capture out rc 'MONITOR_IDLE_POOL_SPAWN_GRACE_SECONDS=0 list_really_idle_workers'
assert_contains  "stale wrap-up (pre-spawn) → no-wrap-up class"  "$out" \
                 $'recycled\tno-wrap-up'
assert_not_contains "stale wrap-up not surfaced as wrapped"      "$out" \
                    $'recycled\twrapped'

echo '=== lifecycle scope: wrap-up after spawn IS authoritative ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt"
LOG="$STATE_DIR/action-log.jsonl"
SPAWN_TS=$(date -Is -d "@$(( NOW - 600 ))")
FRESH_WRAP_TS=$(date -Is -d "@$(( NOW - 300 ))")   # after spawn
cat > "$LOG" <<EOF
{"ts":"$SPAWN_TS","agent":"monitor","event":"spawn","window":"fresh-wrap","workdir":"/tmp/fresh"}
{"ts":"$FRESH_WRAP_TS","agent":"monitor","event":"wrap-up","window":"fresh-wrap","report":"fresh-wrap_2026-05-11_120000_now.md","upload":"ok","comment":"ok","rocket":"ok"}
EOF
export MOCK_TMUX_WINDOWS="$(printf 'fresh-wrap|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_fresh_wrap=idle
run_probe_capture out rc 'MONITOR_IDLE_POOL_SPAWN_GRACE_SECONDS=0 list_really_idle_workers'
assert_contains  "post-spawn wrap-up → wrapped"                  "$out" \
                 $'fresh-wrap\twrapped'

# ---- Test 43: spawn-grace skip (issue #72) ---------------------------
#
# A worker spawned 30s ago should not enter the idle pool yet, even if
# its pane-state classifies as idle and the engagement-log epoch is
# pre-grace-threshold-aged.

echo '=== spawn grace: window < grace seconds old is skipped ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt"
LOG="$STATE_DIR/action-log.jsonl"
# Fresh anchor for the spawn event: the grace gate measures
# `now - spawn_epoch` against live wall-clock, so a spawn ts pinned to
# the top-of-test NOW aged past the 120s grace whenever the suite ran
# long under load, surfacing `booting` and failing this assertion
# (your-org/your-nexus#180, R3 idle-probe flake). Anchoring 30s back
# from a fresh now keeps spawn_age ≈ 30s regardless of total runtime.
_seed_now=$(date +%s)
RECENT_SPAWN_TS=$(date -Is -d "@$(( _seed_now - 30 ))")
cat > "$LOG" <<EOF
{"ts":"$RECENT_SPAWN_TS","agent":"monitor","event":"spawn","window":"booting","workdir":"/tmp/booting"}
EOF
# Engagement-log seeded with an OLD epoch — proves the grace gate
# overrides the engagement-anchored idle age.
printf 'booting\t%s\n' "$OLD_TS" > "$STATE_DIR/engagement-log.tsv"
export MOCK_TMUX_WINDOWS="$(printf 'booting|%s' "$OLD_TS")"
export MOCK_PANE_STATE_booting=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_not_contains "booting (30s old) skipped by grace"          "$out" \
                    "booting"

echo '=== spawn grace: window >= grace seconds old is classified ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt"
LOG="$STATE_DIR/action-log.jsonl"
ELDERLY_SPAWN_TS=$(date -Is -d "@$(( NOW - 300 ))")  # 5 min ago
cat > "$LOG" <<EOF
{"ts":"$ELDERLY_SPAWN_TS","agent":"monitor","event":"spawn","window":"elderly","workdir":"/tmp/elderly"}
EOF
printf 'elderly\t%s\n' "$OLD_TS" > "$STATE_DIR/engagement-log.tsv"
export MOCK_TMUX_WINDOWS="$(printf 'elderly|%s' "$OLD_TS")"
export MOCK_PANE_STATE_elderly=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_contains  "elderly (5min old) classified normally"        "$out" \
                 "elderly"

echo '=== spawn grace: legacy window (no spawn event) passes through ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt"
: > "$STATE_DIR/action-log.jsonl"
printf 'legacy\t%s\n' "$OLD_TS" > "$STATE_DIR/engagement-log.tsv"
export MOCK_TMUX_WINDOWS="$(printf 'legacy|%s' "$OLD_TS")"
export MOCK_PANE_STATE_legacy=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_contains  "legacy (no spawn event) bypasses grace"        "$out" \
                 "legacy"

# ---- Tests 35-38: render_idle_prelude awaiting-input counter (issue #76) --
#
# Workers' Notification hook appends `{event,notification,window,ts}`
# JSONL rows to STATE_DIR/worker-notifications.jsonl. render_idle_prelude
# counts distinct windows whose ts is newer than the prior prelude
# render's stamp, and surfaces the count as `| N awaiting-input` at the
# tail of the prelude. Rotation on >= MONITOR_NOTIFICATIONS_LOG_MAX_BYTES
# keeps the log bounded.

# 35. Empty notifications log → 0 awaiting-input, prelude ends with the
#     new column.

echo '=== prelude: missing notifications log → 0 awaiting-input ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt" \
      "$STATE_DIR/worker-notifications.jsonl" \
      "$STATE_DIR/last-prelude.ts"
export MOCK_TMUX_WINDOWS="$(printf 'quietworker|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_quietworker=busy
run_probe_capture out rc 'render_idle_prelude'
assert_eq        "exit 0"                                "$rc"  "0"
assert_contains  "prelude includes awaiting-input column" "$out" "awaiting-input"
assert_contains  "missing log → 0 awaiting-input"        "$out" "0 awaiting-input"

# 36. First render with rows present but no prior stamp → cold-start
#     scope reports 0 (avoid inflating on stale historical rows).
#     Second render counts only rows added since the first.

echo '=== prelude: first call after fresh STATE_DIR reports 0 (cold start) ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt" \
      "$STATE_DIR/worker-notifications.jsonl" \
      "$STATE_DIR/last-prelude.ts"
NLOG="$STATE_DIR/worker-notifications.jsonl"
PRE_TS=$(( NOW - 600 ))   # 10 minutes ago
cat > "$NLOG" <<EOF
{"event":"Notification","notification":{"type":"permission_prompt"},"window":"alpha","ts":$PRE_TS}
{"event":"Notification","notification":{"type":"idle_prompt"},"window":"beta","ts":$PRE_TS}
EOF
export MOCK_TMUX_WINDOWS="$(printf 'alpha|%s\nbeta|%s' "$OLD_TS" "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_alpha=busy
export MOCK_PANE_STATE_beta=busy
# A cold-start with stamp absent counts only rows newer than 0; with
# stale rows in the file at PRE_TS this would over-report. The probe
# guards against that by treating "missing stamp" as "no scope yet"
# only after stamping NOW — so the second call sees 0 unless new rows
# arrived. Verify: first call should be 0 awaiting-input (since the
# stamp absent → epoch 0 means everything counts on the very first
# pass). Documented trade-off; the assertion below pins the behavior.
run_probe_capture out rc 'render_idle_prelude'
# First-call semantics: stamp epoch defaults to 0 → all rows in file
# are "newer than 0" → count both windows. The doc-comment in
# render_idle_prelude calls this out as the documented trade-off; we
# expect exactly 2 here.
assert_contains  "first call counts pre-existing rows"   "$out" "2 awaiting-input"

# Second render right after, no new rows: stamp from the first render
# is now in place, count drops to 0.
run_probe_capture out2 rc 'render_idle_prelude'
assert_contains  "second call (no new rows) → 0 awaiting-input" \
                 "$out2" "0 awaiting-input"

# 37. New row arrives between renders → prelude bumps awaiting-input.
#     Two events from the same window de-dupe (distinct-by-window).

echo '=== prelude: new rows since last render bump the counter, deduped per window ==='
# Append two rows for charlie + one for delta. NEW_TS is pinned a few
# seconds ahead of the previous prelude's stamp so the integer-second
# `ts > since` comparison can't tie (same-second appends would falsely
# fall under the prior stamp).
NEW_TS=$(( $(date +%s) + 5 ))
cat >> "$NLOG" <<EOF
{"event":"Notification","notification":{"type":"permission_prompt"},"window":"charlie","ts":$NEW_TS}
{"event":"Notification","notification":{"type":"permission_prompt"},"window":"charlie","ts":$NEW_TS}
{"event":"Notification","notification":{"type":"idle_prompt"},"window":"delta","ts":$NEW_TS}
EOF
run_probe_capture out3 rc 'render_idle_prelude'
assert_contains  "new rows since stamp → count 2 distinct windows"  "$out3" "2 awaiting-input"
# Subsequent render (no new rows) collapses back to 0. Force the stamp
# past NEW_TS so the test is deterministic regardless of how fast the
# probe advances its own subsecond stamp.
printf '%s' "$(( NEW_TS + 1 ))" > "$STATE_DIR/last-prelude.ts"
run_probe_capture out4 rc 'render_idle_prelude'
assert_contains  "next call after new-row burst → 0 awaiting-input" \
                 "$out4" "0 awaiting-input"

# 38. Rotation fires when the file crosses the size cap. After
#     rotation the live file is gone (recreated by the next worker
#     append in production) and the rotated archive `*.jsonl.<epoch>`
#     exists alongside it.

echo '=== prelude: rotation moves oversized log to <path>.<epoch> ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt" \
      "$STATE_DIR/worker-notifications.jsonl"* \
      "$STATE_DIR/last-prelude.ts"
NLOG="$STATE_DIR/worker-notifications.jsonl"
# Build a > 1KB file by repeating a single row; cap is set to 1024 via
# env override.
ROW='{"event":"Notification","notification":{"type":"permission_prompt"},"window":"big","ts":1}'
{
    for i in $(seq 1 200); do
        printf '%s\n' "$ROW"
    done
} > "$NLOG"
size_before=$(stat -c '%s' "$NLOG" 2>/dev/null || stat -f '%z' "$NLOG")
# Sanity: payload should comfortably exceed the 1KB cap we'll pass.
test "$size_before" -gt 1024 || {
    printf '  FAIL: rotation harness produced %d bytes (need >1024)\n' "$size_before" >&2
    FAIL=$(( FAIL + 1 ))
}
export MOCK_TMUX_WINDOWS=
export MOCK_PANE_STATE_big=busy
run_probe_capture out rc \
    'MONITOR_NOTIFICATIONS_LOG_MAX_BYTES=1024 render_idle_prelude'
assert_eq        "rotation render exit 0"               "$rc"  "0"
# Live file should be gone after rotation; archive should exist.
if [[ -f "$NLOG" ]]; then
    printf '  FAIL: live log still present after rotation\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: live log removed after rotation\n'; PASS=$(( PASS + 1 ))
fi
archive_count=$(find "$STATE_DIR" -maxdepth 1 -type f \
    -name 'worker-notifications.jsonl.*' 2>/dev/null | wc -l)
assert_eq        "rotated archive exists alongside"      "$archive_count" "1"
# Below-threshold case is a no-op — file persists.
echo '=== prelude: file under threshold is not rotated ==='
rm -f "$STATE_DIR/worker-notifications.jsonl"*
NLOG="$STATE_DIR/worker-notifications.jsonl"
printf '%s\n' "$ROW" > "$NLOG"
run_probe_capture out rc \
    'MONITOR_NOTIFICATIONS_LOG_MAX_BYTES=1048576 render_idle_prelude'
assert_eq        "small-file render exit 0"             "$rc"  "0"
if [[ -f "$NLOG" ]]; then
    printf '  PASS: small log preserved\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: small log removed when it should not have been\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Tests 44+: operator-engaged classification (issues #196/#201/#205) -
#
# A worker the operator is actively driving must not nag ("idle …
# WITHOUT wrap-up"), must not surface as retire-eligible — but the
# your-org/your-nexus#205 follow-up makes the mark SELF-EXPIRING and
# CHANGE-CORROBORATED: a present-mark holds only while the pane keeps
# changing within the decay TTL, and lapses (releasing the window) once
# it goes static. THE seed is still the UserPromptSubmit hook stamp,
# attributed via the machine-input rule; #270's fragile one-frame
# bright-marker `user-typing` corroboration is REPLACED by observed
# pane-content change. Pane state alone never seeds.

echo '=== operator-engaged: present-mark self-expires once the pane goes static (part A) ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt" "$STATE_DIR/operator-engaged.tsv"
rm -rf "$STATE_DIR/user-prompt" "$STATE_DIR/pane-change"
LOG="$STATE_DIR/action-log.jsonl"
_oe_now=$(date +%s)
OE_SPAWN_TS=$(date -Is -d "@$(( _oe_now - 900 ))")
OE_WRAP_TS=$(date -Is -d "@$(( _oe_now - 300 ))")
cat > "$LOG" <<EOF
{"ts":"$OE_SPAWN_TS","agent":"monitor","event":"spawn","window":"chatty","workdir":"/tmp/chatty"}
{"ts":"$OE_WRAP_TS","agent":"monitor","event":"wrap-up","window":"chatty","report":"chatty_2026-06-10_120000_done.md","upload":"ok","comment":"ok","rocket":"ok"}
EOF
export MOCK_TMUX_WINDOWS="$(printf 'chatty|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_chatty=idle

# Cycle 1: wrapped + idle → normal wrapped row; no submit yet means no
# bookkeeping row (idleness alone is never tracked).
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "cycle1: wrapped row emitted"            "$out" $'chatty\twrapped'
assert_not_contains "cycle1: no submit → no engagement row" \
    "$(cat "$STATE_DIR/operator-engaged.tsv" 2>/dev/null)" 'chatty'

# Cycle 2: the operator submits (hook stamp; spawn 900 s old, far
# outside the slack; nothing machine-side claims it) AND the pane has
# changed within the TTL — the agent answered, growing the transcript.
# Seed corroborated in ONE cycle.
stamp_user_prompt   chatty "$_oe_now"
stamp_pane_change   chatty "$_oe_now"
run_probe_capture out rc 'MONITOR_IDLE_THRESHOLD_SECONDS=0 list_really_idle_workers'
assert_contains "cycle2: corroborated submit → operator-engaged" "$out" $'chatty\toperator-engaged'
assert_contains "cycle2: mark created src=submit-after-wrap" \
    "$(cat "$STATE_DIR/operator-engaged.tsv")" 'submit-after-wrap'

# Cycle 3: the pane has now been STATIC past the change TTL (operator
# walked away / the mark was a phantom). The mark self-expires and the
# window returns to its normal wrapped classification — retire-eligible
# again. This is the non-negotiable bias toward RELEASE.
stamp_pane_change chatty "$(( _oe_now - 700 ))"   # 700 s > 600 s TTL
rm -f "$STATE_DIR/idle-state.tsv"
run_probe_capture out rc 'MONITOR_IDLE_THRESHOLD_SECONDS=0 list_really_idle_workers'
assert_contains     "cycle3: static-past-TTL mark lapses → wrapped resumes" "$out" $'chatty\twrapped'
assert_not_contains "cycle3: lapsed mark no longer suppresses"             "$out" $'chatty\toperator-engaged'
unset MOCK_PANE_STATE_chatty

echo '=== operator-engaged: a present-mark HOLDS while the pane keeps changing (part B) ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt" "$STATE_DIR/operator-engaged.tsv"
rm -rf "$STATE_DIR/user-prompt" "$STATE_DIR/pane-change"
: > "$LOG"
_oe_now=$(date +%s)
export MOCK_TMUX_WINDOWS="$(printf 'alive|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
# Seed: corroborated submit (never-wrapped window).
stamp_user_prompt alive "$_oe_now"
stamp_pane_change alive "$_oe_now" hashA
export MOCK_PANE_STATE_alive=idle
run_probe_capture out rc 'MONITOR_IDLE_THRESHOLD_SECONDS=0 list_really_idle_workers'
assert_contains "seed: operator-engaged" "$out" $'alive\toperator-engaged'
# A busy cycle whose transcript hash ADVANCES — the agent is streaming
# output. The probe records the change, refreshing the corroboration
# clock from the content hash itself (no submit needed).
export MOCK_PANE_STATE_alive=busy
export MOCK_CONTENT_HASH_alive=hashB
run_probe_capture out rc 'MONITOR_IDLE_THRESHOLD_SECONDS=0 list_really_idle_workers'
CHG_AFTER=$(awk -F'\t' 'NR==1{print $2}' "$STATE_DIR/pane-change/alive")
assert_eq "busy cycle advanced the change clock (hash differed)" \
    "$( [[ "$CHG_AFTER" -ge "$_oe_now" ]] && echo yes )" "yes"
# Back to idle — change was recent, so the mark still holds.
unset MOCK_CONTENT_HASH_alive
export MOCK_PANE_STATE_alive=idle
run_probe_capture out rc 'MONITOR_IDLE_THRESHOLD_SECONDS=0 list_really_idle_workers'
assert_contains "sustained change → mark still held"  "$out" $'alive\toperator-engaged'
assert_not_contains "sustained change → no nag"       "$out" $'alive\tno-wrap-up'
unset MOCK_PANE_STATE_alive

echo '=== operator-engaged: a constant hash (dim ghost + ticking timer) is NOT change (part B) ==='
# pane-state.sh normalises the autosuggest row and timer/token digits
# out of content_hash, so a window showing only those emits the SAME
# hash cycle after cycle. The probe must read that as "not changing":
# the change clock stays frozen and a mark over the window ages out.
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt" "$STATE_DIR/operator-engaged.tsv"
rm -rf "$STATE_DIR/user-prompt" "$STATE_DIR/pane-change"
: > "$LOG"
_oe_now=$(date +%s)
export MOCK_TMUX_WINDOWS="$(printf 'quiescent|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_quiescent=idle
export MOCK_CONTENT_HASH_quiescent=frozenhash
# Two cycles with an identical hash. last_change_epoch is set on the
# first sight, then must NOT advance on the second.
run_probe_capture _ rc 'list_really_idle_workers'
CHG1=$(awk -F'\t' 'NR==1{print $2}' "$STATE_DIR/pane-change/quiescent")
sleep 1
run_probe_capture _ rc 'list_really_idle_workers'
CHG2=$(awk -F'\t' 'NR==1{print $2}' "$STATE_DIR/pane-change/quiescent")
assert_eq "identical hash across cycles → change clock frozen" "$CHG2" "$CHG1"
unset MOCK_PANE_STATE_quiescent MOCK_CONTENT_HASH_quiescent

echo '=== operator-engaged: corroboration — submit + change marks; submit + NO change does not (part B) ==='
# Two never-wrapped windows, each with an operator-attributed submit.
# `genuine` is followed by a pane change within the TTL (the agent
# answered) → marked. `phantom` is a redraw artifact: the submit lands
# but the pane never changes; once the await TTL elapses the submit is
# consumed WITHOUT a mark, and the window keeps nagging.
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt" "$STATE_DIR/operator-engaged.tsv" \
      "$STATE_DIR/machine-input.tsv"
rm -rf "$STATE_DIR/user-prompt" "$STATE_DIR/pane-change"
: > "$LOG"
_oe_now=$(date +%s)
export MOCK_TMUX_WINDOWS="$(printf 'genuine|%s\nphantom|%s' "$OLD_TS" "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_genuine=idle
export MOCK_PANE_STATE_phantom=idle
# genuine: submit corroborated by a recent change.
stamp_user_prompt genuine "$_oe_now"
stamp_pane_change genuine "$_oe_now"
# phantom: submit a full TTL in the past with NO change ever observed
# → the bounded await has elapsed, so it is consumed without marking.
# (Use a small TTL so the test is fast and deterministic.)
stamp_user_prompt phantom "$(( _oe_now - 40 ))"
run_probe_capture out rc 'MONITOR_OPERATOR_ENGAGED_CHANGE_TTL_SECONDS=30 MONITOR_IDLE_THRESHOLD_SECONDS=0 list_really_idle_workers'
assert_contains     "genuine: corroborated submit marks src=submit" \
    "$(awk -F'\t' '$1=="genuine" && $2 != 0 { print $5 }' "$STATE_DIR/operator-engaged.tsv" 2>/dev/null)" 'submit'
assert_contains     "genuine: classifies operator-engaged" "$out" $'genuine\toperator-engaged'
assert_not_contains "phantom: artifact submit creates NO mark" \
    "$(awk -F'\t' '$2 != 0 { print $1 }' "$STATE_DIR/operator-engaged.tsv" 2>/dev/null)" 'phantom'
assert_contains     "phantom: still nags no-wrap-up"       "$out" $'phantom\tno-wrap-up'
# phantom's stamp is consumed (await timed out) so attribution doesn't
# re-run forever.
assert_contains "phantom stamp consumed without a mark" \
    "$(awk -F'\t' -v e="$(( _oe_now - 40 ))" '$1=="phantom" && $2 == 0 && $4 == e { print $1 }' "$STATE_DIR/operator-engaged.tsv" 2>/dev/null)" 'phantom'
unset MOCK_PANE_STATE_genuine MOCK_PANE_STATE_phantom

echo '=== operator-engaged: pane state alone never seeds (busy / typing / autosuggest) ==='
# No UserPromptSubmit stamp ⇒ no mark, whatever the pane shows. The
# orchestrator's follow-up-paste flow depends on the nag continuing.
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt" "$STATE_DIR/operator-engaged.tsv"
rm -rf "$STATE_DIR/user-prompt" "$STATE_DIR/pane-change"
: > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'typer|%s\nplain|%s\nghost|%s' "$OLD_TS" "$OLD_TS" "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_typer=user-typing
export MOCK_PANE_STATE_plain=busy
export MOCK_PANE_STATE_ghost=autosuggest-only
export MOCK_CONTENT_HASH_plain=streaming   # plain's transcript even changes
run_probe_capture out rc 'list_really_idle_workers'
assert_empty "no submit anywhere → no marks at all" \
    "$(awk -F'\t' '$2 != 0 { print $1 }' "$STATE_DIR/operator-engaged.tsv" 2>/dev/null)"
unset MOCK_PANE_STATE_typer MOCK_PANE_STATE_plain MOCK_PANE_STATE_ghost MOCK_CONTENT_HASH_plain

echo '=== operator-engaged: a NEWER wrap-up does NOT invalidate; engaged-done DOES (the #205 state machine) ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt" "$STATE_DIR/operator-engaged.tsv"
rm -rf "$STATE_DIR/pane-change"
_oe_now=$(date +%s)
REWRAP_TS=$(date -Is -d "@$(( _oe_now - 50 ))")
cat > "$LOG" <<EOF
{"ts":"$REWRAP_TS","agent":"monitor","event":"wrap-up","window":"rewrap","report":"rewrap_2026-06-10_130000_again.md","upload":"ok","comment":"ok","rocket":"ok"}
EOF
# Mark created BEFORE the wrap-up (since=now-100 < wrap ts=now-50) and
# the pane changed recently. The interactive session stays engaged
# across its own hand-off — the operator may have follow-up
# inquiries — so the mark must HOLD and keep suppressing.
printf 'rewrap\t%s\t%s\t%s\tsubmit\t0\n' \
    "$(( _oe_now - 100 ))" "$(( _oe_now - 10 ))" "$(( _oe_now - 90 ))" \
    > "$STATE_DIR/operator-engaged.tsv"
stamp_pane_change rewrap "$_oe_now"
export MOCK_TMUX_WINDOWS="$(printf 'rewrap|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_rewrap=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_contains     "newer wrap-up → interactive session stays engaged" "$out" $'rewrap\toperator-engaged'
assert_not_contains "newer wrap-up → no wrapped row while engaged"      "$out" $'rewrap\twrapped'
# The explicit finished-signal (`ng engaged-done` appends this event)
# is what releases the window: mark dies, the wrapped row surfaces,
# and the typical cleanup path applies.
DONE_TS=$(date -Is -d "@$(( _oe_now - 5 ))")
cat >> "$LOG" <<EOF
{"ts":"$DONE_TS","agent":"monitor","event":"engaged-done","window":"rewrap"}
EOF
rm -f "$STATE_DIR/idle-state.tsv"
run_probe_capture out rc 'list_really_idle_workers'
assert_contains     "engaged-done → wrapped surfaces (typical cleanup)" "$out" $'rewrap\twrapped'
assert_not_contains "engaged-done → mark inert"                         "$out" $'rewrap\toperator-engaged'
# Re-engagement after the finished-signal: a NEW corroborated operator
# submit newer than the engaged-done seeds a fresh episode.
stamp_user_prompt rewrap "$_oe_now"
stamp_pane_change rewrap "$_oe_now"
rm -f "$STATE_DIR/idle-state.tsv"
run_probe_capture out rc 'MONITOR_IDLE_THRESHOLD_SECONDS=0 list_really_idle_workers'
assert_contains     "post-done operator prompt re-engages" "$out" $'rewrap\toperator-engaged'
unset MOCK_PANE_STATE_rewrap

echo '=== operator-engaged: render format + transition dedupe ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt" "$STATE_DIR/operator-engaged.tsv"
rm -rf "$STATE_DIR/pane-change"
: > "$LOG"
_oe_now=$(date +%s)
printf 'fmt\t%s\t%s\t0\tsubmit\t0\n' "$(( _oe_now - 30 ))" "$(( _oe_now - 5 ))" \
    > "$STATE_DIR/operator-engaged.tsv"
stamp_pane_change fmt "$_oe_now"   # mark valid (change recent)
export MOCK_TMUX_WINDOWS="$(printf 'fmt|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_fmt=idle
run_probe_capture out rc 'render_idle_section'
assert_contains "engaged row rendered with src + suppression note" "$out" \
    'fmt operator-engaged (src=submit;'
run_probe_capture out rc 'render_idle_section'
assert_empty    "second cycle: same class deduped (no re-emit)"    "$out"
# Mid-episode oscillation: a busy cycle (window leaves the pool), then
# the next think-gap returns it. The carried dedupe row must keep the
# episode at ONE announcement.
export MOCK_PANE_STATE_fmt=busy
run_probe_capture out rc 'render_idle_section'
assert_empty    "busy cycle: no row (out of pool)"                 "$out"
export MOCK_PANE_STATE_fmt=idle
run_probe_capture out rc 'MONITOR_IDLE_THRESHOLD_SECONDS=0 render_idle_section'
assert_empty    "post-busy think-gap: episode NOT re-announced"    "$out"
unset MOCK_PANE_STATE_fmt

echo '=== transitions: empty state file does not swallow the first row ==='
# Regression guard for the awk FNR==NR empty-file pitfall: a cycle
# where the workspace's ONLY idle window went busy truncates
# idle-state.tsv to empty; when the window idles again, its row must
# re-emit (it previously vanished forever in single-idle-window
# workspaces).
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt" "$STATE_DIR/operator-engaged.tsv" \
      "$STATE_DIR/machine-input.tsv"
: > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'solo|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_solo=idle
run_probe_capture out rc 'list_idle_transitions'
assert_contains "solo cycle1: idle row emitted"            "$out" $'solo\tno-wrap-up'
# No hook stamp accompanies the busy flip, so the engagement seed
# cannot fire — this block tests the dedupe plumbing undisturbed.
export MOCK_PANE_STATE_solo=busy
run_probe_capture out rc 'list_idle_transitions'
assert_empty    "solo cycle2: busy → empty transitions"    "$out"
export MOCK_PANE_STATE_solo=idle
run_probe_capture out rc 'MONITOR_IDLE_THRESHOLD_SECONDS=0 list_idle_transitions'
assert_contains "solo cycle3: re-idle re-emits (not swallowed)" "$out" $'solo\tno-wrap-up'
unset MOCK_PANE_STATE_solo

# ---- Tests 50+: user-prompt-submit seed + attribution (issue #201) ------
#
# A window the operator drives that NEVER wrapped (the
# demo-rerun-lead case): a UserPromptSubmit stamp newer than the
# row's prompt_seen means someone submitted input; with no
# machine-input stamp (paste-followup event / machine-input.tsv row
# / spawn event) covering the submit, the input is the operator's
# and the window is marked engaged. A machine-stamped submit stays
# on the normal nag schedule — the orchestrator's follow-up-paste
# flow must keep surfacing stalls.

echo '=== operator-engaged: never-wrapped unstamped submit seeds (issue #201) ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt" "$STATE_DIR/operator-engaged.tsv" \
      "$STATE_DIR/machine-input.tsv"
rm -rf "$STATE_DIR/user-prompt" "$STATE_DIR/pane-change"
: > "$LOG"
_lead_now=$(date +%s)
export MOCK_TMUX_WINDOWS="$(printf 'lead|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_lead=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "cycle1: never-wrapped window nags no-wrap-up" "$out" $'lead\tno-wrap-up'
assert_empty    "cycle1: no submit → no engagement bookkeeping" \
    "$(cat "$STATE_DIR/operator-engaged.tsv" 2>/dev/null)"
# The operator submits the prompt; the hook stamps it. No machine
# input anywhere near the submit epoch, and the pane changed within
# the TTL (the agent answered) → operator-attributed, corroborated.
stamp_user_prompt lead "$_lead_now"
stamp_pane_change lead "$_lead_now"
run_probe_capture out rc 'MONITOR_IDLE_THRESHOLD_SECONDS=0 list_really_idle_workers'
assert_contains "cycle2: unstamped submit seeds mark src=submit" \
    "$(awk -F'\t' '$1=="lead" && $2 != 0 { print $5 }' "$STATE_DIR/operator-engaged.tsv" 2>/dev/null)" 'submit'
assert_contains     "cycle2: classifies operator-engaged"   "$out" $'lead\toperator-engaged'
assert_not_contains "cycle2: follow-up-paste nag suppressed" "$out" $'lead\tno-wrap-up'
# The stamp is consumed: re-running the probe must not re-attribute
# the same submit (prompt_seen == stamp epoch).
assert_contains "stamp consumed (prompt_seen == stamp epoch)" \
    "$(awk -F'\t' '$1=="lead" && $4 == $2 { print $1 }' "$STATE_DIR/operator-engaged.tsv" 2>/dev/null)" 'lead'
unset MOCK_PANE_STATE_lead

echo '=== operator-engaged: machine-stamped submits do NOT seed (attribution rule) ==='
# Three machine-input stamp sources, each claiming the submit for
# the orchestrator: an action-log paste-followup event, a
# machine-input.tsv row (unstick nudge / paste helper), and a spawn
# event. None may mark the window — a stalled worker the
# orchestrator just pasted to must keep surfacing. (The paste itself
# fires the worker's UserPromptSubmit hook, hence the stamps.)
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt" "$STATE_DIR/operator-engaged.tsv" \
      "$STATE_DIR/machine-input.tsv"
rm -rf "$STATE_DIR/user-prompt" "$STATE_DIR/pane-change"
: > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'pasted|%s\nnudged|%s' "$OLD_TS" "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_pasted=idle
export MOCK_PANE_STATE_nudged=idle
run_probe_capture out rc 'list_really_idle_workers'
_at_now=$(date +%s)
PASTE_TS=$(date -Is -d "@$_at_now")
cat >> "$LOG" <<EOF
{"ts":"$PASTE_TS","agent":"monitor","event":"paste-followup","note":"please wrap up","window":"pasted"}
EOF
printf 'nudged\t%s\tunstick-api-error\n' "$_at_now" > "$STATE_DIR/machine-input.tsv"
# Both pastes land and fire the workers' UserPromptSubmit hooks.
stamp_user_prompt pasted "$_at_now"
stamp_user_prompt nudged "$_at_now"
export MOCK_PANE_STATE_pasted=busy
export MOCK_PANE_STATE_nudged=busy
run_probe_capture out rc 'list_really_idle_workers'
assert_empty "machine-stamped submits create NO marks" \
    "$(awk -F'\t' '$2 != 0 { print $1 }' "$STATE_DIR/operator-engaged.tsv" 2>/dev/null)"
export MOCK_PANE_STATE_pasted=idle
export MOCK_PANE_STATE_nudged=idle
run_probe_capture out rc 'MONITOR_IDLE_THRESHOLD_SECONDS=0 list_really_idle_workers'
assert_contains "post-paste re-idle: pasted still nags no-wrap-up" "$out" $'pasted\tno-wrap-up'
assert_contains "post-nudge re-idle: nudged still nags no-wrap-up" "$out" $'nudged\tno-wrap-up'
assert_not_contains "no false suppression after stamped pastes" "$out" 'operator-engaged'
unset MOCK_PANE_STATE_pasted MOCK_PANE_STATE_nudged
rm -f "$STATE_DIR/machine-input.tsv"

echo '=== operator-engaged: spawn event claims the submit (resume nudge) ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt" "$STATE_DIR/operator-engaged.tsv"
rm -rf "$STATE_DIR/user-prompt" "$STATE_DIR/pane-change"
: > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'resumed|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_resumed=idle
run_probe_capture out rc 'list_really_idle_workers'
SPAWN2_TS=$(date -Is -d "@$(date +%s)")
cat >> "$LOG" <<EOF
{"ts":"$SPAWN2_TS","agent":"monitor","event":"spawn","window":"resumed","workdir":"/tmp/resumed","mode":"resume"}
EOF
# The respawn's continuation nudge fires the UserPromptSubmit hook;
# the spawn event claims it.
stamp_user_prompt resumed
export MOCK_PANE_STATE_resumed=busy
run_probe_capture out rc 'list_really_idle_workers'
assert_empty "spawn-stamped submit creates NO mark" \
    "$(awk -F'\t' '$2 != 0 { print $1 }' "$STATE_DIR/operator-engaged.tsv" 2>/dev/null)"
unset MOCK_PANE_STATE_resumed

# ---- Tests 52+: bounded await for corroboration (your-org/your-nexus#205
#      follow-up) ----------------------------------------------------------
#
# An operator-attributed submit may land one probe BEFORE the agent's
# answer renders, so corroboration is AWAITED up to the change TTL: the
# stamp is left UNCONSUMED and no mark is made until either a pane
# change lands (→ mark) or the TTL elapses (→ artifact, consumed, no
# mark). This is what lets a genuine deep-think submit still seed while
# a phantom submit is rejected.

echo '=== operator-engaged: a submit awaits corroboration, then marks when change lands ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt" "$STATE_DIR/operator-engaged.tsv" \
      "$STATE_DIR/machine-input.tsv"
rm -rf "$STATE_DIR/user-prompt" "$STATE_DIR/pane-change"
: > "$LOG"
_aw_now=$(date +%s)
export MOCK_TMUX_WINDOWS="$(printf 'await|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_await=idle
# Cycle 1: the operator submits (recent) but the pane has NOT changed
# yet — no prior change stamp at all. Within the await window: the
# stamp must stay UNCONSUMED (prompt_seen still 0) and no mark forms.
stamp_user_prompt await "$_aw_now"
run_probe_capture out rc 'MONITOR_IDLE_THRESHOLD_SECONDS=0 list_really_idle_workers'
assert_not_contains "await cycle: no mark yet" "$out" $'await\toperator-engaged'
assert_contains "await cycle: window still nags (no premature suppression)" "$out" $'await\tno-wrap-up'
# The submit is NOT consumed during await: nothing is written to the
# operator-engaged row, so the next cycle re-checks the same submit.
assert_empty "await cycle: stamp NOT consumed (no row written yet)" \
    "$(awk -F'\t' '$1=="await"' "$STATE_DIR/operator-engaged.tsv" 2>/dev/null)"
# Cycle 2: the agent's answer renders — a pane change lands within the
# TTL. The awaited submit is now corroborated → mark.
stamp_pane_change await "$(date +%s)"
run_probe_capture out rc 'MONITOR_IDLE_THRESHOLD_SECONDS=0 list_really_idle_workers'
assert_contains "await→change: now marks operator-engaged" "$out" $'await\toperator-engaged'
assert_contains "await→change: src=submit" \
    "$(awk -F'\t' '$1=="await" && $2 != 0 { print $5 }' "$STATE_DIR/operator-engaged.tsv" 2>/dev/null)" 'submit'
unset MOCK_PANE_STATE_await

# ---- Tests 53+: away-phase close reminder (issue #201) -------------------
#
# The away phase is a SEPARATE soft clock on `last` (last operator
# submit) that rides on top of the change-TTL validity: a mark kept
# VALID by sustained pane change (the agent keeps working on the
# operator's behalf) but whose operator hasn't SUBMITTED for the grace
# is "away". So these blocks pin a RECENT pane-change stamp (mark
# valid) while `last` is hours old (away). Lifecycle: (1) away <
# reminder period → suppressed, NO emit; (2) away ≥ period → exactly
# ONE "consider closing" emit per period; a returning operator re-seeds
# and resets the cadence.

echo '=== operator-engaged: away < period → suppressed, no emit ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt" "$STATE_DIR/operator-engaged.tsv"
rm -rf "$STATE_DIR/user-prompt" "$STATE_DIR/pane-change"
: > "$LOG"
_rem_now=$(date +%s)
export MOCK_TMUX_WINDOWS="$(printf 'linger|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_linger=idle
# Mark kept VALID by recent change; `last` (submit) 2 h old (beyond the
# 1800 s grace, below the 86400 s period) → away.
stamp_pane_change linger "$_rem_now"
printf 'linger\t%s\t%s\t%s\tbusy-after-prompt\t0\n' \
    "$(( _rem_now - 10000 ))" "$(( _rem_now - 7200 ))" "$(( _rem_now - 7000 ))" \
    > "$STATE_DIR/operator-engaged.tsv"
run_probe_capture out rc 'render_idle_section'
assert_contains "away<period: engaged announce only" "$out" 'linger operator-engaged (src=busy-after-prompt;'
assert_not_contains "away<period: no close reminder"  "$out" 'consider closing'
run_probe_capture out rc 'render_idle_section'
assert_empty "away<period second cycle: fully silent" "$out"

echo '=== operator-engaged: away ≥ period → ONE close reminder per period ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/idle-probe-previous-windows.txt"
# Away 25 h, never reminded; mark still valid (recent change).
stamp_pane_change linger "$_rem_now"
printf 'linger\t%s\t%s\t%s\tbusy-after-prompt\t0\n' \
    "$(( _rem_now - 100000 ))" "$(( _rem_now - 90000 ))" "$(( _rem_now - 89000 ))" \
    > "$STATE_DIR/operator-engaged.tsv"
run_probe_capture out rc 'render_idle_section'
assert_contains "away≥period: close reminder rendered" "$out" \
    'operator-engaged but operator away'
assert_contains "away≥period: reminder names the action" "$out" 'consider closing this window'
assert_contains "reminded stamp recorded" \
    "$(awk -F'\t' -v n="$_rem_now" '$1=="linger" && $6 >= n - 60' "$STATE_DIR/operator-engaged.tsv")" 'linger'
run_probe_capture out rc 'render_idle_section'
assert_empty "same period: NO second reminder" "$out"
# Next period: age the reminded stamp a full period back → re-fires
# exactly once, with no engaged-row re-announce.
awk -F'\t' -v OFS='\t' -v aged="$(( _rem_now - 90000 ))" \
    '$1=="linger" { $6=aged } { print }' \
    "$STATE_DIR/operator-engaged.tsv" > "$STATE_DIR/operator-engaged.tsv.new"
mv "$STATE_DIR/operator-engaged.tsv.new" "$STATE_DIR/operator-engaged.tsv"
run_probe_capture out rc 'list_idle_transitions'
assert_eq "next period: exactly one reminder row" \
    "$(grep -c 'engaged-close-reminder' <<<"$out")" "1"
assert_not_contains "next period: engaged row not re-announced" "$out" $'linger\toperator-engaged'

echo '=== operator-engaged: returning operator re-seeds and resets the cadence ==='
# A fresh operator-attributed submit while the mark is stale (away)
# starts a NEW episode and zeroes `reminded`. No submit ⇒ no re-seed —
# the hook stamp is the only trigger (pane state alone never re-seeds).
stamp_pane_change linger "$_rem_now"   # mark valid (recent change)
printf 'linger\t%s\t%s\t%s\tbusy-after-prompt\t%s\n' \
    "$(( _rem_now - 100000 ))" "$(( _rem_now - 90000 ))" "$(( _rem_now - 89000 ))" "$(( _rem_now - 50 ))" \
    > "$STATE_DIR/operator-engaged.tsv"
export MOCK_PANE_STATE_linger=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "idle while away: NO re-seed (since unchanged)" \
    "$(awk -F'\t' -v s="$(( _rem_now - 100000 ))" '$1=="linger" && $2 == s' "$STATE_DIR/operator-engaged.tsv")" 'linger'
# The operator returns: a fresh submit, corroborated by the recent
# change → new episode, src=submit, reminded reset.
stamp_user_prompt linger
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "return: fresh episode src=submit" \
    "$(awk -F'\t' -v n="$_rem_now" '$1=="linger" && $2 >= n - 60 && $5=="submit"' "$STATE_DIR/operator-engaged.tsv")" 'linger'
assert_contains "return: reminded reset to 0" \
    "$(awk -F'\t' '$1=="linger" && $6 == 0' "$STATE_DIR/operator-engaged.tsv")" 'linger'
unset MOCK_PANE_STATE_linger

# ---- parked-awaiting-skeptic exemption (PR #285) ------------------------
# A worker parked in `skeptic-channel await` has a LIVE skeptic-pending
# marker whose mtime its await loop refreshes. The probe must exempt it
# from idle-too-long / no-wrap-up (so the orchestrator doesn't close it
# mid-handshake) and surface it as `parked-awaiting-skeptic` — but only
# while the marker is FRESH; a stale marker (await died) must let a
# genuine hang resurface. close_hours is forced to 0 so an UNexempted
# idle worker is the strongest class (idle-too-long), making the
# exemption's override unambiguous.
echo '=== parked-awaiting-skeptic: live marker exempts from idle/close ==='
rm -f "$STATE_DIR/idle-state.tsv"
PARK_PEND="$STATE_DIR/skeptic/pending"
mkdir -p "$PARK_PEND"
export MONITOR_SKEPTIC_AWAIT_HANG_SECONDS=600
export MONITOR_IDLE_CLOSE_HOURS=0
export MOCK_TMUX_WINDOWS="$(printf 'parked-w|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_parked_w=idle   # MOCK key sanitises '-' → '_'

# (a) No marker → baseline: classified idle-too-long.
rm -f "$PARK_PEND/parked-w"
run_probe_capture out rc 'list_really_idle_workers'
assert_contains    "no marker → idle-too-long (baseline)"   "$out" $'parked-w\tidle-too-long'
assert_not_contains "no marker → not parked"                "$out" "parked-awaiting-skeptic"

# (b) Fresh marker → parked-awaiting-skeptic, EXEMPT from idle-too-long.
touch "$PARK_PEND/parked-w"
run_probe_capture out rc 'list_really_idle_workers'
assert_contains    "fresh marker → parked-awaiting-skeptic" "$out" $'parked-w\tparked-awaiting-skeptic'
assert_not_contains "fresh marker → NOT idle-too-long"      "$out" "idle-too-long"

# (c) Stale marker (older than hang threshold) → exemption lapses; the
#     genuine hang resurfaces. MUTATION CATCH: drop the mtime check in
#     _idle_skeptic_parked and this goes red (a stale marker would
#     wrongly stay exempt forever).
touch -d "@$(( NOW - 700 ))" "$PARK_PEND/parked-w"
run_probe_capture out rc 'list_really_idle_workers'
assert_contains    "stale marker → exemption lapses (idle-too-long)" "$out" $'parked-w\tidle-too-long'
assert_not_contains "stale marker → not parked"             "$out" "parked-awaiting-skeptic"

# (d) Marker cleared (skeptic returned its verdict) → normal again.
rm -f "$PARK_PEND/parked-w"
run_probe_capture out rc 'list_really_idle_workers'
assert_contains    "cleared marker → normal (idle-too-long)"  "$out" $'parked-w\tidle-too-long'

unset MOCK_PANE_STATE_parked_w MONITOR_SKEPTIC_AWAIT_HANG_SECONDS MONITOR_IDLE_CLOSE_HOURS MOCK_TMUX_WINDOWS

# ---- interrupted ⨉ parked-awaiting-skeptic coexistence (merge #285⨉#286) -
# When PR #285 (parked-awaiting-skeptic) and PR #286 (interrupted-mid-turn)
# both classify the same idle worker, interrupted must WIN: a fresh
# turn-failure marker means the worker's `skeptic-channel await` loop died
# mid-handshake, so the (possibly still-fresh) skeptic-pending marker no
# longer reflects a live park — the crash is recoverable (paste/respawn)
# and must surface, not be masked by the park exemption. The probe runs the
# interrupted short-circuit ABOVE the skeptic-park short-circuit precisely
# so this holds. close_hours is forced high so interrupted is NOT downgraded
# to idle-too-long by age, making the precedence assertion unambiguous.
# MUTATION CATCH: reorder the two blocks (park before interrupted) and (b)
# goes red — the worker would surface parked-awaiting-skeptic and a crashed
# worker would sit un-recovered behind a stale park.
echo '=== interrupted beats parked-awaiting-skeptic when both markers live ==='
rm -f "$STATE_DIR/idle-state.tsv"
PARK_PEND="$STATE_DIR/skeptic/pending"
mkdir -p "$PARK_PEND" "$STATE_DIR/turn-failure"
export MONITOR_SKEPTIC_AWAIT_HANG_SECONDS=600
export MONITOR_IDLE_CLOSE_HOURS=99       # >> 120s age → interrupted, not idle-too-long
export MOCK_TMUX_WINDOWS="$(printf 'coex-w|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_coex_w=idle       # MOCK key sanitises '-' → '_'

write_coex_tf_marker() {                 # fresh turn-failure marker (ts=NOW)
    jq -nc --argjson ts "$NOW" \
        '{ts:$ts, error:"server_error", category:"transient", recovery:"paste", window:"coex-w"}' \
        > "$STATE_DIR/turn-failure/coex-w.json"
}

# (a) Fresh skeptic-pending marker alone → parked-awaiting-skeptic (control).
touch "$PARK_PEND/coex-w"
rm -f "$STATE_DIR/turn-failure/coex-w.json"
run_probe_capture out rc 'list_really_idle_workers'
assert_contains    "park alone → parked-awaiting-skeptic" "$out" $'coex-w\tparked-awaiting-skeptic'
assert_not_contains "park alone → not interrupted"        "$out" "interrupted"

# (b) BOTH markers fresh → interrupted wins (carries category:recovery).
write_coex_tf_marker
run_probe_capture out rc 'list_really_idle_workers'
assert_contains    "both live → interrupted wins"          "$out" $'coex-w\tinterrupted\t'
assert_contains    "both live → carries transient:paste"   "$out" "transient:paste"
assert_not_contains "both live → NOT parked"               "$out" "parked-awaiting-skeptic"

# (c) Turn-failure cleared, skeptic-pending still fresh → reverts to park.
#     Proves interrupted's precedence is driven by the live crash marker,
#     not a permanent suppression of the park exemption.
rm -f "$STATE_DIR/turn-failure/coex-w.json"
run_probe_capture out rc 'list_really_idle_workers'
assert_contains    "tf cleared → parked-awaiting-skeptic again" "$out" $'coex-w\tparked-awaiting-skeptic'
assert_not_contains "tf cleared → not interrupted"         "$out" "interrupted"

rm -f "$PARK_PEND/coex-w" "$STATE_DIR/turn-failure/coex-w.json"
unset MOCK_PANE_STATE_coex_w MONITOR_SKEPTIC_AWAIT_HANG_SECONDS MONITOR_IDLE_CLOSE_HOURS MOCK_TMUX_WINDOWS

# ---- summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
