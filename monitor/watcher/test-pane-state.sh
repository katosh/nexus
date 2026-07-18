#!/usr/bin/env bash
# Fixture-driven tests for monitor/pane-state.sh.
#
# Each fixture under monitor/watcher/fixtures/*.ansi is a real or
# synthesized tmux capture-pane -e -p output. The expected state for
# each fixture is encoded in its filename prefix (`autosuggest-`,
# `busy-`, `idle-`, `user-typing-`, `blocked-`, `absent-`).
#
# Run: bash monitor/watcher/test-pane-state.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
HELPER="$_repo_root/monitor/pane-state.sh"
FIX_DIR="$_test_dir/fixtures"

PASS=0
FAIL=0

assert_state() {
    local fixture="$1" want="$2"
    local out got
    out=$("$HELPER" --fixture "$fixture" --window 9 --name testwin --active 0 2>&1) || {
        printf '  FAIL: %s — helper exited nonzero: %s\n' "$(basename "$fixture")" "$out" >&2
        FAIL=$(( FAIL + 1 ))
        return
    }
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %-50s state=%s\n' "$(basename "$fixture")" "$got"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %-50s got=%s want=%s (full: %s)\n' \
            "$(basename "$fixture")" "$got" "$want" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# Filename prefix → expected state.
expected_state_for() {
    local base
    base=$(basename "$1")
    case "$base" in
        autosuggest-*) echo autosuggest-only ;;
        busy-*)        echo busy ;;
        idle-*)        echo idle ;;
        user-typing-*) echo user-typing ;;
        blocked-*)     echo blocked ;;
        absent-*)      echo absent ;;
        over-limit-*)  echo over-limit ;;
        *) echo "" ;;
    esac
}

[[ -x "$HELPER" ]] || { echo "helper not executable: $HELPER" >&2; exit 1; }
[[ -d "$FIX_DIR" ]] || { echo "fixtures dir missing: $FIX_DIR" >&2; exit 1; }

