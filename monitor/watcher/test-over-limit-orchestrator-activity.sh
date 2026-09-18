#!/usr/bin/env bash
# Guard: the over-limit stamp on the ORCHESTRATOR's pane is invalidated by that
# pane's own post-stamp model activity (your-org/nexus-code#1155 residual 2).
#
# Run: bash monitor/watcher/test-over-limit-orchestrator-activity.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# ===========================================================================
# THE GAP THIS CLOSES
# ===========================================================================
#
# `#1147` made `pane-state.sh` §1b invalidate a stamp contradicted by activity
# recorded STRICTLY LATER than the stamp's own `ts`. It keys on the per-window
# heartbeat — and `monitor/orchestrator-settings.json` never invokes
# `worker-heartbeat.sh`, so `heartbeat/<orchestrator>.json` does not exist.
# Measured on the production board: 0 of 1842 heartbeat files carry
# `"window":"orchestrator"`. The rule therefore hit `[[ -f "$hb" ]] || return 1`
# and failed CLOSED for that pane in every case, while that pane IS stamped —
# `StopFailure -> over-limit-emit.sh` is registered in its settings, and three
# `rate_limit` StopFailures landed on 2026-08-28 alone.
#
# So for the `_orchestrator` key the watcher-side post-resume gate was not
# defence in depth, it was the ONLY cover — and that is the key whose emit gate
# produced the incident's 63 held emits in an hour.
#
# ===========================================================================
# THE EVIDENCE USED, AND WHY AN MTIME IS ADMISSIBLE HERE
# ===========================================================================
#
# `monitor/.state/orchestrator-heartbeat` already exists and is already
# load-bearing (`_orchestrator_liveness_decide` reads it). The orchestrator's
# hooks touch it on EXACTLY TWO events — `PostToolUse` and `Stop` — both of
# which are already in §1b's qualifying set. The two events that would poison
# it are routed to OTHER files by the same settings block: `UserPromptSubmit`
# touches `orchestrator-paste-received`, and `Notification` goes to
# `notification-record.sh`. So the `idle_prompt` finding that shaped §1b's
# allowlist — 6766 of 6791 captured Notification payloads, fired FROM IDLENESS
# ~60 s after a pane goes quiet, i.e. while genuinely suspended — cannot reach
# this marker.
#
# AN MTIME CARRIES NO EVENT NAME, so it cannot be filtered after the fact: the
# filtering must already have happened at WRITE time. That is the whole reason
# this is sound, and it is a property of the SETTINGS FILE rather than of the
# rule. Assertion group D below therefore pins it directly — the complement
# `test-settings-json.sh` does not assert. That suite requires the Stop and
# PostToolUse hooks to touch the marker; nothing required that NOTHING ELSE
# does, and without that half the mtime means "something happened", which is
# not evidence of anything.
#
# ===========================================================================
# HERMETICITY
# ===========================================================================
#
# Every `pane-state.sh` invocation is driven through explicit `--over-limit-file`
# / `--heartbeat-file` / `--orchestrator-heartbeat-file` / `--orchestrator-window`
# overrides against a captured ANSI fixture, so nothing here reads the live
# state dir or the operator's board. `--now` is pinned, so no assertion depends
# on wall-clock time.
#
# NOTE ON CLOCK CHOICE, inherited from `test-over-limit-stale-stamp.sh` and
# load-bearing for the same reason: the marker is deliberately STALE for
# CLASSIFICATION (older than the 30 s heartbeat-staleness horizon) while being
# NEWER THAN THE STAMP. A fresh signal is answered by step 0, which exits before
# §1b is reached — so a naively-written "the orchestrator is busy" test would
# pass on the BROKEN tree without ever executing the code under test. The gap
# between the two horizons (30 s to classify, 27 h to believe a stamp) is the
# defect itself.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
PS="$_repo_root/monitor/pane-state.sh"
ORCH_SETTINGS="$_repo_root/monitor/orchestrator-settings.json"
FIX_DIR="$_test_dir/fixtures"
FIX="$FIX_DIR/busy-orchestrator-win1.ansi"
for f in "$PS" "$ORCH_SETTINGS" "$FIX"; do
    [[ -f "$f" ]] || { echo "not found: $f" >&2; exit 1; }
