#!/usr/bin/env bash
# test-interactive-sessions.sh — hermetic tests for interactive-sessions D1/D2/D4.
#
# Covers:
#   T1  _write_provenance_record writes valid JSON with expected fields
#   T2  _write_provenance_record sanitizes window name (special chars → _)
#   T3  Tombstone recipe writes .handled.json with required keys
#   T4  render_pending_decisions skips tombstoned decisions (smoke: file absent)
#   T5  ng interactive-sessions --dry-run renders markdown with table header
#   T6  ng interactive-sessions --dry-run reflects provenance record content
#   T7  ng interactive-sessions idempotency: second --dry-run same output as first
#   T8  Upsert awk logic: block absent → appended; block present → replaced

set -uo pipefail

PASS=0; FAIL=0
ok()  { printf 'PASS  %s\n' "$1"; (( PASS += 1 )); }
fail(){ printf 'FAIL  %s\n' "$1"; (( FAIL += 1 )); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NG="$SCRIPT_DIR/ng"
SPAWN_SH="$SCRIPT_DIR/spawn-worker.sh"

# ── temp fixture ──────────────────────────────────────────────────────────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

NEXUS_ROOT="$TMP/nexus"
WINDOWS_DIR="$NEXUS_ROOT/monitor/.state/windows"
DECISIONS_DIR="$NEXUS_ROOT/monitor/.state/decisions"
HEARTBEAT_DIR="$NEXUS_ROOT/monitor/.state/heartbeat"
mkdir -p "$WINDOWS_DIR" "$DECISIONS_DIR" "$HEARTBEAT_DIR"

export NEXUS_ROOT
# Point ng's state dir to temp (avoids touching real .state)
export NEXUS_STATE_DIR="$TMP/ng-state"
mkdir -p "$NEXUS_STATE_DIR"

# ── load _write_provenance_record from spawn-worker.sh ────────────────────────
# Extract the function definition (the first ^}$ at column 0 closes it).
eval "$(awk '/^_write_provenance_record\(\)/,/^}$/' "$SPAWN_SH")"

# ── T1: provenance record — valid JSON with expected fields ──────────────────
WIN=test-interactive
TOPIC="My test interactive session"
_write_provenance_record "$NEXUS_ROOT" "$WIN" "fake-session-uuid" \
    "interactive" "/path/to/workdir" "/tmp/prompt.txt" "$TOPIC"

PROV_FILE="$WINDOWS_DIR/${WIN}.json"
if [[ ! -f "$PROV_FILE" ]]; then
    fail "T1: provenance file not created at $PROV_FILE"
else
    if jq -e '.window == "test-interactive"
              and .session_id == "fake-session-uuid"
              and .kind == "interactive"
              and .spawned_by == "orchestrator"
              and .workdir == "/path/to/workdir"
              and (.topic | length > 0)
              and (.spawned_at | length > 0)
              and (.last_activity_ref | length > 0)' \
        "$PROV_FILE" >/dev/null 2>&1; then
        ok "T1: provenance record has all required fields"
    else
        fail "T1: provenance record missing required fields — $(cat "$PROV_FILE")"
    fi
fi

# ── T2: window name sanitization ─────────────────────────────────────────────
WIN2="my window/name:odd"
_write_provenance_record "$NEXUS_ROOT" "$WIN2" "" "task" "/wd" "/pf" ""
SAFE="my_window_name_odd"
if [[ -f "$WINDOWS_DIR/${SAFE}.json" ]]; then
    ok "T2: window name sanitized (special chars → _)"
else
    fail "T2: expected sanitized file $WINDOWS_DIR/${SAFE}.json not found (got: $(ls "$WINDOWS_DIR/"))"
fi

# ── T3: tombstone recipe writes .handled.json with required keys ─────────────
WIN3=test-tomb
FP="abc123def456"
DECISION_FILE="$DECISIONS_DIR/${WIN3}.${FP}.json"
TOMBSTONE_FILE="$DECISIONS_DIR/${WIN3}.${FP}.handled.json"

jq -n --arg w "$WIN3" --arg fp "$FP" --arg k "idle_prompt" \
    '{"window":$w,"fp":$fp,"kind":$k}' > "$DECISION_FILE"

# Apply tombstone (exact recipe from the skill).
jq -n \
    --arg window "$WIN3" \
    --arg fp     "$FP" \
    --arg reason "interactive-kept" \
    --arg ts     "2026-06-15T00:00:00+00:00" \
    '{"window": $window, "fp": $fp, "reason": $reason, "ts": $ts}' \
  > "$TOMBSTONE_FILE"

if [[ -f "$TOMBSTONE_FILE" ]]; then
    if jq -e '.window and .fp and .reason and .ts' "$TOMBSTONE_FILE" >/dev/null 2>&1; then
        ok "T3: tombstone .handled.json exists with required keys"
    else
        fail "T3: tombstone missing required keys — $(cat "$TOMBSTONE_FILE")"
    fi
else
    fail "T3: tombstone file not created"
fi

# ── T4: smoke — tombstone presence means .handled.json sibling exists ─────────
# render_pending_decisions skips any file matching *.handled.json; we just
# verify the sibling pattern holds (the watcher code itself is not loaded here).
ACTIVE_COUNT=$(find "$DECISIONS_DIR" -maxdepth 1 -name "*.json" \
    ! -name "*.handled.json" | wc -l)
HANDLED_COUNT=$(find "$DECISIONS_DIR" -maxdepth 1 -name "*.handled.json" | wc -l)
if (( HANDLED_COUNT == 1 )); then
    ok "T4: exactly one tombstone exists (pending=$ACTIVE_COUNT, handled=$HANDLED_COUNT)"
else
    fail "T4: unexpected tombstone count=$HANDLED_COUNT (active=$ACTIVE_COUNT)"
fi

# ── T5: ng interactive-sessions --dry-run renders markdown with table header ─
OUTPUT=$(NEXUS_ROOT="$TMP/nexus" NEXUS_STATE_DIR="$TMP/ng-state" \
    "$NG" interactive-sessions --dry-run 2>/dev/null)
if printf '%s' "$OUTPUT" | grep -q '<!-- interactive-sessions:start -->'; then
    ok "T5: output contains start marker"
else
    fail "T5: output missing start marker"
fi
if printf '%s' "$OUTPUT" | grep -q '| Window | Topic | Status |'; then
    ok "T5: output contains table header"
else
    fail "T5: output missing table header — got: $(printf '%s' "$OUTPUT" | head -5)"
fi
if printf '%s' "$OUTPUT" | grep -q '<!-- interactive-sessions:end -->'; then
    ok "T5: output contains end marker"
else
    fail "T5: output missing end marker"
fi

# ── T5d: table rows use real newlines, not literal \n ────────────────────────
# Guard: catches single-/double-quoted \n in cmd_interactive_sessions block
# assignments. The pattern matches header row immediately followed by a real
# newline and the |--- separator — impossible if \n is literal backslash-n.
OUTPUT_5D=$(NEXUS_ROOT="$TMP/nexus" NEXUS_STATE_DIR="$TMP/ng-state" \
    "$NG" interactive-sessions --dry-run 2>/dev/null)
if printf '%s' "$OUTPUT_5D" | grep -Pzo '(?m)^\| Window[^\n]*\n\|---' >/dev/null 2>&1; then
    ok "T5d: table header and separator are on consecutive real lines (not literal \\n)"
else
    fail "T5d: table header/separator not on consecutive lines — literal \\\\n bug"
fi

# ── T6: ng interactive-sessions --dry-run reflects provenance record ─────────
# T1 wrote a provenance record for "test-interactive" with kind=interactive.
OUTPUT6=$(NEXUS_ROOT="$TMP/nexus" NEXUS_STATE_DIR="$TMP/ng-state" \
    "$NG" interactive-sessions --dry-run 2>/dev/null)
if printf '%s' "$OUTPUT6" | grep -q 'test-interactive'; then
    ok "T6: output lists 'test-interactive' from provenance record"
else
    # The task kind (T2 write) is 'task' not 'interactive', so only T1 record
    # (test-interactive, kind=interactive) should appear.
    fail "T6: 'test-interactive' not found in output — got: $(printf '%s' "$OUTPUT6")"
fi

# ── T7: idempotency — second run same output as first ────────────────────────
OUT_A=$(NEXUS_ROOT="$TMP/nexus" NEXUS_STATE_DIR="$TMP/ng-state" \
    "$NG" interactive-sessions --dry-run 2>/dev/null)
OUT_B=$(NEXUS_ROOT="$TMP/nexus" NEXUS_STATE_DIR="$TMP/ng-state" \
    "$NG" interactive-sessions --dry-run 2>/dev/null)
if [[ "$OUT_A" == "$OUT_B" ]]; then
    ok "T7: --dry-run output is idempotent (two runs identical)"
else
    fail "T7: --dry-run output differs between runs"
fi

# ── T8: upsert awk logic — block absent → append; block present → replace ────
START_M='<!-- interactive-sessions:start -->'
END_M='<!-- interactive-sessions:end -->'
BLOCK_V1="${START_M}"$'\n''## v1'$'\n'"${END_M}"
BLOCK_V2="${START_M}"$'\n''## v2'$'\n'"${END_M}"

# Case A: block absent — append
BODY_BEFORE="## Intro\n\nSome text."
BODY_AFTER=$(printf '%s\n\n%s' "$BODY_BEFORE" "$BLOCK_V1")
# Verify appended body contains both intro and block.
if printf '%s' "$BODY_AFTER" | grep -q 'Some text.' \
   && printf '%s' "$BODY_AFTER" | grep -q "$START_M"; then
    ok "T8a: block absent case: appended"
else
    fail "T8a: block absent case: unexpected body"
fi

# Case B: block present — replace v1 with v2 via awk
NEW_BODY=$(printf '%s' "$BODY_AFTER" \
    | awk -v block="$BLOCK_V2" \
        'BEGIN { in_block=0 }
         /<!--[[:space:]]*interactive-sessions:start[[:space:]]*-->/ { in_block=1; print block; next }
         in_block && /<!--[[:space:]]*interactive-sessions:end[[:space:]]*-->/ { in_block=0; next }
         in_block { next }
         { print }')

if printf '%s' "$NEW_BODY" | grep -q 'Some text.' \
   && printf '%s' "$NEW_BODY" | grep -q '## v2' \
   && ! printf '%s' "$NEW_BODY" | grep -q '## v1'; then
    ok "T8b: block present case: replaced v1 with v2, non-block content preserved"
else
    fail "T8b: block present case — got: $(printf '%s' "$NEW_BODY")"
fi

# ── Double-upsert idempotency: replace v2 with itself ────────────────────────
BODY_V2_TWICE=$(printf '%s' "$NEW_BODY" \
    | awk -v block="$BLOCK_V2" \
        'BEGIN { in_block=0 }
         /<!--[[:space:]]*interactive-sessions:start[[:space:]]*-->/ { in_block=1; print block; next }
         in_block && /<!--[[:space:]]*interactive-sessions:end[[:space:]]*-->/ { in_block=0; next }
         in_block { next }
         { print }')

if [[ "$BODY_V2_TWICE" == "$NEW_BODY" ]]; then
    ok "T8c: double-upsert of same block is idempotent"
else
    fail "T8c: double-upsert produced different output"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
