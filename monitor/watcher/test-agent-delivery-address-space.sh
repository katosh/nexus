#!/usr/bin/env bash
# The delivery contract's ADDRESS SPACE (your-org/nexus-code#1081).
#
# Run: bash monitor/watcher/test-agent-delivery-address-space.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE FINDING IS A POPULATION DEFECT, NOT A LOGIC ONE. The contract pins identity
# to the tmux window name and thereby owes uniqueness of that address. It
# discharged that against the LIVE tmux window list — correct over a set SMALLER
# than the one the property must hold over. The transport resolves a name against
# the harness's peer set, which has included RETIRED nexus window names surfaced
# as the operator's sessions on other machines.
#
# WHAT THIS SUITE CAN AND CANNOT ESTABLISH, said plainly because the issue turns
# on it. The harness peer list is available to an AGENT, never to a shell script,
# so NOTHING here enumerates it and nothing here measures how the harness
# RESOLVES an ambiguous name. That is the one experiment the issue names as
# outstanding, and it stays outstanding. What is testable is the half that lives
# in this repo: the script refuses what it can see, NOTICES what it can look up,
# and the contract states the residual boundary rather than implying none exists.
#
# The three polarities the issue asks for, minus the one that needs the harness:
#   live collision      -> REFUSED (exit 7), unchanged
#   recycled name       -> permitted, but NOT silently: the ambiguity is surfaced
#   fresh name          -> silent, or the channel is noise
#
# NAME REUSE IS SUPPORTED, NOT AN ACCIDENT — `#73` D2 made the spawn event's ts
# the lifecycle birth precisely so a recycled name rejects the prior life's
# wrap-up, and test-integration/test-same-name-recycle.sh holds it. So a fix that
# REFUSED every previously-used name would break a designed behaviour to close a
# narrower hazard. That is why the recycle arm asserts the spawn is PERMITTED.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
_repo_root=$(cd "$_test_dir/../.." && pwd)

SPAWNER="$_repo_root/monitor/spawn-worker.sh"
CONTRACT="$_repo_root/skills/nexus.agent-delivery/SKILL.md"
[ -r "$SPAWNER" ]  || { echo "missing spawn-worker.sh" >&2; exit 1; }
[ -r "$CONTRACT" ] || { echo "missing agent-delivery SKILL.md" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/state/windows" "$WORK/bin" "$WORK/wd"
echo "task prompt body" > "$WORK/p.txt"

# tmux stub. FAKE_LIVE_WINDOWS is the ENTIRE live window list, so the "live"
# population is a variable of the experiment rather than whatever this host
# happens to be running.
cat > "$WORK/bin/tmux" <<'T'
#!/bin/bash
case "$1" in
  info)         exit 0 ;;
  list-windows) printf '%s\n' ${FAKE_LIVE_WINDOWS:-} ; exit 0 ;;
  new-window)   echo '@9'; exit 0 ;;
  *)            exit 0 ;;
esac
T
chmod +x "$WORK/bin/tmux"

# `claude` stub. spawn-worker.sh resolves a claude binary via _claude-bin.sh and
# REFUSES when it finds none — CI runners have no claude on PATH, so without this
# the spawn dies long before reaching the code under test and every assertion
# below reports the resolver's diagnostic instead of a verdict. Measured: this
# suite was 19/0 locally and rc=1 in CI with "no claude binary found" quoted back
# as the haystack of three assertions. A green that depends on the developer's
# machine having a binary is not a green.
cat > "$WORK/bin/claude" <<'C'
#!/bin/bash
exit 0
C
chmod +x "$WORK/bin/claude"

# Run the REAL spawn-worker.sh. State is pinned to the fixture so nothing
# touches this clone's own records.
# NOT `out=$(spawn …)`: a command substitution runs the function in a SUBSHELL,
# so an rc stashed in a global dies with it (`SPAWN_RC: unbound variable`, hit
# while writing this suite). Output goes to a FILE; the rc is the function's own.
SPAWN_OUT="$WORK/spawn.out"
spawn() {                       # spawn <live-windows> <name> -> rc; output in the file
    local live="$1" name="$2"
    ( cd "$WORK/wd" && PATH="$WORK/bin:$PATH" CLAUDE_BIN="$WORK/bin/claude" \
      NEXUS_ROOT="$_repo_root" NEXUS_STATE_DIR="$WORK/state" \
      FAKE_LIVE_WINDOWS="$live" \
      timeout 90 bash "$SPAWNER" -n "$name" -c "$WORK/wd" -p "$WORK/p.txt" ) \
        > "$SPAWN_OUT" 2>&1
}

# ═══════════════════════════════════════════════════════════════════════════
echo "== a LIVE collision is still REFUSED — the narrow guard is not weakened =="

spawn "alpha taken beta" "taken"; rc=$?
out=$(cat "$SPAWN_OUT")
# ENVIRONMENT CONTROL FIRST. Every assertion below is a needle test against the
# spawn's output, and a spawn that died in its own preamble produces output that
# fails all of them for a reason that has nothing to do with the property. Name
# that case rather than letting it masquerade as a defect.
assert_not_contains "the spawn reached the code under test (no binary-resolver refusal)" \
    "$out" "no claude binary found"
assert_eq "a live window-name collision exits 7" "$rc" "7"
assert_contains "…and says which name" "$out" "taken"

# ═══════════════════════════════════════════════════════════════════════════
echo "== a RECYCLED name is PERMITTED but NOT silent =="

# The durable record is what the script CAN look up: 1,321 of these exist on
# this nexus against ~20 live windows, so the lookup population is two orders of
# magnitude wider than the one the guard used.
RECORD="$WORK/state/windows/recycled.json"
printf '{"window":"recycled"}\n' > "$RECORD"
assert_file_exists "fixture: a prior-life record exists for the name" "$RECORD"

