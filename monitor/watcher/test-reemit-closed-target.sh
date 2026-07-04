#!/usr/bin/env bash
# Tests for the CLOSED/MERGED-target terminal-ack (your-org/nexus-code#384):
# a non-operator 👀 on a cross-repo mention whose target issue/PR is closed/
# merged is TERMINAL — `_reemit_gc` evicts it instead of parking it on the
# slow tier forever. Hermetic: no live GitHub — both the reactions query
# (`_reemit_reaction_state`) AND the target-state query (`_reemit_target_state`)
# are served by ONE injected `gh` stub (MONITOR_REEMIT_GH_CMD) that branches on
# the API path.
#
# The bug (#384): an answered, 👀-acked mention on a MERGED PR re-surfaced on
# every slow re-emit cycle for the whole max-age window — the operator re-acked
# it repeatedly and it "never stuck". Root cause: the two-tier GC (#360) only
# evicts on 🚀 or max-age; a bare 👀 merely demotes to slow tier, which keeps
# re-emitting. For a CLOSED target there is no remaining work, so the slow
# "still on track?" reminder is pure noise.
#
# Asserts:
#   1. 👀 + CLOSED target          -> EVICT (reason=eyes-closed).
#   2. 👀 + OPEN target            -> NOT evicted; demoted to slow (the #360
#                                     reminder for open cross-repo work is kept).
#   3. NO reaction (un-acked)      -> NOT evicted regardless of target state
#                                     (a genuinely-new mention still emits).
#   4. 🚀 (done)                   -> EVICT (reason=rocket), even on OPEN target
#                                     (regression guard for the #360 terminal).
#   5. flag OFF                    -> 👀 + CLOSED is NOT evicted (stays slow),
#                                     proving the behavior is gated/tunable.
#   6. `_reemit_target_state` classifier: open|closed + gh-fail (rc1, no print).
#
# Run: bash monitor/watcher/test-reemit-closed-target.sh

set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0; FAIL=0
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s\n         expected: %s\n         in:\n%s\n' "$label" "$needle" "$hay" >&2; FAIL=$((FAIL+1)); fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if ! grep -qF -- "$needle" <<<"$hay"; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s\n         did NOT expect: %s\n         in:\n%s\n' "$label" "$needle" "$hay" >&2; FAIL=$((FAIL+1)); fi
}
assert_eq() {
    local label="$1" want="$2" got="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s — got [%s] want [%s]\n' "$label" "$got" "$want" >&2; FAIL=$((FAIL+1)); fi
}

# ---- harness ----
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR"
REPO="your-org/your-nexus"
USER_LOGIN="operator"
BOT_LOGIN="your-org-bot"
MONITOR_REEMIT_ENABLED="true"
MONITOR_REEMIT_LIVE_RECHECK="true"     # the closed-target check rides the live recheck
MONITOR_REEMIT_MAX_AGE_SECONDS="259200"
MONITOR_EMIT_COOLDOWN_SECONDS="0"      # never throttle the recheck under test
MONITOR_REEMIT_NOEYES_MINUTES="5"
MONITOR_REEMIT_NOROCKET_HOURS="6"
MONITOR_REEMIT_EVICT_EYES_ON_CLOSED="true"
export STATE_DIR REPO USER_LOGIN BOT_LOGIN \
       MONITOR_REEMIT_ENABLED MONITOR_REEMIT_LIVE_RECHECK \
       MONITOR_REEMIT_MAX_AGE_SECONDS MONITOR_EMIT_COOLDOWN_SECONDS \
       MONITOR_REEMIT_NOEYES_MINUTES MONITOR_REEMIT_NOROCKET_HOURS \
       MONITOR_REEMIT_EVICT_EYES_ON_CLOSED

. "$_test_dir/_reemit.sh"

reg="$STATE_DIR/unacked-mentions.lines"
log_file="$STATE_DIR/watcher.log"

# A 👀'd merged-PR mention, exactly like the live #384 reproducer.
MID="4838758117"; N="379"
BLOCK=$'mention=your-org/nexus-code kind=pr n=379 id=4838758117 author=operator\n  body: @your-org-bot please take a look at this merged PR follow-up'

reset_state() {
    rm -f "$STATE_DIR/unacked-mentions.lines" "$STATE_DIR/unacked-mentions.lock" \
          "$STATE_DIR/processed-comments.txt" "$STATE_DIR/watcher.log" 2>/dev/null || true
}

