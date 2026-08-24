#!/usr/bin/env bash
# Tests for the fail-CLOSED shim precondition emitted into every agent
# launcher (your-org/nexus-code#589, #577).
#
# The defect this suite exists to prevent: the guard used to be emitted as
#
#     if [ -x "$NEXUS_ROOT/monitor/assert-gh-wrapped.sh" ]; then
#         "$NEXUS_ROOT/monitor/assert-gh-wrapped.sh" || exit 78
#     fi
#
# with the comment "Absent helper (older checkout) → skipped." That is a
# guard that does not execute, and a guard that does not execute is
# indistinguishable from a guard that passed. It was LIVE: re-rooting
# (`#577`) points NEXUS_ROOT at the operator's primary, whose checkout
# carried no assert helper at all — so the check silently did not run, over
# the `#487` pip fork-storm that took a node down twice in two days.
#
# The teeth, in order of importance:
#   - REFUSAL (the negative control that is the whole point): with NO guard
#     under either root the block must exit 78 and SAY SO. Asserted on the
#     refusal MESSAGE, not merely the exit code, so a coincidental non-zero
#     from any other cause cannot be mistaken for the guard firing.
#   - RELOCATION: a guard absent under NEXUS_ROOT but present in the tree the
#     spawn script itself ships in must still RUN. This is the `#577`
#     root-cause fix — a guard follows the code that requires it.
#   - TEETH RETAINED: a guard that exits 1 still aborts the spawn (78).
#   - THIRD OUTCOME: exit 79 ("could not check") is neither pass nor fail —
#     loud, allowed by default, refused under NEXUS_REQUIRE_SHIM_CHECK=1.
#   - ANTI-DRIFT: no emission site may reintroduce the fail-open form.
#   - THE CONSEQUENCE, END TO END (§9, your-org/nexus-code#612): with the REAL
#     guard rather than a stub, 79 must survive the whole path and land as a
#     DURABLE row in monitor/.state/guard-unverified.log — and the deprecated
#     entry point must forward that verdict unchanged, or the contract lives in
#     a file the spawn path never executes.
#
# WHAT THIS SUITE DELIBERATELY DOES NOT ASSERT, and why the split matters.
# The guard's exit code per condition belongs to
# monitor/watcher/test-assert-shims-wrapped.sh, which reaches each condition
# through every override route. This suite asserts the CONSEQUENCE — durable
# evidence, escalation, forwarder equivalence. The separation is not tidiness:
# an implementation was demonstrated that satisfied #598's suite and #612's at
# the same time by branching on which override variable the fixture had set,
# because both suites ultimately read the same observable. Two suites reading
# the same thing are one suite. Keep the contracts disjoint.
#
# The block under test is EXTRACTED FROM spawn-worker.sh, not copied here —
# a copy would drift and the suite would then be testing prose.
#
# Hermetic: fake trees in a tmpdir, stub guards, no tmux, no network.
#
# Run: bash monitor/watcher/test-spawn-guard-fail-closed.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
SPAWNER="$REPO_ROOT/monitor/spawn-worker.sh"
RESPAWN="$REPO_ROOT/monitor/watcher/_respawn.sh"
AGW="$REPO_ROOT/monitor/assert-gh-wrapped.sh"

. "$_test_dir/_test_helpers.sh"

# Every assertion helper this file calls must EXIST before any of them is
# called. An undefined `assert_*` is not a failing assertion — it is
# `command not found`, rc 127 under `set -uo pipefail` without `-e`, tallied by
# no counter, invisible in the footer. A suite can lose assertions this way and
# still print ALL TESTS PASSED. Fail here, loudly, instead.
for _th in assert_eq assert_contains assert_not_contains assert_empty \
           assert_file_exists assert_no_file th_summary_and_exit; do
    declare -F "$_th" >/dev/null 2>&1 || {
        echo "FATAL: assertion helper '$_th' is not defined by _test_helpers.sh." >&2
        echo "       Every call to it would exit 127 and be counted by nothing." >&2
        exit 1
    }