done

. "$_test_dir/_test_helpers.sh"

# --- the `--population` protocol (your-org/nexus-code#803) -----------------
_ooa_population_files() { printf '%s\n' "$PS" "$ORCH_SETTINGS" "$FIX" "$_test_dir/_test_helpers.sh"; }
. "$_test_dir/../_guard_population.sh"
gp_population() { _ooa_population_files; }
gp_handle "$@"

command -v jq >/dev/null 2>&1 || th_abort "jq is required"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/olorch.XXXXXX") || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

NOW=1800000000
ORCH_WIN=orchestrator
stamp="$WORK/stamp.json"
marker="$WORK/orchestrator-heartbeat"
hb="$WORK/hb.json"          # deliberately NEVER created, except in group C

write_stamp() {   # $1 = ts. reset_at deliberately a FUTURE wall-clock time, so
                  # no assertion here can pass via the TTL/expiry path instead.
    printf '{"ts":%s,"session_id":"sess","error_type":"rate_limit","error_message":"weekly limit","reset_at":"1:40pm_America/Los_Angeles","window":"%s","hook_event_name":"StopFailure"}\n' \
        "$1" "$ORCH_WIN" > "$stamp"
}
touch_marker() {  # $1 = mtime epoch
    : > "$marker"
    touch -d "@$1" "$marker" 2>/dev/null || touch -t "$(date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null)" "$marker"
}
run_as() {        # $1 = window name
    "$PS" --fixture "$FIX" --window 9 --name "$1" --active 0 --now "$NOW" \
          --over-limit-file "$stamp" --heartbeat-file "$hb" \
          --orchestrator-heartbeat-file "$marker" --orchestrator-window "$ORCH_WIN" 2>&1
}
state_of() { awk -F'[ =]' '{print $2}' <<<"$1"; }

# ===========================================================================
# A. THE CORE PROPERTY — the 16:01 shape, on the orchestrator's own pane
# ===========================================================================
# Stamp an hour old, reset_at still in the future, marker two minutes old:
# stale to CLASSIFY, 3480 s NEWER than the stamp. The orchestrator ran a tool
# call after the limit was recorded, so the limit has lifted.

echo '=== A. orchestrator: post-stamp marker activity invalidates the stamp ==='
rm -f "$hb"
write_stamp  $(( NOW - 3600 ))
touch_marker $(( NOW - 120 ))
out=$(run_as "$ORCH_WIN")
assert_eq "A1 marker NEWER than the stamp ⇒ NOT over-limit (falls through to the live pane)" \
    "$(state_of "$out")" "busy"
assert_no_file "A2 …and the contradicted stamp is deleted, so the question is not re-posed every 60 s" \
    "$stamp"

# ===========================================================================
# B. THE LOAD-BEARING NEGATIVE CONTROLS
# ===========================================================================
# Without these, A1 is a green from an instrument nobody has seen fire: it
# would pass identically if the rule merely noticed the marker EXISTED, or if
# it fired for every window.

echo '=== B. fail-closed: the rule reads the mtime, and only for this pane ==='
rm -f "$hb"
write_stamp  $(( NOW - 3600 ))
touch_marker $(( NOW - 7200 ))          # marker OLDER than the stamp
out=$(run_as "$ORCH_WIN")
assert_eq "B1 marker OLDER than the stamp ⇒ STILL over-limit (a genuine suspension is held)" \
    "$(state_of "$out")" "over-limit"
assert_file_exists "B2 …and the stamp survives" "$stamp"

rm -f "$hb" "$marker"
write_stamp $(( NOW - 3600 ))
out=$(run_as "$ORCH_WIN")
assert_eq "B3 NO marker at all ⇒ STILL over-limit (fail closed, exactly as before this change)" \
    "$(state_of "$out")" "over-limit"

# THE ISOLATION CONTROL. A worker's stamp must never be invalidated by the
# ORCHESTRATOR's activity. Identical fixture, identical fresh marker; the only
# variable is the window NAME.
rm -f "$hb"
write_stamp  $(( NOW - 3600 ))
touch_marker $(( NOW - 120 ))
out=$(run_as "some-worker")
assert_eq "B4 ISOLATION: a NON-orchestrator window is NOT released by the orchestrator's marker" \
    "$(state_of "$out")" "over-limit"
