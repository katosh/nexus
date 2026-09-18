#!/usr/bin/env bash
# Tests for the cc-harness pre-update gate's fail-on-skip behavior —
# monitor/cc-harness/gate.sh + the CCH_GATE skip sentinel in
# monitor/cc-harness/_lib.sh.
#
# THE INVARIANT under test (your-org/your-nexus#236 / U12): under
# candidate evaluation the gate must NEVER print GREEN when a scenario
# was merely SKIPPED. A skipped scenario means the candidate binary was
# not actually exercised — counting it as a pass is the exact
# green-via-skip hole the gate exists to prevent (a prior gate printed
# "GATE GREEN — safe to promote" with every scenario skipped for lack of
# node). The pre-fix gate did exactly that: the skip path exited 0 and
# the gate's rc only flipped on a non-zero exit, so all-skipped == green.
#
# Mechanism: a self-skip exits 77 (the autotools SKIP sentinel). The gate
# classifies 0=pass / 77=skip / other=fail and goes RED on any skip or fail,
# with a passed/failed/skipped tally in the headline.
#
# Note the exit code no longer depends on CCH_GATE (your-org/nexus-code#568 A6).
# It used to exit 0 unless the gate was set, to "preserve" run-tests.sh's
# rc==0==PASS fast loop — which meant the broad suite laundered every declined
# realmodel scenario into the PASS column. run-tests.sh now has a real SKIP
# status, so the sentinel is unconditional and the two runners agree: a scenario
# that declined to run is reported as declined, in both.
#
# Fully hermetic: the gate's scenario list is overridden with stub
# scripts via CCH_GATE_SCENARIOS, and a real claude binary is stood in
# with /bin/bash (--claude-bin), so no node / npm / tmux / network. The
# #1002 band at the end drives the --version path through a stub `npm` on a
# private PATH that stages a fake binary under --prefix and REFUSES a call
# without it — still no network, and never the live node_modules.
#
# Run: bash monitor/watcher/test-cc-gate.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
GATE="$_repo_root/monitor/cc-harness/gate.sh"
LIB="$_repo_root/monitor/cc-harness/_lib.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

