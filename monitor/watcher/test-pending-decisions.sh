#!/usr/bin/env bash
# Tests for the decision-event channel groundwork (issue #129):
#
#   1. monitor/hooks/decision-emit.sh, given a Notification payload
#      on stdin, writes a well-formed per-decision JSON event to
#      $NEXUS_ROOT/monitor/.state/decisions/<window>.<fp>.json.
#   2. Re-firing the same prompt yields the same fingerprint
#      (file gets overwritten, not duplicated).
#   3. monitor/hooks/decision-mark-unresolved.sh marks lingering
#      files with unresolved=true (Stop-hook surface).
#   4. render_pending_decisions in monitor/watcher/_idle_probe.sh
#      emits the operator's expected line shape, cites the file
#      path, dedupes against the cooldown TSV, and re-emits after
#      DECISION_REEMIT_COOLDOWN_SECONDS elapses.
#   5. File-removal ack drops the entry on the next cycle.
#   6. *.handled.json tombstones are honoured (silently skipped).
#   7. decision-emit.sh honours the tombstone on the write path:
#      a sibling `<window>.<fp>.handled.json` makes a same-fingerprint
#      re-fire a silent no-op, while a different fingerprint still
#      writes its own `<fp>.json`.
#
# Run: bash monitor/watcher/test-pending-decisions.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_monitor_dir=$(cd "$_test_dir/.." && pwd)
EMIT_SCRIPT="$_monitor_dir/hooks/decision-emit.sh"
MARK_SCRIPT="$_monitor_dir/hooks/decision-mark-unresolved.sh"

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
        printf '  FAIL: %s — missing %q\n  in: <<%s>>\n' "$label" "$needle" "$hay" >&2
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
assert_file_exists() {
    local label="$1" path="$2"
    if [[ -f "$path" ]]; then
        printf '  PASS: %s (%s)\n' "$label" "$path"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — file missing: %s\n' "$label" "$path" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_no_file() {
    local label="$1" path="$2"
    if [[ -f "$path" ]]; then
        printf '  FAIL: %s — file unexpectedly present: %s\n' "$label" "$path" >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    fi
}