done

[[ -r "$SPAWNER" ]] || { echo "missing spawn-worker.sh" >&2; exit 1; }
[[ -r "$RESPAWN" ]] || { echo "missing _respawn.sh" >&2; exit 1; }
[[ -x "$AGW" ]]     || { echo "missing assert-gh-wrapped.sh" >&2; exit 1; }

SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT

# --- extract the SHIPPED block ----------------------------------------------
# The block now lives in ONE place, monitor/guard-block.sh.in, read as data by
# both launchers. Substitute the same way spawn-worker.sh does so the text
# under test is byte-identical to what ships.
TEMPLATE="$REPO_ROOT/monitor/guard-block.sh.in"
[[ -r "$TEMPLATE" ]] || { echo "missing guard-block.sh.in" >&2; exit 1; }
BLOCK="$SB/block.sh"
{
    printf '#!/bin/bash\n'
    sed -e 's/@@WHO@@/spawn-worker/g' -e 's/@@ACTION@@/SPAWN/g' -- "$TEMPLATE"
} > "$BLOCK"
chmod +x "$BLOCK"

# A block that extracted to nothing would make every case below pass
# vacuously — the exact failure mode this file is about. Assert it has body,
# and that no placeholder survived the substitution.
_block_lines=$(grep -cve '^[[:space:]]*$' "$BLOCK")
if (( _block_lines < 10 )); then
    echo "FATAL: guard block is $_block_lines lines — template unreadable or empty." >&2
    echo "       Do NOT let this suite report green on an empty block." >&2
    exit 1
fi
if grep -q '@@' "$BLOCK"; then
    echo "FATAL: an unsubstituted @@PLACEHOLDER@@ survived — the emitted guard" >&2
    echo "       would carry it verbatim into every launcher." >&2
    exit 1
fi

# make_guard <path> <exit-code> — a stub guard that records that it RAN.
make_guard() {
    local p="$1" rc="$2"
    mkdir -p "$(dirname "$p")"
    printf '#!/bin/sh\necho "stub-guard ran: $0" >> "%s/ran.log"\nexit %s\n' "$SB" "$rc" > "$p"
    chmod +x "$p"
}

# run_block <nexus_root> <code_root> [ENV=VAL ...] — returns rc, sets OUT.
run_block() {
    local nr="$1" cr="$2"; shift 2
    local rc
    OUT=$(env -i PATH="$PATH" HOME="$HOME" \
              NEXUS_ROOT="$nr" NEXUS_SPAWN_CODE_ROOT="$cr" "$@" \
              bash "$BLOCK" 2>&1)
    rc=$?
    return $rc
}

echo "=== 0. THE DEFECT, CHARACTERISED — the superseded form fails OPEN ==="
# Running this whole suite against a pre-fix checkout is a WEAK control: it
# aborts at the extraction above, proving only that the new block is absent.
# So the superseded emission is reproduced here VERBATIM (from
# spawn-worker.sh @ c3a81ec) and exercised under the SAME condition Case 1
# uses. Under that condition the old form exits 0 in complete silence and the
# new form refuses — that differential, not an exit code in isolation, is the
# evidence that the fix has teeth. It is pinned in CI so a refactor back
# toward `if [ -x <helper> ]` cannot land quietly.
OLDBLOCK="$SB/oldblock.sh"
cat > "$OLDBLOCK" <<'OLDFORM'
#!/bin/bash
# --- superseded; DO NOT REINTRODUCE (your-org/nexus-code#589) --------------
if [ -x "$NEXUS_ROOT/monitor/assert-gh-wrapped.sh" ]; then
    "$NEXUS_ROOT/monitor/assert-gh-wrapped.sh" || { echo "spawn-worker: aborting — gh wrapper unreachable in the agent shell (see above)" >&2; exit 78; }
