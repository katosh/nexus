#!/usr/bin/env bash
# test-claude-md-pipeline-status.sh — execute CLAUDE.md's PIPELINE-STATUS block.
#
# WHY THIS SUITE EXISTS. `CLAUDE.md`'s authority rests on its blocks being
# EXECUTED rather than asserted. This one pins your-org/nexus-code#928: a
# pipeline's exit status is its LAST command's, so `cmd | tail` reports
# `tail`'s success and never `cmd`'s.
#
# WHAT IS ACTUALLY PINNED. Not "bash has pipelines". The two CLAIMS the entry
# makes, in both directions, because they are not the same defect:
#
#   MASKED FAILURE      — a real rc 1 is reported as 0 through `| tail`.
#   MANUFACTURED SUCCESS — a nonexistent command still lets a trailing
#                          `&& echo` fire, announcing work never done. This is
#                          the dangerous direction: the only artefact is an
#                          absence, so nothing downstream disagrees.
#   REMEDY              — `set -o pipefail` restores the real status.
#
# CONTROLS, because "the commands ran" proves nothing:
#   A — the extracted form count is PINNED at 3. A botched extraction yielding
#       zero forms would satisfy every assertion below by having none to make,
#       which is #618's own shape.
#   B — POSITIVE CONTROL: a pipeline whose producer SUCCEEDS must report 0
#       under both regimes. Without it, an assertion suite that always expected
#       0 without pipefail and 1 with it would pass against a stub that simply
#       returned the constant it was asked for.
#   C — the wrong readings EXIT 0. The defect is not that they fail; it is that
#       they succeed while describing something that did not happen.
#
# NOT COVERED, declared rather than implied: this exercises `bash`. The entry's
# claim about ad-hoc AGENT-TYPED command lines (where no `set -o` from any file
# applies) is a claim about the tool-call surface, not about a shell, and no
# in-repo fixture can witness it.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
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
th_claude_md_block_coverage PIPELINE-STATUS   # the entry's UNCHECKED share, in this suite's own output (#1239)

echo '=== Extraction: pull the delimited block out of CLAUDE.md ==='
BEGIN_MARK='<!-- BEGIN PIPELINE-STATUS -->'
END_MARK='<!-- END PIPELINE-STATUS -->'

[[ -r "$CLAUDE_MD" ]] || th_abort "CLAUDE.md not readable at $CLAUDE_MD"
assert_file_exists "CLAUDE.md is readable" "$CLAUDE_MD"

FORMS=$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    index($0, b) { inb = 1; next }
    index($0, e) { inb = 0 }
    inb' "$CLAUDE_MD" \
    | sed -E 's/^[[:space:]]+//' \
    | grep -vE '^```' \
    | sed -E 's/[[:space:]]{2,}#.*$//' \
    | grep -E '^bash ')

# CONTROL A — pin the count under an explicit bash -c. `mapfile` does not exist
# in zsh and this suite's interactive shell may be zsh; a silent empty array
# here is the very defect class the file documents.
FORM_COUNT=$(printf '%s\n' "$FORMS" | grep -c '^bash ')
assert_eq "extracted exactly 3 documented forms" "$FORM_COUNT" "3"
if [[ "$FORM_COUNT" != "3" ]]; then
    th_abort "block malformed — refusing to draw conclusions from it"
fi

FORM_MASK=$(printf '%s\n' "$FORMS" | sed -n '1p')
FORM_MANU=$(printf '%s\n' "$FORMS" | sed -n '2p')
FORM_FIX=$(printf  '%s\n' "$FORMS" | sed -n '3p')

assert_contains "form 1 is the MASKED-failure demo"      "$FORM_MASK" 'tail'
assert_contains "form 2 is the MANUFACTURED-success demo" "$FORM_MANU" 'no-such'
assert_contains "form 3 is the pipefail remedy"           "$FORM_FIX"  'pipefail'

echo
echo '=== Direction 1: a pipeline MASKS a real failure ==='
WORK=$(mktemp -d -t nexus-pipestatus-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || th_abort "cannot cd into the fixture dir"

out_mask=$(eval "$FORM_MASK" 2>/dev/null); rc_mask=$?
assert_eq       "the masking form itself EXITS 0 (control C)" "$rc_mask" "0"
assert_contains "…and reports rc=0 for a producer that exited 1" "$out_mask" "rc=0"

# Independently establish that the producer really did fail, so the assertion
# above is about MASKING and not about a producer that quietly succeeded.
bash -c 'exit 1'; producer_rc=$?
assert_eq "the producer genuinely exits 1 when not piped" "$producer_rc" "1"

echo
echo '=== Direction 2: a pipeline MANUFACTURES a success message ==='
# The documented form references ./no-such.sh; guarantee it is absent so the
# fixture cannot accidentally find a real one.
rm -f ./no-such.sh
assert_no_file "the referenced script genuinely does not exist" "$WORK/no-such.sh"

out_manu=$(eval "$FORM_MANU" 2>/dev/null); rc_manu=$?
assert_eq       "the manufacturing form EXITS 0 (control C)"        "$rc_manu" "0"
assert_contains "…and PRINTS the success message for work never done" "$out_manu" "closed 17"
assert_not_contains "…while the fallback arm never ran"          "$out_manu" "FALLBACK"

echo
echo '=== The remedy: set -o pipefail restores the real status ==='
out_fix=$(eval "$FORM_FIX" 2>/dev/null); rc_fix=$?
assert_eq       "the remedy form itself exits 0"          "$rc_fix" "0"
assert_contains "…and now reports the producer's real rc=1" "$out_fix" "rc=1"

echo
echo '=== CONTROL B: a SUCCEEDING producer reports 0 under BOTH regimes ==='
# Without this, a suite asserting "0 without pipefail, 1 with it" would pass
# against a stub that returned whichever constant it was asked for. This pins
# that pipefail changes the answer ONLY when the producer actually failed.
ok_plain=$(bash -c 'bash -c "exit 0" | tail -1; echo "rc=$?"')
ok_pf=$(bash -c 'set -o pipefail; bash -c "exit 0" | tail -1; echo "rc=$?"')
assert_contains "succeeding producer, no pipefail → rc=0" "$ok_plain" "rc=0"
assert_contains "succeeding producer, with pipefail → rc=0" "$ok_pf"   "rc=0"

echo
echo '=== The || && precedence hazard the entry names ==='
prim=$(bash -c 'true  || echo FELLBACK && echo REPORTED')
fall=$(bash -c 'false || echo FELLBACK && echo REPORTED')
assert_contains "primary-path run announces success"  "$prim" "REPORTED"
assert_contains "fallback-path run announces the SAME" "$fall" "REPORTED"
assert_contains "…even though it demonstrably took the fallback" "$fall" "FELLBACK"

# ---- assertion-count guard (your-org/nexus-code#946 F6) -------------------
# A missing assert_* helper (a typo → rc 127) is counted by NOTHING: the suite
# still prints ALL TESTS PASSED with a quietly smaller total. This suite has no
# conditional arms, so the expectation is a constant. Required by
# `test-summary-honesty-manifest.sh`, which this PR's four new suites joined as
# `ledger=yes count=none` — a green that records nothing about how much ran.
EXPECTED_ASSERTIONS=19
TOTAL_ASSERTIONS=$(( PASS + FAIL ))
assert_eq "assertion TOTAL matches the EXPECTED total — no assertion silently dropped or added" \
          "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
