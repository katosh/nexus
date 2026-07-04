#!/usr/bin/env bash
# Unit tests for the orchestrator-liveness state machine
# (`monitor/watcher/_orchestrator_liveness.sh`, issue #164).
#
# Replaces the binary `unresponsive_age > threshold` check
# exercised by `test-orchestrator-liveness-probe.sh` (which
# remains as a regression guard on the legacy
# `_orchestrator_should_fresh_spawn` helper while it's around).
#
# The new state machine inputs are:
#
#   - Heartbeat file mtime — bumped by the orchestrator's Stop
#     hook at every turn-end. `now - mtime` is the "time since
#     last turn ended."
#   - Last-paste-ts file — epoch on line 1, stamped by main.sh
#     on every successful paste-to-orchestrator. The moment the
#     watcher poked.
#   - Optional pin + jsonl for the backward-compat fallback
#     (sessions whose settings file predates the Stop hook).
#   - Unresponsive-since marker file — stamped by the state
#     machine on first entry into the pasted-without-response
#     phase; cleared on any healthy decision.
#
# Cases covered (mirrors the issue body's matrix):
#
#   1. idle-but-healthy — no pastes, heartbeat stale, no respawn.
#   2. pasted-then-acked — heartbeat fresher than last paste,
#      no respawn.
#   3. pasted-without-response — heartbeat stale relative to
#      paste, within grace window, no respawn.
#   4. pasted-without-response past grace, within unstick window
#      — state machine returns "waiting" + stamps marker.
#   5. stuck-then-recovered — unstick handler bumped the
#      heartbeat past the unresponsive-since stamp; state
#      resets to healthy + marker cleared.
#   6. fully-wedged — unstick window exhausted; state machine
#      requests the one-shot re-submit rescue (NOT a respawn).
#   7. dead-threshold floor — even if marker hasn't crossed
#      unstick_window yet, age past dead_threshold escalates.
#   8. cooldown gate — respawn verdict suppressed while
#      cooldown active.
#   9. jsonl-mtime backward-compat — heartbeat absent but
#      jsonl past paste → healthy.
#  10. heartbeat absent (legacy settings) AND jsonl stale →
#      state machine still escalates correctly.
#
# Sections 23+ cover the orchestrator-liveness resilience changes
# (re-submit before respawn, post-resubmit escalation, dead-
# threshold supremacy, new 120/150/300 defaults, and the verdict
# log throttle).
#
# Run: bash monitor/watcher/test-orchestrator-liveness.sh

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_orchestrator_liveness.sh
source "$_script_dir/_orchestrator_liveness.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
HB="$WORK/orchestrator-heartbeat"
PR="$WORK/orchestrator-paste-received"
LP="$WORK/orchestrator-last-paste.ts"
PIN="$WORK/orchestrator-session-id"
US="$WORK/orchestrator-unresponsive-since"
RS="$WORK/orchestrator-resubmit-attempted"
CD="$WORK/orchestrator-fresh-spawn.last"

FAKE_HOME="$WORK/home"
FAKE_NEXUS_ROOT="$WORK/nexus"
mkdir -p "$FAKE_HOME/.claude/projects" "$FAKE_NEXUS_ROOT"
VALID_SID="11111111-2222-3333-4444-555555555555"
slug_of() {
    printf '%s' "$1" | sed 's|[^a-zA-Z0-9]|-|g'
}

# Defaults the issue body specifies.
GRACE=60
UNSTICK=180
DEAD=300
COOLDOWN=1800
CEILING=1800

write_paste_ts() {
    local file="$1" ts="$2"
    printf '%d\n' "$ts" > "$file"
}

stamp_n_seconds_ago() {
    local file="$1" seconds="$2"
    [[ -e "$file" ]] || : > "$file"
    touch -d "$seconds seconds ago" "$file"
}

plant_jsonl() {
    local sid="$1" age_s="$2"
    local slug proj_dir jsonl
    slug=$(slug_of "$FAKE_NEXUS_ROOT")
    proj_dir="$FAKE_HOME/.claude/projects/$slug"
    mkdir -p "$proj_dir"
    jsonl="$proj_dir/$sid.jsonl"
    printf '{"type":"assistant"}\n' > "$jsonl"
    touch -d "$age_s seconds ago" "$jsonl"
    printf '%s' "$jsonl"
}

# Plant the session's tool-results/ dir with mtime $age_s ago. Mirrors
# Claude Code's `<projects>/<slug>/<sid>/tool-results/` offload dir,
# whose mtime the Signal-4 witness stats. Write the file FIRST, then
# stamp the dir mtime (the write would otherwise reset it to "now").
plant_tool_results() {
    local sid="$1" age_s="$2"
    local slug proj_dir tr_dir
    slug=$(slug_of "$FAKE_NEXUS_ROOT")
    proj_dir="$FAKE_HOME/.claude/projects/$slug"
    tr_dir="$proj_dir/$sid/tool-results"
    mkdir -p "$tr_dir"
    printf 'x' > "$tr_dir/bigresult.txt"
    touch -d "$age_s seconds ago" "$tr_dir"
    printf '%s' "$tr_dir"
}

reset_world() {
    rm -f "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD"
    rm -rf "$FAKE_HOME/.claude/projects" 2>/dev/null || true
    mkdir -p "$FAKE_HOME/.claude/projects"
}

now=$(date +%s)

# --- 1: idle-but-healthy — no paste, no respawn -------------------------
#
# A quiet workspace with no recent watcher emits is the dominant
# steady state. Heartbeat may be stale (orch hasn't done a turn in
# minutes); state machine must NOT respawn.

reset_world
# Plant a stale heartbeat to make sure the test isn't pass-by-default.
: > "$HB"; touch -d "600 seconds ago" "$HB"
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == healthy* ]]; then
    pass "idle-but-healthy (no paste, stale heartbeat) → healthy verdict, no respawn"
else
    fail "idle-but-healthy: rc=$rc verdict='$verdict' (expected healthy)"
fi
[[ -f "$US" ]] && fail "idle-but-healthy: unresponsive-since marker should be absent"

# --- 2: pasted-then-acked — heartbeat past paste → healthy --------------
#
# Watcher paste landed, orchestrator turn-ended (Stop hook bumped
# heartbeat) after the paste. State machine: heartbeat_mtime > paste_ts
# is the strongest "I reacted" signal.

reset_world
write_paste_ts "$LP" "$(( now - 200 ))"
: > "$HB"; touch -d "30 seconds ago" "$HB"   # heartbeat 30s ago > paste 200s ago
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == healthy* ]]; then
    pass "pasted-then-acked (heartbeat 30s, paste 200s) → healthy"
else
    fail "pasted-then-acked: rc=$rc verdict='$verdict'"
fi

# --- 3: pasted-without-response, within grace → healthy ------------------
#
# Paste landed inside the grace window. Even a real wedge wouldn't
# have manifested yet — multi-step tool turns legitimately take this
# long. Healthy + no marker.

reset_world
write_paste_ts "$LP" "$(( now - 30 ))"
# Heartbeat older than the paste — orch hasn't turn-ended since
# the poke.
: > "$HB"; touch -d "120 seconds ago" "$HB"
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == healthy* ]]; then
    pass "pasted-within-grace (age=30s, grace=60s) → healthy, no marker"
else
    fail "pasted-within-grace: rc=$rc verdict='$verdict'"
