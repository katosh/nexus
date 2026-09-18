#!/usr/bin/env bash
# Executes the arm-order shadowing block CLAUDE.md documents
# (your-org/nexus-code#1121), and pins the property it teaches.
#
# Run: bash monitor/watcher/test-claude-md-arm-order-shadowing.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS SUITE EXISTS. The allowlist doctrine this repo prescribes is always
# stated as a PAIR — an allowlist, with a default-deny arm. `#1121` is the case
# that shows the pair is INSUFFICIENT: `_tmux_shim_scan.awk` at `7458daf` was a
# correct default-deny allowlist whose dedicated "body names the wrapper
# LITERALLY" DENY arm was unreachable for 86% of its corpus, because a
# permissive `SAFE-STUB` arm returned first. A body containing the literal
# string `tmuxwrap` classified SAFE and was measured reaching the operator's
# live socket. The arms were in the wrong ORDER; nothing else was wrong.
#
# A doctrine is prose, and prose cannot be wrong in a way anything notices. So
# CLAUDE.md carries the demonstration in a delimited fenced block and this
# suite runs it, on the same contract as the `#618` remedies block: a
# documented form that stops behaving as documented turns this red rather than
# quietly misinforming the next reader.
#
# NON-VACUITY, because "the block ran" is exactly the vacuous green this
# cluster of issues is about:
#   Control A — the extracted line count is PINNED. A botched extraction
#               yielding zero commands would satisfy every assertion below by
#               having none to make (`#618`'s own shape).
#   Control B — the two classifiers DIFFER on the same input. Asserting only
#               `safe_first -> SAFE` would pass for a block that always says
#               SAFE; the finding is that ONE REORDERING changes the verdict.
#   Control C — the EQUALITY classifier is order-independent, asserted by
#               reordering it here and getting the same answer. That is the
#               scoping half of the rule, and without it a reader concludes
#               "hoist every deny arm", which is not what the doctrine says.
#   Control D — the block is asserted to still be REACHABLE in CLAUDE.md by
#               its markers, so deleting the doctrine reds this file.
#
# COVERAGE BOUNDARY, stated on the axis the mechanism varies on: this pins the
# SHELL's `case` semantics (first matching arm wins, patterns are globs) and
# the CLAUDE.md text ↔ behaviour coupling. It does NOT scan the repo for
# classifiers that violate the property — that is a static read a human does,
# and claiming otherwise would be a guard credited with a population it does
# not cover. `_tmux_shim_scan.awk`'s own arm order is guarded BEHAVIOURALLY by
# control `B/c1a` in test-tmux-shim-gate3-safety.sh, which is the instance.

set -uo pipefail
export LC_ALL=C

_test_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

# ── this suite DECLARES its own population (the --population protocol) ──────
# your-org/nexus-code#1219. CLAUDE.md is the document this suite EXECUTES, so
# an edit to the fenced block it pins is exactly the edit that can change its
# verdict — and until #1219 no such edit could SELECT it: a suite that declares
# no population is INVISIBLE to `guards-for-diff` rather than excluded by it
# (#1078), appearing in neither SELECTED nor CONSIDERED AND EXCLUDED, so its
# absence reads as a considered exclusion. `gp_handle` adds this suite's own
# path and `monitor/_guard_population.sh` for free; everything else is declared
# because this suite READS ITS BYTES to reach a verdict.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' \
        CLAUDE.md \
        monitor/watcher/_test_helpers.sh
}
gp_handle "$@"
th_claude_md_block_coverage ARM-ORDER-SHADOWING   # the entry's UNCHECKED share, in this suite's own output (#1239)

. "$_test_dir/_test_helpers.sh"
EXPECTED_ASSERTIONS=11   # counted BEFORE the census assertion itself
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s (got %q)\n' "$label" "$got"; _th_pass
    else printf '  FAIL: %s — got %q, want %q\n' "$label" "$got" "$want" >&2; _th_fail; fi
}