fi
OLDFORM
mkdir -p "$SB/nowhere/monitor"
old_out=$(env -i PATH="$PATH" HOME="$HOME" NEXUS_ROOT="$SB/nowhere" \
          bash "$OLDBLOCK" 2>&1); old_rc=$?
assert_eq "superseded form with NO guard present: exits 0 (a silent pass)" "$old_rc" "0"
assert_empty "…and says NOTHING — 'missing' and 'passed' are one outcome" "$old_out"

echo
echo "=== 1. REFUSAL — no guard under either root (the negative control) ==="
: > "$SB/ran.log"
mkdir -p "$SB/empty_a/monitor" "$SB/empty_b/monitor"
run_block "$SB/empty_a" "$SB/empty_b"; rc=$?
assert_eq "no guard anywhere → block REFUSES with exit 78" "$rc" "78"
assert_contains "…and the refusal names the missing guard, not just a code" \
    "$OUT" "REFUSING TO SPAWN — no shim precondition guard found"
assert_contains "…and names both helper names it looked for" \
    "$OUT" "assert-shims-wrapped.sh, assert-gh-wrapped.sh"
assert_contains "…and states the rule that makes this a refusal" \
    "$OUT" "a MISSING guard is not a passing guard"
assert_empty "…and nothing claimed to have run" "$(cat "$SB/ran.log" 2>/dev/null)"

echo
echo "=== 2. RELOCATION — guard absent under NEXUS_ROOT, present in the"
echo "       spawn script's own tree (#577 root cause) — it must RUN ==="
: > "$SB/ran.log"
mkdir -p "$SB/stale_primary/monitor"
make_guard "$SB/code_tree/monitor/assert-gh-wrapped.sh" 0
run_block "$SB/stale_primary" "$SB/code_tree"; rc=$?
assert_eq "re-rooted NEXUS_ROOT does not disable the guard" "$rc" "0"
assert_contains "…the guard in the shipping tree actually executed" \
    "$(cat "$SB/ran.log")" "code_tree/monitor/assert-gh-wrapped.sh"

echo
echo "=== 3. TEETH RETAINED — a guard that refuses still aborts the spawn ==="
: > "$SB/ran.log"
make_guard "$SB/bad_tree/monitor/assert-gh-wrapped.sh" 1
run_block "$SB/bad_tree" ""; rc=$?
assert_eq "guard exit 1 → spawn aborts with 78" "$rc" "78"
assert_contains "…and says the precondition FAILED (not that it was missing)" \
    "$OUT" "shim precondition failed"
assert_not_contains "…and does NOT report it as missing" \
    "$OUT" "REFUSING TO SPAWN — no shim precondition guard found"

echo
echo "=== 4. THIRD OUTCOME — exit 79 is 'not checked', not 'passed' ==="
: > "$SB/ran.log"
make_guard "$SB/unchecked_tree/monitor/assert-gh-wrapped.sh" 79
run_block "$SB/unchecked_tree" ""; rc=$?
assert_eq "guard exit 79 → spawn allowed by default" "$rc" "0"
assert_contains "…but loudly reported as NOT CHECKED" "$OUT" "NOT CHECKED"
assert_contains "…and explicitly denied the status of a pass" \
    "$OUT" "This is not a pass"
run_block "$SB/unchecked_tree" "" NEXUS_REQUIRE_SHIM_CHECK=1; rc=$?
assert_eq "…and REFUSES under NEXUS_REQUIRE_SHIM_CHECK=1" "$rc" "78"
assert_contains "…naming the reason" "$OUT" "the check could not run"

echo
echo "=== 5. #589 RENAME — the generalised helper name is found too ==="
: > "$SB/ran.log"
make_guard "$SB/new_name/monitor/assert-shims-wrapped.sh" 0
run_block "$SB/new_name" ""; rc=$?
assert_eq "assert-shims-wrapped.sh alone is sufficient" "$rc" "0"
assert_contains "…and it is the file that ran" \
    "$(cat "$SB/ran.log")" "assert-shims-wrapped.sh"