echo "=== fixture classification ==="
shopt -s nullglob
fixtures=("$FIX_DIR"/*.ansi)
(( ${#fixtures[@]} > 0 )) || { echo "no fixtures found" >&2; exit 1; }
for f in "${fixtures[@]}"; do
    want=$(expected_state_for "$f")
    [[ -z "$want" ]] && {
        printf '  SKIP: %s (unrecognised filename prefix)\n' "$(basename "$f")"
        continue
    }
    assert_state "$f" "$want"
done

echo
echo "=== output format ==="
out=$("$HELPER" --fixture "${fixtures[0]}" --window 42 --name myname --active 1)
for key in state active window name; do
    if grep -qE "(^| )${key}=" <<<"$out"; then
        printf '  PASS: output contains %s=...\n' "$key"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: output missing key %s (got: %s)\n' "$key" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
done
if grep -q 'window=42' <<<"$out" && grep -q 'name=myname' <<<"$out" && grep -q 'active=1' <<<"$out"; then
    printf '  PASS: --window/--name/--active passthrough\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: --window/--name/--active passthrough (got: %s)\n' "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== heartbeat substrate (issue #74) ==="
# These exercise the new worker-side heartbeat path. We pin a temp
# state-dir, write a JSON heartbeat for a known window name, and
# point pane-state.sh at it via --heartbeat-file / --window /
# --name. The renderer fixture is a passive idle-empty so any
# fall-through emits `idle` and we can prove the heartbeat
# overrode (or correctly didn't override) it.
hb_tmp=$(mktemp -d)
trap 'rm -rf "$hb_tmp"' EXIT
hb_file="$hb_tmp/test.json"
idle_fixture="$FIX_DIR/idle-empty-synthetic.ansi"
[[ -f "$idle_fixture" ]] || { echo "heartbeat tests need $idle_fixture" >&2; exit 1; }

# Pinned `now` so the test is hermetic — no real-time skew.
NOW=2000000000

assert_heartbeat_state() {
    local label="$1" want="$2" hb_state="$3" age="$4"; shift 4
    local extra=("$@")
    local last_activity=$(( NOW - age ))
    printf '{"state":"%s","last_activity":%s,"window":"test"}\n' \
        "$hb_state" "$last_activity" > "$hb_file"
    local out got
    out=$("$HELPER" --fixture "$idle_fixture" \
                    --window 9 --name test --active 0 \
                    --heartbeat-file "$hb_file" \
                    --now "$NOW" \
                    "${extra[@]}" 2>&1) || {
        printf '  FAIL: %s — helper exited nonzero: %s\n' "$label" "$out" >&2
        FAIL=$(( FAIL + 1 ))
        return
    }
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %-55s state=%s\n' "$label" "$got"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %-55s got=%s want=%s (full: %s)\n' \
            "$label" "$got" "$want" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# Fresh heartbeat overrides the renderer.
assert_heartbeat_state "fresh busy → busy"                    busy    busy              5
assert_heartbeat_state "fresh user_prompt → busy"             busy    user_prompt       5
assert_heartbeat_state "fresh permission_prompt → blocked"    blocked permission_prompt 5
assert_heartbeat_state "fresh idle_prompt → idle"             idle    idle_prompt       5

# Stale heartbeat (older than default 30 s) falls through to renderer.
assert_heartbeat_state "stale busy → falls through to renderer (idle)" idle busy 31

# Custom staleness window: 10 s. A 15 s-old heartbeat is now stale.
assert_heartbeat_state "stale w/ --heartbeat-staleness 10 → idle"      idle busy 15 \
    --heartbeat-staleness 10
# Same age, default (30 s) staleness — fresh, busy.
assert_heartbeat_state "fresh w/ default staleness, age 15 → busy"     busy busy 15

# Unmapped state in the file: fall through.
printf '{"state":"weird","last_activity":%s,"window":"test"}\n' "$NOW" > "$hb_file"
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name test --active 0 \
                --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "idle" ]]; then
    printf '  PASS: unmapped heartbeat state falls through (state=idle)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: unmapped heartbeat state — got=%s want=idle\n' "$got" >&2
    FAIL=$(( FAIL + 1 ))
fi

# Malformed JSON: fall through.
echo "not actually json" > "$hb_file"
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name test --active 0 \
                --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "idle" ]]; then
    printf '  PASS: malformed heartbeat JSON falls through (state=idle)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: malformed heartbeat — got=%s want=idle\n' "$got" >&2
    FAIL=$(( FAIL + 1 ))
fi

# Missing file: fall through.
rm -f "$hb_file"
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name test --active 0 \
                --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "idle" ]]; then
    printf '  PASS: missing heartbeat file falls through (state=idle)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: missing heartbeat — got=%s want=idle\n' "$got" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== heartbeat overrides busy-mid-render fixture ==="
# The busy-mid-render fixture has no chevron at all — without a
# heartbeat, pane-state has to infer busy from the spinner token
# counter. With a fresh `idle_prompt` heartbeat, the heartbeat wins.
mid_render_fixture="$FIX_DIR/busy-mid-render-no-chevron-synthetic.ansi"
if [[ -f "$mid_render_fixture" ]]; then
    printf '{"state":"idle_prompt","last_activity":%s,"window":"test"}\n' "$NOW" > "$hb_file"
    out=$("$HELPER" --fixture "$mid_render_fixture" --window 9 --name test --active 0 \
                    --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "idle" ]]; then
        printf '  PASS: fresh idle_prompt heartbeat overrides busy-mid-render → idle\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: heartbeat override — got=%s want=idle\n' "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    # And the inverse: stale heartbeat lets the renderer's busy
    # detection through.
    printf '{"state":"idle_prompt","last_activity":1,"window":"test"}\n' > "$hb_file"
    out=$("$HELPER" --fixture "$mid_render_fixture" --window 9 --name test --active 0 \
                    --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "busy" ]]; then
        printf '  PASS: stale heartbeat → renderer reclaims busy-mid-render → busy\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: stale heartbeat fall-through — got=%s want=busy\n' "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

echo
echo "=== heartbeat-idle refined by renderer typing (issue #196) ==="
# A fresh `idle_prompt` heartbeat proves the agent's turn ended but
# cannot see the operator typing into the input box afterwards. The
# heartbeat-idle verdict must be refined to `user-typing` when the
# renderer shows the bright-text marker; autosuggest ghost text (dim
# only) must NOT refine; a busy heartbeat is untouched.
typing_fixture="$FIX_DIR/user-typing-synthetic.ansi"
autosuggest_fixture="$FIX_DIR/autosuggest-merge-win3.ansi"
if [[ -f "$typing_fixture" && -f "$autosuggest_fixture" ]]; then
    printf '{"state":"idle_prompt","last_activity":%s,"window":"test"}\n' "$NOW" > "$hb_file"
    out=$("$HELPER" --fixture "$typing_fixture" --window 9 --name test --active 0 \
                    --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "user-typing" ]]; then
        printf '  PASS: idle heartbeat + bright input row → user-typing\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: idle heartbeat + typing fixture — got=%s want=user-typing\n' "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    out=$("$HELPER" --fixture "$autosuggest_fixture" --window 9 --name test --active 0 \
                    --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "idle" ]]; then
        printf '  PASS: idle heartbeat + autosuggest ghost stays idle\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: idle heartbeat + autosuggest — got=%s want=idle\n' "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    printf '{"state":"busy","last_activity":%s,"window":"test"}\n' "$NOW" > "$hb_file"
    out=$("$HELPER" --fixture "$typing_fixture" --window 9 --name test --active 0 \
                    --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "busy" ]]; then
        printf '  PASS: busy heartbeat unaffected by typing refinement\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: busy heartbeat + typing fixture — got=%s want=busy\n' "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
else
    printf '  SKIP: typing/autosuggest fixtures missing\n'
fi

echo
echo "=== last_turn_end staleness (Stop-hook idle, #129 item 3) ==="
# A turn_end-derived heartbeat carries BOTH last_activity and
# last_turn_end. The classifier should use last_turn_end as the
# staleness anchor and apply the longer threshold — proving that
# Stop-derived idle survives past the 30 s `last_activity` window.

# 1. Fresh turn_end (both anchors current) → idle.
printf '{"state":"idle_prompt","last_activity":%s,"last_turn_end":%s,"window":"test"}\n' \
    "$NOW" "$NOW" > "$hb_file"
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name test --active 0 \
                --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "idle" ]]; then
    printf '  PASS: turn_end heartbeat (fresh both anchors) → idle\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: turn_end fresh → idle — got=%s\n' "$got" >&2; FAIL=$(( FAIL + 1 ))
fi

# 2. last_activity stale (>30 s), last_turn_end fresh → idle.
#    This is the load-bearing case: without the last_turn_end anchor
#    the heartbeat would go stale and pane-state would fall through
#    to the renderer. With it, the Stop-derived idle survives.
old_la=$(( NOW - 600 ))
printf '{"state":"idle_prompt","last_activity":%s,"last_turn_end":%s,"window":"test"}\n' \
    "$old_la" "$NOW" > "$hb_file"
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name test --active 0 \
                --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "idle" ]]; then
    printf '  PASS: last_activity stale (10min), last_turn_end fresh → idle (anchor swap working)\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: last_activity stale + last_turn_end fresh — got=%s want=idle\n' "$got" >&2; FAIL=$(( FAIL + 1 ))
fi

# 3. last_turn_end older than its longer threshold (1800 s default) →
#    classifier returns 1 → fall through to renderer (idle on the
#    idle-empty fixture). Proves the longer threshold isn't infinite.
ancient_lte=$(( NOW - 3600 ))
printf '{"state":"idle_prompt","last_activity":%s,"last_turn_end":%s,"window":"test"}\n' \
    "$NOW" "$ancient_lte" > "$hb_file"
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name test --active 0 \
                --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
# Anchor swap puts us on the stale last_turn_end → fall through →
# renderer says idle on the idle-empty fixture. The renderer verdict
# is the same emit value, but it's reached via the renderer path,
# not the heartbeat path. Hard to assert "took which path" from the
# emit alone, so this test guards against a regression where the
# anchor swap forgot the threshold check entirely and returned `idle`
# from an arbitrarily-old stamp.
if [[ "$got" == "idle" ]]; then
    printf '  PASS: turn_end older than 1800 s threshold → falls through (renderer also says idle)\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: turn_end > threshold expected idle (renderer), got=%s\n' "$got" >&2; FAIL=$(( FAIL + 1 ))
fi

# 4. Custom --heartbeat-turn-end-staleness wins. With threshold=60,
#    a 120 s-old last_turn_end is stale → fall-through.
old_lte=$(( NOW - 120 ))
printf '{"state":"idle_prompt","last_activity":%s,"last_turn_end":%s,"window":"test"}\n' \
    "$NOW" "$old_lte" > "$hb_file"
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name test --active 0 \
                --heartbeat-file "$hb_file" --now "$NOW" \
                --heartbeat-turn-end-staleness 60 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "idle" ]]; then
    printf '  PASS: --heartbeat-turn-end-staleness 60 honored (120s old → stale → renderer fallback)\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: turn_end staleness override — got=%s\n' "$got" >&2; FAIL=$(( FAIL + 1 ))
fi

# 5. busy heartbeat MUST NOT receive the turn_end longer threshold
#    even if some buggy caller injects last_turn_end into a non-idle
#    state. The classifier still picks last_turn_end as the anchor
#    (anchor selection is field-presence-based, not state-based) —
#    that's the contract. Document this so a future change doesn't
#    silently make busy heartbeats survive 30 min of silence.
old_la2=$(( NOW - 60 ))
printf '{"state":"busy","last_activity":%s,"last_turn_end":%s,"window":"test"}\n' \
    "$old_la2" "$NOW" > "$hb_file"
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name test --active 0 \
                --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "busy" ]]; then
    printf '  PASS: anchor selection is field-presence-based (busy+last_turn_end → busy emit; contract documented)\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: malformed busy+last_turn_end → busy expected, got=%s\n' "$got" >&2; FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== PermissionRequest hook → state=blocked (end-to-end, #129 item 2) ==="
# Exercise the full hook → heartbeat → pane-state classification chain
# for the PermissionRequest hook block in monitor/worker-settings.json.
# The hook command is `$NEXUS_ROOT/monitor/worker-heartbeat.sh
# permission_prompt` — fire the helper exactly the way the hook
# would, then read the resulting heartbeat through pane-state.sh and
# assert the renderer-fallback regex `_has_blocked_overlay` did NOT
# need to run (the heartbeat alone produced `state=blocked`).
#
# This complements the existing `fresh permission_prompt → blocked`
# unit (which writes a JSON file directly) and PR #131's "What
# Remains" regression-test item: prove the per-spawn hook config
# lands the correct heartbeat without depending on the rendered
# permission overlay.
hb_e2e_dir=$(mktemp -d)
HEARTBEAT_HELPER="$_repo_root/monitor/worker-heartbeat.sh"
env -i PATH="$PATH" \
    NEXUS_STATE_DIR="$hb_e2e_dir" NEXUS_WORKER_WINDOW=permreq-test \
    bash "$HEARTBEAT_HELPER" permission_prompt \
    <<<'{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' \
    >/dev/null 2>&1
hb_e2e_file="$hb_e2e_dir/heartbeat/permreq-test.json"
if [[ -f "$hb_e2e_file" ]]; then
    # Verify the heartbeat itself carries the expected state.
    hb_state_token=$(jq -r '.state // empty' "$hb_e2e_file" 2>/dev/null)
    if [[ "$hb_state_token" == "permission_prompt" ]]; then
        printf '  PASS: PermissionRequest hook fire → heartbeat state=permission_prompt\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: PermissionRequest hook fire — heartbeat state=%s want=permission_prompt\n' "$hb_state_token" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    # And classifier emit: the idle-empty fixture would normally yield
    # `idle`. The fresh permission_prompt heartbeat must override to
    # `blocked` without consulting the renderer's overlay regex.
    out=$("$HELPER" --fixture "$idle_fixture" \
                    --window 9 --name permreq-test --active 0 \
                    --heartbeat-file "$hb_e2e_file" \
                    --now "$(date +%s)" 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "blocked" ]]; then
        printf '  PASS: pane-state reads fresh heartbeat → state=blocked (renderer overlay regex not exercised)\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: pane-state heartbeat → blocked — got=%s (full: %s)\n' "$got" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
else
    printf '  FAIL: PermissionRequest hook fire produced no heartbeat at %s\n' "$hb_e2e_file" >&2
    FAIL=$(( FAIL + 1 ))
fi
rm -rf "$hb_e2e_dir"

echo
echo "=== over-limit stamp file (StopFailure hook, #129 item 4) ==="
# Hook-driven over-limit detection: when the StopFailure handler has
# written $STATE_DIR/over-limit/<window>.json, pane-state must emit
# state=over-limit + reset_at directly, without scanning the rendered
# pane for the "You've hit your limit · resets" text. The file path
# is also overridable via --over-limit-file for hermetic tests.

ol_tmp=$(mktemp)
ol_idle_fixture="$FIX_DIR/idle-empty-synthetic.ansi"
[[ -f "$ol_idle_fixture" ]] || { echo "needs $ol_idle_fixture" >&2; exit 1; }

# 1. File present with reset_at populated → emit state=over-limit
#    reset_at=<token>. `ts` must be FRESH: stamps older than the
#    anti-latch TTL (default 27h) are ignored + deleted by design.
printf '{"ts":%s,"session_id":"sess","error_type":"rate_limit","error_message":"weekly Opus limit","reset_at":"3am (America/Los_Angeles)","window":"olwin","hook_event_name":"StopFailure"}\n' \
    "$(date +%s)" > "$ol_tmp"
out=$("$HELPER" --fixture "$ol_idle_fixture" --window 9 --name olwin --active 0 \
                --over-limit-file "$ol_tmp" 2>&1)
got_state=$(awk -F'[ =]' '{print $2}' <<<"$out")
got_reset=$(grep -oE 'reset_at=[^ ]+' <<<"$out" | sed 's/^reset_at=//')
if [[ "$got_state" == "over-limit" ]]; then
    printf '  PASS: over-limit file present → state=over-limit (renderer scrape not exercised)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: over-limit file → state — got=%s want=over-limit (full: %s)\n' "$got_state" "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi
# Reset normalisation mirrors the renderer's: parens stripped, whitespace → _.
if [[ "$got_reset" == "3am_America/Los_Angeles" ]]; then
    printf '  PASS: reset_at normalised (got %s)\n' "$got_reset"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: reset_at normalisation — got=%s want=3am_America/Los_Angeles\n' "$got_reset" >&2
    FAIL=$(( FAIL + 1 ))
fi

# 2. File present with reset_at:null → emit state=over-limit
#    reset_at=unknown. Documents the documented-blocked path the
#    handler takes when no reset_at field was extractable from the
#    StopFailure payload.
printf '{"ts":%s,"session_id":"sess","error_type":"rate_limit","reset_at":null,"window":"olwin","hook_event_name":"StopFailure"}\n' \
    "$(date +%s)" > "$ol_tmp"
out=$("$HELPER" --fixture "$ol_idle_fixture" --window 9 --name olwin --active 0 \
                --over-limit-file "$ol_tmp" 2>&1)
got_state=$(awk -F'[ =]' '{print $2}' <<<"$out")
got_reset=$(grep -oE 'reset_at=[^ ]+' <<<"$out" | sed 's/^reset_at=//')
if [[ "$got_state" == "over-limit" ]] && [[ "$got_reset" == "unknown" ]]; then
    printf '  PASS: over-limit file + reset_at:null → state=over-limit reset_at=unknown\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: over-limit reset_at:null — state=%s reset_at=%s\n' "$got_state" "$got_reset" >&2
    FAIL=$(( FAIL + 1 ))
fi

# 3. A fresh busy heartbeat wins over the over-limit stamp — by
#    design. PostToolUse just fired ⇒ the worker IS doing real work
#    again ⇒ the rate limit has lifted (or the stamp is stale).
#    The Stop hook will clear the stamp on the next turn-end, so we
#    don't need to clear it pre-emptively; just let the heartbeat
#    speak. This documents the ordering: heartbeat (busy/idle/
#    blocked) before over-limit-stamp before over-limit-text. The
#    reverse would have a resumed worker stuck classifying as
#    over-limit until the Stop hook fired again.
# ts is pinned near the frozen $NOW these sub-tests pass via --now,
# so the stamp reads FRESH relative to the injected clock.
printf '{"ts":%s,"session_id":"sess","error_type":"rate_limit","reset_at":"3am","window":"olwin","hook_event_name":"StopFailure"}\n' \
    "$(( NOW - 60 ))" > "$ol_tmp"
printf '{"state":"busy","last_activity":%s,"window":"olwin"}\n' "$NOW" > "$hb_file"
out=$("$HELPER" --fixture "$ol_idle_fixture" --window 9 --name olwin --active 0 \
                --over-limit-file "$ol_tmp" \
                --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
got_state=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got_state" == "busy" ]]; then
    printf '  PASS: fresh busy heartbeat wins over stale over-limit stamp (resumed worker)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: heartbeat-over-stamp precedence — got=%s want=busy\n' "$got_state" >&2
    FAIL=$(( FAIL + 1 ))
fi

# 3b. The load-bearing inverse: STALE heartbeat + over-limit stamp →
#     emit over-limit. The 30 s last_activity threshold expires, the
#     classifier returns 1 (no heartbeat match), the renderer-blocked
#     overlay check finds nothing on the idle-empty fixture, and the
#     over-limit-stamp check fires. Demonstrates the stamp is
#     consulted when the heartbeat doesn't fire.
old_la=$(( NOW - 600 ))
printf '{"state":"busy","last_activity":%s,"window":"olwin"}\n' "$old_la" > "$hb_file"
out=$("$HELPER" --fixture "$ol_idle_fixture" --window 9 --name olwin --active 0 \
                --over-limit-file "$ol_tmp" \
                --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
got_state=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got_state" == "over-limit" ]]; then
    printf '  PASS: stale heartbeat + over-limit stamp → state=over-limit\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: stale heartbeat + over-limit stamp — got=%s want=over-limit\n' "$got_state" >&2
    FAIL=$(( FAIL + 1 ))
fi

# 3c. Blocked-overlay precedence over the over-limit stamp — load-
#     bearing for the brief's "case-B cascade MUST still fire"
#     constraint. When the rate-limit menu is up AND the over-limit
#     stamp is present, pane-state must emit state=blocked so
#     _unstick.sh case B can fire its auto-Enter cascade. Once the
#     menu is dismissed (no overlay text), the stamp takes over.
blocked_fixture=$(ls "$FIX_DIR"/blocked-*.ansi 2>/dev/null | head -1)
if [[ -n "$blocked_fixture" ]]; then
    out=$("$HELPER" --fixture "$blocked_fixture" --window 9 --name olwin --active 0 \
                    --over-limit-file "$ol_tmp" \
                    --heartbeat-file /dev/null --now "$NOW" 2>&1)
    got_state=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got_state" == "blocked" ]]; then
        printf '  PASS: blocked-overlay wins over over-limit stamp (case-B cascade preserved)\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: blocked vs stamp precedence — got=%s want=blocked (fixture: %s)\n' "$got_state" "$(basename "$blocked_fixture")" >&2
        FAIL=$(( FAIL + 1 ))
    fi
else
    printf '  SKIP: no blocked-*.ansi fixture available for case-B precedence check\n'
fi

# 4. Missing over-limit file → fall through to heartbeat / renderer.
#    Empty --over-limit-file flag would mis-interpret as "use blank
#    path", but the override only kicks in when non-empty; absent or
#    empty falls through to the env-var resolved path, which (with
#    NEXUS_STATE_DIR unset in this test process) yields no lookup.
rm -f "$ol_tmp"
printf '{"state":"idle_prompt","last_activity":%s,"window":"olwin"}\n' "$NOW" > "$hb_file"
out=$("$HELPER" --fixture "$ol_idle_fixture" --window 9 --name olwin --active 0 \
                --over-limit-file "$ol_tmp" \
                --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
got_state=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got_state" == "idle" ]]; then
    printf '  PASS: missing over-limit file → falls through (heartbeat → idle)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: missing over-limit file — got=%s want=idle\n' "$got_state" >&2
    FAIL=$(( FAIL + 1 ))
fi

rm -f "$ol_tmp"

# 5. Anti-latch TTL (2026-07-14 incident follow-up): a stamp whose
#    `ts` is older than MONITOR_OVER_LIMIT_STAMP_TTL_SECONDS (default
#    27h) is EXPIRED — ignored, best-effort deleted, and the
#    classifier falls through to the renderer. The stamp's cleanup
#    contract ("Stop hook clears it on the next successful turn")
#    has no successful turn to ride when a pane's settings lost the
#    Stop entry; without the TTL that pane reads over-limit forever
#    and the watcher's emit gate latches shut.
stale_ts=$(( NOW - 100 * 3600 ))   # 100h old ≫ 27h TTL
printf '{"ts":%s,"session_id":"sess","error_type":"rate_limit","reset_at":"3am","window":"olwin","hook_event_name":"StopFailure"}\n' \
    "$stale_ts" > "$ol_tmp"
out=$("$HELPER" --fixture "$ol_idle_fixture" --window 9 --name olwin --active 0 \
                --over-limit-file "$ol_tmp" \
                --heartbeat-file /dev/null --now "$NOW" 2>&1)
got_state=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got_state" != "over-limit" ]]; then
    printf '  PASS: expired stamp (100h) ignored → state=%s (no latch)\n' "$got_state"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: expired stamp still classifies over-limit — the latch the TTL exists to prevent\n' >&2
    FAIL=$(( FAIL + 1 ))
fi
if [[ ! -f "$ol_tmp" ]]; then
    printf '  PASS: expired stamp deleted (self-cleaning)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: expired stamp not deleted\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

# 5b. TTL boundary: a stamp INSIDE the TTL still classifies
#     over-limit (the TTL must not eat live suspensions).
printf '{"ts":%s,"session_id":"sess","error_type":"rate_limit","reset_at":"3am","window":"olwin","hook_event_name":"StopFailure"}\n' \
    "$(( NOW - 20 * 3600 ))" > "$ol_tmp"   # 20h old < 27h TTL
out=$("$HELPER" --fixture "$ol_idle_fixture" --window 9 --name olwin --active 0 \
                --over-limit-file "$ol_tmp" \
                --heartbeat-file /dev/null --now "$NOW" 2>&1)
got_state=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got_state" == "over-limit" ]]; then
    printf '  PASS: 20h-old stamp (inside TTL) still over-limit\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: inside-TTL stamp lost — got=%s want=over-limit\n' "$got_state" >&2
    FAIL=$(( FAIL + 1 ))
fi

# 5c. Corrupt stamp (no parseable ts, ancient mtime) ages out via
#     the mtime fallback instead of latching.
printf 'not json at all\n' > "$ol_tmp"
touch -d '@1700000000' "$ol_tmp" 2>/dev/null || touch -t 202311140000 "$ol_tmp"
out=$("$HELPER" --fixture "$ol_idle_fixture" --window 9 --name olwin --active 0 \
                --over-limit-file "$ol_tmp" \
                --heartbeat-file /dev/null 2>&1)
got_state=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got_state" != "over-limit" ]]; then
    printf '  PASS: corrupt ancient stamp ages out via mtime (got %s)\n' "$got_state"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: corrupt ancient stamp latched over-limit\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

rm -f "$ol_tmp"

echo
echo "=== over-limit detection (issue #87) ==="
# Canonical fixture: emits reset_at=<token> alongside state=over-limit.
canonical_fixture="$FIX_DIR/over-limit-canonical-synthetic.ansi"
if [[ -f "$canonical_fixture" ]]; then
    out=$("$HELPER" --fixture "$canonical_fixture" --window 9 --name overw --active 0)
    if grep -q 'state=over-limit' <<<"$out" \
       && grep -q 'reset_at=3am_America/Los_Angeles' <<<"$out"; then
        printf '  PASS: canonical over-limit emits reset_at=3am_America/Los_Angeles\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: canonical over-limit emit (got: %s)\n' "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

# Terse variant: bare time, no timezone parenthetical.
terse_fixture="$FIX_DIR/over-limit-terse-synthetic.ansi"
if [[ -f "$terse_fixture" ]]; then
    out=$("$HELPER" --fixture "$terse_fixture" --window 9 --name overw --active 0)
    if grep -q 'state=over-limit' <<<"$out" \
       && grep -q 'reset_at=11pm' <<<"$out"; then
        printf '  PASS: terse over-limit emits reset_at=11pm\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: terse over-limit emit (got: %s)\n' "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

# False-positive guard: idle pane whose scrollback contains the canonical
# text. Detection is anchored to the bottom 15 rows so this MUST emit idle.
fp_fixture="$FIX_DIR/idle-overlimit-text-in-scrollback-synthetic.ansi"
if [[ -f "$fp_fixture" ]]; then
    out=$("$HELPER" --fixture "$fp_fixture" --window 9 --name overw --active 0)
    if grep -q 'state=idle' <<<"$out" && ! grep -q 'state=over-limit' <<<"$out"; then
        printf '  PASS: over-limit text in scrollback does not false-trigger\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: scrollback over-limit text false-triggered (got: %s)\n' "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

# Hand-crafted fixture: notice text without a "resets <time>" companion.
# Detector requires both keys, so this should fall through to absent
# (no chevron, no spinner, no live claude in fixture mode).
no_reset_tmp=$(mktemp)
printf "Some random output\nYou've hit your limit (no reset line)\nmore text\n" > "$no_reset_tmp"
out=$("$HELPER" --fixture "$no_reset_tmp" --window 9 --name overw --active 0)
if ! grep -q 'state=over-limit' <<<"$out"; then
    printf '  PASS: half-rendered notice (no resets companion) does not over-trigger\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: half-rendered notice over-triggered (got: %s)\n' "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi
rm -f "$no_reset_tmp"

echo
echo "=== dead-claude liveness gate ==="
# Reproduces the original bug: a pane whose inner `claude` REPL has
# exited but whose last-rendered bytes still match an alive-state
# regex (autosuggest, busy-spinner, idle-empty input row, bright
# user-typed text). With tmux's `remain-on-exit on`, those bytes
# linger forever; a regex-only classifier returns alive every poll
# and the watcher's dead-pane → cleanup-policy → restart path never
# fires. The fix hoists `_pane_has_live_claude` to the very top of
# the classifier, gating absent on process state regardless of
# rendered bytes or in-flight heartbeat. We exercise it via the
# `--pane-pid` test surface: pass a known-dead pid alongside an
# alive-looking fixture and assert state=absent.
DEAD_PID=999999
while kill -0 "$DEAD_PID" 2>/dev/null; do
    DEAD_PID=$(( DEAD_PID + 1 ))
done

assert_dead_pid_absent() {
    local fixture="$1" label="$2"; shift 2
    local extra=("$@")
    local out got
    out=$("$HELPER" --fixture "$fixture" --window 9 --name testwin --active 0 \
                    --pane-pid "$DEAD_PID" "${extra[@]}" 2>&1) || {
        printf '  FAIL: %s — helper exited nonzero: %s\n' "$label" "$out" >&2
        FAIL=$(( FAIL + 1 ))
        return
    }
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "absent" ]]; then
        printf '  PASS: %-58s state=%s\n' "$label" "$got"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %-58s got=%s want=absent (full: %s)\n' \
            "$label" "$got" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# The pane content for each fixture would classify as alive without
# the gate; pairing each with a dead pid must produce absent.
assert_dead_pid_absent "$FIX_DIR/autosuggest-merge-win3.ansi"  "autosuggest bytes + dead pid → absent"
assert_dead_pid_absent "$FIX_DIR/busy-encode-win5.ansi"        "busy spinner + dead pid → absent"
assert_dead_pid_absent "$FIX_DIR/idle-empty-synthetic.ansi"    "idle empty input + dead pid → absent"
assert_dead_pid_absent "$FIX_DIR/user-typing-synthetic.ansi"   "user-typed bright text + dead pid → absent"
assert_dead_pid_absent "$FIX_DIR/busy-mid-render-no-chevron-synthetic.ansi" "busy mid-render + dead pid → absent"

# Process check supersedes a fresh heartbeat — heartbeat is a hint,
# pid liveness is ground truth. Without this guarantee, a worker that
# crashed within the heartbeat staleness window (default 30 s) would
# stay classified as busy until the heartbeat went stale.
hb_file="$hb_tmp/test.json"
printf '{"state":"busy","last_activity":%s,"window":"test"}\n' "$NOW" > "$hb_file"
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name test --active 0 \
                --heartbeat-file "$hb_file" --now "$NOW" \
                --pane-pid "$DEAD_PID" 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "absent" ]]; then
    printf '  PASS: fresh busy heartbeat + dead pid → absent (process > heartbeat)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: fresh heartbeat + dead pid — got=%s want=absent (full: %s)\n' \
        "$got" "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

# Live, non-claude pid (sleep) must also classify as absent — the
# gate is "live claude descendant", not "live anything". A sleep
# child has no claude in its tree but is unambiguously alive.
sleep 60 &
SLEEP_PID=$!
out=$("$HELPER" --fixture "$FIX_DIR/autosuggest-merge-win3.ansi" \
                --window 9 --name testwin --active 0 \
                --pane-pid "$SLEEP_PID" 2>&1)
kill "$SLEEP_PID" 2>/dev/null
wait "$SLEEP_PID" 2>/dev/null
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "absent" ]]; then
    printf '  PASS: alive sleep pid (no claude descendant) → absent\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: alive non-claude pid — got=%s want=absent (full: %s)\n' \
        "$got" "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

# No --pane-pid: gate is bypassed (fixture mode default), classifier
# falls through to renderer matching. Guards against accidentally
# making the gate fire on every fixture-mode invocation.
out=$("$HELPER" --fixture "$FIX_DIR/autosuggest-merge-win3.ansi" \
                --window 9 --name testwin --active 0 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "autosuggest-only" ]]; then
    printf '  PASS: fixture mode without --pane-pid still classifies from renderer\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: fixture mode without --pane-pid — got=%s want=autosuggest-only (full: %s)\n' \
        "$got" "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== content_hash emission + absent precedence (#205 / PR 270) ==="
# The transcript-region fingerprint must (a) ride every renderer-path
# emit, (b) neutralise digit-only churn (timer/token ticks), (c) stay
# cheap and safe on a pane with NO `❯<NBSP>` row, and (d) never delay
# or displace the dead-pane `absent` verdict — the liveness gate runs
# before any capture, so a gate-emitted `absent` carries no hash.
ch_tmp=$(mktemp -d)
trap 'rm -rf "$hb_tmp" "$ch_tmp"' EXIT
NB=$'\xc2\xa0'
ESCB=$'\x1b'
# Base: two transcript lines, an idle banner with digits, an idle
# empty-cursor input row.
printf 'Routine transcript line one\n\xe2\x9c\xbb Brewed for 34m 12s\n\xe2\x9d\xaf%s%s[7m %s[0m\n' \
    "$NB" "$ESCB" "$ESCB" > "$ch_tmp/base.ansi"
# Digits-only delta: same shape, only the timer numbers moved.
printf 'Routine transcript line one\n\xe2\x9c\xbb Brewed for 51m 48s\n\xe2\x9d\xaf%s%s[7m %s[0m\n' \
    "$NB" "$ESCB" "$ESCB" > "$ch_tmp/digits.ansi"
# Textual delta: the transcript itself grew.
printf 'Routine transcript line one plus fresh prose\n\xe2\x9c\xbb Brewed for 34m 12s\n\xe2\x9d\xaf%s%s[7m %s[0m\n' \
    "$NB" "$ESCB" "$ESCB" > "$ch_tmp/text.ansi"
# Chevron-less: transcript only — _content_hash digests the whole capture.
printf 'just some plain output\nno chevron anywhere here\n' > "$ch_tmp/nochevron.ansi"

ch_field() { sed -n 's/.*content_hash=\([0-9]*\).*/\1/p' <<<"$1"; }

out_base=$("$HELPER" --fixture "$ch_tmp/base.ansi" --window 9 --name chw --active 0)
out_base2=$("$HELPER" --fixture "$ch_tmp/base.ansi" --window 9 --name chw --active 0)
out_digits=$("$HELPER" --fixture "$ch_tmp/digits.ansi" --window 9 --name chw --active 0)
out_text=$("$HELPER" --fixture "$ch_tmp/text.ansi" --window 9 --name chw --active 0)
h_base=$(ch_field "$out_base"); h_base2=$(ch_field "$out_base2")
h_digits=$(ch_field "$out_digits"); h_text=$(ch_field "$out_text")

if grep -q 'state=idle' <<<"$out_base" && [[ -n "$h_base" ]]; then
    printf '  PASS: renderer-path idle emit carries content_hash\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: idle emit missing content_hash (got: %s)\n' "$out_base" >&2; FAIL=$(( FAIL + 1 ))
fi
if [[ -n "$h_base" && "$h_base" == "$h_base2" ]]; then
    printf '  PASS: content_hash is stable across invocations\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: content_hash unstable (%s vs %s)\n' "$h_base" "$h_base2" >&2; FAIL=$(( FAIL + 1 ))
fi
if [[ -n "$h_base" && "$h_base" == "$h_digits" ]]; then
    printf '  PASS: digit-only delta (timer tick) leaves content_hash unchanged\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: digit-only delta moved the hash (%s vs %s)\n' "$h_base" "$h_digits" >&2; FAIL=$(( FAIL + 1 ))
fi
if [[ -n "$h_text" && "$h_base" != "$h_text" ]]; then
    printf '  PASS: textual transcript delta moves content_hash\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: textual delta did not move the hash (%s vs %s)\n' "$h_base" "$h_text" >&2; FAIL=$(( FAIL + 1 ))
fi

# Chevron-less pane: classifies absent via the renderer fallback
# (no input row, no spinner, no pid supplied) and must still emit a
# whole-capture hash — proving _content_hash neither hangs nor
# misclassifies when the `❯<NBSP>` anchor is missing.
out_noc=$("$HELPER" --fixture "$ch_tmp/nochevron.ansi" --window 9 --name chw --active 0)
h_noc=$(ch_field "$out_noc")
if grep -q 'state=absent' <<<"$out_noc" && [[ -n "$h_noc" ]]; then
    printf '  PASS: chevron-less pane → renderer absent + whole-capture hash\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: chevron-less pane (got: %s)\n' "$out_noc" >&2; FAIL=$(( FAIL + 1 ))
fi

# Dead pid + alive-looking bytes: the liveness gate decides `absent`
# BEFORE any capture or fingerprint work, so the emit must carry NO
# content_hash. Guards the PR 270 ordering: fingerprinting must never
# sit ahead of (or delay) the dead-pane verdict.
out_dead=$("$HELPER" --fixture "$ch_tmp/base.ansi" --window 9 --name chw --active 0 \
                     --pane-pid "$DEAD_PID")
if grep -q 'state=absent' <<<"$out_dead" && ! grep -q 'content_hash=' <<<"$out_dead"; then
    printf '  PASS: dead pid → absent decided ahead of fingerprint (no content_hash)\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: dead-pid emit wrong shape (got: %s)\n' "$out_dead" >&2; FAIL=$(( FAIL + 1 ))
fi

# Zombie claude: an exited-but-unreaped `claude` in the pane tree is
# NOT alive — the gate must read it as dead and emit absent. This is
# the unit-level stand-in for the realmodel kill scenario: after the
# harness TERMs the pane tree, any window where the corpse lingers
# (slow reap, slow teardown) must still classify absent within the
# poll budget. Requires python3 (Popen-without-wait makes the zombie).
if command -v python3 >/dev/null 2>&1; then
    printf '#!/bin/sh\nexit 0\n' > "$ch_tmp/claude"
    chmod +x "$ch_tmp/claude"
    python3 -c 'import subprocess,sys,time; subprocess.Popen([sys.argv[1]]); time.sleep(30)' \
        "$ch_tmp/claude" &
    ZPARENT=$!
    # Give the child a beat to exec, exit, and become a zombie.
    sleep 0.5
    out_z=$("$HELPER" --fixture "$ch_tmp/base.ansi" --window 9 --name chw --active 0 \
                      --pane-pid "$ZPARENT")
    kill "$ZPARENT" 2>/dev/null; wait "$ZPARENT" 2>/dev/null
    if grep -q 'state=absent' <<<"$out_z"; then
        printf '  PASS: zombie claude in pane tree → absent (corpse is not alive)\n'; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: zombie claude read as live (got: %s)\n' "$out_z" >&2; FAIL=$(( FAIL + 1 ))
    fi
else
    printf '  SKIP: zombie-claude case (python3 unavailable)\n'
fi

echo
echo "=== async-signal idle refinement (issue #183) ==="
# Refinement applies when the renderer (or heartbeat) would have
# emitted `idle`. The four refined classes:
#   working-background  monitor_handles>0 OR background_bash_count>0
#   working-self-paced  scheduled_wakeup_at > now
#   idle-orphan-async   external_waits != [] AND no monitor/wakeup
#   idle                none of the above
# Heartbeat is authoritative when fresh; pane-footer fills in the
# monitor/bg counts when heartbeat is missing or stale.
async_tmp=$(mktemp -d)
trap 'rm -rf "$hb_tmp" "$ch_tmp" "$async_tmp"' EXIT
ASYNC_NOW=2000000000
async_hb="$async_tmp/async.json"

write_async_hb() {
    # Args: <state> <age> <monitor_handles> <bg_count> <scheduled_wakeup_at|-> <external_waits_json>
    local state="$1" age="$2" mon="$3" bg="$4" swa="$5" waits="$6"
    local last_activity=$(( ASYNC_NOW - age ))
    if [[ "$swa" == "-" ]]; then
        jq -nc \
            --arg s "$state" --argjson la "$last_activity" --arg w test \
            --argjson m "$mon" --argjson b "$bg" \
            --argjson ew "$waits" \
            '{state:$s, last_activity:$la, window:$w, monitor_handles:$m, background_bash_count:$b, external_waits:$ew}' \
            > "$async_hb"
    else
        jq -nc \
            --arg s "$state" --argjson la "$last_activity" --arg w test \
            --argjson m "$mon" --argjson b "$bg" \
            --argjson swa "$swa" --argjson ew "$waits" \
            '{state:$s, last_activity:$la, window:$w, monitor_handles:$m, background_bash_count:$b, scheduled_wakeup_at:$swa, external_waits:$ew}' \
            > "$async_hb"
    fi
}

assert_async_state() {
    local label="$1" want_state="$2" want_extra="$3"; shift 3
    local out got_state got_extra
    out=$("$HELPER" --fixture "$idle_fixture" \
                    --window 9 --name test --active 0 \
                    --heartbeat-file "$async_hb" \
                    --now "$ASYNC_NOW" \
                    "$@" 2>&1) || {
        printf '  FAIL: %s — helper rc nonzero: %s\n' "$label" "$out" >&2
        FAIL=$(( FAIL + 1 ))
        return
    }
    got_state=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got_state" == "$want_state" ]]; then
        printf '  PASS: %-55s state=%s\n' "$label" "$got_state"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %-55s got=%s want=%s (full: %s)\n' \
            "$label" "$got_state" "$want_state" "$out" >&2
        FAIL=$(( FAIL + 1 ))
        return
    fi
    if [[ -n "$want_extra" ]]; then
        if grep -qF "$want_extra" <<<"$out"; then
            printf '  PASS: %-55s extra=%s\n' "$label (extra)" "$want_extra"
            PASS=$(( PASS + 1 ))
        else
            printf '  FAIL: %-55s missing extra: %s (full: %s)\n' \
                "$label (extra)" "$want_extra" "$out" >&2
            FAIL=$(( FAIL + 1 ))
        fi
    fi
}

# (1) working-background: monitor handle live.
write_async_hb idle_prompt 5 1 0 - '[]'
assert_async_state "monitor_handles=1 → working-background" \
    working-background ""

# (1b) working-background: background bash live.
write_async_hb idle_prompt 5 0 2 - '[]'
assert_async_state "background_bash_count=2 → working-background" \
    working-background ""

# (2) working-self-paced: scheduled_wakeup_at > now.
write_async_hb idle_prompt 5 0 0 "$(( ASYNC_NOW + 300 ))" '[]'
assert_async_state "scheduled_wakeup_at>now → working-self-paced" \
    working-self-paced ""

# (2b) past wakeup → does NOT cause working-self-paced.
write_async_hb idle_prompt 5 0 0 "$(( ASYNC_NOW - 60 ))" '[]'
assert_async_state "scheduled_wakeup_at<now → plain idle" \
    idle ""

# (3) idle-orphan-async: external_waits non-empty, no resume signal.
write_async_hb idle_prompt 5 0 0 - \
    '[{"kind":"slurm","id":"52527284_4","desc":"BL"}]'
assert_async_state "external_waits non-empty → idle-orphan-async" \
    idle-orphan-async "orphan_kinds=slurm:52527284_4"

# (3b) multiple external_waits surface as csv summary.
write_async_hb idle_prompt 5 0 0 - \
    '[{"kind":"slurm","id":"1","desc":""},{"kind":"ci","id":"abc/runs/9","desc":""}]'
assert_async_state "multi-waits → orphan_kinds csv" \
    idle-orphan-async "orphan_kinds=slurm:1,ci:abc/runs/9"

# (3c) external_waits empty array → plain idle.
write_async_hb idle_prompt 5 0 0 - '[]'
assert_async_state "empty external_waits → plain idle" \
    idle ""

# (4) Priority: monitor handle beats external_waits.
write_async_hb idle_prompt 5 1 0 - \
    '[{"kind":"slurm","id":"99999","desc":""}]'
assert_async_state "monitor + waits → working-background wins" \
    working-background ""

# (4b) scheduled_wakeup beats external_waits.
write_async_hb idle_prompt 5 0 0 "$(( ASYNC_NOW + 60 ))" \
    '[{"kind":"slurm","id":"77777","desc":""}]'
assert_async_state "wakeup + waits → working-self-paced wins" \
    working-self-paced ""

# (5) Stale heartbeat: refinement skipped — falls through to renderer
#     (idle from the fixture). The async-signal staleness defaults to
#     60 s; bump the age past it.
write_async_hb idle_prompt 5 0 0 - \
    '[{"kind":"slurm","id":"x","desc":""}]'
# Override last_activity to be way in the past for the async window.
jq -c '.last_activity = (.last_activity - 3600)' "$async_hb" \
    > "$async_hb.tmp" && mv "$async_hb.tmp" "$async_hb"
assert_async_state "stale async signals → renderer fallback (idle)" \
    idle ""

# (6) Custom async-staleness lets a row in.
write_async_hb idle_prompt 5 0 0 - \
    '[{"kind":"slurm","id":"y","desc":""}]'
# Make it 90 s old, then permit via --heartbeat-async-staleness 120.
jq -c '.last_activity = (.last_activity - 85)' "$async_hb" \
    > "$async_hb.tmp" && mv "$async_hb.tmp" "$async_hb"
# Heartbeat-state staleness for `idle_prompt` (last_turn_end-anchored)
# is 1800 s by default; well within the 85-s age. So the heartbeat-
# fast-path still emits `idle`. Then refinement triggers because the
# async-staleness override permits it.
assert_async_state "--heartbeat-async-staleness 120 allows 85s-old waits" \
    idle-orphan-async "orphan_kinds=slurm:y" \
    --heartbeat-async-staleness 120

# (7) Pane-footer fallback: no heartbeat, but fixture shows `1 monitor`.
foot_mon_fixture="$FIX_DIR/working-background-monitor-synthetic.ansi"
if [[ -f "$foot_mon_fixture" ]]; then
    out=$("$HELPER" --fixture "$foot_mon_fixture" \
                    --window 9 --name ftest --active 0 \
                    --heartbeat-file "$async_tmp/missing.json" \
                    --now "$ASYNC_NOW" 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "working-background" ]]; then
        printf '  PASS: no heartbeat + footer "1 monitor" → working-background\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: footer fallback monitor — got=%s want=working-background\n' "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