assert_file_exists "B5 …and that worker's stamp survives" "$stamp"

# ===========================================================================
# C. THE WORKER PATH IS UNCHANGED
# ===========================================================================
# The fallback is reached ONLY when the per-window heartbeat is unusable. A
# present heartbeat must still decide, by its EVENT, exactly as `#1147` left it
# — including on the orchestrator's own window, where a heartbeat would take
# precedence over the marker. Regression cover for the reordering this change
# made inside the rule.

echo '=== C. a present per-window heartbeat still decides, by event ==='
write_stamp  $(( NOW - 3600 ))
touch_marker $(( NOW - 7200 ))          # marker OLD, so only the heartbeat can release
printf '{"state":"busy","last_activity":%s,"event":"PostToolUse","window":"%s"}\n' \
    $(( NOW - 120 )) "$ORCH_WIN" > "$hb"
out=$(run_as "$ORCH_WIN")
assert_eq "C1 heartbeat PostToolUse still releases the stamp (marker not consulted)" \
    "$(state_of "$out")" "busy"

write_stamp  $(( NOW - 3600 ))
touch_marker $(( NOW - 120 ))           # marker FRESH — must NOT rescue a disqualified event
printf '{"state":"user_prompt","last_activity":%s,"event":"UserPromptSubmit","window":"%s"}\n' \
    $(( NOW - 120 )) "$ORCH_WIN" > "$hb"
out=$(run_as "$ORCH_WIN")
assert_eq "C2 heartbeat UserPromptSubmit still HOLDS the stamp — a fresh marker does not override it" \
    "$(state_of "$out")" "over-limit"
rm -f "$hb"

# ===========================================================================
# D. THE PRECONDITION: what may touch the marker
# ===========================================================================
# The mtime is admissible ONLY because the marker is touched exclusively on
# model-activity events. That is a property of the settings file, so it is
# asserted against the settings file rather than assumed in a comment.
# `test-settings-json.sh` pins that Stop and PostToolUse DO touch it; this pins
# the complement, which is the half that makes an mtime mean something.

echo '=== D. only PostToolUse and Stop may touch orchestrator-heartbeat ==='
_ooa_touching_events() {   # <settings.json> -> sorted event names
    jq -r '.hooks | to_entries[]
           | .key as $ev
           | .value[]?.hooks[]?.command
           | select(. != null and test("orchestrator-heartbeat"))
           | $ev' "$1" 2>/dev/null | LC_ALL=C sort -u
}
_events=$(_ooa_touching_events "$ORCH_SETTINGS")
assert_eq "D1 exactly the two model-activity events touch the marker" \
    "$(printf '%s' "$_events" | tr '\n' ',')" "PostToolUse,Stop"

# POTENCY for D1, varying the axis the MECHANISM varies on — the settings
# JSON, with the predicate held constant. A precondition that has never been
# shown to fail is prose.
_planted="$WORK/planted-settings.json"
jq '.hooks.UserPromptSubmit[0].hooks += [{"type":"command","command":"touch \"$NEXUS_ROOT/monitor/.state/orchestrator-heartbeat\""}]' \
    "$ORCH_SETTINGS" > "$_planted" 2>/dev/null || th_abort "jq plant failed"
_planted_events=$(_ooa_touching_events "$_planted")
assert_eq "D2 POTENCY: a third toucher on UserPromptSubmit is DETECTED (it would poison the mtime)" \
    "$(printf '%s' "$_planted_events" | tr '\n' ',')" "PostToolUse,Stop,UserPromptSubmit"

# ---- assertion-count guard ----------------------------------------------
#   2 core + 5 fail-closed/isolation + 2 worker-path + 2 precondition
EXPECTED_ASSERTIONS=11
TOTAL=$(( PASS + FAIL ))
if (( TOTAL != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count %d != expected %d — an assertion was silently dropped\n' \
        "$TOTAL" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
fi

th_summary_and_exit