[[ -f "$GATE" ]] || { echo "missing: $GATE" >&2; exit 1; }
[[ -f "$LIB"  ]] || { echo "missing: $LIB"  >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A real-enough "claude" binary: /bin/bash answers `--version` and is
# executable, satisfying gate.sh's [[ -x ]] + version-echo pre-flight.
CLAUDE_STUB=$(command -v bash)

# --- stub scenarios (the gate runs each via `bash "$s"`) -------------
mk_stub() {  # $1 = name, $2 = exit code
    local p="$WORK/$1"
    printf '#!/usr/bin/env bash\nexit %s\n' "$2" > "$p"
    chmod +x "$p"
    printf '%s' "$p"
}
S_PASS=$(mk_stub pass.sh 0)
S_FAIL=$(mk_stub fail.sh 1)

# The SKIP stub drives the REAL skip path (cch_skip_if_disabled), so this
# is a faithful end-to-end mutation check: it exercises the actual
# _lib.sh sentinel that gate.sh sets CCH_GATE=1 for. Pre-fix that path
# exited 0 (→ counted as a pass → GREEN); post-fix, under the gate's
# CCH_GATE=1, it exits 77 (→ skip → RED). Forces the skip by clearing
# RUN_CC_HARNESS (the first skip condition) — CCH_GATE is inherited from
# the gate's per-scenario env.
S_SKIP="$WORK/skip.sh"
{
    printf '#!/usr/bin/env bash\n'
    printf 'unset RUN_CC_HARNESS\n'
    printf '. %q\n' "$LIB"
    printf 'cch_skip_if_disabled\n'
    printf 'echo "BUG: skip stub kept running (not skipped)"\n'
} > "$S_SKIP"
chmod +x "$S_SKIP"

run_gate() {  # remaining args: scenario paths
    local scen="$*"
    CCH_GATE_SCENARIOS="$scen" \
        bash "$GATE" --claude-bin "$CLAUDE_STUB" 2>&1
}

echo "=== gate.sh classification + fail-on-skip ==="

# (1) All scenarios pass → GREEN, exit 0, tally reflects 0 skipped.
out=$(run_gate "$S_PASS $S_PASS"); rc=$?
if (( rc == 0 )) && grep -q 'GATE GREEN' <<<"$out" \
   && grep -qE '2 passed / 0 failed / 0 skipped' <<<"$out"; then
    ok "all pass → GATE GREEN (exit 0)"
else
    bad "all-pass green" "rc=$rc out=$out"
fi

# (2) THE BUG: every scenario SKIPPED → must be RED, never GREEN.
#     Pre-fix gate exited 0 with 'GATE GREEN' here.
out=$(run_gate "$S_SKIP $S_SKIP"); rc=$?
if (( rc != 0 )) && grep -q 'GATE RED' <<<"$out" \
   && ! grep -q 'GATE GREEN' <<<"$out" \
   && grep -qE '0 passed / 0 failed / 2 skipped' <<<"$out"; then
    ok "all skipped → GATE RED (exit non-zero), never GREEN"
else
    bad "all-skip must be red" "rc=$rc out=$out"
fi

# (3) A single skip among passes still poisons the verdict → RED.
out=$(run_gate "$S_PASS $S_SKIP"); rc=$?
if (( rc != 0 )) && grep -q 'GATE RED' <<<"$out" \
   && grep -qE '1 passed / 0 failed / 1 skipped' <<<"$out"; then
    ok "one skip among passes → GATE RED"
else
    bad "single-skip red" "rc=$rc out=$out"
fi

# (4) A real failure → RED (unchanged from pre-fix, must still hold).
out=$(run_gate "$S_PASS $S_FAIL"); rc=$?
if (( rc != 0 )) && grep -q 'GATE RED' <<<"$out" \
   && grep -qE '1 passed / 1 failed / 0 skipped' <<<"$out"; then
    ok "a failing scenario → GATE RED"
else
    bad "fail red" "rc=$rc out=$out"
fi

# (5) The headline carries a passed/failed/skipped tally (B12 ask).
out=$(run_gate "$S_PASS $S_FAIL $S_SKIP"); rc=$?
if grep -qE 'tally: 1 passed / 1 failed / 1 skipped \(of 3\)' <<<"$out"; then
    ok "headline tally: passed/failed/skipped counts present"
else
    bad "tally line" "rc=$rc out=$out"
fi

echo
echo "=== CCH_GATE skip sentinel in _lib.sh ==="

# (6) A self-skip exits 77 (SKIP) whether or not CCH_GATE is set.
#
#     CONTRACT CHANGE, your-org/nexus-code#568 A6. This case previously
#     asserted the opposite — exit 0 without CCH_GATE — to "preserve the
#     run-tests.sh fast-loop contract (rc==0 == PASS) so the broad suite stays
#     green". That reasoning is exactly backwards, and A6 is the fix: the suite
#     stayed green by counting six scenarios that had asserted NOTHING as
#     passes, in the one band that guards renderer drift against the real
#     binary. `run-tests.sh` now has a real SKIP status, so a declined run is
#     reported as declined instead of being laundered into the PASS column.
( unset CCH_GATE RUN_CC_HARNESS; . "$LIB"; cch_skip_if_disabled ) >/dev/null 2>&1
rc=$?
if (( rc == 77 )); then
    ok "no CCH_GATE → self-skip still exits 77 (declined ≠ passed, #568 A6)"
else
    bad "default skip exit 77" "rc=$rc (a skip must never be laundered into a PASS)"
fi

# (7) CCH_GATE=1 keeps the same 77 (the sentinel gate.sh keys on). Retained as
#     an explicit pin that setting the gate does not perturb the exit code.
( unset RUN_CC_HARNESS; CCH_GATE=1; export CCH_GATE; . "$LIB"; cch_skip_if_disabled ) >/dev/null 2>&1
rc=$?
if (( rc == 77 )); then
    ok "CCH_GATE=1 → self-skip exits 77 (unchanged by the gate)"
else
    bad "gate skip exit 77" "rc=$rc"
fi


echo
echo "=== assertion accounting: scenario vs lint (your-org/nexus-code#1019) ==="

# A scenario stub that emits a KNOWN number of `  PASS:` lines in the same
# format the real scenarios and both lint selftests use. The whole defect is
# that the two populations share the literal prefix `  PASS: `, so the
# fixture has to share it too or it proves nothing.
mk_pass_stub() {  # $1 = name, $2 = how many PASS lines
    local p="$WORK/$1" i
    { printf '#!/usr/bin/env bash\n'
      for (( i = 1; i <= $2; i++ )); do printf 'echo "  PASS: planted-%s-%d"\n' "$1" "$i"; done
      printf 'exit 0\n'
    } > "$p"
    chmod +x "$p"
    printf '%s' "$p"
}
S_P3=$(mk_pass_stub pass3.sh 3)
S_P2=$(mk_pass_stub pass2.sh 2)

# (8) The split is emitted at all, with all three fields present.
out=$(run_gate "$S_P3"); rc=$?
if grep -qE '^=== gate-assertions: scenario=[0-9]+ lint=[0-9]+ total=[0-9]+ ===$' <<<"$out"; then
    ok "the gate emits an un-conflated assertion split"
else
    bad "assertion split emitted" "rc=$rc out=$(grep -E 'gate-assertions|GATE ' <<<"$out")"
fi

# (9) THE ANTI-CONFLATION ASSERTION, keyed on the VALUE and not on the line's
#     shape. Two stubs plant 3 + 2 = 5 scenario PASS lines. The lint
#     selftests contribute their own (65 at 989b888, and deliberately NOT
#     pinned here — the count grows as the lints gain coverage, which is
#     exactly why #1019 asks for a DERIVED number). So:
#       scenario == 5            <- conflation would make this 5 + lint
#       lint     >  0            <- the pre-flight actually asserted
#       total    == scenario + lint
#     A conflated implementation cannot satisfy the first and the third at
#     once, which is what makes this a property check rather than a
#     transcription check.
out=$(run_gate "$S_P3 $S_P2"); rc=$?
a_scen=$(sed -n 's/^=== gate-assertions: scenario=\([0-9]*\) .*$/\1/p' <<<"$out" | tail -n1)
a_lint=$(sed -n 's/^=== gate-assertions: .* lint=\([0-9]*\) .*$/\1/p' <<<"$out" | tail -n1)
a_tot=$(sed -n 's/^=== gate-assertions: .* total=\([0-9]*\) ===$/\1/p' <<<"$out" | tail -n1)
if [[ "$a_scen" == "5" ]]; then
    ok "scenario assertions counted from the scenario region ONLY (5 planted, 5 reported)"
else
    bad "scenario count excludes lint selftests" "got scenario=$a_scen want 5 (conflation would give 5+lint); lint=$a_lint total=$a_tot"
fi
if [[ "$a_lint" =~ ^[1-9][0-9]*$ ]]; then
    ok "lint assertions counted and non-zero (the pre-flight asserted something)"
else
    bad "lint count non-zero" "got lint=$a_lint"
fi
if [[ "$a_scen" =~ ^[0-9]+$ && "$a_lint" =~ ^[0-9]+$ && "$a_tot" == "$(( a_scen + a_lint ))" ]]; then
    ok "total == scenario + lint (the three numbers are consistent)"
else
    bad "total reconciles" "scenario=$a_scen lint=$a_lint total=$a_tot"
fi

# (10) A VACUOUS SAFETY PRE-FLIGHT MUST NOT YIELD A GREEN.
#
#      #1019's second property: `lint=0` means the pre-flight silently did
#      not run, and before the count was emitted that was indistinguishable
#      from a small lint suite. Driven by standing up a MINIMAL fake harness
#      root whose two lint scripts exit 0 and assert nothing — a real
#      vacuous guard, not a stubbed-out predicate. The lint PATHS are
#      deliberately NOT overridable in production (an env var that can
#      replace the mass-kill / tmux-server-kill pre-flight is a footgun
#      worse than the defect), so the fixture is a tree rather than a knob.
FAKE="$WORK/fakeroot"
mkdir -p "$FAKE/monitor/cc-harness"
cp "$GATE" "$FAKE/monitor/cc-harness/gate.sh"
cp "$_repo_root/monitor/_node-bootstrap.sh" "$_repo_root/monitor/_trash.sh" "$FAKE/monitor/"
for _l in lint-no-mass-kill lint-no-tmux-server-kill; do
    printf '#!/usr/bin/env bash\n# vacuous by construction: exits 0, asserts nothing\nexit 0\n' \
        > "$FAKE/monitor/cc-harness/$_l.sh"
    chmod +x "$FAKE/monitor/cc-harness/$_l.sh"
done
# POTENCY CONTROL: the planted lints must really assert nothing, or the case
# below passes for the wrong reason (an inert mutant and a live one produce
# byte-identical output — your-org/nexus-code#1131 residual 2 is exactly
# this failure).
_fake_lint_passes=$(bash "$FAKE/monitor/cc-harness/lint-no-mass-kill.sh" --selftest 2>/dev/null | grep -c '^  PASS:')
if [[ "$_fake_lint_passes" == "0" ]]; then
    ok "POTENCY: the planted vacuous lint really asserts nothing (0 PASS lines)"
else
    bad "vacuous lint potency" "planted lint emitted $_fake_lint_passes PASS lines — the case below would prove nothing"
fi
out=$(CCH_GATE_SCENARIOS="$S_P3" bash "$FAKE/monitor/cc-harness/gate.sh" \
          --claude-bin "$CLAUDE_STUB" 2>&1); rc=$?
if (( rc != 0 )) && grep -q 'lint=0' <<<"$out" \
   && grep -q 'SAFETY PRE-FLIGHT ASSERTED NOTHING' <<<"$out" \
   && ! grep -q 'GATE GREEN' <<<"$out"; then
    ok "a vacuous safety pre-flight (lint=0) is REFUSED, never green"
else
    bad "vacuous pre-flight refused" "rc=$rc out=$(grep -E 'gate-assertions|GATE |ASSERTED' <<<"$out")"
fi

echo
echo "=== tree attribution: a verdict carries its subject (your-org/nexus-code#1259) ==="

# (11) An attributable run stamps the tree — and the assertion is on the
#      VALUE, not on the line's shape: the stamped head must be the head
#      this repository is actually at. A stamp that merely EXISTS would
#      satisfy a shape check while naming the wrong tree, which is the
#      defect #1259 describes rather than a fix for it.
out=$(run_gate "$S_PASS"); rc=$?
want_head=$(git -C "$_repo_root" rev-parse HEAD 2>/dev/null)
got_head=$(sed -n 's/^=== gated-tree: head=\([0-9a-f]*\) .*$/\1/p' <<<"$out" | tail -n1)
if [[ -n "$want_head" && "$got_head" == "$want_head" ]]; then
    ok "the gate stamps the ACTUAL head of the tree it gated ($got_head)"
else
    bad "gated-tree head is the real head" "stamped='$got_head' actual='$want_head'"
fi
# The blob of the artefact the scenarios assert THROUGH. On 2026-09-01 this
# was the only field that distinguished the RED tree from the GREEN one
# (08ed8ea7 vs 69b3d1ed), and it had to be reconstructed by hand.
want_blob=$(git -C "$_repo_root" rev-parse HEAD:monitor/pane-state.sh 2>/dev/null)
got_blob=$(sed -n 's/^=== gated-tree: .* subject_blob=\([0-9a-f]*\) ===$/\1/p' <<<"$out" | tail -n1)
if [[ -n "$want_blob" && "$got_blob" == "$want_blob" ]]; then
    ok "the stamp carries the gated blob of the classifier under test"
else
    bad "gated-tree subject blob" "stamped='$got_blob' actual='$want_blob'"
fi

# (12) THE THIRD OUTCOME. "I could not establish which tree I gated" is
#      neither green nor red. Asserted as `rc == 3` AND explicitly as
#      `rc != 0 && rc != 1`, because the property is non-collapse: as a 0 it
#      licenses a bump on evidence about nothing; as a 1 it attributes to the
#      candidate a red whose cause could be the checkout. Both directions are
#      the #1259 defect. Driven with an unusable git, mirroring
#      `_CLONE_DRIFT_GIT_BIN` in monitor/watcher/_clone_drift.sh.
out=$(CCH_GATE_SCENARIOS="$S_PASS" _GATE_GIT_BIN="$WORK/no-such-git" \
          bash "$GATE" --claude-bin "$CLAUDE_STUB" 2>&1); rc=$?
if (( rc == 3 )) && (( rc != 0 )) && (( rc != 1 )) \
   && grep -q 'gated-tree: UNATTRIBUTABLE' <<<"$out" \
   && grep -q 'GATE UNATTRIBUTABLE' <<<"$out"; then
    ok "tree unidentifiable → a THIRD outcome (exit 3), not green and not red"
else
    bad "third outcome on an unidentifiable tree" "rc=$rc out=$(grep -E 'gated-tree|GATE ' <<<"$out")"
fi
# ...and the scenario verdict is still PRINTED, just disowned. Suppressing it
# would destroy information the operator needs; the fix is attribution, not
# silence.
if grep -q 'GATE GREEN' <<<"$out" && grep -q 'NOT a property of the candidate' <<<"$out"; then
    ok "the underlying verdict is still printed, and explicitly DISOWNED"
else
    bad "verdict printed but disowned" "out=$(grep -E 'GATE ' <<<"$out")"
fi

echo
echo "=== tracked vs untracked dirtiness (your-org/nexus-code#1320) ==="

# THE DEFECT. `_gate_stamp_tree` computed one `dirty=` from a bare
# `git status --porcelain`, WHICH COUNTS UNTRACKED FILES, and
# `cc-auto-update-apply.sh` refused any bump on it. A live primary clone is
# never free of untracked files, so the bump path was unreachable on the only
# tree that same function accepts evidence from — measured on this nexus at
# `dev` 97c385e5 and again at c055051c a day later: 21 untracked entries,
# 0 tracked modifications both times, two of them
# written by the nexus's own service supervisor.
#
# THE TEST IS A PAIR AND THE SECOND HALF IS THE POINT. Asserting only that an
# untracked file no longer blocks would pass for a stamp that had simply
# stopped measuring anything: that is a relaxation dressed as a fix. The
# POTENCY control is the tracked-modification case, which must still flip the
# field. One fixture, one variable — the same shape as the #1320 write-up's
# own table, run in both directions.
#
# A REAL GIT REPOSITORY, not a stub: the thing under test is what
# `git status` reports about trackedness, so a fixture that fakes git would
# assert nothing. Identity is passed with `-c` and NEVER written to the
# operator's global config (CLAUDE.md; your-org/nexus-code#1244).
GITFIX="$WORK/gitfix"
mkdir -p "$GITFIX/monitor/cc-harness"
cp "$GATE" "$GITFIX/monitor/cc-harness/gate.sh"
cp "$_repo_root/monitor/_node-bootstrap.sh" "$_repo_root/monitor/_trash.sh" "$GITFIX/monitor/"
for _l in lint-no-mass-kill lint-no-tmux-server-kill; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$GITFIX/monitor/cc-harness/$_l.sh"
    chmod +x "$GITFIX/monitor/cc-harness/$_l.sh"
done
# The stamp's default subject path, so `subject_blob` resolves rather than
# reading `none` and muddying a failure message.
printf '#!/usr/bin/env bash\n# fixture stand-in for the gated classifier\n' \
    > "$GITFIX/monitor/pane-state.sh"
_git_fix() { git -C "$GITFIX" -c user.email=fixture@example.invalid -c user.name=fixture "$@"; }
_gitfix_ok=1
_git_fix init -q                >/dev/null 2>&1 || _gitfix_ok=0
_git_fix add -A                 >/dev/null 2>&1 || _gitfix_ok=0
_git_fix commit -qm fixture     >/dev/null 2>&1 || _gitfix_ok=0

# stamp_of <extra-env…> — run the fixture gate and echo its `=== gated-tree:`
# line. rc is deliberately ignored: the vacuous lints make the gate RED at the
# END, long after `_gate_stamp_tree` has printed, and the stamp is the subject
# here. Field reads are by KEY, so they survive any later field being added.
_fix_stamp() {
    CCH_GATE_SCENARIOS="$S_PASS" bash "$GITFIX/monitor/cc-harness/gate.sh" \
        --claude-bin "$CLAUDE_STUB" 2>/dev/null \
        | sed -n 's/^=== gated-tree: \(.*\) ===$/\1/p' | tail -n1
}
_fix_field() {  # <stamp-line> <key>
    printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | tail -n1
}

if (( _gitfix_ok == 0 )); then
    bad "#1320 fixture repo" "could not init/commit the fixture git repo — the four cases below are UNMEASURED, not passing"
else
    # GUARD + POSITIVE CONTROL before believing any reading (CLAUDE.md
    # WORKTREE-BLIND-SPOT): a tracked file must be visible to the fixture's
    # git, or every trackedness answer below is a false zero.
    if _git_fix ls-files --error-unmatch -- monitor/cc-harness/gate.sh >/dev/null 2>&1; then
        ok "#1320 fixture: a TRACKED file is visible to the fixture's git (positive control)"
    else
        bad "#1320 fixture positive control" "gate.sh is not tracked in the fixture — readings below would be false zeros"
    fi

    # (13) CLEAN: both fields 0, untracked 0. The baseline the other two vary from.
    _st=$(_fix_stamp)
    _d=$(_fix_field "$_st" dirty); _dt=$(_fix_field "$_st" dirty_tracked); _u=$(_fix_field "$_st" untracked)
    if [[ "$_d" == "0" && "$_dt" == "0" && "$_u" == "0" ]]; then
        ok "#1320 clean tree → dirty=0 dirty_tracked=0 untracked=0"
    else
        bad "#1320 clean baseline" "dirty=$_d dirty_tracked=$_dt untracked=$_u  stamp='$_st'"
    fi

    # (14) THE DEADLOCK CASE. An UNTRACKED file alone must NOT flip the field
    #      the bump path keys on. `dirty=` still reports 1 — the audit value is
    #      unchanged and deliberately so — and `untracked=` counts it.
    printf 'operator scratch\n' > "$GITFIX/untracked-scratch.txt"
    _st=$(_fix_stamp)
    _d=$(_fix_field "$_st" dirty); _dt=$(_fix_field "$_st" dirty_tracked); _u=$(_fix_field "$_st" untracked)
    if [[ "$_dt" == "0" ]]; then
        ok "#1320 an UNTRACKED file does NOT flip dirty_tracked (the bump path stays reachable)"
    else
        bad "#1320 untracked must not block" "dirty_tracked=$_dt (want 0)  stamp='$_st'"
    fi
    if [[ "$_d" == "1" && "$_u" == "1" ]]; then
        ok "#1320 …and it is still RECORDED: dirty=1, untracked=1 (the residual stays auditable)"
    else
        bad "#1320 untracked recorded" "dirty=$_d untracked=$_u (want 1 and 1)  stamp='$_st'"
    fi

    # (15) THE POTENCY CONTROL. Same fixture, one variable changed: a TRACKED
    #      modification. If this does not flip `dirty_tracked`, case (14) above
    #      proves nothing — a field that never reports 1 would satisfy it.
    printf '\n# tracked modification\n' >> "$GITFIX/monitor/pane-state.sh"
    _st=$(_fix_stamp)
    _dt=$(_fix_field "$_st" dirty_tracked)
    if [[ "$_dt" == "1" ]]; then
        ok "POTENCY: a TRACKED modification DOES flip dirty_tracked → 1 (the field still refuses)"
    else
        bad "#1320 potency control" "a tracked modification left dirty_tracked=$_dt — case (14) proves nothing  stamp='$_st'"
    fi
    _git_fix checkout -- monitor/pane-state.sh >/dev/null 2>&1
    rm -f "$GITFIX/untracked-scratch.txt"

    # (16) FAIL CLOSED, part 1: git entirely unavailable. The stamp must be
    #      the UNATTRIBUTABLE form and must carry NO `dirty_tracked=` at all.
    #      That absence is load-bearing: `cc-auto-update-apply.sh` refuses an
    #      evidence file whose `dirty_tracked` reads empty, so "could not
    #      look" can never present as "tracked tree was clean".
    #
    #      NOTE THIS ASSERTION WAS WRONG FIRST TIME and the code was right.
    #      It asserted that no `=== gated-tree:` line appeared — but the
    #      UNATTRIBUTABLE line IS one. Asserting on the line's ABSENCE was a
    #      claim about formatting; asserting on the FIELD's absence is a
    #      claim about the property the consumer keys on.
    _st=$(CCH_GATE_SCENARIOS="$S_PASS" _GATE_GIT_BIN="$WORK/no-such-git" \
              bash "$GITFIX/monitor/cc-harness/gate.sh" --claude-bin "$CLAUDE_STUB" 2>/dev/null \
              | sed -n 's/^=== gated-tree: \(.*\) ===$/\1/p' | tail -n1)
    _dt=$(_fix_field "$_st" dirty_tracked)
    if [[ "$_st" == UNATTRIBUTABLE* && -z "$_dt" ]]; then
        ok "#1320 git unavailable → UNATTRIBUTABLE, and NO dirty_tracked field (apply.sh refuses it)"
    else
        bad "#1320 unreadable git" "stamp='$_st' dirty_tracked='$_dt' (want UNATTRIBUTABLE… and empty)"
    fi

    # (17) FAIL CLOSED, part 2 — THE ARM THAT ACTUALLY MATTERS. A git that
    #      answers `rev-parse` but FAILS `status` is attributable (so the
    #      UNATTRIBUTABLE path above does not fire) and its dirtiness is
    #      unknowable. `dirty_tracked` must say `unknown`, never `0`: a
    #      probe that could not look must not borrow the head probe's
    #      success. Without this case the split could degrade to a silent
    #      `0` on an unreadable worktree — a green about nothing, which is
    #      the #1259 defect arriving through the #1320 fix.
    _fakegit="$WORK/fakegit"
    { printf '#!/usr/bin/env bash\n'
      printf 'for a in "$@"; do [[ "$a" == status ]] && exit 9; done\n'
      printf 'exec git "$@"\n'
    } > "$_fakegit"
    chmod +x "$_fakegit"
    # POTENCY on the stub itself: it must really fail `status` and really
    # answer `rev-parse`, or case (17) proves nothing.
    "$_fakegit" -C "$GITFIX" status --porcelain >/dev/null 2>&1
    _fg_status_rc=$?
    _fg_head=$("$_fakegit" -C "$GITFIX" rev-parse HEAD 2>/dev/null)
    if (( _fg_status_rc != 0 )) && [[ "$_fg_head" =~ ^[0-9a-f]{40}$ ]]; then
        # Single quotes around the backticked words, and the whole label built
        # with printf -v: a backticked identifier inside a DOUBLE-quoted string
        # is command-substituted before `ok` ever sees it. The first version of
        # this line printed "the stub git fails  (rc=9) and still answers" —
        # both words silently DELETED, rc 127 landing on an assignment nothing
        # tests. CLAUDE.md BACKTICK-SUBSTITUTION, mode 1, in a test label.
        printf -v _fg_label 'POTENCY: the stub git fails %s (rc=%s) and still answers %s' \
               "'status'" "$_fg_status_rc" "'rev-parse'"
        ok "$_fg_label"
    else
        bad "#1320 stub git potency" "status rc=$_fg_status_rc head='$_fg_head' — case (17) would prove nothing"
    fi
    _st=$(CCH_GATE_SCENARIOS="$S_PASS" _GATE_GIT_BIN="$_fakegit" \
              bash "$GITFIX/monitor/cc-harness/gate.sh" --claude-bin "$CLAUDE_STUB" 2>/dev/null \
              | sed -n 's/^=== gated-tree: \(.*\) ===$/\1/p' | tail -n1)
    _dt=$(_fix_field "$_st" dirty_tracked); _d=$(_fix_field "$_st" dirty); _u=$(_fix_field "$_st" untracked)
    if [[ "$_dt" == "unknown" && "$_d" == "unknown" && "$_u" == "unknown" ]]; then
        ok "#1320 status unreadable → dirty_tracked=unknown (fail-closed; never a silent 0)"
    else
        bad "#1320 unreadable status" "dirty=$_d dirty_tracked=$_dt untracked=$_u (want all 'unknown')  stamp='$_st'"
    fi

    # (18)/(19) INDEPENDENCE, DRIVEN RATHER THAN ASSERTED (#1320 skeptic Q3).
    #      Case (17)'s stub matches the token `status` in BOTH invocations, so
    #      it fails both and measures only the both-fail case. The comment in
    #      gate.sh claims each probe degrades to `unknown` INDEPENDENTLY, and
    #      that is a claim about the ONE-fails-one-succeeds cases, which
    #      nothing drove. Two stubs, each failing exactly one probe.
    #
    #      The discriminator is the `--untracked-files=no` flag: the plain
    #      status probe carries it NOT, the tracked probe carries it. A stub
    #      keying on that flag can fail exactly one of the two.

    # (18) ONLY the plain `status` fails -> dirty/untracked unknown, tracked 0.
    _fg18="$WORK/fakegit18"
    { printf '#!/usr/bin/env bash\n'
      printf '_is_status=0; _has_uno=0\n'
      printf 'for a in "$@"; do\n'
      printf '  [[ "$a" == status ]] && _is_status=1\n'
      printf '  [[ "$a" == --untracked-files=no ]] && _has_uno=1\n'
      printf 'done\n'
      printf '(( _is_status && ! _has_uno )) && exit 9\n'
      printf 'exec git "$@"\n'
    } > "$_fg18"; chmod +x "$_fg18"
    # POTENCY on the stub: it must fail the PLAIN status and PASS the tracked one.
    "$_fg18" -C "$GITFIX" status --porcelain >/dev/null 2>&1; _r_plain=$?
    "$_fg18" -C "$GITFIX" status --porcelain --untracked-files=no >/dev/null 2>&1; _r_trk=$?
    if (( _r_plain != 0 && _r_trk == 0 )); then
        ok "POTENCY: stub18 fails ONLY the plain status (plain=$_r_plain tracked=$_r_trk)"
    else
        bad "#1320 stub18 potency" "plain=$_r_plain tracked=$_r_trk — case (18) would prove nothing"
    fi
    _st=$(CCH_GATE_SCENARIOS="$S_PASS" _GATE_GIT_BIN="$_fg18" \
              bash "$GITFIX/monitor/cc-harness/gate.sh" --claude-bin "$CLAUDE_STUB" 2>/dev/null \
              | sed -n 's/^=== gated-tree: \(.*\) ===$/\1/p' | tail -n1)
    _d=$(_fix_field "$_st" dirty); _dt=$(_fix_field "$_st" dirty_tracked); _u=$(_fix_field "$_st" untracked)
    if [[ "$_d" == "unknown" && "$_u" == "unknown" && "$_dt" == "0" ]]; then
        ok "#1320 INDEPENDENCE: plain status fails alone → dirty/untracked unknown, dirty_tracked=0"
    else
        bad "#1320 independence (plain fails)" "dirty=$_d dirty_tracked=$_dt untracked=$_u  stamp='$_st'"
    fi

    # (19) ONLY the tracked probe fails -> dirty_tracked unknown, dirty/untracked real.
    #      THIS IS THE DIRECTION THAT MATTERS: dirty_tracked is what the bump
    #      keys on, so it must read `unknown` and NOT borrow the plain probe's
    #      success. A silent 0 here would be a green about nothing.
    _fg19="$WORK/fakegit19"
    { printf '#!/usr/bin/env bash\n'
      printf 'for a in "$@"; do [[ "$a" == --untracked-files=no ]] && exit 9; done\n'
      printf 'exec git "$@"\n'
    } > "$_fg19"; chmod +x "$_fg19"
    "$_fg19" -C "$GITFIX" status --porcelain >/dev/null 2>&1; _r_plain=$?
    "$_fg19" -C "$GITFIX" status --porcelain --untracked-files=no >/dev/null 2>&1; _r_trk=$?
    if (( _r_plain == 0 && _r_trk != 0 )); then
        ok "POTENCY: stub19 fails ONLY the tracked status (plain=$_r_plain tracked=$_r_trk)"
    else
        bad "#1320 stub19 potency" "plain=$_r_plain tracked=$_r_trk — case (19) would prove nothing"
    fi
    _st=$(CCH_GATE_SCENARIOS="$S_PASS" _GATE_GIT_BIN="$_fg19" \
              bash "$GITFIX/monitor/cc-harness/gate.sh" --claude-bin "$CLAUDE_STUB" 2>/dev/null \
              | sed -n 's/^=== gated-tree: \(.*\) ===$/\1/p' | tail -n1)
    _dt=$(_fix_field "$_st" dirty_tracked); _d=$(_fix_field "$_st" dirty)
    if [[ "$_dt" == "unknown" && "$_d" != "unknown" ]]; then
        ok "#1320 INDEPENDENCE: tracked probe fails alone → dirty_tracked=unknown, NOT a borrowed 0"
    else
        bad "#1320 independence (tracked fails)" "dirty=$_d dirty_tracked=$_dt  stamp='$_st'"
    fi
fi

echo
echo "=== production TUI geometry: resolved, stamped, and gated (your-org/nexus-code#1448) ==="
# The gate used to run every scenario in the binary's default geometry while
# production runs `tui: fullscreen`, and its log recorded nothing about which.
# `_gate_resolve_tui` reads the ONE key `tui` from where production reads it,
# exports CCH_TUI so `cch_write_settings` renders it, and STAMPS the resolved
# mode beside the tree stamp. Hermetic: HOME and CLAUDE_CONFIG_DIR point at
# fixtures under $WORK, so the operator's real settings.json is never read.
#
# TWO INSTRUMENTS, CHOSEN BY COST. A full `gate.sh` run stamps the tree and
# builds the coverage report over the real repo -- ~35 s here, ~70 s in CI's
# zsh band -- and this section's first version drove all eight arms that way,
# which added ~6 min to the slowest CI band and pushed it over its 40-minute
# ceiling (PR 1473, job cancelled at 40m17s with 434/463 reported and zero
# FAILs). So: the three arms where the STAMP-VS-ENVIRONMENT agreement is the
# point run END TO END through the real gate with a probe scenario recording
# what a scenario actually SEES -- config-dir resolution, hostile rejection
# (with a sentinel that must not leak), and the invalid-preset refusal with
# its valid-preset control. The five arms that exercise the resolver's own
# branching (home fallback, preset precedence, non-string, no-file, no-key)
# drive the FUNCTION, extracted from gate.sh the way this corpus extracts
# `respawn_agent` from main.sh, in a subshell that reports the CCH_TUI it
# would have exported -- the same agreement property, sub-second.

TUI_SEEN="$WORK/tui-seen"
S_TUI="$WORK/tui-probe.sh"
{
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "${CCH_TUI-UNSET}" > %q\n' "$TUI_SEEN"
    printf 'exit 0\n'
} > "$S_TUI"
chmod +x "$S_TUI"

# $1 = HOME fixture, $2 = CLAUDE_CONFIG_DIR fixture ("" => unset), rest = extra
# `K=V` for env. CCH_TUI is scrubbed from the inherited environment first so
# a runner that happens to export it cannot turn the "unresolved" arms green.
run_gate_tui() {
    local home="$1" cfg="$2"; shift 2
    # All `-u` flags BEFORE the first NAME=VALUE: env(1) parses options first,
    # and relying on getopt permutation to find a later `-u` is a portability bet.
    local -a envargs=(-u CCH_TUI)
    [[ -n "$cfg" ]] || envargs+=(-u CLAUDE_CONFIG_DIR)
    envargs+=("HOME=$home")
    [[ -n "$cfg" ]] && envargs+=("CLAUDE_CONFIG_DIR=$cfg")
    envargs+=("$@" "CCH_GATE_SCENARIOS=$S_TUI")
    rm -f "$TUI_SEEN"
    env "${envargs[@]}" bash "$GATE" --claude-bin "$CLAUDE_STUB" 2>&1
}
seen() { cat "$TUI_SEEN" 2>/dev/null || printf 'NO-SCENARIO-RAN'; }

# The resolver's BODY, extracted from the gate so it can be driven without a
# gate run. Positive control first: an extraction that came back empty would
# make every function-level arm below vacuous.
resolve_tui_body=$(awk '
    /^_gate_resolve_tui\(\) \{$/ { capture = 1 }
    capture { print }
    capture && /^\}$/ { capture = 0 }
' "$GATE")
if [[ "$resolve_tui_body" == *'gated-tui: mode='* ]]; then
    ok "#1448 positive control: _gate_resolve_tui extracted from gate.sh (body names the stamp)"
else
    bad "#1448 resolver extraction" "empty or unrecognised body — the function-level arms below would be vacuous"
fi
# $1 = HOME, $2 = CLAUDE_CONFIG_DIR ("" => unset), rest = extra K=V. Prints the
# resolver's stdout, then one line `SEEN=<CCH_TUI as a scenario would see it>`.
run_resolver() {
    local home="$1" cfg="$2"; shift 2
    local -a envargs=(-u CCH_TUI)
    [[ -n "$cfg" ]] || envargs+=(-u CLAUDE_CONFIG_DIR)
    envargs+=("HOME=$home")
    [[ -n "$cfg" ]] && envargs+=("CLAUDE_CONFIG_DIR=$cfg")
    envargs+=("$@")
    env "${envargs[@]}" bash -c "$resolve_tui_body"'
        _gate_resolve_tui 2>&1
        printf "SEEN=%s\n" "${CCH_TUI-UNSET}"'
}
seen_of() { sed -n 's/^SEEN=//p' <<<"$1" | tail -1; }

TH="$WORK/tui-home"; TC="$WORK/tui-cfg"; TE="$WORK/tui-empty-home"; TEC="$WORK/tui-empty-cfg"
mkdir -p "$TH/.claude" "$TC" "$TE" "$TEC"

# (1) END TO END: CLAUDE_CONFIG_DIR carries `tui: fullscreen` -> stamped from
#     config-dir, and the SCENARIO sees CCH_TUI=fullscreen.
printf '{"tui": "fullscreen", "editorMode": "vim"}\n' > "$TC/settings.json"
printf '{}\n' > "$TH/.claude/settings.json"
out=$(run_gate_tui "$TH" "$TC"); rc=$?
if grep -qF '=== gated-tui: mode=fullscreen source=config-dir ===' <<<"$out"; then
    ok "#1448 config-dir tui resolves and is STAMPED as source=config-dir"
else
    bad "#1448 config-dir stamp" "rc=$rc out=$(grep -F 'gated-tui' <<<"$out")"
fi
if [[ "$(seen)" == "fullscreen" ]]; then
    ok "#1448 …and the scenario SAW CCH_TUI=fullscreen (stamp and environment agree)"
else
    bad "#1448 scenario env (config-dir)" "seen=$(seen)"
fi

# (2) FUNCTION: config-dir has NO tui key, HOME/.claude does -> source=home.
printf '{"editorMode": "vim"}\n' > "$TC/settings.json"
printf '{"tui": "fullscreen"}\n'  > "$TH/.claude/settings.json"
out=$(run_resolver "$TH" "$TC")
if grep -qF '=== gated-tui: mode=fullscreen source=home ===' <<<"$out" && [[ "$(seen_of "$out")" == "fullscreen" ]]; then
    ok "#1448 falls through to HOME/.claude when config-dir has no tui key (source=home), CCH_TUI exported"
else
    bad "#1448 home fallback" "out=$out"
fi

# (3) FUNCTION: an explicit preset WINS over a resolvable config and is not
#     overridden -- the CI matrix depends on this.
printf '{"tui": "compact"}\n' > "$TC/settings.json"
out=$(run_resolver "$TH" "$TC" "CCH_TUI=fullscreen")
if grep -qF '=== gated-tui: mode=fullscreen source=preset ===' <<<"$out" && [[ "$(seen_of "$out")" == "fullscreen" ]]; then
    ok "#1448 a preset CCH_TUI wins over settings.json and is stamped source=preset"
else
    bad "#1448 preset precedence" "out=$out"
fi

# (4) END TO END: HOSTILE value beside a sentinel secret: rejected whole,
#     nothing from the file reaches stdout/stderr or the scenario environment.
#     The sentinel is first shown to be IN the file, so the zero is measured.
SENTINEL='SENTINEL-KEY-9f3a7c'
printf '{"tui": "fullscreen; echo PWNED", "apiKeyHelper": "echo %s", "env": {"TOKEN": "%s"}}\n' "$SENTINEL" "$SENTINEL" > "$TC/settings.json"
printf '{}\n' > "$TH/.claude/settings.json"
if (( $(grep -cF "$SENTINEL" "$TC/settings.json") == 1 )); then
    ok "#1448 positive control: the sentinel IS in the planted settings.json"
else
    bad "#1448 sentinel plant" "the fixture does not contain the sentinel; the leak check below would be vacuous"
fi
out=$(run_gate_tui "$TH" "$TC"); rc=$?
if grep -qF '=== gated-tui: mode=binary-default source=unresolved reason=rejected-value ===' <<<"$out" && [[ "$(seen)" == "UNSET" ]]; then
    ok "#1448 a non-token tui value is REJECTED whole: stamped unresolved/rejected-value, scenario sees CCH_TUI unset"
else
    bad "#1448 hostile rejection" "rc=$rc seen=$(seen) out=$(grep -F 'gated-tui' <<<"$out")"
fi
if ! grep -qF "$SENTINEL" <<<"$out" && ! grep -qF 'PWNED' <<<"$out"; then
    ok "#1448 …and neither the sentinel nor the injected command text appears anywhere in the gate's output"
else
    bad "#1448 settings.json content LEAKED into gate output" "$(grep -nF -e "$SENTINEL" -e PWNED <<<"$out")"
fi

# (5) FUNCTION: a non-string `tui` (object) arrives from jq as JSON text and
#     fails the same token rule.
printf '{"tui": {"mode": "fullscreen"}}\n' > "$TC/settings.json"
out=$(run_resolver "$TH" "$TC")
if grep -qF 'source=unresolved reason=rejected-value' <<<"$out" && [[ "$(seen_of "$out")" == "UNSET" ]]; then
    ok "#1448 a non-string tui value is rejected, not stringified into the harness"
else
    bad "#1448 non-string tui" "out=$out"
fi

# (6) FUNCTION: nothing to read anywhere -> unresolved, the reason names it,
#     CCH_TUI stays unset, and it is LOUD (the NOTE on stderr).
out=$(run_resolver "$TE" "$TEC")
if grep -qF '=== gated-tui: mode=binary-default source=unresolved reason=no-settings-file ===' <<<"$out" && [[ "$(seen_of "$out")" == "UNSET" ]]; then
    ok "#1448 no settings.json anywhere -> unresolved/no-settings-file, CCH_TUI unset"
else
    bad "#1448 unresolved arm" "out=$out"
fi
if grep -qF 'gate.sh: NOTE' <<<"$out" && grep -qF 'reason=no-settings-file' <<<"$out"; then
    ok "#1448 …and it is LOUD: the NOTE on stderr names the reason"
else
    bad "#1448 unresolved NOTE" "$(grep -F 'NOTE' <<<"$out")"
fi

# (7) FUNCTION: a settings.json with no tui key -> reason=no-tui-key (distinct
#     from no file).
printf '{"editorMode": "vim"}\n' > "$TEC/settings.json"
out=$(run_resolver "$TE" "$TEC")
if grep -qF 'source=unresolved reason=no-tui-key' <<<"$out" && [[ "$(seen_of "$out")" == "UNSET" ]]; then
    ok "#1448 a settings.json without tui -> reason=no-tui-key"
else
    bad "#1448 no-tui-key reason" "out=$out"
fi
rm -f "$TEC/settings.json"

# (8) END TO END: an INVALID preset is REFUSED (exit 2), before any scenario
#     runs -- a preset the harness would splice into JSON unvalidated must not
#     be stamped as binary-default and then written anyway.
printf '{"tui": "compact"}\n' > "$TC/settings.json"
out=$(run_gate_tui "$TH" "$TC" "CCH_TUI=Full Screen"); rc=$?
if (( rc == 2 )) && grep -qF 'gate.sh: REFUSED' <<<"$out" && ! grep -qF 'gated-tui:' <<<"$out" \
   && [[ "$(seen)" == "NO-SCENARIO-RAN" ]]; then
    ok "#1448 an invalid preset is REFUSED at exit 2 with no stamp and no scenario run"
else
    bad "#1448 invalid preset must refuse" "rc=$rc seen=$(seen) out=$(grep -E 'REFUSED|gated-tui|GATE ' <<<"$out")"
fi
# Mutation-shaped control for (8): the same call with a VALID preset runs the
# scenario, renders a verdict, and the scenario sees the preset.
out=$(run_gate_tui "$TH" "$TC" "CCH_TUI=fullscreen"); rc=$?
if (( rc == 0 )) && grep -qF 'GATE GREEN' <<<"$out" && [[ "$(seen)" == "fullscreen" ]]; then
    ok "#1448 …control: the identical call with a valid preset runs the scenario (rc 0, GATE GREEN, scenario sees it)"
else
    bad "#1448 valid-preset control" "rc=$rc seen=$(seen) out=$(grep -E 'GATE ' <<<"$out")"
fi

echo
echo "=== #1002: gate.sh --keep-prefix + cch_stage_candidate (stub npm on a private PATH) ==="

# THE HAZARD (your-org/nexus-code#1002): the non-gate probes need a candidate
# binary IN HAND, gate.sh tears its throwaway prefix down on exit, and the
# obvious ad-hoc form — `cd <dir> && npm install …` — walks UP to the nexus
# root's package.json and installs into the LIVE node_modules at rc 0.
# Two fixes are under test: `--keep-prefix` skips the teardown and prints the
# staged path; `cch_stage_candidate` in _lib.sh is the single
# root-resolution-immune install both the gate and an ad-hoc probe go through.
#
# A stub `npm` stands in for the real one in exactly the property under test:
# it honours `--prefix <dir>` and stages `<dir>/node_modules/.bin/claude`
# printing the requested version. It REFUSES (rc 9) any call WITHOUT
# `--prefix` — the walk-up shape — so a gate.sh or helper that dropped the flag
# fails here rather than "installing" somewhere unasserted. Every argv is
# logged so the FORM of the call is asserted, not inferred from its effect.
# STUB_NPM_STAGES_NOTHING=1 / STUB_NPM_STAGES_VERSION=<v> drive the helper's
# two refusal arms (no binary produced / wrong version produced).
NPMBIN="$WORK/npmbin"; mkdir -p "$NPMBIN"
NPMLOG="$WORK/npm-calls.log"; : > "$NPMLOG"
cat > "$NPMBIN/npm" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$NPMLOG"
prefix=""; spec=""
while (( \$# > 0 )); do
    case "\$1" in
        --prefix)   prefix="\$2"; shift 2 ;;
        --prefix=*) prefix="\${1#--prefix=}"; shift ;;
        @*)         spec="\$1"; shift ;;
        *)          shift ;;
    esac
