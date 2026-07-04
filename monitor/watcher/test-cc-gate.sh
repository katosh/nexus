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
# Mechanism: CCH_GATE=1 makes a self-skip exit 77 (autotools SKIP
# sentinel) instead of 0, WITHOUT changing the exit-0 self-skip the
# fast-loop runner (run-tests.sh, counts rc==0 as PASS) relies on. The
# gate classifies 0=pass / 77=skip / other=fail and goes RED on any skip
# or fail, with a passed/failed/skipped tally in the headline.
#
# Fully hermetic: the gate's scenario list is overridden with stub
# scripts via CCH_GATE_SCENARIOS, and a real claude binary is stood in
# with /bin/bash (--claude-bin), so no node / npm / tmux / network.
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

# (6) Without CCH_GATE, a self-skip exits 0 — preserves the run-tests.sh
#     fast-loop contract (rc==0 == PASS) so the broad suite stays green.
( unset CCH_GATE RUN_CC_HARNESS; . "$LIB"; cch_skip_if_disabled ) >/dev/null 2>&1
rc=$?
if (( rc == 0 )); then
    ok "no CCH_GATE → self-skip exits 0 (fast-loop contract preserved)"
else
    bad "default skip exit 0" "rc=$rc"
fi

# (7) Under CCH_GATE=1, the same self-skip exits 77 (the SKIP sentinel
#     the gate keys on). RUN_CC_HARNESS unset → the first skip branch.
( unset RUN_CC_HARNESS; CCH_GATE=1; export CCH_GATE; . "$LIB"; cch_skip_if_disabled ) >/dev/null 2>&1
rc=$?
if (( rc == 77 )); then
    ok "CCH_GATE=1 → self-skip exits 77 (SKIP sentinel)"
else
    bad "gate skip exit 77" "rc=$rc"
fi

echo
echo "=== summary ==="
printf '  %d pass / %d fail\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    echo "FAIL"
    exit 1
fi
echo "ALL TESTS PASSED"
exit 0