command -v jq >/dev/null 2>&1 || {
    echo "test-pending-decisions: jq missing — decision handler requires it" >&2
    exit 2
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export NEXUS_ROOT="$WORK"
export NEXUS_WORKER_WINDOW="worker-A"
mkdir -p "$NEXUS_ROOT/monitor/.state"
mkdir -p "$NEXUS_ROOT/monitor"
# Copy handler scripts into the fake nexus root so their absolute
# self-references resolve.
mkdir -p "$NEXUS_ROOT/monitor/hooks"
cp "$EMIT_SCRIPT" "$NEXUS_ROOT/monitor/hooks/decision-emit.sh"
cp "$MARK_SCRIPT" "$NEXUS_ROOT/monitor/hooks/decision-mark-unresolved.sh"
chmod +x "$NEXUS_ROOT/monitor/hooks/"*.sh

DECISIONS_DIR="$NEXUS_ROOT/monitor/.state/decisions"

# ---- Test 1: emit handler writes per-decision JSON -----

echo '=== decision-emit: writes per-decision JSON event ==='
payload='{"hook_event_name":"Notification","notification":{"type":"permission_prompt","message":"Allow Bash to run git push --force?"},"session_id":"sess-abc"}'
printf '%s' "$payload" | "$NEXUS_ROOT/monitor/hooks/decision-emit.sh"
shopt -s nullglob
files=( "$DECISIONS_DIR/worker-A".*.json )
shopt -u nullglob
if (( ${#files[@]} == 1 )); then
    printf '  PASS: exactly one decision file written (%s)\n' "$(basename "${files[0]}")"; PASS=$(( PASS + 1 ))
    f="${files[0]}"
    body=$(<"$f")
    assert_contains "carries kind=permission_prompt"  "$body" '"kind":"permission_prompt"'
    assert_contains "carries window=worker-A"          "$body" '"window":"worker-A"'
    assert_contains "carries session_id=sess-abc"      "$body" '"session_id":"sess-abc"'
    assert_contains "carries prompt_excerpt"           "$body" 'Allow Bash to run git push --force'
    assert_contains "carries 12-hex fingerprint"       "$body" '"fingerprint":"'
    # Verify ts is ISO 8601 UTC (Z suffix).
    ts=$(jq -r '.ts' "$f")
    [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
        && { printf '  PASS: ts is ISO 8601 UTC (got %s)\n' "$ts"; PASS=$(( PASS + 1 )); } \
        || { printf '  FAIL: ts not ISO 8601 UTC (got %s)\n' "$ts" >&2; FAIL=$(( FAIL + 1 )); }
    # Filename matches <window>.<12hex>.json convention.
    bn=$(basename "$f" .json)
    [[ "$bn" =~ ^worker-A\.[0-9a-f]{12}$ ]] \
        && { printf '  PASS: filename matches <window>.<12hex>.json (%s)\n' "$bn"; PASS=$(( PASS + 1 )); } \
        || { printf '  FAIL: filename malformed (%s)\n' "$bn" >&2; FAIL=$(( FAIL + 1 )); }
else
    printf '  FAIL: expected exactly one decision file, got %d\n' "${#files[@]}" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 1b: empirically-observed payload shape (top-level fields) ----

echo '=== decision-emit: top-level notification_type + message (PR #132 shape) ==='
# Real payload shape Claude Code emits (captured in PR #132):
#   {"hook_event_name":"Notification","notification_type":"idle_prompt",
#    "message":"Claude is waiting for your input","session_id":"..."}
# The handler MUST read kind from .notification_type (not .notification.type)
# and prompt_excerpt from .message (not .notification.message), or the
# decision file silently records kind:"Notification" / prompt_excerpt:""
# regardless of the actual notification type — the bug PR #132 surfaced.
export NEXUS_WORKER_WINDOW="worker-B"
payload_topfield='{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input","session_id":"sess-xyz"}'
printf '%s' "$payload_topfield" | "$NEXUS_ROOT/monitor/hooks/decision-emit.sh"
shopt -s nullglob
files_b=( "$DECISIONS_DIR/worker-B".*.json )
shopt -u nullglob
if (( ${#files_b[@]} == 1 )); then
    printf '  PASS: top-level shape — exactly one decision file written (%s)\n' "$(basename "${files_b[0]}")"; PASS=$(( PASS + 1 ))
    body_b=$(<"${files_b[0]}")
    assert_contains "top-level shape → kind=idle_prompt"        "$body_b" '"kind":"idle_prompt"'
    assert_contains "top-level shape → message in prompt_excerpt" "$body_b" 'Claude is waiting for your input'
    assert_contains "top-level shape → session_id=sess-xyz"      "$body_b" '"session_id":"sess-xyz"'
    assert_not_contains "kind is NOT raw hook_event_name"       "$body_b" '"kind":"Notification"'
else
    printf '  FAIL: top-level shape — expected exactly one decision file, got %d\n' "${#files_b[@]}" >&2
    FAIL=$(( FAIL + 1 ))
fi
export NEXUS_WORKER_WINDOW="worker-A"

# ---- Test 2: re-firing same prompt keeps the same file (fp stable) -----

echo '=== decision-emit: same payload → same fingerprint → file overwritten ==='
shopt -s nullglob
files_before=( "$DECISIONS_DIR/worker-A".*.json )
shopt -u nullglob
fp_before=$(basename "${files_before[0]}" .json | awk -F. '{print $NF}')
printf '%s' "$payload" | "$NEXUS_ROOT/monitor/hooks/decision-emit.sh"
shopt -s nullglob
files_after=( "$DECISIONS_DIR/worker-A".*.json )
shopt -u nullglob
assert_eq "still exactly one file after re-emit" "${#files_after[@]}" "1"
fp_after=$(basename "${files_after[0]}" .json | awk -F. '{print $NF}')
assert_eq "fingerprint stable across re-fires" "$fp_after" "$fp_before"

# ---- Test 3: different prompt → different fingerprint → second file ----

echo '=== decision-emit: different message → distinct fingerprint ==='
payload2='{"hook_event_name":"Notification","notification":{"type":"permission_prompt","message":"Allow Write to /etc/passwd?"},"session_id":"sess-abc"}'
printf '%s' "$payload2" | "$NEXUS_ROOT/monitor/hooks/decision-emit.sh"
shopt -s nullglob
files_two=( "$DECISIONS_DIR/worker-A".*.json )
shopt -u nullglob
assert_eq "two distinct decision files now present" "${#files_two[@]}" "2"

# ---- Test 4: tool_context embeds the pending-tool snapshot -------------

echo '=== decision-emit: embeds pending-tool snapshot into tool_context ==='
rm -f "$DECISIONS_DIR/"*.json
mkdir -p "$NEXUS_ROOT/monitor/.state/pending-tool"
printf '%s\n' '{"tool":"Bash","input_summary":"git push --force origin main","ts":1700000000}' \
    > "$NEXUS_ROOT/monitor/.state/pending-tool/$NEXUS_WORKER_WINDOW.json"
printf '%s' "$payload" | "$NEXUS_ROOT/monitor/hooks/decision-emit.sh"
shopt -s nullglob
files_tc=( "$DECISIONS_DIR/worker-A".*.json )
shopt -u nullglob
if (( ${#files_tc[@]} == 1 )); then
    body=$(<"${files_tc[0]}")
    assert_contains "tool_context carries tool name"          "$body" 'Bash'
    assert_contains "tool_context carries input summary"       "$body" 'git push --force'
else
    printf '  FAIL: tool_context test — expected 1 decision file, got %d\n' "${#files_tc[@]}" >&2
    FAIL=$(( FAIL + 1 ))
fi
rm -f "$NEXUS_ROOT/monitor/.state/pending-tool/$NEXUS_WORKER_WINDOW.json"

# ---- Test 5: Stop hook marks lingering decisions unresolved=true --------

echo '=== decision-mark-unresolved: stamps unresolved=true on lingering files ==='
"$NEXUS_ROOT/monitor/hooks/decision-mark-unresolved.sh"
body=$(<"${files_tc[0]}")
assert_contains "lingering file marked unresolved=true" "$body" '"unresolved":true'

# Idempotent: running again shouldn't double-stamp.
"$NEXUS_ROOT/monitor/hooks/decision-mark-unresolved.sh"
body2=$(<"${files_tc[0]}")
unresolved_count=$(jq -r 'paths | select(.[-1] == "unresolved") | length' "${files_tc[0]}" | wc -l)
assert_eq "unresolved key present exactly once after re-mark" "$unresolved_count" "1"

# Tombstone sibling should NOT be touched.
tombstone="$DECISIONS_DIR/worker-A.deadbeefcafe.handled.json"
printf '{"window":"worker-A","fingerprint":"deadbeefcafe","handled":true}\n' > "$tombstone"
"$NEXUS_ROOT/monitor/hooks/decision-mark-unresolved.sh"
body3=$(<"$tombstone")
assert_not_contains "tombstone NOT marked unresolved" "$body3" '"unresolved":true'

# ---- Test 6: render_pending_decisions emits the operator line shape ----

echo '=== render_pending_decisions: emits operator-spec line shape ==='
rm -f "$DECISIONS_DIR/"*.json
# Seed two decisions: one with tool_context, one without.
cat > "$DECISIONS_DIR/worker-A.aaaa11112222.json" <<'EOF'
{
  "ts": "2026-05-18T20:55:00Z",
  "window": "worker-A",
  "session_id": "sess-1",
  "kind": "permission_prompt",
  "prompt_excerpt": "Allow Bash to run git push?",
  "tool_context": "{\"tool\":\"Bash\",\"input_summary\":\"git push origin main\"}",
  "fingerprint": "aaaa11112222"
}
EOF
cat > "$DECISIONS_DIR/worker-B.bbbb33334444.json" <<'EOF'
{
  "ts": "2026-05-18T20:56:00Z",
  "window": "worker-B",
  "session_id": "sess-2",
  "kind": "idle_prompt",
  "prompt_excerpt": "Awaiting your input",
  "tool_context": "",
  "fingerprint": "bbbb33334444"
}
EOF

# Source the renderer.
export STATE_DIR="$NEXUS_ROOT/monitor/.state"
# Reset cooldown state.
rm -f "$STATE_DIR/pending-decisions-emit-state.tsv"
# shellcheck disable=SC1091
. "$_test_dir/_idle_probe.sh" >/dev/null 2>&1
out=$(render_pending_decisions 2>/dev/null)
assert_contains "emits operator-spec line for worker-A"     "$out" 'window=worker-A fp=aaaa11112222 kind=permission_prompt'
assert_contains "cites file path for worker-A"               "$out" "file=$DECISIONS_DIR/worker-A.aaaa11112222.json"
assert_contains "emits operator-spec line for worker-B"     "$out" 'window=worker-B fp=bbbb33334444 kind=idle_prompt'
assert_contains "emits prompt-excerpt for worker-A"          "$out" 'prompt-excerpt=Allow Bash'
# unresolved=false by default (Stop hasn't fired).
assert_contains "unresolved=false on fresh decisions"        "$out" 'unresolved=false'

# ---- Test 7: cooldown — second cycle within cooldown emits nothing -----

echo '=== render_pending_decisions: cooldown dedupes within DECISION_REEMIT_COOLDOWN_SECONDS ==='
export DECISION_REEMIT_COOLDOWN_SECONDS=300
out2=$(render_pending_decisions 2>/dev/null)
assert_eq "second cycle within cooldown emits nothing" "$out2" ""

# ---- Test 8: cooldown — past cooldown, re-emits ------------------------

echo '=== render_pending_decisions: re-emits after cooldown elapses ==='
# Backdate the state file by 1000s so the cooldown is exceeded.
state_file="$STATE_DIR/pending-decisions-emit-state.tsv"
now=$(date +%s)
old=$(( now - 1000 ))
awk -F'\t' -v old="$old" 'BEGIN { OFS="\t" } { $3 = old; print }' "$state_file" > "$state_file.bak"
mv "$state_file.bak" "$state_file"
out3=$(render_pending_decisions 2>/dev/null)
assert_contains "re-emits worker-A after cooldown" "$out3" 'window=worker-A'
assert_contains "re-emits worker-B after cooldown" "$out3" 'window=worker-B'

# ---- Test 9: file removal (ack) → drops on next cycle -------------------

echo '=== render_pending_decisions: file removal acks the decision ==='
rm -f "$DECISIONS_DIR/worker-A.aaaa11112222.json"
# Reset cooldown so the worker-B reemit isn't gated.
awk -F'\t' -v old="$old" 'BEGIN { OFS="\t" } { $3 = old; print }' "$state_file" > "$state_file.bak"
mv "$state_file.bak" "$state_file"
out4=$(render_pending_decisions 2>/dev/null)
assert_not_contains "worker-A no longer surfaces" "$out4" 'worker-A'
assert_contains    "worker-B still surfaces"      "$out4" 'window=worker-B'

# ---- Test 10: handled.json tombstones are silently skipped --------------

echo '=== render_pending_decisions: *.handled.json tombstones are skipped ==='
rm -f "$DECISIONS_DIR/"*.json "$state_file"
printf '{"window":"worker-A","fingerprint":"cccccccc1234"}\n' > "$DECISIONS_DIR/worker-A.cccccccc1234.handled.json"
out5=$(render_pending_decisions 2>/dev/null)
assert_eq "tombstones produce no output" "$out5" ""

# ---- Test 11: empty decisions dir → empty output ------------------------

echo '=== render_pending_decisions: empty directory → no output ==='
rm -f "$DECISIONS_DIR/"*.json
out6=$(render_pending_decisions 2>/dev/null)
assert_eq "empty dir → empty stdout" "$out6" ""

# ---- Test 12: decision-emit honours tombstone on the write path ---------
#
# Regression for the operator's observation: a retained-idle worker
# repeatedly fires `idle_prompt`, the orchestrator tombstones the
# decision file, and the next hook fire re-writes `<fp>.json` over
# the tombstone — the watcher then re-emits. The tombstone is
# documented as ack-and-suppress; the hook must silently no-op when
# a sibling `<fp>.handled.json` exists.

echo '=== decision-emit: tombstone suppresses same-fingerprint re-fires ==='
rm -f "$DECISIONS_DIR/"*.json "$DECISIONS_DIR/"*.handled.json
export NEXUS_WORKER_WINDOW="worker-A"
emit_payload='{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input","session_id":"sess-tomb"}'

# First fire writes the .json.
printf '%s' "$emit_payload" | "$NEXUS_ROOT/monitor/hooks/decision-emit.sh"
shopt -s nullglob
seed_files=( "$DECISIONS_DIR/worker-A".*.json )
shopt -u nullglob
assert_eq "seed fire wrote exactly one .json" "${#seed_files[@]}" "1"
seed_fp=$(basename "${seed_files[0]}" .json | awk -F. '{print $NF}')

# Tombstone it (orchestrator's ack-and-suppress move).
mv "${seed_files[0]}" "$DECISIONS_DIR/worker-A.$seed_fp.handled.json"

# Re-fire the SAME payload. Capture stderr to assert no noise.
stderr_capture=$(mktemp)
trap 'rm -f "$stderr_capture"; rm -rf "$WORK"' EXIT
printf '%s' "$emit_payload" \
    | "$NEXUS_ROOT/monitor/hooks/decision-emit.sh" 2>"$stderr_capture"
rc=$?
assert_eq "re-fire over tombstone exits 0" "$rc" "0"

stderr_body=$(<"$stderr_capture")
assert_eq "re-fire over tombstone writes no stderr" "$stderr_body" ""

assert_no_file "no <fp>.json resurrected over tombstone" \
    "$DECISIONS_DIR/worker-A.$seed_fp.json"
assert_file_exists "tombstone still present" \
    "$DECISIONS_DIR/worker-A.$seed_fp.handled.json"

# Different payload (different fp) writes a fresh .json; the tombstone
# is unaffected.
echo '=== decision-emit: tombstone only gates the matching fingerprint ==='
other_payload='{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Allow Bash to run git push?","session_id":"sess-tomb"}'
printf '%s' "$other_payload" | "$NEXUS_ROOT/monitor/hooks/decision-emit.sh"
# Glob for ACTIVE .json files only (exclude *.handled.json siblings).
new_files=()
shopt -s nullglob
for f in "$DECISIONS_DIR/worker-A".*.json; do
    [[ "$f" == *.handled.json ]] && continue
    new_files+=( "$f" )
done
shopt -u nullglob
assert_eq "different fp wrote a fresh .json (active count)" "${#new_files[@]}" "1"
new_fp=$(basename "${new_files[0]}" .json | awk -F. '{print $NF}')
[[ "$new_fp" != "$seed_fp" ]] \
    && { printf '  PASS: distinct fingerprint (%s != %s)\n' "$new_fp" "$seed_fp"; PASS=$(( PASS + 1 )); } \
    || { printf '  FAIL: expected distinct fingerprints, both %s\n' "$new_fp" >&2; FAIL=$(( FAIL + 1 )); }
assert_file_exists "prior tombstone still present" \
    "$DECISIONS_DIR/worker-A.$seed_fp.handled.json"

# ---- Test 12: operator-engaged suppresses idle_prompt (#196, #201) ------
#
# The turn-end `idle_prompt` pings of a window the operator drives
# are not decisions to ack. While the window carries a VALID
# operator-engaged mark, the renderer withholds idle_prompt rows
# (file kept on disk, no cooldown state) and other kinds still
# surface. Since issue #201 the suppression spans the away phase too
# (a mark aged past the grace still withholds); only invalidation —
# a newer `engaged-done` finished-signal or spawn (the #205
# state-machine follow-up moved invalidation off the wrap-up event:
# interactive sessions stay engaged across their own hand-off) —
# lets the lingering file surface as brand-new. Nothing is
# permanently muted: invalidation or window close always reopens
# the path.

echo '=== render_pending_decisions: operator-engaged suppresses idle_prompt (issues #196/#201) ==='
rm -f "$DECISIONS_DIR/"*.json "$STATE_DIR/pending-decisions-emit-state.tsv"
_oe_now=$(date +%s)
printf 'worker-E\t%s\t%s\t0\tsubmit\t0\n' "$(( _oe_now - 60 ))" "$(( _oe_now - 5 ))" \
    > "$STATE_DIR/operator-engaged.tsv"
# Mark validity now requires a recent pane-content change (the
# your-org/your-nexus#205 follow-up self-expiry); stamp one so
# `_openg_marked` accepts the mark as VALID.
mkdir -p "$STATE_DIR/pane-change"
printf 'h\t%s\n' "$_oe_now" > "$STATE_DIR/pane-change/worker-E"
cat > "$DECISIONS_DIR/worker-E.eeee55556666.json" <<'EOF'
{"ts":"2026-06-10T22:00:00Z","window":"worker-E","session_id":"sess-e","kind":"idle_prompt","prompt_excerpt":"Awaiting your input","tool_context":"","fingerprint":"eeee55556666"}
EOF
cat > "$DECISIONS_DIR/worker-E.ffff77778888.json" <<'EOF'
{"ts":"2026-06-10T22:00:01Z","window":"worker-E","session_id":"sess-e","kind":"permission_prompt","prompt_excerpt":"Allow Bash to run rm?","tool_context":"","fingerprint":"ffff77778888"}
EOF
out=$(render_pending_decisions 2>/dev/null)
assert_not_contains "engaged window: idle_prompt withheld"      "$out" 'kind=idle_prompt'
assert_contains     "engaged window: permission_prompt surfaces" "$out" 'kind=permission_prompt'
assert_file_exists  "withheld decision file kept on disk" \
    "$DECISIONS_DIR/worker-E.eeee55556666.json"

# Walk-away (issue #201): the operator hasn't SUBMITTED for hours
# (`last` 2 h old) but the pane is STILL changing (the agent is
# working on the operator's behalf), so the mark stays valid and the
# idle_prompt remains withheld — the away phase's surface is the
# engaged-close-reminder, not a decision row. (Once the pane goes
# static past the change TTL the mark self-expires and the path
# reopens — exercised in test-idle-probe's part-A block.)
printf 'worker-E\t%s\t%s\t0\tsubmit\t0\n' "$(( _oe_now - 7200 ))" "$(( _oe_now - 7000 ))" \
    > "$STATE_DIR/operator-engaged.tsv"
printf 'h\t%s\n' "$_oe_now" > "$STATE_DIR/pane-change/worker-E"   # still changing → valid
out=$(render_pending_decisions 2>/dev/null)
assert_not_contains "away phase (still changing): idle_prompt withheld" "$out" 'kind=idle_prompt'

# A wrap-up NEWER than the mark's `since` does NOT invalidate (the
# #205 state-machine follow-up): the interactive session stays
# engaged across its own hand-off, so the idle_prompt stays withheld.
WRAP_TS=$(date -Is -d "@$(( _oe_now - 3600 ))")
printf '{"ts":"%s","agent":"monitor","event":"wrap-up","window":"worker-E","report":"worker-E_2026-06-11_000000_done.md"}\n' \
    "$WRAP_TS" >> "$STATE_DIR/action-log.jsonl"
out=$(render_pending_decisions 2>/dev/null)
assert_not_contains "newer wrap-up does NOT invalidate: idle_prompt stays withheld" "$out" 'kind=idle_prompt'

# Invalidation: an `engaged-done` finished-signal (ng engaged-done)
# NEWER than the mark's `since` kills it; the lingering idle_prompt
# surfaces as a brand-new row.
DONE_TS=$(date -Is -d "@$(( _oe_now - 1800 ))")
printf '{"ts":"%s","agent":"monitor","event":"engaged-done","window":"worker-E"}\n' \
    "$DONE_TS" >> "$STATE_DIR/action-log.jsonl"
out=$(render_pending_decisions 2>/dev/null)
assert_contains "after engaged-done invalidation: idle_prompt resurfaces" "$out" 'kind=idle_prompt'
rm -f "$STATE_DIR/operator-engaged.tsv"

# ---- summary -----------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