done
[[ -n "\$prefix" ]] || { echo "stub npm: NO --prefix — refusing to walk up (the #1002 shape)" >&2; exit 9; }
[[ "\${STUB_NPM_STAGES_NOTHING:-0}" == 1 ]] && exit 0
ver="\${spec##*@}"
[[ -n "\${STUB_NPM_STAGES_VERSION:-}" ]] && ver="\$STUB_NPM_STAGES_VERSION"
mkdir -p "\$prefix/node_modules/.bin" || exit 1
printf '#!/usr/bin/env bash\necho "%s (Claude Code)"\n' "\$ver" > "\$prefix/node_modules/.bin/claude"
chmod +x "\$prefix/node_modules/.bin/claude"
exit 0
STUB
chmod +x "$NPMBIN/npm"

# POTENCY of the stub itself, both arms — or every case below could pass on a
# stub that stages nothing (inert) or accepts anything (permissive).
_pot="$WORK/npm-potency"; mkdir -p "$_pot"
( cd "$_pot" && PATH="$NPMBIN:$PATH" npm install --no-save @anthropic-ai/claude-code@1.2.3 >/dev/null 2>&1 ); _rc_noprefix=$?
PATH="$NPMBIN:$PATH" npm install --prefix "$_pot/p" --no-save @anthropic-ai/claude-code@1.2.3 >/dev/null 2>&1; _rc_prefix=$?
if (( _rc_noprefix == 9 )) && [[ ! -e "$_pot/node_modules/.bin/claude" ]] \
   && (( _rc_prefix == 0 )) && [[ "$("$_pot/p/node_modules/.bin/claude" --version 2>/dev/null)" == "1.2.3 (Claude Code)" ]]; then
    ok "#1002 POTENCY: stub npm refuses a prefix-less install (rc 9, nothing staged) and stages under --prefix"