fi
[[ -f "$US" ]] && fail "pasted-within-grace: marker should NOT be stamped"

# --- 4: pasted-without-response, past grace → waiting + marker stamped ---
#
# Paste 90s old, heartbeat 200s old. Past grace; state machine
# stamps the unresponsive-since marker AND returns "waiting" (rc=1)
# so detect_and_unstick gets a chance to recover.

reset_world
write_paste_ts "$LP" "$(( now - 90 ))"
: > "$HB"; touch -d "200 seconds ago" "$HB"
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == waiting* ]]; then
    pass "pasted-past-grace (age=90s, grace=60s) → waiting verdict"
else
    fail "pasted-past-grace: rc=$rc verdict='$verdict'"
fi
if [[ -f "$US" ]]; then
    pass "pasted-past-grace: unresponsive-since marker stamped"
else
    fail "pasted-past-grace: marker missing"
fi

# --- 5: stuck-then-recovered — heartbeat bumps after marker → healthy ----
#
# Marker was stamped a moment ago, but the unstick handler (or the
# orchestrator on its own) just turn-ended and bumped the heartbeat
# past the last paste. State machine: heartbeat fresher than paste
# → healthy. Marker must be cleared so the next wedge starts a
# fresh unstick budget.

# Set up a state where the marker exists from a prior cycle.
reset_world
write_paste_ts "$LP" "$(( now - 200 ))"
: > "$HB"; touch -d "300 seconds ago" "$HB"  # initially stale
: > "$US"; touch -d "100 seconds ago" "$US"  # marker from earlier
# Now simulate the unstick succeeding — heartbeat bumps to "now":
touch "$HB"
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == healthy* ]]; then
    pass "stuck-then-recovered (heartbeat bumped to now) → healthy"
else
    fail "stuck-then-recovered: rc=$rc verdict='$verdict'"
fi
if [[ ! -f "$US" ]]; then
    pass "stuck-then-recovered: unresponsive-since marker cleared"
else
    fail "stuck-then-recovered: marker should be cleared on healthy"
fi

# --- 6: fully-wedged — unstick window exhausted → re-submit rescue -------
#
# Marker stamped 200s ago (> unstick_window 180s). Paste 250s ago
# (< dead_threshold 300s). No re-submit attempted yet. The state
# machine must request the one-shot re-paste rescue, NOT a respawn —
# a dropped Enter on an alive pane is rescued by a re-paste
# (resilience change; previously this escalated straight to respawn
# and killed four healthy-but-slow orchestrator turns 2026-05-29..31).

reset_world
write_paste_ts "$LP" "$(( now - 250 ))"
: > "$HB"; touch -d "300 seconds ago" "$HB"
: > "$US"; touch -d "200 seconds ago" "$US"
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == resubmit*unstick-window-exhausted* ]]; then
    pass "fully-wedged (unstick window exhausted, no resubmit yet) → resubmit verdict"
else
    fail "fully-wedged: rc=$rc verdict='$verdict' (expected resubmit)"
fi
# The step must NOT stamp the resubmit marker itself — only the
# caller does, after actually attempting the re-paste.
if [[ ! -f "$RS" ]]; then
    pass "fully-wedged: step does not stamp the resubmit marker (caller's job)"
else
    fail "fully-wedged: resubmit marker stamped by step (must be caller-stamped)"
fi

# --- 7: dead-threshold floor — age past dead_threshold → respawn ---------
#
# Paste 350s ago (> dead_threshold 300s). Marker only 30s old
# (< unstick_window 180s). The dead_threshold cap fires regardless
# of the unstick budget — a wedge that the state machine missed
# stamping on time still escalates.

reset_world
write_paste_ts "$LP" "$(( now - 350 ))"
: > "$HB"; touch -d "400 seconds ago" "$HB"
: > "$US"; touch -d "30 seconds ago" "$US"
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 0 )) && [[ "$verdict" == respawn* ]]; then
    pass "dead-threshold floor (age=350s, dead=300s) → respawn"
else
    fail "dead-threshold floor: rc=$rc verdict='$verdict'"
fi

# --- 8: cooldown gate — respawn verdict suppressed by recent spawn -------
#
# Even when the state machine would respawn, a cooldown stamp
# inside `cooldown_seconds` must block it. Mtime-based; identical
# protocol to _orchestrator_should_fresh_spawn's gate.

reset_world
write_paste_ts "$LP" "$(( now - 350 ))"
: > "$HB"; touch -d "400 seconds ago" "$HB"
: > "$US"; touch -d "30 seconds ago" "$US"
: > "$CD"; touch -d "60 seconds ago" "$CD"   # 60s < 1800s cooldown
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == blocked-by-cooldown* ]]; then
    pass "cooldown-gate (cooldown 60s < 1800s) → respawn blocked"
else
    fail "cooldown-gate: rc=$rc verdict='$verdict'"
fi

# --- 9: jsonl-mtime backward-compat — heartbeat absent but jsonl fresh ---
#
# A session whose orchestrator-settings.json predates the Stop hook
# will never touch the heartbeat file. The state machine must fall
# back to the pinned session's jsonl mtime: any write past the
# paste counts as "orch responded." Default ships should never need
# this branch, but it covers the upgrade window cleanly.

reset_world
write_paste_ts "$LP" "$(( now - 200 ))"
# Heartbeat absent (rm'd by reset_world).
printf '%s\n' "$VALID_SID" > "$PIN"
plant_jsonl "$VALID_SID" 60 >/dev/null   # jsonl 60s ago > paste 200s ago
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == healthy* ]]; then
    pass "jsonl-fallback (no heartbeat, jsonl past paste) → healthy"
else
    fail "jsonl-fallback: rc=$rc verdict='$verdict'"
fi

# --- 10: legacy-settings + stale jsonl → state machine still escalates --
#
# Worst case: settings file too old for the heartbeat hook AND the
# pinned jsonl mtime hasn't advanced either. State machine treats
# this as no-evidence-of-response and progresses through the budgets
# normally.

reset_world
write_paste_ts "$LP" "$(( now - 400 ))"  # past dead_threshold
printf '%s\n' "$VALID_SID" > "$PIN"
plant_jsonl "$VALID_SID" 600 >/dev/null  # jsonl 600s ago < paste 400s ago
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 0 )) && [[ "$verdict" == respawn* ]]; then
    pass "legacy-settings + stale jsonl past dead-threshold → respawn"
else
    fail "legacy-settings dead-threshold: rc=$rc verdict='$verdict'"
fi

# --- 11: pure-idle quiet workspace across many cycles → never fires ------
#
# Issue #157's failure mode was "quiet workspace looks dead because
# nothing's writing." This is now structurally impossible: no paste
# → no signal to react to → healthy. Verify across many simulated
# cycles.

reset_world
fire_count=0
for cycle in 1 2 3 4 5 6 7 8 9 10; do
    if verdict=$(HOME="$FAKE_HOME" \
                 _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
                 "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT"); then
        fire_count=$(( fire_count + 1 ))
    fi
done
if (( fire_count == 0 )); then
    pass "10 cycles, no paste ever → state machine never escalates (#157 fix)"
else
    fail "state machine fired ${fire_count}/10 cycles on a quiet workspace"
fi

# --- 12: empty / unparseable paste-ts → healthy (defensive) --------------

reset_world
: > "$LP"
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == healthy* ]]; then
    pass "empty paste-ts file → healthy (defensive)"