# Preference order: the generalised guard wins when both are present.
: > "$SB/ran.log"
make_guard "$SB/both/monitor/assert-shims-wrapped.sh" 0
make_guard "$SB/both/monitor/assert-gh-wrapped.sh" 0
run_block "$SB/both" "" >/dev/null
assert_contains "both present → the generalised (#589) guard is preferred" \
    "$(cat "$SB/ran.log")" "assert-shims-wrapped.sh"
assert_not_contains "…and the superseded one does not also run" \
    "$(cat "$SB/ran.log")" "assert-gh-wrapped.sh"

echo
echo "=== 6. OVERRIDE — explicit, reasoned, and LOUD (never silent) ==="
: > "$SB/ran.log"
run_block "$SB/empty_a" "$SB/empty_b" NEXUS_ALLOW_MISSING_SHIM_GUARD="stale checkout, recovering"; rc=$?
assert_eq "override allows the spawn" "$rc" "0"
assert_contains "…loudly" "$OUT" "WARNING — shim precondition guard MISSING"
assert_contains "…carrying the operator's reason" "$OUT" "stale checkout, recovering"
assert_contains "…and naming what is unverified" "$OUT" "#487 pip fork-storm"

echo
echo "=== 7. ANTI-DRIFT — no emission site may reintroduce the fail-open form ==="
legacy=$(grep -n 'if \[ -x "\\\$NEXUS_ROOT/monitor/assert-' "$SPAWNER" "$RESPAWN" || true)
assert_empty "no launcher still gates the guard on plain [ -x ] with no else" "$legacy"
skipped=$(grep -n 'Absent helper (older checkout)' "$SPAWNER" "$RESPAWN" || true)
assert_empty "the 'absent helper → skipped' contract is gone from both files" "$skipped"
n_sites=$(grep -c '^\$SHIM_GUARD_BLOCK$' "$SPAWNER" || true)
assert_eq "all three spawn-worker launchers emit the block" "$n_sites" "3"
n_root=$(grep -c '^export NEXUS_ROOT="\$NEXUS_ROOT"$' "$SPAWNER" || true)
n_code=$(grep -c '^export NEXUS_SPAWN_CODE_ROOT="\$NEXUS_SPAWN_CODE_ROOT"$' "$SPAWNER" || true)
assert_eq "every launcher exporting NEXUS_ROOT also exports the code root" \
    "$n_code" "$n_root"
# The code root must be captured from the SCRIPT, never re-derived from a
# variable that re-rooting can move.
assert_contains "code root is captured from the script's own tree" \
    "$(grep -A1 '^NEXUS_ROOT="\$(cd "\$(dirname "\$0")/\.\." && pwd)"$' "$SPAWNER" | head -20; grep -n 'NEXUS_SPAWN_CODE_ROOT=' "$SPAWNER" | head -1)" \
    "NEXUS_SPAWN_CODE_ROOT="

echo
echo "=== 8. _respawn launcher — SAME SOURCE, same contract, end to end ==="
# _respawn.sh no longer carries its own copy of the block: it reads the same
# monitor/guard-block.sh.in and substitutes @@WHO@@/@@ACTION@@. Two
# hand-maintained copies of a guard is how the next divergence lands, and a
# guard silently diverged from its twin is a cousin of this whole defect class.
#
# NOTE on the fixture: _respawn exports NEXUS_SPAWN_CODE_ROOT as the tree the
# WATCHER ships in, which in the real repo always contains the guard — so the
# refusal case cannot be built by pointing nexus_root at an empty dir. It has
# to be built from a COPY of _respawn.sh inside a guard-less tree, which is
# also the only faithful model of the state that produces it (a checkout that
# genuinely lacks the helper).
compose_from() { # compose_from <tree> <out> <nexus_root>
    local tree="$1" out="$2" root="$3"
    ( set +u
      CLAUDE_BIN=/bin/true
      . "$tree/monitor/watcher/_respawn.sh"
      _respawn_compose_launcher "$out" "$root" "" "" "orchestrator" "" )
}
mk_tree() { # mk_tree <dir> [--with-guard]
    local d="$1"; mkdir -p "$d/monitor/watcher"
    cp "$REPO_ROOT/monitor/watcher/_respawn.sh" "$d/monitor/watcher/"
    cp "$REPO_ROOT/monitor/guard-block.sh.in"   "$d/monitor/"
    [[ "${2:-}" == "--with-guard" ]] && make_guard "$d/monitor/assert-gh-wrapped.sh" "${3:-0}"
    return 0
}