else
    bad "#1002 stub npm potency" "noprefix rc=$_rc_noprefix prefix rc=$_rc_prefix"
fi
: > "$NPMLOG"

TRASH="$WORK/trash"; mkdir -p "$TRASH"
_trash_count() { ls -A "$TRASH" 2>/dev/null | grep -c '' || true; }
run_gate_ver() {   # $@ = extra gate.sh args; the scenario list is one passing stub
    CCH_GATE_SCENARIOS="$S_PASS" NEXUS_TRASH_DIR="$TRASH" PATH="$NPMBIN:$PATH" \
        bash "$GATE" --version 9.9.9 "$@" 2>&1
}
_kept_bin() {   # the claude_bin= field of the LAST kept-prefix line in $1
    sed -n 's/^=== kept-prefix: claude_bin=\([^ ]*\) prefix=\([^ ]*\) ===$/\1/p' <<<"$1" | tail -1
}
_installed_prefix() {   # the prefix the install banner named
    sed -n '/^=== installing @anthropic-ai\/claude-code@9.9.9 into throwaway prefix ===$/{n;s/^ *//;p;q}' <<<"$1"
}

# (K1) CONTROL — the default is unchanged: the prefix is torn down on exit and
#      NO kept-prefix line is printed. Without this, K2 could pass on a gate
#      that simply stopped cleaning up.
out=$(run_gate_ver); rc=$?
pfx=$(_installed_prefix "$out")
if (( rc == 0 )) && grep -q 'GATE GREEN' <<<"$out" && [[ -n "$pfx" && ! -d "$pfx" ]] \
   && [[ "$(_trash_count)" == 1 ]] && ! grep -q 'kept-prefix' <<<"$out"; then
    ok "#1002 K1 CONTROL: without --keep-prefix the prefix is MOVED ASIDE on exit (1 trash entry, path gone) and no kept-prefix line prints"
