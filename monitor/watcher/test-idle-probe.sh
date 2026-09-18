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
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    if [[ -n "$needle" ]] && grep -qF -- "$needle" <<<"$hay"; then
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
        # your-org/nexus-code#845: honour `-F '#{window_name}'` — production
        # asks for BARE names to build `live_windows`, and the stub used to
        # return `name|activity` for that too, so `_idle_skeptic_live_window`
        # (a whole-line `grep -qxF`) could never find a reviewer in this
        # suite: the join was unguardable by construction. Any other format
        # keeps the full `name|activity[|index]` rows.
        if [[ "${2:-}" == -F && "${3:-}" == '#{window_name}' ]]; then
            printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" | cut -d'|' -f1
        else
            printf '%s\n' "${MOCK_TMUX_WINDOWS:-}"
        fi
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
bgcpu_key="MOCK_BG_CPU_${win//[^a-zA-Z0-9_]/_}"
bgshells_key="MOCK_BG_SHELLS_${win//[^a-zA-Z0-9_]/_}"
bgrel_key="MOCK_BG_RELIABLE_${win//[^a-zA-Z0-9_]/_}"
bgold_key="MOCK_BG_OLDEST_START_${win//[^a-zA-Z0-9_]/_}"
bginfra_key="MOCK_BG_INFRA_${win//[^a-zA-Z0-9_]/_}"
bgcmd_key="MOCK_BG_CMD_${win//[^a-zA-Z0-9_]/_}"
bgwedged_key="MOCK_BG_WEDGED_${win//[^a-zA-Z0-9_]/_}"
bgmembers_key="MOCK_BG_MEMBERS_${win//[^a-zA-Z0-9_]/_}"
state="${!key:-busy}"
reset_at="${!reset_key:-}"
orphan_kinds="${!orphan_key:-}"
content_hash="${!hash_key:-}"
bg_cpu="${!bgcpu_key:-}"
bg_shells="${!bgshells_key:-}"
bg_reliable="${!bgrel_key:-}"
bg_oldest_start="${!bgold_key:-}"
bg_infra="${!bginfra_key:-}"
bg_cmd="${!bgcmd_key:-}"
bg_wedged="${!bgwedged_key:-}"
bg_members="${!bgmembers_key:-}"
extras=""
[[ -n "$reset_at" ]]      && extras+=" reset_at=$reset_at"
[[ -n "$orphan_kinds" ]]  && extras+=" orphan_kinds=$orphan_kinds"
[[ -n "$content_hash" ]]  && extras+=" content_hash=$content_hash"
[[ -n "$bg_shells" ]]     && extras+=" bg_shells=$bg_shells"
[[ -n "$bg_reliable" ]]   && extras+=" bg_reliable=$bg_reliable"
[[ -n "$bg_cpu" ]]        && extras+=" bg_cpu=$bg_cpu"
[[ -n "$bg_oldest_start" ]] && extras+=" bg_oldest_start=$bg_oldest_start"
[[ -n "$bg_infra" ]]      && extras+=" bg_infra=$bg_infra"
[[ -n "$bg_cmd" ]]        && extras+=" bg_cmd=$bg_cmd"
[[ -n "$bg_wedged" ]]     && extras+=" bg_cpu_bp=2 bg_wedged=$bg_wedged"
[[ -n "$bg_members" ]]    && extras+=" bg_members=$bg_members"
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

# ---- background-compute orphan-grace (your-org/nexus-code#445) -----------
#
# A SHELL-driven working-background carries bg_cpu=<jiffies>. While the
# jiffies advance the worker is genuinely computing (exempt); once they
# FREEZE past the orphan grace the shell is orphaned and the window
# falls back to normal idle classification (reapable). A Monitor-handle
# working-background carries NO bg_cpu and is never capped.
echo '=== background-compute orphan-grace (#445) ==='
export MONITOR_BACKGROUND_ORPHAN_GRACE_SECONDS=60

# (a) Live compute: bg_cpu ADVANCED vs a stored (old-epoch) sample →
#     the progress clock resets → still exempt (suppressed), even though
#     the stored progress epoch was well past the grace. Proves a live
#     compute worker is NEVER false-flagged idle.
rm -f "$STATE_DIR/idle-state.tsv"; : > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'wbglive|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
mkdir -p "$STATE_DIR/background-progress"
printf '%s\t%s\n' 900 "$(( NOW - 3600 ))" > "$STATE_DIR/background-progress/wbglive"
export MOCK_PANE_STATE_wbglive=working-background
export MOCK_BG_CPU_wbglive=1000   # 1000 != stored 900 → progress
run_probe_capture out rc 'list_really_idle_workers'
assert_not_contains "advancing bg_cpu → live compute stays exempt" "$out" \
    "wbglive"

# (b) Orphaned shell: bg_cpu FROZEN (== stored) with the stored epoch
#     past the grace → stalled → falls back to normal classification →
#     surfaces as no-wrap-up (reapable). This is the truly-orphaned
#     background shell the cap exists to reap.
rm -f "$STATE_DIR/idle-state.tsv"; : > "$LOG"
unset MOCK_PANE_STATE_wbglive MOCK_BG_CPU_wbglive
export MOCK_TMUX_WINDOWS="$(printf 'wbgorph|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
mkdir -p "$STATE_DIR/background-progress"
printf '%s\t%s\n' 500 "$(( NOW - 3600 ))" > "$STATE_DIR/background-progress/wbgorph"
export MOCK_PANE_STATE_wbgorph=working-background
export MOCK_BG_CPU_wbgorph=500    # 500 == stored → frozen past grace
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "frozen bg_cpu past grace → reapable (no-wrap-up)" "$out" \
    $'wbgorph\tno-wrap-up'

# (c) Frozen bg_cpu but WITHIN grace → still exempt (a normal
#     think-pause between poll iterations must not reap a live worker).
rm -f "$STATE_DIR/idle-state.tsv"; : > "$LOG"
unset MOCK_PANE_STATE_wbgorph MOCK_BG_CPU_wbgorph
export MOCK_TMUX_WINDOWS="$(printf 'wbgfresh|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
mkdir -p "$STATE_DIR/background-progress"
# Anchor the freeze-start to the CURRENT clock, not to the suite-start `NOW`.
# The case asserts "frozen, but the freeze began INSIDE the grace" and the grace
# in force here is 60s (set above), so anchoring to a `NOW` captured minutes
# earlier made the assertion depend on how long the preceding suite took to run:
# it passed at ~19s of elapsed suite time and failed at ~65s. That is a fixture
# encoding a wrong assumption, not a real behaviour boundary — the assertion
# itself is unchanged and still exercises exactly the within-grace branch.
printf '%s\t%s\n' 700 "$(( $(date +%s) - 10 ))" > "$STATE_DIR/background-progress/wbgfresh"
export MOCK_PANE_STATE_wbgfresh=working-background
export MOCK_BG_CPU_wbgfresh=700   # frozen, but stored epoch only 10s old
run_probe_capture out rc 'list_really_idle_workers'
assert_not_contains "frozen bg_cpu within grace → still exempt" "$out" \
    "wbgfresh"

# (d) working-background WITHOUT bg_cpu (Monitor-handle) is never capped
#     even with a stale progress file present — absence of bg_cpu means
#     "uncapped". Guards against a Monitor await being reaped.
rm -f "$STATE_DIR/idle-state.tsv"; : > "$LOG"
unset MOCK_PANE_STATE_wbgfresh MOCK_BG_CPU_wbgfresh
export MOCK_TMUX_WINDOWS="$(printf 'wbgmon|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
mkdir -p "$STATE_DIR/background-progress"
printf '%s\t%s\n' 0 "$(( NOW - 3600 ))" > "$STATE_DIR/background-progress/wbgmon"
export MOCK_PANE_STATE_wbgmon=working-background   # no MOCK_BG_CPU_wbgmon
run_probe_capture out rc 'list_really_idle_workers'
assert_not_contains "monitor-handle working-background never capped" "$out" \
    "wbgmon"
unset MOCK_PANE_STATE_wbgmon MONITOR_BACKGROUND_ORPHAN_GRACE_SECONDS

# ---- idle-with-children long timeout + inconsistency (#455 refine) --------
#
# An AUTHORITATIVE working-background reading (bg_reliable=1, bg_shells>=1)
# whose child CPU has FROZEN past base earns an exponentially-backing-off
# long timeout instead of the flat #445 orphan reap. A wrapped worker that
# still has a live child surfaces as the wrapped-with-children inconsistency.
# The worker-health file overrides the grace decision.
echo '=== idle-with-children backoff + inconsistency (#455 refine) ==='
# Small, fast constants so the test does not need multi-hour epochs.
export MONITOR_BG_CHILDREN_GRACE_BASE_SECONDS=60
export MONITOR_BG_CHILDREN_INTERVAL_CAP_SECONDS=240
export MONITOR_BG_CHILDREN_GRACE_CEILING_SECONDS=3600
export MONITOR_WORKER_HEALTH_SLACK_SECONDS=10

