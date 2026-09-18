#!/usr/bin/env bash
# test-paste-dead-pane-guard-arms.sh — your-org/nexus-code#1025, code from #1283.
#
# Executes the EXIT CASCADE of test-paste-dead-pane-guard.sh and pins the one
# property that cascade exists to have: an ENVIRONMENT failure declines, a
# PRODUCT failure accuses, and a product failure is NEVER laundered by an
# environment decline occurring in the same run.
#
# Run: bash monitor/watcher/test-paste-dead-pane-guard-arms.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS SUITE EXISTS, AND WHY IT IS NOT GATED BEHIND SLOW_TESTS.
#
# The cascade it tests lives in a suite that IS so gated, and that gate makes
# the cascade unreachable: without SLOW_TESTS=1 the parent takes its line-38
# skip and exits before ANY of its five ENV sites — including the `ENVF > 0`
# arm, which is #1025's own subject. So the arms that decide whether a
# safety-critical guard's red is believable were never executed by anything, in
# either band. `58f37277` shipped them; nothing ran them. This suite is the
# thing that runs them, and it must live in the fast band to be reachable at
# all.
#
# It does NOT stand up tmux, deliberately. The parent crashes real tmux servers
# on purpose and is under a standing operator constraint not to be run here;
# the cascade is pure arithmetic over three counters and needs none of that.
#
# THE PROPERTY, and why ORDER is the whole of it. The cascade is:
#
#     if   (( FAIL > 0 )); then exit 1     # product red
#     elif (( ENVF > 0 )); then exit 69    # ENVSKIP  (#1283)
#     else                      exit 0
#
# Every arm is individually correct and the default is the permissive one, so
# the usual review heuristics — "is the default deny?", "what spelling did you
# miss?" — are both satisfied by a cascade with these two arms REVERSED. The
# defect is reachable only by asking the ordering question directly, which is
# this repo's ARM-ORDER-SHADOWING doctrine (`#1121`, CLAUDE.md). Reversed, a
# genuine `#745` guard regression on a loaded node exits 69 and reads as an
# environment skip: the guard's red becomes invisible in exactly the conditions
# that produce guard reds. That is strictly worse than the bug `#1025` fixed,
# so it is pinned here rather than trusted.
#
# NON-VACUITY, because "the harness ran" is the vacuous green this whole
# cluster of issues is about:
#   Control A — the extracted harness is PINNED by line count AND by the
#               presence of all four exit arms. A botched extraction yielding
#               no cascade would satisfy every scenario below by having no arm
#               to reach (`#618`'s shape).
#   Control B — the MUTANT MUST DIFFER. Asserting only "HEAD gives rc 1" would
#               pass for a cascade that always exits 1; the finding is that ONE
#               REORDERING changes the verdict, so the mutant is required to
#               produce a DIFFERENT rc from HEAD on the same input.
#   Control C — no captured `=== summary:` line may reach stdout. The harness
#               prints the parent's real footer, and run-tests.sh scrapes that
#               marker anchored to first-non-blank; a leaked one would make
#               this suite report the HARNESS's tally as its own.
#
# ============================================================================
# DECLARED: THIS SUITE IS IN THE BLOCKING SLOW BAND — BY MENTION, NOT BY GATE.
# ============================================================================
#
# Stated because the alternative is a reader meeting a contradiction. The band
# is discovered by `.github/workflows/tests-slow-integration.yml:221`:
#
#     grep -l 'SLOW_TESTS' monitor/watcher/test-*.sh | sort
#
# That matches the WORD, not the MECHANISM. This file contains NO gate — zero
# `$SLOW_TESTS` expansions, against the subject's one — and mentions the string
# only in comments and in the patterns/messages of the two assertions at the end
# that check the subject's gate. So `sed -n '/SLOW_TESTS:-0/,/^fi$/p' "$SUBJECT"`
# is the line that enrolled this file in the band.
#
# THE ACT OF ASSERTING ABOUT THE GATE PUT THE ASSERTER INSIDE THE GATE'S
# POPULATION. Verified, not assumed: running the workflow's own predicate at
# this ref returns this file, and `grep -cE '\$\{?SLOW_TESTS'` returns 0 here
# and 1 in the subject.
#
# IT IS HARMLESS AND THAT IS ALSO MEASURED, not argued: bare and
# `SLOW_TESTS=1 RUN_INTEGRATION=1` produce BYTE-IDENTICAL output, 15/0 each,
# with identical assertion-ID sets (`comm -3` -> 0 differing members) and a
# positive control proving the comparison can detect a planted one-token change.
# This suite reads no ambient band variable, so it cannot invert its premise the
# way `#1280`'s fixture did. It is a band member that simply always runs.
#
# DELIBERATELY NOT "FIXED". Contorting the sed pattern to dodge a `grep -l`
# would make the assertion less readable in order to protect a predicate that is
# itself the defect — the same word-not-mechanism class as `28be79e9`. Declaring
# the membership is the honest move; hiding from the grep is not.
#
# ============================================================================
# COVERAGE BOUNDARY — READ THIS BEFORE CITING THIS SUITE AS EVIDENCE.
# ============================================================================
#
# Stated here, in the artefact, rather than only in the report that accompanied
# it: closing a class against an undeclared subset is itself the defect, and a
# green whose limits live in a document nobody reads beside the code is the
# vacuous-green class with extra steps.
#
# WHAT THIS SUITE DOES ESTABLISH.
#   The exit cascade of test-paste-dead-pane-guard.sh classifies correctly in
#   all four reachable states (ENV-only, PRODUCT-only, MIXED, CLEAN), and the
#   ORDER of its two non-default arms is what produces that — proven by a
#   mutation that reverses only the order and is asserted to have APPLIED
#   (control B; an inert mutant and a real surviving mutant give byte-identical
#   output, so the mutant is required to DIFFER both as a file and in verdict).
#   The arms are EXTRACTED from the tracked subject by content-anchored `awk`,
#   never retyped, so this cannot pass against a reimplementation: edit the
#   subject's arms and the edited arms are what runs here.
#
# WHAT THIS SUITE DOES *NOT* ESTABLISH, AND WHY — A DELIBERATE EXCLUSION.
#   End-to-end integration through the parent suite under SLOW_TESTS=1 is NOT
#   measured, and was not attempted. That is an operator constraint on this
#   board, not an oversight and not a gap to be closed by a later patch: under
#   SLOW_TESTS=1 the parent exercises PASTE DELIVERY AGAINST PANES, and on a
#   board carrying live agent windows a stray paste is indistinguishable from
#   an instruction to the agent that receives it. `#1105` is the case where
#   this suite's own fixture escaped to the operator's live socket and
#   submitted its payload into a running agent four times. The cost of the
#   constraint is one unmeasured integration path; the cost of lifting it is a
#   live worker acting on a phantom instruction.
#
#   Concretely unmeasured: that `make_corpse` returning non-zero on a real
#   loaded node reaches `survival_env_skip` through the real Part C control
#   flow. This suite proves what those arms DO once reached; it does not prove
#   the reaching. Anyone citing this suite as "#1025 verified end-to-end" is
#   overstating it — say "the classification arms are proven; the integration
#   path is excluded by operator constraint."
# ============================================================================

