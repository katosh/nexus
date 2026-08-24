#!/usr/bin/env bash
# test-realmodel-trust-dialog.sh — real-binary scenario for the STRUCTURAL
# select-dialog arm (`pane-state.sh:_has_menu_dialog_frame`,
# your-org/nexus-code#896).
#
# WHAT IT PINS. Claude Code's workspace-trust dialog used to classify
# `state=empty active=0` — "don't know yet" — so `_unstick.sh` never fired (its
# case_B needs `blocked`), the watcher saw an idle-looking window, and a worker
# that would NEVER proceed was indistinguishable from one that had merely not
# started. 2.1.232 turned that from a rarity into every spawn: nested git repos
# stopped inheriting trust from a parent, and every `work/<project>` is a nested
# repo. This scenario drives the REAL binary into that dialog and asserts the
# production classifier now reports `blocked` + `overlay=workspace-trust`.
#
# WHY THE INSTALLED PIN IS ENOUGH. 2.1.232 changed WHEN the dialog appears, not
# WHAT it renders — the gate that produces it (`hasTrustDialogAccepted` for the
# cwd) has been there for many releases, and `cc-harness/_lib.sh` pre-seeds it
# precisely so the harness never trips over it. Deleting that one key
# reproduces the frame on ANY version, including the 2.1.224 this repo pins. So
# the arm is exercised on every gate run rather than only while a candidate
# happens to be staged.
#
# THE FIXTURE-FRESHNESS ARM is the reason this file exists at all rather than a
# fixture alone. `fixtures/blocked-workspace-trust-realmodel.ansi` was CAPTURED
# from the live binary, not transcribed from a PR body — and a committed capture
# rots silently. Arm 3 re-derives the frame here and compares the rows the
# DETECTOR actually reads (the option rows and the navigation footer) against
# the committed copy. Prose rows are deliberately excluded: the detector never
# consults them, so a copy edit upstream should not paint this red, while a
# repaint of the menu chrome — the thing that would silently un-cover the class
# — must.
#
# Gated on RUN_CC_HARNESS=1 (+ node + a resolvable claude binary);
# self-skips otherwise. See monitor/cc-harness/README.md.

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_self_dir/../../.." && pwd)
. "$_self_dir/../_test_helpers.sh"
. "$_self_dir/../../cc-harness/_lib.sh"

FIXTURE="$_repo_root/monitor/watcher/fixtures/blocked-workspace-trust-realmodel.ansi"

cch_skip_if_disabled
cch_setup

# Strip ANSI, drop blank lines, trim trailing padding, and keep only the rows
# `_has_menu_dialog_frame` reads: numbered options (with or without the `❯`
# cursor) and the Enter/Esc navigation footer.
_detector_skeleton() {
    sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' \
        | sed -E 's/[[:space:]]+$//' \
        | grep -E '^[[:space:]]*(❯ +)?[0-9]+\.[[:space:]]|(Enter|Esc) to [a-z]'
}

echo "=== real-binary harness: workspace-trust dialog -> blocked ==="

# --- arm 1: the trust gate UNSEEDED -> the dialog, and it must be `blocked`.
# `cch_setup` seeds `projects.<cwd>.hasTrustDialogAccepted`; removing it is the
# ONLY difference from a normal harness boot, which is what makes arm 2 a
# controlled comparison rather than a second unrelated observation.
if command -v jq >/dev/null 2>&1; then
    jq 'del(.projects[].hasTrustDialogAccepted)' "$CCH_CFG/.claude.json" \
        > "$CCH_CFG/.claude.json.tmp" && mv "$CCH_CFG/.claude.json.tmp" "$CCH_CFG/.claude.json"
else
    echo "FAIL: jq unavailable — cannot un-seed the trust key" >&2
    exit 1
fi
assert_not_contains "trust key removed from the harness config" \
    "$(cat "$CCH_CFG/.claude.json")" "hasTrustDialogAccepted"

win=$(cch_boot_worker untrusted)
[[ -n "$win" ]] || { echo "FAIL: worker window never appeared" >&2; exit 1; }
wait_for "untrusted repo -> state=blocked" 30 -- cch_state_is "$win" blocked

live_state=$(cch_pane_state "$win")
assert_contains "the live dialog names itself" "$live_state" "overlay=workspace-trust"

live_pane=$(cch_capture "$win")
assert_contains "the live pane really is the trust dialog" "$live_pane" "trust this folder"

# --- arm 2: the CONTROL. Same binary, same harness, same window shape — put the
# one key back and the pane reaches idle. Without this arm, arm 1 would be
# consistent with "this harness cannot boot at all", which is a different bug.
cch_kill_claude "$win" >/dev/null 2>&1 || true
jq --arg wd "$CCH_WORKDIR" '.projects[$wd].hasTrustDialogAccepted = true' \
    "$CCH_CFG/.claude.json" > "$CCH_CFG/.claude.json.tmp" \
    && mv "$CCH_CFG/.claude.json.tmp" "$CCH_CFG/.claude.json"
ctrl=$(cch_boot_worker trusted)
[[ -n "$ctrl" ]] || { echo "FAIL: control window never appeared" >&2; exit 1; }
wait_for "trusted control -> boots to idle" 30 -- cch_state_is "$ctrl" idle
assert_not_contains "the control pane carries no overlay claim" \
    "$(cch_pane_state "$ctrl")" "overlay="

# --- arm 3: the committed fixture still matches what the binary renders.
assert_file_exists "the captured fixture is committed" "$FIXTURE"
live_skel=$(printf '%s\n' "$live_pane" | _detector_skeleton)
fix_skel=$(_detector_skeleton < "$FIXTURE")
# Non-vacuity first: an empty skeleton on BOTH sides would compare equal and
# assert nothing — the silent-zero shape this repo keeps re-finding.
if [[ -z "$live_skel" ]]; then
    echo "FAIL: the live pane yielded an EMPTY detector skeleton — the comparison below would be vacuous" >&2
    _th_fail
else
    assert_eq "the fixture's detector-relevant rows match the live binary's" "$fix_skel" "$live_skel"
fi

# And the committed fixture classifies the same way the live pane just did, run
# through the same production classifier.
fix_state=$("$CCH_PANE_STATE" --fixture "$FIXTURE" --window 9 --name fixwin --active 0 2>&1)
assert_contains "the committed fixture classifies blocked" "$fix_state" "state=blocked"
assert_contains "…with the same overlay kind as the live pane" "$fix_state" "overlay=workspace-trust"

# EXPECTED-COUNT GUARD. The ledger proves no assertion's FAILURE was lost to a
# subshell; it cannot prove an assertion never RAN. This scenario is a live-binary
# run whose middle arms are reached only if the earlier `wait_for`s succeed, so a
# silently short run is the realistic failure — and it would otherwise report a
# clean green over fewer assertions than it claims.
#
# Derived rather than pinned to a literal: 1 config precondition + 2 in arm 1
# + 1 control assertion in arm 2 + 1 file-exists + 1 skeleton comparison
# (whichever branch is taken, exactly one outcome) + 2 fixture classification
# + 1 arm-2 idle wait + 1 arm-1 blocked wait = 10. Every skip path exits through
# `cch_skip_if_disabled` long before here, so by this point all arms have run.
#
# Added because your-org/nexus-code#872 raises `summary-honesty.manifest`'s
# standard: a `ledger=yes` suite now also needs `count=exact`. Fixed here rather
# than by appending a manifest line — the guard's own message is explicit that a
# new suite appending its own opt-out is the thing not to do.
EXPECTED=$(( 1 + 2 + 1 + 1 + 1 + 2 + 1 + 1 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