# WHY THIS IS NOT `rc == 0`. The property under test is the NAME DECISION —
# refused, or permitted — and nothing else. A full spawn additionally requires a
# resolvable claude binary, a pre-seedable workspace-trust record and a
# worker-settings.json, none of which this issue touches and ALL THREE OF WHICH
# HAVE ALREADY PRODUCED A FALSE RED HERE (CI rc=1 "no claude binary found";
# a stripped environment rc=10). Asserting rc==0 tests the runner's environment
# and reports it as a defect in the address-space guard.
#
# `exit 7` IS the name refusal and is the only code this code path produces, so
# "not refused" is asserted BOTH ways — the code and the message — rather than
# as a bare not-equal, which would be the permissive-default shape this repo
# warns about. The notice assertions below are the positive half.
spawn "alpha beta" "recycled"; rc=$?
out=$(cat "$SPAWN_OUT")
assert_eq "a recycled name is PERMITTED — not the name-collision refusal" \
    "$( [ "$rc" -eq 7 ] && echo refused || echo permitted )" "permitted"
assert_not_contains "…and no collision message was emitted for it" \
    "$out" "already exists"
assert_contains "…but the prior use is SURFACED"        "$out" "has been used in this nexus before"
assert_contains "…naming the record that proves it"      "$out" "recycled.json"
# Needle chosen to be CASE- and WRAP-safe: the notice capitalises WIDER, and a
# prose needle that spans a line wrap matches nothing. Both bit here.
assert_contains "…and naming the wider address space"    "$out" "than the live window list"
assert_contains "…and telling the reader how to check"   "$out" "ListAgents"
assert_contains "…with the read-only constraint stated"  "$out" "never message"

# ═══════════════════════════════════════════════════════════════════════════
echo "== the notice SURVIVES ng retire-window, or its coverage shrinks with adoption =="

# your-org/nexus-code#1081 skeptic. `"file:windows/{s}.json"` is a member of
# BK_RETIRE_SURFACES, so `ng retire-window` — the verb the skill tells the
# orchestrator to PREFER — DELETES the record. Keyed only on that file, this
# check would go quiet for exactly the names retired properly, and coverage
# would shrink as operators adopted the preferred verb. A retired name would
# become indistinguishable from one never used.
#
# The action log is not a retire surface and is append-only, so it survives.
rm -f "$WORK/state/windows/retired.json"
mkdir -p "$WORK/state"
printf '%s\n' '{"ts":"2026-01-01T00:00:00-00:00","agent":"monitor","event":"spawn","window":"retired"}' \
    > "$WORK/state/action-log.jsonl"
assert_no_file "fixture: the windows/ record is GONE, as retire-window leaves it" \
    "$WORK/state/windows/retired.json"

spawn "alpha beta" "retired"; rc=$?
out=$(cat "$SPAWN_OUT")
assert_contains "a name known ONLY to the action log is still surfaced" \
    "$out" "has been used in this nexus before"

# NEGATIVE: a name in neither surface stays silent, so the arm is not simply on.
: > "$WORK/state/action-log.jsonl"
spawn "alpha beta" "never-seen-anywhere"; rc=$?
out=$(cat "$SPAWN_OUT")
assert_not_contains "a name in NEITHER surface stays silent" \
    "$out" "has been used in this nexus before"

# ═══════════════════════════════════════════════════════════════════════════
echo "== a FRESH name is SILENT — or the channel is noise =="

spawn "alpha beta" "brand-new-name"; rc=$?
out=$(cat "$SPAWN_OUT")
assert_eq "a fresh name is PERMITTED — not the name-collision refusal" \
    "$( [ "$rc" -eq 7 ] && echo refused || echo permitted )" "permitted"
assert_not_contains "…and no collision message was emitted for it" \
    "$out" "already exists"
assert_not_contains "a fresh name produces NO recycle notice" \
    "$out" "has been used in this nexus before"

# THE PAIR IS THE POINT. Without the negative above, a notice printed
# unconditionally would satisfy every positive assertion in this file.

# ═══════════════════════════════════════════════════════════════════════════
echo "== the CONTRACT states the boundary, and states it CONSISTENTLY with the code =="

# A doc-only claim is worth nothing if the code disagrees, which is the defect
# class this repo keeps filing. Each assertion below pairs a sentence in the
# contract with the behaviour measured above.
contract=$(cat "$CONTRACT")

assert_contains "the contract declares WHERE the name is unique" \
    "$contract" "unique among LIVE tmux windows"
assert_contains "…and names the exit code that enforces it" "$contract" "exit 7"
assert_contains "…and says a wider transport MUST disambiguate" \
    "$contract" "MUST disambiguate"
assert_contains "…and assigns the residual check to the ORCHESTRATOR" \
    "$contract" "ORCHESTRATOR obligation"
assert_contains "…and keeps the enumeration READ-ONLY" "$contract" "enumerable but MUST NOT be"
assert_contains "…and records what is still UNMEASURED" "$contract" "unmeasured"

# THE DOC/CODE CONSISTENCY CHECK. The contract says exit 7; assert the script
# actually uses 7 for this, rather than the doc quoting a number nobody re-ran.
# The live-collision arm above measured 7 — this ties that measurement to the
# sentence, so a future edit to either side reddens.
assert_contains "the contract's 'exit 7' is the code the script really returns" \
    "$contract" "refusing a colliding name with **exit 7**"

# The contract must NOT claim the script can enumerate the harness peer set —
# that is the false promise #1081 is open about.
assert_contains "the contract says the peer list is agent-only, not script-reachable" \
    "$contract" "no command \`spawn-worker.sh\` could run to enumerate it"

th_summary_and_exit