: > "$SB/ran.log"
mk_tree "$SB/rs_empty"
compose_from "$SB/rs_empty" "$SB/l1.sh" "$SB/rs_empty"
out=$(env -i PATH="$PATH" HOME="$HOME" bash "$SB/l1.sh" 2>&1); rc=$?
assert_eq "orchestrator respawn with NO guard in EITHER root → refuses (78)" "$rc" "78"
assert_contains "…naming the refusal, with _respawn's own prefix" \
    "$out" "_respawn: REFUSING TO RESPAWN — no shim precondition guard found"
assert_contains "…and the rule" "$out" "a MISSING guard is not a passing guard"

: > "$SB/ran.log"
mk_tree "$SB/rs_ok" --with-guard 0
compose_from "$SB/rs_ok" "$SB/l2.sh" "$SB/rs_ok"
env -i PATH="$PATH" HOME="$HOME" bash "$SB/l2.sh" >/dev/null 2>&1; rc=$?
assert_eq "orchestrator respawn with a passing guard proceeds" "$rc" "0"
assert_contains "…and the guard ran" "$(cat "$SB/ran.log")" "rs_ok/monitor/assert-gh-wrapped.sh"

: > "$SB/ran.log"
mk_tree "$SB/rs_bad" --with-guard 1
compose_from "$SB/rs_bad" "$SB/l3.sh" "$SB/rs_bad"
out=$(env -i PATH="$PATH" HOME="$HOME" bash "$SB/l3.sh" 2>&1); rc=$?
assert_eq "orchestrator respawn with a REFUSING guard aborts (78)" "$rc" "78"
assert_contains "…for the right reason" "$out" "shim precondition failed"

# The guard FOLLOWS THE CODE: nexus_root re-rooted onto a guard-less primary,
# while the watcher's own tree has one. This is the #577 case, orchestrator side.
: > "$SB/ran.log"
mkdir -p "$SB/rs_stale_primary/monitor"
compose_from "$SB/rs_ok" "$SB/l4.sh" "$SB/rs_stale_primary"
env -i PATH="$PATH" HOME="$HOME" bash "$SB/l4.sh" >/dev/null 2>&1; rc=$?
assert_eq "re-rooted NEXUS_ROOT does not disable the orchestrator's guard" "$rc" "0"
assert_contains "…the guard in the watcher's OWN tree ran" \
    "$(cat "$SB/ran.log")" "rs_ok/monitor/assert-gh-wrapped.sh"

# An absent template must NOT degrade to an empty guard block.
: > "$SB/ran.log"
mk_tree "$SB/rs_notpl"; rm -f "$SB/rs_notpl/monitor/guard-block.sh.in"
compose_from "$SB/rs_notpl" "$SB/l5.sh" "$SB/rs_notpl"
out=$(env -i PATH="$PATH" HOME="$HOME" bash "$SB/l5.sh" 2>&1); rc=$?
assert_eq "missing TEMPLATE refuses rather than emitting an empty block" "$rc" "78"
assert_contains "…saying exactly that" "$out" "an empty guard block is a guard that does not run"

