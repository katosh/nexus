#!/usr/bin/env bash
# Validation harness for monitor/hooks/block-askuserquestion.sh
# (Layer A1 of the dialog-guard — see PR #TODO and
# monitor/agent-prompt.md).
#
# The hook is wired as a Claude Code `PreToolUse` matcher
# (`AskUserQuestion`) in `monitor/orchestrator-settings.json`. A
# `PreToolUse` hook exiting code 2 BLOCKS the tool call at the API
# level: the agent cannot dispatch `AskUserQuestion`. The hook's
# stderr is surfaced as the tool-error result so the agent sees why
# and routes the question via GitHub instead.
#
# This test feeds the hook a synthetic Claude Code hook input on
# stdin and asserts exit code 2 + the BLOCKED stderr message.
# Mirrors the test pattern in test-unstick.sh / test-pane-state.sh
# (zero-dep, hand-rolled assertions).
#
# Run: bash monitor/watcher/test-block-askuserquestion-hook.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
HOOK="$_repo_root/monitor/hooks/block-askuserquestion.sh"

PASS=0
FAIL=0

assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s (got %q)\n' "$label" "$got"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s: got %q, want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         expected to find: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

[[ -x "$HOOK" ]] || { echo "hook not executable: $HOOK" >&2; exit 1; }

# ---- canonical PreToolUse payload (AskUserQuestion) -----------------------
echo '=== canonical PreToolUse: AskUserQuestion → exit 2 + BLOCKED stderr ==='
payload='{"session_id":"sess-1234","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which approach should we take?","header":"Approach","options":[{"label":"A","description":"first"},{"label":"B","description":"second"}]}]}}'
err_file=$(mktemp)
out_file=$(mktemp)
printf '%s' "$payload" | "$HOOK" >"$out_file" 2>"$err_file"
rc=$?
stderr_content=$(<"$err_file")
stdout_content=$(<"$out_file")
rm -f "$err_file" "$out_file"

assert_eq "exit code is 2 (blocks the tool call)" "$rc" "2"
assert_contains "stderr starts with BLOCKED:"        "$stderr_content" "BLOCKED:"
assert_contains "stderr names AskUserQuestion"       "$stderr_content" "AskUserQuestion"
# The load-bearing reason — the paste channel must stay open. Keeps
# the assertion stable against later wording softenings (the rule
# isn't "talk only via GitHub"; the operator does chat in-pane too).
assert_contains "stderr names the paste channel"     "$stderr_content" "paste channel"
assert_contains "stderr names the tracking issue"    "$stderr_content" "tracking issue"
assert_contains "stderr names sandbox-notify"        "$stderr_content" "sandbox-notify"
[[ -z "$stdout_content" ]] \
    && { echo "  PASS: stdout is empty (hook is stderr-only)"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: stdout should be empty; got: $stdout_content" >&2; FAIL=$((FAIL+1)); }

# ---- empty / malformed payloads (defensive) ------------------------------
echo '=== empty stdin still blocks (hook is payload-agnostic) ==='
err_file=$(mktemp)
"$HOOK" </dev/null 2>"$err_file"
rc=$?
stderr_content=$(<"$err_file")
rm -f "$err_file"
assert_eq "empty stdin still exits 2" "$rc" "2"
assert_contains "empty stdin still emits BLOCKED" "$stderr_content" "BLOCKED"

echo '=== unrelated tool payload still blocks (matcher is the orchestrator-settings gate) ==='
# The hook itself is unconditional — the `matcher` field in
# orchestrator-settings.json is what scopes it to AskUserQuestion.
# Hook code path is therefore the same regardless of payload shape;
# this test documents that contract.
payload='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"}}'
err_file=$(mktemp)
printf '%s' "$payload" | "$HOOK" 2>"$err_file"
rc=$?
stderr_content=$(<"$err_file")
rm -f "$err_file"
assert_eq "unrelated payload still exits 2" "$rc" "2"
assert_contains "stderr is unchanged" "$stderr_content" "BLOCKED:"

# ---- settings.json wiring ------------------------------------------------
echo '=== orchestrator-settings.json wires the hook with matcher AskUserQuestion ==='
SETTINGS="$_repo_root/monitor/orchestrator-settings.json"
[[ -f "$SETTINGS" ]] || { echo "settings file missing: $SETTINGS" >&2; exit 1; }
if command -v jq >/dev/null 2>&1; then
    matcher=$(jq -r '.hooks.PreToolUse[0].matcher // empty' "$SETTINGS")
    cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command // empty' "$SETTINGS")
    assert_eq "matcher is AskUserQuestion" "$matcher" "AskUserQuestion"
    assert_contains "command points at block-askuserquestion.sh" "$cmd" "monitor/hooks/block-askuserquestion.sh"
else
    # jq absent — grep fallback. Both tokens must appear inside the
    # PreToolUse block. Crude but adequate for this wiring smoke-test.
    content=$(<"$SETTINGS")
    assert_contains "settings carries PreToolUse block"            "$content" '"PreToolUse"'
    assert_contains "settings names matcher AskUserQuestion"       "$content" '"matcher": "AskUserQuestion"'
    assert_contains "settings names block-askuserquestion.sh"      "$content" "block-askuserquestion.sh"
fi

# ---- Summary -----------------------------------------------------------
echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