else
    fail "empty paste-ts: rc=$rc verdict='$verdict'"
fi

reset_world
printf 'not-an-epoch\n' > "$LP"
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == healthy* ]]; then
    pass "garbage paste-ts file → healthy (defensive)"
else
    fail "garbage paste-ts: rc=$rc verdict='$verdict'"
fi

# --- 13: decide() pure form — exposed for callers that don't want side fx
#
# Smoke check that _orchestrator_liveness_decide returns identical
# verdicts without managing the marker file.

reset_world
write_paste_ts "$LP" "$(( now - 90 ))"
: > "$HB"; touch -d "200 seconds ago" "$HB"
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_decide "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" \
          "$GRACE" "$UNSTICK" "$DEAD" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == waiting* ]]; then
    pass "_orchestrator_liveness_decide returns 'waiting' verbatim"
else
    fail "_orchestrator_liveness_decide: rc=$rc verdict='$verdict'"
fi

# --- 14: pasted-and-received-but-still-mid-turn → healthy ----------------
#
# The load-bearing addition. A multi-step tool turn looks identical
# to a wedge from heartbeat alone: Stop hasn't fired (still mid-
# turn), so heartbeat_mtime < last_paste_ts. The UserPromptSubmit
# hook bumps `orchestrator-paste-received` the moment the prompt
# lands in the orchestrator's input queue — proves the agent has
# the paste and is actively processing it. State machine prefers
# this signal over the fragile jsonl-mtime fallback.

reset_world
# Paste landed 200s ago. Heartbeat is much older — orchestrator
# hasn't turn-ended since (still running a multi-step tool turn).
write_paste_ts "$LP" "$(( now - 200 ))"
: > "$HB"; touch -d "600 seconds ago" "$HB"
# Paste-received was bumped 180s ago — i.e. ~20s after the paste,
# the orchestrator's UserPromptSubmit hook fired. The agent is
# processing.
: > "$PR"; touch -d "180 seconds ago" "$PR"
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == healthy* ]]; then
    pass "pasted-and-received-mid-turn (paste 200s, heartbeat 600s, paste-received 180s) → healthy"
else
    fail "mid-turn: rc=$rc verdict='$verdict'"
fi
[[ -f "$US" ]] && fail "mid-turn: unresponsive-since marker should NOT be stamped"

# --- 15: paste-received predates paste → does NOT count as response -----
#
# Defensive: paste-received mtime BEFORE last_paste_ts means an
# older response, not the current one. State machine must ignore
# it and fall through to the next signal (or pasted-without-response).

reset_world
write_paste_ts "$LP" "$(( now - 200 ))"
: > "$HB"; touch -d "600 seconds ago" "$HB"
# Paste-received from before this paste — from a prior cycle.
: > "$PR"; touch -d "300 seconds ago" "$PR"
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == waiting* ]]; then
    pass "paste-received predates paste (300s vs 200s) → waiting (does not count)"
else
    fail "paste-received-stale: rc=$rc verdict='$verdict'"
fi

# --- 16: paste-received present but no heartbeat/jsonl → still healthy --
#
# A session whose Stop hook somehow never fires (orphaned tool
# turn, hang inside Claude Code's Stop dispatch) but whose
# UserPromptSubmit fires normally still produces a healthy
# verdict on paste-received alone. The state machine doesn't
# require all three signals — any one past the paste is
# sufficient.

reset_world
write_paste_ts "$LP" "$(( now - 200 ))"
# No heartbeat file at all.
: > "$PR"; touch -d "100 seconds ago" "$PR"
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == healthy* ]]; then
    pass "paste-received only (no heartbeat / jsonl) → healthy"
else
    fail "paste-received-only: rc=$rc verdict='$verdict'"
fi

# --- 17: paste-received preferred over jsonl-mtime ----------------------
#
# A session with both signals available: state machine prefers
# the paste-received hook over the fragile jsonl-mtime fallback.
# This test verifies the ordering by setting paste-received past
# the paste and jsonl-mtime before the paste — the helper must
# short-circuit on paste-received and never look at jsonl.

reset_world
write_paste_ts "$LP" "$(( now - 200 ))"
: > "$HB"; touch -d "600 seconds ago" "$HB"
: > "$PR"; touch -d "100 seconds ago" "$PR"
# jsonl is stale (predates the paste) — but paste-received already
# proved the agent is processing.
printf '%s\n' "$VALID_SID" > "$PIN"
plant_jsonl "$VALID_SID" 600 >/dev/null
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == healthy* ]]; then
    pass "paste-received fresh + jsonl stale → healthy (paste-received preferred)"
else
    fail "paste-received-over-jsonl: rc=$rc verdict='$verdict'"
fi

# --- 18: marker persists across cycles → elapsed accumulates -------------
#
# The marker file's mtime is the unstick-budget anchor. Once stamped,
# repeated calls should observe accumulated elapsed without re-
# stamping (otherwise the budget would reset every cycle).

reset_world
write_paste_ts "$LP" "$(( now - 90 ))"
: > "$HB"; touch -d "200 seconds ago" "$HB"
# Cycle 1: stamps the marker.
HOME="$FAKE_HOME" \
    _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
    "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT" >/dev/null || true
# Back-date the marker by 30s to simulate one polling cycle elapsing.
touch -d "30 seconds ago" "$US"
# Cycle 2: must NOT re-stamp; mtime stays back-dated.
HOME="$FAKE_HOME" \
    _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
    "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT" >/dev/null || true
us_age=$(( $(date +%s) - $(date +%s -r "$US") ))
if (( us_age >= 27 && us_age <= 33 )); then
    pass "unresponsive-since marker persists (age=${us_age}s, expected ~30s)"
else
    fail "marker re-stamped or drifted: age=${us_age}s expected ~30s"
fi

# --- 19: stale-paste ceiling — long idle does NOT trip dead-threshold ----
#
# Regression for the 2026-05-27 02:50 incident: orchestrator stood by
# silently for ~3.5 h with no eligible pastes and no response signals.
# The watcher fired `respawn reason=dead-threshold age=12602s`, killing
# a healthy session that had simply nothing to react to. Pure idle must
# NOT respawn — once the paste is too old to be evidence of wedging,
# the dead-threshold cap must yield to a stale-paste ceiling. The
# default ceiling (1800 s) is well above dead_threshold (300 s) so the
# wedge window stays intact.

reset_world
# Age = ceiling default (1800) + 60 s. No response signals; no prior
# unresponsive-since marker.
write_paste_ts "$LP" "$(( now - 1860 ))"
: > "$HB"; touch -d "2000 seconds ago" "$HB"
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == *paste-too-stale* ]]; then
    pass "long-idle (age 1860s, ceiling 1800s) → healthy paste-too-stale, NOT respawn"
else
    fail "long-idle ceiling: rc=$rc verdict='$verdict' (expected healthy paste-too-stale)"
fi

# --- 20: marker cleared on paste-too-stale healthy -----------------------
#
# A `paste-too-stale` verdict is a healthy decision; like every other
# healthy verdict it must clear the unresponsive-since marker so the
# next genuine wedge starts with a fresh unstick budget. Without this
# clear, a stale marker carried over from a prior cycle would bias
# `elapsed_unstick` in the next pasted-without-response episode.

reset_world
write_paste_ts "$LP" "$(( now - 1860 ))"
: > "$HB"; touch -d "2000 seconds ago" "$HB"
: > "$US"; touch -d "100 seconds ago" "$US"   # marker survived from prior cycle
HOME="$FAKE_HOME" \
    _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
    "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT" >/dev/null || true
