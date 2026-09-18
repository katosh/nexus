#!/usr/bin/env bash
# test-gh-write-guard.sh — the bot-identity backstop's TOOL REACH and its
# both-directions behaviour (your-org/nexus-code#936).
#
# WHY THIS FILE EXISTS AT ALL. `monitor/hooks/gh-write-guard.sh` had **no test
# suite** before this — measured with `git ls-files 'monitor/watcher/test-*'`
# at `e256d4a`, zero files named it. The guard whose miss is silent by
# construction — a write lands as the operator, and GitHub mutes the
# recipient's own notification, so the thread simply goes dark — was the one
# with no coverage.
#
# WHAT IT IS, precisely, because the class matters for how far it may widen:
# this hook is **advisory**. It reads the payload, appends a line to
# `gh-bypass-warnings.log`, prints a warning to stderr, and `exit 0` on every
# path. It does NOT inject a token and it does NOT block. Token injection is
# the PATH-front `gh` wrapper (`monitor/ghwrap/gh`), a different mechanism.
# That is why widening its tool reach is the same class of change as widening
# a record-only detector, and why it can be exercised hermetically from a
# synthesised payload rather than needing a live GitHub surface.
#
# THE GAP: it was gated to `Bash` at both layers — the worker-settings matcher
# and its own `_tool` check — while `Monitor` carries `.tool_input.command`
# into the same shell and `Monitor`'s own documentation demonstrates `gh api`
# poll loops. So the identity backstop was absent on a tool documented to run
# the very command it guards.
#
# ASSERTION SHAPE: every warn case is paired with a silent case on a
# byte-identical command differing only in the property under test, so a pair
# can only both pass if the guard discriminates rather than warning always or
# never.
#
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$_test_dir/../hooks/gh-write-guard.sh"
[[ -r "$HOOK" ]] || { echo "missing $HOOK" >&2; exit 1; }

