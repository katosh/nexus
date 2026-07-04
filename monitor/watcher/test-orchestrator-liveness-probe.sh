#!/usr/bin/env bash
# Unit tests for the orchestrator-liveness probe helpers in _lib.sh:
#   _orchestrator_pin_age                 (utility, unchanged)
#   _orchestrator_should_fresh_spawn      (REWRITTEN for issue #157)
#   _orchestrator_unresponsive            (new for issue #157)
#   _orchestrator_record_paste            (new for issue #157)
#   _orchestrator_refresh_pin             (issue #150, unchanged)
#   _orchestrator_poll_refresh_pin        (issue #150 follow-up, unchanged)
#
# Issue #157 replaced the jsonl-mtime-only liveness signal with a
# paste-driven rule: idle orchestrator is alive; only an orchestrator
# that has not reacted to a paste delivered more than the
# unresponsive-threshold ago counts as wedged.
#
# Strategy: forge last-paste files, pin files, and per-session jsonl
# files with controlled mtimes; verify the decision helper fires only
# in the unresponsive case, suppresses on every other axis (no paste
# yet, paste within grace window, orch jsonl mtime > paste ts), and
# that the cooldown still throttles repeats.
#
# Run: bash monitor/watcher/test-orchestrator-liveness-probe.sh

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_lib.sh
source "$_script_dir/_lib.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PIN="$WORK/orchestrator-session-id"
CD="$WORK/orchestrator-fresh-spawn.last"
LP="$WORK/orchestrator-last-paste.ts"

# Per-test ($FAKE_HOME, $FAKE_NEXUS_ROOT, jsonl) is set up below
# inside each test that exercises the jsonl-mtime branch. Tests
# that don't need the jsonl resolve to a sid-less pin so the
# helper's "no sid → unresponsive" fallback fires.
FAKE_HOME="$WORK/home-default"
FAKE_NEXUS_ROOT="$WORK/nexus-default"
mkdir -p "$FAKE_HOME/.claude/projects" "$FAKE_NEXUS_ROOT"

# Helper: write `<epoch>` to a file with arbitrary contents-vs-mtime
# decoupling. The paste timestamp is read from the file's TEXT, not
# its mtime — the file just needs to contain the epoch on line 1.
write_paste_ts() {
    local file="$1" ts="$2"
    printf '%d\n' "$ts" > "$file"
}

# Helper: stamp a file's mtime to N seconds in the past. Contents
# may be set by the caller before calling this (so callers can write
# real data and then back-date its mtime).
stamp_n_seconds_ago() {
    local file="$1" seconds="$2"
    [[ -e "$file" ]] || : > "$file"
    touch -d "$seconds seconds ago" "$file"
}

# Helper: plant a fake jsonl with a controlled mtime under
# $FAKE_HOME/.claude/projects/<slug>/<sid>.jsonl. Returns the jsonl
# path on stdout for convenience.
plant_jsonl() {
    local sid="$1" age_s="$2"
    local slug proj_dir jsonl
    slug=$(printf '%s' "$FAKE_NEXUS_ROOT" | sed 's|[^a-zA-Z0-9]|-|g')
    proj_dir="$FAKE_HOME/.claude/projects/$slug"
    mkdir -p "$proj_dir"
    jsonl="$proj_dir/$sid.jsonl"
    printf '{"type":"assistant"}\n' > "$jsonl"
    touch -d "$age_s seconds ago" "$jsonl"
    printf '%s' "$jsonl"
}

VALID_SID="11111111-2222-3333-4444-555555555555"
now=$(date +%s)

# --- 1: no paste file yet → no spawn (first-watcher-cycle grace) ---------

