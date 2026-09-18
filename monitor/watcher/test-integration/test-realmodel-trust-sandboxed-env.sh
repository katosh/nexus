#!/usr/bin/env bash
# test-realmodel-trust-sandboxed-env.sh — CANARY for the undocumented env var
# spawn-worker.sh's launchers set to keep workers off the workspace-trust
# dialog (your-org/nexus-code#1334).
#
# WHAT IT PINS. Claude Code (measured at 2.1.261) reads `CLAUDE_CODE_SANDBOXED`
# at the head of its trust gate and returns "trusted" before the config key
# `projects.<cwd>.hasTrustDialogAccepted` is consulted. The nexus sets it on
# every worker's claude invocation — truthfully: workers run under a
# kernel-enforced sandbox — so the dialog cannot appear whatever happened to
# the seed. That is a claim about an UNDOCUMENTED flag read at three sites in a
# binary this repo re-pins weekly, so an upstream change would be SILENT: the
# dialog simply comes back, intermittently, in the field. This suite makes
# that a RED on the next cc bump instead. It belongs on
# skills/nexus.cc-update/GUIDE.md's collision list.
#
# THREE ARMS, and the first is the control that makes the second mean anything:
#   1. key ABSENT, env UNSET, real worker configuration -> the dialog
#      (`state=blocked overlay=workspace-trust`). Proves the gate is live in
#      this harness — without it, arm 2's idle could be "the gate is gone".
#   2. key ABSENT, env SET, same configuration -> idle, no overlay claim.
#      THE CANARY. Red here = the flag's semantics moved upstream; the
#      recovery loop in spawn-worker.sh is then the only thing standing, and
#      the pin bump must not proceed without a decision.
#   3. the flag is actually in PRODUCTION's launcher templates, in command
#      position, at all three sites — so this suite is a canary for what
#      workers run, not for a flag nobody sets.
#
# Real worker configuration means `--dangerously-skip-permissions` (the
# harness always passes it) plus `monitor/worker-settings.json` via
# CCH_SETTINGS — the two things that were measured to make the flag's OTHER
# two sites unobservable (spawn-worker.sh, "PRIMARY FIX" paragraph).
#
# Gated on RUN_CC_HARNESS=1 (+ node + a resolvable claude binary);
# self-skips otherwise. See monitor/cc-harness/README.md.
set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_self_dir/../../.." && pwd)
. "$_self_dir/../_test_helpers.sh"
. "$_self_dir/../../cc-harness/_lib.sh"

cch_skip_if_disabled
cch_setup

WS="$_repo_root/monitor/worker-settings.json"
[[ -r "$WS" ]] || { echo "FAIL: worker-settings.json unreadable at $WS" >&2; exit 1; }
CFG="$CCH_CFG/.claude.json"
trust_of() { jq -r --arg d "$1" '.projects[$d].hasTrustDialogAccepted // "ABSENT"' "$CFG" 2>/dev/null; }
del_key() {
    jq --arg wd "$1" 'del(.projects[$wd].hasTrustDialogAccepted)' "$CFG" > "$CFG.tmp" \
        && mv "$CFG.tmp" "$CFG"
}
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq unavailable — cannot un-seed the trust key" >&2; exit 1; }

echo "=== real-binary canary: CLAUDE_CODE_SANDBOXED=1 keeps a worker off the trust dialog ==="

# --- arm 1: CONTROL — the gate is live: key absent, env unset -> the dialog.
del_key "$CCH_WORKDIR"
assert_eq "precondition: the trust key is ABSENT for the workdir" "$(trust_of "$CCH_WORKDIR")" "ABSENT"
ctrl=$(CCH_SETTINGS="$WS" cch_boot_worker unseeded)
[[ -n "$ctrl" ]] || { echo "FAIL: control window never appeared" >&2; exit 1; }
wait_for "control (key absent, env unset) -> state=blocked" 30 -- cch_state_is "$ctrl" blocked
assert_contains "…and it is the workspace-trust dialog" "$(cch_pane_state "$ctrl")" "overlay=workspace-trust"
cch_kill_claude "$ctrl" >/dev/null 2>&1 || true

# --- arm 2: THE CANARY — same key state, the flag set -> idle, no dialog.
assert_eq "the key is still ABSENT before the canary boots" "$(trust_of "$CCH_WORKDIR")" "ABSENT"
can=$(CCH_SETTINGS="$WS" CCH_EXTRA_ENV="CLAUDE_CODE_SANDBOXED=1" cch_boot_worker sandboxed)
[[ -n "$can" ]] || { echo "FAIL: canary window never appeared" >&2; exit 1; }
wait_for "canary (key absent, CLAUDE_CODE_SANDBOXED=1) -> state=idle" 30 -- cch_state_is "$can" idle
assert_not_contains "the canary pane carries no overlay claim" "$(cch_pane_state "$can")" "overlay="
assert_not_contains "the canary pane never painted the dialog" "$(cch_capture "$can")" "trust this folder"
# The flag skips the gate; it does not WRITE the key. Recorded so nobody reads
# a later ABSENT as "the flag stopped working" — the seeder still writes it.
assert_eq "the flag does not write the key (still ABSENT after an idle boot)" "$(trust_of "$CCH_WORKDIR")" "ABSENT"
cch_kill_claude "$can" >/dev/null 2>&1 || true

# --- arm 3: production actually sets it, in command position, at every site.
SPAWN="$_repo_root/monitor/spawn-worker.sh"
assert_eq "spawn-worker.sh sets CLAUDE_CODE_SANDBOXED=1 on all three launcher templates" \
    "$(grep -cE '^(export )?CLAUDE_CODE_SANDBOXED=1( |$)' "$SPAWN")" "3"

# EXPECTED-COUNT GUARD (your-org/nexus-code#872: ledger=yes needs count=exact).
# 1 precondition + 1 wait + 1 overlay in arm 1; 1 precondition + 1 wait + 2
# pane assertions + 1 key assertion in arm 2; 1 structural in arm 3.
EXPECTED=9
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi
th_summary_and_exit