# Seed a frozen-child working-background window. Helper: pre-stamp the
# background-progress file so the child CPU reads as frozen `age` seconds.
# Uses LIVE `date +%s` (not the script-start NOW): the probe reads live time,
# and the suite can take minutes to reach this section, so a fixed NOW would
# inflate the effective stall age and make within/past-base asserts flaky.
seed_frozen_child() {
    local win="$1" age="$2" cpu="${3:-500}" n
    n=$(date +%s)
    mkdir -p "$STATE_DIR/background-progress"
    printf '%s\t%s\n' "$cpu" "$(( n - age ))" > "$STATE_DIR/background-progress/$win"
}
clear_bg_state() {
    rm -f "$STATE_DIR"/bg-backoff/* "$STATE_DIR"/worker-health/* \
          "$STATE_DIR"/background-progress/* "$STATE_DIR"/bg-firstseen/* 2>/dev/null || true
}

# (a1) Frozen child WITHIN base → silently exempt (no surface, no reap).
rm -f "$STATE_DIR/idle-state.tsv"; : > "$LOG"; clear_bg_state
export MOCK_TMUX_WINDOWS="$(printf 'bgc1|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgc1 30 500
export MOCK_PANE_STATE_bgc1=working-background
export MOCK_BG_SHELLS_bgc1=1 MOCK_BG_RELIABLE_bgc1=1 MOCK_BG_CPU_bgc1=500
run_probe_capture out rc 'list_really_idle_workers'
assert_not_contains "frozen child within base → silent exempt" "$out" "bgc1"

# (a2) Frozen child PAST base, no health decl → first clarification nudge.
rm -f "$STATE_DIR/idle-state.tsv"; : > "$LOG"; clear_bg_state
unset MOCK_PANE_STATE_bgc1 MOCK_BG_SHELLS_bgc1 MOCK_BG_RELIABLE_bgc1 MOCK_BG_CPU_bgc1
export MOCK_TMUX_WINDOWS="$(printf 'bgc2|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgc2 120 500
export MOCK_PANE_STATE_bgc2=working-background
export MOCK_BG_SHELLS_bgc2=1 MOCK_BG_RELIABLE_bgc2=1 MOCK_BG_CPU_bgc2=500
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "frozen past base → idle-children-clarify" "$out" \
    $'bgc2\tidle-children-clarify'
assert_contains "clarify detail points at worker-health.sh" "$out" \
    "worker-health.sh"

# (a3) After the first nudge, a fresh cycle before the next interval →
#      idle-awaiting-job (exempt, informational).
rm -f "$STATE_DIR/idle-state.tsv"; : > "$LOG"; clear_bg_state
unset MOCK_PANE_STATE_bgc2 MOCK_BG_SHELLS_bgc2 MOCK_BG_RELIABLE_bgc2 MOCK_BG_CPU_bgc2
export MOCK_TMUX_WINDOWS="$(printf 'bgc3|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgc3 120 500
mkdir -p "$STATE_DIR/bg-backoff"
# sig=1 matches child_count; level=1; last escalation 5s ago (< interval 120).
# Live now so the elapsed-since-last stays below the interval under drift.
printf '%s\t%s\t%s\n' 1 1 "$(( $(date +%s) - 5 ))" > "$STATE_DIR/bg-backoff/bgc3"
export MOCK_PANE_STATE_bgc3=working-background
export MOCK_BG_SHELLS_bgc3=1 MOCK_BG_RELIABLE_bgc3=1 MOCK_BG_CPU_bgc3=500
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "between nudges → idle-awaiting-job" "$out" \
    $'bgc3\tidle-awaiting-job'

# (a4) health=running with a live deadline → idle-awaiting-job (extend).
rm -f "$STATE_DIR/idle-state.tsv"; : > "$LOG"; clear_bg_state
unset MOCK_PANE_STATE_bgc3 MOCK_BG_SHELLS_bgc3 MOCK_BG_RELIABLE_bgc3 MOCK_BG_CPU_bgc3
export MOCK_TMUX_WINDOWS="$(printf 'bgc4|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgc4 120 500
mkdir -p "$STATE_DIR/worker-health"
cat > "$STATE_DIR/worker-health/bgc4.json" <<EOF
{"window":"bgc4","job_kind":"slurm","job_id":"52527284","expected_runtime_s":100000,"health":"running","note":"DE sweep","written_at":$NOW}
EOF
export MOCK_PANE_STATE_bgc4=working-background
export MOCK_BG_SHELLS_bgc4=1 MOCK_BG_RELIABLE_bgc4=1 MOCK_BG_CPU_bgc4=500
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "health=running within deadline → idle-awaiting-job" "$out" \
    $'bgc4\tidle-awaiting-job'
assert_contains "awaiting-job detail cites declared runtime" "$out" "running"

# (a5) health=running but declared runtime elapsed → resume nudging.
rm -f "$STATE_DIR/idle-state.tsv"; : > "$LOG"; clear_bg_state
unset MOCK_PANE_STATE_bgc4 MOCK_BG_SHELLS_bgc4 MOCK_BG_RELIABLE_bgc4 MOCK_BG_CPU_bgc4
export MOCK_TMUX_WINDOWS="$(printf 'bgc5|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgc5 120 500
mkdir -p "$STATE_DIR/worker-health"
cat > "$STATE_DIR/worker-health/bgc5.json" <<EOF
{"window":"bgc5","job_kind":"slurm","expected_runtime_s":30,"health":"running","written_at":$(( NOW - 3600 ))}
EOF
export MOCK_PANE_STATE_bgc5=working-background
export MOCK_BG_SHELLS_bgc5=1 MOCK_BG_RELIABLE_bgc5=1 MOCK_BG_CPU_bgc5=500
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "declared runtime elapsed → resume clarify" "$out" \
    $'bgc5\tidle-children-clarify'

# (a6) health=stuck → idle-children-clarify (stuck).
rm -f "$STATE_DIR/idle-state.tsv"; : > "$LOG"; clear_bg_state
unset MOCK_PANE_STATE_bgc5 MOCK_BG_SHELLS_bgc5 MOCK_BG_RELIABLE_bgc5 MOCK_BG_CPU_bgc5
export MOCK_TMUX_WINDOWS="$(printf 'bgc6|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgc6 120 500
mkdir -p "$STATE_DIR/worker-health"
cat > "$STATE_DIR/worker-health/bgc6.json" <<EOF
{"window":"bgc6","health":"stuck","note":"sbatch --wait never returned","written_at":$NOW}
EOF
export MOCK_PANE_STATE_bgc6=working-background
export MOCK_BG_SHELLS_bgc6=1 MOCK_BG_RELIABLE_bgc6=1 MOCK_BG_CPU_bgc6=500
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "health=stuck → clarify" "$out" $'bgc6\tidle-children-clarify'
assert_contains "stuck detail says STUCK" "$out" "STUCK"

# (a7) health=done → idle-children-clarify (leftover children).
rm -f "$STATE_DIR/idle-state.tsv"; : > "$LOG"; clear_bg_state
unset MOCK_PANE_STATE_bgc6 MOCK_BG_SHELLS_bgc6 MOCK_BG_RELIABLE_bgc6 MOCK_BG_CPU_bgc6
export MOCK_TMUX_WINDOWS="$(printf 'bgc7|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgc7 120 500
mkdir -p "$STATE_DIR/worker-health"
cat > "$STATE_DIR/worker-health/bgc7.json" <<EOF
{"window":"bgc7","health":"done","written_at":$NOW}
EOF
export MOCK_PANE_STATE_bgc7=working-background
export MOCK_BG_SHELLS_bgc7=1 MOCK_BG_RELIABLE_bgc7=1 MOCK_BG_CPU_bgc7=500
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "health=done → clarify" "$out" $'bgc7\tidle-children-clarify'
assert_contains "done detail says DONE/leftover" "$out" "DONE"

# (a8) Frozen child past the HARD CEILING, no health → idle-too-long (reap).
rm -f "$STATE_DIR/idle-state.tsv"; : > "$LOG"; clear_bg_state
unset MOCK_PANE_STATE_bgc7 MOCK_BG_SHELLS_bgc7 MOCK_BG_RELIABLE_bgc7 MOCK_BG_CPU_bgc7
export MOCK_TMUX_WINDOWS="$(printf 'bgc8|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgc8 4000 500   # 4000 > ceiling 3600
export MOCK_PANE_STATE_bgc8=working-background
export MOCK_BG_SHELLS_bgc8=1 MOCK_BG_RELIABLE_bgc8=1 MOCK_BG_CPU_bgc8=500
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "frozen past ceiling → idle-too-long (reapable)" "$out" \
    $'bgc8\tidle-too-long'

# (a9) Unreliable reading (footer fallback, bg_reliable=0) → NOT the new
#      classes; legacy #445 flat-grace path governs (here: within legacy
#      grace → exempt).
rm -f "$STATE_DIR/idle-state.tsv"; : > "$LOG"; clear_bg_state
unset MOCK_PANE_STATE_bgc8 MOCK_BG_SHELLS_bgc8 MOCK_BG_RELIABLE_bgc8 MOCK_BG_CPU_bgc8
export MONITOR_BACKGROUND_ORPHAN_GRACE_SECONDS=100000
export MOCK_TMUX_WINDOWS="$(printf 'bgc9|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgc9 4000 500
export MOCK_PANE_STATE_bgc9=working-background
export MOCK_BG_SHELLS_bgc9=1 MOCK_BG_RELIABLE_bgc9=0 MOCK_BG_CPU_bgc9=500
run_probe_capture out rc 'list_really_idle_workers'
assert_not_contains "unreliable reading → no new #455-refine classes" "$out" \
    "idle-children-clarify"
assert_not_contains "unreliable reading → no idle-awaiting-job" "$out" \
    "idle-awaiting-job"
unset MONITOR_BACKGROUND_ORPHAN_GRACE_SECONDS

# (a10) READ-ONLY mode must NOT advance the backoff level or drop state —
#       the prelude counts without stealing the section's clarify nudge.
rm -f "$STATE_DIR/idle-state.tsv"; : > "$LOG"; clear_bg_state
export MOCK_TMUX_WINDOWS="$(printf 'bgcro|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgcro 120 500
export MOCK_PANE_STATE_bgcro=working-background
export MOCK_BG_SHELLS_bgcro=1 MOCK_BG_RELIABLE_bgcro=1 MOCK_BG_CPU_bgcro=500
# Read-only pass: still classifies as clarify (nudge due) but writes nothing.
run_probe_capture out rc 'MONITOR_IDLE_PROBE_READONLY=1 list_really_idle_workers'
assert_contains "readonly pass still classifies clarify" "$out" \
    $'bgcro\tidle-children-clarify'
assert_eq "readonly pass wrote NO backoff state" \
    "$( [[ -f "$STATE_DIR/bg-backoff/bgcro" ]] && echo present || echo absent )" \
    "absent"
# Authoritative pass then commits the escalation.
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "authoritative pass classifies clarify" "$out" \
    $'bgcro\tidle-children-clarify'
assert_eq "authoritative pass wrote backoff state" \
    "$( [[ -f "$STATE_DIR/bg-backoff/bgcro" ]] && echo present || echo absent )" \
    "present"
unset MOCK_PANE_STATE_bgcro MOCK_BG_SHELLS_bgcro MOCK_BG_RELIABLE_bgcro MOCK_BG_CPU_bgcro

# (b1) Wrapped worker WITH a live child → wrapped-with-children inconsistency.
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state
unset MOCK_PANE_STATE_bgc9 MOCK_BG_SHELLS_bgc9 MOCK_BG_RELIABLE_bgc9 MOCK_BG_CPU_bgc9
LOG="$STATE_DIR/action-log.jsonl"
echo '{"ts":"2026-05-10T12:00:00-07:00","event":"wrap-up","issue":"7","window":"bgw1","report":"bgw1_2026-05-10_120000_done.md","upload":"ok","comment":"ok","rocket":"ok"}' > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'bgw1|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgw1 30 500   # even a NON-frozen child would surface; use recent
export MOCK_PANE_STATE_bgw1=working-background
export MOCK_BG_SHELLS_bgw1=1 MOCK_BG_RELIABLE_bgw1=1 MOCK_BG_CPU_bgw1=500
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "wrapped + live child → wrapped-with-children" "$out" \
    $'bgw1\twrapped-with-children'

# (b2) wrapped-with-children fires even when the child CPU is ADVANCING
#      (the strongest inconsistency — wrapped while a job actively runs).
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state
unset MOCK_PANE_STATE_bgw1 MOCK_BG_SHELLS_bgw1 MOCK_BG_RELIABLE_bgw1 MOCK_BG_CPU_bgw1
echo '{"ts":"2026-05-10T12:00:00-07:00","event":"wrap-up","issue":"8","window":"bgw2","report":"bgw2_2026-05-10_120000_done.md","upload":"ok","comment":"ok","rocket":"ok"}' > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'bgw2|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
mkdir -p "$STATE_DIR/background-progress"
printf '%s\t%s\n' 400 "$(( NOW - 3600 ))" > "$STATE_DIR/background-progress/bgw2"
export MOCK_PANE_STATE_bgw2=working-background
export MOCK_BG_SHELLS_bgw2=1 MOCK_BG_RELIABLE_bgw2=1 MOCK_BG_CPU_bgw2=999  # advancing
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "wrapped + advancing child → still wrapped-with-children" "$out" \
    $'bgw2\twrapped-with-children'

# (b3) A wrap-up SUPERSEDED by a newer machine submit (re-tasked) is NOT a
#      wrapped state → case (a), not wrapped-with-children.
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state
unset MOCK_PANE_STATE_bgw2 MOCK_BG_SHELLS_bgw2 MOCK_BG_RELIABLE_bgw2 MOCK_BG_CPU_bgw2
echo '{"ts":"2026-05-10T12:00:00-07:00","event":"wrap-up","issue":"9","window":"bgw3","report":"bgw3_2026-05-10_120000_done.md","upload":"ok","comment":"ok","rocket":"ok"}' > "$LOG"
mkdir -p "$STATE_DIR/machine-submit"
echo "$NOW" > "$STATE_DIR/machine-submit/bgw3"   # re-tasked after wrap-up
export MOCK_TMUX_WINDOWS="$(printf 'bgw3|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgw3 120 500
export MOCK_PANE_STATE_bgw3=working-background
export MOCK_BG_SHELLS_bgw3=1 MOCK_BG_RELIABLE_bgw3=1 MOCK_BG_CPU_bgw3=500
run_probe_capture out rc 'list_really_idle_workers'
assert_not_contains "re-tasked wrap → NOT wrapped-with-children" "$out" \
    "wrapped-with-children"
assert_contains "re-tasked wrap → case (a) clarify instead" "$out" \
    $'bgw3\tidle-children-clarify'
rm -f "$STATE_DIR/machine-submit/bgw3"
unset MOCK_PANE_STATE_bgw3 MOCK_BG_SHELLS_bgw3 MOCK_BG_RELIABLE_bgw3 MOCK_BG_CPU_bgw3

# (b4) A skeptic-PARKED worker is wrapped-with-children BY DESIGN: `ng wrap-up`
#      is what writes the skeptic-pending marker, and the worker then holds its
#      `skeptic-channel await` re-check loop in a background shell. That is the
#      expected `parked-awaiting-skeptic` state, NOT an inconsistency.
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state
echo '{"ts":"2026-05-10T12:00:00-07:00","event":"wrap-up","issue":"10","window":"bgw4","report":"bgw4_2026-05-10_120000_done.md","upload":"ok","comment":"ok","rocket":"ok"}' > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'bgw4|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgw4 120 500
mkdir -p "$STATE_DIR/skeptic/pending"
echo 1 > "$STATE_DIR/skeptic/pending/bgw4"   # fresh marker → live park
export MOCK_PANE_STATE_bgw4=working-background
export MOCK_BG_SHELLS_bgw4=1 MOCK_BG_RELIABLE_bgw4=1 MOCK_BG_CPU_bgw4=500
run_probe_capture out rc 'list_really_idle_workers'
assert_not_contains "skeptic-parked + child → NOT wrapped-with-children" "$out" \
    "wrapped-with-children"
assert_contains "skeptic-parked + child → parked-awaiting-skeptic" "$out" \
    $'bgw4\tparked-awaiting-skeptic'
rm -f "$STATE_DIR/skeptic/pending/bgw4"
unset MOCK_PANE_STATE_bgw4 MOCK_BG_SHELLS_bgw4 MOCK_BG_RELIABLE_bgw4 MOCK_BG_CPU_bgw4

# (b5) Same shape, but the marker is STALE (the await loop died past the hang
#      threshold) → the park lapses and the inconsistency surfaces again. This
#      is what keeps the exemption from becoming an indefinite mute.
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state
echo '{"ts":"2026-05-10T12:00:00-07:00","event":"wrap-up","issue":"11","window":"bgw5","report":"bgw5_2026-05-10_120000_done.md","upload":"ok","comment":"ok","rocket":"ok"}' > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'bgw5|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgw5 120 500
mkdir -p "$STATE_DIR/skeptic/pending"
echo 1 > "$STATE_DIR/skeptic/pending/bgw5"
touch -d '@1' "$STATE_DIR/skeptic/pending/bgw5" 2>/dev/null \
    || touch -t 197001010000 "$STATE_DIR/skeptic/pending/bgw5"
export MOCK_PANE_STATE_bgw5=working-background
export MOCK_BG_SHELLS_bgw5=1 MOCK_BG_RELIABLE_bgw5=1 MOCK_BG_CPU_bgw5=500
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "stale skeptic marker → wrapped-with-children resurfaces" "$out" \
    $'bgw5\twrapped-with-children'
rm -f "$STATE_DIR/skeptic/pending/bgw5"
unset MOCK_PANE_STATE_bgw5 MOCK_BG_SHELLS_bgw5 MOCK_BG_RELIABLE_bgw5 MOCK_BG_CPU_bgw5
: > "$LOG"

# ---- (b6)-(b9): protocol-wait children are not an inconsistency (#590) ----
#
# The wrapped-with-children emit fired on EVERY skeptic-gated worker. Sequence:
# `ng wrap-up` tells the worker to hold a `skeptic-channel await` re-check loop
# in a background shell; the skeptic returns a verdict, which CLEARS the pending
# marker; the prescribed await child keeps polling until its own timeout. So the
# `parked-awaiting-skeptic` exemption (b4) lapses while the prescribed child is
# still alive, and the window resurfaced as an "inconsistency" demanding a
# decision. Firing routinely trains the operator to dismiss it — and then a
# genuine orphaned `sbatch` arrives looking like the twenty false ones before it.
# Reproduced live on 2026-07-29: two emits, both ~11-14 min AFTER the verdict
# that cleared the marker.

# (b6) Wrapped, marker already cleared, the ONLY child is a protocol await loop
#      → must NOT surface as an inconsistency.
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state
echo '{"ts":"2026-05-10T12:00:00-07:00","event":"wrap-up","issue":"12","window":"bgw6","report":"bgw6_2026-05-10_120000_done.md","upload":"ok","comment":"ok","rocket":"ok"}' > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'bgw6|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgw6 120 500
export MOCK_PANE_STATE_bgw6=working-background
export MOCK_BG_SHELLS_bgw6=1 MOCK_BG_RELIABLE_bgw6=1 MOCK_BG_CPU_bgw6=500
export MOCK_BG_OLDEST_START_bgw6="$(( NOW - 120 ))"   # young episode
export MOCK_BG_INFRA_bgw6=1
export MOCK_BG_CMD_bgw6='zsh:./monitor/skeptic-channel.sh_await_bgw6'
run_probe_capture out rc 'list_really_idle_workers'
assert_not_contains "protocol await loop only → NOT wrapped-with-children (#590)" "$out" \
    "wrapped-with-children"
unset MOCK_PANE_STATE_bgw6 MOCK_BG_SHELLS_bgw6 MOCK_BG_RELIABLE_bgw6 \
      MOCK_BG_CPU_bgw6 MOCK_BG_OLDEST_START_bgw6 MOCK_BG_INFRA_bgw6 MOCK_BG_CMD_bgw6

# (b7) NEGATIVE CONTROL for (b6): the same shape with a NON-protocol child
#      (a real orphaned job) MUST still surface. Without this, (b6) could be
#      passing because the detector was switched off wholesale.
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state
echo '{"ts":"2026-05-10T12:00:00-07:00","event":"wrap-up","issue":"13","window":"bgw7","report":"bgw7_2026-05-10_120000_done.md","upload":"ok","comment":"ok","rocket":"ok"}' > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'bgw7|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgw7 120 500
export MOCK_PANE_STATE_bgw7=working-background
export MOCK_BG_SHELLS_bgw7=1 MOCK_BG_RELIABLE_bgw7=1 MOCK_BG_CPU_bgw7=500
export MOCK_BG_OLDEST_START_bgw7="$(( NOW - 120 ))"
export MOCK_BG_INFRA_bgw7=0
export MOCK_BG_CMD_bgw7='zsh:sbatch_--mem_64G_run_pipeline.sh'
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "real orphaned job still surfaces (#590 negative control)" "$out" \
    $'bgw7\twrapped-with-children'
# and it NAMES the child — the whole point of #590's minimum ask.
assert_contains "the emit NAMES the offending child" "$out" \
    "sbatch_--mem_64G_run_pipeline.sh"
unset MOCK_PANE_STATE_bgw7 MOCK_BG_SHELLS_bgw7 MOCK_BG_RELIABLE_bgw7 \
      MOCK_BG_CPU_bgw7 MOCK_BG_OLDEST_START_bgw7 MOCK_BG_INFRA_bgw7 MOCK_BG_CMD_bgw7

# (b8) MIXED set: one protocol await loop + one real job → still surfaces, and
#      reports the count of children that need a DECISION (1), not the raw 2.
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state
echo '{"ts":"2026-05-10T12:00:00-07:00","event":"wrap-up","issue":"14","window":"bgw8","report":"bgw8_2026-05-10_120000_done.md","upload":"ok","comment":"ok","rocket":"ok"}' > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'bgw8|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgw8 120 500
export MOCK_PANE_STATE_bgw8=working-background
export MOCK_BG_SHELLS_bgw8=2 MOCK_BG_RELIABLE_bgw8=1 MOCK_BG_CPU_bgw8=500
export MOCK_BG_OLDEST_START_bgw8="$(( NOW - 120 ))"
export MOCK_BG_INFRA_bgw8=1
export MOCK_BG_CMD_bgw8='zsh:nohup_train.py'
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "mixed set → still surfaces the real child" "$out" \
    $'bgw8\twrapped-with-children'
assert_contains "mixed set → counts only the decision-worthy child" "$out" \
    "1 live child"
unset MOCK_PANE_STATE_bgw8 MOCK_BG_SHELLS_bgw8 MOCK_BG_RELIABLE_bgw8 \
      MOCK_BG_CPU_bgw8 MOCK_BG_OLDEST_START_bgw8 MOCK_BG_INFRA_bgw8 MOCK_BG_CMD_bgw8

# (b9) The (b6) exemption is BOUNDED, never a permanent mute. A single `await`
#      is self-limiting, but a worker that wraps it in an `until` loop would
#      otherwise hold the window exempt forever. Past the ABSOLUTE ceiling the
#      window surfaces again, with the loop named.
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state
echo '{"ts":"2026-05-10T12:00:00-07:00","event":"wrap-up","issue":"15","window":"bgw9","report":"bgw9_2026-05-10_120000_done.md","upload":"ok","comment":"ok","rocket":"ok"}' > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'bgw9|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgw9 120 500
# SAVE/RESTORE, never unset: line ~815 exports a section-wide ceiling of 3600
# that later cases (c3) depend on, so clearing it here would silently break them.
_saved_ceiling="${MONITOR_BG_CHILDREN_GRACE_CEILING_SECONDS:-}"
export MONITOR_BG_CHILDREN_GRACE_CEILING_SECONDS=600
export MOCK_PANE_STATE_bgw9=working-background
export MOCK_BG_SHELLS_bgw9=1 MOCK_BG_RELIABLE_bgw9=1 MOCK_BG_CPU_bgw9=500
export MOCK_BG_OLDEST_START_bgw9="$(( NOW - 5000 ))"   # far past the ceiling
export MOCK_BG_INFRA_bgw9=1
export MOCK_BG_CMD_bgw9='zsh:./monitor/skeptic-channel.sh_await_bgw9'
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "protocol-only exemption is bounded by the absolute ceiling" "$out" \
    $'bgw9\twrapped-with-children'
assert_contains "past-ceiling emit names the protocol loop" "$out" \
    "skeptic-channel.sh_await_bgw9"
if [[ -n "$_saved_ceiling" ]]; then
    export MONITOR_BG_CHILDREN_GRACE_CEILING_SECONDS="$_saved_ceiling"
else
    unset MONITOR_BG_CHILDREN_GRACE_CEILING_SECONDS
fi
unset _saved_ceiling
unset MOCK_PANE_STATE_bgw9 MOCK_BG_SHELLS_bgw9 MOCK_BG_RELIABLE_bgw9 \
      MOCK_BG_CPU_bgw9 MOCK_BG_OLDEST_START_bgw9 MOCK_BG_INFRA_bgw9 MOCK_BG_CMD_bgw9
: > "$LOG"

# (b10)/(b11) The FULL-STATE snapshot classifies INDEPENDENTLY of
# list_really_idle_workers, so it needs the same exclusion — otherwise the false
# positive fixed above simply reappears at the full-state cadence (which is
# exactly where the two 2026-07-29 emits were recorded: `*_full-state.md` and
# `*_resurface.md` under monitor/.state/diffs).
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state
echo '{"ts":"2026-05-10T12:00:00-07:00","event":"wrap-up","issue":"16","window":"bgs1","report":"bgs1_2026-05-10_120000_done.md","upload":"ok","comment":"ok","rocket":"ok"}' > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'bgs1|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_bgs1=working-background
export MOCK_BG_SHELLS_bgs1=1 MOCK_BG_RELIABLE_bgs1=1 MOCK_BG_CPU_bgs1=500
export MOCK_BG_INFRA_bgs1=1
export MOCK_BG_CMD_bgs1='zsh:./monitor/skeptic-channel.sh_await_bgs1'
run_probe_capture out rc 'render_full_state_snapshot'
assert_not_contains "snapshot: protocol-only child is NOT an inconsistency" "$out" \
    "wrapped-with-children"
assert_contains "snapshot: reported as the benign prescribed state" "$out" \
    "wrapped-awaiting-protocol"
unset MOCK_PANE_STATE_bgs1 MOCK_BG_SHELLS_bgs1 MOCK_BG_RELIABLE_bgs1 \
      MOCK_BG_CPU_bgs1 MOCK_BG_INFRA_bgs1 MOCK_BG_CMD_bgs1

rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state
echo '{"ts":"2026-05-10T12:00:00-07:00","event":"wrap-up","issue":"17","window":"bgs2","report":"bgs2_2026-05-10_120000_done.md","upload":"ok","comment":"ok","rocket":"ok"}' > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'bgs2|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_bgs2=working-background
export MOCK_BG_SHELLS_bgs2=1 MOCK_BG_RELIABLE_bgs2=1 MOCK_BG_CPU_bgs2=500
export MOCK_BG_INFRA_bgs2=0
export MOCK_BG_CMD_bgs2='zsh:sbatch_--mem_64G_run_pipeline.sh'
run_probe_capture out rc 'render_full_state_snapshot'
assert_contains "snapshot: a real orphaned job still surfaces" "$out" \
    "wrapped-with-children"
assert_contains "snapshot: and names the child" "$out" \
    "sbatch_--mem_64G_run_pipeline.sh"
unset MOCK_PANE_STATE_bgs2 MOCK_BG_SHELLS_bgs2 MOCK_BG_RELIABLE_bgs2 \
      MOCK_BG_CPU_bgs2 MOCK_BG_INFRA_bgs2 MOCK_BG_CMD_bgs2
: > "$LOG"

# (b12) your-org/nexus-code#1446: a child whose elapsed dwarfs its CPU is
#       BLOCKED, and the snapshot must NAME it — three >5h stalls read as
#       healthy-with-a-job here. The stub passes `bg_wedged=1 bg_cpu_bp=2`.
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state
echo '{"ts":"2026-05-10T12:00:00-07:00","event":"wrap-up","issue":"18","window":"bgs3","report":"bgs3_2026-05-10_120000_done.md","upload":"ok","comment":"ok","rocket":"ok"}' > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'bgs3|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_bgs3=working-background
export MOCK_BG_SHELLS_bgs3=1 MOCK_BG_RELIABLE_bgs3=1 MOCK_BG_CPU_bgs3=428
export MOCK_BG_INFRA_bgs3=0
export MOCK_BG_CMD_bgs3='zsh:grep_-raIl_PR_22049'
export MOCK_BG_WEDGED_bgs3=1
run_probe_capture out rc 'render_full_state_snapshot'
assert_contains "snapshot: a wedged child is NAMED as such (#1446)" "$out" \
    "WEDGED? child at 2 bp CPU"
# CONTROL: the same window with bg_wedged=0 carries no such note.
export MOCK_BG_WEDGED_bgs3=0
run_probe_capture out rc 'render_full_state_snapshot'
assert_not_contains "snapshot: bg_wedged=0 → no WEDGED note (control)" "$out" \
    "WEDGED?"
unset MOCK_PANE_STATE_bgs3 MOCK_BG_SHELLS_bgs3 MOCK_BG_RELIABLE_bgs3 \
      MOCK_BG_CPU_bgs3 MOCK_BG_INFRA_bgs3 MOCK_BG_CMD_bgs3 MOCK_BG_WEDGED_bgs3
: > "$LOG"

# (b13) your-org/nexus-code#1460: lifetime CPU cannot tell a wedge from a
#       sequential driver blocked in wait(); MEMBERSHIP TURNOVER can. With a
#       `bg_members` digest on the line, the note is decided across ticks:
#       first sight -> recorded, not yet WEDGED; same digest again -> WEDGED
#       with the static age; a different digest -> a driver, not a wedge.
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state; rm -rf "$STATE_DIR/bg-members"
echo '{"ts":"2026-05-10T12:00:00-07:00","event":"wrap-up","issue":"18","window":"bgs4","report":"bgs4_2026-05-10_120000_done.md","upload":"ok","comment":"ok","rocket":"ok"}' > "$LOG"
export MOCK_TMUX_WINDOWS="$(printf 'bgs4|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
export MOCK_PANE_STATE_bgs4=working-background
export MOCK_BG_SHELLS_bgs4=1 MOCK_BG_RELIABLE_bgs4=1 MOCK_BG_CPU_bgs4=53
export MOCK_BG_INFRA_bgs4=0
export MOCK_BG_CMD_bgs4='bash:guards-for-diff.sh_--run'
export MOCK_BG_WEDGED_bgs4=1
export MOCK_BG_MEMBERS_bgs4=1111111111
run_probe_capture out rc 'render_full_state_snapshot'
assert_not_contains "snapshot (#1460): first sight of a digest is NOT yet called WEDGED" "$out" "WEDGED?"
assert_contains "snapshot (#1460): …it says the membership is recorded for the next tick" "$out" \
    "compared next tick"
assert_file_exists "snapshot (#1460): the digest is recorded per window" "$STATE_DIR/bg-members/bgs4"
# Same digest on the next tick: static membership — the wedge signature.
run_probe_capture out rc 'render_full_state_snapshot'
assert_contains "snapshot (#1460): a STATIC membership across ticks is WEDGED" "$out" "WEDGED? child at 2 bp CPU"
assert_contains "snapshot (#1460): …and the note names the static membership" "$out" \
    "membership has been STATIC for"
# A different digest: a descendant started or exited — a driver, never a wedge.
export MOCK_BG_MEMBERS_bgs4=2222222222
run_probe_capture out rc 'render_full_state_snapshot'
assert_not_contains "snapshot (#1460): membership TURNOVER suppresses the WEDGED note" "$out" "WEDGED?"
assert_contains "snapshot (#1460): …and says why — a driver blocked in wait(), a wedge cannot produce an exit" "$out" \
    "cannot produce an exit"
# CONTROL: the b12 shape (no digest on the line) keeps the pre-#1460 reading.
unset MOCK_BG_MEMBERS_bgs4
run_probe_capture out rc 'render_full_state_snapshot'
assert_contains "snapshot (#1460 control): no digest on the line -> the pre-#1460 WEDGED note, marked unmeasured" "$out" \
    "WEDGED? child at 2 bp CPU (0.01%=1) over its whole episode (membership not measured)"
unset MOCK_PANE_STATE_bgs4 MOCK_BG_SHELLS_bgs4 MOCK_BG_RELIABLE_bgs4 \
      MOCK_BG_CPU_bgs4 MOCK_BG_INFRA_bgs4 MOCK_BG_CMD_bgs4 MOCK_BG_WEDGED_bgs4
rm -rf "$STATE_DIR/bg-members"
: > "$LOG"

# ---- inverted priority: the exemption is BOUNDED (#455 follow-up) ---------
#
# "We'd rather misclassify and consider retiring a worker rather than having
# it stick around forever." Every with-children exemption must therefore be
# bounded by the hard ceiling: neither a `running` health declaration nor a
# CPU-advancing child may suppress the window indefinitely. Past the ceiling
# the window surfaces as a retire CANDIDATE — retire-preflight still gates the
# kill.
echo '=== bounded exemption: ceiling dominates health decl + CPU advance ==='

# (c1) health=running with a declared runtime that would outlast the ceiling →
#      the deadline is CLAMPED; past the ceiling the window surfaces
#      idle-too-long instead of being extended forever.
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state
export MOCK_TMUX_WINDOWS="$(printf 'bgcap1|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgcap1 4000 500        # frozen 4000s > ceiling 3600
mkdir -p "$STATE_DIR/worker-health"
cat > "$STATE_DIR/worker-health/bgcap1.json" <<EOF
{"window":"bgcap1","job_kind":"slurm","job_id":"52527999","expected_runtime_s":999999999,"health":"running","written_at":$(date +%s)}
EOF
export MOCK_PANE_STATE_bgcap1=working-background
export MOCK_BG_SHELLS_bgcap1=1 MOCK_BG_RELIABLE_bgcap1=1 MOCK_BG_CPU_bgcap1=500
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "running decl past ceiling → idle-too-long (retire candidate)" "$out" \
    $'bgcap1\tidle-too-long'
assert_contains "ceiling row echoes the declaration for investigation" "$out" \
    "worker declared running"
unset MOCK_PANE_STATE_bgcap1 MOCK_BG_SHELLS_bgcap1 MOCK_BG_RELIABLE_bgcap1 MOCK_BG_CPU_bgcap1

# (c2) health=running, within the ceiling, but the declared deadline exceeds
#      it → still exempt this cycle, and the row says the deadline was clamped.
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state
export MOCK_TMUX_WINDOWS="$(printf 'bgcap2|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgcap2 120 500         # 120s ≪ ceiling 3600
mkdir -p "$STATE_DIR/worker-health"
cat > "$STATE_DIR/worker-health/bgcap2.json" <<EOF
{"window":"bgcap2","job_kind":"slurm","expected_runtime_s":999999999,"health":"running","written_at":$(date +%s)}
EOF
export MOCK_PANE_STATE_bgcap2=working-background
export MOCK_BG_SHELLS_bgcap2=1 MOCK_BG_RELIABLE_bgcap2=1 MOCK_BG_CPU_bgcap2=500
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "running decl within ceiling → still exempt" "$out" \
    $'bgcap2\tidle-awaiting-job'
assert_contains "over-long declaration is clamped to the ceiling" "$out" \
    "clamped to ceiling"
unset MOCK_PANE_STATE_bgcap2 MOCK_BG_SHELLS_bgcap2 MOCK_BG_RELIABLE_bgcap2 MOCK_BG_CPU_bgcap2

# (c2b) A modest declaration that fits INSIDE the ceiling is honoured as-is —
#       no clamp note, deadline is the worker's own.
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state
export MOCK_TMUX_WINDOWS="$(printf 'bgcap2b|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgcap2b 120 500
mkdir -p "$STATE_DIR/worker-health"
cat > "$STATE_DIR/worker-health/bgcap2b.json" <<EOF
{"window":"bgcap2b","job_kind":"slurm","expected_runtime_s":600,"health":"running","written_at":$(date +%s)}
EOF
export MOCK_PANE_STATE_bgcap2b=working-background
export MOCK_BG_SHELLS_bgcap2b=1 MOCK_BG_RELIABLE_bgcap2b=1 MOCK_BG_CPU_bgcap2b=500
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "in-ceiling declaration honoured → idle-awaiting-job" "$out" \
    $'bgcap2b\tidle-awaiting-job'
assert_not_contains "in-ceiling declaration is NOT clamped" "$out" "clamped to ceiling"
unset MOCK_PANE_STATE_bgcap2b MOCK_BG_SHELLS_bgcap2b MOCK_BG_RELIABLE_bgcap2b MOCK_BG_CPU_bgcap2b

# (c3) A CPU-ADVANCING child (a quiet polling loop) can never freeze, so the
#      CPU-freeze clock resets every cycle. The EPISODE age, derived from the
#      oldest live background shell's start time, cannot be reset that way:
#      past the ceiling it surfaces as a retire candidate. This is the case
#      the old "never false-idle a live worker" priority suppressed forever.
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state
export MOCK_TMUX_WINDOWS="$(printf 'bgcap3|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgcap3 0 500          # CPU advancing → freeze clock resets
export MOCK_PANE_STATE_bgcap3=working-background
export MOCK_BG_SHELLS_bgcap3=1 MOCK_BG_RELIABLE_bgcap3=1 MOCK_BG_CPU_bgcap3=999
export MOCK_BG_OLDEST_START_bgcap3=$(( $(date +%s) - 4000 ))   # episode > ceiling
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "advancing child past ceiling → idle-too-long (bounded)" "$out" \
    $'bgcap3\tidle-too-long'
unset MOCK_PANE_STATE_bgcap3 MOCK_BG_SHELLS_bgcap3 MOCK_BG_RELIABLE_bgcap3 \
      MOCK_BG_CPU_bgcap3 MOCK_BG_OLDEST_START_bgcap3

# (c4) …but an advancing child WITHIN the ceiling stays silently exempt: the
#      bound is a ceiling, not a new nag. No regression for live compute.
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state
export MOCK_TMUX_WINDOWS="$(printf 'bgcap4|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgcap4 0 500
export MOCK_PANE_STATE_bgcap4=working-background
export MOCK_BG_SHELLS_bgcap4=1 MOCK_BG_RELIABLE_bgcap4=1 MOCK_BG_CPU_bgcap4=999
export MOCK_BG_OLDEST_START_bgcap4=$(( $(date +%s) - 100 ))
run_probe_capture out rc 'list_really_idle_workers'
assert_not_contains "advancing child within ceiling → still silent exempt" "$out" \
    "bgcap4"
unset MOCK_PANE_STATE_bgcap4 MOCK_BG_SHELLS_bgcap4 MOCK_BG_RELIABLE_bgcap4 \
      MOCK_BG_CPU_bgcap4 MOCK_BG_OLDEST_START_bgcap4

# (c6) your-org/nexus-code#1221 — THE PROPERTY, and the coverage hole it fills.
#      ONE jiffy of advance annihilates an arbitrarily old freeze clock: a stamp
#      5000s stale (base=60 here) is reset to zero by bg_cpu 500 -> 501. That is
#      the mechanism which makes `bg_stall_age >= bg_base` unreachable for any
#      child advancing even once per base — measured, a bare `sleep N` poll loop
#      advances ~1 jiffy per 51*N seconds, so every poll period under ~70s
#      defeats it. The EPISODE ceiling is the only bound that binds such a child.
#
#      Worth pinning because every OTHER children-path case pre-seeds the stamp
#      by hand via seed_frozen_child, so no assertion above depends on
#      _bg_progress_check's freeze/advance decision at all: it could be replaced
#      with `printf '%s' "$now"` and only the orphan-path case would notice.
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state
export MOCK_TMUX_WINDOWS="$(printf 'bgpoll|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgpoll 5000 500                            # freeze clock 5000s >> base 60
export MOCK_PANE_STATE_bgpoll=working-background
export MOCK_BG_SHELLS_bgpoll=1 MOCK_BG_RELIABLE_bgpoll=1
export MOCK_BG_CPU_bgpoll=501                                # ONE jiffy of advance
export MOCK_BG_OLDEST_START_bgpoll=$(( $(date +%s) - 100 ))  # episode YOUNG: ceiling cannot fire
run_probe_capture out rc 'list_really_idle_workers'
assert_not_contains "one jiffy of advance annihilates a 5000s freeze clock (#1221)" \
    "$out" "bgpoll"

# (c6b) THE PAIRED POSITIVE CONTROL, and it is the point rather than (c6).
#       (c6) alone is an ABSENCE assertion and could pass for the wrong reason —
#       any unrelated exemption silencing the row would satisfy it, which is this
#       workspace's dominant defect class. (c6b) holds every variable constant
#       except the CPU delta and demands the row APPEAR. Together they assert the
#       property; separately, neither does.
#
#       It is also the grace's LIVE CONSTITUENCY, which is why #1221 resolves to
#       DOC rather than DROP: a child that forks nothing (`sbatch --wait`, bare
#       `wait`, `read` on a fifo) measured 0 jiffies over 90s, so the freeze
#       clock is the operative bound for that shape and fires 47 hours before
#       the ceiling would.
rm -f "$STATE_DIR/idle-state.tsv"; : > "$LOG"; clear_bg_state
export MOCK_TMUX_WINDOWS="$(printf 'bgpoll|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgpoll 5000 500
export MOCK_BG_CPU_bgpoll=500                                # UNCHANGED: frozen
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "…and a FROZEN clock at the same age DOES surface (#1221)" \
    "$out" $'bgpoll\t'
unset MOCK_PANE_STATE_bgpoll MOCK_BG_SHELLS_bgpoll MOCK_BG_RELIABLE_bgpoll \
      MOCK_BG_CPU_bgpoll MOCK_BG_OLDEST_START_bgpoll

# (c5) CHURN in the child COUNT must NOT reset the ceiling. Background shells
#      come and go routinely; an earlier cut keyed the episode clock on the
#      count, so any fluctuation reset it and the worker could linger forever.
#      The age is now derived from the OLDEST live shell, so the count is
#      irrelevant: 1 → 3 → 1 → 5 children all still hit the ceiling.
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state
export MOCK_TMUX_WINDOWS="$(printf 'bgcap5|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgcap5 0 500
export MOCK_PANE_STATE_bgcap5=working-background
export MOCK_BG_RELIABLE_bgcap5=1 MOCK_BG_CPU_bgcap5=999
export MOCK_BG_OLDEST_START_bgcap5=$(( $(date +%s) - 4000 ))
for _n in 1 3 1 5; do
    rm -f "$STATE_DIR/idle-state.tsv"
    export MOCK_BG_SHELLS_bgcap5="$_n"
    run_probe_capture out rc 'list_really_idle_workers'
    assert_contains "child-count churn (n=$_n) does NOT reset the ceiling" "$out" \
        $'bgcap5\tidle-too-long'
done
unset MOCK_PANE_STATE_bgcap5 MOCK_BG_SHELLS_bgcap5 MOCK_BG_RELIABLE_bgcap5 \
      MOCK_BG_CPU_bgcap5 MOCK_BG_OLDEST_START_bgcap5

# (c7) A NEW job (a fresh background shell) starts a fresh episode: its
#      oldest-start is recent, so it is silently exempt rather than inheriting
#      the previous job's age and surfacing as an instant false retire-candidate.
#      This holds regardless of what the pane rendered in between — there is no
#      stored clock to inherit.
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state
export MOCK_TMUX_WINDOWS="$(printf 'bgcap7|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgcap7 0 500
export MOCK_PANE_STATE_bgcap7=working-background
export MOCK_BG_SHELLS_bgcap7=1 MOCK_BG_RELIABLE_bgcap7=1 MOCK_BG_CPU_bgcap7=999
export MOCK_BG_OLDEST_START_bgcap7=$(date +%s)   # brand-new shell
run_probe_capture out rc 'list_really_idle_workers'
assert_not_contains "new job does not inherit the old episode's age" "$out" \
    $'bgcap7\tidle-too-long'
unset MOCK_PANE_STATE_bgcap7 MOCK_BG_SHELLS_bgcap7 MOCK_BG_RELIABLE_bgcap7 \
      MOCK_BG_CPU_bgcap7 MOCK_BG_OLDEST_START_bgcap7

# (c8) GHOST-CYCLE REGRESSION (round-2 skeptic finding). `autosuggest-only` is
#      emitted from pane-state's renderer ladder BEFORE the process tree is
#      walked, so it carries no child information at all. An earlier cut treated
#      it as an authoritative "no children" reading and deleted the stored
#      episode clock — silently, before the idle-age gate, emitting no row. One
#      dim autosuggest ghost per ~60 poll cycles was enough to suppress a window
#      forever. With the age DERIVED from the process tree there is nothing to
#      delete: a ghost cycle passes through and the next working-background
#      cycle still reports the full episode age.
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state
export MOCK_TMUX_WINDOWS="$(printf 'bgghost|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgghost 0 500
GHOST_START=$(( $(date +%s) - 4000 ))   # episode well past the 3600s ceiling
# cycle 1: working-background, past ceiling → surfaces.
export MOCK_PANE_STATE_bgghost=working-background
export MOCK_BG_SHELLS_bgghost=1 MOCK_BG_RELIABLE_bgghost=1 MOCK_BG_CPU_bgghost=999
export MOCK_BG_OLDEST_START_bgghost="$GHOST_START"
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "pre-ghost cycle surfaces at the ceiling" "$out" \
    $'bgghost\tidle-too-long'
# cycle 2: the GHOST — a dim autosuggest render, same live child underneath.
rm -f "$STATE_DIR/idle-state.tsv"
export MOCK_PANE_STATE_bgghost=autosuggest-only
unset MOCK_BG_SHELLS_bgghost MOCK_BG_RELIABLE_bgghost MOCK_BG_OLDEST_START_bgghost
run_probe_capture out rc 'list_really_idle_workers'
# cycle 3: back to working-background, SAME shell → episode age intact.
rm -f "$STATE_DIR/idle-state.tsv"
export MOCK_PANE_STATE_bgghost=working-background
export MOCK_BG_SHELLS_bgghost=1 MOCK_BG_RELIABLE_bgghost=1 MOCK_BG_CPU_bgghost=999
export MOCK_BG_OLDEST_START_bgghost="$GHOST_START"
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "ghost cycle does NOT reset the episode age" "$out" \
    $'bgghost\tidle-too-long'
unset MOCK_PANE_STATE_bgghost MOCK_BG_SHELLS_bgghost MOCK_BG_RELIABLE_bgghost \
      MOCK_BG_CPU_bgghost MOCK_BG_OLDEST_START_bgghost

# (c9) The episode age is DERIVED — no `bg-firstseen` state file is created by
#      any of the above. Nothing to migrate, leak, or go stale.
assert_eq "no bg-firstseen state dir is ever created" \
    "$( [[ -d "$STATE_DIR/bg-firstseen" ]] && echo present || echo absent )" \
    "absent"

# (c6) An unknown/absent `bg_oldest_start` (a footer-fallback or an unreadable
#      /proc) means UNKNOWN, never "past the ceiling": the window must not be
#      surfaced as a retire candidate on missing evidence.
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state
export MOCK_TMUX_WINDOWS="$(printf 'bgcapunk|%s' "$OLD_TS")"
seed_engagement_log_matching_activity
seed_frozen_child bgcapunk 0 500
export MOCK_PANE_STATE_bgcapunk=working-background
export MOCK_BG_SHELLS_bgcapunk=1 MOCK_BG_RELIABLE_bgcapunk=1 MOCK_BG_CPU_bgcapunk=999
run_probe_capture out rc 'list_really_idle_workers'   # no MOCK_BG_OLDEST_START
assert_not_contains "missing bg_oldest_start → not a retire candidate" "$out" \
    $'bgcapunk\tidle-too-long'
unset MOCK_PANE_STATE_bgcapunk MOCK_BG_SHELLS_bgcapunk MOCK_BG_RELIABLE_bgcapunk \
      MOCK_BG_CPU_bgcapunk

unset MONITOR_BG_CHILDREN_GRACE_BASE_SECONDS MONITOR_BG_CHILDREN_INTERVAL_CAP_SECONDS \
      MONITOR_BG_CHILDREN_GRACE_CEILING_SECONDS MONITOR_WORKER_HEALTH_SLACK_SECONDS
: > "$LOG"

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

echo '=== the orphan-async advisory BRANCHES on wait class (your-org/nexus-code#1240) ==='
#
# THE PROPERTY: a wait whose job has already reached `terminal` must NOT be
# told "a wait you have not confirmed dead must not be cleared". That sentence
# is correct for `running` and `died` and unsatisfiable for a job that exited
# normally — the reader can never confirm a finished job DEAD, so the guidance
# forbids the one correct action and the worker has no exit. Seven recorded
# instances, all rc=0, one stale for sixteen hours.
#
# Both branches are asserted in BOTH directions (present AND absent), because a
# branch that renders the right words while ALSO rendering the wrong ones is
# the failure this is guarding against.

render_orphan_row() {   # $1 = the detail column ($4)
    rm -f "$STATE_DIR/idle-state.tsv"
    PATH="$STUB_DIR:$PATH" bash -c "
        set -uo pipefail
        STATE_DIR='$STATE_DIR'
        NEXUS_ROOT='$NEXUS_ROOT'
        source '$PROBE'
        list_really_idle_workers() {
            printf 'orphw\tidle-orphan-async\t120\t%s\n' '$1'
        }
        render_idle_section
    " 2>/dev/null
}

out=$(render_orphan_row 'terminal|asyncrun:ar-deadbeefcafe')
assert_contains     "terminal branch: says the jobs have FINISHED" "$out" "ALREADY FINISHED"
assert_contains     "terminal branch: orders --status-line first"  "$out" "--status-line"
assert_contains     "terminal branch: names the sanctioned verb"   "$out" "declare-no-wait asyncrun"
assert_contains     "terminal branch: warns an empty rc is uncorroborated" "$out" "UNCORROBORATED"
assert_not_contains "terminal branch: does NOT forbid clearing"    "$out" "must not be cleared"
assert_not_contains "terminal branch: does NOT prescribe a poller" "$out" "background poller"

out=$(render_orphan_row 'unresolved|asyncrun:ar-0123456789ab')
assert_contains     "unresolved branch: keeps the do-not-clear rule" "$out" "must not be cleared"
assert_not_contains "unresolved branch: does NOT offer the verb"     "$out" "declare-no-wait"

# The legacy 4th-column shape (no class prefix) must degrade to the SAFE arm.
out=$(render_orphan_row 'slurm:52527284_4')
assert_contains     "legacy detail degrades to the do-not-clear text" "$out" "must not be cleared"
assert_contains     "legacy detail still quotes the job"              "$out" "slurm:52527284_4"

echo '=== _idle_orphan_wait_class resolves fail-CLOSED ==='
#
# The classifier is where the safety lives: everything not POSITIVELY
# established terminal must return `unresolved`. Asserted by planting real
# status files under a real STATE_DIR, not by reading the source.
# The classifier now returns `<class>|<counts>`. These arms assert the CLASS;
# the counts are asserted by the cardinality block below, which is where they
# carry meaning.
wc_class() { printf '%s' "${1%%|*}"; }
wc_probe() {   # $1 = window, $2 = kinds
    PATH="$STUB_DIR:$PATH" bash -c "
        set -uo pipefail
        STATE_DIR='$STATE_DIR'
        NEXUS_ROOT='$NEXUS_ROOT'
        source '$PROBE'
        _idle_orphan_wait_class '$1' '$2'
    " 2>/dev/null
}
_wc_enc=$(bash -c "source '$NEXUS_ROOT/monitor/_bookkeeping.sh' 2>/dev/null; wk_encode wcw" 2>/dev/null)
[[ -n "$_wc_enc" ]] || _wc_enc=wcw
_wc_root="$STATE_DIR/async-run/$_wc_enc"
mkdir -p "$_wc_root/ar-aaaaaaaaaaaa" "$_wc_root/ar-bbbbbbbbbbbb" "$_wc_root/ar-cccccccccccc"
printf 'rc=0\n' > "$_wc_root/ar-aaaaaaaaaaaa/status"
printf 'rc=0\n' > "$_wc_root/ar-bbbbbbbbbbbb/status"
# ar-cccccccccccc deliberately has NO status file — the `died`/`running` shape.

assert_eq "one terminal token → terminal" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-aaaaaaaaaaaa')")" terminal
assert_eq "two terminal tokens → terminal" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-aaaaaaaaaaaa,asyncrun:ar-bbbbbbbbbbbb')")" terminal
# THE ARM THAT MATTERS: one unfinished job among finished ones must not be
# reported as finished. `all terminal` is a conjunction, not a majority.
assert_eq "one token WITHOUT a status file → unresolved" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-aaaaaaaaaaaa,asyncrun:ar-cccccccccccc')")" unresolved
assert_eq "a non-asyncrun kind → untracked" \
    "$(wc_class "$(wc_probe wcw 'slurm:52527284_4')")" untracked
# RE-BASELINED, NOT DECIDED (your-org/nexus-code#1311). `git log -G` shows this
# was written `→ unresolved` at cbf61b0a and flipped to `→ untracked` 4.5h later
# at 002f1138, the commit that CREATED the untracked class, in a block edit whose
# rationale argues only the HOMOGENEOUS case. Do not cite it as evidence that the
# mixed case was deliberated — it froze the behaviour. #1311 is dispositioned on
# the issue own argument instead, and shipped as a PROSE fix.
assert_eq "a MIXED list with a slurm wait → untracked" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-aaaaaaaaaaaa,slurm:1')")" untracked
# A truncated list cannot support an all-terminal claim: the waits the 80-char
# cap removed are unknown, and unknown is not terminal.
assert_eq "a TRUNCATED list → unresolved" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-aaaaaaaaaaaa,asyncrun:ar-bbbbb…')")" unresolved
assert_eq "an empty list → unresolved"   "$(wc_class "$(wc_probe wcw '')")" unresolved
assert_eq "the literal unknown → unresolved" "$(wc_class "$(wc_probe wcw 'unknown')")" unresolved
assert_eq "a malformed token → untracked" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:not-a-token')")" untracked
# A window with no async-run dir at all — the ordinary case for most windows.
assert_eq "a window with no async-run state → untracked" \
    "$(wc_class "$(wc_probe wcw-absent 'asyncrun:ar-aaaaaaaaaaaa')")" untracked

echo '=== your-org/nexus-code#1292 — RUNNING is a THIRD state, resolved by (pid, pidstart) ==='
# 11 of 13 listed waits on this board had a terminal rc on disk (stale 5 to 304
# min); the two that did NOT are the only ones the warning exists for, and they
# were invisible among the stale ones. Two states could not express that.
#
# THE PID-REUSE ARM IS THE POINT. A recorded pid can still be present in /proc
# as a DIFFERENT process — measured on this board, starttime 911215293 against
# a recorded 910769323. A check on the pid alone says ALIVE; a kill on it hits
# a stranger. So `running` requires BOTH pid and start-time to match, which is
# delegated to monitor/proc-exists-authorized rather than re-derived.
_wc_live_root="$STATE_DIR/async-run/$_wc_enc"
mkdir -p "$_wc_live_root/ar-dddddddddddd" "$_wc_live_root/ar-eeeeeeeeeeee"
# A REAL live process we own, with its REAL start-time — no status file.
sleep 120 &
_wc_livepid=$!
_wc_livest=$(awk '{n=split($0,a,") "); split(a[n],f," "); print f[20]}' "/proc/$_wc_livepid/stat" 2>/dev/null)
printf '%s\n' "$_wc_livepid" > "$_wc_live_root/ar-dddddddddddd/pid"
printf '%s\n' "$_wc_livest" > "$_wc_live_root/ar-dddddddddddd/pidstart"
# POSITIVE CONTROL on the fixture itself: without a real start-time every arm
# below would be satisfied by the fail-closed path for the wrong reason.
if [[ -n "$_wc_livest" && "$_wc_livest" =~ ^[0-9]+$ ]]; then
    printf '  PASS: fixture planted a live pid with a readable start-time\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: fixture could not read a start-time for pid %s\n' "$_wc_livepid" >&2; FAIL=$(( FAIL + 1 ))
fi
assert_eq "a live (pid,pidstart) with no status → running" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-dddddddddddd')")" running
# SAME pid, WRONG start-time: the recycled-pid case. Must NOT be running.
printf '%s\n' "$(( _wc_livest + 987654 ))" > "$_wc_live_root/ar-dddddddddddd/pidstart"
assert_eq "same pid, WRONG start-time (RECYCLED) → unresolved, not running" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-dddddddddddd')")" unresolved
printf '%s\n' "$_wc_livest" > "$_wc_live_root/ar-dddddddddddd/pidstart"
# No status and no pid files at all: the genuinely indeterminate case.
assert_eq "no status and no recorded pid → unresolved" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-eeeeeeeeeeee')")" unresolved
# A live job MIXED with a finished one is still work in flight.
assert_eq "one terminal + one live → running" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-aaaaaaaaaaaa,asyncrun:ar-dddddddddddd')")" running
# ALL terminal still wins over running — the arm order must not regress.
assert_eq "all terminal (no live) → terminal, not running" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-aaaaaaaaaaaa,asyncrun:ar-bbbbbbbbbbbb')")" terminal
kill "$_wc_livepid" 2>/dev/null; wait "$_wc_livepid" 2>/dev/null
# With the process GONE and still no status, the same token must fall to
# unresolved — this is the `died` shape, and the arm that proves the running
# verdict was about the PROCESS and not about the files being present.
assert_eq "…and once that process EXITS, the same token → unresolved" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-dddddddddddd')")" unresolved

# The emit must SAY which of the three it is, or the third state changes nothing.
out=$(render_orphan_row 'running|asyncrun:ar-dddddddddddd')
assert_contains     "running branch: says a job is still RUNNING"      "$out" "still RUNNING"
assert_contains     "running branch: keeps the do-not-clear rule"      "$out" "must not be cleared"
assert_not_contains "running branch: does NOT offer the verb"          "$out" "declare-no-wait"
out=$(render_orphan_row 'unresolved|asyncrun:ar-eeeeeeeeeeee')
assert_contains     "unresolved branch: says it is NOT verifiable"     "$out" "NOT verifiable"
assert_not_contains "unresolved branch: does not claim a live process" "$out" "still RUNNING"

echo '=== #1292 review: the classifier must FIRE AT REAL CARDINALITY, not just at 2 ==='
# THE DEFECT THIS PINS. `orphan_kinds` is capped at 80 chars for DISPLAY, and
# `asyncrun:ar-xxxxxxxxxxxx` is 24 chars plus a comma — so the cap truncates at
# FOUR waits. The first cut of the classifier fail-closed on truncation, which
# made it INERT for every window with >= 4 waits: measured, it reached 1 of the
# 4 windows in #1292 own evidence table, and 0 of the 13- and 11-wait windows
# an operator then had to sort BY HAND.
#
# A guard that does not fire at the cardinality its defect occurs at is not a
# guard, so these cases are sized from the REAL population — 4, 11, 13, 15 —
# and the classifier now reads the UNCAPPED list from the heartbeat.
_card_win=cardw
_card_hb="$STATE_DIR/heartbeat"; mkdir -p "$_card_hb"
# $1 terminal, $2 nohup-untracked, $3 died  -> writes heartbeat + async-run dirs
plant_waits() {
    local nt="$1" nu="$2" nd="$3" i t w=""
    rm -rf "$STATE_DIR/async-run/$_card_win"; mkdir -p "$STATE_DIR/async-run/$_card_win"
    for (( i=1; i<=nt; i++ )); do
        t=$(printf 'ar-t%011d' "$i"); mkdir -p "$STATE_DIR/async-run/$_card_win/$t"
        printf 'rc=0\n' > "$STATE_DIR/async-run/$_card_win/$t/status"
        w="$w{\"kind\":\"asyncrun\",\"id\":\"$t\"},"
    done
    for (( i=1; i<=nu; i++ )); do w="$w{\"kind\":\"nohup\",\"id\":\"nh-$i\"},"; done
    for (( i=1; i<=nd; i++ )); do
        t=$(printf 'ar-d%011d' "$i"); mkdir -p "$STATE_DIR/async-run/$_card_win/$t"
        printf '999999\n' > "$STATE_DIR/async-run/$_card_win/$t/pid"
        printf '1\n'      > "$STATE_DIR/async-run/$_card_win/$t/pidstart"
        w="$w{\"kind\":\"asyncrun\",\"id\":\"$t\"},"
    done
    printf '{"last_activity":%s,"external_waits":[%s]}' "$(date +%s)" "${w%,}" \
        > "$_card_hb/$_card_win.json"
}
# The capped string EXACTLY as pane-state hands it over, ellipsis and all — so
# the arms below are driven through the same truncation the defect rode in on.
capped_of() {
    local csv; csv=$(python3 - "$_card_hb/$_card_win.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
s=",".join("%s:%s"%(w["kind"],w["id"]) for w in d["external_waits"])
print(s[:79]+"…" if len(s)>80 else s)
PY
); printf '%s' "$csv"
}
card_probe() {
    PATH="$STUB_DIR:$PATH" bash -c "
        set -uo pipefail
        STATE_DIR='$STATE_DIR'
        NEXUS_ROOT='$NEXUS_ROOT'
        source '$PROBE'
        _idle_orphan_wait_class '$_card_win' \"\$1\"
    " _ "$1" 2>/dev/null
}

# POSITIVE CONTROL on the fixture: the cap must actually be truncating at 4, or
# every assertion below passes for the wrong reason.
plant_waits 4 0 0
_cap4=$(capped_of)
if [[ "$_cap4" == *…* ]]; then
    printf '  PASS: fixture confirms the 80-char cap TRUNCATES at 4 waits\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: 4 waits did not truncate (len=%s) — the cardinality arms would be vacuous\n' "${#_cap4}" >&2
    FAIL=$(( FAIL + 1 ))
fi
assert_eq "4 terminal waits (TRUNCATED display) → terminal" \
    "$(card_probe "$_cap4")" 'terminal|t=4 r=0 d=0 u=0 c=0 n=4 b=0 x=0'

# annzui2 live shape, measured on this board: 15 waits, every one terminal.
plant_waits 15 0 0
assert_eq "15 terminal waits → terminal (annzui2 live shape)" \
    "$(card_probe "$(capped_of)")" 'terminal|t=15 r=0 d=0 u=0 c=0 n=15 b=0 x=0'

# guardkey hand-sorted shape: 2 finished, 9 nohup, 2 genuinely indeterminate.
plant_waits 2 9 2
assert_eq "13 mixed waits → unresolved, and the tally names all four classes" \
    "$(card_probe "$(capped_of)")" 'unresolved|t=2 r=0 d=2 u=9 c=0 n=13 b=0 x=0'

# excc shape: 11 of 11 unresolvable BY CONSTRUCTION — the fourth state.
plant_waits 0 11 0
assert_eq "11 nohup waits → untracked, not unresolved" \
    "$(card_probe "$(capped_of)")" 'untracked|t=0 r=0 d=0 u=11 c=0 n=11 b=0 x=0'

# NON-VACUITY: the classifier must still DISCRIMINATE at high cardinality, not
# merely always answer terminal now that truncation no longer stops it.
plant_waits 14 0 1
assert_eq "14 terminal + 1 died → unresolved, NOT terminal" \
    "$(card_probe "$(capped_of)")" 'unresolved|t=14 r=0 d=1 u=0 c=0 n=15 b=0 x=0'

# The heartbeat is AUTHORITATIVE: a caller passing a wrong/empty display string
# must still get the right answer, because the cap is a display artefact.
assert_eq "an EMPTY display string still resolves from the heartbeat" \
    "$(card_probe '')" 'unresolved|t=14 r=0 d=1 u=0 c=0 n=15 b=0 x=0'
rm -rf "$STATE_DIR/async-run" "$_card_hb/$_card_win.json"

# The emit must SURFACE the tally — a 13-wait window is unreadable as a list.
out=$(render_orphan_row 'unresolved|t=2 r=0 d=2 u=9 c=0 n=13|asyncrun:ar-x,nohup:nh-1')
assert_contains "emit carries the tally at high cardinality" "$out" "t=2 r=0 d=2 u=9 c=0 n=13"
out=$(render_orphan_row 'untracked|t=0 r=0 d=0 u=11 c=0 n=11|nohup:nh-1')
assert_contains     "untracked branch: says UNTRACKED"            "$out" "UNTRACKED"
assert_contains     "untracked branch: says nothing to poll"      "$out" "nothing to poll"
assert_not_contains "untracked branch: does NOT claim a live job"  "$out" "still RUNNING"

# ── #1311: the UNTRACKED arm fires on ANY, the prose claimed EVERY ──────────
# The arm is `n_untr > 0` (existential); the sentence asserted ALL. On a mixed
# window that instructed the operator to clear waits whose rc is on disk,
# unread. Prose only — the classifier is right and an existing assertion above
# pins that a mixed list still CLASSIFIES untracked.
out=$(render_orphan_row 'untracked|t=2 r=0 d=0 u=1 c=0 n=3|nohup:syn-1,asyncrun:ar-a,asyncrun:ar-b')
assert_not_contains "#1311 MIXED: does NOT claim EVERY wait is untracked" "$out" "every wait here is UNTRACKED"
assert_contains     "#1311 MIXED: names the split"                        "$out" "1 of 3 waits are UNTRACKED"
assert_contains     "#1311 MIXED: routes to the status line FIRST"        "$out" "--status-line"
# #1333 coupling: cancelled waits are resolvable too, so t+c is the count.
out=$(render_orphan_row 'untracked|t=1 r=0 d=0 u=1 c=1 n=3|nohup:syn-1,asyncrun:ar-a,asyncrun:ar-b')
assert_contains     "#1311 MIXED: resolvable count is t+c, not t alone"   "$out" "The other 2 have POSITIVE EVIDENCE"
# NON-VACUITY: the HOMOGENEOUS case must still print the original sentence, or
# the assertion above is satisfied by simply deleting the branch.
out=$(render_orphan_row 'untracked|t=0 r=0 d=0 u=11 c=0 n=11|nohup:nh-1')
assert_contains     "#1311 ALL-untracked: keeps the every-wait wording (it is TRUE)" "$out" "every wait here is UNTRACKED"
assert_not_contains "#1311 ALL-untracked: does not claim a terminal status exists"   "$out" "--status-line"

# ── #1183: an ARMED skeptic await is not an orphan ──────────────────────────
# `skeptic-channel.sh await` IS the resume mechanism. The running arm told the
# operator to install a Monitor for a recorded command that is already a poller
# — and acting on that stacks a second await, which SIGTERMs the older one
# (#1178), leaving the window with NONE armed while believing it is parked.
_a83="$STATE_DIR/async-run/$_wc_enc/ar-await000001"
mkdir -p "$_a83"
# A REAL await-shaped process: a stub whose cmdline IS
# `bash <path>/skeptic-channel.sh await dolicompsk`, because since the #1183
# reopen the classifier ALSO asks the channel's own record — `.await-owner`
# must name a live pid whose cmdline is this await (read off /proc by the same
# property parser) and `.await-heartbeat` must be fresh. A bare `sleep` would
# fail that check, correctly.
printf '#!/usr/bin/env bash\nsleep 120\n' > "$WORK/monitor/skeptic-channel.sh"
chmod +x "$WORK/monitor/skeptic-channel.sh"
bash "$WORK/monitor/skeptic-channel.sh" await dolicompsk &
_a83pid=$!
_a83st=$(awk '{n=split($0,a,") "); split(a[n],f," "); print f[20]}' "/proc/$_a83pid/stat" 2>/dev/null)
_a83chan_enc=$(bash -c "source '$NEXUS_ROOT/monitor/_bookkeeping.sh' 2>/dev/null; wk_encode dolicompsk" 2>/dev/null)
[[ -n "$_a83chan_enc" ]] || _a83chan_enc=dolicompsk
_a83chan="$STATE_DIR/skeptic/$_a83chan_enc"
mkdir -p "$_a83chan"
_a83_arm() {   # the channel's own record: owner pid + fresh heartbeat
    printf '%s\n' "$_a83pid" > "$_a83chan/.await-owner"
    date +%s > "$_a83chan/.await-heartbeat"
}
_a83_arm
printf '%s\n' "$_a83pid" > "$_a83/pid"
printf '%s\n' "$_a83st"  > "$_a83/pidstart"
printf './monitor/skeptic-channel.sh\0await\0dolicompsk\0' > "$_a83/argv"
assert_eq "#1183 a live SKEPTIC AWAIT -> skeptic-await, not running" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-await000001')")" skeptic-await
# THE REOPEN (2026-09-03): argv[0] had to BE the script, which missed the form
# the skill PRESCRIBES. Measured on the primary: 7 of 27 live awaits missed —
# six `bash <path>/skeptic-channel.sh await …`, one `bash -c '<;-list>'` — and
# every one was told to install a second listener.
printf 'bash\0/shared/x/monitor/skeptic-channel.sh\0await\0dolicompsk\0--timeout\021600\0' > "$_a83/argv"
assert_eq "#1183 REOPEN: \`bash <path>/skeptic-channel.sh await …\` -> skeptic-await" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-await000001')")" skeptic-await
printf 'bash\0monitor/skeptic-channel.sh\0await\0dolicompsk\0' > "$_a83/argv"
assert_eq "#1183 REOPEN: \`bash monitor/skeptic-channel.sh await …\` (relative) -> skeptic-await" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-await000001')")" skeptic-await
printf 'bash\0-c\0monitor/skeptic-channel.sh await dolicompsk; rc=$?; echo "await rc=$rc"; exit $rc\0' > "$_a83/argv"
assert_eq "#1183 REOPEN: the SKILL-prescribed \`bash -c '<list>'\` form -> skeptic-await" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-await000001')")" skeptic-await
printf 'bash\0-c\0cd /x && timeout 550 monitor/skeptic-channel.sh await dolicompsk --timeout 600\0' > "$_a83/argv"
assert_eq "#1183 REOPEN: an await behind \`cd … &&\` and a \`timeout\` wrapper -> skeptic-await" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-await000001')")" skeptic-await
# >>> NEGATIVE CONTROL (the issue's own): a `bash -c` that merely MENTIONS the
# script must NOT be classified skeptic-await — that over-match is exactly what
# a substring predicate (`_await_pid_is_ours`-style) would commit, and it would
# suppress the poller advice for real work.
printf 'bash\0-c\0echo "skeptic-channel.sh await dolicompsk is armed"; sleep 5\0' > "$_a83/argv"
assert_eq "#1183 NEG CONTROL: a \`bash -c\` that only MENTIONS \`skeptic-channel.sh await\` -> running" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-await000001')")" running
printf 'bash\0-c\0grep -c "skeptic-channel.sh await" notes.md\0' > "$_a83/argv"
assert_eq "#1183 NEG CONTROL: a grep FOR the phrase -> running" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-await000001')")" running
printf 'bash\0-c\0monitor/skeptic-channel.sh status dolicompsk\0' > "$_a83/argv"
assert_eq "#1183 NEG CONTROL: the script with a verb other than await -> running" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-await000001')")" running
# >>> STALENESS, FAIL CLOSED (the issue's ask, previously prose only): the
# channel record decides. Owner dead, heartbeat past the hang threshold, or
# either file missing -> a STALE await is an orphan and keeps `running`.
printf './monitor/skeptic-channel.sh\0await\0dolicompsk\0' > "$_a83/argv"
printf '%s\n' "$(( $(date +%s) - 100000 ))" > "$_a83chan/.await-heartbeat"
assert_eq "#1183 STALE: heartbeat past the hang threshold -> running (fail closed)" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-await000001')")" running
_a83_arm; printf '999999\n' > "$_a83chan/.await-owner"
assert_eq "#1183 STALE: .await-owner names a DEAD pid -> running (fail closed)" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-await000001')")" running
_a83_arm; printf '%s\n' "$$" > "$_a83chan/.await-owner"
assert_eq "#1183 STALE: .await-owner names a LIVE pid that is NOT an await -> running (recycled pid)" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-await000001')")" running
_a83_arm; rm -f "$_a83chan/.await-owner"
assert_eq "#1183 STALE: no .await-owner at all -> running (fail closed)" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-await000001')")" running
# POTENCY: re-arm and the SAME token returns to skeptic-await.
_a83_arm
assert_eq "#1183 …re-armed channel, same token -> skeptic-await again (the plant is potent)" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-await000001')")" skeptic-await
out=$(render_orphan_row 'skeptic-await|t=0 r=1 d=0 u=0 c=0 n=1|asyncrun:ar-await000001')
assert_not_contains "#1183 skeptic-await: does NOT tell the operator to install a Monitor" \
    "$out" "install a Monitor"
assert_contains     "#1183 skeptic-await: says it is ARMED" "$out" "ARMED"
# NON-VACUITY: strip the argv record and the SAME live token returns to running.
rm -f "$_a83/argv"
assert_eq "#1183 …without the argv record, the same live token is plain running" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-await000001')")" running
# `== n_run`, not `> 0`: an await ALONGSIDE a live compute job still needs the
# poller advice, so the mixed window must NOT take the skeptic-await arm.
printf './monitor/skeptic-channel.sh\0await\0dolicompsk\0' > "$_a83/argv"
_a83b="$STATE_DIR/async-run/$_wc_enc/ar-await000002"
mkdir -p "$_a83b"
printf '%s\n' "$_a83pid" > "$_a83b/pid"
printf '%s\n' "$_a83st"  > "$_a83b/pidstart"
printf 'python3\0train.py\0' > "$_a83b/argv"
assert_eq "#1183 an await ALONGSIDE a live compute job -> running, not skeptic-await" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-await000001,asyncrun:ar-await000002')")" running
# FAIL CLOSED: a DEAD await keeps the current treatment, never skeptic-await.
kill "$_a83pid" 2>/dev/null; wait "$_a83pid" 2>/dev/null
assert_eq "#1183 a DEAD skeptic await -> unresolved, not skeptic-await (fail closed)" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-await000001')")" unresolved
rm -rf "$_a83" "$_a83b" "$_a83chan" "$WORK/monitor/skeptic-channel.sh"

echo '=== #1355: restate async-run.sh _evidence FAITHFULLY — scoped to rc=0, redirect clause carried, no "not a result" ==='
# The emit used to say "an rc with 0 B out and 0 B err is UNCORROBORATED, not a
# result" at three arms: it DROPPED the source redirect clause and ADDED a
# phrase the source never says. 7 of 7 false alarms on one window whose driver
# redirected per-suite output to files; and rc=2 (REFUSED) / rc=124 (TIMEOUT)
# with empty streams were labelled "not a result" though each IS a status.
_p55root="$STATE_DIR/async-run/$_wc_enc"
_p55() {   # <token> <rc> <out-bytes|-> <err-bytes|-> <argv-words…>
    local t="$1" rc="$2" ob="$3" eb="$4"; shift 4
    mkdir -p "$_p55root/$t"
    printf 'rc=%s\nended=1\n' "$rc" > "$_p55root/$t/status"
    rm -f "$_p55root/$t/out" "$_p55root/$t/err"
    [[ "$ob" == - ]] || printf '%*s' "$ob" '' > "$_p55root/$t/out"
    [[ "$eb" == - ]] || printf '%*s' "$eb" '' > "$_p55root/$t/err"
    : > "$_p55root/$t/argv"; local a; for a in "$@"; do printf '%s\0' "$a" >> "$_p55root/$t/argv"; done
}
wc_counts() { printf '%s' "${1#*|}"; }
# (a) wgate shape: rc=0, 0 B / 0 B, driver `bash run3.sh` — NO redirect in the ARGV
_p55 ar-p55a 0 0 0 bash .w213-out/run3.sh
assert_eq "#1355 rc=0 with 0 B/0 B, no redirect in argv -> b=1 x=0" \
    "$(wc_counts "$(wc_probe wcw 'asyncrun:ar-p55a')")" 't=1 r=0 d=0 u=0 c=0 n=1 b=1 x=0'
# (b) the argv itself redirects -> x counts it
_p55 ar-p55b 0 0 0 bash -c 'bash run3.sh > .out/run3.log 2>&1'
assert_eq "#1355 rc=0 with 0 B/0 B and a redirect in argv -> b=1 x=1" \
    "$(wc_counts "$(wc_probe wcw 'asyncrun:ar-p55b')")" 't=1 r=0 d=0 u=0 c=0 n=1 b=1 x=1'
_p55 ar-p55t 0 0 0 bash -c 'run.sh | tee log.txt'
assert_eq "#1355 …a tee pipe counts as a redirect too" \
    "$(wc_counts "$(wc_probe wcw 'asyncrun:ar-p55t')")" 't=1 r=0 d=0 u=0 c=0 n=1 b=1 x=1'
# (c) SCOPED TO rc=0: a non-zero rc with empty streams is a STATUS, not blank
_p55 ar-p55c 2 0 0 monitor/ng guards-for-diff --run
assert_eq "#1355 rc=2 (REFUSED) with 0 B/0 B -> NOT counted blank (b=0)" \
    "$(wc_counts "$(wc_probe wcw 'asyncrun:ar-p55c')")" 't=1 r=0 d=0 u=0 c=0 n=1 b=0 x=0'
_p55 ar-p55d 124 0 0 timeout 5 sleep 99
assert_eq "#1355 rc=124 (TIMEOUT) with 0 B/0 B -> NOT counted blank (b=0)" \
    "$(wc_counts "$(wc_probe wcw 'asyncrun:ar-p55d')")" 't=1 r=0 d=0 u=0 c=0 n=1 b=0 x=0'
# (d) corroborated rc=0, and a MISSING capture file (async-run says `?`, not 0)
_p55 ar-p55e 0 4615 0 python3 train.py
assert_eq "#1355 rc=0 with 4615 B out -> corroborated, b=0" \
    "$(wc_counts "$(wc_probe wcw 'asyncrun:ar-p55e')")" 't=1 r=0 d=0 u=0 c=0 n=1 b=0 x=0'
_p55 ar-p55f 0 - - python3 train.py
assert_eq "#1355 rc=0 with NO capture files -> a missing capture is not a zero, b=0" \
    "$(wc_counts "$(wc_probe wcw 'asyncrun:ar-p55f')")" 't=1 r=0 d=0 u=0 c=0 n=1 b=0 x=0'
# (e) the window-level tally sums across tokens
assert_eq "#1355 tally sums: two blank, one of them redirecting" \
    "$(wc_counts "$(wc_probe wcw 'asyncrun:ar-p55a,asyncrun:ar-p55b,asyncrun:ar-p55c')")" 't=3 r=0 d=0 u=0 c=0 n=3 b=2 x=1'
# --- the PROSE, per shape ---
out=$(render_orphan_row 'terminal|t=1 r=0 d=0 u=0 c=0 n=1 b=0 x=0|asyncrun:ar-p55c')
assert_not_contains "#1355 b=0: the empty-streams WARNING does not fire"        "$out" "UNCORROBORATED"
assert_contains     "#1355 b=0: a non-zero rc with empty streams is a STATUS"  "$out" "is a STATUS"
assert_not_contains "#1355 b=0: never says not a result"                       "$out" "not a result"
out=$(render_orphan_row 'terminal|t=1 r=0 d=0 u=0 c=0 n=1 b=1 x=1|asyncrun:ar-p55b')
assert_contains     "#1355 x==b: says EMPTY BY DESIGN"                          "$out" "EMPTY BY DESIGN"
assert_contains     "#1355 x==b: carries the redirect clause (find the own log)" "$out" "find the payload own log"
assert_not_contains "#1355 x==b: never says not a result"                      "$out" "not a result"
out=$(render_orphan_row 'terminal|t=1 r=0 d=0 u=0 c=0 n=1 b=1 x=0|asyncrun:ar-p55a')
assert_contains     "#1355 b>0 x=0: UNCORROBORATED as a verdict on the WORK"   "$out" "UNCORROBORATED as a verdict on the work"
assert_contains     "#1355 b>0 x=0: carries the redirect clause"               "$out" "redirects its own output"
assert_contains     "#1355 b>0 x=0: non-zero rc is a STATUS"                   "$out" "NON-ZERO rc with empty streams is a STATUS"
assert_not_contains "#1355 b>0 x=0: never says not a result"                   "$out" "not a result"
out=$(render_orphan_row 'terminal|t=3 r=0 d=0 u=0 c=0 n=3 b=2 x=1|asyncrun:ar-p55a,asyncrun:ar-p55b,asyncrun:ar-p55c')
assert_contains     "#1355 mixed b=2 x=1: names the split"                     "$out" "1 of those redirect their own output"
assert_contains     "#1355 mixed b=2 x=1: the other 1 is UNCORROBORATED"       "$out" "the other 1 are UNCORROBORATED"
# the SAME sentence is what the cancelled-mixed and untracked-mixed arms carry
out=$(render_orphan_row 'cancelled|t=2 r=0 d=0 u=0 c=1 n=3 b=0 x=0|asyncrun:ar-a,asyncrun:ar-b,asyncrun:ar-c')
assert_not_contains "#1355 cancelled-mixed arm: no not-a-result"               "$out" "not a result"
assert_contains     "#1355 cancelled-mixed arm: scoped sentence (b=0)"          "$out" "is a STATUS"
out=$(render_orphan_row 'untracked|t=1 r=0 d=0 u=1 c=0 n=2 b=1 x=1|nohup:syn-1,asyncrun:ar-b')
assert_not_contains "#1355 untracked-mixed arm: no not-a-result"               "$out" "not a result"
assert_contains     "#1355 untracked-mixed arm: EMPTY BY DESIGN when x==b"      "$out" "EMPTY BY DESIGN"
# LEGACY counts (no b=): the FULL faithful sentence, never silence
out=$(render_orphan_row 'terminal|t=1 r=0 d=0 u=0 c=0 n=1|asyncrun:ar-old')
assert_contains     "#1355 legacy counts: still warns UNCORROBORATED"          "$out" "UNCORROBORATED"
assert_contains     "#1355 legacy counts: carries the redirect clause"         "$out" "redirects its own output"
assert_not_contains "#1355 legacy counts: never says not a result"             "$out" "not a result"
# >>> NEGATIVE CONTROL (the issue's): #1201's genuinely-dead shape — no status,
# pid gone, nothing captured — must STILL warn. That is the `died` shape and
# it lands in the unresolved arm, whose warning is untouched.
mkdir -p "$_p55root/ar-p55dead"
printf '999999\n' > "$_p55root/ar-p55dead/pid"; printf '1\n' > "$_p55root/ar-p55dead/pidstart"
: > "$_p55root/ar-p55dead/out"; : > "$_p55root/ar-p55dead/err"
_p55cls=$(wc_probe wcw 'asyncrun:ar-p55dead')
assert_eq "#1355 NEG CONTROL: a job that died leaving nothing -> unresolved" "$(wc_class "$_p55cls")" unresolved
out=$(render_orphan_row "$_p55cls|asyncrun:ar-p55dead")
assert_contains "#1355 NEG CONTROL: …and the warning still fires (NOT verifiable)" "$out" "NOT verifiable"
# and the rc=0 blank NON-redirecting shape (wgate driver, redirect INSIDE the
# script) is still flagged — the issue asks for argv-level redirect only, and
# a refinement that silenced this would be #1201 reopened.
out=$(render_orphan_row "$(wc_probe wcw 'asyncrun:ar-p55a')|asyncrun:ar-p55a")
assert_contains "#1355 NEG CONTROL: rc=0 blank with no argv redirect is still UNCORROBORATED" "$out" "UNCORROBORATED"
rm -rf "$_p55root"/ar-p55*

echo '=== #1333: cancelled is NOT died — ask async-run.sh _verdict, do not restate it ==='
# The classifier used to test `[[ -s status ]]` and nothing else, so a job
# CANCELLED BY ITS OWNER and a job that DIED UNATTENDED produced byte-identical
# rows — and those have opposite operator responses. `status` is written by the
# runner at exit, so a SIGNALLED job never reaches that line and the cancel
# marker is the only terminal evidence on disk.
#
# SELF-CONTAINED BY CONSTRUCTION. The first draft of this block reused the
# #1292 fixtures and sat below the `rm -rf "$STATE_DIR/async-run"` that clears
# them, so three assertions read a tree that had been deleted and failed for a
# reason that had nothing to do with the code. Every fixture below is planted
# here and torn down here.
_c33root="$STATE_DIR/async-run/$_wc_enc"
mkdir -p "$_c33root/ar-c33canc" "$_c33root/ar-c33dead" "$_c33root/ar-c33live"
# A REAL live process we own, with its REAL start-time.
sleep 120 &
_c33pid=$!
_c33st=$(awk '{n=split($0,a,") "); split(a[n],f," "); print f[20]}' "/proc/$_c33pid/stat" 2>/dev/null)
if [[ -n "$_c33st" && "$_c33st" =~ ^[0-9]+$ ]]; then
    printf '  PASS: #1333 fixture planted a live pid with a readable start-time\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: #1333 fixture could not read a start-time for pid %s\n' "$_c33pid" >&2; FAIL=$(( FAIL + 1 ))
fi
# cancelled + pid gone
printf '999999\n' > "$_c33root/ar-c33canc/pid"
printf '1\n'      > "$_c33root/ar-c33canc/pidstart"
printf 'by=sess-xyz\nat=1788373387\nsignalled=yes\n' > "$_c33root/ar-c33canc/cancelled"
# died: tracked, no status, no marker, pid gone
printf '999999\n' > "$_c33root/ar-c33dead/pid"
printf '1\n'      > "$_c33root/ar-c33dead/pidstart"
# cancel marker on a LIVE pid -> cancel-requested
printf '%s\n' "$_c33pid" > "$_c33root/ar-c33live/pid"
printf '%s\n' "$_c33st"  > "$_c33root/ar-c33live/pidstart"
printf 'by=sess-xyz\nat=1788373387\nsignalled=yes\n' > "$_c33root/ar-c33live/cancelled"

assert_eq "#1333 a CANCELLED wait (marker, pid gone) -> cancelled, not unresolved" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-c33canc')")" cancelled

# >>> THE MANDATORY NEGATIVE CONTROL. Without it, `cancelled` is satisfiable by
# relabelling every dead wait — the fix being strictly WORSE than the bug,
# because it converts a stuck window into a lost one.
assert_eq "#1333 NEG CONTROL: a wait that DIED with NO marker -> still unresolved" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-c33dead')")" unresolved

# `cancel-requested`: marker present AND PID ALIVE. Must count as RUNNING —
# "marker => settled" would retire a window whose job is still working.
assert_eq "#1333 a cancel marker on a LIVE pid -> running (cancel-requested), NOT cancelled" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-c33live')")" running

# ALL-arm, not existential: #1311's shape must not arrive in the arm next door.
assert_eq "#1333 cancelled + died -> unresolved, not cancelled (fail closed)" \
    "$(wc_class "$(wc_probe wcw 'asyncrun:ar-c33canc,asyncrun:ar-c33dead')")" unresolved

# THE FAST PATH IS A CACHE OF _verdict, NOT A SECOND DEFINITION. `[[ -s status ]]`
# survives above the ask; these two assert the authority agrees with it on BOTH
# arms, so the shortcut stays equivalent rather than becoming a second opinion.
printf 'rc=0\nended=1\n' > "$_c33root/ar-c33canc/status"
_v33=$(NEXUS_ASYNC_RUN_WINDOW=wcw NEXUS_STATE_DIR="$STATE_DIR" \
       timeout 10 bash "$_test_dir/../async-run.sh" --status-line ar-c33canc 2>/dev/null)
assert_eq "#1333 AUTHORITY: status file + cancel marker -> terminal (arm order, #1121)" \
    "${_v33%%|*}" terminal
rm -f "$_c33root/ar-c33canc/cancelled"
_v33=$(NEXUS_ASYNC_RUN_WINDOW=wcw NEXUS_STATE_DIR="$STATE_DIR" \
       timeout 10 bash "$_test_dir/../async-run.sh" --status-line ar-c33canc 2>/dev/null)
assert_eq "#1333 AUTHORITY: status file alone -> terminal (the fast path is equivalent)" \
    "${_v33%%|*}" terminal

# MIXED terminal + cancelled. The gate is an ALL-arm over the UNION
# (`n_canc + n_term == n`), so it legitimately fires here — and the FIRST
# version of this arm then asserted a universal over the set, telling the
# operator that two jobs which COMPLETED WITH A REAL RC had output "truncated by
# design … not evidence of anything". That is #1311's defect committed in the
# arm directly above #1311's fix, and it was caught in review, not by this
# suite. These assertions are why it cannot come back.
out=$(render_orphan_row 'cancelled|t=2 r=0 d=0 u=0 c=1 n=3|asyncrun:ar-a,asyncrun:ar-b,asyncrun:ar-c')
assert_not_contains "#1333 MIXED: does NOT claim ALL of them were cancelled" \
    "$out" "these jobs were CANCELLED ON REQUEST"
assert_contains     "#1333 MIXED: names the split" "$out" "1 of 3 were CANCELLED ON REQUEST"
assert_contains     "#1333 MIXED: says the others COMPLETED with a real rc" "$out" "The other 2 COMPLETED"
# …and it must not contradict the terminal arm three arms up, which warns that
# an rc with 0 B out and 0 B err is UNCORROBORATED rather than a result.
assert_contains     "#1333 MIXED: keeps the UNCORROBORATED warning for the terminal ones" \
    "$out" "UNCORROBORATED"

# NON-VACUITY: the HOMOGENEOUS case must still print the universal sentence, or
# the assertions above are satisfied by deleting the branch outright.
out=$(render_orphan_row 'cancelled|t=0 r=0 d=0 u=0 c=1 n=1|asyncrun:ar-c33canc')
assert_contains     "#1333 cancelled branch: says CANCELLED ON REQUEST"       "$out" "CANCELLED ON REQUEST"
assert_contains     "#1333 cancelled branch: says output is truncated"        "$out" "TRUNCATED BY DESIGN"
assert_not_contains "#1333 cancelled branch: does NOT say it died unattended" "$out" "NOT verifiable"

kill "$_c33pid" 2>/dev/null; wait "$_c33pid" 2>/dev/null
rm -rf "$_c33root/ar-c33canc" "$_c33root/ar-c33dead" "$_c33root/ar-c33live"

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
# `ng` sources monitor/_bookkeeping.sh and REFUSES TO START without
# it (your-org/nexus-code#601/#605: degrading to the silent-coercion
# behaviour it replaces is worse than refusing). Copy it alongside.
cp "$(dirname "$FAKE_NEXUS_8/monitor/ng")/_bookkeeping.sh" "$FAKE_NEXUS_14/monitor/_bookkeeping.sh"
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
# The negative control for your-org/nexus-code#808's split: `absent` must keep
# the relaunch advisory. Without this, "make blocked say something else" could
# be satisfied by making EVERY pane-absent row say the blocked thing — which
# would tell an operator to answer an overlay on a pane whose process is gone.
assert_contains  "absent keeps the relaunch advisory"             "$out" \
                 "relaunch or close"
assert_not_contains "absent is NOT given the blocked advisory"    "$out" \
                    "ANSWER it in the pane"
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
# your-org/nexus-code#808 — THE ADVISORY, not just the class. `blocked` means
# the agent is ALIVE and rendering a modal only a human can clear; it shares
# the `pane-absent` surface with `absent` because both need the operator, but
# the two need OPPOSITE actions. Observed in production 2026-08-07 against a
# worker displaying an AskUserQuestion: the operator was told the process was
# gone and to relaunch it.
#
# The class assertion above passed throughout that incident. That is the point
# of these two lines: the string is what an operator reads and acts on, and
# nothing asserted it.
#
# The negative asserts the ABSENT advisory is absent, NOT the bare phrase
# "relaunch or close" — the blocked advisory ends "do NOT relaunch or close",
# which CONTAINS that phrase. A substring test on it fires on the corrected
# wording and reports the fix as the bug. (It did, on the first draft of this
# very assertion.) So the discriminator is the unnegated advisory itself.
assert_not_contains "blocked is NOT told the process is gone"     "$out" \
                    "claude process gone or unresponsive"
assert_contains  "blocked is told to ANSWER the overlay"          "$out" \
                 "ANSWER it in the pane"
assert_contains  "blocked advisory NEGATES the relaunch"          "$out" \
                 "do NOT relaunch or close"

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

# ---- Test 31a: the pane-absent renderer honours the ROW's advisory ------
#
# your-org/nexus-code#808, the second half. The classifier computes a
# per-state advisory into column 4; this awk arm used to print a FIXED string
# and discard it. So the advisory was decided in one file and overwritten in
# another, and the fix in `list_really_idle_workers` alone would have been
# invisible to every operator.
#
# Two rows, one render, because the failure this guards is "print one string
# for everything" — which a single-row test cannot distinguish from "print
# the right string". Each row must show its OWN advisory and NOT the other's.
echo '=== render_idle_section honours the per-row pane-absent advisory (#808) ==='
rm -f "$STATE_DIR/idle-state.tsv"
out=$(PATH="$STUB_DIR:$PATH" bash -c "
    set -uo pipefail
    STATE_DIR='$STATE_DIR'
    NEXUS_ROOT='$NEXUS_ROOT'
    source '$PROBE'
    list_really_idle_workers() {
        printf 'crashedwin\tpane-absent\t900\tclaude process gone or unresponsive; relaunch or close\n'
        printf 'askuqwin\tpane-absent\t900\toverlay awaiting the operator (blocked) — ANSWER it in the pane; do NOT relaunch or close\n'
    }
    render_idle_section
" 2>/dev/null)
assert_contains  "blocked row renders its own advisory"           "$out" \
                 "askuqwin pane-absent (overlay awaiting the operator (blocked) — ANSWER it in the pane"
assert_contains  "absent row still renders the relaunch advisory" "$out" \
                 "crashedwin pane-absent (claude process gone or unresponsive; relaunch or close)"
# The load-bearing negative: the blocked row must not carry the ABSENT
# advisory anywhere on its line. Asserted per-LINE, because that advisory
# legitimately appears on the OTHER row in the same output — a whole-output
# assertion here would be vacuous.
#
# The probe is "claude process gone or unresponsive", not "relaunch or
# close": the corrected blocked wording ends "do NOT relaunch or close" and
# so CONTAINS the latter. Testing for it would flag the fix as the defect.
askuq_line=$(printf '%s\n' "$out" | grep -F 'askuqwin' || true)
assert_not_contains "blocked LINE never claims the process is gone" "$askuq_line" \
                    "claude process gone"
assert_contains  "blocked LINE negates the relaunch"              "$askuq_line" \
                 "do NOT relaunch or close"
# …and an empty detail column falls back to the historical wording rather
# than rendering an empty parenthesis, so a row from an older producer still
# says something actionable.
out=$(PATH="$STUB_DIR:$PATH" bash -c "
    set -uo pipefail
    STATE_DIR='$STATE_DIR'
    NEXUS_ROOT='$NEXUS_ROOT'
    source '$PROBE'
    list_really_idle_workers() { printf 'legacywin\tpane-absent\t900\t\n'; }
    render_idle_section
" 2>/dev/null)
assert_contains  "empty detail falls back, never renders blank"   "$out" \
                 "legacywin pane-absent (claude process gone or unresponsive; relaunch or close)"

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
# ── your-org/nexus-code#845: the JOIN — parked-awaiting-skeptic names the
# resolved skeptic and its idle age; the deadlock shape is flagged only on
# positive evidence ────────────────────────────────────────────────────────
echo '=== #845: parked-awaiting-skeptic carries the resolved skeptic NAME and IDLE AGE ==='
# The issue's own paneclass numbers: target parked 23m, skeptic idle 4h06m.
# Before: the row read `skeptic reviewing; exempt from idle/close` and was
# BYTE-IDENTICAL at skeptic idle 10s, 14760s and 360000s (measured on the
# 2026-09-02 re-derivation). `_idle_skeptic_live_window` computed the name and
# discarded it; nothing read the skeptic's activity.
rm -f "$STATE_DIR/idle-state.tsv"; clear_bg_state 2>/dev/null || true
LOG="$STATE_DIR/action-log.jsonl"; : > "$LOG"
_j45now=$(date +%s)
mkdir -p "$STATE_DIR/skeptic/pending"
echo 1 > "$STATE_DIR/skeptic/pending/paneclass"      # fresh marker -> parked
j45_windows() {   # <skeptic-window-name|-> <skeptic-idle-seconds>
    # NO index column: the pane-state stub keys MOCK_PANE_STATE_<arg> on its
    # first argument, and with an index present the probe passes the INDEX.
    if [[ "$1" == - ]]; then
        printf 'paneclass|%s' "$(( _j45now - 1380 ))"
    else
        printf 'paneclass|%s\n%s|%s' "$(( _j45now - 1380 ))" "$1" "$(( _j45now - $2 ))"
    fi
}
export MOCK_TMUX_WINDOWS="$(j45_windows paneclass-skeptic 14760)"
seed_engagement_log_matching_activity
# The TARGET pane must be IDLE here: list_really_idle_workers filters on the
# idle pool BEFORE the park check (a busy pane is never in the pool). The
# snapshot renderer, by contrast, asks the park question for every window.
export MOCK_PANE_STATE_paneclass=idle MOCK_PANE_STATE_paneclass_skeptic=autosuggest-only
run_probe_capture out rc 'list_really_idle_workers'
row=$(printf '%s\n' "$out" | grep -F $'paneclass\tparked-awaiting-skeptic' || true)
assert_contains "#845 the parked row exists (positive control)"            "$row" "parked-awaiting-skeptic"
assert_contains "#845 …names the resolved skeptic"                          "$row" "skeptic=paneclass-skeptic idle "
_j45age=$(printf '%s' "$row" | sed -n 's/.*skeptic=paneclass-skeptic idle \([0-9]*\)s.*/\1/p')
if [[ "$_j45age" =~ ^[0-9]+$ ]] && (( _j45age >= 14760 && _j45age < 14760 + 300 )); then
    printf '  PASS: #845 …carries the skeptic IDLE AGE from tmux activity (%ss)\n' "$_j45age"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: #845 …skeptic idle age not carried (got %q from row %q)\n' "$_j45age" "$row" >&2; FAIL=$(( FAIL + 1 ))
fi
assert_contains "#845 4h06m idle, un-retained -> DEADLOCK SHAPE flagged"   "$row" "DEADLOCK SHAPE (#845)"
assert_contains "#845 …the flag names the release verbs"                     "$row" "notify-delta"
# the rendered idle section carries it too
rm -f "$STATE_DIR/idle-state.tsv"
run_probe_capture out rc 'render_idle_section'
assert_contains "#845 render_idle_section: row carries skeptic name + age"  "$out" "skeptic=paneclass-skeptic idle "
# and the full-state SNAPSHOT — where the orchestrator looks most
run_probe_capture out rc 'render_full_state_snapshot'
srow=$(printf '%s\n' "$out" | grep -F '  - paneclass parked-awaiting-skeptic' || true)
assert_contains "#845 snapshot: parked row carries the join"                 "$srow" "skeptic=paneclass-skeptic idle "
assert_contains "#845 snapshot: …and the deadlock flag"                      "$srow" "DEADLOCK SHAPE"

# >>> ALLOWLIST, DEFAULT-DENY (the 2026-08-09 objection): the flag needs EVERY
# condition. Drop one at a time; the JOIN (name + age) stays, the flag goes.
# (1) skeptic idle 10s — below the threshold
export MOCK_TMUX_WINDOWS="$(j45_windows paneclass-skeptic 10)"; seed_engagement_log_matching_activity
run_probe_capture out rc 'list_really_idle_workers'
row=$(printf '%s\n' "$out" | grep -F $'paneclass\tparked-awaiting-skeptic' || true)
assert_contains     "#845 NEG(1) skeptic idle 10s: join still present"       "$row" "skeptic=paneclass-skeptic idle "
assert_not_contains "#845 NEG(1) skeptic idle 10s: NO deadlock flag"         "$row" "DEADLOCK SHAPE"
# (2) skeptic RETAINED (declared hold, within TTL) — intent beats inference
export MOCK_TMUX_WINDOWS="$(j45_windows paneclass-skeptic 14760)"; seed_engagement_log_matching_activity
printf '{"ts":"%s","agent":"monitor","event":"window-retain","window":"paneclass-skeptic","reason":"held-for-delta"}\n' "$(date -Is -d "@$(( _j45now - 60 ))")" > "$LOG"
run_probe_capture out rc 'list_really_idle_workers'
row=$(printf '%s\n' "$out" | grep -F $'paneclass\tparked-awaiting-skeptic' || true)
assert_contains     "#845 NEG(2) retained skeptic: join still present"       "$row" "skeptic=paneclass-skeptic idle "
assert_not_contains "#845 NEG(2) retained skeptic: NO deadlock flag"         "$row" "DEADLOCK SHAPE"
# (2b) …but a retain older than the TTL has LAPSED, and the flag returns
printf '{"ts":"%s","agent":"monitor","event":"window-retain","window":"paneclass-skeptic","reason":"held-for-delta"}\n' "$(date -Is -d "@$(( _j45now - 200000 ))")" > "$LOG"
run_probe_capture out rc 'list_really_idle_workers'
row=$(printf '%s\n' "$out" | grep -F $'paneclass\tparked-awaiting-skeptic' || true)
assert_contains     "#845 NEG(2b) retain past TTL: flag returns"             "$row" "DEADLOCK SHAPE"
: > "$LOG"
# (3) threshold is configurable: raise it above the age and the flag goes
MONITOR_SKEPTIC_DEADLOCK_IDLE_SECONDS=20000 run_probe_capture out rc 'list_really_idle_workers'
row=$(printf '%s\n' "$out" | grep -F $'paneclass\tparked-awaiting-skeptic' || true)
assert_not_contains "#845 NEG(3) threshold above the age: NO deadlock flag"  "$row" "DEADLOCK SHAPE"
# (4) the resolved name comes from the skeptic-spawn LINKAGE when present,
#     not from the `<name>-skeptic` convention
printf '{"ts":"%s","agent":"monitor","event":"skeptic-spawn","window":"sk-pc","target-window":"paneclass","orig-window":"paneclass","depth":"1"}\n' "$(date -Is -d "@$(( _j45now - 1400 ))")" > "$LOG"
export MOCK_TMUX_WINDOWS="$(j45_windows sk-pc 14760)"; seed_engagement_log_matching_activity
run_probe_capture out rc 'list_really_idle_workers'
row=$(printf '%s\n' "$out" | grep -F $'paneclass\tparked-awaiting-skeptic' || true)
assert_contains "#845 linkage record wins: skeptic=sk-pc"                    "$row" "skeptic=sk-pc idle "
: > "$LOG"
# (5) GRACE basis — no live skeptic yet: parked, and NO skeptic named (never a guess)
export MOCK_TMUX_WINDOWS="$(j45_windows - 0)"; seed_engagement_log_matching_activity
run_probe_capture out rc 'list_really_idle_workers'
row=$(printf '%s\n' "$out" | grep -F $'paneclass\tparked-awaiting-skeptic' || true)
assert_contains     "#845 NEG(5) grace basis: still parked"                  "$row" "parked-awaiting-skeptic"
assert_not_contains "#845 NEG(5) grace basis: no skeptic named"              "$row" "skeptic="
# (6) the boolean callers are unaffected: orphaned still refuses when a live
#     skeptic exists (stdout of the resolver must not leak into a verdict)
export MOCK_TMUX_WINDOWS="$(j45_windows paneclass-skeptic 14760)"; seed_engagement_log_matching_activity
run_probe_capture out rc '_idle_skeptic_orphaned paneclass "$(date +%s)" "$(printf "paneclass\npaneclass-skeptic")"; echo "orphaned-rc=$?"'
assert_contains "#845 _idle_skeptic_orphaned with a live skeptic -> rc 1, no leaked name" "$out" "orphaned-rc=1"
assert_not_contains "#845 …stdout carries no window name"                     "$out" "paneclass-skeptic"
rm -f "$STATE_DIR/skeptic/pending/paneclass"
unset MOCK_PANE_STATE_paneclass MOCK_PANE_STATE_paneclass_skeptic

# ---------------------------------------------------------------------------
# your-org/nexus-code#1478 — the `N awaiting-input` scalar must not count the
# ORCHESTRATOR's own idle_prompt. Its resting state (waiting for the operator)
# rendered as a worker needing attention: `1` nearly always, a real worker as
# `2`. Excluded by the watcher's paste-target identity ($TARGET), default
# `orchestrator` like the window lister — never a hardcoded name.
# ---------------------------------------------------------------------------
echo "=== #1478: awaiting-input excludes the orchestrator (by \$TARGET) ==="
NSTATE="$WORK/.state-1478"; mkdir -p "$NSTATE"
printf '%s\n' \
  '{"event":"Notification","notification_type":"idle_prompt","window":"orchestrator","ts":2000}' \
  '{"event":"Notification","notification_type":"permission_prompt","window":"w7","ts":2001}' \
  '{"event":"Notification","notification_type":"idle_prompt","window":"mission-control","ts":2002}' \
  '{"event":"Notification","notification_type":"idle_prompt","window":"w7","ts":2003}' \
  > "$NSTATE/worker-notifications.jsonl"
_n1478() {  # _n1478 <TARGET-or-empty> <since>
    bash -c "set -uo pipefail; STATE_DIR='$NSTATE'; export STATE_DIR; ${1:+TARGET='$1'; export TARGET;} source '$PROBE'; _notifications_count_distinct_since $2" 2>/dev/null
}
assert_eq "#1478 default target: orchestrator's idle_prompt is NOT counted (w7 + mission-control = 2)" "$(_n1478 '' 1000)" "2"
assert_eq "#1478 TARGET=mission-control: THAT window is excluded instead (orchestrator + w7 = 2)" "$(_n1478 mission-control 1000)" "2"
assert_eq "#1478 CONTROL: the since-epoch filter still applies (only rows after 2002 → w7 = 1)" "$(_n1478 '' 2002)" "1"
assert_eq "#1478 nothing but the orchestrator since the stamp → 0 is REACHABLE" "$(bash -c "set -uo pipefail; STATE_DIR='$NSTATE'; export STATE_DIR; source '$PROBE'; printf '%s\n' '{\"event\":\"Notification\",\"notification_type\":\"idle_prompt\",\"window\":\"orchestrator\",\"ts\":3000}' >> '$NSTATE/worker-notifications.jsonl'; _notifications_count_distinct_since 2999" 2>/dev/null)" "0"
# The sed fallback arm (no jq) must agree with the jq arm.
# jq is resolved with `command -v`; shadowing `command` in the child makes it
# report jq ABSENT so the awk fallback is what runs (a PATH without jq is not
# constructible here — jq lives beside the coreutils).
assert_eq "#1478 the no-jq (awk) arm excludes the same window (2)" \
    "$(bash -c "set -uo pipefail; STATE_DIR='$NSTATE'; export STATE_DIR; source '$PROBE'; command() { if [[ \"\${1:-}\" == -v && \"\${2:-}\" == jq ]]; then return 1; fi; builtin command \"\$@\"; }; _notifications_count_distinct_since 1000" 2>/dev/null)" "2"

# ---------------------------------------------------------------------------
# your-org/nexus-code#1478 lead 2, verified: with STATE_DIR UNSET every state
# path used to resolve to `.` — the checkout, when an agent ran a sourcer from
# the repo root (four such files sat at the operator's repo root with one
# mtime). Now a scratch fallback, announced once, never the cwd.
# ---------------------------------------------------------------------------
echo "=== #1478: STATE_DIR unset never resolves a state path into the CWD ==="
CWD1478="$WORK/cwd-1478"; mkdir -p "$CWD1478"
paths=$(cd "$CWD1478" && env -u STATE_DIR bash -c "set -uo pipefail; source '$PROBE'; _notifications_stamp_path; echo; _notifications_log_path; echo; _engagement_log_path 2>/dev/null || true" 2>/dev/null)
case "$paths" in
    *"$CWD1478"*|./*|*$'\n'./*) printf '  FAIL: #1478 a state path resolved into the CWD with STATE_DIR unset:\n%s\n' "$paths" >&2; FAIL=$(( FAIL + 1 )) ;;
    *nexus-idle-probe-NOSTATE*) printf '  PASS: #1478 STATE_DIR unset → paths resolve to the announced scratch fallback, not the cwd\n'; PASS=$(( PASS + 1 )) ;;
    *) printf '  FAIL: #1478 unexpected fallback paths:\n%s\n' "$paths" >&2; FAIL=$(( FAIL + 1 )) ;;
esac
warn=$(cd "$CWD1478" && env -u STATE_DIR bash -c "source '$PROBE'; _notifications_stamp_path >/dev/null; _notifications_log_path >/dev/null" 2>&1 >/dev/null)
assert_eq "#1478 the fallback is announced exactly ONCE per process" "$(grep -c 'STATE_DIR is unset' <<<"$warn")" "1"
assert_eq "#1478 …and the cwd stays empty" "$(find "$CWD1478" -mindepth 1 | wc -l)" "0"

echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