if [[ ! -f "$US" ]]; then
    pass "paste-too-stale healthy clears the unresponsive-since marker"
else
    fail "paste-too-stale: marker should be cleared (still present)"
fi

# --- 21: dead-threshold still fires INSIDE the ceiling window -----------
#
# Regression guard: the ceiling caps when the dead-threshold check
# applies, but does NOT suppress it inside the [dead, ceiling) range.
# A genuine wedge at age = dead_threshold + 10 s must still respawn.

reset_world
write_paste_ts "$LP" "$(( now - 310 ))"
: > "$HB"; touch -d "400 seconds ago" "$HB"
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 0 )) && [[ "$verdict" == respawn*dead-threshold* ]]; then
    pass "in-window wedge (age=310s, dead=300s, ceiling=1800s) → respawn dead-threshold"
else
    fail "in-window wedge regression: rc=$rc verdict='$verdict'"
fi

# --- 22: fresh paste resets the clock — ceiling does not interfere ------
#
# After a paste-too-stale verdict, a fresh paste-to-orchestrator
# rewrites last_paste_ts to "now". The state machine must re-engage
# normally on the next cycle — fresh paste 90 s ago, past grace, no
# response signal → waiting verdict (not blocked by the ceiling, not
# masked by anything from the prior idle stretch).

reset_world
write_paste_ts "$LP" "$(( now - 2000 ))"
: > "$HB"; touch -d "2200 seconds ago" "$HB"
# Cycle 1: well past ceiling → paste-too-stale healthy.
HOME="$FAKE_HOME" \
    _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
    "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT" >/dev/null || true
# Fresh paste lands — rewrite paste-ts to 90s ago (past grace).
write_paste_ts "$LP" "$(( now - 90 ))"
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == waiting* ]]; then
    pass "fresh paste after ceiling → waiting (state machine re-engaged)"
else
    fail "fresh-paste-reset: rc=$rc verdict='$verdict'"
fi

# ==========================================================================
# Orchestrator-liveness resilience (re-submit before respawn, log throttle,
# 120/150/300 defaults).
# ==========================================================================

# --- 23: resubmit verdict → marker stamped by caller → resubmit-pending --
#
# Full hand-off sequence: exhaustion produces `resubmit`, the caller
# (simulated here) stamps the marker and re-pastes, and the next
# cycle returns `waiting reason=resubmit-pending` instead of a
# second resubmit or a respawn.

reset_world
write_paste_ts "$LP" "$(( now - 250 ))"
: > "$HB"; touch -d "300 seconds ago" "$HB"
: > "$US"; touch -d "200 seconds ago" "$US"
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == resubmit* ]]; then
    pass "resubmit-handoff: cycle 1 → resubmit verdict"
else
    fail "resubmit-handoff cycle 1: rc=$rc verdict='$verdict'"
fi
# Caller performs the re-paste and stamps the marker (10s ago to
# simulate one-and-a-bit poll cycles elapsing).
: > "$RS"; touch -d "10 seconds ago" "$RS"
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == waiting*resubmit-pending* ]]; then
    pass "resubmit-handoff: cycle 2 (marker 10s old) → waiting resubmit-pending"
else
    fail "resubmit-handoff cycle 2: rc=$rc verdict='$verdict'"
fi

# --- 24: resubmit failed (no response past grace) → respawn ---------------
#
# The re-paste was attempted but the orchestrator produced no
# response signal within one grace window. The rescue failed —
# escalate to respawn. This also proves the one-shot cap: a second
# resubmit verdict is never produced once the marker exists.

reset_world
write_paste_ts "$LP" "$(( now - 280 ))"
: > "$HB"; touch -d "400 seconds ago" "$HB"
: > "$US"; touch -d "220 seconds ago" "$US"
# Marker stamped longer than grace (60s in this parameterisation) ago.
: > "$RS"; touch -d "70 seconds ago" "$RS"
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 0 )) && [[ "$verdict" == respawn*resubmit-failed* ]]; then
    pass "resubmit-failed (marker 70s > grace 60s, no signal) → respawn"
else
    fail "resubmit-failed: rc=$rc verdict='$verdict'"
fi

# --- 25: resubmit rescued — response signal arrives → healthy + cleanup ---
#
# The re-paste landed and the orchestrator picked it up (heartbeat
# advanced past the original paste). Healthy verdict; BOTH markers
# (unresponsive-since and resubmit-attempted) must be cleared so the
# next wedge episode starts with a fresh budget and a fresh one-shot
# rescue allowance.

reset_world
write_paste_ts "$LP" "$(( now - 280 ))"
: > "$US"; touch -d "220 seconds ago" "$US"
: > "$RS"; touch -d "20 seconds ago" "$RS"
# Heartbeat bumps to now — the re-paste worked.
: > "$HB"; touch "$HB"
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == healthy* ]]; then
    pass "resubmit-rescued (heartbeat past paste) → healthy"
else
    fail "resubmit-rescued: rc=$rc verdict='$verdict'"
fi
if [[ ! -f "$US" && ! -f "$RS" ]]; then
    pass "resubmit-rescued: both markers cleared on healthy"
else
    fail "resubmit-rescued: markers not cleared (US=$([[ -f "$US" ]] && echo present || echo absent) RS=$([[ -f "$RS" ]] && echo present || echo absent))"
fi

# --- 26: dead-threshold supremacy — resubmit cannot defer the deadline ----
#
# Even with a freshly-stamped resubmit marker (rescue in flight),
# age past dead_threshold respawns unconditionally. The re-submit
# path must never defeat the absolute deadline.

reset_world
write_paste_ts "$LP" "$(( now - 350 ))"   # past dead_threshold 300
: > "$HB"; touch -d "500 seconds ago" "$HB"
: > "$US"; touch -d "280 seconds ago" "$US"
: > "$RS"; touch -d "5 seconds ago" "$RS"   # rescue just fired
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 0 )) && [[ "$verdict" == respawn*dead-threshold* ]]; then
    pass "dead-threshold supremacy (age 350s, marker 5s) → respawn dead-threshold"
else
    fail "dead-threshold supremacy: rc=$rc verdict='$verdict'"
fi

# --- 27: new defaults (120/150/300) — rescue fires before the deadline ----
#
# With the shipped defaults the exhaustion boundary sits at
# grace + unstick = 270s, leaving a 30s verification window before
# the 300s dead threshold. Verify the resubmit verdict is reachable
# under the defaults (i.e. the knob rebalance keeps the rescue
# meaningful) and that a turn slower than the old 60s grace but
# inside the new 120s grace stays healthy.

NEW_GRACE=120
NEW_UNSTICK=150
NEW_DEAD=300

# (a) A 90s-old paste with no response — within the new grace —
# stays healthy. Under the old 60s grace this entered the countdown
# (the 2026-05-29..31 false-positive incidents).
reset_world
write_paste_ts "$LP" "$(( now - 90 ))"
: > "$HB"; touch -d "300 seconds ago" "$HB"
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$NEW_GRACE" "$NEW_UNSTICK" "$NEW_DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == healthy*within-grace* ]]; then
    pass "new-defaults: 90s-old unanswered paste → healthy (inside 120s grace)"
else
    fail "new-defaults within-grace: rc=$rc verdict='$verdict'"
fi

