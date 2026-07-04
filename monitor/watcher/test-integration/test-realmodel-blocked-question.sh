#!/usr/bin/env bash
# test-realmodel-blocked-question.sh — real-binary scenario for the
# `blocked` classification.
#
# Drives the REAL claude binary (against the auth-free mock) into an
# AskUserQuestion selection overlay by having the mock emit an
# AskUserQuestion tool_use, then asserts monitor/pane-state.sh detects
# the chip-bar overlay as state=blocked (the dialog-guard Layer-B path:
# `Type something.` + `Chat about this`). This is the live analogue of
# the synthetic blocked-askuq fixture, proving the detection holds
# against the bytes the real TUI actually renders.
#
# Gated on RUN_CC_HARNESS=1 (+ node + a resolvable claude binary);
# self-skips otherwise. See monitor/cc-harness/README.md.

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_self_dir/../_test_helpers.sh"
. "$_self_dir/../../cc-harness/_lib.sh"

cch_skip_if_disabled
cch_setup

echo "=== real-binary harness: AskUserQuestion -> blocked ==="
win=$(cch_boot_worker w1)
[[ -n "$win" ]] || { echo "FAIL: worker window never appeared" >&2; exit 1; }
wait_for "boots to idle" 30 -- cch_state_is "$win" idle

# Arm the mock to answer with an AskUserQuestion tool_use, then prompt.
cch_control '{"mode":"tool_use","tool":{"name":"AskUserQuestion","input":{"questions":[{"question":"Which color should the demo use?","header":"Color","multiSelect":false,"options":[{"label":"Blue","description":"Calm and classic"},{"label":"Green","description":"Fresh and natural"},{"label":"Red","description":"Bold and energetic"}]}]}}}'
cch_send "$win" "ask me which color"

# The selection overlay renders the chip-bar that pane-state's
# dialog-guard recognises as blocked.
wait_for "AskUserQuestion overlay -> blocked" 20 -- cch_state_is "$win" blocked
pane=$(cch_capture "$win")
assert_contains "overlay shows the question" "$pane" "Which color"
assert_contains "overlay shows the free-form chip" "$pane" "Type something."

th_summary_and_exit