else
    bad "#1002 K1 default teardown" "rc=$rc prefix=$pfx exists=$([[ -d "$pfx" ]] && echo yes || echo no) trash=$(_trash_count) out=$(grep -E 'GATE |kept-prefix|installing' <<<"$out")"
fi

# (K2) --keep-prefix: same gate, same verdict, but the staged install SURVIVES
#      the EXIT trap and the binary path is printed in a greppable line.
out=$(run_gate_ver --keep-prefix); rc=$?
kept=$(_kept_bin "$out"); pfx=$(_installed_prefix "$out")
if (( rc == 0 )) && grep -q 'GATE GREEN' <<<"$out" && [[ -n "$kept" && -x "$kept" ]] \
   && [[ "$("$kept" --version 2>/dev/null)" == "9.9.9 (Claude Code)" ]]; then
    ok "#1002 K2 --keep-prefix: GATE GREEN (rc 0) AND the staged binary survives at the printed path, reporting the candidate"
else
    bad "#1002 K2 keep-prefix" "rc=$rc kept=$kept exists=$([[ -x "$kept" ]] && echo yes || echo no) out=$(grep -E 'GATE |kept-prefix' <<<"$out")"
fi
if [[ -n "$pfx" && "$kept" == "$pfx/node_modules/.bin/claude" ]] && [[ "$(_trash_count)" == 1 ]]; then
    ok "#1002 K2 …the kept path is <prefix>/node_modules/.bin/claude and the prefix was NOT trashed (trash count unchanged at 1)"