# Combined gh stub: reactions endpoint → $REACT json; issues/<n> → $TSTATE.
# Mirrors the real call shapes:
#   gh api repos/<r>/issues/comments/<id>/reactions          (reaction list)
#   gh api repos/<r>/issues/<n> --jq .state                  (target state)
REACT='[]'; TSTATE='open'
gh_stub() {
    [[ "$1" == api ]] || return 1
    case "$2" in
        */reactions) printf '%s' "$REACT" ;;
        */issues/[0-9]*) printf '%s' "$TSTATE" ;;
        *) return 1 ;;
    esac
}
export -f gh_stub
export MONITOR_REEMIT_GH_CMD=gh_stub

# A bot 👀 reaction list, and a bot 🚀 reaction list.
EYES_JSON='[{"content":"eyes","user":{"login":"your-org-bot[bot]"}}]'
ROCKET_JSON='[{"content":"rocket","user":{"login":"your-org-bot[bot]"}},{"content":"eyes","user":{"login":"your-org-bot[bot]"}}]'

register() { reset_state; printf '%s\n' "$BLOCK" | _reemit_register; }

# ===================================================================
echo '=== 1. 👀 + CLOSED target → EVICT (reason=eyes-closed) ==='
register
REACT="$EYES_JSON"; TSTATE='closed'
_reemit_gc
assert_not_contains "👀+closed: entry evicted from registry" "$(cat "$reg" 2>/dev/null)" "id=$MID"
assert_contains     "👀+closed: eviction logged reason=eyes-closed" "$(cat "$log_file" 2>/dev/null)" "reason=eyes-closed"

echo '=== 2. 👀 + OPEN target → NOT evicted; demoted to slow (preserve #360) ==='
register
REACT="$EYES_JSON"; TSTATE='open'
_reemit_gc
assert_contains     "👀+open: entry retained"           "$(cat "$reg" 2>/dev/null)" "id=$MID"
assert_contains     "👀+open: demoted to tier=slow"     "$(cat "$reg" 2>/dev/null)" "tier=slow"
assert_not_contains "👀+open: NOT eyes-closed evicted"  "$(cat "$log_file" 2>/dev/null)" "reason=eyes-closed"

echo '=== 3. NO reaction (un-acked) → NOT evicted even on a CLOSED target ==='
register
REACT='[]'; TSTATE='closed'
_reemit_gc
assert_contains     "no-reaction+closed: entry retained (still emits)" "$(cat "$reg" 2>/dev/null)" "id=$MID"
assert_contains     "no-reaction: stays tier=fast"                     "$(cat "$reg" 2>/dev/null)" "tier=fast"
assert_not_contains "no-reaction: nothing eyes-closed evicted"         "$(cat "$log_file" 2>/dev/null)" "reason=eyes-closed"

echo '=== 4. 🚀 (done) → EVICT reason=rocket, even on an OPEN target ==='
register
REACT="$ROCKET_JSON"; TSTATE='open'
_reemit_gc
assert_not_contains "🚀+open: entry evicted"            "$(cat "$reg" 2>/dev/null)" "id=$MID"
assert_contains     "🚀+open: logged reason=rocket-live" "$(cat "$log_file" 2>/dev/null)" "reason=rocket-live"

echo '=== 5. flag OFF → 👀 + CLOSED NOT evicted (gated/tunable) ==='
register
REACT="$EYES_JSON"; TSTATE='closed'
MONITOR_REEMIT_EVICT_EYES_ON_CLOSED=false _reemit_gc
assert_contains     "flag off: 👀+closed retained"   "$(cat "$reg" 2>/dev/null)" "id=$MID"
assert_contains     "flag off: demoted to slow only" "$(cat "$reg" 2>/dev/null)" "tier=slow"
assert_not_contains "flag off: NOT eyes-closed evicted" "$(cat "$log_file" 2>/dev/null)" "reason=eyes-closed"

echo '=== 6. _reemit_target_state classifier (open|closed|fail) ==='
TSTATE='open';   assert_eq "open target → open"   "open"   "$(_reemit_target_state your-org/nexus-code 379)"
TSTATE='closed'; assert_eq "closed target → closed" "closed" "$(_reemit_target_state your-org/nexus-code 379)"
gh_fail() { return 7; }; export -f gh_fail
out=$(MONITOR_REEMIT_GH_CMD=gh_fail _reemit_target_state your-org/nexus-code 379); rc=$?
assert_eq "gh failure → rc1, no output (unknown)" "1|" "${rc}|${out}"
out=$(_reemit_target_state your-org/nexus-code "not-a-number"); rc=$?
assert_eq "non-numeric n → rc1, no output" "1|" "${rc}|${out}"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && { echo "ALL TESTS PASSED"; exit 0; }
exit 1
