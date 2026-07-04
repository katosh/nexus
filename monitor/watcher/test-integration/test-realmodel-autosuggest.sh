#!/usr/bin/env bash
# test-realmodel-autosuggest.sh — real-binary scenario for the
# `autosuggest-only` classification (the grey input-box ghost text that
# Claude Code paints from a server-side prompt suggestion; Tab accepts it).
#
# WHY THIS TEST IS STRUCTURED THE WAY IT IS — read before "fixing" it.
#
# The input-box autosuggest is driven by a SEPARATE background request the
# binary makes on idle (a final user message tagged `[SUGGESTION MODE: …]`,
# answered as plain text — see mock-backend.py `_is_suggestion_request`).
# Empirically, claude 2.1.147 does NOT emit that request against our mock
# even with a warm prompt cache advertised and several turns driven: the
# suggestion is gated server-side (feature flag / response metadata we cannot
# forge), so the live TUI never paints the ghost text against a custom
# backend. Probed and confirmed 2026-05-29 (orchestrator session; the mock's
# session-title structured call fires, the suggestion call never does).
#
# Therefore a pure-live "drive the binary until it suggests" assertion would
# never pass and must not be shipped. What this test DOES assert, faithfully:
#
#   * the REAL binary boots against the auth-free mock and reaches idle with
#     a live `claude` process in the pane tree (real boot / liveness), and
#   * the PRODUCTION monitor/pane-state.sh classifies the REAL autosuggest
#     renderer bytes (captured fixtures) as `autosuggest-only` when anchored
#     to that genuinely-live claude pid — and degrades to `absent` when the
#     backing process is gone (the liveness gate).
#
# This is strictly more than the pure-fixture unit test
# (monitor/watcher/test-pane-state.sh), which classifies the same bytes with
# a SYNTHETIC pid and so never exercises the gate against a real cc process.
# If a future cc release starts emitting the suggestion against the mock,
# upgrade this to a pure-live capture assertion (the mock already serves it).
#
# Gated on RUN_CC_HARNESS=1 (+ node + a resolvable claude binary);
# self-skips otherwise. See monitor/cc-harness/README.md.

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_self_dir/../_test_helpers.sh"
. "$_self_dir/../../cc-harness/_lib.sh"

cch_skip_if_disabled
cch_setup

FIX_DIR="$_self_dir/../fixtures"
# Real captured autosuggest frames (grey ghost text on the input row).
AUTOSUGGEST_FIXTURES=(
    "$FIX_DIR/autosuggest-why-win4.ansi"
    "$FIX_DIR/autosuggest-review-win6.ansi"
)

# Run the production pane-state.sh in fixture mode against a real
# autosuggest frame, anchored to a given (live or dead) pane pid. Mirrors
# cch_pane_state's env (tmux-wrapper PATH + isolated state dir).
cch_classify_fixture() {
    local fixture="$1" pid="$2"
    PATH="$CCH_DIR/.bin:$PATH" NEXUS_STATE_DIR="$CCH_STATE_DIR" \
        "$CCH_PANE_STATE" --fixture "$fixture" \
            --window 9 --name agauto --active 0 --pane-pid "$pid" \
        | sed -n 's/.*state=\([^ ]*\).*/\1/p'
}

echo "=== real-binary harness: autosuggest-only ==="
echo "    claude:  $CLAUDE_BIN"
echo "    mock:    127.0.0.1:$CCH_MOCK_PORT"

# 1. Boot the real binary to idle.
win=$(cch_boot_worker w1)
[[ -n "$win" ]] || { echo "FAIL: worker window never appeared" >&2; exit 1; }
wait_for "boots to idle" 30 -- cch_state_is "$win" idle

# 2. A live claude must back the pane (the autosuggest-only verdict is
#    liveness-gated; without a live claude the renderer bytes mean absent).
live_pid=$(cch_tmux display-message -p -t "$CCH_SESSION:$win" '#{pane_pid}' 2>/dev/null)
if [[ -n "$live_pid" ]] && kill -0 "$live_pid" 2>/dev/null; then
    echo "  PASS: live claude pid backs the pane ($live_pid)"
    PASS=$(( PASS + 1 ))
else
    echo "  FAIL: no live pane pid for the booted worker" >&2
    FAIL=$(( FAIL + 1 ))
fi

# 3. Real autosuggest renderer bytes + the LIVE real-claude pid ->
#    autosuggest-only, through the production classifier.
for fx in "${AUTOSUGGEST_FIXTURES[@]}"; do
    [[ -f "$fx" ]] || { echo "FAIL: missing fixture $fx" >&2; FAIL=$(( FAIL + 1 )); continue; }
    got=$(cch_classify_fixture "$fx" "$live_pid")
    assert_eq "live claude + $(basename "$fx") -> autosuggest-only" "$got" "autosuggest-only"
done

# 4. Liveness gate: the SAME real autosuggest bytes with a dead backing pid
#    must classify as absent, not autosuggest-only (process-liveness wins).
( exit 0 ) & dead_pid=$!; wait "$dead_pid" 2>/dev/null
got=$(cch_classify_fixture "${AUTOSUGGEST_FIXTURES[0]}" "$dead_pid")
assert_eq "autosuggest bytes + dead pid -> absent" "$got" "absent"

th_summary_and_exit