else
    bad "#1002 K2 kept path / trash" "kept=$kept prefix=$pfx trash=$(_trash_count)"
fi
[[ -n "$pfx" && -d "$pfx" ]] && rm -rf "$pfx"

# (K3) --keep-prefix without --version is a usage error: there is no prefix to
#      keep, and a silent accept would print a kept-prefix line naming the
#      LIVE binary — the exact confusion #1002 is about.
out=$(CCH_GATE_SCENARIOS="$S_PASS" bash "$GATE" --keep-prefix --claude-bin "$CLAUDE_STUB" 2>&1); rc=$?
if (( rc == 2 )) && ! grep -q 'kept-prefix' <<<"$out" && ! grep -q 'GATE ' <<<"$out"; then
    ok "#1002 K3 --keep-prefix without --version → rc 2, no gate run, no kept-prefix line"
else
    bad "#1002 K3 keep-prefix usage" "rc=$rc out=$(head -3 <<<"$out")"
fi

# (K4) THE FORM. Every npm call the gate made carried --prefix <its prefix> and
#      --no-save and the exact package spec — asserted from the argv log, not
#      inferred from the green (a green only says SOMETHING got staged).
n_calls=$(grep -c '' "$NPMLOG" || true)
n_prefixed=$(grep -c -- '--prefix ' "$NPMLOG" || true)
if (( n_calls >= 2 )) && (( n_calls == n_prefixed )) \
   && ! grep -vq -- '--no-save' "$NPMLOG" \
   && ! grep -vq -- '@anthropic-ai/claude-code@9.9.9' "$NPMLOG"; then
    ok "#1002 K4 every npm call the gate made was 'install --prefix <dir> --no-save @anthropic-ai/claude-code@9.9.9' ($n_calls calls)"