# (b) Exhaustion under the defaults (age 280s, marker past 150s
# unstick window, no resubmit yet, age < 300 dead) → resubmit.
reset_world
write_paste_ts "$LP" "$(( now - 280 ))"
: > "$HB"; touch -d "500 seconds ago" "$HB"
: > "$US"; touch -d "155 seconds ago" "$US"
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$NEW_GRACE" "$NEW_UNSTICK" "$NEW_DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == resubmit* ]]; then
    pass "new-defaults: exhaustion at age 280s < dead 300s → resubmit fires"
else
    fail "new-defaults exhaustion: rc=$rc verdict='$verdict'"
fi

# (c) Constraint sanity: grace + unstick < dead under the defaults.
if (( NEW_GRACE + NEW_UNSTICK < NEW_DEAD )); then
    pass "new-defaults: grace ($NEW_GRACE) + unstick ($NEW_UNSTICK) < dead ($NEW_DEAD)"
else
    fail "new-defaults: constraint violated — rescue can never fire before deadline"
fi

# --- 28: log throttle — entry + periodic + transitions only ---------------
#
# The _orchestrator_liveness_log_decide helper turns the per-poll
# verdict stream into a throttled breadcrumb trail. Timestamps are
# injected so the test is fully deterministic.

# Reset the throttle's process-global state.
unset _ORCH_LIVENESS_LOG_STATE _ORCH_LIVENESS_LOG_LAST_TS \
      _ORCH_LIVENESS_LOG_ENTERED_TS _ORCH_LIVENESS_LOG_SUPPRESSED \
      _ORCH_LIVENESS_LOG_LINE 2>/dev/null || true

T0=1000000
THROTTLE=30

# (a) healthy → healthy: silent.
_orchestrator_liveness_log_decide "healthy reason=no-paste-yet" "$T0" "$THROTTLE"
if [[ -z "$_ORCH_LIVENESS_LOG_LINE" ]]; then
    pass "log-throttle: healthy steady state is silent"
else
    fail "log-throttle: healthy logged '\$_ORCH_LIVENESS_LOG_LINE'"
fi

# (b) healthy → waiting: state entry always logs.
_orchestrator_liveness_log_decide "waiting reason=unstick-window age=70s" "$(( T0 + 5 ))" "$THROTTLE"
if [[ -n "$_ORCH_LIVENESS_LOG_LINE" && "$_ORCH_LIVENESS_LOG_LINE" == *"entered waiting"* ]]; then
    pass "log-throttle: waiting state entry logs"
else
    fail "log-throttle: waiting entry produced '$_ORCH_LIVENESS_LOG_LINE'"
fi

# (c) waiting polls inside the throttle window: suppressed.
suppressed_all=1
for dt in 10 15 20 25; do
    _orchestrator_liveness_log_decide "waiting reason=unstick-window age=$(( 70 + dt ))s" "$(( T0 + 5 + dt ))" "$THROTTLE"
    [[ -n "$_ORCH_LIVENESS_LOG_LINE" ]] && suppressed_all=0
done
if (( suppressed_all == 1 )); then
    pass "log-throttle: 4 waiting polls inside 30s window all suppressed"
else
    fail "log-throttle: a within-window waiting poll leaked a log line"
fi

# (d) waiting poll past the throttle window: logs with suppressed count.
_orchestrator_liveness_log_decide "waiting reason=unstick-window age=110s" "$(( T0 + 40 ))" "$THROTTLE"
if [[ -n "$_ORCH_LIVENESS_LOG_LINE" && "$_ORCH_LIVENESS_LOG_LINE" == *"4 polls suppressed"* ]]; then
    pass "log-throttle: periodic line carries suppressed-poll count"
else
    fail "log-throttle: periodic line was '$_ORCH_LIVENESS_LOG_LINE'"
fi

# (e) waiting → resubmit: always logged verbatim.
_orchestrator_liveness_log_decide "resubmit reason=unstick-window-exhausted age=250s" "$(( T0 + 45 ))" "$THROTTLE"
if [[ "$_ORCH_LIVENESS_LOG_LINE" == resubmit* ]]; then
    pass "log-throttle: resubmit event always logged"
else
    fail "log-throttle: resubmit produced '$_ORCH_LIVENESS_LOG_LINE'"
fi

# (f) resubmit → waiting (resubmit-pending): re-entry logs, episode
# anchor preserved (duration counts from the original entry).
_orchestrator_liveness_log_decide "waiting reason=resubmit-pending age=255s" "$(( T0 + 50 ))" "$THROTTLE"
if [[ -n "$_ORCH_LIVENESS_LOG_LINE" && "$_ORCH_LIVENESS_LOG_LINE" == *"entered waiting"* ]]; then
    pass "log-throttle: resubmit → waiting re-entry logs"
else
    fail "log-throttle: resubmit → waiting produced '$_ORCH_LIVENESS_LOG_LINE'"
fi

# (g) waiting → healthy: recovery summary with episode duration
# (anchored at the ORIGINAL waiting entry T0+5, not the re-entry).
_orchestrator_liveness_log_decide "healthy reason=signal-past-paste age=260s" "$(( T0 + 65 ))" "$THROTTLE"
if [[ "$_ORCH_LIVENESS_LOG_LINE" == *"recovered after 60s"* ]]; then
    pass "log-throttle: recovery summary spans the whole episode (60s)"
else
    fail "log-throttle: recovery summary was '$_ORCH_LIVENESS_LOG_LINE'"
fi

# (h) healthy → healthy after recovery: silent again.
_orchestrator_liveness_log_decide "healthy reason=no-paste-yet" "$(( T0 + 70 ))" "$THROTTLE"
if [[ -z "$_ORCH_LIVENESS_LOG_LINE" ]]; then
    pass "log-throttle: post-recovery healthy is silent"
else
    fail "log-throttle: post-recovery healthy logged '$_ORCH_LIVENESS_LOG_LINE'"
fi

# (i) waiting → respawn: escalation summary logged.
_orchestrator_liveness_log_decide "waiting reason=unstick-window age=70s" "$(( T0 + 100 ))" "$THROTTLE"
_orchestrator_liveness_log_decide "respawn reason=dead-threshold age=310s" "$(( T0 + 130 ))" "$THROTTLE"
if [[ -n "$_ORCH_LIVENESS_LOG_LINE" && "$_ORCH_LIVENESS_LOG_LINE" == *"escalated to respawn"* ]]; then
    pass "log-throttle: waiting → respawn logs escalation summary"
else
    fail "log-throttle: respawn transition produced '$_ORCH_LIVENESS_LOG_LINE'"
fi

# (j) blocked-by-cooldown is throttled like waiting (same class).
unset _ORCH_LIVENESS_LOG_STATE _ORCH_LIVENESS_LOG_LAST_TS \
      _ORCH_LIVENESS_LOG_ENTERED_TS _ORCH_LIVENESS_LOG_SUPPRESSED \
      _ORCH_LIVENESS_LOG_LINE 2>/dev/null || true
_orchestrator_liveness_log_decide "blocked-by-cooldown respawn reason=dead-threshold" "$T0" "$THROTTLE"
first_line="$_ORCH_LIVENESS_LOG_LINE"
_orchestrator_liveness_log_decide "blocked-by-cooldown respawn reason=dead-threshold" "$(( T0 + 5 ))" "$THROTTLE"
if [[ -n "$first_line" && -z "$_ORCH_LIVENESS_LOG_LINE" ]]; then
    pass "log-throttle: blocked-by-cooldown logs entry then throttles"
