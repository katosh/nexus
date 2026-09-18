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
# From 2.1.248 the same regression returned by a different route — see the
# freshness-arm note below — so the assertion is now made against TWO
# committed renderings of the dialog, not one.
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

# TWO committed captures, because the dialog has TWO renderings in the release
# range this repo spans and the scenario must pin BOTH (your-org/nexus-code#1112):
#
#   ...-realmodel.ansi      captured 2026-08-14 at 311430b2 from 2.1.224-era
#                           rendering — ` \u276f 1. Yes, I trust this folder`
#                           / `   2. No, exit`. Still what the operator's pin
#                           (2.1.246) paints.
#   ...-realmodel-248.ansi  captured 2026-08-30 from a 2.1.248 install in a
#                           throwaway prefix. Same dialog, ordinals DROPPED and
#                           options reordered — ` \u276f No, exit` / `   Yes, I
#                           trust this folder`.
#
# Arm 3 below therefore asks whether the live binary's frame matches ANY
# committed capture, not one nominated in advance. A THIRD rendering matches
# neither and paints this red, which is the whole job.
FIXTURES=(
    "$_repo_root/monitor/watcher/fixtures/blocked-workspace-trust-realmodel.ansi"
    "$_repo_root/monitor/watcher/fixtures/blocked-workspace-trust-realmodel-248.ansi"
)

cch_skip_if_disabled
cch_setup

# Strip ANSI, trim trailing padding, and keep only the rows
# `_has_menu_dialog_frame` reads: the `❯` cursor row, every row COLUMN-ALIGNED
# with it (its sibling options), and the Enter/Esc navigation footer.
#
# THE COLUMN IS DERIVED FROM THE PANE, not assumed — same arithmetic the
# detector does, so a repaint that moves the option column shows up here as a
# changed skeleton rather than being silently normalised away. Ordinals are no
# longer part of the shape (your-org/nexus-code#1112): keying the freshness
# check on them is what made this arm report a footer-only skeleton on 2.1.248
# instead of naming the drift.
_detector_skeleton() {
    local plain
    plain=$(sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' | sed -E 's/[[:space:]]+$//')
    local sel lead rest gap col
    sel=$(grep -E '^ *❯ +[^ ]' <<<"$plain" | tail -1)
    if [[ -z "$sel" ]]; then
        # No cursor row at all. Emit the footer alone rather than nothing, so
        # the comparison below still has something to disagree about — and so
        # the skeleton VISIBLY degenerates instead of going empty, which is the
        # shape the non-vacuity check downstream is watching for.
        grep -E '(Enter|Esc) to [a-z]' <<<"$plain"
        return 0
    fi
    lead=${sel%%❯*}; rest=${sel#*❯}; gap=${rest%%[! ]*}
    col=$(( ${#lead} + 1 + ${#gap} ))
    grep -E "^ *❯ +[^ ]|^ {$col}[^ ]|(Enter|Esc) to [a-z]" <<<"$plain"
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

# --- arm 3: SOME committed fixture still matches what the binary renders.
#
# Not a nominated one: the release stream carries two renderings of this dialog
# (see FIXTURES above), and which one the binary paints is exactly the thing
# under test. So the question is "is the live frame one we have on file?" — a
# THIRD rendering matches neither and paints this red, which is what caught
# #1112 in the first place.
for _fx in "${FIXTURES[@]}"; do
    assert_file_exists "the captured fixture is committed: $(basename "$_fx")" "$_fx"
done
live_skel=$(printf '%s\n' "$live_pane" | _detector_skeleton)
# Non-vacuity first: an empty skeleton on BOTH sides would compare equal and
# assert nothing — the silent-zero shape this repo keeps re-finding.
if [[ -z "$live_skel" ]]; then
    echo "FAIL: the live pane yielded an EMPTY detector skeleton — the comparison below would be vacuous" >&2
    _th_fail
else
    matched=""; want_skel=""
    for _fx in "${FIXTURES[@]}"; do
        fix_skel=$(_detector_skeleton < "$_fx")
        if [[ "$fix_skel" == "$live_skel" ]]; then
            matched=$(basename "$_fx"); want_skel="$fix_skel"; break
        fi
    done
    if [[ -z "$matched" ]]; then
        # Nothing on file matches. Fall back to the NEWEST capture as `want` so
        # the failure prints a real diff against the most recent rendering,
        # which is the one a new drift is most likely measured against.
        matched="NONE — diffed against the newest capture"
        want_skel=$(_detector_skeleton < "${FIXTURES[$(( ${#FIXTURES[@]} - 1 ))]}")
    fi
    # NOTE THE ARGUMENT ORDER — assert_eq is (label, GOT, WANT), and this call
    # site used to pass the FIXTURE as `got` and the LIVE binary as `want`, so
    # its failure text read exactly backwards from its label. Under #1112 that
    # printed the committed 2.1.246 rows as `got` and the live 2.1.248 footer as
    # `want`, i.e. it named the fixture as the thing that had changed. `got` is
    # what we OBSERVED — the live binary; `want` is the committed corpus.
    assert_eq "the live binary's detector-relevant rows match a committed capture ($matched)" \
        "$live_skel" "$want_skel"
fi

# And EVERY committed fixture still classifies the way the live pane just did,
# run through the same production classifier. Both, not just the matching one:
# the operator's pin is 2.1.246 and the candidate stream is >=2.1.248, so a fix
# that trades one rendering for the other must not pass here.
for _fx in "${FIXTURES[@]}"; do
    fix_state=$("$CCH_PANE_STATE" --fixture "$_fx" --window 9 --name fixwin --active 0 2>&1)
    assert_contains "the committed fixture classifies blocked: $(basename "$_fx")" "$fix_state" "state=blocked"
    assert_contains "…with the same overlay kind as the live pane: $(basename "$_fx")" "$fix_state" "overlay=workspace-trust"
done

# EXPECTED-COUNT GUARD. The ledger proves no assertion's FAILURE was lost to a
# subshell; it cannot prove an assertion never RAN. This scenario is a live-binary
# run whose middle arms are reached only if the earlier `wait_for`s succeed, so a
# silently short run is the realistic failure — and it would otherwise report a
# clean green over fewer assertions than it claims.
#
# Derived rather than pinned to a literal, and derived from ${#FIXTURES[@]} so
# committing a third capture cannot leave this guard silently short: 1 config
# precondition + 2 in arm 1 + 1 control assertion in arm 2 + one file-exists PER
# fixture + 1 skeleton comparison (whichever branch is taken, exactly one
# outcome) + two classification assertions PER fixture + 1 arm-2 idle wait
# + 1 arm-1 blocked wait. Every skip path exits through `cch_skip_if_disabled`
# long before here, so by this point all arms have run.
#
# Added because your-org/nexus-code#872 raises `summary-honesty.manifest`'s
# standard: a `ledger=yes` suite now also needs `count=exact`. Fixed here rather
# than by appending a manifest line — the guard's own message is explicit that a
# new suite appending its own opt-out is the thing not to do.
EXPECTED=$(( 1 + 2 + 1 + ${#FIXTURES[@]} + 1 + 2 * ${#FIXTURES[@]} + 1 + 1 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