else
    bad "#1002 K4 npm call form" "calls=$n_calls prefixed=$n_prefixed log=$(tr '\n' '|' < "$NPMLOG")"
fi

# (K5) cch_stage_candidate directly — the helper gate.sh now goes through, and
#      the one an ad-hoc probe is told to use. Exit vocabulary: 0 path printed;
#      2 usage (empty version, or a prefix that IS the nexus root); 3 the stage
#      produced no binary under the prefix; 4 the binary does not report the
#      requested version. 3 and 4 are the two shapes a mis-rooted install takes.
stage() { ( PATH="$NPMBIN:$PATH"; . "$LIB"; cch_stage_candidate "$@" ); }
p=$(stage 9.9.9 "$WORK/stage1" 2>/dev/null); rc=$?
if (( rc == 0 )) && [[ "$p" == "$WORK/stage1/node_modules/.bin/claude" && -x "$p" ]] \
   && [[ "$("$p" --version 2>/dev/null)" == "9.9.9 (Claude Code)" ]]; then
    ok "#1002 K5a cch_stage_candidate <v> <prefix> → rc 0, prints <prefix>/node_modules/.bin/claude, binary reports <v>"
else
    bad "#1002 K5a stage" "rc=$rc p=$p"
fi
mkdir -p "$WORK/stagetmp"
p=$(TMPDIR="$WORK/stagetmp" stage 9.9.9 2>/dev/null); rc=$?
if (( rc == 0 )) && [[ "$p" == "$WORK/stagetmp/"*"/node_modules/.bin/claude" && -x "$p" ]]; then
    ok "#1002 K5b …with no prefix it stages under a fresh mktemp dir beneath TMPDIR"