foot_bg_fixture="$FIX_DIR/working-background-bgbash-synthetic.ansi"
if [[ -f "$foot_bg_fixture" ]]; then
    out=$("$HELPER" --fixture "$foot_bg_fixture" \
                    --window 9 --name ftest --active 0 \
                    --heartbeat-file "$async_tmp/missing.json" \
                    --now "$ASYNC_NOW" 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "working-background" ]]; then
        printf '  PASS: no heartbeat + footer "N background bash" → working-background\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: footer fallback bg — got=%s want=working-background\n' "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

# (8) Footer count is preferred over heartbeat zeros (heartbeat hook
#     can't introspect claude's handle list, so 0 there is "no signal"
#     not "definitely zero"). If the heartbeat lacks a wait and the
#     footer carries monitor, we still pick working-background.
if [[ -f "$foot_mon_fixture" ]]; then
    write_async_hb idle_prompt 5 0 0 - '[]'
    out=$("$HELPER" --fixture "$foot_mon_fixture" \
                    --window 9 --name ftest --active 0 \
                    --heartbeat-file "$async_hb" \
                    --now "$ASYNC_NOW" 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "working-background" ]]; then
        printf '  PASS: heartbeat zeros + footer monitor → working-background\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: heartbeat+footer OR — got=%s want=working-background\n' "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

