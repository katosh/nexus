#!/usr/bin/env bash
# monitor/watcher/test-bash-footgun-guard.sh
#
# Unit tests for the just-in-time footgun hook (proposal: worker-floor
# redesign). Verifies that bash-footgun-guard.sh injects the right
# reminder as PreToolUse `additionalContext` when a worker's Bash
# command matches a footgun, stays silent otherwise, dedups per
# (window, tag), and passes benign / non-Bash calls through.

set -u
_test_dir=$(cd "$(dirname "$0")" && pwd)
HOOK="$_test_dir/../hooks/bash-footgun-guard.sh"
CONF="$_test_dir/../bash-footgun-patterns.conf"

PASS=0; FAIL=0
STATE=$(mktemp -d)
trap 'rm -rf "$STATE"' EXIT
export NEXUS_ROOT="$_test_dir/../.."
export NEXUS_STATE_DIR="$STATE"
export NEXUS_FOOTGUN_PATTERNS="$CONF"
export NEXUS_WORKER_WINDOW="footgun-test"

# run <payload-json> → prints hook stdout, sets RC
run() { OUT=$(printf '%s' "$1" | bash "$HOOK"); RC=$?; }

assert_ctx() { # <desc> <substring>  (additionalContext must contain substring, exit 0)
    if [[ $RC -eq 0 && "$OUT" == *"$2"* ]]; then
        printf '  PASS: %s\n' "$1"; PASS=$((PASS+1))
    else
        printf '  FAIL: %s (rc=%s out=%q)\n' "$1" "$RC" "$OUT" >&2; FAIL=$((FAIL+1))
    fi
}
assert_silent() { # <desc>  (no stdout, exit 0)
    if [[ $RC -eq 0 && -z "$OUT" ]]; then
        printf '  PASS: %s\n' "$1"; PASS=$((PASS+1))
    else
        printf '  FAIL: %s (rc=%s out=%q)\n' "$1" "$RC" "$OUT" >&2; FAIL=$((FAIL+1))
    fi
}

echo '=== conf-driven footgun matches inject additionalContext ==='
run '{"tool_name":"Bash","tool_input":{"command":"pkill -f my-task-marker"}}'
assert_ctx "pkill -f fires self-kill reminder" "self-kill"
run '{"tool_name":"Bash","tool_input":{"command":"cd a && git push origin x"}}'
assert_ctx "git push fires wrong-remote reminder" "git -C <clone> push"
run '{"tool_name":"Bash","tool_input":{"command":"scancel --name myjob"}}'
assert_ctx "scancel --name fires sibling-job reminder" "scancel <jobid>"
run '{"tool_name":"Bash","tool_input":{"command":"kill $(jobs -p)"}}'
assert_ctx "kill \$(jobs -p) fires empty-jobtable reminder" "no-ops and leaks"
run '{"tool_name":"Bash","tool_input":{"command":"sleep 30 && echo done"}}'
assert_ctx "foreground sleep fires Monitor reminder" "until-loop"

echo '=== in-code pipe-triggered footguns (cannot live in the |-conf) ==='
run '{"tool_name":"Bash","tool_input":{"command":"python train.py | tail -20"}}'
assert_ctx "python | tail fires block-buffer reminder" "python -u"
run '{"tool_name":"Bash","tool_input":{"command":"ml Python | tail"}}'
assert_ctx "ml | tail fires eval-loss reminder" "forks a subshell"

echo '=== dedup: same (window, tag) fires at most once ==='
run '{"tool_name":"Bash","tool_input":{"command":"pgrep -f other-marker"}}'
assert_silent "second pkill-family call is silent (already seen)"

echo '=== pass-through: benign and non-Bash calls ==='
run '{"tool_name":"Bash","tool_input":{"command":"ls -la && grep foo bar"}}'
assert_silent "benign command injects nothing"
run '{"tool_name":"Read","tool_input":{"file_path":"/x"}}'
assert_silent "non-Bash tool is skipped"

echo '=== output is valid JSON on a match ==='
# Every conf tag has already fired for window "footgun-test" above, so the
# per-(window,tag) dedup would (correctly) silence a repeat here — leaving
# nothing to validate. Switch to a fresh window to exercise a clean
# first-fire. The `-n "$OUT"` guard makes the assertion reject an empty
# capture regardless of jq version: jq 1.5 exits 0 on empty stdin (masking
# a silenced fire), newer jq errors — so empty must fail explicitly.
export NEXUS_WORKER_WINDOW="footgun-json-check"
run '{"tool_name":"Bash","tool_input":{"command":"scancel --partition foo"}}'
if [[ -n "$OUT" ]] && printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1; then
    printf '  PASS: additionalContext is valid hookSpecificOutput JSON\n'; PASS=$((PASS+1))
else
    printf '  FAIL: additionalContext JSON malformed: %q\n' "$OUT" >&2; FAIL=$((FAIL+1))
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && { echo "ALL TESTS PASSED"; exit 0; }
exit 1