else
    fail "log-throttle: blocked-by-cooldown entry='$first_line' second='$_ORCH_LIVENESS_LOG_LINE'"
fi

# ==========================================================================
# Tool-results witness (operator-blind-spot fix, 2026-06-05 false-positive
# orchestrator respawn). An INDEPENDENT, watcher-side activity signal —
# folded into the liveness verdict itself rather than overriding it after
# the fact — so a live orchestrator the operator drives directly is
# detected as alive, while a genuinely-stuck one (no fresh tool-results)
# still respawns.
# ==========================================================================

# --- 29: tool-results witness — THE incident regression ------------------
#
# Encodes the 2026-06-05 kill. The operator drove the orchestrator
# directly (manual pane paste, invisible to the watcher's paste-
# tracking), so all three paste-keyed signals {heartbeat, paste-
# received, jsonl} sit at/below last_paste_ts — yet the live session
# offloaded a 1.6 MB tool output 28 s before the would-be kill,
# advancing the tool-results/ dir mtime. `age` is PAST dead_threshold,
# so without the witness the unconditional dead-threshold floor
# respawns a demonstrably-busy orchestrator. With it: healthy.

reset_world
write_paste_ts "$LP" "$(( now - 350 ))"          # past dead_threshold (300)
: > "$HB"; touch -d "500 seconds ago" "$HB"       # heartbeat older than the paste
: > "$PR"; touch -d "500 seconds ago" "$PR"       # paste-received older than the paste
printf '%s\n' "$VALID_SID" > "$PIN"
plant_jsonl "$VALID_SID" 600 >/dev/null           # jsonl older than the paste
plant_tool_results "$VALID_SID" 28 >/dev/null     # tool-results 28s ago > paste 350s ago
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == healthy* ]]; then
    pass "tool-results witness (incident): paste-keyed signals lag, tool-results 28s ago → healthy, NOT respawn"
else
    fail "tool-results witness (incident): rc=$rc verdict='$verdict' (expected healthy)"
fi
[[ -f "$US" ]] && fail "tool-results witness: unresponsive-since marker should NOT be stamped"

# --- 30: true-dead safety net — tool-results ALSO stale → still respawn ---
#
# The witness must not neuter the safety net. A genuinely-hung
# session writes nothing anywhere: all four signals (heartbeat,
# paste-received, jsonl, tool-results) predate last_paste_ts and age
# is past dead_threshold → respawn STILL fires.

reset_world
write_paste_ts "$LP" "$(( now - 350 ))"
: > "$HB"; touch -d "500 seconds ago" "$HB"
printf '%s\n' "$VALID_SID" > "$PIN"
plant_jsonl "$VALID_SID" 600 >/dev/null
plant_tool_results "$VALID_SID" 600 >/dev/null    # tool-results 600s ago < paste 350s ago
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 0 )) && [[ "$verdict" == respawn*dead-threshold* ]]; then
    pass "true-dead safety net: all four signals stale (incl. tool-results) → respawn still fires"
else
    fail "true-dead safety net: rc=$rc verdict='$verdict' (expected respawn dead-threshold)"
fi

# --- 31: pure helper — fresh tool-results alone counts as "responded" ----
#
# Direct check of _orchestrator_pasted_without_response: heartbeat /
# paste-received absent, jsonl absent, but a fresh tool-results dir →
# rc=1 (responded / alive). (rc=0 would mean pasted-without-response.)

reset_world
write_paste_ts "$LP" "$(( now - 350 ))"
printf '%s\n' "$VALID_SID" > "$PIN"
plant_tool_results "$VALID_SID" 30 >/dev/null
if HOME="$FAKE_HOME" \
   _orchestrator_pasted_without_response "$HB" "$PR" "$LP" "$PIN" "$FAKE_NEXUS_ROOT"; then
    fail "pasted-without-response: fresh tool-results should read as responded (rc=1), got rc=0"
else
    pass "pasted-without-response: fresh tool-results dir alone → responded (rc=1)"
fi

# --- 32: tool-results that PREDATES the paste does NOT count -------------
#
# Defensive ordering check: a tool-results dir whose mtime is older
# than last_paste_ts is stale evidence from a prior turn and must NOT
# flip the verdict. Past grace, no fresh signal → waiting.

reset_world
write_paste_ts "$LP" "$(( now - 90 ))"            # past grace (60), inside dead (300)
: > "$HB"; touch -d "300 seconds ago" "$HB"
printf '%s\n' "$VALID_SID" > "$PIN"
plant_tool_results "$VALID_SID" 200 >/dev/null    # tool-results 200s ago < paste 90s ago
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == waiting* ]]; then
    pass "stale tool-results (predates paste) does not flip verdict → waiting"
else
    fail "stale tool-results: rc=$rc verdict='$verdict' (expected waiting)"
fi

# --- 33: static-workspace gap (2026-06-15 incident) ----------------------
#
# In a fully-static workspace compose_emit fires only when workspace state
# changes or the full-state interval (600 s) elapses. With a 60 s loop
# tick the maximum paste gap is 660 s — greater than dead_threshold (300).
# When the paste ages past dead_threshold and all response signals predate
# it (fast-then-idle orchestrator: quick response, then nothing for 10 min),
# the step function correctly escalates to `respawn reason=dead-threshold`.
# The idle-pane guard in `_v2_task_orchestrator_liveness` (main.sh) must
# intercept this and suppress the kill when the pane is provably idle.
# This test validates the step-level escalation so the guard has a target.
#
# Signals are set definitively OLDER than the paste (using 700 s age for
# 641 s paste) to avoid epoch-second timing sensitivity from test execution
# drift between `now=$(date +%s)` and the `touch -d "N seconds ago"` calls.

reset_world
write_paste_ts "$LP" "$(( now - 641 ))"             # 641 s > dead_threshold (300)
: > "$HB"; touch -d "700 seconds ago" "$HB"          # heartbeat before the paste
: > "$PR"; touch -d "700 seconds ago" "$PR"          # paste-received before the paste
printf '%s\n' "$VALID_SID" > "$PIN"
plant_jsonl         "$VALID_SID" 700 >/dev/null      # jsonl before the paste
plant_tool_results  "$VALID_SID" 700 >/dev/null      # tool-results before the paste
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 0 )) && [[ "$verdict" == respawn*dead-threshold* ]]; then
    pass "static-workspace gap (2026-06-15): paste 641s old, all signals predate it → step produces respawn (idle-pane guard in main.sh intercepts when pane is idle)"
else
    fail "static-workspace gap: rc=$rc verdict='$verdict' (expected respawn dead-threshold)"
fi

# --- 34: stale-ceiling is the backstop when full-state gap > ceiling ------
#
# Once last_paste_ts ages past stale_paste_ceiling_s (default 1800 s) the
# state machine returns `paste-too-stale` regardless of signals. Confirm
# that a paste age of 1800 s (exactly at the ceiling) returns stale, so
# the ceiling is a hard backstop for very long quiet periods.

