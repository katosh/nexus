#!/usr/bin/env bash
# test-realmodel-hooks.sh — closes the 2d hole the cc-harness gate leaves
# open.
#
# The gate's other renderer scenarios boot the candidate WITHOUT
# `--settings`, so the hook-event contract the whole nexus control
# surface rides on is never exercised against the candidate there. A
# renamed event, a changed matcher schema, or a dropped exit-2 block
# would pass the gate green and silently disable the watcher's eyes.
#
# This scenario boots the REAL candidate with a `--settings` file whose
# hooks write marker files, drives a tool call from the mock, and asserts:
#   * UserPromptSubmit, PreToolUse and Stop hooks still FIRE
#   * a PreToolUse hook that exits 2 still BLOCKS the tool call
#     (the load-bearing AskUserQuestion guard, monitor/hooks/block-askuserquestion.sh)
#   * the `"matcher"` regex-alternation syntax still selects
#
# Gated on RUN_CC_HARNESS=1 (+ node + a resolvable claude binary);
# self-skips otherwise. See monitor/cc-harness/README.md.
#
# Run: RUN_CC_HARNESS=1 CLAUDE_BIN=<candidate> bash test-realmodel-hooks.sh
set -uo pipefail

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_self_dir/../../.." && pwd)
. "$_self_dir/../_test_helpers.sh"
. "$_self_dir/../../cc-harness/_lib.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

cch_skip_if_disabled
cch_setup
trap cch_teardown EXIT

echo "=== real-binary harness: hook + settings contract (2d) ==="
echo "    claude:  $CLAUDE_BIN ($("$CLAUDE_BIN" --version 2>&1 | head -1))"

MK="$CCH_DIR/hookmarks"; mkdir -p "$MK"
SETTINGS="$CCH_DIR/hook-settings.json"
cat > "$SETTINGS" <<JSON
{
  "skipDangerousModePermissionPrompt": true,
  "env": { "DISABLE_AUTOUPDATER": "1" },
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "touch $MK/userpromptsubmit" } ] }
    ],
    "PreToolUse": [
      { "matcher": "Bash|Write|Edit|NotebookEdit",
        "hooks": [ { "type": "command",
                     "command": "touch $MK/pretooluse-matched; echo 'BLOCKED-BY-TEST-HOOK' >&2; exit 2" } ] }
    ],
    "PostToolUse": [
      { "matcher": "Bash",
        "hooks": [ { "type": "command", "command": "touch $MK/posttooluse-bash" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "touch $MK/stop" } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command", "command": "touch $MK/notification" } ] }
    ]
  }
}
JSON

# Boot WITH --settings (the two-argument form of cch_boot_worker; the
# one-argument renderer path deliberately carries no hooks).
WIN=hooks
IDX=$(cch_boot_worker "$WIN" "$SETTINGS")
[[ -n "$IDX" ]] || { bad "window did not open"; echo "=== summary: $PASS passed, $FAIL failed ==="; exit 1; }

wait_for "candidate booted to idle WITH --settings" 60 -- cch_state_is "$IDX" idle \
    || { cch_capture "$IDX" | tail -15 >&2; echo "=== summary: $PASS passed, $FAIL failed ==="; exit 1; }

# Ask the mock to answer the next request with a Bash tool_use block.
cch_control '{"mode":"tool_use","text":"running it","tool":{"name":"Bash","input":{"command":"echo hook-contract-probe"}}}'

# The prompt goes in through the harness's own injector, not a
# production paste helper. This scenario pins the HOOK contract; paste
# delivery is pinned by test-realmodel-paste-held.sh, and the production
# helpers refuse to paste into a pane they cannot prove live on the
# PRODUCTION socket — which a harness pane, on its private socket, never
# is.
cch_send "$IDX" "run the probe command"

_mark() { [[ -e "$MK/$1" ]]; }
wait_for "UserPromptSubmit hook FIRED" 30 -- _mark userpromptsubmit
wait_for "PreToolUse hook FIRED and its matcher regex selected Bash" 45 -- _mark pretooluse-matched

# ---- the exit-2 block, asserted behind a turn-end BARRIER -------------
#
# The exit-2 block is the load-bearing contract: if it stopped blocking,
# the orchestrator's AskUserQuestion guard is silently dead. A blocked
# call must NOT reach PostToolUse.
#
# "PostToolUse never fired" is a NEGATIVE assertion about an ASYNCHRONOUS
# event, so it is only sound behind an event that ORDERS AFTER it. A
# fixed sleep is not that event: this scenario first shipped with
# `sleep 6`, and the skeptic pass on Claude Code 2.1.273 measured the
# real delay to PostToolUse at about 9 s. With the block removed the
# tool RAN and the assertion still passed, 3 runs of 3.
#
# The barrier used instead is the Stop hook. In BOTH arms it orders
# after PostToolUse would fire: the tool result (or the block feedback)
# goes back to the model, the model answers, and only then does the turn
# end. So `Stop fired` proves the tool-call round trip is complete, and
# the absence of the PostToolUse marker at that point is real, on any
# host, at any speed.
#
# Getting to Stop needs one harness step first: while the control file
# still says `tool_use` the mock re-emits the blocked call on every
# request and the turn never ends. That is a HARNESS artifact, not a
# candidate defect — switch the mock back to plain text, then wait.
cch_control '{"mode":"text","text":"done"}'
wait_for "Stop hook FIRED at turn end" 120 -- _mark stop

# hold_false, not a bare `[[ -e ]]`: the barrier orders the marker, but
# a hook command is a forked process and the touch lands whenever the
# fork is scheduled. The slack between the barrier and the check was
# measured at 0.19 s, which bounds nothing. The hold keeps the negative
# true for a window AFTER the ordering event, so a late marker fails the
# assertion instead of arriving unobserved. It fails on the FIRST poll
# if the marker is already there, so the blocked-arm cost is 5 s and the
# broken-arm cost is nothing.
hold_false "PreToolUse exit 2 still BLOCKS the tool call (no PostToolUse through turn end)" 5 \
    -- _mark posttooluse-bash

# Control: the marker directory must not report a hook that was never
# wired, so an `[[ -e ]]` that always succeeds cannot fake the passes.
if _mark neverwired; then
    bad "control: an unwired hook marker exists — the assertion is not specific"
else
    ok "control: an unwired hook marker does not exist"
fi

echo "    markers present: $(ls "$MK" 2>/dev/null | tr '\n' ' ')"
echo "=== summary: $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