echo '=== Extraction: pull the delimited block out of CLAUDE.md ==='
assert_eq "CLAUDE.md is readable at $CLAUDE_MD" \
    "$([[ -r "$CLAUDE_MD" ]] && echo yes || echo no)" "yes"

BLOCK=$(awk -v b='<!-- BEGIN ARM-ORDER-SHADOWING -->' -v e='<!-- END ARM-ORDER-SHADOWING -->' '
    index($0, b) { inb = 1; next }
    index($0, e) { inb = 0; next }
    inb         { print }
' "$CLAUDE_MD" | sed -e 's/^[[:space:]]*//' -e '/^```/d' -e '/^$/d')

n_lines=$(printf '%s\n' "$BLOCK" | grep -c .)
# Control A — a botched extraction must RED, not silently assert nothing.
assert_eq "Control A: exactly 6 lines extracted from the CLAUDE.md block" "$n_lines" "6"

# Run the block VERBATIM in a subshell and capture the four emitted verdicts.
out=$(eval "$BLOCK" 2>&1); rc=$?
assert_eq "the extracted block runs cleanly" "$rc" "0"
mapfile_out=$(printf '%s\n' "$out" | grep -c .)
assert_eq "the block emits exactly 3 verdicts" "$mapfile_out" "3"

v1=$(printf '%s\n' "$out" | sed -n '1p')
v2=$(printf '%s\n' "$out" | sed -n '2p')
v3=$(printf '%s\n' "$out" | sed -n '3p')

echo '=== The finding: ONE reordering decides a hazardous input ==='
assert_eq "SAFE arm first: a body naming the wrapper is pronounced SAFE" "$v1" "SAFE"
assert_eq "DENY arm first: the SAME input is pronounced DENY"           "$v2" "DENY"
# Control B — the two must DISAGREE. Without this, a block that always printed
# SAFE would satisfy the assertion above.
assert_eq "Control B: the two orders DISAGREE on the same input" \
    "$([[ "$v1" != "$v2" ]] && echo differ || echo same)" "differ"

echo '=== The scope: EQUALITY arms are order-independent ==='
assert_eq "equality classifier: idle is SAFE" "$v3" "SAFE"
# Control C — reorder the equality classifier and get the SAME answer. This is
# the half that stops the rule being read as "always hoist the deny arms".
eq_reordered(){ case "$1" in busy) echo DENY;; idle) echo SAFE;; *) echo DENY-DEFAULT;; esac; }
assert_eq "Control C: reordering EQUALITY arms changes nothing" "$(eq_reordered idle)" "SAFE"
# …and the pattern classifier must still be the one that moves, so the contrast
# is measured rather than asserted.
assert_eq "Control C': the PATTERN classifier is the one order moves" \
    "$([[ "$v1" != "$v2" ]] && echo moved || echo static)" "moved"

echo '=== Control D: the doctrine is still in CLAUDE.md, not just this file ==='
# `grep -o … | wc -l` counts OCCURRENCES; `grep -c` counts LINES, and
# `monitor/watcher/textguard-lint.sh` R1 is right to refuse the latter here —
# the claim is that the property is stated ONCE, and two statements on one line
# would read as one.
assert_eq "CLAUDE.md states the third property by name, exactly once" \
    "$(grep -o 'no SAFE arm may precede a DENY arm' "$CLAUDE_MD" | wc -l)" "1"

# ASSERTION CENSUS — the exact-count guard that makes this suite's green mean
# something, and the reason `summary-honesty.manifest` carries no line for it.
# A vanished assertion reddens here rather than shrinking the total in silence:
# that is `#807`'s property, and it is the one every other check in this file
# is about, applied to this file.
_total=$(( ${PASS:-0} + ${FAIL:-0} + ${SKIP:-0} ))
if [[ "$_total" == "$EXPECTED_ASSERTIONS" ]]; then
    printf '  PASS: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS" >&2; _th_fail
fi

th_summary_and_exit