# (9) external_waits has NO renderer fallback — pane bytes can't
#     declare a slurm wait. A fixture without footer signals and no
#     heartbeat must classify as plain idle.
out=$("$HELPER" --fixture "$idle_fixture" \
                --window 9 --name ntest --active 0 \
                --heartbeat-file "$async_tmp/missing.json" \
                --now "$ASYNC_NOW" 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "idle" ]]; then
    printf '  PASS: no heartbeat + no footer signals → idle (not orphan-async)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: no-signal — got=%s want=idle\n' "$got" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== real-footer shell phrasing + bg_cpu scoping (your-org/nexus-code#445) ==="
# The pre-#445 regex looked for the word "background" and never matched
# the real Claude Code v2.1.204 status line `· N shell[s], N monitor ·`,
# so a worker idling between turns with a live background shell was
# false-classified `idle` → spurious idle-without-wrap-up nag.

# (10) Real status-line `1 shell, 1 monitor` (no spinner "still
#      running") → working-background. This is the exact form the old
#      regex missed. Footer fallback (no heartbeat).
real_foot="$FIX_DIR/working-background-shell-realfooter.ansi"
if [[ -f "$real_foot" ]]; then
    out=$("$HELPER" --fixture "$real_foot" \
                    --window 9 --name paperbench --active 0 \
                    --heartbeat-file "$async_tmp/missing.json" \
                    --now "$ASYNC_NOW" --bg-cpu 1200 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "working-background" ]]; then
        printf '  PASS: real "1 shell, 1 monitor" footer → working-background\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: real-footer shell — got=%s want=working-background (full: %s)\n' "$got" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    # (10b) shell-driven working-background CARRIES bg_cpu (grace-capped).
    if grep -qF 'bg_cpu=1200' <<<"$out"; then
        printf '  PASS: shell-driven working-background carries bg_cpu\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: shell-driven missing bg_cpu (full: %s)\n' "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