WORK=$(mktemp -d -t ghwg-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# The SHARED assertion ledger (your-org/nexus-code#805): a FAILING assertion
# counted inside a subshell still reddens the suite.
# shellcheck source=_test_helpers.sh
. "$_test_dir/_test_helpers.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; _th_pass; }
bad() { printf '  FAIL: %s (%s)\n' "$1" "${2:-}" >&2; _th_fail; }

# fire <tool> <command> -> stderr of the hook
fire() {
    local tool="$1" cmd="$2"
    jq -nc --arg t "$tool" --arg c "$cmd" \
        '{hook_event_name:"PreToolUse",tool_name:$t,tool_input:{command:$c}}' \
      | env NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
            bash "$HOOK" 2>&1 >/dev/null
}
warns()  { grep -q 'gh-write-guard: WARNING' <<<"$1"; }

# fire_full <tool> <command> -> "<rc>|<stdout-bytes>"
# A PreToolUse hook can BLOCK or MODIFY a call only through stdout JSON (and a
# non-zero exit). `fire` above captures stderr only, so nothing it returns can
# tell an advisory warning from a hard block — the property this file's header
# asserts would have been stated and never checked.
fire_full() {
    local tool="$1" cmd="$2" out rc
    out=$(jq -nc --arg t "$tool" --arg c "$cmd" \
            '{hook_event_name:"PreToolUse",tool_name:$t,tool_input:{command:$c}}' \
          | env NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
                bash "$HOOK" 2>/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$(printf %s "$out" | wc -c)"
}

# A bypassing WRITE: absolute-path gh, no token, no impersonation opt-in.
BYPASS='/usr/bin/gh pr comment 12 --body hi'
# Same shape, but the caller chose an identity on purpose.
TOKENED='GH_TOKEN=$(./monitor/mint-token.sh) /usr/bin/gh pr comment 12 --body hi'
# Same bypass shape, but a READ — not a write verb.
READONLY='/usr/bin/gh pr view 12'
# The sanctioned form: a bare `gh` rides the PATH-front shim.
BARE='gh pr comment 12 --body hi'

echo '=== the guard discriminates on Bash (control: it worked here already) ==='
out=$(fire Bash "$BYPASS")
if warns "$out"; then ok "Bash: a bypassing gh WRITE warns"; else bad "Bash bypass" "$out"; fi
out=$(fire Bash "$TOKENED")
if warns "$out"; then bad "Bash tokened" "warned on a deliberate identity"; else ok "Bash: an explicit GH_TOKEN is silent"; fi
out=$(fire Bash "$READONLY")
if warns "$out"; then bad "Bash read" "warned on a read"; else ok "Bash: a READ is silent"; fi
out=$(fire Bash "$BARE")
if warns "$out"; then bad "Bash bare" "warned on the sanctioned form"; else ok "Bash: a bare gh (rides the shim) is silent"; fi

echo '=== Monitor carries commands too — the gap this closes (#936) ==='
#
# `Monitor`'s own documentation demonstrates a `gh api` poll loop, so this is
# not a hypothetical surface for a gh write.
out=$(fire Monitor "$BYPASS")
if warns "$out"; then ok "Monitor: a bypassing gh WRITE warns (was silent)"; else bad "Monitor bypass" "$out"; fi

# BOTH DIRECTIONS on the new surface. Widening a guard means it fires on more
# surfaces for every worker; one that over-fires gets suppressed, which
# removes it entirely.
out=$(fire Monitor "$TOKENED")
if warns "$out"; then bad "Monitor tokened" "warned on a deliberate identity"; else ok "Monitor: an explicit GH_TOKEN is silent"; fi
out=$(fire Monitor "$READONLY")
if warns "$out"; then bad "Monitor read" "warned on a read"; else ok "Monitor: a READ is silent"; fi
out=$(fire Monitor "$BARE")
if warns "$out"; then bad "Monitor bare" "warned on the sanctioned form"; else ok "Monitor: a bare gh is silent"; fi

# The documented Monitor poll loop, verbatim in shape from the tool's own
# docs: a READ in a loop. It must stay silent, or every CI-watching Monitor
# on the board warns.
POLL='while true; do gh api "repos/o/r/issues/1/comments" --jq ".[].body"; sleep 30; done'
out=$(fire Monitor "$POLL")
if warns "$out"; then bad "Monitor poll loop" "warned on a documented read-only poll"; else ok "Monitor: the documented gh api poll loop is silent"; fi

echo '=== ADVISORY-ONLY: it warns, it never blocks (your-org/nexus-code#936) ==='
#
# This is the property that sets the severity of a miss: a missed WARNING, not
# an unguarded write. It is what the header claims and what the record was
# corrected to say — so it must be asserted, not narrated. A mutant that added
# a `permissionDecision:"deny"` to stdout survived the whole suite before this,
# because every case here reads stderr only.
for _t in Bash Monitor; do
    got=$(fire_full "$_t" "$BYPASS")
    if [[ "$got" == "0|0" ]]; then
        ok "$_t: a flagged write exits 0 with EMPTY stdout (advisory, cannot block)"
    else
        bad "$_t: advisory-ness" "expected rc 0 and 0 stdout bytes, got rc|bytes = $got"
    fi
done

echo '=== the gate still discriminates: a tool with no shell command ==='
out=$(fire Read "$BYPASS")
if warns "$out"; then bad "Read" "guard fired for a tool that carries no command"; else ok "a non-command tool is ignored"; fi

echo '=== the warning is also recorded, not only printed ==='
rm -rf "$WORK/.state"
fire Monitor "$BYPASS" >/dev/null
if [[ -s "$WORK/.state/gh-bypass-warnings.log" ]] \
   && grep -q 'window=testw' "$WORK/.state/gh-bypass-warnings.log"; then
    ok "the Monitor bypass is appended to gh-bypass-warnings.log"
else
    bad "audit log" "no record written for the Monitor path"
fi

# COUNT GUARD — a case that stops running must be a red, not a smaller green.
_EXPECTED_ASSERTIONS=14
_ran=$(( PASS + FAIL + 1 ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    ok "every declared assertion executed ($_EXPECTED_ASSERTIONS)"
else
    bad "assertion count drifted" "ran $_ran, expected $_EXPECTED_ASSERTIONS"
fi

th_summary_and_exit