else
    bad "#1002 K5b default prefix" "rc=$rc p=$p"
fi
stage "" "$WORK/stage2" >/dev/null 2>&1; rc=$?
(( rc == 2 )) && ok "#1002 K5c an empty version is a usage error (rc 2)" || bad "#1002 K5c empty version" "rc=$rc"
: > "$NPMLOG"
stage 9.9.9 "$_repo_root" >/dev/null 2>&1; rc=$?
if (( rc == 2 )) && [[ ! -s "$NPMLOG" ]]; then
    ok "#1002 K5d a prefix that IS the nexus root is REFUSED (rc 2) before npm is ever invoked"
else
    bad "#1002 K5d nexus-root prefix" "rc=$rc npm-calls=$(tr '\n' '|' < "$NPMLOG")"
fi
# (K5d2) …and the refusal has NO side effect: a copy of the library rooted in a
#        fixture tree refuses <fixture>/node_modules and leaves it UNCREATED.
#        A `mkdir -p` that ran ahead of the check left an empty node_modules/
#        in the live tree as the refusal's own footprint (measured).
FR="$WORK/fakeroot-stage"; mkdir -p "$FR/monitor/cc-harness"
cp "$LIB" "$FR/monitor/cc-harness/_lib.sh"; cp "$_repo_root/monitor/_trash.sh" "$FR/monitor/"
( PATH="$NPMBIN:$PATH"; . "$FR/monitor/cc-harness/_lib.sh"; cch_stage_candidate 9.9.9 "$FR/node_modules" ) >/dev/null 2>&1; rc=$?
if (( rc == 2 )) && [[ ! -e "$FR/node_modules" ]]; then
    ok "#1002 K5d2 refusing <root>/node_modules creates NOTHING (no empty node_modules/ left behind)"
else
    bad "#1002 K5d2 refusal side effect" "rc=$rc node_modules=$([[ -e "$FR/node_modules" ]] && echo CREATED || echo absent)"
fi
STUB_NPM_STAGES_NOTHING=1 stage 9.9.9 "$WORK/stage3" >/dev/null 2>&1; rc=$?
(( rc == 3 )) && ok "#1002 K5e an install that produced NO binary under the prefix → rc 3 (the mis-rooted-install shape)" \
    || bad "#1002 K5e missing binary" "rc=$rc"
STUB_NPM_STAGES_VERSION=1.0.0 stage 9.9.9 "$WORK/stage4" >/dev/null 2>&1; rc=$?
(( rc == 4 )) && ok "#1002 K5f a staged binary reporting the WRONG version → rc 4 (never printed as the candidate)" \
    || bad "#1002 K5f wrong version" "rc=$rc"
# the refusal arms must not have printed a path a caller could export
p=$(STUB_NPM_STAGES_VERSION=1.0.0 stage 9.9.9 "$WORK/stage5" 2>/dev/null)
[[ -z "$p" ]] && ok "#1002 K5g …and a refusing stage prints NOTHING on stdout (no path to export)" \
    || bad "#1002 K5g refusal printed a path" "p=$p"

echo
echo "=== summary ==="
printf '  %d pass / %d fail\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    echo "FAIL"
    exit 1
fi
echo "ALL TESTS PASSED"
exit 0