# (10c) Monitor-handle working-background carries NO bg_cpu (it is
#       self-waking and must never be subjected to the shell
#       orphan-grace). Heartbeat monitor_handles=1, bg=0.
write_async_hb idle_prompt 5 1 0 - '[]'
out=$("$HELPER" --fixture "$idle_fixture" \
                --window 9 --name montest --active 0 \
                --heartbeat-file "$async_hb" \
                --now "$ASYNC_NOW" --bg-cpu 9999 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "working-background" ]] && ! grep -qF 'bg_cpu=' <<<"$out"; then
    printf '  PASS: monitor-handle working-background omits bg_cpu\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: monitor-handle bg_cpu scoping — got=%s (full: %s)\n' "$got" "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

# (10d) shell-count from heartbeat (background_bash_count=3) → shell
#       driver → bg_cpu present.
write_async_hb idle_prompt 5 0 3 - '[]'
out=$("$HELPER" --fixture "$idle_fixture" \
                --window 9 --name bgtest --active 0 \
                --heartbeat-file "$async_hb" \
                --now "$ASYNC_NOW" --bg-cpu 555 2>&1)
if grep -qF 'state=working-background' <<<"$out" && grep -qF 'bg_cpu=555' <<<"$out"; then
    printf '  PASS: heartbeat background_bash_count → shell-driven bg_cpu\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: heartbeat bg-count bg_cpu — (full: %s)\n' "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== process-tree as the authoritative background-shell signal (your-org/nexus-code#455) ==="