echo
echo "=== 9. END TO END with the REAL guard — the third outcome survives the"
echo "       whole path and leaves DURABLE evidence (your-org/nexus-code#612) ==="
#
# Everything above this point drives the block against STUB guards whose exit
# code the fixture chose. That proves the block's arithmetic and nothing about
# the guard. This section removes the stub: a real assert-shims-wrapped.sh, in
# a real tree with no shim dirs, reached through the real search loop.
#
# WHY THIS SUITE ASSERTS SOMETHING DIFFERENT FROM
# monitor/watcher/test-assert-shims-wrapped.sh. That suite pins the guard's
# EXIT CODE across every route into the condition. This one pins the
# CONSEQUENCE: that a launcher turns 79 into a loud, durable, explicitly
# non-pass record — and escalates it to a refusal on demand. The two contracts
# have no shared proxy, which is deliberate. The #598/#612 contradiction was
# resolvable by an implementation that branched on which override variable the
# fixture had set: it satisfied both suites at once because both suites were
# ultimately reading the same observable. Two suites reading the same thing are
# one suite. An implementation can no longer buy this one by returning a number.
#
# It also closes the DEAD-CODE hazard directly. guard-block.sh.in searches
# assert-shims-wrapped.sh FIRST, so a third outcome implemented only in the
# deprecated assert-gh-wrapped.sh forwarder would never execute — while every
# direct-call assertion in the other suite stayed green, because that suite
# calls the forwarder and the forwarder is what would have been fixed.
REALGUARD="$REPO_ROOT/monitor/assert-shims-wrapped.sh"
[[ -x "$REALGUARD" ]] || { echo "missing assert-shims-wrapped.sh" >&2; exit 1; }

# A tree that is a faithful model of the state that produces 79 in production:
# a checkout (or a re-rooted primary) that carries the guard but no monitor/*wrap
# shim dirs at all. Nothing is stubbed.
mk_real_tree() {  # mk_real_tree <dir> [--legacy-too]
    local d="$1"
    mkdir -p "$d/monitor/.state"
    cp "$REALGUARD" "$d/monitor/assert-shims-wrapped.sh"
    chmod +x "$d/monitor/assert-shims-wrapped.sh"
    # Supply the in-turn guards' pattern file. That leg writes its OWN
    # _nx_note row when it is missing, which is correct behaviour and a
    # confound here — this section is about the SHIM precondition's row, and a
    # control that cannot tell the two rows apart controls for nothing.
    : > "$d/monitor/bash-footgun-patterns.conf"
    if [[ "${2:-}" == "--legacy-too" ]]; then
        cp "$REPO_ROOT/monitor/assert-gh-wrapped.sh" "$d/monitor/"
        chmod +x "$d/monitor/assert-gh-wrapped.sh"
    fi
}

mk_real_tree "$SB/real_nowrap"
run_block "$SB/real_nowrap" "" NEXUS_ASSERT_SKIP_NPROC=1 \
          NEXUS_WORKER_WINDOW=w-612-e2e; rc=$?
assert_eq "real guard, no shim dirs → the block ALLOWS the spawn" "$rc" "0"
assert_contains "…and the guard itself announced NOT CHECKED" \
    "$OUT" "NOT CHECKED: no shim dirs found"
assert_contains "…the block restates it as the launcher's own verdict" \
    "$OUT" "shim precondition NOT CHECKED"
assert_contains "…and denies it the status of a pass, in words" \
    "$OUT" "This is not a pass"
# The half that makes it observable AFTER the fact. An announcement that
# reaches only a pane's stderr is gone the moment the pane is.
LOG9="$SB/real_nowrap/monitor/.state/guard-unverified.log"
assert_file_exists "…and the outcome is recorded durably, not just announced" "$LOG9"
assert_contains "…the row names the window it belongs to" \
    "$(cat "$LOG9" 2>/dev/null)" "w-612-e2e"