reset_world
write_paste_ts "$LP" "$(( now - 1800 ))"
: > "$HB"; touch -d "2000 seconds ago" "$HB"
verdict=$(HOME="$FAKE_HOME" \
          _orchestrator_liveness_step "$HB" "$PR" "$LP" "$PIN" "$US" "$RS" "$CD" \
          "$GRACE" "$UNSTICK" "$DEAD" "$COOLDOWN" "$CEILING" "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ "$verdict" == healthy*paste-too-stale* ]]; then
    pass "stale-ceiling backstop: paste age=1800s (= ceiling) → paste-too-stale, no respawn"
else
    fail "stale-ceiling backstop: rc=$rc verdict='$verdict' (expected healthy paste-too-stale)"
fi

# --- 35: idle-pane guard — the SAFETY-CRITICAL runtime override ----------
#
# The dead-threshold respawn verdict (case 33) is intercepted at runtime
# by `_orchestrator_idle_pane_guard` in `_v2_task_orchestrator_liveness`
# (main.sh) before the kill fires. The guard is a pure function over
# (verdict, pane_state, override_count, max_overrides); these cases pin
# both failure directions the 2026-06-15 review flagged:
#   - false POSITIVE: a healthy idle/empty pane must SUPPRESS the respawn.
#   - false NEGATIVE: a genuinely-wedged pane (busy/blocked/absent), an
#     unknown/errored pane, AND an idle pane that has exhausted the
#     override budget must all PROCEED to respawn — a hung-but-idle TUI
#     can never suppress its own respawn forever.

guard() { _orchestrator_idle_pane_guard "$@"; }   # (verdict, state, count, max)

RESPAWN_V="respawn reason=dead-threshold age=641s dead_threshold=300s"

# idle pane, budget available → suppress the false positive
[[ "$(guard "$RESPAWN_V" idle 0 5)" == suppress ]] \
    && pass "idle-pane guard: state=idle, count=0/5 → suppress (false-positive respawn intercepted)" \
    || fail "idle-pane guard: state=idle, count=0/5 expected suppress, got '$(guard "$RESPAWN_V" idle 0 5)'"

# empty pane (fresh-resume quirk; process-anchored to claude-alive) → suppress
[[ "$(guard "$RESPAWN_V" empty 0 5)" == suppress ]] \
    && pass "idle-pane guard: state=empty (fresh-resume quirk, claude alive) → suppress" \
    || fail "idle-pane guard: state=empty expected suppress, got '$(guard "$RESPAWN_V" empty 0 5)'"

# busy pane (frozen spinner = a real wedge surfaces here) → proceed
[[ "$(guard "$RESPAWN_V" busy 0 5)" == proceed ]] \
    && pass "idle-pane guard: state=busy → proceed (legitimate respawn NOT suppressed)" \
    || fail "idle-pane guard: state=busy expected proceed, got '$(guard "$RESPAWN_V" busy 0 5)'"

# blocked pane (permission/api-error overlay) → proceed
[[ "$(guard "$RESPAWN_V" blocked 0 5)" == proceed ]] \
    && pass "idle-pane guard: state=blocked → proceed" \
    || fail "idle-pane guard: state=blocked expected proceed, got '$(guard "$RESPAWN_V" blocked 0 5)'"

# absent pane (process dead) → proceed (respawn is exactly right)
[[ "$(guard "$RESPAWN_V" absent 0 5)" == proceed ]] \
    && pass "idle-pane guard: state=absent (process dead) → proceed" \
    || fail "idle-pane guard: state=absent expected proceed, got '$(guard "$RESPAWN_V" absent 0 5)'"

# user-typing pane (dropped-Enter paste sits in the box) → proceed
[[ "$(guard "$RESPAWN_V" user-typing 0 5)" == proceed ]] \
    && pass "idle-pane guard: state=user-typing → proceed" \
    || fail "idle-pane guard: state=user-typing expected proceed, got '$(guard "$RESPAWN_V" user-typing 0 5)'"

# pane-state errored / no state token (empty string arg) → proceed (fail toward respawn)
[[ "$(guard "$RESPAWN_V" "" 0 5)" == proceed ]] \
    && pass "idle-pane guard: empty pane-state (errored/no token) → proceed (fails toward recoverable respawn)" \
    || fail "idle-pane guard: empty state expected proceed, got '$(guard "$RESPAWN_V" "" 0 5)'"

# unknown/novel state token → proceed (conservative)
[[ "$(guard "$RESPAWN_V" working-background 0 5)" == proceed ]] \
    && pass "idle-pane guard: unrecognised state (working-background) → proceed" \
    || fail "idle-pane guard: working-background expected proceed, got '$(guard "$RESPAWN_V" working-background 0 5)'"

# --- 36: idle-pane guard — the bounded-suppression SAFETY FLOOR -----------
#
# The override budget caps consecutive suppressions so a hung-but-idle
# pane can NOT stay dead forever. count just below the cap still
# suppresses; count at/over the cap escalates to honor the respawn.

# count=4, max=5 → still under budget → suppress
[[ "$(guard "$RESPAWN_V" idle 4 5)" == suppress ]] \
    && pass "idle-pane guard: state=idle, count=4/5 → suppress (still under budget)" \
    || fail "idle-pane guard: count=4/5 expected suppress, got '$(guard "$RESPAWN_V" idle 4 5)'"

# count=5, max=5 → budget exhausted → escalate (honor respawn)
[[ "$(guard "$RESPAWN_V" idle 5 5)" == escalate ]] \
    && pass "idle-pane guard: state=idle, count=5/5 → escalate (bounded false-negative: hung-idle pane respawned)" \
    || fail "idle-pane guard: count=5/5 expected escalate, got '$(guard "$RESPAWN_V" idle 5 5)'"

# count over the cap (e.g. stale state) → escalate
[[ "$(guard "$RESPAWN_V" empty 9 5)" == escalate ]] \
    && pass "idle-pane guard: state=empty, count=9/5 → escalate" \
    || fail "idle-pane guard: count=9/5 expected escalate, got '$(guard "$RESPAWN_V" empty 9 5)'"

# max=0 disables the bound → always suppress on idle (legacy unconditional)
[[ "$(guard "$RESPAWN_V" idle 100 0)" == suppress ]] \
    && pass "idle-pane guard: max=0 disables the bound → suppress unconditionally on idle" \
    || fail "idle-pane guard: max=0 expected suppress, got '$(guard "$RESPAWN_V" idle 100 0)'"

# non-respawn verdict is never gated (defensive) → proceed
[[ "$(guard "healthy reason=signal-past-paste age=10s" idle 0 5)" == proceed ]] \
    && pass "idle-pane guard: non-respawn verdict (healthy) → proceed (guard is a no-op off the respawn path)" \
    || fail "idle-pane guard: healthy verdict expected proceed, got '$(guard "healthy reason=signal-past-paste age=10s" idle 0 5)'"

# malformed count is treated as 0 (robustness) → suppress
[[ "$(guard "$RESPAWN_V" idle "garbage" 5)" == suppress ]] \
    && pass "idle-pane guard: malformed count → treated as 0 → suppress" \
    || fail "idle-pane guard: malformed count expected suppress, got '$(guard "$RESPAWN_V" idle "garbage" 5)'"

# --- 37: idle-pane guard — SCOPE is dead-threshold ONLY -------------------
#
# Only `respawn reason=dead-threshold` is gated (the sole verdict the
# static-workspace false positive produces). A resubmit-failed respawn has
# already proven non-responsiveness via the re-paste probe, so it must NOT
# be suppressed even on an idle pane — the false-negative would otherwise
# include a confirmed wedge.

RESUBMIT_FAILED_V="respawn reason=resubmit-failed age=400s resubmit_age=130s/120s"

[[ "$(guard "$RESUBMIT_FAILED_V" idle 0 5)" == proceed ]] \
    && pass "idle-pane guard: resubmit-failed respawn + idle pane → proceed (re-paste probe already proved the wedge; never suppressed)" \
    || fail "idle-pane guard: resubmit-failed+idle expected proceed, got '$(guard "$RESUBMIT_FAILED_V" idle 0 5)'"

[[ "$(guard "$RESUBMIT_FAILED_V" empty 0 5)" == proceed ]] \
    && pass "idle-pane guard: resubmit-failed respawn + empty pane → proceed" \
    || fail "idle-pane guard: resubmit-failed+empty expected proceed, got '$(guard "$RESUBMIT_FAILED_V" empty 0 5)'"

# a hypothetical future respawn reason is also not gated → proceed
[[ "$(guard "respawn reason=some-future-reason age=999s" idle 0 5)" == proceed ]] \
    && pass "idle-pane guard: non-dead-threshold respawn reason + idle → proceed (only dead-threshold is gated)" \
    || fail "idle-pane guard: future-reason+idle expected proceed, got '$(guard "respawn reason=some-future-reason age=999s" idle 0 5)'"

# --- 38: structural-coherence clamp (eliminate the FP race at the source) -
#
# `_orchestrator_effective_dead_threshold(dead, full, interval, margin,
# ceiling)` lifts dead_threshold above the max compose_emit gap
# (full + interval) so a static-workspace paste always resets the clock
# before the deadline — the root-cause fix for the 2026-06-15 incident.

clamp() { _orchestrator_effective_dead_threshold "$@"; }   # (dead, full, interval, margin, ceiling)

# defaults: dead=300, full=600, interval=60 → gap=660 >= 300 → clamp to 660+60=720
[[ "$(clamp 300 600 60 60 1800)" == 720 ]] \
    && pass "dead-threshold clamp: dead=300, gap=660 → clamped to 720 (race eliminated at source)" \
    || fail "dead-threshold clamp: expected 720, got '$(clamp 300 600 60 60 1800)'"

# already safe: dead=900 > gap=660 → unchanged
[[ "$(clamp 900 600 60 60 1800)" == 900 ]] \
    && pass "dead-threshold clamp: dead=900 > gap=660 → unchanged (already coherent)" \
    || fail "dead-threshold clamp: expected 900, got '$(clamp 900 600 60 60 1800)'"

# clamp would cross the stale-paste ceiling → DECLINE (return configured value)
# gap=1700+60=1760, floor=1820 >= ceiling 1800 → decline, leave dead unchanged
[[ "$(clamp 300 1700 60 60 1800)" == 300 ]] \
    && pass "dead-threshold clamp: floor (1820) would cross ceiling (1800) → declines, leaves dead=300 (invariant dead<ceiling preserved)" \
    || fail "dead-threshold clamp: expected decline to 300, got '$(clamp 300 1700 60 60 1800)'"

# boundary: gap exactly equals dead → still clamps (>= comparison)
[[ "$(clamp 660 600 60 60 1800)" == 720 ]] \
    && pass "dead-threshold clamp: gap == dead (660) → clamps (boundary is inclusive)" \
    || fail "dead-threshold clamp: expected 720, got '$(clamp 660 600 60 60 1800)'"

# malformed dead → returned unchanged (robustness)
[[ "$(clamp "garbage" 600 60 60 1800)" == "garbage" ]] \
    && pass "dead-threshold clamp: malformed dead → returned unchanged" \
    || fail "dead-threshold clamp: expected 'garbage', got '$(clamp "garbage" 600 60 60 1800)'"

# --- 39: TOCTOU-race guard — same-tick last_paste_file swap ---------------
#
# Reproduces the 2026-06-22..07-01 silent-wedge respawn pattern
# (five recurrences with `elapsed_unstick=0s`, age ≈ compose_emit
# cadence ~660s). The pattern arose from an inconsistent snapshot:
# `_orchestrator_liveness_decide` read `last_paste_file` once to
# compute `age`, then called `_orchestrator_pasted_without_response`
# which re-read the SAME file. Between those two reads, `compose_emit`'s
# async subshell (running in the same scheduler tick) could
# `_orchestrator_record_paste` a NEW epoch into the file. Result:
#   - decide()'s `last_paste_ts` = OLD → `age` HUGE (looks stale).
#   - pasted_without_response()'s snapshot = NEW → every signal
#     that fired for the OLD paste's hooks compares stale.
#   - All signals fail → wedge branch → age ≥ dead_threshold →
#     respawn, WITHOUT ever entering the `waiting` state
#     (hence `elapsed_unstick=0s` and no log breadcrumb).
#
# The regression check: simulate the race by writing OLD ts to the
# file, then within the same test invocation write NEW ts before
# calling `_orchestrator_pasted_without_response` with the OLD
# override. Even though the file now holds NEW, the caller-pinned
# snapshot must keep the pasted_without_response verdict consistent
# with `age`. A fresh Signal 1 (heartbeat 1 s after the OLD paste
# but many seconds before the NEW ts) must read HEALTHY relative to
# OLD (as the caller intended), not stale relative to NEW.

reset_world
# OLD paste 500s ago; NEW paste "just now" — the racy file swap.
OLD_TS=$(( now - 500 ))
NEW_TS=$now
write_paste_ts "$LP" "$OLD_TS"
# Heartbeat fired for the OLD paste's turn — 1s after OLD_TS. This
# is > OLD_TS (healthy under the caller's OLD snapshot) but
# < NEW_TS by hundreds of seconds (stale under a re-read snapshot).
: > "$HB"; touch -d "$(( 500 - 1 )) seconds ago" "$HB"
printf '%s\n' "$VALID_SID" > "$PIN"
# Race: after the caller has parsed OLD_TS but before the callee
# reads the file, compose_emit's async subshell stamps NEW_TS.
write_paste_ts "$LP" "$NEW_TS"
# Note the rc semantics: rc=0 means "yes, pasted-without-response"
# (WEDGE), rc=1 means "orchestrator responded" (HEALTHY). We want
# HEALTHY with the override — the shell's `if func` runs `then`
# on rc=0, so healthy lands in `else`.
if HOME="$FAKE_HOME" \
   _orchestrator_pasted_without_response "$HB" "$PR" "$LP" "$PIN" "$FAKE_NEXUS_ROOT" "$FAKE_HOME" "$OLD_TS"; then
    fail "TOCTOU race guard: rc=0 (regressed to re-reading the file → silent-wedge respawn returns)"
else
    pass "TOCTOU race guard: caller-pinned last_paste_ts snapshot keeps signal-past-paste verdict healthy (rc=1)"
fi

# Confirm the negative — with NO override, the same fixture (file
# now holds NEW_TS, heartbeat < NEW_TS) reads as pasted-without-
# response. Proves the override path is what's protecting us, not
# some other change.
if HOME="$FAKE_HOME" \
   _orchestrator_pasted_without_response "$HB" "$PR" "$LP" "$PIN" "$FAKE_NEXUS_ROOT"; then
    pass "TOCTOU race guard negative: without override, re-read of NEW_TS reports stale signals (rc=0)"
else
    fail "TOCTOU race guard negative: no override should re-read NEW_TS from file and report stale (rc=0), got rc=1"
fi

# --- summary -------------------------------------------------------------

echo
echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