set -uo pipefail

_test_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
# shellcheck source=./_test_helpers.sh
. "$_test_dir/_test_helpers.sh"

SUBJECT="$REPO_ROOT/monitor/watcher/test-paste-dead-pane-guard.sh"
EXPECTED_ASSERTIONS=14

WORK=$(mktemp -d -t nexus-test-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# THIS SUITE MUST NOT RED FOR AN ENVIRONMENT REASON — it would be the defect it
# exists to enforce against, committed by the enforcement (your-org/nexus-code
# #1025). A missing subject or a missing interpreter is the MACHINE, so both
# decline with the same 69/ENVSKIP token the subject now uses, rather than
# reporting a cascade regression that did not happen.
_env_decline() {
    printf '  ENV-FAIL: %s\n' "$1" >&2
    printf 'ENV-INCONCLUSIVE: this run is NOT a verdict on the cascade.\n' >&2
    exit 69
}
[[ -r "$SUBJECT" ]] || _env_decline "subject not readable: $SUBJECT"
command -v python3 >/dev/null 2>&1 || _env_decline "python3 is not on PATH; the order-reversing mutant (control B) cannot be built, and without it the scenarios below prove nothing"

# --- BUILD THE HARNESS BY EXTRACTION, NEVER BY RETYPING ---------------------
#
# The cascade is lifted out of the tracked file with `sed`, so this suite
# cannot drift from it: if somebody edits the arms, the edited arms are what
# runs here. Regions are located BY CONTENT (a unique anchor line), never by a
# hard-coded line number — a line number is a property of a tree and goes stale
# pointing at different code that still parses (`#1163`).
_region() {   # _region <start-anchor-regex> <end-anchor-regex>
    awk -v s="$1" -v e="$2" '
        $0 ~ s { on = 1 }
        on     { print }
        on && $0 ~ e && NR > 1 { exit }
    ' "$SUBJECT"
}

H="$WORK/arms.sh"
{
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    _region '^PASS=0'        '^fail[(][)]'
    _region '^ENVF=0'        '^env_fail[(][)]'
    echo 'HAZARD_REPRODUCES=${HAZARD_REPRODUCES:-1}'
    echo 'EXPECTED_SURVIVAL_ASSERTIONS=4'
    echo '_sv_ran=0 _sv_skipped=0 _sv_envskip=0'
    _region '^assert_survived[(][)] [{]'   '^[}]'
    _region '^survival_env_skip[(][)] [{]' '^[}]'
    echo 'eval "${SCENARIO}"'
    _region '^_sv_accounted='  '^exit 0'
} > "$H"

# --- CONTROL A: the extraction is real ---------------------------------------
_h_lines=$(wc -l < "$H")
if (( _h_lines >= 40 )); then
    printf '  PASS: control A — harness extracted %s lines (a zero-length extraction cannot fail below)\n' "$_h_lines"; _th_pass
else
    printf '  FAIL: control A — harness is only %s lines; extraction anchors have drifted\n' "$_h_lines" >&2; _th_fail
fi

for _arm in 'if (( FAIL > 0 ))' 'if (( ENVF > 0 ))' 'exit 1' 'exit 69'; do
    if grep -qF -- "$_arm" "$H"; then
        printf '  PASS: control A — extracted cascade contains %s\n' "$_arm"; _th_pass
    else
        printf '  FAIL: control A — extracted cascade is MISSING %s\n' "$_arm" >&2; _th_fail
    fi
done

# --- THE MUTANT: hoist the permissive ENV arm above the product arm ----------
M="$WORK/arms-mutant.sh"
python3 - "$H" "$M" <<'PY'
import sys
src = open(sys.argv[1]).read()
arm = [l for l in src.split('\n') if l.startswith('if (( FAIL > 0 ))')]
assert len(arm) == 1, "FAIL arm not unique in harness -- refusing to mutate blind"
arm = arm[0] + '\n'
src2 = src.replace(arm, '', 1)
i = src2.index('if (( ENVF > 0 )); then')
j = src2.index('\nfi\n', i) + len('\nfi\n')
open(sys.argv[2], 'w').write(src2[:j] + arm + src2[j:])
PY

if ! diff -q "$H" "$M" >/dev/null 2>&1; then
    printf '  PASS: the mutant DIFFERS from the harness (an inert mutant and a real one give identical output)\n'; _th_pass
else
    printf '  FAIL: the mutant is byte-identical to the harness — it never applied\n' >&2; _th_fail
fi

# --- DRIVE THE ARMS ----------------------------------------------------------
#
# Output is CAPTURED, never echoed: the harness prints the parent's real
# `=== summary:` footer and run-tests.sh scrapes that marker at first-non-blank
# (control C below).
_drive() {   # _drive <script> <scenario> -> prints rc; output lands in $WORK/last.out
    local rc
    SCENARIO="$2" bash "$1" > "$WORK/last.out" 2>&1; rc=$?
    printf '%s' "$rc"
}

_ENV_ONLY='server_alive(){ return 0; }
survival_env_skip "leg1"; survival_env_skip "leg2"
survival_env_skip "leg3"; survival_env_skip "leg4"'

_PRODUCT_ONLY='server_alive(){ return 1; }
assert_survived s1 "leg1"; assert_survived s2 "leg2"
assert_survived s3 "leg3"; assert_survived s4 "leg4"'

_MIXED='server_alive(){ return 1; }
survival_env_skip "leg1"; survival_env_skip "leg2"
survival_env_skip "leg3"; assert_survived s4 "leg4"'

_CLEAN='server_alive(){ return 0; }
assert_survived s1 "leg1"; assert_survived s2 "leg2"
assert_survived s3 "leg3"; assert_survived s4 "leg4"'

assert_eq "ENV only: the fixture could not build its subject -> ENVSKIP, not red" \
    "$(_drive "$H" "$_ENV_ONLY")" "69"
cp "$WORK/last.out" "$WORK/env.out"

assert_eq "PRODUCT only: a #745 guard regression still ACCUSES" \
    "$(_drive "$H" "$_PRODUCT_ONLY")" "1"

# The load-bearing one: a real regression DISCOVERED ON A LOADED NODE.
assert_eq "MIXED: 3 ENV declines + 1 real FAIL -> still accuses (FAIL outranks ENVF)" \
    "$(_drive "$H" "$_MIXED")" "1"

assert_eq "CLEAN: everything ran and survived -> green" \
    "$(_drive "$H" "$_CLEAN")" "0"

# --- CONTROL B: the mutant must DIFFER on the mixed case ---------------------
_mut_rc=$(_drive "$M" "$_MIXED")
if [[ "$_mut_rc" == "69" ]]; then
    printf '  PASS: control B — reordered cascade LAUNDERS the real regression as ENV (rc %s vs 1), so the order is what produced the result above\n' "$_mut_rc"; _th_pass
else
    printf '  FAIL: control B — reordered cascade gave rc %s; the ordering is NOT what produces the verdict, so the assertions above prove nothing\n' "$_mut_rc" >&2; _th_fail
fi

# --- CONTROL C: no captured footer leaked to our stdout ----------------------
if grep -qE '^[[:space:]]*===[[:space:]]*summary:' "$WORK/env.out"; then
    printf '  PASS: control C — the harness does emit a scrapable footer, so suppressing it is load-bearing\n'; _th_pass
else
    printf '  FAIL: control C — the harness emitted no footer; this control is asserting nothing\n' >&2; _th_fail
fi

# --- THE SUBJECT STILL DISCRIMINATES ITS TWO 77-vs-69 MEANINGS --------------
_gate=$(sed -n '/SLOW_TESTS:-0/,/^fi$/p' "$SUBJECT" | grep -c 'exit 77')
if (( _gate == 1 )); then
    printf '  PASS: the SLOW_TESTS gate still exits 77 (gate-did-not-take stays SKIP, per #1283)\n'; _th_pass
else
    printf '  FAIL: the SLOW_TESTS gate no longer exits 77 (found %s) — the two meanings have re-collided\n' "$_gate" >&2; _th_fail
fi

if ! grep -qE '^\s+exit 77' <(grep -v 'SKIP, not PASS' "$SUBJECT"); then
    printf '  PASS: every OTHER exit in the subject has left 77 — no honest ENV decline still wears the gate code\n'; _th_pass
else
    printf '  FAIL: an exit 77 survives outside the SLOW_TESTS gate — an ENV decline is still indistinguishable from "never ran"\n' >&2; _th_fail
fi

# ASSERTION CENSUS — a vanished assertion reddens here rather than shrinking
# the total in silence (`#807`).
_total=$(( ${PASS:-0} + ${FAIL:-0} + ${SKIP:-0} ))
if [[ "$_total" == "$EXPECTED_ASSERTIONS" ]]; then
    printf '  PASS: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS" >&2; _th_fail
fi

th_summary_and_exit