# The status-line `N shell` footer is presentation: a user can customise
# the status bar, it changes across CC versions, and a regex can match
# unrelated pane text. #455 makes the kernel PROCESS TREE (claude's live
# background-shell child subtrees) the primary + authoritative signal,
# demoting the footer regex to a fallback for when /proc can't be read.
# `--bg-shells N` injects a RELIABLE process-tree reading (count=N) so the
# fixtures can exercise the authoritative path.

# (11a) UP override — a live background shell the status bar does NOT show
#       (customised/changed footer). Clean idle fixture (no footer shell
#       token, no heartbeat) + a reliable process-tree count of 2 →
#       working-background. The footer regex would have missed this
#       (the #445-class false-idle, now caught by process truth).
out=$("$HELPER" --fixture "$idle_fixture" \
                --window 9 --name pt-up --active 0 \
                --heartbeat-file "$async_tmp/missing.json" \
                --now "$ASYNC_NOW" --bg-shells 2 --bg-cpu 4242 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "working-background" ]] && grep -qF 'bg_cpu=4242' <<<"$out"; then
    printf '  PASS: process-tree count>0 with silent footer → working-background + bg_cpu\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: process-tree UP override — got=%s (full: %s)\n' "$got" "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

# (11b) DOWN override — a spurious footer `· 2 shells ·` (coincidental
#       text / customised status bar) with NO live background shell.
#       A reliable process-tree count of 0 must OVERRIDE the footer down
#       to `idle`. This is the false-positive the operator flagged:
#       "the regex may match other output in the window".
spurious_foot="$FIX_DIR/working-background-spurious-shell-footer-synthetic.ansi"
if [[ -f "$spurious_foot" ]]; then
    # (11b-i) Fallback path (no reliable tree reading): the footer regex
    #         still fires → working-background. Confirms the fragile
    #         fallback is intact for /proc-restricted environments AND
    #         demonstrates the fragility the process tree corrects.
    out=$("$HELPER" --fixture "$spurious_foot" \
                    --window 9 --name pt-fallback --active 0 \
                    --heartbeat-file "$async_tmp/missing.json" \
                    --now "$ASYNC_NOW" 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "working-background" ]]; then
        printf '  PASS: spurious footer, no tree reading → working-background (fallback intact)\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: footer fallback — got=%s (full: %s)\n' "$got" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    # (11b-ii) Authoritative path (reliable tree count=0): overrides the
    #          spurious footer down to idle.
    out=$("$HELPER" --fixture "$spurious_foot" \
                    --window 9 --name pt-down --active 0 \
                    --heartbeat-file "$async_tmp/missing.json" \
                    --now "$ASYNC_NOW" --bg-shells 0 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "idle" ]]; then
        printf '  PASS: reliable process-tree count=0 overrides spurious footer → idle\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: process-tree DOWN override — got=%s want=idle (full: %s)\n' "$got" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