rm -f "$LP" "$CD" "$PIN"
reason=$(HOME="$FAKE_HOME" \
         _orchestrator_should_fresh_spawn "$PIN" "$CD" "$LP" 120 1800 "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ -z "$reason" ]]; then
    pass "no paste-ts file → no spawn (first-cycle grace)"
else
    fail "first-cycle: rc=$rc reason='$reason'"
fi

# --- 2: paste within grace window → no spawn -----------------------------

write_paste_ts "$LP" "$(( now - 30 ))"
rm -f "$CD"
reason=$(HOME="$FAKE_HOME" \
         _orchestrator_should_fresh_spawn "$PIN" "$CD" "$LP" 120 1800 "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ -z "$reason" ]]; then
    pass "paste 30s ago (< 120s threshold) → no spawn"
else
    fail "grace window: rc=$rc reason='$reason'"
fi

# --- 3: paste past threshold, no jsonl evidence → spawn ------------------

write_paste_ts "$LP" "$(( now - 200 ))"
rm -f "$CD" "$PIN"
reason=$(HOME="$FAKE_HOME" \
         _orchestrator_should_fresh_spawn "$PIN" "$CD" "$LP" 120 1800 "$FAKE_NEXUS_ROOT")
rc=$?
# `now` was captured well before the spawn check; allow ±5s drift.
if (( rc == 0 )) && [[ "$reason" == *"unresponsive_age=2"*"s"* ]]; then
    pass "paste 200s ago + no pin/jsonl → spawn, reason cites unresponsive_age"
else
    fail "should spawn (no evidence): rc=$rc reason='$reason'"
fi

# --- 4: paste past threshold, but jsonl mtime AFTER paste → no spawn -----

write_paste_ts "$LP" "$(( now - 200 ))"
printf '%s\n' "$VALID_SID" > "$PIN"
plant_jsonl "$VALID_SID" 60 >/dev/null  # jsonl 60s ago > paste 200s ago
rm -f "$CD"
reason=$(HOME="$FAKE_HOME" \
         _orchestrator_should_fresh_spawn "$PIN" "$CD" "$LP" 120 1800 "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ -z "$reason" ]]; then
    pass "paste 200s ago BUT jsonl 60s ago (post-paste activity) → no spawn"
else
    fail "orch reacted post-paste should suppress: rc=$rc reason='$reason'"
fi

# --- 5: paste past threshold, jsonl mtime BEFORE paste → spawn -----------

write_paste_ts "$LP" "$(( now - 200 ))"
printf '%s\n' "$VALID_SID" > "$PIN"
plant_jsonl "$VALID_SID" 600 >/dev/null  # jsonl 600s ago < paste 200s ago
rm -f "$CD"
reason=$(HOME="$FAKE_HOME" \
         _orchestrator_should_fresh_spawn "$PIN" "$CD" "$LP" 120 1800 "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 0 )) && [[ "$reason" == *"unresponsive_age=2"*"s"* ]]; then
    pass "paste 200s ago, jsonl 600s ago (orch didn't react) → spawn"
else
    fail "unresponsive should spawn: rc=$rc reason='$reason'"
fi

# --- 6: cooldown still active → no spawn even when unresponsive ----------

write_paste_ts "$LP" "$(( now - 200 ))"
rm -f "$PIN"
stamp_n_seconds_ago "$CD" 60   # 60s < 1800s cooldown
reason=$(HOME="$FAKE_HOME" \
         _orchestrator_should_fresh_spawn "$PIN" "$CD" "$LP" 120 1800 "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ -z "$reason" ]]; then
    pass "unresponsive but cooldown active → no spawn"
else
    fail "cooldown should suppress: rc=$rc reason='$reason'"
fi

# --- 7: cooldown expired → spawn ----------------------------------------

write_paste_ts "$LP" "$(( now - 200 ))"
rm -f "$PIN"
stamp_n_seconds_ago "$CD" 2000  # 2000s > 1800s cooldown
reason=$(HOME="$FAKE_HOME" \
         _orchestrator_should_fresh_spawn "$PIN" "$CD" "$LP" 120 1800 "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 0 )); then
    pass "unresponsive + cooldown expired → spawn"
else
    fail "cooldown-expired should spawn: rc=$rc reason='$reason'"
fi

# --- 8: pin sid points to absent jsonl → spawn ---------------------------
#
# An orchestrator whose pinned sid resolves to a missing jsonl can't
# have demonstrably reacted (no jsonl to write to). Treat as
# unresponsive — let the spawn-fresh path fire and let the
# orchestrator's session-pin hook re-write a valid pin on the next
# turn.

write_paste_ts "$LP" "$(( now - 200 ))"
SID_NO_JSONL="22222222-3333-4444-5555-666666666666"
printf '%s\n' "$SID_NO_JSONL" > "$PIN"
# DELIBERATELY NOT planting a jsonl for SID_NO_JSONL.
rm -f "$CD"
reason=$(HOME="$FAKE_HOME" \
         _orchestrator_should_fresh_spawn "$PIN" "$CD" "$LP" 120 1800 "$FAKE_NEXUS_ROOT")
rc=$?
# Allow ±5s of timing drift on the reported age.
if (( rc == 0 )) && [[ "$reason" == *"unresponsive_age=2"*"s"* ]]; then
    pass "pin sid with absent jsonl → spawn (no positive evidence orch reacted)"
else
    fail "absent jsonl should fall through to spawn: rc=$rc reason='$reason'"
fi

# --- 9: malformed pin sid → spawn (UUID guard) ---------------------------
#
# Torn pin write or hook corruption — non-UUID payload. The helper
# must treat it as "no resolvable jsonl" and let the spawn fire.

write_paste_ts "$LP" "$(( now - 200 ))"
printf 'not-a-uuid\n' > "$PIN"
rm -f "$CD"
reason=$(HOME="$FAKE_HOME" \
         _orchestrator_should_fresh_spawn "$PIN" "$CD" "$LP" 120 1800 "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 0 )); then
    pass "malformed pin sid → spawn (UUID guard falls through)"
else
    fail "bad sid should not suppress: rc=$rc reason='$reason'"
fi

# --- 10: _orchestrator_record_paste atomic write ------------------------

rm -f "$LP"
_orchestrator_record_paste "$LP"
if [[ -f "$LP" ]]; then
    written=$(cat "$LP")
    now_ts=$(date +%s)
    delta=$(( now_ts - written ))
    if [[ "$written" =~ ^[0-9]+$ ]] && (( delta >= 0 )) && (( delta <= 3 )); then
        pass "_orchestrator_record_paste writes a fresh epoch (delta=${delta}s)"
    else
        fail "record_paste wrote invalid/old epoch: written='$written' delta=${delta}s"
    fi
else
    fail "record_paste did not create file"
fi

# Idempotent: calling again bumps the ts forward (or stays at now).
sleep 1
_orchestrator_record_paste "$LP"
after=$(cat "$LP")
if (( after >= written )); then
    pass "_orchestrator_record_paste bumps timestamp on repeat call ($written → $after)"
else
    fail "record_paste went backward: $written → $after"
fi

# --- 11: empty / unparseable paste-ts file → no spawn (no signal) -------
#
# Defensive: a torn write that left an empty file shouldn't seed a
# bogus "now=epoch 0" unresponsive_age in the millions of seconds.

: > "$LP"
rm -f "$CD"
reason=$(HOME="$FAKE_HOME" \
         _orchestrator_should_fresh_spawn "$PIN" "$CD" "$LP" 120 1800 "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ -z "$reason" ]]; then
    pass "empty paste-ts file → no spawn (defensive)"
else
    fail "empty paste-ts should not trigger spawn: rc=$rc reason='$reason'"
fi

printf 'not-a-number\n' > "$LP"
reason=$(HOME="$FAKE_HOME" \
         _orchestrator_should_fresh_spawn "$PIN" "$CD" "$LP" 120 1800 "$FAKE_NEXUS_ROOT")
rc=$?
if (( rc == 1 )) && [[ -z "$reason" ]]; then
    pass "garbage paste-ts file → no spawn (defensive)"
else
    fail "garbage paste-ts should not trigger spawn: rc=$rc reason='$reason'"
fi

# --- 12: _orchestrator_pin_age math sanity ------------------------------
# (utility unchanged from issue #150; sanity-check it still works)

stamp_n_seconds_ago "$PIN" 100
age=$(_orchestrator_pin_age "$PIN" 0)
if (( age >= 97 && age <= 103 )); then
    pass "_orchestrator_pin_age within ±3s (got $age, expected ~100)"
else
    fail "_orchestrator_pin_age drift: got $age, expected ~100"
fi

# --- 13: _orchestrator_refresh_pin still no-op on missing / empty file --
# (utility unchanged from issue #150; quick regression guard)

rm -f "$PIN"
_orchestrator_refresh_pin "$PIN"
if [[ ! -e "$PIN" ]]; then
    pass "refresh_pin: missing file → no-op"
else
    fail "refresh_pin wrongly created pin file"
fi

: > "$PIN"
touch -d "1900 seconds ago" "$PIN"
before_mtime=$(date +%s -r "$PIN")
_orchestrator_refresh_pin "$PIN"
after_mtime=$(date +%s -r "$PIN")
if (( before_mtime == after_mtime )); then
    pass "refresh_pin: empty file → no-op"
else
    fail "refresh_pin wrongly touched empty file"
fi

# --- 14: cycle-of-pastes scenario reproduces issue #157 fix --------------
#
# Pre-#157, an idle but healthy orchestrator (no recent jsonl writes,
# no recent pastes from the watcher either) saw the probe fire every
# cooldown — the jsonl-mtime-only signal mistook quiet for dead.
#
# With the new paste-driven rule: 5 consecutive poll cycles where no
# paste happens (and no record_paste call) → probe never fires,
# regardless of how stale the pin/jsonl looks.

rm -f "$LP" "$CD" "$PIN"
fire_count=0
for cycle in 1 2 3 4 5; do
    if reason=$(HOME="$FAKE_HOME" \
                _orchestrator_should_fresh_spawn \
                    "$PIN" "$CD" "$LP" 120 1800 "$FAKE_NEXUS_ROOT"); then
        fire_count=$(( fire_count + 1 ))
    fi
done
if (( fire_count == 0 )); then
    pass "5 cycles, no paste ever → probe never fires (issue #157 quiet-workspace fix)"
else
    fail "probe fired ${fire_count}/5 cycles on a quiet workspace — regression"
fi

# --- 15: paste-then-react scenario keeps probe quiet ---------------------
#
# Realistic healthy steady state: watcher pastes, orch's jsonl ticks
# in response, watcher pastes again N seconds later. Probe must stay
# quiet across many such cycles.

rm -f "$CD"
printf '%s\n' "$VALID_SID" > "$PIN"
fire_count=0
for cycle in 1 2 3 4 5; do
    # Simulate "paste delivered" at this cycle's now.
    _orchestrator_record_paste "$LP"
    # Simulate orch reacting ~1 s later by touching the jsonl.
    plant_jsonl "$VALID_SID" 0 >/dev/null
    # Probe immediately — paste is < grace window AND jsonl just
    # ticked.
    if reason=$(HOME="$FAKE_HOME" \
                _orchestrator_should_fresh_spawn \
                    "$PIN" "$CD" "$LP" 120 1800 "$FAKE_NEXUS_ROOT"); then
        fire_count=$(( fire_count + 1 ))
    fi
done
if (( fire_count == 0 )); then
    pass "5 paste-then-react cycles → probe never fires (healthy steady state)"
else
    fail "probe fired ${fire_count}/5 cycles on a healthy paste-react loop"
fi

# --- summary -------------------------------------------------------------

echo
echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