assert_contains "…and carries the NOT CHECKED reason, not a bare timestamp" \
    "$(cat "$LOG9" 2>/dev/null)" "shim precondition NOT CHECKED"

# NEGATIVE CONTROL for the row: a guard that PASSES must not produce one.
# Without it, a block that logged unconditionally would satisfy every assertion
# above while recording "unverified" for runs that were fully verified — a log
# whose rows mean nothing is worse than no log. Asserted on the ROW, not on the
# file: the in-turn-guards leg legitimately writes its own row on a host
# without `jq`, and a file-existence control would read that as a failure here
# and as a pass on a host that has jq. Same state, two verdicts — which is the
# defect this branch is about, reproduced in a control.
mk_real_tree "$SB/real_pass"
make_guard "$SB/real_pass/monitor/assert-shims-wrapped.sh" 0
run_block "$SB/real_pass" "" NEXUS_WORKER_WINDOW=w-612-pass >/dev/null 2>&1
assert_not_contains "negative control: a PASSING guard records no shim-precondition row" \
    "$(cat "$SB/real_pass/monitor/.state/guard-unverified.log" 2>/dev/null)" \
    "shim precondition NOT CHECKED"

# Escalation: the same host state, refused rather than noted, on demand. This
# is the reason 79 is an exit code at all rather than a log line — a launcher
# can gate on it.
run_block "$SB/real_nowrap" "" NEXUS_ASSERT_SKIP_NPROC=1 \
          NEXUS_REQUIRE_SHIM_CHECK=1; rc=$?
assert_eq "…and NEXUS_REQUIRE_SHIM_CHECK=1 turns the same state into a refusal" "$rc" "78"
assert_contains "…naming the reason, not just the code" "$OUT" "the check could not run"

# THE DEAD-CODE HAZARD, measured rather than reasoned about. With BOTH names
# present the block picks assert-shims-wrapped.sh; the verdict must be identical
# to the one the deprecated name produces. If the two disagree, the contract
# lives in a file nothing on the spawn path executes.
mk_real_tree "$SB/real_both" --legacy-too
rc_direct=$(NEXUS_ROOT="$SB/real_both" NEXUS_ASSERT_SKIP_NPROC=1 \
            "$SB/real_both/monitor/assert-shims-wrapped.sh" >/dev/null 2>&1; echo $?)
rc_legacy=$(NEXUS_ROOT="$SB/real_both" NEXUS_ASSERT_SKIP_NPROC=1 \
            "$SB/real_both/monitor/assert-gh-wrapped.sh" >/dev/null 2>&1; echo $?)
assert_eq "the deprecated name forwards the verdict UNCHANGED (no dead branch)" \
    "$rc_legacy" "$rc_direct"
assert_eq "…and that shared verdict is the third outcome" "$rc_direct" "79"
run_block "$SB/real_both" "" NEXUS_ASSERT_SKIP_NPROC=1; rc=$?
assert_eq "…and the block reaches it through the guard it actually prefers" "$rc" "0"
assert_contains "…via assert-shims-wrapped, whose banner names itself" \
    "$OUT" "assert-shims-wrapped: NOT CHECKED"

echo
echo "=== 10. ASSERTION COUNT — a helper that vanished exits 127 and is"
echo "        counted by nothing, so the verdict alone is not evidence ==="
# `th_summary_and_exit` reports the assertions that RAN. An assertion that
# never ran is invisible to it: an undefined assert_* is `command not found`,
# rc 127, tallied nowhere, and the footer still says ALL TESTS PASSED with a
# quieter number. This suite has no conditional cases, so the count is exact.
# Bump it deliberately when adding a case; a DROP means a case stopped running.
_EXPECTED_ASSERTIONS=55
_ran=$(( PASS + FAIL ))
assert_eq "every declared assertion executed ($_EXPECTED_ASSERTIONS)" \
    "$_ran" "$_EXPECTED_ASSERTIONS"

th_summary_and_exit