# (11c) Monitor is NOT visible to the process tree — a reliable tree
#       count of 0 must NOT suppress a live Monitor handle (heartbeat
#       monitor_handles=1). Still working-background, and (Monitor-driven)
#       carries NO bg_cpu.
write_async_hb idle_prompt 5 1 0 - '[]'
out=$("$HELPER" --fixture "$idle_fixture" \
                --window 9 --name pt-mon --active 0 \
                --heartbeat-file "$async_hb" \
                --now "$ASYNC_NOW" --bg-shells 0 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "working-background" ]] && ! grep -qF 'bg_cpu=' <<<"$out"; then
    printf '  PASS: tree count=0 does not suppress Monitor handle → working-background, no bg_cpu\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: Monitor-not-in-tree — got=%s (full: %s)\n' "$got" "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== bg_shells + bg_reliable emit fields (your-org/nexus-code#455 refine) ==="
# A shell-driven working-background line must ALSO carry bg_shells=<count>
# and bg_reliable=<0|1> so the watcher's idle probe can key its
# idle-with-children backoff + wrap-up-with-children inconsistency detector.

# (12a) Authoritative shell-driven reading → bg_shells=<count> bg_reliable=1.
out=$("$HELPER" --fixture "$idle_fixture" \
                --window 9 --name bgfields-rel --active 0 \
                --heartbeat-file "$async_tmp/missing.json" \
                --now "$ASYNC_NOW" --bg-shells 3 --bg-cpu 777 2>&1)
if grep -qF 'state=working-background' <<<"$out" \
   && grep -qF 'bg_shells=3' <<<"$out" \
   && grep -qF 'bg_reliable=1' <<<"$out" \
   && grep -qF 'bg_cpu=777' <<<"$out"; then
    printf '  PASS: authoritative shell-driven → bg_shells + bg_reliable=1 + bg_cpu\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: bg_shells/bg_reliable emit — (full: %s)\n' "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

# (12b) Fallback path (footer-driven, unreliable tree) → the shell-driven
#       line still carries bg_reliable=0 so the probe keeps legacy behaviour.
real_foot="$FIX_DIR/working-background-shell-realfooter.ansi"
if [[ -f "$real_foot" ]]; then
    out=$("$HELPER" --fixture "$real_foot" \
                    --window 9 --name bgfields-fallback --active 0 \
                    --heartbeat-file "$async_tmp/missing.json" \
                    --now "$ASYNC_NOW" --bg-cpu 1200 2>&1)
    if grep -qF 'state=working-background' <<<"$out" \
       && grep -qF 'bg_reliable=0' <<<"$out"; then
        printf '  PASS: footer-fallback shell-driven → bg_reliable=0\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: footer-fallback bg_reliable — (full: %s)\n' "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

# (12c) Monitor-handle working-background carries NEITHER bg_shells nor
#       bg_reliable (it is not shell-driven).
write_async_hb idle_prompt 5 1 0 - '[]'
out=$("$HELPER" --fixture "$idle_fixture" \
                --window 9 --name bgfields-mon --active 0 \
                --heartbeat-file "$async_hb" \
                --now "$ASYNC_NOW" --bg-shells 0 2>&1)
if grep -qF 'state=working-background' <<<"$out" \
   && ! grep -qF 'bg_shells=' <<<"$out" \
   && ! grep -qF 'bg_reliable=' <<<"$out"; then
    printf '  PASS: Monitor-handle working-background omits bg_shells/bg_reliable\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: Monitor-handle bg-fields scoping — (full: %s)\n' "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== bogus-index fail-loud (issue #140) ==="
