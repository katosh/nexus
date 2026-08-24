#!/usr/bin/env bash
# Tests for `wait_for`'s failure-path diagnostic in monitor/cc-harness/_lib.sh
# (your-org/nexus-code#768).
#
# THE PROPERTY. When a `cch_state_is` wait expires, the failure must say WHAT
# STATE IT SAW, not merely that the wait expired.
#
# WHY IT IS WORTH A TEST. A bare timeout invites the reading "slow runner", and
# that reading is what #768 cost: a control boot was wedged on the Bypass
# Permissions modal for the whole wait, the pane reported `state=empty` — which
# means "don't know yet", never "finished" — and nothing printed the state at
# all. Three probe cells were written up as "VI mode is unreachable" and were
# nothing of the kind. The modal now classifies as `blocked
# overlay=bypass-permissions`, but a name nobody prints is not a diagnosis, so
# the emit is the other half of the fix and is asserted here.
#
# FULLY HERMETIC — no claude binary, no node, no tmux, no network. `_lib.sh` is
# safe to source (definitions and path resolution only), and `cch_pane_state`
# is stubbed, so this exercises the real `wait_for` against synthetic pane
# lines. That is the point: the diagnostic lives on a path only reached when a
# real scenario FAILS, which is exactly the path a passing gate run never
# covers and which would otherwise ship unexercised.
#
# Run: bash monitor/watcher/test-cc-harness-waitfor-diagnostic.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)

PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

# shellcheck source=/dev/null
. "$REPO_ROOT/monitor/cc-harness/_lib.sh"

# The stub `wait_for` will consult. `cch_state_is` calls `cch_state`, which
# calls `cch_pane_state`; overriding the innermost one keeps the real
# extraction (`sed -n 's/.*state=\([^ ]*\).*/\1/p'`) in play, so a change that
# broke state parsing would surface here too.
STUB_LINE=""
cch_pane_state() { printf '%s\n' "$STUB_LINE"; }

# Run a 1-second `wait_for` against a predicate that can never hold, and return
# its stderr. PASS/FAIL are locals to this file, so save and restore the
# counters `wait_for` increments on its way through.
run_expired_wait() {
    local want="$1" err saved_pass=$PASS saved_fail=$FAIL
    err=$(wait_for "probe" 1 -- cch_state_is win9 "$want" 2>&1 >/dev/null)
    PASS=$saved_pass; FAIL=$saved_fail
    printf '%s' "$err"
}

# --- 1. the wedged case: the modal is named and the remedy is given ---------
STUB_LINE='state=blocked active=1 window=9 name=vim0 overlay=bypass-permissions content_hash=1'
err=$(run_expired_wait idle)
if grep -qF 'observed: state=blocked' <<<"$err" \
   && grep -qF 'overlay=bypass-permissions' <<<"$err"; then
    ok "an expired wait prints the observed pane-state line"
else
    bad "observed line" "expected the full pane-state line on stderr, got:
$err"
fi
if grep -qF 'wedged on the Bypass Permissions modal, NOT slow' <<<"$err" \
   && grep -qF 'skipDangerousModePermissionPrompt' <<<"$err"; then
    ok "the bypass-permissions case names the modal AND the re-seed remedy"
else
    bad "bypass remedy" "expected the modal diagnosis + remedy on stderr, got:
$err"
fi

# --- 2. the pre-#768 signature must NOT claim the modal --------------------
# `empty` is what this failure looked like before the overlay arm existed. The
# diagnostic must still print what it saw, but must NOT assert a cause it has
# no evidence for — inventing a confident wrong diagnosis is worse than the
# silence it replaces.
STUB_LINE='state=empty active=1 window=9 name=vim0 content_hash=2'
err=$(run_expired_wait idle)
if grep -qF 'observed: state=empty' <<<"$err"; then
    ok "a non-overlay timeout still reports the observed state"
else
    bad "observed line (empty)" "expected 'observed: state=empty', got:
$err"
fi
if grep -qF 'Bypass Permissions modal' <<<"$err"; then
    bad "false attribution" "claimed the bypass modal for a plain state=empty:
$err"
else
    ok "a plain state=empty is NOT attributed to the bypass modal"
fi

# --- 3. a different overlay is reported as itself --------------------------
STUB_LINE='state=blocked active=1 window=9 name=w overlay=permission content_hash=3'
err=$(run_expired_wait idle)
if grep -qF 'overlay=permission' <<<"$err" \
   && ! grep -qF 'Bypass Permissions modal' <<<"$err"; then
    ok "a permission overlay is reported as itself, not as the bypass modal"
else
    bad "overlay discrimination" "expected overlay=permission and no bypass claim, got:
$err"
fi

# --- 4. anti-vacuous: the diagnostic is absent when the wait SUCCEEDS -------
# If the emit fired unconditionally, cases 1-3 would pass while telling us
# nothing. Assert the success path stays quiet.
STUB_LINE='state=idle active=1 window=9 name=w input=blank content_hash=4'
saved_pass=$PASS; saved_fail=$FAIL
out=$(wait_for "probe" 5 -- cch_state_is win9 idle 2>&1)
rc=$?
PASS=$saved_pass; FAIL=$saved_fail
if (( rc == 0 )) && ! grep -qF 'observed:' <<<"$out"; then
    ok "a satisfied wait emits no diagnostic (the emit is failure-path only)"
else
    bad "anti-vacuous guard" "rc=$rc; success path should be quiet, got:
$out"
fi

# --- 5. a non-cch_state_is predicate is left alone -------------------------
# `wait_for` is generic. The diagnostic keys on the predicate's name, so a
# different predicate must not be handed a window index that is not there.
saved_pass=$PASS; saved_fail=$FAIL
err=$(wait_for "probe" 1 -- false 2>&1 >/dev/null)
PASS=$saved_pass; FAIL=$saved_fail
if grep -qF 'predicate never satisfied' <<<"$err" && ! grep -qF 'observed:' <<<"$err"; then
    ok "a non-cch_state_is predicate still fails cleanly, with no observed line"
else
    bad "generic predicate" "expected a clean expiry with no observed line, got:
$err"
fi

echo
printf '=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then echo "ALL TESTS PASSED"; exit 0; fi
echo "FAILED" >&2; exit 1