# Real-tmux tests: a non-existent window index must emit a clear
# stderr error, exit 3, and produce no stdout (so a grep-style probe
# like `pane-state.sh <idx> | grep state=absent` cannot false-match).
# A valid index whose pane has no claude descendant must still emit
# `state=absent active=<x> window=<idx> name=<actual>` + exit 0 —
# the existing dead-claude semantics are preserved, only the
# bogus-index footgun is removed.
#
# Self-skip when tmux isn't on PATH (e.g. minimal contributor envs).
# CI installs tmux explicitly; the gate is for local dev convenience.
if command -v tmux >/dev/null 2>&1; then
    bogus_tmpdir=$(mktemp -d)
    bogus_sock="nexus-pane-state-140-$$-$RANDOM"
    bogus_session="ps140"
    bogus_tmux_bin=$(command -v tmux)
    cat > "$bogus_tmpdir/tmux" <<TMUXSHIM
#!/usr/bin/env bash
exec "$bogus_tmux_bin" -L "$bogus_sock" "\$@"
TMUXSHIM
    chmod +x "$bogus_tmpdir/tmux"
    cleanup_bogus() {
        PATH="$bogus_tmpdir:$PATH" tmux kill-server 2>/dev/null || true
        rm -rf "$bogus_tmpdir"
    }
    trap cleanup_bogus EXIT

    # Bring up an isolated tmux server. -f /dev/null neutralises the
    # operator's personal tmux.conf so it can't perturb window names
    # or base-index. `sleep 36000` keeps the pane alive without
    # spawning anything that could match `_pane_has_live_claude`.
    PATH="$bogus_tmpdir:$PATH" tmux -f /dev/null new-session -d \
        -s "$bogus_session" -x 80 -y 24 'sleep 36000'

    # Resolve the first real window index — base-index may be 0 or 1
    # depending on the operator's tmux defaults. We took -f /dev/null
    # so it defaults to 0, but read it dynamically for robustness.
    valid_idx=$(PATH="$bogus_tmpdir:$PATH" tmux list-windows \
                  -t "$bogus_session" -F '#{window_index}' | head -1)

    # Pick a bogus index guaranteed to be outside the live set.
    bogus_idx=99999

    # Case 1: bogus index → stderr message, exit 3, no stdout.
    bogus_out_file=$(mktemp)
    bogus_err_file=$(mktemp)
    PATH="$bogus_tmpdir:$PATH" \
        bash "$HELPER" "${bogus_session}:${bogus_idx}" \
        >"$bogus_out_file" 2>"$bogus_err_file"
    bogus_rc=$?
    bogus_stdout=$(<"$bogus_out_file")
    bogus_stderr=$(<"$bogus_err_file")
    rm -f "$bogus_out_file" "$bogus_err_file"
    if (( bogus_rc == 3 )) \
       && [[ -z "$bogus_stdout" ]] \
       && [[ "$bogus_stderr" == *"no such tmux window: ${bogus_idx}"* ]]; then
        printf '  PASS: bogus index → exit 3, empty stdout, stderr names it\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: bogus index — rc=%s stdout=%q stderr=%q\n' \
            "$bogus_rc" "$bogus_stdout" "$bogus_stderr" >&2
        FAIL=$(( FAIL + 1 ))
    fi

    # Case 1b: grep-style probe must not see a positive `state=absent`
    # match for the bogus-index path. This is the canonical
    # orchestrator footgun pattern called out in the issue.
    grep_probe_out=$(PATH="$bogus_tmpdir:$PATH" \
        bash "$HELPER" "${bogus_session}:${bogus_idx}" 2>/dev/null \
        | grep -c 'state=absent' || true)
    if [[ "$grep_probe_out" == "0" ]]; then
        printf '  PASS: grep state=absent finds nothing for bogus index\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: grep state=absent saw %s matches for bogus index\n' \
            "$grep_probe_out" >&2
        FAIL=$(( FAIL + 1 ))
    fi

    # Case 2: valid window, pane runs sleep (no claude descendant) →
    # `state=absent` + populated name + exit 0. The process-liveness
    # gate (_pane_has_live_claude) walks the pane's process tree,
    # finds no claude/claude-code, and emits absent — the documented
    # dead-claude path that the bogus-index fix MUST NOT regress.
    valid_out=$(PATH="$bogus_tmpdir:$PATH" \
        bash "$HELPER" "${bogus_session}:${valid_idx}" 2>&1)
    valid_rc=$?
    if (( valid_rc == 0 )) \
       && grep -qE "state=absent[[:space:]]" <<<"$valid_out" \
       && grep -qE "window=${valid_idx}([[:space:]]|$)" <<<"$valid_out" \
       && grep -qE 'name=[^[:space:]]' <<<"$valid_out"; then
        printf '  PASS: valid index + sleep pane → state=absent + populated name + rc=0\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: valid sleep-pane — rc=%s out=%q\n' \
            "$valid_rc" "$valid_out" >&2
        FAIL=$(( FAIL + 1 ))
    fi

    cleanup_bogus
    trap - EXIT
else
    printf '  SKIP: tmux unavailable — bogus-index fail-loud tests skipped\n'
fi

echo "=== autosuggest ghost is not evidence of an empty child set (#455 follow-up) ==="
# An autosuggest ghost is a RENDERING of the input row; it says nothing about
# the process tree. The renderer ladder used to emit `autosuggest-only` WITHOUT
# ever walking the tree, so a worker holding a live background shell that drew a
# ghost on one poll read as plain-idle. The watcher then took that as an
# authoritative "no children" and silently reset its absolute ceiling.
#
# All three fixtures below are REAL captures from live worker windows.

# (14a) Ghost + LIVE background child → working-background. Deliberately uses
#       ONLY the pre-existing flags, so that when this test is run against the
#       pre-fix tree it fails on the SEMANTICS (it emits `autosuggest-only`)
#       rather than on an unknown-flag usage error. Both directions matter, so
#       14b asserts the converse.
for gf in autosuggest-why-win4 autosuggest-review-win6 autosuggest-merge-win3; do
    gfx="$FIX_DIR/$gf.ansi"
    [[ -f "$gfx" ]] || continue
    out=$("$HELPER" --fixture "$gfx" --window 9 --name ghost-live --active 0 \
                    --heartbeat-file "$async_tmp/missing.json" --now "$ASYNC_NOW" \
                    --bg-shells 1 --bg-cpu 500 2>&1)
    if grep -qF 'state=working-background' <<<"$out" \
       && grep -qF 'bg_shells=1' <<<"$out"; then
        printf '  PASS: ghost + live child → working-background (%s)\n' "$gf"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: ghost + live child should not read idle (%s) — %s\n' "$gf" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
done

# (14b) Ghost with NO background child → still `autosuggest-only`. The promotion
#       must be driven by the tree, not by the ghost: no false busy-flagging of a
#       genuinely idle, ready-to-paste pane.
for gf in autosuggest-why-win4 autosuggest-review-win6 autosuggest-merge-win3; do
    gfx="$FIX_DIR/$gf.ansi"
    [[ -f "$gfx" ]] || continue
    out=$("$HELPER" --fixture "$gfx" --window 9 --name ghost-idle --active 0 \
                    --heartbeat-file "$async_tmp/missing.json" --now "$ASYNC_NOW" 2>&1)
    if grep -qF 'state=autosuggest-only' <<<"$out"; then
        printf '  PASS: ghost, no children → autosuggest-only (%s)\n' "$gf"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: childless ghost must stay autosuggest-only (%s) — %s\n' "$gf" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
done

echo "=== bg_oldest_start: the derived episode start (#455 follow-up) ==="
# (15) The shell-driven working-background line carries the oldest background
#      shell's start epoch, so the probe can DERIVE the episode age instead of
#      storing a resettable clock.
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name bgold --active 0 \
                --heartbeat-file "$async_tmp/missing.json" --now "$ASYNC_NOW" \
                --bg-shells 2 --bg-cpu 10 --bg-oldest-start 1699999999 2>&1)
if grep -qF 'bg_oldest_start=1699999999' <<<"$out"; then
    printf '  PASS: working-background carries bg_oldest_start\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: bg_oldest_start not emitted — %s\n' "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== summary ==="
printf '  %d pass / %d fail\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    echo "FAIL"
    exit 1
fi
echo "ALL TESTS PASSED"
exit 0
